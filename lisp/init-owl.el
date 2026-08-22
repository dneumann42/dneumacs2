;;; init-owl.el --- Major mode for Owl source files -*- lexical-binding: t; -*-

;;; Commentary:

;; Owl is indentation-structured.  A colon opens a layout block, increased
;; indentation groups continuation arguments, and parentheses can group forms
;; inline.  The command set comes from the Owl runtime plus Nest's Owl GUI DSL.

;;; Code:

(require 'subr-x)

(defgroup owl nil
  "Editing support for Owl source files."
  :group 'languages)

(defcustom owl-indent-offset 2
  "Indentation step for `owl-mode'."
  :type 'integer
  :safe #'integerp
  :group 'owl)

(defcustom owl-core-command-names
  '("command" "component" "block-command" "fun" "fn" "lambda"
    "define" "command-define" "define-caller-value"
    "import" "use" "include" "only" "exclude" "except"
    "symbol-text" "concat" "to-string" "record-constructor" "record-predicate"
    "set" "eval" "parse" "value-of" "call" "print" "error"
    "open-file" "open-string" "with"
    "+" "-" "*" "/" "+=" "-=" "*=" "/=" "=" "<" "<=" ">" ">="
    "when" "while" "pick"
    "list" "dict" "cons" "first" "rest" "empty?" "length"
    "not" "and" "or" "dict-put" "dict-get" "field" "index"
    "statements" "body-of" "command-arg" "command-symbol" "command-body"
    "binding-symbol" "binding-value" "eval-with"
    "floor" "command-line-arguments" "exit")
  "Native Owl commands known to the runtime."
  :type '(repeat string)
  :group 'owl)

(defcustom owl-prelude-command-names
  '("if" "else" "[]" "{}" "do" "record" "cond" "append" "pop-front"
    "list-from" "dict-from" "record-fields" "record-defaults" "field-value"
    "unsupported-stream-operation" "Stream" "cond-from" "nth" "append-value"
    "drop-front" "close" "read-line" "read" "read-all" "write-line" "write"
    "assert" "range" "countdown" "iter" "once" "for-each" "for")
  "Commands defined by Owl's prelude."
  :type '(repeat string)
  :group 'owl)

(defcustom owl-nest-command-names
  '("id" "clicked" "middleClicked" "focused" "submitted" "keyPressed"
    "external" "state" "send" "received" "receive"
    "perfOverlay" "togglePerfOverlay" "setPerfOverlay"
    "fill" "fit" "fixed" "hug" "prefer" "insets"
    "clock" "today-date" "redrawAfter"
    "pickFile" "pickDirectory" "pickFileEvent" "pickDirectoryEvent"
    "pickResult" "clearPickResult"
    "shell" "shellQuote" "copyText" "clipboardText"
    "windowWidth" "windowHeight" "shellAsync" "shellLaunch" "tsvCell"
    "swayWorkspaces" "swayWorkspaceSubscription"
    "swayActiveWindowSubscription" "swayWorkspaceCommand"
    "string" "textLines" "listAppend" "textFind" "textSlice"
    "lineCount" "lineTextAt" "pathBaseName" "formatNow"
    "editorText" "editorCursor" "setEditorCursor" "setEditorText"
    "clearEditor" "insertEditorText" "editorLine" "editorColumn"
    "setEditorLineColumn" "setEditorSelection" "selectEditorAll"
    "copyEditorSelection" "cutEditorSelection" "pasteEditorClipboard"
    "deleteEditorSelection" "undoEditor" "redoEditor"
    "date" "date-year" "date-month" "date-day" "date-days-in-month"
    "date-first-weekday" "date-month-name" "date-month-title"
    "date-add-months"
    "color" "theme-color" "mix-color"
    "openDialog" "toggleDialog" "dialogOpen?" "closeManagedDialog"
    "dialogResult" "clearDialogResult" "dialogData" "closeDialog"
    "events" "scope" "menuBar" "menu" "menuItem" "menuDivider"
    "menuResult" "clearMenuResult"
    "panel" "card" "dialogHeader" "table" "tableHeader" "tableRow"
    "tableCell" "row" "column" "overlay" "spacer" "label" "button"
    "checkbox" "lineInput" "modalDialog" "tabs" "editor" "image"
    "imageButton" "horizontalSlider" "verticalSlider")
  "Nest GUI commands available in Owl application files."
  :type '(repeat string)
  :group 'owl)

(defconst owl-constant-names
  '("true" "false" "T" "F" "nothing" "stdin" "stdout"
    "AlignAuto" "AlignStart" "AlignCenter" "AlignEnd" "AlignStretch"
    "JustifyStart" "JustifyCenter" "JustifyEnd")
  "Literal and conventional constant symbols in Owl source.")

(defconst owl-definition-command-names
  '("fun" "fn" "lambda" "command" "component" "block-command" "record")
  "Commands whose first argument introduces a callable or type name.")

(defconst owl-block-command-names
  '("define" "command-define" "set" "if" "else" "when" "while" "with"
    "cond" "for" "events" "scope" "menuBar" "menu" "panel" "card"
    "dialogHeader" "table" "tableHeader" "tableRow" "tableCell"
    "row" "column" "overlay" "modalDialog" "tabs")
  "Commands commonly used with colon blocks.")

(defconst owl-configuration-key-names
  '("main" "title" "width" "height" "layerShell" "layer" "namespace"
    "theme" "exclusiveZone" "marginTop" "marginRight" "marginBottom"
    "marginLeft" "gap" "padding" "paddingLeft" "paddingTop"
    "paddingRight" "paddingBottom" "alignItems" "justifyContent"
    "alignSelf" "scrollX" "scrollY" "textScroll" "lineNumbers"
    "scrollbars" "fontName" "fontSize" "buttonPadding" "syntax"
    "syntaxHighlighter" "background" "backgroundColor" "foreground"
    "foregroundColor" "border" "borderColor" "opacity")
  "Common binding names used by Owl project files and Nest UI configs.")

(defconst owl-symbol-regexp
  "\\(?:[^[:space:]\"()[\\].,:=;]+\\|[-+*/<>=!?]+\\|\\[\\]\\|{}\\)"
  "Regexp matching an Owl atom or structural punctuation command.")

(defconst owl-identifier-regexp
  "[^[:space:]\"()[\\].,:=;]+"
  "Regexp matching a regular Owl atom.")

(defconst owl-number-regexp
  "\\_<-?[0-9]+\\(?:\\.[0-9]+\\)?\\_>"
  "Regexp matching Owl numbers.")

(defconst owl-string-interpolation-regexp
  "\\\\([^)\n]*)"
  "Regexp matching simple Owl string interpolation syntax.")

(defconst owl-selector-regexp
  "\\.\\([A-Za-z_][A-Za-z0-9_-]*\\)"
  "Regexp matching an Owl field selector.")

(defconst owl-delimiter-regexp
  (regexp-opt '("(" ")" "[" "]" "{" "}" ":" "," "."))
  "Regexp matching Owl delimiters.")

(defface owl-function-name-face
  '((((class color) (background dark))
     (:foreground "#8be9a8" :weight bold))
    (((class color) (background light))
     (:foreground "#087830" :weight bold))
    (t (:inherit font-lock-function-name-face :weight bold)))
  "Face for names introduced by Owl definition commands."
  :group 'owl)

(defface owl-delimiter-face
  '((t (:inherit font-lock-builtin-face :weight bold)))
  "Face for delimiters in Owl forms."
  :group 'owl)

(defface owl-selector-face
  '((t (:inherit font-lock-property-use-face)))
  "Face for Owl field selectors."
  :group 'owl)

(defface owl-binding-face
  '((t (:inherit font-lock-variable-name-face)))
  "Face for binding names in Owl assignment forms."
  :group 'owl)

(defun owl--all-command-names ()
  "Return all known Owl command names."
  (delete-dups
   (append owl-core-command-names owl-prelude-command-names owl-nest-command-names)))

(defun owl--regexp-opt-symbols (symbols)
  "Return a symbol regexp for SYMBOLS."
  (regexp-opt symbols 'symbols))

(defun owl--token-in-code-p (position)
  "Return non-nil when POSITION lies outside any Owl string or comment."
  (let ((state (save-excursion (save-match-data (syntax-ppss position)))))
    (not (or (nth 3 state) (nth 4 state)))))

(defun owl--match-command-head (limit)
  "Search for a known command at the start of an Owl form before LIMIT."
  (let ((regexp (concat "\\(" (regexp-opt (owl--all-command-names)) "\\)"))
        (case-fold-search nil))
    (catch 'found
      (while (re-search-forward regexp limit t)
        (let ((start (match-beginning 1)))
          (when (and (owl--token-in-code-p start)
                     (save-excursion
                       (goto-char start)
                       (skip-chars-backward " \t")
                       (or (bolp)
                           (eq (char-before) 40)
                           (eq (char-before) 10)))
                     (save-excursion
                       (goto-char (match-end 1))
                       (or (eobp)
                           (looking-at-p "[[:space:]()\\[\\]{}:;,.]"))))
            (throw 'found t))))
      nil)))

(defun owl--line-opens-block-p ()
  "Return non-nil when the current line opens an Owl colon block."
  (save-excursion
    (end-of-line)
    (skip-chars-backward " \t")
    (and (eq (char-before) ?:)
         (owl--token-in-code-p (1- (point))))))

(defun owl--blank-or-comment-line-p ()
  "Return non-nil when the current Owl line is blank or a comment."
  (save-excursion
    (back-to-indentation)
    (or (eolp) (looking-at-p ";"))))

(defun owl--goto-previous-code-line ()
  "Move to the previous non-blank, non-comment line.
Return non-nil when such a line exists."
  (let (found)
    (while (and (not found) (> (line-number-at-pos) 1))
      (forward-line -1)
      (unless (owl--blank-or-comment-line-p)
        (setq found t)))
    found))

(defun owl--goto-previous-enclosing-line (indent)
  "Move to the previous code line indented less than INDENT.
Return non-nil when such a line exists."
  (let (found)
    (while (and (not found) (owl--goto-previous-code-line))
      (when (< (current-indentation) indent)
        (setq found t)))
    found))

(defun owl--indent-for-new-line ()
  "Return indentation for a fresh line after the previous code line."
  (save-excursion
    (if (owl--goto-previous-code-line)
        (+ (current-indentation)
           (if (owl--line-opens-block-p) owl-indent-offset 0))
      0)))

(defun owl--indent-for-existing-line (indent)
  "Return desired indentation for an existing line currently at INDENT."
  (if (zerop indent)
      0
    (save-excursion
      (if (owl--goto-previous-enclosing-line indent)
          (+ (current-indentation)
             (if (owl--line-opens-block-p) owl-indent-offset 0))
        indent))))

(defun owl-calculate-indentation ()
  "Return desired indentation for the current Owl line."
  (save-excursion
    (back-to-indentation)
    (if (owl--blank-or-comment-line-p)
        (owl--indent-for-new-line)
      (owl--indent-for-existing-line (current-indentation)))))

(defun owl-indent-line ()
  "Indent the current Owl line."
  (interactive)
  (let ((indent (owl-calculate-indentation))
        (offset (- (current-column) (current-indentation))))
    (indent-line-to indent)
    (when (> offset 0)
      (move-to-column (+ indent offset)))))

(defun owl-tab ()
  "Insert spaces up to the next Owl indentation column."
  (interactive)
  (insert (make-string (- owl-indent-offset
                          (% (current-column) owl-indent-offset))
                       ?\s)))

(defun owl-beginning-of-block ()
  "Move to the nearest previous line that opens an Owl block."
  (interactive)
  (let ((origin (point))
        found)
    (while (and (not found) (owl--goto-previous-code-line))
      (setq found (owl--line-opens-block-p)))
    (unless found
      (goto-char origin))))

(defvar owl-mode-syntax-table
  (let ((table (make-syntax-table prog-mode-syntax-table)))
    (modify-syntax-entry ?\" "\"" table)
    (modify-syntax-entry ?\\ "\\" table)
    (modify-syntax-entry ?_ "w" table)
    (modify-syntax-entry ?- "w" table)
    (modify-syntax-entry ?? "w" table)
    (modify-syntax-entry ?\[ "(]" table)
    (modify-syntax-entry ?\] ")[" table)
    (modify-syntax-entry ?\{ "(}" table)
    (modify-syntax-entry ?\} "){" table)
    (modify-syntax-entry ?\( "()" table)
    (modify-syntax-entry ?\) ")(" table)
    (modify-syntax-entry ?. "." table)
    (modify-syntax-entry ?: "." table)
    (modify-syntax-entry ?= "." table)
    (modify-syntax-entry ?\; "<" table)
    (modify-syntax-entry ?\n ">" table)
    table)
  "Syntax table for `owl-mode'.")

(defvar-local owl-font-lock-keywords nil
  "Buffer-local Owl font-lock keywords.")

(defun owl--font-lock-keywords ()
  "Build Owl font-lock keywords from the configured command lists."
  `((,(owl--regexp-opt-symbols owl-constant-names) . font-lock-constant-face)
    (,(owl--regexp-opt-symbols owl-block-command-names) . font-lock-keyword-face)
    (,(concat "^[ \t]*\\(" owl-identifier-regexp "\\)[ \t]*=")
     1 'owl-binding-face)
    (,(concat "\\_<\\(" (owl--regexp-opt-symbols owl-configuration-key-names)
              "\\)\\_>[ \t]*=")
     1 'owl-binding-face)
    (,(concat "\\_<\\(" (owl--regexp-opt-symbols owl-definition-command-names)
              "\\)\\_>[ \t]+\\(?:(\\)?\\(" owl-symbol-regexp "\\)")
     (1 font-lock-keyword-face)
     (2 'owl-function-name-face))
    (,owl-selector-regexp 1 'owl-selector-face)
    (,owl-number-regexp . font-lock-constant-face)
    (,owl-string-interpolation-regexp . font-lock-variable-use-face)
    (owl--match-command-head 1 font-lock-function-name-face)
    (,(owl--regexp-opt-symbols owl-core-command-names) . font-lock-builtin-face)
    (,(owl--regexp-opt-symbols owl-prelude-command-names) . font-lock-builtin-face)
    (,(owl--regexp-opt-symbols owl-nest-command-names) . font-lock-function-name-face)
    (,owl-delimiter-regexp 0 'owl-delimiter-face)))

(defvar owl-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "TAB") #'owl-tab)
    (define-key map (kbd "C-M-a") #'owl-beginning-of-block)
    map)
  "Keymap for `owl-mode'.")

;;;###autoload
(define-derived-mode owl-mode prog-mode "Owl"
  "Major mode for editing Owl source files."
  :syntax-table owl-mode-syntax-table
  (setq-local owl-font-lock-keywords (owl--font-lock-keywords))
  (setq-local font-lock-defaults '(owl-font-lock-keywords nil nil nil nil))
  (setq-local font-lock-multiline t)
  (setq-local indent-line-function #'owl-indent-line)
  (setq-local comment-start "; ")
  (setq-local comment-end "")
  (setq-local comment-start-skip ";+\\s-*")
  (setq-local tab-width owl-indent-offset)
  (setq-local indent-tabs-mode nil)
  (setq-local electric-indent-chars (append (list ?: 10) electric-indent-chars))
  (setq-local imenu-generic-expression
              `(("Definitions"
                 ,(concat "^[ \t]*"
                          (regexp-opt owl-definition-command-names)
                          "[ \t]+\\(?:(\\)?\\(" owl-symbol-regexp "\\)")
                 1)
                ("Bindings" ,(concat "^[ \t]*\\(" owl-identifier-regexp
                                     "\\)[ \t]*=")
                 1))))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.owl\\'" . owl-mode))

(provide 'init-owl)
;;; init-owl.el ends here
