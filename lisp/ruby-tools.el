;;; ruby-tools.el --- Ruby language support -*- lexical-binding: t; -*-

(require 'subr-x)

(declare-function eglot-code-actions "eglot")
(declare-function eglot-ensure "eglot")
(declare-function eglot-help-at-point "eglot")
(declare-function eglot-reconnect "eglot")
(declare-function yas-minor-mode "yasnippet")

(defvar init/ruby--gem-user-bin nil
  "User gem executable directory for the active Ruby, when known.")

(defun init/ruby--detect-gem-user-bin ()
  "Return the user gem executable directory for the active Ruby, or nil."
  (when (executable-find "ruby")
    (with-temp-buffer
      (when (zerop (call-process
                    "ruby" nil t nil
                    "-rrubygems" "-e" "print File.join(Gem.user_dir, 'bin')"))
        (let ((dir (string-trim (buffer-string))))
          (when (file-directory-p dir)
            dir))))))

(defun init/ruby--ensure-gem-path ()
  "Make user-installed Ruby gem executables visible to Emacs."
  (when-let ((dir (or init/ruby--gem-user-bin
                      (setq init/ruby--gem-user-bin
                            (init/ruby--detect-gem-user-bin)))))
    (add-to-list 'exec-path dir)
    (let ((paths (split-string (or (getenv "PATH") "") path-separator t)))
      (unless (member dir paths)
        (setenv "PATH"
                (mapconcat #'identity
                           (cons dir paths)
                           path-separator))))))

(init/ruby--ensure-gem-path)

(defun init/ruby-hover-doc ()
  "Show documentation for symbol at point."
  (interactive)
  (cond
   ((fboundp 'eglot-help-at-point)
    (eglot-help-at-point))
   ((fboundp 'eldoc-print-current-symbol-info)
    (eldoc-print-current-symbol-info))
   (t
    (message "No hover documentation command available."))))

(defun init/ruby-show-diagnostics ()
  "Show diagnostics for the current buffer."
  (interactive)
  (cond
   ((and (bound-and-true-p flycheck-mode)
         (fboundp 'flycheck-list-errors))
    (flycheck-list-errors))
   ((fboundp 'flymake-show-buffer-diagnostics)
    (flymake-show-buffer-diagnostics))
   ((fboundp 'flymake-show-project-diagnostics)
    (flymake-show-project-diagnostics))
   (t
    (message "No diagnostics UI available."))))

(defun init/ruby--server-missing-warning ()
  "Warn if ruby-lsp is not available in PATH."
  (unless (executable-find "ruby-lsp")
    (display-warning
     'ruby
     "ruby-lsp not found in PATH. Install the ruby-lsp gem for Ruby LSP support."
     :warning)))

(defun init/ruby-setup ()
  "Set up Ruby editing, snippets, LSP and navigation in current buffer."
  (setq-local ruby-indent-level 2)
  (setq-local tab-width 2)
  (setq-local indent-tabs-mode nil)
  (when (fboundp 'yas-minor-mode)
    (yas-minor-mode 1))
  (init/ruby--server-missing-warning)
  (when (fboundp 'eglot-ensure)
    (eglot-ensure))
  (local-set-key (kbd "C-c h") #'init/ruby-hover-doc)
  (local-set-key (kbd "C-c d") #'init/ruby-show-diagnostics)
  (local-set-key (kbd "C-c r") #'eglot-reconnect)
  (local-set-key (kbd "C-c a") #'eglot-code-actions)
  (local-set-key (kbd "M-RET") #'eglot-code-actions)
  (local-set-key (kbd "M-.") #'xref-find-definitions)
  (local-set-key (kbd "M-,") #'xref-go-back))

(use-package ruby-mode
  :ensure nil
  :mode (("\\.rb\\'" . ruby-mode)
         ("\\.rake\\'" . ruby-mode)
         ("\\.gemspec\\'" . ruby-mode)
         ("Gemfile\\'" . ruby-mode)
         ("Rakefile\\'" . ruby-mode)
         ("Guardfile\\'" . ruby-mode)
         ("Podfile\\'" . ruby-mode)
         ("\\.irbrc\\'" . ruby-mode)
         ("\\.pryrc\\'" . ruby-mode))
  :interpreter "ruby"
  :hook (ruby-mode . init/ruby-setup))

(defun init/ruby--treesit-ready-p ()
  "Return non-nil when Ruby tree-sitter support is available."
  (and (fboundp 'treesit-ready-p)
       (treesit-ready-p 'ruby)))

(when (and (fboundp 'ruby-ts-mode)
           (init/ruby--treesit-ready-p))
  (dolist (pattern '("\\.rb\\'"
                     "\\.rake\\'"
                     "\\.gemspec\\'"
                     "Gemfile\\'"
                     "Rakefile\\'"
                     "Guardfile\\'"
                     "Podfile\\'"
                     "\\.irbrc\\'"
                     "\\.pryrc\\'"))
    (add-to-list 'auto-mode-alist (cons pattern #'ruby-ts-mode)))
  (add-hook 'ruby-ts-mode-hook #'init/ruby-setup))

(use-package eglot
  :ensure nil
  :commands (eglot eglot-ensure eglot-code-actions)
  :config
  (add-to-list 'eglot-server-programs
               '((ruby-mode ruby-ts-mode) . ("ruby-lsp"))))

(provide 'ruby-tools)
;;; ruby-tools.el ends here
