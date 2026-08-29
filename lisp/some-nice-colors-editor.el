;;; some-nice-colors-editor.el --- Live editor for some-nice-colors -*- lexical-binding: t; -*-

;;; Commentary:

;; A form editor for the palette of themes/some-nice-colors-theme.el.
;;
;; The theme keeps every colour it uses in one `let' at the top of the
;; file, one binding per line, grouped by section comments and annotated
;; with what the colour is for.  This buffer is that block, rendered:
;; groups become headings, the trailing comment becomes the note beside
;; the row, and each colour gets a swatch, an editable #rrggbb field, an
;; ink sample on the theme's own canvas, and its contrast against that
;; canvas.
;;
;; Every edit is written straight back to the theme file and the theme is
;; re-enabled, so the whole frame -- and the preview at the bottom of this
;; buffer -- follows along as you type.  Beyond typing a hex value the
;; colour under point can be nudged in place: lighter, darker, more or
;; less saturated, or around the hue wheel.  `u' walks back through the
;; edits of this session.

;;; Code:

(require 'cl-lib)
(require 'color)
(require 'seq)
(require 'subr-x)
(require 'wid-edit)

(defvar init/theme--internal-load)
(declare-function nim-mode "nim-mode")

(defgroup init/some-nice-colors-editor nil
  "Edit and preview the local some-nice-colors theme."
  :group 'faces)

(defcustom init/some-nice-colors-theme-file
  (expand-file-name "themes/some-nice-colors-theme.el" user-emacs-directory)
  "Theme file edited by `init/some-nice-colors-edit'."
  :type 'file
  :group 'init/some-nice-colors-editor)

(defcustom init/some-nice-colors-step 0.02
  "Amount one lighten, darken or saturation step moves a colour.
Measured in HSL units, where 1.0 is the full range."
  :type 'number
  :group 'init/some-nice-colors-editor)

(defcustom init/some-nice-colors-hue-step 4
  "Degrees one hue-rotation step moves a colour around the wheel."
  :type 'number
  :group 'init/some-nice-colors-editor)

(defconst init/some-nice-colors--theme 'some-nice-colors)

(defconst init/some-nice-colors--buffer-name "*Some Nice Colors*")

(defconst init/some-nice-colors--hex-pattern "\\`#[[:xdigit:]]\\{6\\}\\'"
  "Pattern matching an acceptable palette colour.")

(defconst init/some-nice-colors--binding-pattern
  "^[[:space:]]*(\\([^][()[:space:]]+\\)[[:space:]]+\"\\(#[[:xdigit:]]\\{6\\}\\)\""
  "Pattern matching one palette binding line in the theme file.")

;;;; Samples shown under the palette

(defconst init/some-nice-colors--nim-sample
  "## Syntax specimen: comments, docs, keywords, identifiers, types, strings.
import std/[options, strformat, tables]

type
  Vec2* = object
    x*, y*: float

  TokenKind = enum
    tkName, tkNumber, tkString, tkOperator

  LexerError = object of CatchableError

const
  PiApprox = 3.14159
  DefaultNames = [\"Ada\", \"Grace\", \"Edsger\"]

let punctuation = {'(', ')', '[', ']', '{', '}', ',', ';', ':'}
var counts = initTable[string, int]()

proc length*(v: Vec2): float =
  ## Return the Euclidean length of `v`.
  result = sqrt(v.x * v.x + v.y * v.y)

template withTrace(label: string; body: untyped) =
  echo \"enter: \", label   # a trailing note, panelled like every comment
  try:
    body
  finally:
    echo \"leave: \", label

iterator tokens(source: string): TokenKind =
  for ch in source:
    case ch
    of 'a'..'z', 'A'..'Z', '_': yield tkName
    of '0'..'9': yield tkNumber
    of '\"', '\\'': yield tkString
    of '+', '-', '*', '/', '=', '<', '>', '@', '$': yield tkOperator
    else: discard

func classify[T: SomeInteger](value: T): Option[string] =
  if value < 0:
    some(\"negative\")
  elif value == 0:
    none(string)
  else:
    some(&\"positive({value:#x})\")

proc main() =
  withTrace \"theme-preview\":
    for kind in tokens(\"let answer = 42\"):
      counts.mgetOrPut($kind, 0).inc
    raise newException(LexerError, \"preview warning path\")

when isMainModule:
  main()
"
  "Nim source exercising the syntax faces of the theme.")

(defconst init/some-nice-colors--elisp-sample
  ";;; specimen.el --- Comments, docs, keywords, numbers -*- lexical-binding: t; -*-

;; A block comment sits on its own panel, a little brighter than the code.
(require 'seq)

(defconst specimen-limit #xff
  \"Largest value the renderer accepts.\")

(defvar specimen-cache (make-hash-table :test #'equal)
  \"Memoised results, keyed by NAME.\")

(defun specimen-render (name pixels &optional vivid-p)
  \"Render PIXELS for NAME, keeping contrast when VIVID-P is nil.\"
  (let* ((ratio (/ 13.0 21.0))          ; a trailing note
         (label (format \"theme: %s -> ok\" name)))
    (condition-case failure
        (seq-map (lambda (pixel)
                   (when (and vivid-p (> (car pixel) ratio))
                     (message \"%s @ %03d\" label (cdr pixel))))
                 pixels)
      (wrong-type-argument
       (user-error \"Invalid pixel: %s\" (error-message-string failure))))))

;; FIXME: warnings must be impossible to overlook.
(specimen-render \"cafe/night\" '((0.618 . -42)))
"
  "Emacs Lisp source exercising the syntax faces of the theme.")

(defconst init/some-nice-colors--face-sample
  '(("Region"          region                  "selected text stays legible")
    ("Current line"    hl-line                 "the line under the point")
    ("Highlight"       highlight               "hover and transient marks")
    ("Search match"    isearch                 "the match you are on")
    ("Other matches"   lazy-highlight          "every other match")
    ("Mode line"       mode-line               " nim  main.nim  42:17 ")
    ("Mode line off"   mode-line-inactive      " other-window.nim ")
    ("Header line"     header-line             " project > src > main.nim ")
    ("Line number"     line-number             "   41 ")
    ("Current number"  line-number-current-line "   42 ")
    ("Comment panel"   font-lock-comment-face  "## a note pinned to the code")
    ("Docstring"       font-lock-doc-face      "## what this proc returns")
    ("Error"           error                   "compilation failed")
    ("Warning"         warning                 "suspicious expression")
    ("Success"         success                 "all checks passed")
    ("Link"            link                    "https://nim-lang.org/")
    ("Candidate"       vertico-current         "the highlighted completion")
    ("Diff added"      diff-added              "+ let answer = 42")
    ("Diff removed"    diff-removed            "- let answer = nil")
    ("Selection pill"  org-modern-tag          " tagged "))
  "UI faces shown in the face preview, as (LABEL FACE SAMPLE).")

(defconst init/some-nice-colors--previews '(nim elisp faces)
  "Preview styles cycled through by `init/some-nice-colors-cycle-preview'.")

;;;; One palette entry

(cl-defstruct (init/some-nice-colors-color
               (:constructor init/some-nice-colors--color)
               (:copier init/some-nice-colors--copy))
  "One editable colour of the theme palette."
  name        ; symbol naming the `let' binding
  value       ; current #rrggbb value
  note        ; the trailing comment in the theme file
  group)      ; the section comment the binding sits under

;;;; Buffer state

(defvar-local init/some-nice-colors--palette nil
  "Palette of the theme file, as a list of `init/some-nice-colors-color'.")

(defvar-local init/some-nice-colors--history nil
  "Stack of earlier palettes, most recent first.")

(defvar-local init/some-nice-colors--status-marker nil)
(defvar-local init/some-nice-colors--preview-marker nil)
(defvar-local init/some-nice-colors--rendering nil)
(defvar-local init/some-nice-colors--preview 'nim)

(defvar init/some-nice-colors-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map widget-keymap)
    (define-key map (kbd "g") #'init/some-nice-colors-revert)
    (define-key map (kbd "C-c C-s") #'init/some-nice-colors-save)
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "n") #'init/some-nice-colors-next)
    (define-key map (kbd "p") #'init/some-nice-colors-previous)
    (define-key map (kbd "c") #'init/some-nice-colors-choose)
    (define-key map (kbd "+") #'init/some-nice-colors-lighten)
    (define-key map (kbd "=") #'init/some-nice-colors-lighten)
    (define-key map (kbd "-") #'init/some-nice-colors-darken)
    (define-key map (kbd "]") #'init/some-nice-colors-saturate)
    (define-key map (kbd "[") #'init/some-nice-colors-desaturate)
    (define-key map (kbd ">") #'init/some-nice-colors-rotate-forward)
    (define-key map (kbd "<") #'init/some-nice-colors-rotate-back)
    (define-key map (kbd "u") #'init/some-nice-colors-undo)
    (define-key map (kbd "w") #'init/some-nice-colors-copy)
    (define-key map (kbd "t") #'init/some-nice-colors-cycle-preview)
    map)
  "Keymap for `init/some-nice-colors-mode'.")

(define-derived-mode init/some-nice-colors-mode special-mode "Nice Colors"
  "Major mode for editing the some-nice-colors palette."
  (setq buffer-read-only nil)
  (setq truncate-lines nil)
  (widget-minor-mode 1))

;;;; Reading the palette out of the theme file

(defun init/some-nice-colors--group-title (comment)
  "Return the group heading and subtitle carried by COMMENT."
  (let ((parts (split-string comment "[[:space:]]+--[[:space:]]+" t)))
    (cons (string-trim (or (car parts) comment))
          (string-trim (or (cadr parts) "")))))

(defun init/some-nice-colors--parse-palette ()
  "Return the palette of `init/some-nice-colors-theme-file'.
The bindings of the theme's palette `let' are read in file order, each
one carrying the section comment it sits under and its own trailing
comment."
  (with-temp-buffer
    (insert-file-contents init/some-nice-colors-theme-file)
    (goto-char (point-min))
    (unless (re-search-forward "^(let (" nil t)
      (user-error "No palette block found in %s" init/some-nice-colors-theme-file))
    (beginning-of-line)
    (let ((limit (save-excursion
                   (if (re-search-forward "^[[:space:]]*(custom-theme-set-faces" nil t)
                       (match-beginning 0)
                     (point-max))))
          (group "")
          palette)
      (while (< (point) limit)
        (let ((line (buffer-substring-no-properties
                     (line-beginning-position)
                     (min limit (line-end-position)))))
          (cond
           ((string-match init/some-nice-colors--binding-pattern line)
            (let* ((name (intern (match-string 1 line)))
                   (value (downcase (match-string 2 line)))
                   (tail (substring line (match-end 2)))
                   (note (if (string-match ";+[[:space:]]*\\(.*?\\)[[:space:]]*\\'" tail)
                             (match-string 1 tail)
                           "")))
              (push (init/some-nice-colors--color
                     :name name :value value :note note :group group)
                    palette)))
           ((string-match ";;[[:space:]]*\\(.*?\\)[[:space:]]*\\'" line)
            (setq group (match-string 1 line)))))
        (forward-line 1))
      (unless palette
        (user-error "No palette bindings found in %s"
                    init/some-nice-colors-theme-file))
      (nreverse palette))))

(defun init/some-nice-colors--find (name)
  "Return the palette entry called NAME, or nil."
  (seq-find (lambda (color)
              (eq name (init/some-nice-colors-color-name color)))
            init/some-nice-colors--palette))

;;;; Colour arithmetic

(defun init/some-nice-colors--hex (color)
  "Return COLOR normalized to #rrggbb, or nil when COLOR is invalid."
  (cond
   ((and (stringp color)
         (string-match-p init/some-nice-colors--hex-pattern color))
    (downcase color))
   ((and (stringp color) (color-defined-p color))
    (pcase-let ((`(,red ,green ,blue) (color-name-to-rgb color)))
      (color-rgb-to-hex red green blue 2)))))

(defun init/some-nice-colors--rgb (hex)
  "Return HEX as red, green and blue floats between 0 and 1.
Parsed from the string rather than looked up on the display, so the
numbers stay exact on a terminal frame with a small colour map."
  (list (/ (string-to-number (substring hex 1 3) 16) 255.0)
        (/ (string-to-number (substring hex 3 5) 16) 255.0)
        (/ (string-to-number (substring hex 5 7) 16) 255.0)))

(defun init/some-nice-colors--nudge (hex hue saturation lightness)
  "Return HEX moved by HUE degrees, SATURATION and LIGHTNESS in HSL units."
  (pcase-let* ((`(,red ,green ,blue) (init/some-nice-colors--rgb hex))
               (`(,h ,s ,l) (color-rgb-to-hsl red green blue))
               (shifted (list (mod (+ h (/ (float hue) 360.0)) 1.0)
                              (min 1.0 (max 0.0 (+ s saturation)))
                              (min 1.0 (max 0.0 (+ l lightness))))))
    (apply #'color-rgb-to-hex
           (append (apply #'color-hsl-to-rgb shifted) '(2)))))

(defun init/some-nice-colors--luminance (hex)
  "Return the relative luminance of HEX, as defined by WCAG."
  (let ((channels (mapcar (lambda (value)
                            (if (<= value 0.03928)
                                (/ value 12.92)
                              (expt (/ (+ value 0.055) 1.055) 2.4)))
                          (init/some-nice-colors--rgb hex))))
    (+ (* 0.2126 (nth 0 channels))
       (* 0.7152 (nth 1 channels))
       (* 0.0722 (nth 2 channels)))))

(defun init/some-nice-colors--contrast (one other)
  "Return the WCAG contrast ratio between colours ONE and OTHER."
  (let ((first (init/some-nice-colors--luminance one))
        (second (init/some-nice-colors--luminance other)))
    (/ (+ (max first second) 0.05)
       (+ (min first second) 0.05))))

(defun init/some-nice-colors--canvas ()
  "Return the palette's background colour, or the frame's."
  (or (when-let* ((color (init/some-nice-colors--find 'bg)))
        (init/some-nice-colors-color-value color))
      (face-attribute 'default :background nil t)))

;;;; Writing the palette back

(defun init/some-nice-colors--set-status (message &optional face)
  "Write MESSAGE to the status line using FACE."
  (when (markerp init/some-nice-colors--status-marker)
    (save-excursion
      (let ((inhibit-read-only t)
            (start init/some-nice-colors--status-marker))
        (goto-char start)
        (delete-region start (line-end-position))
        (insert (propertize message 'face (or face 'shadow)))))))

(defun init/some-nice-colors--replace-binding (name value)
  "Replace palette binding NAME with VALUE in the current buffer."
  (goto-char (point-min))
  (let ((pattern (format "(\\s-*%s\\s-+\"\\(#[[:xdigit:]]\\{6\\}\\)\""
                         (regexp-quote (symbol-name name)))))
    (unless (re-search-forward pattern nil t)
      (user-error "Could not find palette binding for %s" name))
    (replace-match value t t nil 1)))

(defun init/some-nice-colors--write-palette (palette)
  "Write PALETTE back to `init/some-nice-colors-theme-file'."
  (let ((buffer (find-file-noselect init/some-nice-colors-theme-file)))
    (with-current-buffer buffer
      (when (buffer-modified-p)
        (user-error "%s has unsaved edits; save or revert it first"
                    init/some-nice-colors-theme-file))
      (save-excursion
        (dolist (color palette)
          (init/some-nice-colors--replace-binding
           (init/some-nice-colors-color-name color)
           (init/some-nice-colors-color-value color))))
      (save-buffer))))

(defun init/some-nice-colors--reload-theme ()
  "Re-evaluate and enable the edited theme."
  (when (custom-theme-enabled-p init/some-nice-colors--theme)
    (disable-theme init/some-nice-colors--theme))
  (let ((init/theme--internal-load t))
    (load-file init/some-nice-colors-theme-file)
    (enable-theme init/some-nice-colors--theme)))

(defun init/some-nice-colors--save-and-preview ()
  "Persist the current palette and refresh the visible preview."
  (init/some-nice-colors--write-palette init/some-nice-colors--palette)
  (init/some-nice-colors--reload-theme)
  (init/some-nice-colors--refresh-preview)
  (init/some-nice-colors--set-status
   (format "Saved %s" (format-time-string "%H:%M:%S"))
   'success))

(defun init/some-nice-colors--remember ()
  "Push the current palette onto the undo stack."
  (push (mapcar #'init/some-nice-colors--copy init/some-nice-colors--palette)
        init/some-nice-colors--history))

(defun init/some-nice-colors--update-color (name color &optional remember)
  "Set palette NAME to COLOR, then save and preview when it is valid.
REMEMBER non-nil records the previous palette, so
`init/some-nice-colors-undo' can put it back."
  (if-let* ((hex (init/some-nice-colors--hex color))
           (entry (init/some-nice-colors--find name)))
      (unless (equal hex (init/some-nice-colors-color-value entry))
        (when remember (init/some-nice-colors--remember))
        (setf (init/some-nice-colors-color-value entry) hex)
        (condition-case failure
            (init/some-nice-colors--save-and-preview)
          (error
           (init/some-nice-colors--set-status
            (error-message-string failure) 'error))))
    (init/some-nice-colors--set-status
     (format "%s is not a valid color" color)
     'warning)))

(defun init/some-nice-colors--field-changed (name widget)
  "Handle a colour text WIDGET change for NAME."
  (unless init/some-nice-colors--rendering
    (let ((value (string-trim (widget-value widget))))
      (when (string-match-p init/some-nice-colors--hex-pattern value)
        (init/some-nice-colors--update-color name value t)))))

;;;; Rendering

(defun init/some-nice-colors--fontified-sample (sample mode)
  "Return SAMPLE with the font-lock faces MODE gives it."
  (with-temp-buffer
    (insert sample)
    (delay-mode-hooks
      (cond
       ((fboundp mode) (funcall mode))
       (t (prog-mode))))
    (font-lock-ensure)
    (buffer-string)))

(defun init/some-nice-colors--insert-face-sample ()
  "Insert one line per face of `init/some-nice-colors--face-sample'."
  (pcase-dolist (`(,label ,face ,sample) init/some-nice-colors--face-sample)
    (insert (propertize (format "%-16s" label) 'face 'shadow))
    (insert (propertize (format " %s " sample) 'face face))
    (insert "\n")))

(defun init/some-nice-colors--preview-label ()
  "Return the heading of the current preview style."
  (pcase init/some-nice-colors--preview
    ('nim "Nim") ('elisp "Emacs Lisp") (_ "UI faces")))

(defun init/some-nice-colors--refresh-preview ()
  "Redraw the preview section under the palette."
  (when (markerp init/some-nice-colors--preview-marker)
    (save-excursion
      (let ((inhibit-read-only t)
            (start init/some-nice-colors--preview-marker))
        (goto-char start)
        (delete-region start (point-max))
        (insert (propertize (format "%s preview" (init/some-nice-colors--preview-label))
                            'face '(:height 1.2 :weight bold)))
        (insert (propertize "   t cycles\n" 'face 'shadow))
        (insert (propertize (make-string 60 ?-) 'face 'shadow) "\n\n")
        (pcase init/some-nice-colors--preview
          ('nim (insert (init/some-nice-colors--fontified-sample
                         init/some-nice-colors--nim-sample 'nim-mode)))
          ('elisp (insert (init/some-nice-colors--fontified-sample
                           init/some-nice-colors--elisp-sample 'emacs-lisp-mode)))
          (_ (init/some-nice-colors--insert-face-sample)))))))

(defun init/some-nice-colors--contrast-face (ratio)
  "Return the face announcing a contrast RATIO."
  (cond ((>= ratio 7.0) 'success)
        ((>= ratio 4.5) 'default)
        (t 'shadow)))

(defun init/some-nice-colors--insert-group (title subtitle)
  "Insert the heading for a palette group called TITLE, described by SUBTITLE."
  (widget-insert "\n")
  (widget-insert (propertize (format "  %s" title)
                             'face '(:height 1.1 :weight bold)))
  (unless (string-empty-p subtitle)
    (widget-insert (propertize (format "  %s" subtitle) 'face 'shadow)))
  (widget-insert "\n"))

(defun init/some-nice-colors--insert-color-row (color width canvas)
  "Insert the editable row for COLOR, its name padded to WIDTH.
CANVAS is the palette background the ink sample is drawn on."
  (let* ((name (init/some-nice-colors-color-name color))
         (value (init/some-nice-colors-color-value color))
         (note (init/some-nice-colors-color-note color))
         (ratio (init/some-nice-colors--contrast value canvas)))
    (widget-insert (propertize (format (format "  %%-%ds " width) name)
                               'init/some-nice-colors-name name))
    (widget-create
     'push-button
     :tag "        "
     :format "%[%t%] "
     :button-face `(:background ,value :foreground ,value
                    :box (:line-width -1 :color ,canvas))
     :help-echo "Choose this color"
     :notify (lambda (&rest _ignore)
               (init/some-nice-colors--choose-color name)))
    (widget-create
     'editable-field
     :size 9
     :format "%v"
     :value value
     :help-echo "Edit a #rrggbb color"
     :notify (lambda (widget &rest _ignore)
               (init/some-nice-colors--field-changed name widget)))
    (widget-insert (propertize " Aa 123 " 'face `(:foreground ,value :background ,canvas)))
    (widget-insert (propertize (format " %5.1f:1" ratio)
                               'face (init/some-nice-colors--contrast-face ratio)))
    (unless (string-empty-p note)
      (widget-insert (propertize (format "  %s" note) 'face 'shadow)))
    (widget-insert "\n")))

(defun init/some-nice-colors--insert-header ()
  "Insert the title, buttons and status line of the editor."
  (widget-insert (propertize "Some Nice Colors\n" 'face '(:height 1.35 :weight bold)))
  (widget-insert (propertize
                  (format "%d colours in %s\n\n"
                          (length init/some-nice-colors--palette)
                          (abbreviate-file-name init/some-nice-colors-theme-file))
                  'face 'shadow))
  (widget-create
   'push-button
   :tag "Revert"
   :help-echo "Reload the palette from disk"
   :notify (lambda (&rest _ignore) (init/some-nice-colors-revert)))
  (widget-insert " ")
  (widget-create
   'push-button
   :tag "Save"
   :help-echo "Write the current palette and reload the theme"
   :notify (lambda (&rest _ignore) (init/some-nice-colors-save)))
  (widget-insert " ")
  (widget-create
   'push-button
   :tag "Preview"
   :help-echo "Cycle the preview under the palette"
   :notify (lambda (&rest _ignore) (init/some-nice-colors-cycle-preview)))
  (widget-insert " ")
  (setq init/some-nice-colors--status-marker (point-marker))
  (widget-insert (propertize "Edits save as soon as a colour is complete."
                             'face 'shadow))
  (widget-insert "\n"))

(defun init/some-nice-colors--insert-legend ()
  "Insert the reminder of what the keys do."
  (widget-insert "\n")
  (dolist (line '("  n/p move    c pick    +/- lighter, darker    ]/[ more, less colour"
                  "  </> rotate hue    u undo    w copy hex    g revert    q quit"))
    (widget-insert (propertize line 'face 'shadow))
    (widget-insert "\n")))

(defun init/some-nice-colors--erase ()
  "Empty the buffer, dropping the widgets that were in it.
`erase-buffer' alone runs the widget change hook over fields that are
being deleted, which `wid-edit' reports as overlapping fields."
  (let ((inhibit-read-only t)
        (inhibit-modification-hooks t))
    (erase-buffer)
    (remove-overlays))
  (setq widget-field-new nil
        widget-field-list nil))

(defun init/some-nice-colors--render ()
  "Render the editor buffer from `init/some-nice-colors--palette'."
  (let* ((inhibit-read-only t)
         (init/some-nice-colors--rendering t)
         (previous (init/some-nice-colors--name-at-point))
         (canvas (init/some-nice-colors--canvas))
         (width (apply #'max 4 (mapcar (lambda (color)
                                         (length (symbol-name
                                                  (init/some-nice-colors-color-name color))))
                                       init/some-nice-colors--palette)))
         (group nil))
    (init/some-nice-colors--erase)
    (init/some-nice-colors--insert-header)
    (dolist (color init/some-nice-colors--palette)
      (let ((entry-group (init/some-nice-colors-color-group color)))
        (unless (equal group entry-group)
          (setq group entry-group)
          (pcase-let ((`(,title . ,subtitle)
                       (init/some-nice-colors--group-title entry-group)))
            (init/some-nice-colors--insert-group title subtitle))))
      (init/some-nice-colors--insert-color-row color width canvas))
    (init/some-nice-colors--insert-legend)
    (widget-insert "\n")
    (setq init/some-nice-colors--preview-marker (point-marker))
    (init/some-nice-colors--refresh-preview)
    (goto-char (point-min))
    (when previous (init/some-nice-colors--goto-row previous))
    (widget-setup)))

;;;; Moving between rows

(defun init/some-nice-colors--name-at-point ()
  "Return the palette name of the row point is on, or nil."
  (get-text-property (line-beginning-position) 'init/some-nice-colors-name))

(defun init/some-nice-colors--row-positions ()
  "Return the buffer positions where palette rows start."
  (let ((position (point-min))
        positions)
    (while position
      (when (get-text-property position 'init/some-nice-colors-name)
        (push position positions))
      (setq position (next-single-property-change
                      position 'init/some-nice-colors-name)))
    (nreverse positions)))

(defun init/some-nice-colors--goto-row (name)
  "Move point to the row of NAME when the buffer has one."
  (when-let* ((position (seq-find
                        (lambda (start)
                          (eq name (get-text-property
                                    start 'init/some-nice-colors-name)))
                        (init/some-nice-colors--row-positions))))
    (goto-char position)))

(defun init/some-nice-colors--color-at-point ()
  "Return the palette entry point is on, or signal a `user-error'."
  (or (when-let* ((name (init/some-nice-colors--name-at-point)))
        (init/some-nice-colors--find name))
      (user-error "Point is not on a colour row")))

(defun init/some-nice-colors--nudge-at-point (hue saturation lightness)
  "Nudge the colour under point by HUE, SATURATION and LIGHTNESS."
  (let* ((color (init/some-nice-colors--color-at-point))
         (name (init/some-nice-colors-color-name color))
         (nudged (init/some-nice-colors--nudge
                  (init/some-nice-colors-color-value color)
                  hue saturation lightness)))
    (init/some-nice-colors--update-color name nudged t)
    (init/some-nice-colors--render)
    (init/some-nice-colors--set-status
     (format "%s is now %s" name nudged) 'success)))

;;;; Commands

(defun init/some-nice-colors-next ()
  "Move point to the next colour row."
  (interactive)
  (when-let* ((position (seq-find (lambda (start) (> start (point)))
                                 (init/some-nice-colors--row-positions))))
    (goto-char position)))

(defun init/some-nice-colors-previous ()
  "Move point to the previous colour row."
  (interactive)
  (when-let* ((position (seq-find (lambda (start) (< start (line-beginning-position)))
                                 (reverse (init/some-nice-colors--row-positions)))))
    (goto-char position)))

(defun init/some-nice-colors--choose-color (name)
  "Prompt for a new colour for palette NAME."
  (let* ((color (init/some-nice-colors--find name))
         (current (and color (init/some-nice-colors-color-value color)))
         (choice (read-color (format "%s (%s): " name current) t)))
    (init/some-nice-colors--update-color name choice t)
    (init/some-nice-colors--render)))

(defun init/some-nice-colors-choose ()
  "Pick a new colour for the row under point."
  (interactive)
  (init/some-nice-colors--choose-color
   (init/some-nice-colors-color-name (init/some-nice-colors--color-at-point))))

(defun init/some-nice-colors-lighten ()
  "Lighten the colour under point."
  (interactive)
  (init/some-nice-colors--nudge-at-point 0 0 init/some-nice-colors-step))

(defun init/some-nice-colors-darken ()
  "Darken the colour under point."
  (interactive)
  (init/some-nice-colors--nudge-at-point 0 0 (- init/some-nice-colors-step)))

(defun init/some-nice-colors-saturate ()
  "Give the colour under point more colour."
  (interactive)
  (init/some-nice-colors--nudge-at-point 0 init/some-nice-colors-step 0))

(defun init/some-nice-colors-desaturate ()
  "Take colour out of the colour under point."
  (interactive)
  (init/some-nice-colors--nudge-at-point 0 (- init/some-nice-colors-step) 0))

(defun init/some-nice-colors-rotate-forward ()
  "Rotate the colour under point forward around the hue wheel."
  (interactive)
  (init/some-nice-colors--nudge-at-point init/some-nice-colors-hue-step 0 0))

(defun init/some-nice-colors-rotate-back ()
  "Rotate the colour under point back around the hue wheel."
  (interactive)
  (init/some-nice-colors--nudge-at-point (- init/some-nice-colors-hue-step) 0 0))

(defun init/some-nice-colors-copy ()
  "Copy the hex value of the colour under point to the kill ring."
  (interactive)
  (let ((value (init/some-nice-colors-color-value
                (init/some-nice-colors--color-at-point))))
    (kill-new value)
    (init/some-nice-colors--set-status (format "Copied %s" value) 'success)))

(defun init/some-nice-colors-undo ()
  "Restore the palette as it was before the last edit."
  (interactive)
  (unless init/some-nice-colors--history
    (user-error "No palette edits to undo"))
  (setq init/some-nice-colors--palette (pop init/some-nice-colors--history))
  (init/some-nice-colors--save-and-preview)
  (init/some-nice-colors--render)
  (init/some-nice-colors--set-status "Undid the last edit" 'success))

(defun init/some-nice-colors-cycle-preview ()
  "Show the next preview style under the palette."
  (interactive)
  (let ((rest (cdr (memq init/some-nice-colors--preview
                         init/some-nice-colors--previews))))
    (setq init/some-nice-colors--preview
          (or (car rest) (car init/some-nice-colors--previews))))
  (init/some-nice-colors--refresh-preview))

(defun init/some-nice-colors-revert ()
  "Reload the editable palette from disk."
  (interactive)
  (setq init/some-nice-colors--palette (init/some-nice-colors--parse-palette))
  (setq init/some-nice-colors--history nil)
  (init/some-nice-colors--render)
  (init/some-nice-colors--set-status "Reloaded from disk" 'success))

(defun init/some-nice-colors-save ()
  "Write the current palette, reload the theme, and refresh the preview."
  (interactive)
  (init/some-nice-colors--save-and-preview))

;;;###autoload
(defun init/some-nice-colors-edit ()
  "Open a live form editor for `some-nice-colors-theme.el'."
  (interactive)
  (let ((buffer (get-buffer-create init/some-nice-colors--buffer-name)))
    (with-current-buffer buffer
      (init/some-nice-colors-mode)
      (init/some-nice-colors-revert))
    (pop-to-buffer buffer)))

(provide 'some-nice-colors-editor)
;;; some-nice-colors-editor.el ends here
