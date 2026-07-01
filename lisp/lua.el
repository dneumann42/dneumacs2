;;; lua.el --- Lua language support -*- lexical-binding: t; -*-

;; `init/lua-lsp-server-command' is defined centrally in init-lsp.el.

(defun init/lua-setup ()
  "Set up Lua editing, LSP and diagnostics in current buffer."
  (setq-local lua-indent-level 4)
  (when (boundp 'lua-ts-mode-indent-offset)
    (setq-local lua-ts-mode-indent-offset 4))
  (setq-local tab-width 4)
  (setq-local indent-tabs-mode nil)
  (setq-local eglot-workspace-configuration
              '(("Lua" . (("format" . (("defaultConfig" . (("indent_style" . "space")
                                                            ("indent_size" . "4")))))))))
  (init/ide--warn-missing-server init/lua-lsp-server-command
                                 "Install lua-language-server for Lua LSP support.")
  (when (fboundp 'eglot-ensure)
    (eglot-ensure))
  (when (bound-and-true-p flymake-mode)
    (flymake-mode -1))
  (when (fboundp 'flycheck-mode)
    (flycheck-mode 1))
  (add-hook 'before-save-hook #'init/ide-eglot-format-on-save nil t)
  ;; All IDE actions use the shared Eglot defaults.
  (init/ide-mode 1))

(use-package lua-mode
  :mode (("\\.lua\\'" . lua-mode)
         ("\\.rockspec\\'" . lua-mode))
  :interpreter ("lua" . lua-mode)
  :hook (lua-mode . init/lua-setup))

(defun init/lua--treesit-ready-p ()
  "Return non-nil when Lua tree-sitter support is available."
  (and (fboundp 'treesit-language-available-p)
       (treesit-language-available-p 'lua)))

(when (and (fboundp 'lua-ts-mode)
           (init/lua--treesit-ready-p))
  (add-to-list 'auto-mode-alist '("\\.lua\\'" . lua-ts-mode))
  (add-hook 'lua-ts-mode-hook #'init/lua-setup))

(provide 'lua)
;;; lua.el ends here
