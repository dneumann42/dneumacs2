;;; pulldown-menu.el --- Themed buffer-based pulldown menus -*- lexical-binding: t; -*-

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
;;   left / C-b             close the current submenu
;;   RET / SPC              run the item, or open its submenu
;;   a printable character  jump to the next item whose label starts with it
;;   ESC / C-g             cancel
;;   mouse hover            highlight the row, open submenus automatically
;;   mouse click            run the item; a click outside the menu cancels
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
  buffer       ; the buffer displayed in this level's child frame
  frame        ; the posframe child frame
  items        ; list of parsed item plists, one per line
  selection    ; index into ITEMS of the current row, or nil
  overlay      ; overlay drawing the selection highlight
  depth        ; 0 for the root menu, +1 per nested submenu
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
  (pcase (car-safe (plist-get item :state))
    (:toggle (if (cdr (plist-get item :state)) "☑ " "☐ "))
    (:radio  (if (cdr (plist-get item :state)) "◉ " "○ "))
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
    (let ((r (ignore-errors (funcall value)))) (and (stringp r) r)))
   ((symbolp value) nil)
   (t (let ((r (pulldown-menu--eval value))) (and (stringp r) r)))))

(defun pulldown-menu--coerce-keys (value)
  "Coerce a menu-item :keys VALUE to a substituted key-hint string, or nil."
  (let ((s (pulldown-menu--coerce-string value)))
    (when (and s (> (length s) 0))
      (or (ignore-errors (substitute-command-keys s)) s))))

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
         ('item (let ((c (plist-get item :command)))
                  (or (commandp c) (keymapp c))))
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
            (lface (if enabled 'pulldown-menu-default 'pulldown-menu-disabled))
            (rface (if (eq (plist-get item :type) 'submenu)
                       'pulldown-menu-arrow 'pulldown-menu-key))
            (pad (max 1 (- width 2 (string-width left) (string-width right)))))
       (concat " "
               (propertize left 'face lface)
               (make-string pad ?\s)
               (propertize right 'face rface)
               " ")))))

(defun pulldown-menu--color (face attr fallback)
  "Return FACE's ATTR color as a string, or FALLBACK's when unset."
  (let ((c (face-attribute face attr nil t)))
    (if (stringp c) c (face-attribute fallback attr nil t))))

(defun pulldown-menu--divider-color ()
  "Return a faint separator color blended toward the menu background."
  (require 'color)
  (let ((bg (color-name-to-rgb
             (pulldown-menu--color 'pulldown-menu-default :background 'default)))
        (fg (color-name-to-rgb
             (pulldown-menu--color 'pulldown-menu-separator :foreground 'shadow)))
        (w (max 0.0 (min 1.0 pulldown-menu-separator-blend))))
    (if (and bg fg)
        (apply #'color-rgb-to-hex
               (append (cl-mapcar (lambda (b f) (+ (* w b) (* (- 1.0 w) f))) bg fg)
                       '(2)))
      (pulldown-menu--color 'pulldown-menu-separator :foreground 'shadow))))

(defun pulldown-menu--show (buf x y width nlines)
  "Show BUF in a child frame at frame-relative pixel X, Y.
WIDTH is in columns and NLINES the number of rows; both clamp the
frame onto the parent.  Return the child frame."
  (let* ((frame (selected-frame))
         (cw (frame-char-width frame))
         (chh (frame-char-height frame))
         (pw (frame-pixel-width frame))
         (ph (frame-pixel-height frame))
         (px-w (+ (* width cw) 4))
         (px-h (+ (* nlines chh) 4))
         (x2 (max 0 (min x (max 0 (- pw px-w)))))
         (y2 (max 0 (min y (max 0 (- ph px-h))))))
    (posframe-show
     buf
     :position (cons x2 y2)
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
  (let ((buf (pulldown-menu--level-buffer level))
        (idx (pulldown-menu--level-selection level))
        (ov (pulldown-menu--level-overlay level)))
    (when (and idx (buffer-live-p buf) (overlayp ov))
      (with-current-buffer buf
        (goto-char (point-min))
        (forward-line idx)
        (move-overlay ov (line-beginning-position)
                      (min (point-max) (1+ (line-end-position)))
                      buf)))))

(defun pulldown-menu--open (items x y depth parent-index)
  "Render ITEMS in a child frame at X, Y and return a level struct.
DEPTH and PARENT-INDEX identify the level within the open menu tree."
  (let* ((buf (get-buffer-create (format " *pulldown-menu-%d*" depth)))
         (cells (mapcar #'pulldown-menu--item-cells items))
         (lw (apply #'max 1 (mapcar (lambda (c) (string-width (car c))) cells)))
         (rw (apply #'max 0 (mapcar (lambda (c) (string-width (cdr c))) cells)))
         (gap (if (> rw 0) 3 0))
         (width (max pulldown-menu-min-width (+ 2 lw gap rw)))
         overlay)
    (with-current-buffer buf
      (pulldown-menu--setup-buffer)
      (let ((inhibit-read-only t)
            (n (length items)))
        (erase-buffer)
        (cl-loop for item in items
                 for cell in cells
                 for i from 0
                 do (insert (pulldown-menu--format-line
                             item (car cell) (cdr cell) width))
                 (when (< i (1- n))
                   ;; The newline that ends a row carries its `line-height';
                   ;; trim separator rows so the divider stays thin.
                   (insert (if (eq (plist-get item :type) 'separator)
                               (propertize "\n" 'line-height
                                           pulldown-menu-separator-height)
                             "\n"))))
        (goto-char (point-min)))
      (setq overlay (make-overlay (point-min) (point-min)))
      (overlay-put overlay 'face 'pulldown-menu-selection)
      (overlay-put overlay 'priority 100))
    (let ((level (pulldown-menu--level-make
                  :buffer buf
                  :frame (pulldown-menu--show buf x y width (length items))
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
    (let ((buf (pulldown-menu--level-buffer level))
          (ov (pulldown-menu--level-overlay level)))
      (when (overlayp ov) (delete-overlay ov))
      (when (buffer-live-p buf) (ignore-errors (posframe-hide buf))))))

;;;; Navigation helpers operating on the open stack

(defun pulldown-menu--current-item (level)
  "Return the currently selected item of LEVEL, or nil."
  (let ((sel (pulldown-menu--level-selection level)))
    (when sel (nth sel (pulldown-menu--level-items level)))))

(defun pulldown-menu--child-of (level)
  "Return the open child level of LEVEL, or nil."
  (cl-find (1+ (pulldown-menu--level-depth level))
           pulldown-menu--stack :key #'pulldown-menu--level-depth))

(defun pulldown-menu--close-deeper-than (level)
  "Close every open level nested below LEVEL."
  (let ((d (pulldown-menu--level-depth level)))
    (while (and pulldown-menu--stack
                (> (pulldown-menu--level-depth (car pulldown-menu--stack)) d))
      (pulldown-menu--close (pop pulldown-menu--stack)))))

(defun pulldown-menu--collapse-one ()
  "Close the deepest open submenu, keeping the root open."
  (when (cdr pulldown-menu--stack)
    (pulldown-menu--close (pop pulldown-menu--stack))))

(defun pulldown-menu--move (level dir)
  "Move LEVEL's selection by DIR (+1 or -1) to the next selectable row."
  (let* ((items (pulldown-menu--level-items level))
         (n (length items))
         (i (or (pulldown-menu--level-selection level) 0)))
    (when (> n 0)
      (cl-loop repeat n
               do (setq i (mod (+ i dir) n))
               when (pulldown-menu--selectable-p (nth i items))
               return (progn
                        (setf (pulldown-menu--level-selection level) i)
                        (pulldown-menu--draw-selection level))))))

(defun pulldown-menu--type-ahead (level ch)
  "Select the next item in LEVEL whose label starts with character CH."
  (let* ((items (pulldown-menu--level-items level))
         (n (length items))
         (start (or (pulldown-menu--level-selection level) -1))
         (down (downcase ch)))
    (cl-loop for k from 1 to n
             for i = (mod (+ start k) n)
             for item = (nth i items)
             when (and (pulldown-menu--selectable-p item)
                       (let ((lbl (plist-get item :label)))
                         (and (> (length lbl) 0)
                              (eql (downcase (aref lbl 0)) down))))
             return (progn
                      (setf (pulldown-menu--level-selection level) i)
                      (pulldown-menu--draw-selection level)))))

(defun pulldown-menu--submenu-position (level)
  "Return frame-relative (X . Y) for a submenu opened from LEVEL."
  (let* ((parent (selected-frame))
         (cframe (pulldown-menu--level-frame level)))
    (pcase-let ((`(,pl ,pt ,_pr ,_pb) (frame-edges parent 'native-edges))
                (`(,_cl ,ct ,cr ,_cb) (frame-edges cframe 'native-edges)))
      (let ((sel (or (pulldown-menu--level-selection level) 0))
            (chh (frame-char-height cframe)))
        (cons (max 0 (- cr pl 3))
              (max 0 (+ (- ct pt) (* sel chh) 1)))))))

(defun pulldown-menu--open-submenu-of (level)
  "Open the submenu selected in LEVEL, if any, pushing it on the stack."
  (let ((item (pulldown-menu--current-item level)))
    (when (and item (eq (plist-get item :type) 'submenu)
               (plist-get item :enabled))
      (let ((child (pulldown-menu--child-of level)))
        (unless (and child (eql (pulldown-menu--level-parent-index child)
                                (pulldown-menu--level-selection level)))
          (pulldown-menu--close-deeper-than level)
          (let ((subitems (pulldown-menu--parse (plist-get item :keymap))))
            (when (cl-some #'pulldown-menu--selectable-p subitems)
              (pcase-let ((`(,sx . ,sy) (pulldown-menu--submenu-position level)))
                (push (pulldown-menu--open
                       subitems sx sy
                       (1+ (pulldown-menu--level-depth level))
                       (pulldown-menu--level-selection level))
                      pulldown-menu--stack)))))))))

(defun pulldown-menu--activate ()
  "Act on the current item of the deepest level."
  (let* ((level (car pulldown-menu--stack))
         (item (pulldown-menu--current-item level)))
    (when (and item (plist-get item :enabled))
      (pcase (plist-get item :type)
        ('submenu (pulldown-menu--open-submenu-of level))
        ('item (setq pulldown-menu--result (plist-get item :command)
                     pulldown-menu--done t))))))

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
  (let* ((posn (event-start event))
         (win (posn-window posn)))
    (when (windowp win)
      (let* ((buf (window-buffer win))
             (level (cl-find buf pulldown-menu--stack
                             :key #'pulldown-menu--level-buffer)))
        (when level
          (let* ((pt (posn-point posn))
                 (row (cdr (posn-col-row posn)))
                 (idx (cond
                       ((integerp pt)
                        (with-current-buffer buf (1- (line-number-at-pos pt))))
                       ((integerp row) row))))
            (when (and idx (>= idx 0)
                       (< idx (length (pulldown-menu--level-items level))))
              (cons level idx))))))))

(defun pulldown-menu--select-at (level idx)
  "Select row IDX in LEVEL and redraw its highlight."
  (setf (pulldown-menu--level-selection level) idx)
  (pulldown-menu--draw-selection level))

(defun pulldown-menu--hover (event)
  "Handle a mouse-movement EVENT: highlight and open submenus on hover."
  (let ((hit (pulldown-menu--event->hit event)))
    (when hit
      (pcase-let ((`(,level . ,idx) hit))
        (let ((item (nth idx (pulldown-menu--level-items level))))
          (when (pulldown-menu--selectable-p item)
            (unless (and (eql (pulldown-menu--level-selection level) idx)
                         (let ((child (pulldown-menu--child-of level)))
                           (if (eq (plist-get item :type) 'submenu)
                               (and child (eql (pulldown-menu--level-parent-index child)
                                               idx))
                             (null child))))
              (pulldown-menu--close-deeper-than level)
              (pulldown-menu--select-at level idx)
              (when (eq (plist-get item :type) 'submenu)
                (pulldown-menu--open-submenu-of level)))))))))

(defun pulldown-menu--click (event)
  "Handle a mouse click EVENT: activate the row under it."
  (let ((hit (pulldown-menu--event->hit event)))
    (when hit
      (pcase-let ((`(,level . ,idx) hit))
        (let ((item (nth idx (pulldown-menu--level-items level))))
          (when (pulldown-menu--selectable-p item)
            (pulldown-menu--close-deeper-than level)
            (pulldown-menu--select-at level idx)
            (pcase (plist-get item :type)
              ('submenu (pulldown-menu--open-submenu-of level))
              ('item (setq pulldown-menu--result (plist-get item :command)
                           pulldown-menu--done t)))))))))

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
      (`(char . ,c) (pulldown-menu--type-ahead (car pulldown-menu--stack) c))))))

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

;;;; Entry point

(defun pulldown-menu--trigger-position (trigger)
  "Return frame-relative (X . Y) pixels at which to open the menu.
TRIGGER is the mouse event that requested the menu, or nil.  Without a
mouse event, open near point; failing that, near the top-left corner."
  (let ((frame (selected-frame)))
    (pcase-let ((`(,fl ,ft ,_r ,_b) (frame-edges frame 'native-edges)))
      (cond
       ((and trigger (mouse-event-p trigger))
        (pcase-let ((`(,mx . ,my) (mouse-absolute-pixel-position)))
          (let* ((chh (frame-char-height frame))
                 (y0 (max 0 (- my ft))))
            ;; Anchor to the bottom of the row the pointer is in, so the
            ;; menu sits just under the clicked line or bar regardless of
            ;; where within that row the click landed (adding a full line
            ;; to the raw pointer overshoots by up to a line).
            (cons (max 0 (- mx fl))
                  (* (1+ (/ y0 chh)) chh)))))
       ((posn-at-point)
        (pcase-let ((`(,px . ,py) (posn-x-y (posn-at-point)))
                    (`(,wl ,wt ,_wr ,_wb) (window-inside-pixel-edges)))
          (cons (+ px wl) (+ py wt (frame-char-height frame)))))
       (t (cons 8 (frame-char-height frame)))))))

;;;###autoload
(defun pulldown-menu-popup (menu &optional trigger)
  "Display MENU as a themed, buffer-based pulldown and run the chosen item.
MENU is an Emacs menu keymap or an `easy-menu' item list.  TRIGGER, when
given, is the mouse event that requested the menu and positions it.

Falls back to `tmm-prompt' on a non-graphical frame."
  (let ((keymap (if (keymapp menu) menu (easy-menu-create-menu nil menu))))
    (if (not (and (display-graphic-p) (require 'posframe nil t)))
        (let ((cmd (tmm-prompt keymap)))
          (when (commandp cmd)
            (let ((last-nonmenu-event t)) (call-interactively cmd))))
      (let ((items (pulldown-menu--parse keymap)))
        (if (not (cl-some #'pulldown-menu--selectable-p items))
            (message "(Empty menu)")
          (pcase-let ((`(,x . ,y) (pulldown-menu--trigger-position trigger)))
            (let ((command (pulldown-menu--run items x y)))
              (when (commandp command)
                (setq this-command command)
                (let ((last-nonmenu-event t))
                  (call-interactively command))))))))))

;;;; Context-menu integration

(declare-function context-menu-map "mouse")

(defun pulldown-menu--popup-context (menu trigger)
  "Show context MENU via the pulldown, or run it if it is a command.
TRIGGER is the event that requested it, or nil."
  (if (commandp menu)
      (let ((last-nonmenu-event t)) (call-interactively menu))
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

(provide 'pulldown-menu)
;;; pulldown-menu.el ends here
