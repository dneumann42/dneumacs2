;;; lua.el --- Lua language support -*- lexical-binding: t; -*-

(defgroup init/lua nil
  "Lua editing support."
  :group 'languages)

(defcustom init/lua-lsp-server-command "lua-language-server"
  "Command used to start the Lua language server."
  :type 'string
  :group 'init/lua)

(defun init/lua-hover-doc ()
  "Show documentation for symbol at point."
  (interactive)
  (cond
   ((fboundp 'eglot-help-at-point)
    (eglot-help-at-point))
   ((fboundp 'eldoc-print-current-symbol-info)
    (eldoc-print-current-symbol-info))
   (t
    (message "No hover documentation command available."))))

(defun init/lua-show-diagnostics ()
  "Show diagnostics at point, preferring popup UI."
  (interactive)
  (cond
   ((fboundp 'flycheck-posframe-show-posframe)
    (flycheck-posframe-show-posframe))
   ((fboundp 'flycheck-list-errors)
    (flycheck-list-errors))
   (t
    (message "No diagnostics UI available."))))

(defun init/lua--server-missing-warning ()
  "Warn if the configured Lua language server is not available in PATH."
  (unless (executable-find init/lua-lsp-server-command)
    (display-warning
     'lua
     (format "%s not found in PATH. Install lua-language-server for Lua LSP support."
             init/lua-lsp-server-command)
     :warning)))

(defun init/lua-format-buffer-on-save ()
  "Format the current buffer with Eglot when a Lua LSP server is attached."
  (when (and (fboundp 'eglot-managed-p)
             (eglot-managed-p)
             (fboundp 'eglot-format-buffer))
    (eglot-format-buffer)))

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
  (init/lua--server-missing-warning)
  (when (fboundp 'eglot-ensure)
    (eglot-ensure))
  (when (bound-and-true-p flymake-mode)
    (flymake-mode -1))
  (when (fboundp 'flycheck-mode)
    (flycheck-mode 1))
  (add-hook 'before-save-hook #'init/lua-format-buffer-on-save nil t)
  (local-set-key (kbd "C-c l h") #'init/lua-hover-doc)
  (local-set-key (kbd "C-c l d") #'init/lua-show-diagnostics)
  (local-set-key (kbd "C-c l r") #'eglot-reconnect)
  (local-set-key (kbd "M-RET") #'eglot-code-actions)
  (local-set-key (kbd "M-.") #'xref-find-definitions)
  (local-set-key (kbd "M-,") #'xref-go-back))

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

(use-package eglot
  :ensure nil
  :commands (eglot eglot-ensure eglot-code-actions)
  :config
  (add-to-list 'eglot-server-programs
               `((lua-mode lua-ts-mode) . (,init/lua-lsp-server-command))))

(provide 'lua)
;;; lua.el ends here
