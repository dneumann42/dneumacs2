;;; c-tools.el --- C language support -*- lexical-binding: t; -*-

(defun init/c-hover-doc ()
  "Show documentation for symbol at point."
  (interactive)
  (cond
   ((fboundp 'eglot-help-at-point)
    (eglot-help-at-point))
   ((fboundp 'eldoc-print-current-symbol-info)
    (eldoc-print-current-symbol-info))
   (t
    (message "No hover documentation command available."))))

(defun init/c-show-diagnostics ()
  "Show diagnostics at point, preferring popup UI."
  (interactive)
  (cond
   ((fboundp 'flycheck-posframe-show-posframe)
    (flycheck-posframe-show-posframe))
   ((fboundp 'flycheck-list-errors)
    (flycheck-list-errors))
   (t
    (message "No diagnostics UI available."))))

(defun init/c--server-missing-warning ()
  "Warn if clangd is not available in PATH."
  (unless (executable-find "clangd")
    (display-warning
     'c
     "clangd not found in PATH. Install clangd for C LSP support."
     :warning)))

(defun init/c-format-buffer-on-save ()
  "Format the current buffer with Eglot when a C/C++ LSP server is attached."
  (when (and (fboundp 'eglot-managed-p)
             (eglot-managed-p)
             (fboundp 'eglot-format-buffer))
    (eglot-format-buffer)))

(defun init/c-setup ()
  "Set up C editing, LSP and diagnostics in current buffer."
  (when (derived-mode-p 'c-mode)
    (c-set-style "linux"))
  (setq-local c-basic-offset 4)
  (when (boundp 'c-ts-mode-indent-offset)
    (setq-local c-ts-mode-indent-offset 4))
  (setq-local tab-width 4)
  (setq-local indent-tabs-mode nil)
  (init/c--server-missing-warning)
  (when (fboundp 'eglot-ensure)
    (eglot-ensure))
  (when (bound-and-true-p flymake-mode)
    (flymake-mode -1))
  (when (fboundp 'flycheck-mode)
    (flycheck-mode 1))
  (add-hook 'before-save-hook #'init/c-format-buffer-on-save nil t)
  (local-set-key (kbd "C-c l h") #'init/c-hover-doc)
  (local-set-key (kbd "C-c l d") #'init/c-show-diagnostics)
  (local-set-key (kbd "M-RET") #'eglot-code-actions)
  (local-set-key (kbd "M-.") #'xref-find-definitions)
  (local-set-key (kbd "M-,") #'xref-go-back))

(use-package cc-mode
  :ensure nil
  :mode (("\\.c\\'" . c-mode)
         ("\\.h\\'" . c-mode))
  :hook ((c-mode c++-mode) . init/c-setup))

(add-hook 'c-ts-mode-hook #'init/c-setup)
(add-hook 'c++-ts-mode-hook #'init/c-setup)

(use-package eglot
  :ensure nil
  :commands (eglot eglot-ensure eglot-code-actions)
  :config
  (add-to-list 'eglot-server-programs
               '((c-mode c++-mode c-ts-mode c++-ts-mode) . ("clangd"))))

(use-package flycheck
  :defer t)

(use-package flycheck-eglot
  :after (flycheck eglot)
  :hook (eglot-managed-mode . flycheck-eglot-mode))

(use-package flycheck-posframe
  :after flycheck
  :hook (flycheck-mode . flycheck-posframe-mode)
  :custom
  (flycheck-posframe-position 'window-bottom-left-corner))

(provide 'c-tools)
;;; c-tools.el ends here
