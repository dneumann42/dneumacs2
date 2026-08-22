;;; some-nice-colors-editor.el --- Live editor for some-nice-colors -*- lexical-binding: t; -*-

(require 'color)
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

(defconst init/some-nice-colors--theme 'some-nice-colors)

(defconst init/some-nice-colors--buffer-name "*Some Nice Colors*")

(defconst init/some-nice-colors--sample
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
  echo \"enter: \", label
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
")

(defvar-local init/some-nice-colors--palette nil)
(defvar-local init/some-nice-colors--status-marker nil)
(defvar-local init/some-nice-colors--preview-marker nil)
(defvar-local init/some-nice-colors--rendering nil)

(defvar init/some-nice-colors-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map widget-keymap)
    (define-key map (kbd "g") #'init/some-nice-colors-revert)
    (define-key map (kbd "C-c C-s") #'init/some-nice-colors-save)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `init/some-nice-colors-mode'.")

(define-derived-mode init/some-nice-colors-mode special-mode "Nice Colors"
  "Major mode for editing the some-nice-colors palette."
  (setq buffer-read-only nil)
  (setq truncate-lines nil)
  (widget-minor-mode 1))

(defun init/some-nice-colors--read-forms (file)
  "Read every top-level form in FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (let (forms form)
      (goto-char (point-min))
      (condition-case nil
          (while t
            (setq form (read (current-buffer)))
            (push form forms))
        (end-of-file (nreverse forms))))))

(defun init/some-nice-colors--read-palette ()
  "Return the palette bindings from `init/some-nice-colors-theme-file'."
  (let ((forms (init/some-nice-colors--read-forms init/some-nice-colors-theme-file))
        palette)
    (dolist (form forms)
      (when (and (eq (car-safe form) 'let)
                 (listp (cadr form)))
        (dolist (binding (cadr form))
          (when-let* ((name (car-safe binding))
                      (value (cadr binding)))
            (when (and (symbolp name)
                       (stringp value)
                       (string-match-p "\\`#[[:xdigit:]]\\{6\\}\\'" value))
              (push (cons name (downcase value)) palette))))))
    (unless palette
      (user-error "No palette bindings found in %s" init/some-nice-colors-theme-file))
    (nreverse palette)))

(defun init/some-nice-colors--hex (color)
  "Return COLOR normalized to #rrggbb, or nil when COLOR is invalid."
  (cond
   ((and (stringp color)
         (string-match-p "\\`#[[:xdigit:]]\\{6\\}\\'" color))
    (downcase color))
   ((and (stringp color) (color-defined-p color))
    (pcase-let ((`(,red ,green ,blue) (color-name-to-rgb color)))
      (color-rgb-to-hex red green blue 2)))))

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
        (dolist (entry palette)
          (init/some-nice-colors--replace-binding (car entry) (cdr entry))))
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

(defun init/some-nice-colors--update-color (name color)
  "Set palette NAME to COLOR, then save and preview when valid."
  (if-let ((hex (init/some-nice-colors--hex color)))
      (progn
        (setf (alist-get name init/some-nice-colors--palette) hex)
        (condition-case error-data
            (init/some-nice-colors--save-and-preview)
          (error
           (init/some-nice-colors--set-status (error-message-string error-data) 'error))))
    (init/some-nice-colors--set-status
     (format "%s is not a valid color" color)
     'warning)))

(defun init/some-nice-colors--field-changed (name widget)
  "Handle a color text WIDGET change for NAME."
  (unless init/some-nice-colors--rendering
    (let ((value (string-trim (widget-value widget))))
      (when (string-match-p "\\`#[[:xdigit:]]\\{6\\}\\'" value)
        (init/some-nice-colors--update-color name value)))))

(defun init/some-nice-colors--choose-color (name)
  "Prompt for a new color for palette NAME."
  (let* ((current (alist-get name init/some-nice-colors--palette))
         (choice (read-color (format "%s: " name) t current)))
    (init/some-nice-colors--update-color name choice)
    (init/some-nice-colors--render)))

(defun init/some-nice-colors--fontified-nim-sample ()
  "Return the Nim sample with font-lock face properties."
  (with-temp-buffer
    (insert init/some-nice-colors--sample)
    (delay-mode-hooks
      (cond
       ((fboundp 'nim-mode) (nim-mode))
       ((require 'nim-mode nil t) (nim-mode))
       (t (prog-mode))))
    (font-lock-ensure)
    (buffer-string)))

(defun init/some-nice-colors--refresh-preview ()
  "Redraw the Nim preview section."
  (when (markerp init/some-nice-colors--preview-marker)
    (save-excursion
      (let ((inhibit-read-only t)
            (start init/some-nice-colors--preview-marker))
        (goto-char start)
        (delete-region start (point-max))
        (insert (propertize "Nim Preview\n" 'face '(:height 1.2 :weight bold)))
        (insert (propertize "-----------\n\n" 'face 'shadow))
        (insert (init/some-nice-colors--fontified-nim-sample))))))

(defun init/some-nice-colors--insert-color-row (name value)
  "Insert one editable palette row for NAME with current VALUE."
  (let ((name name))
    (widget-insert (format "%-10s " name))
    (widget-create
     'push-button
     :tag "      "
     :format "%[%t%] "
     :button-face `(:background ,value :foreground ,value)
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
    (widget-insert "\n")))

(defun init/some-nice-colors--render ()
  "Render the editor buffer from `init/some-nice-colors--palette'."
  (let ((inhibit-read-only t)
        (init/some-nice-colors--rendering t))
    (erase-buffer)
    (remove-overlays)
    (widget-insert (propertize "Some Nice Colors\n" 'face '(:height 1.35 :weight bold)))
    (widget-insert (propertize "Theme palette editor\n\n" 'face 'shadow))
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
    (setq init/some-nice-colors--status-marker (point-marker))
    (widget-insert (propertize "Edits save automatically when a complete color is valid." 'face 'shadow))
    (widget-insert "\n\n")
    (dolist (entry init/some-nice-colors--palette)
      (init/some-nice-colors--insert-color-row (car entry) (cdr entry)))
    (widget-insert "\n")
    (setq init/some-nice-colors--preview-marker (point-marker))
    (init/some-nice-colors--refresh-preview)
    (goto-char (point-min))
    (widget-setup)))

(defun init/some-nice-colors-revert ()
  "Reload the editable palette from disk."
  (interactive)
  (setq init/some-nice-colors--palette (init/some-nice-colors--read-palette))
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
