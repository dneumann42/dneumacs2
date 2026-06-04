;;; nim.el --- Nim language support -*- lexical-binding: t; -*-

(defun init/nim-hover-doc ()
  "Show documentation for symbol at point."
  (interactive)
  (cond
   ((fboundp 'eglot-help-at-point)
    (eglot-help-at-point))
   ((fboundp 'eldoc-print-current-symbol-info)
    (eldoc-print-current-symbol-info))
   (t
    (message "No hover documentation command available."))))

(defun init/nim-show-diagnostics ()
  "Show diagnostics at point, preferring popup UI."
  (interactive)
  (cond
   ((fboundp 'flycheck-posframe-show-posframe)
    (flycheck-posframe-show-posframe))
   ((fboundp 'flycheck-list-errors)
    (flycheck-list-errors))
   (t
    (message "No diagnostics UI available."))))

(defun init/nim--server-missing-warning ()
  "Warn if nimlangserver is not available in PATH."
  (unless (executable-find "nimlangserver")
    (display-warning
     'nim
     "nimlangserver not found in PATH. Install with: nimble install nimlangserver"
     :warning)))

(defun init/nim-setup ()
  "Set up Nim editing, LSP and diagnostics in current buffer."
  (init/nim--server-missing-warning)
  (when (fboundp 'eglot-ensure)
    (eglot-ensure))
  (when (bound-and-true-p flymake-mode)
    (flymake-mode -1))
  (when (fboundp 'flycheck-mode)
    (flycheck-mode 1))
  (local-set-key (kbd "C-c l h") #'init/nim-hover-doc)
  (local-set-key (kbd "C-c l d") #'init/nim-show-diagnostics)
  (local-set-key (kbd "M-RET") #'eglot-code-actions)
  (local-set-key (kbd "M-.") #'xref-find-definitions)
  (local-set-key (kbd "M-,") #'xref-go-back))

(use-package nim-mode
  :mode ("\\.nim\\'" "\\.nims\\'" "\\.nimble\\'")
  :hook (nim-mode . init/nim-setup))

(use-package eglot
  :ensure nil
  :commands (eglot eglot-ensure eglot-code-actions)
  :config
  (add-to-list 'eglot-server-programs '(nim-mode "nimlangserver")))

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

(provide 'nim)
;;; nim.el ends here
