;;; init-lang-dsl.el --- Major modes for the Owl and Nest DSLs -*- lexical-binding: t; -*-

;;; Commentary:

;; Two hand-written major modes for small domain-specific languages that
;; have no upstream Emacs support.
;;
;; Owl is block-structured with explicit `do'/`then'/`cond' openers and a
;; matching `end'; indentation is computed by counting those tokens.  Its
;; parser registers commands dynamically, so the command names that get
;; highlighted are customizable.
;;
;; Nest is indentation-structured: a line ending in a colon opens a block,
;; exactly like Python.

;;; Code:

(require 'subr-x)

;;; Owl

(defgroup owl nil
  "Editing support for Owl source files."
  :group 'languages)

(defcustom owl-line-command-names '("def" "print")
  "Known Owl line commands to highlight.
Owl's parser registers commands dynamically, so this list is
deliberately customizable."
  :type '(repeat string)
  :group 'owl)

(defcustom owl-block-command-names '("if" "fun")
  "Known Owl block commands to highlight and indent."
  :type '(repeat string)
  :group 'owl)

(defconst owl-indent-offset 4
  "Indentation width used for Owl block bodies.")

(defconst owl-intro-keywords '("do" "then" "cond" "else" "end")
  "Owl block-intro keywords understood by the parser.")

(defconst owl-language-keywords
  '("true" "false" "set" "for" "while" "command")
  "Owl literals and language keywords.")

;;;; Regexps and faces

(defconst owl-symbol-regexp
  ;; The hyphen must sit at the end of each character class to be a
  ;; literal member.
  "[A-Za-z_+*/<>=!?-][A-Za-z0-9_+*/<>=!?-]*"
  "Regexp matching Owl symbols and command heads.")

(defconst owl-number-regexp
  "\\_<-?[0-9]+\\(?:\\.[0-9]+\\)?\\_>"
  "Regexp matching Owl numbers.")

(defconst owl-keyword-regexp
  "\\_<:[A-Za-z_+*/<>=!?-][A-Za-z0-9_+*/<>=!?-]*\\_>"
  "Regexp matching Owl keywords.")

(defconst owl-operator-regexp "[-+*/<>=!?]+"
  "Regexp matching Owl operators.")

(defconst owl-delimiter-regexp
  (regexp-opt '("(" ")" "[" "]" "{" "}" "<" ">"))
  "Regexp matching Owl opening and closing delimiters.")

(defconst owl-fun-name-regexp
  (concat "\\_<fun\\_>[ \t]+\\(" owl-symbol-regexp "\\)[ \t]*\\[")
  "Regexp matching the name in an Owl `fun NAME[...]' form.")

(defface owl-function-name-face
  '((((class color) (background dark))
     (:foreground "#8be9a8" :weight bold))
    (((class color) (background light))
     (:foreground "#087830" :weight bold))
    (t (:inherit font-lock-function-name-face :weight bold)))
  "Face for function identifiers in Owl `fun NAME[...]' forms."
  :group 'owl)

(defface owl-delimiter-face
  '((t (:inherit font-lock-builtin-face :weight bold)))
  "Face for delimiters in Owl forms."
  :group 'owl)

;;;; Commands and blocks

(defun owl--command-names ()
  "Return the union of the known Owl command names."
  (delete-dups (append owl-line-command-names owl-block-command-names)))

(defun owl--intro-regexp ()
  "Return the regexp matching Owl block-intro keywords."
  (concat "\\_<\\(" (regexp-opt owl-intro-keywords t) "\\)\\_>"))

(defun owl--command-head-regexp ()
  "Return the regexp matching a command head at the start of a form."
  (concat "\\(?:\\`\\|^\\|\n\\)[ \t]*\\("
          "\\_<" (regexp-opt (owl--command-names)) "\\_>"
          "\\)"))

(defun owl--match-command-head (limit)
  "Search forward for a known Owl command head, up to LIMIT.
A font-lock matcher: heads inside strings are skipped."
  (let ((regexp (owl--command-head-regexp))
        (case-fold-search nil))
    (catch 'found
      (while (re-search-forward regexp limit t)
        (unless (nth 3 (syntax-ppss (match-beginning 1)))
          (throw 'found t)))
      nil)))

(defun owl--line-opens-block-p ()
  "Return non-nil when the current line opens an Owl block."
  (let* ((line (string-trim (buffer-substring-no-properties
                             (line-beginning-position)
                             (line-end-position))))
         (head (when (string-match (concat "^\\(" owl-symbol-regexp "\\)") line)
                 (match-string 1 line))))
    (or (and head (member head owl-block-command-names))
        (string-match-p
         (concat "\\_<\\(" (regexp-opt owl-intro-keywords t)
                 "\\)\\_>[ \t]*\\(?:;.*\\)?\\'")
         line))))

(defun owl--token-in-code-p (position)
  "Return non-nil when POSITION lies outside any Owl string or comment."
  (let ((state (save-excursion (save-match-data (syntax-ppss position)))))
    (not (or (nth 3 state) (nth 4 state)))))

(defun owl--apply-line-tokens (depth)
  "Return DEPTH updated by the block tokens on the current line.
Point must be at the start of the line; it is left no further than the
line's end.  Tokens inside a string or comment do not count."
  (let ((line-end (line-end-position)))
    (while (re-search-forward "\\_<\\(do\\|then\\|cond\\|end\\)\\_>" line-end t)
      (when (owl--token-in-code-p (match-beginning 0))
        (setq depth (if (string= (match-string-no-properties 1) "end")
                        (max 0 (1- depth))
                      (1+ depth)))))
    depth))

(defun owl--block-depth-before-line ()
  "Return the open Owl block depth just before the current line."
  (save-excursion
    (let ((limit (line-beginning-position))
          (depth 0))
      (goto-char (point-min))
      (while (< (point) limit)
        (let ((line-end (line-end-position))
              ;; `elif ... do' replaces the preceding branch rather than
              ;; nesting another block inside it.
              (elif-line (looking-at-p "^[ \t]*elif\\_>")))
          (setq depth (owl--apply-line-tokens depth))
          (when elif-line (setq depth (max 0 (1- depth))))
          (goto-char (min limit (1+ line-end)))))
      depth)))

;;;; Indentation

(defun owl-indent-line ()
  "Indent the current Owl line."
  (interactive)
  (let* ((old-indent (current-indentation))
         (text-column (max 0 (- (current-column) old-indent)))
         (depth (owl--block-depth-before-line))
         (closing (save-excursion
                    (back-to-indentation)
                    (looking-at-p "\\(?:else\\|elif\\|end\\)\\_>")))
         (indent (* owl-indent-offset (max 0 (- depth (if closing 1 0))))))
    (indent-line-to indent)
    (move-to-column (+ indent text-column))))

(defun owl-tab ()
  "Insert spaces up to the next Owl indentation column."
  (interactive)
  (insert (make-string (- owl-indent-offset
                          (% (current-column) owl-indent-offset))
                       ?\s)))

(defun owl--electric-dedent ()
  "Re-indent a closing Owl keyword as soon as it has been typed."
  (when (and (memq last-command-event '(?d ?e ?f))
             (save-excursion
               (beginning-of-line)
               (looking-at-p "^[ \t]*\\(?:end\\|else\\|elif\\)[ \t]*$")))
    (owl-indent-line)))

;;;; Syntax and font lock

(defvar owl-mode-syntax-table
  (let ((table (make-syntax-table prog-mode-syntax-table)))
    (modify-syntax-entry ?\" "\"" table)
    (modify-syntax-entry ?\\ "\\" table)
    (modify-syntax-entry ?_ "w" table)
    (dolist (character '(?+ ?- ?* ?/ ?< ?= ?> ?! ??))
      (modify-syntax-entry character "_" table))
    (modify-syntax-entry ?\[ "(]" table)
    (modify-syntax-entry ?\] ")[" table)
    (modify-syntax-entry ?\{ "(}" table)
    (modify-syntax-entry ?\} "){" table)
    (modify-syntax-entry ?\( "()" table)
    (modify-syntax-entry ?\) ")(" table)
    (modify-syntax-entry ?. "." table)
    (modify-syntax-entry ?: "." table)
    (modify-syntax-entry ?\; "<" table)
    (modify-syntax-entry ?\n ">" table)
    table)
  "Syntax table for `owl-mode'.")

(defvar-local owl-font-lock-keywords nil
  "Buffer-local Owl font-lock keywords, built from the command lists.")

(defun owl--font-lock-keywords ()
  "Build the Owl font-lock keywords from the current command lists."
  (let ((commands (regexp-opt (owl--command-names) 'symbols)))
    `((,(owl--intro-regexp) . font-lock-keyword-face)
      (,(regexp-opt owl-language-keywords 'symbols) . font-lock-keyword-face)
      (,owl-keyword-regexp . font-lock-constant-face)
      (,owl-number-regexp . font-lock-constant-face)
      (,owl-fun-name-regexp 1 'owl-function-name-face)
      (,owl-delimiter-regexp 0 'owl-delimiter-face)
      (,owl-operator-regexp . font-lock-builtin-face)
      (owl--match-command-head 1 font-lock-function-name-face)
      (,(concat "\\_<\\(" commands "\\)\\_>") 1 font-lock-function-name-face))))

;;;; Major mode

(defvar owl-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "TAB") #'owl-tab)
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
  (setq-local electric-indent-chars
              (cons ?\n (remove ?\; electric-indent-chars)))
  (setq-local imenu-generic-expression
              `(("Commands" ,(concat "^\\s-*\\(" owl-symbol-regexp "\\)") 1)))
  (add-hook 'post-self-insert-hook #'owl--electric-dedent nil t))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.owl\\'" . owl-mode))

;;; Nest

(defgroup nest nil
  "Editing support for Nest DSL files."
  :group 'languages)

(defcustom nest-indent-offset 2
  "Indentation step for `nest-mode'."
  :type 'integer
  :safe #'integerp
  :group 'nest)

(defconst nest-mode-keywords
  '("define" "events" "when" "command" "import" "export" "fun" "record"
    "if" "cond" "unless" "while")
  "Nest keywords introducing a form.")

(defconst nest-mode-builtins
  '("id" "LineInputState" "EditLineState"
    "fill" "fit" "fixed" "hug" "prefer"
    "clicked" "submitted" "not" "scope" "exec"
    "env" "split" "loadLines" "writeLines"
    "appendLine" "insertLine" "setLine" "deleteLine"
    "setText" "browseFolder" "execStatus"
    "forLines" "editing" "beginEdit" "cancelEdit" "saveEdit"
    "editInputID" "editInput" "print")
  "Nest built-in procedures.")

(defconst nest-mode-widgets
  '("row" "column" "panel" "label" "button" "lineInput" "pathListBox")
  "Nest widget constructors.")

(defconst nest-mode-constants
  '("true" "false"
    "AlignAuto" "AlignStart" "AlignCenter" "AlignEnd" "AlignStretch"
    "JustifyStart" "JustifyCenter" "JustifyEnd")
  "Nest literal constants.")

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
    ("\\_<-?[0-9]+\\(?:\\.[0-9]+\\)?\\_>" . font-lock-constant-face))
  "Font-lock keywords for `nest-mode'.")

(defconst nest-mode-imenu-generic-expression
  '(("Commands" "^[[:blank:]]*command[[:blank:]]+\\([[:word:]_-]+\\)" 1))
  "Imenu patterns for `nest-mode'.")

;;;; Indentation

(defun nest--blank-or-comment-line-p ()
  "Return non-nil when the current line is blank or a comment."
  (save-excursion
    (back-to-indentation)
    (or (eolp) (looking-at-p ";"))))

(defun nest--line-opens-block-p ()
  "Return non-nil when the current line ends with a block colon."
  (save-excursion
    (end-of-line)
    (skip-chars-backward " \t")
    (eq (char-before) ?:)))

(defun nest--goto-previous-code-line ()
  "Move to the previous non-blank, non-comment line.
Return non-nil when such a line exists."
  (let (found)
    (while (and (not found) (> (line-number-at-pos) 1))
      (forward-line -1)
      (unless (nest--blank-or-comment-line-p)
        (setq found t)))
    found))

(defun nest--goto-previous-enclosing-line (indent)
  "Move to the previous code line indented less than INDENT.
Return non-nil when such a line exists."
  (let (found)
    (while (and (not found) (nest--goto-previous-code-line))
      (when (< (current-indentation) indent)
        (setq found t)))
    found))

(defun nest--indent-for-new-line ()
  "Return the indentation for a fresh line after the previous code line."
  (save-excursion
    (if (nest--goto-previous-code-line)
        (+ (current-indentation)
           (if (nest--line-opens-block-p) nest-indent-offset 0))
      0)))

(defun nest--indent-for-existing-line (indent)
  "Return the desired indentation for an existing line now at INDENT."
  (if (zerop indent)
      0
    (save-excursion
      (if (nest--goto-previous-enclosing-line indent)
          (+ (current-indentation)
             (if (nest--line-opens-block-p) nest-indent-offset 0))
        indent))))

(defun nest-calculate-indentation ()
  "Return the desired indentation for the current line."
  (save-excursion
    (back-to-indentation)
    (if (nest--blank-or-comment-line-p)
        (nest--indent-for-new-line)
      (nest--indent-for-existing-line (current-indentation)))))

(defun nest-indent-line ()
  "Indent the current line as Nest DSL."
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
        found)
    (while (and (not found) (nest--goto-previous-code-line))
      (setq found (nest--line-opens-block-p)))
    (unless found
      (goto-char origin))))

;;;; Major mode

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

(provide 'init-lang-dsl)
;;; init-lang-dsl.el ends here
