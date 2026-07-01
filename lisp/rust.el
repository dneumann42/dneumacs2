;;; rust.el --- Rust language support -*- lexical-binding: t; -*-

(defgroup init/rust nil
  "Rust editing support."
  :group 'languages)

(defcustom init/rust-cargo-bin-directory
  (expand-file-name ".cargo/bin" (getenv "HOME"))
  "Directory containing Cargo-installed Rust tools."
  :type 'directory
  :group 'init/rust)

;; `init/rust-analyzer-command' is defined centrally in init-lsp.el.

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
  (init/ide--warn-missing-server init/rust-analyzer-command
                                 "Install rust-analyzer for Rust LSP support.")
  (when (fboundp 'eglot-ensure)
    (eglot-ensure))
  ;; Hover, diagnostics, actions, reconnect and format use shared defaults.
  (setq-local init/ide-run-function #'init/rust-run
              init/ide-fix-function #'init/rust-add-module-definition)
  (init/ide-mode 1))

(use-package rust-mode
  :mode ("\\.rs\\'" . rust-mode)
  :hook (rust-mode . init/rust-setup))

(defun init/rust--treesit-ready-p ()
  "Return non-nil when Rust tree-sitter support is available."
  (and (fboundp 'treesit-language-available-p)
       (treesit-language-available-p 'rust)))

(when (and (fboundp 'rust-ts-mode)
           (init/rust--treesit-ready-p))
  (add-to-list 'auto-mode-alist '("\\.rs\\'" . rust-ts-mode))
  (add-hook 'rust-ts-mode-hook #'init/rust-setup))

(provide 'rust)
;;; rust.el ends here
