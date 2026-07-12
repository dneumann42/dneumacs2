;;; nest-mode.el --- Major mode for Nest DSL files -*- lexical-binding: t; -*-

(defgroup nest nil
  "Editing support for Nest DSL files."
  :group 'languages)

(defcustom nest-indent-offset 2
  "Indentation step for `nest-mode'."
  :type 'integer
  :safe #'integerp
  :group 'nest)

(defconst nest-mode-keywords
  '("define" "events" "when" "command" "import" "export"))

(defconst nest-mode-builtins
  '("id" "LineInputState" "EditLineState"
    "fill" "fit" "fixed" "hug" "prefer"
    "clicked" "submitted" "not" "scope"
    "env" "split" "loadLines" "writeLines"
    "appendLine" "insertLine" "setLine" "deleteLine"
    "setText" "browseFolder" "exec" "execStatus"
    "forLines" "editing" "beginEdit" "cancelEdit" "saveEdit"
    "editInputID" "editInput" "print"))

(defconst nest-mode-widgets
  '("row" "column" "panel" "label" "button" "lineInput" "pathListBox"))

(defconst nest-mode-constants
  '("true" "false"
    "AlignAuto" "AlignStart" "AlignCenter" "AlignEnd" "AlignStretch"
    "JustifyStart" "JustifyCenter" "JustifyEnd"))

(defvar nest-mode-syntax-table
  (let ((table (make-syntax-table)))
    (modify-syntax-entry ?\; "<" table)
    (modify-syntax-entry ?\n ">" table)
    (modify-syntax-entry ?_ "w" table)
    (modify-syntax-entry ?- "w" table)
    table)
  "Syntax table for `nest-mode'.")

(defconst nest-font-lock-keywords
  `((,(concat "^[[:blank:]]*" (regexp-opt nest-mode-keywords 'symbols))
     . font-lock-keyword-face)
    ("^[[:blank:]]*command[[:blank:]]+\\([[:word:]_-]+\\)"
     1 font-lock-function-name-face)
    (,(regexp-opt nest-mode-builtins 'symbols) . font-lock-builtin-face)
    (,(regexp-opt nest-mode-widgets 'symbols) . font-lock-function-name-face)
    (,(regexp-opt nest-mode-constants 'symbols) . font-lock-constant-face)
    ("\\_<-?[0-9]+\\(?:\\.[0-9]+\\)?\\_>" . font-lock-constant-face)))

(defvar nest-mode-imenu-generic-expression
  '(("Commands" "^[[:blank:]]*command[[:blank:]]+\\([[:word:]_-]+\\)" 1)))

(defun nest--line-blank-or-comment-p ()
  "Return non-nil when the current line is blank or a comment."
  (save-excursion
    (back-to-indentation)
    (or (eolp) (looking-at-p ";"))))

(defun nest--previous-code-line ()
  "Move to the previous nonblank, noncomment line.
Return non-nil when such a line exists."
  (let ((found nil))
    (while (and (not found) (> (line-number-at-pos) 1))
      (forward-line -1)
      (unless (nest--line-blank-or-comment-p)
        (setq found t)))
    found))

(defun nest--previous-indent ()
  "Indentation of the previous code line, or 0."
  (save-excursion
    (if (nest--previous-code-line)
        (current-indentation)
      0)))

(defun nest--previous-opens-block-p ()
  "Return non-nil when the previous code line ends with a block colon."
  (save-excursion
    (and (nest--previous-code-line)
         (end-of-line)
         (skip-chars-backward " \t")
         (eq (char-before) ?:))))

(defun nest-calculate-indentation ()
  "Return desired indentation for the current line."
  (save-excursion
    (back-to-indentation)
    (let ((base (nest--previous-indent)))
      (if (nest--previous-opens-block-p)
          (+ base nest-indent-offset)
        base))))

(defun nest-indent-line ()
  "Indent current line as Nest DSL."
  (interactive)
  (let ((indent (nest-calculate-indentation))
        (offset (- (current-column) (current-indentation))))
    (indent-line-to indent)
    (when (> offset 0)
      (move-to-column (+ indent offset)))))

(defun nest-beginning-of-block ()
  "Move to the nearest previous line that opens a block."
  (interactive)
  (let ((origin (point))
        (found nil))
    (while (and (not found) (nest--previous-code-line))
      (save-excursion
        (end-of-line)
        (skip-chars-backward " \t")
        (setq found (eq (char-before) ?:))))
    (unless found
      (goto-char origin))))

;;;###autoload
(define-derived-mode nest-mode prog-mode "Nest"
  "Major mode for editing Nest DSL files."
  :syntax-table nest-mode-syntax-table
  (setq-local comment-start ";")
  (setq-local comment-start-skip ";+\\s-*")
  (setq-local indent-line-function #'nest-indent-line)
  (setq-local font-lock-defaults '(nest-font-lock-keywords))
  (setq-local imenu-generic-expression nest-mode-imenu-generic-expression)
  (setq-local electric-indent-chars (append '(?: ?\n) electric-indent-chars)))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.nest\\'" . nest-mode))

(provide 'nest-mode)
;;; nest-mode.el ends here
