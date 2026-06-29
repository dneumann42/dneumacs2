;;; owl.el --- Owl syntax highlighting and indentation -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'subr-x)

(defgroup init/owl nil
  "Owl editing support."
  :group 'languages)

(defcustom init/owl-indent-offset 2
  "Indentation width used for Owl block bodies."
  :type 'integer
  :group 'init/owl)

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

(defconst init/owl--symbol-regexp
  "[A-Za-z_+\\-*/<>=!?][A-Za-z0-9_+\\-*/<>=!?]*"
  "Regexp for Owl symbols and command heads.")

(defconst init/owl--number-regexp
  "\\_<-?[0-9]+\\(?:\\.[0-9]+\\)?\\_>"
  "Regexp for Owl numbers.")

(defconst init/owl--keyword-regexp
  "\\_<:[A-Za-z_+\\-*/<>=!?][A-Za-z0-9_+\\-*/<>=!?]*\\_>"
  "Regexp for Owl keywords.")

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
  (concat "\\(?:\\`\\|^\\|[;\n]\\)[ \t]*\\("
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

(defun init/owl--previous-code-line-indent ()
  "Return the indentation of the previous nonblank Owl line."
  (save-excursion
    (let ((indent 0)
          (found nil))
      (while (and (not found) (not (bobp)))
        (forward-line -1)
        (unless (looking-at-p "^[ \t]*$")
          (setq indent (current-indentation)
                found t)))
      indent)))

(defun init/owl-indent-line ()
  "Indent the current Owl line."
  (interactive)
  (let* ((offset init/owl-indent-offset)
         (save-point (- (point) (line-beginning-position)))
         (indent
          (save-excursion
            (back-to-indentation)
            (cond
             ((bobp) 0)
             ((looking-at-p "end\\_>")
              (max 0 (- (init/owl--previous-code-line-indent) offset)))
             (t
              (let ((prev-indent (init/owl--previous-code-line-indent)))
                (if (save-excursion
                      (forward-line -1)
                      (init/owl--line-opens-block-p))
                    (+ prev-indent offset)
                  prev-indent)))))))
    (indent-line-to indent)
    (if (> save-point (current-indentation))
        (goto-char (+ (line-beginning-position) (current-indentation)))
      (goto-char (+ (line-beginning-position) save-point)))))

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
    (modify-syntax-entry ?\; "." table)
    table)
  "Syntax table for `owl-mode'.")

(defvar-local init/owl-font-lock-keywords nil
  "Buffer-local Owl font-lock keywords.")

(defun init/owl--font-lock-keywords ()
  "Build Owl font-lock keywords from the current command lists."
  (let ((intro (init/owl--intro-regexp))
        (commands (regexp-opt (init/owl--command-names) 'symbols)))
    `((,intro . font-lock-keyword-face)
      (,init/owl--keyword-regexp . font-lock-constant-face)
      (,init/owl--number-regexp . font-lock-constant-face)
      (init/owl--match-command-head 1 font-lock-function-name-face)
      (,(concat "\\_<\\(" commands "\\)\\_>") 1 font-lock-function-name-face))))

(defun init/owl-setup ()
  "Configure Owl editing defaults for the current buffer."
  (setq-local init/owl-font-lock-keywords (init/owl--font-lock-keywords))
  (setq-local font-lock-defaults '(init/owl-font-lock-keywords nil nil nil nil))
  (setq-local font-lock-multiline t)
  (setq-local indent-line-function #'init/owl-indent-line)
  (setq-local comment-start nil)
  (setq-local comment-end nil)
  (setq-local tab-width init/owl-indent-offset)
  (setq-local indent-tabs-mode nil)
  (setq-local electric-indent-chars
              (append '(?\n ?\;) electric-indent-chars))
  (setq-local imenu-generic-expression
              `(("Commands"
                 ,(concat "^\\s-*\\(" init/owl--symbol-regexp "\\)")
                 1))))

(define-derived-mode owl-mode prog-mode "Owl"
  "Major mode for Owl source files."
  :syntax-table init/owl-mode-syntax-table
  (init/owl-setup))

(add-to-list 'auto-mode-alist '("\\.owl\\'" . owl-mode))

(provide 'owl)
;;; owl.el ends here
