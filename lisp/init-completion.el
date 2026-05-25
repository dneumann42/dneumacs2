;;; init-completion.el --- Minibuffer/completion UX -*- lexical-binding: t; -*-

(use-package savehist
  :ensure nil
  :init
  (savehist-mode 1))

(use-package vertico
  :init
  (vertico-mode 1)
  :custom
  (vertico-cycle t)
  :bind
  (:map vertico-map
        ("C-j" . vertico-next)
        ("C-k" . vertico-previous)
        ("C-f" . vertico-exit)
        ("M-RET" . vertico-exit-input)))

(use-package orderless
  :custom
  (completion-styles '(orderless basic))
  (completion-category-defaults nil)
  (completion-category-overrides '((file (styles partial-completion)))))

(use-package marginalia
  :init
  (marginalia-mode 1))

(use-package consult
  :bind (("C-s" . consult-line)
         ("C-c h" . consult-history)
         ("C-c m" . consult-mode-command)
         ("C-x /" . consult-ripgrep)
         ("C-x b" . consult-buffer)
         ("C-x 4 b" . consult-buffer-other-window)
         ("M-y" . consult-yank-pop)
         ("M-g g" . consult-goto-line)
         ("M-g i" . consult-imenu)
         ("M-s r" . consult-ripgrep)))

;; Embark warns if Consult is loaded and this integration is missing.
;; Preload it when available so startup stays clean.
(when (locate-library "embark-consult")
  (require 'embark-consult nil t))

(use-package embark
  :bind (("C-." . embark-act)
         ("C-;" . embark-dwim)
         ("C-h B" . embark-bindings))
  :init
  (setq prefix-help-command #'embark-prefix-help-command))

(use-package embark-consult
  :after (embark consult))

(provide 'init-completion)
;;; init-completion.el ends here
