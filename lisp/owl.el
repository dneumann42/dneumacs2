;;; owl.el --- Owl syntax highlighting and indentation -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'subr-x)

;;;; Customization

(defgroup init/owl nil
  "Owl editing support."
  :group 'languages)

(defconst init/owl-indent-offset 4
  "Indentation width used for Owl block bodies.")

(defcustom init/owl-line-command-names '("def" "print")
  "Known Owl line commands to highlight.
Owl's parser registers commands dynamically, so this list is intentionally
customizable."
  :type '(repeat string)
  :group 'init/owl)

(defcustom init/owl-block-command-names '("if" "fun")
  "Known Owl block commands to highlight and indent."
  :type '(repeat string)
  :group 'init/owl)

(defconst init/owl--intro-keywords '("do" "then" "cond" "else" "end")
  "Owl block-intro keywords understood by the parser.")

(defconst init/owl--language-keywords
  '("true" "false" "set" "for" "while" "command")
  "Owl literals and language keywords.")

;;;; Regexps and faces

(defconst init/owl--symbol-regexp
  ;; The hyphen must sit at the end of each class to be a literal member;
  ;; the previous "\\-" form neither matched "-" nor "*", so hyphenated
  ;; symbols such as "list-tail" were never recognized.
  "[A-Za-z_+*/<>=!?-][A-Za-z0-9_+*/<>=!?-]*"
  "Regexp for Owl symbols and command heads.")

(defconst init/owl--number-regexp
  "\\_<-?[0-9]+\\(?:\\.[0-9]+\\)?\\_>"
  "Regexp for Owl numbers.")

(defconst init/owl--keyword-regexp
  "\\_<:[A-Za-z_+*/<>=!?-][A-Za-z0-9_+*/<>=!?-]*\\_>"
  "Regexp for Owl keywords.")

(defconst init/owl--operator-regexp
  "[-+*/<>=!?]+"
  "Regexp for Owl operators.")

(defconst init/owl--delimiter-regexp
  (regexp-opt '("(" ")" "[" "]" "{" "}" "<" ">"))
  "Regexp matching Owl opening and closing delimiters.")

(defconst init/owl--fun-name-regexp
  (concat "\\_<fun\\_>[ \t]+\\(" init/owl--symbol-regexp "\\)[ \t]*\\[")
  "Regexp matching the name in an Owl `fun NAME[...]' form.")

(defface init/owl-function-name-face
  '((((class color) (background dark))
     (:foreground "#8be9a8" :weight bold))
    (((class color) (background light))
     (:foreground "#087830" :weight bold))
    (t (:inherit font-lock-function-name-face :weight bold)))
  "Face used for function identifiers in Owl `fun NAME[...]' forms."
  :group 'init/owl)

(defface init/owl-delimiter-face
  '((t (:inherit font-lock-builtin-face :weight bold)))
  "Face used for delimiters in Owl forms."
  :group 'init/owl)

;;;; Command and block detection

(defun init/owl--command-names ()
  "Return the union of known Owl command names."
  (delete-dups (append init/owl-line-command-names
                       init/owl-block-command-names)))

(defun init/owl--intro-regexp ()
  "Return the regexp that matches Owl block-intro keywords."
  (concat "\\_<\\("
          (regexp-opt init/owl--intro-keywords t)
          "\\)\\_>"))

(defun init/owl--command-head-regexp ()
  "Return the regexp for a command head at the start of a form."
  (concat "\\(?:\\`\\|^\\|\n\\)[ \t]*\\("
          "\\_<"
          (regexp-opt (init/owl--command-names))
          "\\_>"
          "\\)"))

(defun init/owl--match-command-head (limit)
  "Search forward for a known Owl command head up to LIMIT."
  (let ((regexp (init/owl--command-head-regexp))
        (case-fold-search nil))
    (catch 'found
      (while (re-search-forward regexp limit t)
        (unless (nth 3 (syntax-ppss (match-beginning 1)))
          (throw 'found t)))
      nil)))

(defun init/owl--line-opens-block-p ()
  "Return non-nil when the current line opens an Owl block."
  (let* ((line (string-trim (buffer-substring-no-properties
                             (line-beginning-position)
                             (line-end-position))))
         (head (when (string-match (concat "^\\(" init/owl--symbol-regexp "\\)") line)
                 (match-string 1 line))))
    (or (and head (member head init/owl-block-command-names))
        (string-match-p
         (concat "\\_<\\("
                 (regexp-opt init/owl--intro-keywords t)
                 "\\)\\_>[ \t]*\\(?:;.*\\)?\\'")
         line))))

(defun init/owl--block-depth-before-line ()
  "Return the open Owl block depth before the current line."
  (save-excursion
    (let ((limit (line-beginning-position))
          (depth 0))
      (goto-char (point-min))
      (while (< (point) limit)
        (let ((line-end (line-end-position))
              (elif-line (looking-at-p "^[ \t]*elif\\_>")))
          (while (re-search-forward "\\_<\\(do\\|then\\|cond\\|end\\)\\_>" line-end t)
            (let ((position (match-beginning 0))
                  (token (match-string-no-properties 1)))
              (unless (let ((state (save-excursion
                                     (save-match-data (syntax-ppss position)))))
                        (or (nth 3 state) (nth 4 state)))
                (if (string= token "end")
                    (setq depth (max 0 (1- depth)))
                  (setq depth (1+ depth))))))
          ;; `elif ... do' replaces the preceding branch rather than nesting
          ;; another block inside it.
          (when elif-line
            (setq depth (max 0 (1- depth))))
          (goto-char (min limit (1+ line-end)))))
      depth)))

;;;; Indentation

(defun init/owl-indent-line ()
  "Indent the current Owl line."
  (interactive)
  (let* ((offset init/owl-indent-offset)
         (old-indent (current-indentation))
         (text-column (max 0 (- (current-column) old-indent)))
         (depth (init/owl--block-depth-before-line))
         (closing (save-excursion
                    (back-to-indentation)
                    (looking-at-p "\\(?:else\\|elif\\|end\\)\\_>")))
         (indent (* offset (max 0 (- depth (if closing 1 0))))))
    (indent-line-to indent)
    (move-to-column (+ indent text-column))))

(defun init/owl-tab ()
  "Insert spaces through the next Owl indentation column."
  (interactive)
  (let ((count (- init/owl-indent-offset
                  (% (current-column) init/owl-indent-offset))))
    (insert (make-string count ?\s))))

(defun init/owl--electric-dedent ()
  "Indent a closing Owl keyword immediately after it is typed."
  (when (and (memq last-command-event '(?d ?e ?f))
             (save-excursion
               (beginning-of-line)
               (looking-at-p "^[ \t]*\\(?:end\\|else\\|elif\\)[ \t]*$")))
    (init/owl-indent-line)))

;;;; Syntax table and font-lock

(defvar init/owl-mode-syntax-table
  (let ((table (make-syntax-table prog-mode-syntax-table)))
    (modify-syntax-entry ?\" "\"" table)
    (modify-syntax-entry ?\\ "\\" table)
    (modify-syntax-entry ?_ "w" table)
    (dolist (ch '(?+ ?- ?* ?/ ?< ?= ?> ?! ??))
      (modify-syntax-entry ch "_" table))
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

(defvar-local init/owl-font-lock-keywords nil
  "Buffer-local Owl font-lock keywords.")

(defun init/owl--font-lock-keywords ()
  "Build Owl font-lock keywords from the current command lists."
  (let ((intro (init/owl--intro-regexp))
        (commands (regexp-opt (init/owl--command-names) 'symbols))
        (language-keywords (regexp-opt init/owl--language-keywords 'symbols)))
    `((,intro . font-lock-keyword-face)
      (,language-keywords . font-lock-keyword-face)
      (,init/owl--keyword-regexp . font-lock-constant-face)
      (,init/owl--number-regexp . font-lock-constant-face)
      (,init/owl--fun-name-regexp 1 'init/owl-function-name-face)
      (,init/owl--delimiter-regexp 0 'init/owl-delimiter-face)
      (,init/owl--operator-regexp . font-lock-builtin-face)
      (init/owl--match-command-head 1 font-lock-function-name-face)
      (,(concat "\\_<\\(" commands "\\)\\_>") 1 font-lock-function-name-face))))

;;;; Major mode

(defun init/owl-setup ()
  "Configure Owl editing defaults for the current buffer."
  (setq-local init/owl-font-lock-keywords (init/owl--font-lock-keywords))
  (setq-local font-lock-defaults '(init/owl-font-lock-keywords nil nil nil nil))
  (setq-local font-lock-multiline t)
  (setq-local indent-line-function #'init/owl-indent-line)
  (setq-local comment-start "; ")
  (setq-local comment-end "")
  (setq-local comment-start-skip ";+\\s-*")
  (setq-local tab-width init/owl-indent-offset)
  (setq-local indent-tabs-mode nil)
  (setq-local electric-indent-chars
              (cons ?\n (remove ?\; electric-indent-chars)))
  (add-hook 'post-self-insert-hook #'init/owl--electric-dedent nil t)
  (setq-local imenu-generic-expression
              `(("Commands"
                 ,(concat "^\\s-*\\(" init/owl--symbol-regexp "\\)")
                 1))))

(define-derived-mode owl-mode prog-mode "Owl"
  "Major mode for Owl source files."
  :syntax-table init/owl-mode-syntax-table
  (init/owl-setup))

(define-key owl-mode-map (kbd "TAB") #'init/owl-tab)

(add-to-list 'auto-mode-alist '("\\.owl\\'" . owl-mode))

(provide 'owl)
;;; owl.el ends here
