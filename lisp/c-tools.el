;;; c-tools.el --- C language support -*- lexical-binding: t; -*-

(defun init/c-setup ()
  "Set up C editing, LSP and diagnostics in current buffer."
  (when (derived-mode-p 'c-mode)
    (c-set-style "linux"))
  (setq-local c-basic-offset 4)
  (when (boundp 'c-ts-mode-indent-offset)
    (setq-local c-ts-mode-indent-offset 4))
  (setq-local tab-width 4)
  (setq-local indent-tabs-mode nil)
  (init/ide--warn-missing-server "clangd" "Install clangd for C LSP support.")
  (when (fboundp 'eglot-ensure)
    (eglot-ensure))
  (when (bound-and-true-p flymake-mode)
    (flymake-mode -1))
  (when (fboundp 'flycheck-mode)
    (flycheck-mode 1))
  (add-hook 'before-save-hook #'init/ide-eglot-format-on-save nil t)
  ;; All IDE actions use the shared Eglot defaults.
  (init/ide-mode 1))

(use-package cc-mode
  :ensure nil
  :mode (("\\.c\\'" . c-mode)
         ("\\.h\\'" . c-mode))
  :hook ((c-mode c++-mode) . init/c-setup))

(add-hook 'c-ts-mode-hook #'init/c-setup)
(add-hook 'c++-ts-mode-hook #'init/c-setup)

(provide 'c-tools)
;;; c-tools.el ends here
