;;; rust.el --- Rust language support -*- lexical-binding: t; -*-

(defgroup init/rust nil
  "Rust editing support."
  :group 'languages)

(defcustom init/rust-cargo-bin-directory
  (expand-file-name ".cargo/bin" (getenv "HOME"))
  "Directory containing Cargo-installed Rust tools."
  :type 'directory
  :group 'init/rust)

(defcustom init/rust-analyzer-command "rust-analyzer"
  "Command used to start rust-analyzer."
  :type 'string
  :group 'init/rust)

(defun init/rust--ensure-cargo-bin-in-path ()
  "Make Cargo-installed tools visible to Emacs."
  (when (file-directory-p init/rust-cargo-bin-directory)
    (add-to-list 'exec-path init/rust-cargo-bin-directory)
    (let ((paths (split-string (or (getenv "PATH") "") path-separator t)))
      (unless (member init/rust-cargo-bin-directory paths)
        (setenv "PATH"
                (mapconcat #'identity
                           (cons init/rust-cargo-bin-directory paths)
                           path-separator))))))

(defun init/rust-hover-doc ()
  "Show documentation for symbol at point."
  (interactive)
  (cond
   ((fboundp 'eglot-help-at-point)
    (eglot-help-at-point))
   ((fboundp 'eldoc-print-current-symbol-info)
    (eldoc-print-current-symbol-info))
   (t
    (message "No hover documentation command available."))))

(defun init/rust-show-diagnostics ()
  "Show diagnostics at point, preferring popup UI."
  (interactive)
  (cond
   ((fboundp 'flycheck-posframe-show-posframe)
    (flycheck-posframe-show-posframe))
   ((fboundp 'flycheck-list-errors)
    (flycheck-list-errors))
   (t
    (message "No diagnostics UI available."))))

(defun init/rust--server-missing-warning ()
  "Warn if rust-analyzer is not available in PATH."
  (unless (executable-find init/rust-analyzer-command)
    (display-warning
     'rust
     (format "%s not found in PATH. Install rust-analyzer for Rust LSP support."
             init/rust-analyzer-command)
     :warning)))

(defun init/rust-project-root ()
  "Return the current Rust project root, or `default-directory'."
  (or (when (fboundp 'project-current)
        (when-let ((project (project-current nil)))
          (project-root project)))
      default-directory))

(defun init/rust-run ()
  "Save the current buffer and run `cargo run' from the project root."
  (interactive)
  (save-buffer)
  (let ((default-directory (init/rust-project-root)))
    (compile "cargo run")))

(defun init/rust-add-module-definition ()
  "Offer Rust quick fixes, including module definition fixes."
  (interactive)
  (if (fboundp 'eglot-code-action-quickfix)
      (call-interactively #'eglot-code-action-quickfix)
    (call-interactively #'eglot-code-actions)))

(defun init/rust-setup ()
  "Set up Rust editing, LSP and diagnostics in current buffer."
  (init/rust--ensure-cargo-bin-in-path)
  (init/rust--server-missing-warning)
  (when (fboundp 'eglot-ensure)
    (eglot-ensure))
  (local-set-key (kbd "C-c l h") #'init/rust-hover-doc)
  (local-set-key (kbd "C-c l d") #'init/rust-show-diagnostics)
  (local-set-key (kbd "C-c l r") #'eglot-reconnect)
  (local-set-key (kbd "C-c m") #'init/rust-add-module-definition)
  (local-set-key (kbd "<f5>") #'init/rust-run)
  (local-set-key (kbd "M-RET") #'eglot-code-actions)
  (local-set-key (kbd "M-.") #'xref-find-definitions)
  (local-set-key (kbd "M-,") #'xref-go-back))

(use-package rust-mode
  :mode ("\\.rs\\'" . rust-mode)
  :hook (rust-mode . init/rust-setup))

(defun init/rust--treesit-ready-p ()
  "Return non-nil when Rust tree-sitter support is available."
  (and (fboundp 'treesit-ready-p)
       (treesit-ready-p 'rust)))

(when (and (fboundp 'rust-ts-mode)
           (init/rust--treesit-ready-p))
  (add-to-list 'auto-mode-alist '("\\.rs\\'" . rust-ts-mode))
  (add-hook 'rust-ts-mode-hook #'init/rust-setup))

(use-package eglot
  :ensure nil
  :commands (eglot eglot-ensure eglot-code-actions)
  :config
  (init/rust--ensure-cargo-bin-in-path)
  (add-to-list 'eglot-server-programs
               `((rust-mode rust-ts-mode) . (,init/rust-analyzer-command))))

(provide 'rust)
;;; rust.el ends here
