;;; init-pulldown.el --- Themed buffer-based pulldown menus -*- lexical-binding: t; -*-

;;; Commentary:

;; A themed, buffer-based replacement for the native (GTK/Lucid/Motif)
;; popup menus that `popup-menu' and `x-popup-menu' draw.  Native menus
;; ignore the Emacs theme and, under some GTK themes, draw ugly double
;; separators.  This library renders the same menus in `posframe' child
;; frames using ordinary buffers and faces, so they inherit the current
;; theme and look consistent with the rest of the frame.
;;
;; It consumes the very same data the native menus do -- an Emacs menu
;; keymap or an `easy-menu' item list -- so existing menu definitions work
;; unchanged.  Just swap the renderer:
;;
;;     (popup-menu MENU EVENT)      =>  (pulldown-menu-popup MENU EVENT)
;;     (x-popup-menu EVENT KEYMAP)  =>  (pulldown-menu-popup KEYMAP EVENT)
;;
;; Interaction (mouse-driven, keyboard-focused):
;;   up / down / C-p / C-n   move between items (separators are skipped)
;;   right / C-f             open the submenu under the cursor
;;   left / C-b              close the current submenu
;;   RET / SPC               run the item, or open its submenu
;;   a printable character   jump to the next item whose label starts with it
;;   ESC / C-g               cancel
;;   mouse hover             highlight the row, open submenus automatically
;;   mouse click             run the item; a click outside the menu cancels
;;
;; On a non-graphical frame (no child frames) it falls back to the
;; built-in text menu, `tmm-prompt'.

;;; Code:

(require 'cl-lib)

(declare-function posframe-show "posframe")
(declare-function posframe-hide "posframe")
(declare-function easy-menu-create-menu "easymenu")
(declare-function tmm-prompt "tmm")

;;;; Customization and faces

(defgroup pulldown-menu nil
  "Themed buffer-based pulldown menus."
  :group 'convenience
  :prefix "pulldown-menu-")

(defcustom pulldown-menu-min-width 18
  "Minimum width, in columns, of a pulldown menu."
  :type 'integer)

(defcustom pulldown-menu-separator-height 0.3
  "Height of a separator row as a fraction of the default line height.
Smaller values give a thinner divider that hugs its neighbours instead
of leaving a tall striped band."
  :type 'number)

(defcustom pulldown-menu-separator-blend 0.65
  "How far the separator color is blended toward the background, 0.0-1.0.
Higher values make the divider fainter."
  :type 'number)

(defface pulldown-menu-default
  '((t :inherit default))
  "Base face for pulldown-menu text and background.")

(defface pulldown-menu-selection
  '((t :inherit highlight :extend t))
  "Face for the highlighted (current) menu row.")

(defface pulldown-menu-key
  '((t :inherit shadow))
  "Face for the accelerator key shown at the right of an item.")

(defface pulldown-menu-arrow
  '((t :inherit shadow))
  "Face for the submenu arrow shown at the right of an item.")

(defface pulldown-menu-separator
  '((t :inherit shadow))
  "Face for separator rules between item groups.")

(defface pulldown-menu-disabled
  '((t :inherit shadow))
  "Face for disabled (greyed-out) items.")

(defface pulldown-menu-border
  '((t :inherit shadow))
  "Face whose foreground colors the border around a pulldown menu.")

;;;; A single open menu level

(cl-defstruct (pulldown-menu--level (:constructor pulldown-menu--level-make))
  "One open level of the menu tree, displayed in its own child frame."
  buffer         ; the buffer displayed in this level's child frame
  frame          ; the posframe child frame
  items          ; list of parsed item plists, one per line
  selection      ; index into ITEMS of the current row, or nil
  overlay        ; overlay drawing the selection highlight
  depth          ; 0 for the root menu, +1 per nested submenu
  parent-index)  ; index in the parent level this submenu was opened from

;; Dynamic state of the modal loop, bound in `pulldown-menu--run'.
(defvar pulldown-menu--stack nil
  "Stack of open `pulldown-menu--level' structs, deepest first.")
(defvar pulldown-menu--result nil
  "Command chosen by the user, set when the loop should finish.")
(defvar pulldown-menu--done nil
  "Non-nil ends the modal loop.")

;;;; Parsing menu keymaps into item plists

(defun pulldown-menu--eval (form)
  "Evaluate a menu-item property FORM, returning nil on error."
  (condition-case nil
      (eval form t)
    (error nil)))

(defun pulldown-menu--as-keymap (binding)
  "Return BINDING as a keymap if it is (or names) one, else nil."
  (cond
   ((keymapp binding) binding)
   ((and (symbolp binding) (fboundp binding)
         (keymapp (symbol-function binding)))
    (symbol-function binding))))

(defun pulldown-menu--key-hint (command)
  "Return a key-description string for COMMAND's binding, or nil."
  (when (and (symbolp command) (commandp command))
    (let ((keys (where-is-internal command nil t)))
      (when keys (ignore-errors (key-description keys))))))

(defun pulldown-menu--button-state (button)
  "Return (TYPE . ON) for a menu-item :button BUTTON spec, or nil.
TYPE is `:toggle' or `:radio'; ON is the evaluated on/off state."
  (when (consp button)
    (cons (car button) (pulldown-menu--eval (cdr button)))))

(defun pulldown-menu--prefix (item)
  "Return the two-column check/radio prefix string for ITEM."
  (pcase (plist-get item :state)
    (`(:toggle . ,on) (if on "☑ " "☐ "))
    (`(:radio . ,on) (if on "◉ " "○ "))
    (_ "  ")))

(defun pulldown-menu--make-item (label binding enabled &optional keys state)
  "Build an item plist from LABEL, BINDING, ENABLED, KEYS and STATE."
  (let ((submenu (pulldown-menu--as-keymap binding)))
    (if submenu
        (list :type 'submenu :label label :keymap submenu :enabled enabled)
      (list :type 'item :label label :command binding :enabled enabled
            :keys (or keys (pulldown-menu--key-hint binding))
            :state state))))

(defun pulldown-menu--coerce-string (value)
  "Coerce a menu VALUE to a display string, or nil.
VALUE may already be a string, a function to call (as menu-item labels
and key hints sometimes are), or a form to evaluate."
  (cond
   ((stringp value) value)
   ((null value) nil)
   ((and (functionp value) (not (symbolp value)))
    (let ((result (ignore-errors (funcall value))))
      (and (stringp result) result)))
   ((symbolp value) nil)
   (t (let ((result (pulldown-menu--eval value)))
        (and (stringp result) result)))))

(defun pulldown-menu--coerce-keys (value)
  "Coerce a menu-item :keys VALUE to a substituted key-hint string, or nil."
  (let ((hint (pulldown-menu--coerce-string value)))
    (when (and hint (> (length hint) 0))
      (or (ignore-errors (substitute-command-keys hint)) hint))))

(defun pulldown-menu--parse-menu-item (def)
  "Parse a `menu-item' form DEF into an item plist, or nil."
  (let* ((props (nthcdr 3 def))
         ;; A :label property, when present, overrides NAME (nth 1); both
         ;; can be strings, forms, or functions (e.g. cua-mode's Cut/Copy).
         (name (or (pulldown-menu--coerce-string (plist-get props :label))
                   (pulldown-menu--coerce-string (nth 1 def))))
         (binding (nth 2 def))
         (visible (plist-member props :visible)))
    (cond
     ((null name) nil)
     ((string-prefix-p "--" name) '(:type separator))
     ((and visible (not (pulldown-menu--eval (cadr visible)))) nil)
     (t
      (let* ((filter (plist-get props :filter))
             (enable (plist-member props :enable))
             (keys (pulldown-menu--coerce-keys (plist-get props :keys)))
             (button (plist-get props :button)))
        (when filter (setq binding (funcall filter binding)))
        (pulldown-menu--make-item
         name binding
         (if enable (and (pulldown-menu--eval (cadr enable)) t) t)
         keys (pulldown-menu--button-state button)))))))

(defun pulldown-menu--parse-entry (def)
  "Parse one keymap binding DEF into an item plist, or nil."
  (cond
   ((and (stringp def) (string-prefix-p "--" def)) '(:type separator))
   ((eq (car-safe def) 'menu-item) (pulldown-menu--parse-menu-item def))
   ;; Old-style (STRING . BINDING) or (STRING HELP . BINDING).
   ((and (consp def) (stringp (car def)))
    (let ((label (car def))
          (binding (cdr def)))
      (when (stringp (car-safe binding)) (setq binding (cdr binding)))
      (if (string-prefix-p "--" label)
          '(:type separator)
        (pulldown-menu--make-item label binding t))))))

(defun pulldown-menu--parse (keymap)
  "Parse KEYMAP into an ordered list of item plists."
  (let (items)
    (map-keymap
     (lambda (_key def)
       (let ((item (pulldown-menu--parse-entry def)))
         (when item (push item items))))
     keymap)
    (nreverse items)))

(defun pulldown-menu--selectable-p (item)
  "Return non-nil when ITEM can be highlighted and activated."
  (and item
       (plist-get item :enabled)
       (pcase (plist-get item :type)
         ('submenu t)
         ('item (let ((command (plist-get item :command)))
                  (or (commandp command) (keymapp command))))
         (_ nil))))

(defun pulldown-menu--first-selectable (items)
  "Return the index of the first selectable item in ITEMS, or nil."
  (cl-position-if #'pulldown-menu--selectable-p items))

;;;; Rendering

(defun pulldown-menu--setup-buffer ()
  "Prepare the current buffer to display a menu level."
  (setq-local mode-line-format nil
              header-line-format nil
              cursor-type nil
              truncate-lines t
              show-trailing-whitespace nil
              display-line-numbers nil
              left-margin-width 0
              right-margin-width 0
              face-remapping-alist nil)
  (buffer-disable-undo)
  (setq-local buffer-read-only t))

(defun pulldown-menu--item-cells (item)
  "Return (LEFT . RIGHT) display strings for ITEM before padding."
  (pcase (plist-get item :type)
    ('separator (cons "" ""))
    ('submenu (cons (concat (pulldown-menu--prefix item)
                            (plist-get item :label))
                    "▸"))
    ('item (cons (concat (pulldown-menu--prefix item)
                         (plist-get item :label))
                 (or (plist-get item :keys) "")))))

(defun pulldown-menu--color (face attribute fallback)
  "Return FACE's ATTRIBUTE color as a string, or FALLBACK's when unset."
  (let ((color (face-attribute face attribute nil t)))
    (if (stringp color) color (face-attribute fallback attribute nil t))))

(defun pulldown-menu--divider-color ()
  "Return a faint separator color blended toward the menu background."
  (require 'color)
  (let ((background (color-name-to-rgb
                     (pulldown-menu--color 'pulldown-menu-default
                                           :background 'default)))
        (foreground (color-name-to-rgb
                     (pulldown-menu--color 'pulldown-menu-separator
                                           :foreground 'shadow)))
        (weight (max 0.0 (min 1.0 pulldown-menu-separator-blend))))
    (if (and background foreground)
        (apply #'color-rgb-to-hex
               (append (cl-mapcar (lambda (b f)
                                    (+ (* weight b) (* (- 1.0 weight) f)))
                                  background foreground)
                       '(2)))
      (pulldown-menu--color 'pulldown-menu-separator :foreground 'shadow))))

(defun pulldown-menu--format-line (item left right width)
  "Return the WIDTH-column rendered line for ITEM from LEFT and RIGHT."
  (pcase (plist-get item :type)
    ('separator
     ;; A 1-pixel hairline (an overline, not a filled bar) on a row whose
     ;; height is trimmed by `line-height' on the terminating newline in
     ;; `pulldown-menu--open', so it hugs its neighbours without a band.
     (propertize (make-string width ?\s)
                 'face (list :overline (pulldown-menu--divider-color))))
    (_
     (let* ((enabled (plist-get item :enabled))
            (left-face (if enabled 'pulldown-menu-default 'pulldown-menu-disabled))
            (right-face (if (eq (plist-get item :type) 'submenu)
                            'pulldown-menu-arrow 'pulldown-menu-key))
            (padding (max 1 (- width 2 (string-width left) (string-width right)))))
       (concat " "
               (propertize left 'face left-face)
               (make-string padding ?\s)
               (propertize right 'face right-face)
               " ")))))

(defun pulldown-menu--show (buffer x y width lines)
  "Show BUFFER in a child frame at frame-relative pixel X, Y.
WIDTH is in columns and LINES the number of rows; both clamp the frame
onto the parent.  Return the child frame."
  (let* ((frame (selected-frame))
         (pixel-width (+ (* width (frame-char-width frame)) 4))
         (pixel-height (+ (* lines (frame-char-height frame)) 4))
         (left (max 0 (min x (max 0 (- (frame-pixel-width frame) pixel-width)))))
         (top (max 0 (min y (max 0 (- (frame-pixel-height frame) pixel-height))))))
    (posframe-show
     buffer
     :position (cons left top)
     :internal-border-width 1
     :internal-border-color (pulldown-menu--color 'pulldown-menu-border
                                                  :foreground 'shadow)
     :background-color (pulldown-menu--color 'pulldown-menu-default
                                             :background 'default)
     :foreground-color (pulldown-menu--color 'pulldown-menu-default
                                             :foreground 'default)
     :accept-focus nil
     :lines-truncate t
     :hidehandler nil)))

(defun pulldown-menu--draw-selection (level)
  "Move LEVEL's selection overlay onto its current row."
  (let ((buffer (pulldown-menu--level-buffer level))
        (index (pulldown-menu--level-selection level))
        (overlay (pulldown-menu--level-overlay level)))
    (when (and index (buffer-live-p buffer) (overlayp overlay))
      (with-current-buffer buffer
        (goto-char (point-min))
        (forward-line index)
        (move-overlay overlay (line-beginning-position)
                      (min (point-max) (1+ (line-end-position)))
                      buffer)))))

(defun pulldown-menu--line-width (cells)
  "Return the rendered menu width in columns for item CELLS."
  (let ((left (apply #'max 1 (mapcar (lambda (cell) (string-width (car cell)))
                                     cells)))
        (right (apply #'max 0 (mapcar (lambda (cell) (string-width (cdr cell)))
                                      cells))))
    (max pulldown-menu-min-width
         (+ 2 left (if (> right 0) 3 0) right))))

(defun pulldown-menu--insert-items (items cells width)
  "Insert ITEMS, rendered from CELLS at WIDTH columns, into the buffer."
  (let ((last (1- (length items))))
    (cl-loop for item in items
             for cell in cells
             for index from 0
             do (insert (pulldown-menu--format-line
                         item (car cell) (cdr cell) width))
             (when (< index last)
               ;; The newline that ends a row carries its `line-height';
               ;; trim separator rows so the divider stays thin.
               (insert (if (eq (plist-get item :type) 'separator)
                           (propertize "\n" 'line-height
                                       pulldown-menu-separator-height)
                         "\n"))))))

(defun pulldown-menu--open (items x y depth parent-index)
  "Render ITEMS in a child frame at X, Y and return a level struct.
DEPTH and PARENT-INDEX identify the level within the open menu tree."
  (let* ((buffer (get-buffer-create (format " *pulldown-menu-%d*" depth)))
         (cells (mapcar #'pulldown-menu--item-cells items))
         (width (pulldown-menu--line-width cells))
         overlay)
    (with-current-buffer buffer
      (pulldown-menu--setup-buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (pulldown-menu--insert-items items cells width)
        (goto-char (point-min)))
      (setq overlay (make-overlay (point-min) (point-min)))
      (overlay-put overlay 'face 'pulldown-menu-selection)
      (overlay-put overlay 'priority 100))
    (let ((level (pulldown-menu--level-make
                  :buffer buffer
                  :frame (pulldown-menu--show buffer x y width (length items))
                  :items items
                  :selection (pulldown-menu--first-selectable items)
                  :overlay overlay
                  :depth depth
                  :parent-index parent-index)))
      (pulldown-menu--draw-selection level)
      level)))

(defun pulldown-menu--close (level)
  "Hide LEVEL's child frame and drop its selection overlay."
  (when level
    (let ((buffer (pulldown-menu--level-buffer level))
          (overlay (pulldown-menu--level-overlay level)))
      (when (overlayp overlay) (delete-overlay overlay))
      (when (buffer-live-p buffer) (ignore-errors (posframe-hide buffer))))))

;;;; Navigation over the open stack

(defun pulldown-menu--current-item (level)
  "Return the currently selected item of LEVEL, or nil."
  (when-let ((selection (pulldown-menu--level-selection level)))
    (nth selection (pulldown-menu--level-items level))))

(defun pulldown-menu--child-of (level)
  "Return the open child level of LEVEL, or nil."
  (cl-find (1+ (pulldown-menu--level-depth level))
           pulldown-menu--stack :key #'pulldown-menu--level-depth))

(defun pulldown-menu--close-deeper-than (level)
  "Close every open level nested below LEVEL."
  (let ((depth (pulldown-menu--level-depth level)))
    (while (and pulldown-menu--stack
                (> (pulldown-menu--level-depth (car pulldown-menu--stack)) depth))
      (pulldown-menu--close (pop pulldown-menu--stack)))))

(defun pulldown-menu--collapse-one ()
  "Close the deepest open submenu, keeping the root open."
  (when (cdr pulldown-menu--stack)
    (pulldown-menu--close (pop pulldown-menu--stack))))

(defun pulldown-menu--select-at (level index)
  "Select row INDEX in LEVEL and redraw its highlight."
  (setf (pulldown-menu--level-selection level) index)
  (pulldown-menu--draw-selection level))

(defun pulldown-menu--move (level direction)
  "Move LEVEL's selection by DIRECTION (+1 or -1) to the next selectable row."
  (let* ((items (pulldown-menu--level-items level))
         (count (length items))
         (index (or (pulldown-menu--level-selection level) 0)))
    (when (> count 0)
      (cl-loop repeat count
               do (setq index (mod (+ index direction) count))
               when (pulldown-menu--selectable-p (nth index items))
               return (pulldown-menu--select-at level index)))))

(defun pulldown-menu--type-ahead (level character)
  "Select the next item in LEVEL whose label starts with CHARACTER."
  (let* ((items (pulldown-menu--level-items level))
         (count (length items))
         (start (or (pulldown-menu--level-selection level) -1))
         (wanted (downcase character)))
    (cl-loop for step from 1 to count
             for index = (mod (+ start step) count)
             for item = (nth index items)
             when (and (pulldown-menu--selectable-p item)
                       (let ((label (plist-get item :label)))
                         (and (> (length label) 0)
                              (eql (downcase (aref label 0)) wanted))))
             return (pulldown-menu--select-at level index))))

(defun pulldown-menu--submenu-position (level)
  "Return frame-relative (X . Y) for a submenu opened from LEVEL."
  (let ((parent (selected-frame))
        (child (pulldown-menu--level-frame level)))
    (pcase-let ((`(,parent-left ,parent-top ,_r ,_b)
                 (frame-edges parent 'native-edges))
                (`(,_l ,child-top ,child-right ,_cb)
                 (frame-edges child 'native-edges)))
      (let ((selection (or (pulldown-menu--level-selection level) 0))
            (line-height (frame-char-height child)))
        (cons (max 0 (- child-right parent-left 3))
              (max 0 (+ (- child-top parent-top)
                        (* selection line-height) 1)))))))

(defun pulldown-menu--open-submenu-of (level)
  "Open the submenu selected in LEVEL, if any, pushing it on the stack."
  (let ((item (pulldown-menu--current-item level)))
    (when (and item (eq (plist-get item :type) 'submenu)
               (plist-get item :enabled))
      (let ((child (pulldown-menu--child-of level)))
        (unless (and child (eql (pulldown-menu--level-parent-index child)
                                (pulldown-menu--level-selection level)))
          (pulldown-menu--close-deeper-than level)
          (let ((items (pulldown-menu--parse (plist-get item :keymap))))
            (when (cl-some #'pulldown-menu--selectable-p items)
              (pcase-let ((`(,x . ,y) (pulldown-menu--submenu-position level)))
                (push (pulldown-menu--open
                       items x y
                       (1+ (pulldown-menu--level-depth level))
                       (pulldown-menu--level-selection level))
                      pulldown-menu--stack)))))))))

(defun pulldown-menu--choose (item)
  "Finish the modal loop by choosing ITEM's command."
  (setq pulldown-menu--result (plist-get item :command)
        pulldown-menu--done t))

(defun pulldown-menu--activate ()
  "Act on the current item of the deepest open level."
  (let* ((level (car pulldown-menu--stack))
         (item (pulldown-menu--current-item level)))
    (when (and item (plist-get item :enabled))
      (pcase (plist-get item :type)
        ('submenu (pulldown-menu--open-submenu-of level))
        ('item (pulldown-menu--choose item))))))

;;;; Event handling

(defun pulldown-menu--key-action (event)
  "Classify a keyboard EVENT into a navigation action symbol, or nil."
  (cond
   ((memq event '(up ?\C-p)) 'up)
   ((memq event '(down ?\C-n)) 'down)
   ((memq event '(right ?\C-f)) 'right)
   ((memq event '(left ?\C-b)) 'left)
   ((memq event '(return ?\r ?\n kp-enter ?\s)) 'activate)
   ((memq event '(escape ?\e ?\C-g)) 'cancel)
   ((and (characterp event) (>= event ?!) (<= event ?~)) (cons 'char event))))

(defun pulldown-menu--event->hit (event)
  "Return (LEVEL . INDEX) for the menu row under EVENT, or nil."
  (let* ((position (event-start event))
         (window (posn-window position)))
    (when (windowp window)
      (let* ((buffer (window-buffer window))
             (level (cl-find buffer pulldown-menu--stack
                             :key #'pulldown-menu--level-buffer)))
        (when level
          (let* ((point (posn-point position))
                 (row (cdr (posn-col-row position)))
                 (index (cond
                         ((integerp point)
                          (with-current-buffer buffer
                            (1- (line-number-at-pos point))))
                         ((integerp row) row))))
            (when (and index (>= index 0)
                       (< index (length (pulldown-menu--level-items level))))
              (cons level index))))))))

(defun pulldown-menu--hover-settled-p (level index item)
  "Return non-nil when hovering row INDEX of LEVEL needs no redraw.
ITEM is the item on that row: it is settled when the row is already
selected and its submenu state already matches."
  (and (eql (pulldown-menu--level-selection level) index)
       (let ((child (pulldown-menu--child-of level)))
         (if (eq (plist-get item :type) 'submenu)
             (and child (eql (pulldown-menu--level-parent-index child) index))
           (null child)))))

(defun pulldown-menu--hover (event)
  "Handle a mouse-movement EVENT: highlight and open submenus on hover."
  (when-let ((hit (pulldown-menu--event->hit event)))
    (pcase-let ((`(,level . ,index) hit))
      (let ((item (nth index (pulldown-menu--level-items level))))
        (when (and (pulldown-menu--selectable-p item)
                   (not (pulldown-menu--hover-settled-p level index item)))
          (pulldown-menu--close-deeper-than level)
          (pulldown-menu--select-at level index)
          (when (eq (plist-get item :type) 'submenu)
            (pulldown-menu--open-submenu-of level)))))))

(defun pulldown-menu--click (event)
  "Handle a mouse click EVENT: activate the row under it."
  (when-let ((hit (pulldown-menu--event->hit event)))
    (pcase-let ((`(,level . ,index) hit))
      (let ((item (nth index (pulldown-menu--level-items level))))
        (when (pulldown-menu--selectable-p item)
          (pulldown-menu--close-deeper-than level)
          (pulldown-menu--select-at level index)
          (pcase (plist-get item :type)
            ('submenu (pulldown-menu--open-submenu-of level))
            ('item (pulldown-menu--choose item))))))))

(defun pulldown-menu--handle-mouse (event)
  "Dispatch a mouse EVENT to hover, wheel, click or cancel handling."
  (pcase (car event)
    ('mouse-movement (pulldown-menu--hover event))
    ((or 'wheel-up 'mouse-4) (pulldown-menu--move (car pulldown-menu--stack) -1))
    ((or 'wheel-down 'mouse-5) (pulldown-menu--move (car pulldown-menu--stack) 1))
    ((or 'down-mouse-1 'down-mouse-2 'down-mouse-3)
     ;; A press outside every open frame dismisses the menu.
     (unless (pulldown-menu--event->hit event)
       (setq pulldown-menu--done t)))
    ((or 'mouse-1 'mouse-2 'mouse-3 'double-mouse-1 'triple-mouse-1)
     (pulldown-menu--click event))))

(defun pulldown-menu--handle-event (event)
  "Dispatch a single input EVENT read by the modal loop."
  (cond
   ((null event) nil)
   ((consp event) (pulldown-menu--handle-mouse event))
   (t
    (pcase (pulldown-menu--key-action event)
      ('up       (pulldown-menu--move (car pulldown-menu--stack) -1))
      ('down     (pulldown-menu--move (car pulldown-menu--stack) 1))
      ('right    (pulldown-menu--open-submenu-of (car pulldown-menu--stack)))
      ('left     (pulldown-menu--collapse-one))
      ('activate (pulldown-menu--activate))
      ('cancel   (setq pulldown-menu--done t))
      (`(char . ,character)
       (pulldown-menu--type-ahead (car pulldown-menu--stack) character))))))

(defun pulldown-menu--run (items x y)
  "Run the modal menu loop for root ITEMS shown at X, Y.
Return the command the user chose, or nil."
  (let ((pulldown-menu--stack (list (pulldown-menu--open items x y 0 nil)))
        (pulldown-menu--result nil)
        (pulldown-menu--done nil)
        (inhibit-quit t)
        ;; The invoking key sequence (e.g. "tab-bar down-mouse-1 mouse-1")
        ;; is echoed while a command reads events; silence it for the loop.
        (echo-keystrokes 0))
    (unwind-protect
        (let ((track-mouse t))
          (clear-this-command-keys)
          (while (not pulldown-menu--done)
            (pulldown-menu--handle-event (read-event))))
      (mapc #'pulldown-menu--close pulldown-menu--stack)
      (message nil))
    pulldown-menu--result))

;;;; Entry points

(defun pulldown-menu--mouse-position (frame)
  "Return frame-relative (X . Y) just below the mouse pointer in FRAME."
  (pcase-let ((`(,frame-left ,frame-top ,_r ,_b)
               (frame-edges frame 'native-edges))
              (`(,mouse-x . ,mouse-y) (mouse-absolute-pixel-position)))
    (let ((line-height (frame-char-height frame))
          (relative-y (max 0 (- mouse-y frame-top))))
      ;; Anchor to the bottom of the row the pointer is in, so the menu
      ;; sits just under the clicked line or bar wherever within that row
      ;; the click landed; adding a full line overshoots by up to a line.
      (cons (max 0 (- mouse-x frame-left))
            (* (1+ (/ relative-y line-height)) line-height)))))

(defun pulldown-menu--point-position (frame)
  "Return frame-relative (X . Y) just below point in FRAME."
  (if-let ((position (posn-at-point)))
      (pcase-let ((`(,x . ,y) (posn-x-y position))
                  (`(,left ,top ,_r ,_b) (window-inside-pixel-edges)))
        (cons (+ x left) (+ y top (frame-char-height frame))))
    (cons 8 (frame-char-height frame))))

(defun pulldown-menu--trigger-position (trigger)
  "Return frame-relative (X . Y) pixels at which to open the menu.
TRIGGER is the mouse event that requested the menu, or nil.  Without a
mouse event, open near point; failing that, near the top-left corner."
  (let ((frame (selected-frame)))
    (if (and trigger (mouse-event-p trigger))
        (pulldown-menu--mouse-position frame)
      (pulldown-menu--point-position frame))))

(defun pulldown-menu--call (command)
  "Run COMMAND as if the user had invoked it from a menu."
  (when (commandp command)
    (setq this-command command)
    (let ((last-nonmenu-event t))
      (call-interactively command))))

;;;###autoload
(defun pulldown-menu-popup (menu &optional trigger)
  "Display MENU as a themed, buffer-based pulldown and run the chosen item.
MENU is an Emacs menu keymap or an `easy-menu' item list.  TRIGGER, when
given, is the mouse event that requested the menu and positions it.

Falls back to `tmm-prompt' on a non-graphical frame."
  (let ((keymap (if (keymapp menu) menu (easy-menu-create-menu nil menu))))
    (if (not (and (display-graphic-p) (require 'posframe nil t)))
        (pulldown-menu--call (tmm-prompt keymap))
      (let ((items (pulldown-menu--parse keymap)))
        (if (not (cl-some #'pulldown-menu--selectable-p items))
            (message "(Empty menu)")
          (pcase-let ((`(,x . ,y) (pulldown-menu--trigger-position trigger)))
            (pulldown-menu--call (pulldown-menu--run items x y))))))))

;;;; Context-menu integration

(declare-function context-menu-map "mouse")

(defun pulldown-menu--popup-context (menu trigger)
  "Show context MENU via the pulldown, or run it when it is a command.
TRIGGER is the event that requested it, or nil."
  (if (commandp menu)
      (pulldown-menu--call menu)
    (pulldown-menu-popup menu trigger)))

;;;###autoload
(defun pulldown-menu-context-menu (event)
  "Open the context menu for mouse EVENT as a themed pulldown.
A drop-in replacement for the native binding on `down-mouse-3'."
  (interactive "e")
  (require 'mouse)
  ;; `context-menu-map' selects the clicked window and builds the menu
  ;; from `context-menu-functions', exactly as the native path does.
  (pulldown-menu--popup-context (context-menu-map event) event))

;;;###autoload
(defun pulldown-menu-context-menu-open ()
  "Open the context menu at point as a themed pulldown.
A drop-in replacement for `context-menu-open' (keyboard entry points
such as \\[context-menu-open])."
  (interactive)
  (require 'mouse)
  (pulldown-menu--popup-context (context-menu-map) nil))

(provide 'init-pulldown)
;;; init-pulldown.el ends here
