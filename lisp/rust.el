;;; rust.el --- Rust language support -*- lexical-binding: t; -*-

(defgroup init/rust nil
  "Rust editing support."
  :group 'languages)

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
  (unless (executable-find "rust-analyzer")
    (display-warning
     'rust
     "rust-analyzer not found in PATH. Install rust-analyzer for Rust LSP support."
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

(defcustom init/rust-auto-reconnect-on-save t
  "Reconnect rust-analyzer automatically after saving Rust workspace files."
  :type 'boolean
  :group 'init/rust)

(defun init/rust--workspace-file-p ()
  "Return non-nil when the current buffer is a Rust workspace file."
  (let ((file (buffer-file-name)))
    (and file
         (or (string-match-p "\\.rs\\'" file)
             (string-match-p "/Cargo\\.toml\\'" file)
             (string-match-p "/build\\.rs\\'" file)))))

(defun init/rust--reconnect-after-save ()
  "Reconnect rust-analyzer after saving Rust workspace files.
This helps when rust-analyzer keeps stale analysis around after Cargo or
source edits."
  (when (and init/rust-auto-reconnect-on-save
             (init/rust--workspace-file-p)
             (fboundp 'eglot-current-server)
             (eglot-current-server)
             (fboundp 'eglot-reconnect))
    (eglot-reconnect (eglot-current-server))))

(defun init/rust-setup ()
  "Set up Rust editing, LSP and diagnostics in current buffer."
  (init/rust--server-missing-warning)
  (when (fboundp 'eglot-ensure)
    (eglot-ensure))
  (add-hook 'after-save-hook #'init/rust--reconnect-after-save nil t)
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
  (add-to-list 'eglot-server-programs
               '((rust-mode rust-ts-mode) . ("rust-analyzer"))))

(provide 'rust)
;;; rust.el ends here
