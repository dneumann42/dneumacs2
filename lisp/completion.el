;;; completion.el --- Minibuffer/completion UX -*- lexical-binding: t; -*-

(use-package savehist
  :ensure nil
  :init
  (savehist-mode 1))

(use-package vertico
  :ensure t
  :init
  (vertico-mode 1)
  :custom
  (vertico-cycle t)
  :bind
  (:map vertico-map
        ("C-j" . vertico-next)
        ("C-p" . vertico-previous)
        ("C-f" . vertico-exit)
        ("M-RET" . vertico-exit-input)))

(use-package corfu
  :ensure t
  :custom
  (corfu-auto t)
  (corfu-auto-prefix 3)
  (corfu-auto-delay 0.2)
  (corfu-popupinfo-delay '(0.75 . 0.3))
  :init
  (global-corfu-mode 1)
  :config
  ;; Documentation popup next to the completion candidate.
  (corfu-popupinfo-mode 1))

;; Extra completion-at-point sources merged into Corfu.
(use-package cape
  :init
  (add-hook 'completion-at-point-functions #'cape-file)
  (add-hook 'completion-at-point-functions #'cape-dabbrev))

(use-package orderless
  :ensure t
  :custom
  (completion-styles '(orderless basic))
  (completion-category-defaults nil)
  (completion-category-overrides '((file (styles partial-completion)))))

(use-package marginalia
  :ensure t
  :init
  (marginalia-mode 1))

(use-package consult
  :ensure t
  :preface
  ;; Same name and initial value as consult's own defvar, so whichever
  ;; loads first wins harmlessly.  Without this, the (car ...) below
  ;; would be a void-variable error when consult is not yet loaded.
  (defvar consult--line-history nil)
  (defun init/consult-line-repeat ()
    "Search lines, initially reusing the most recent line search."
    (interactive)
    (consult-line (car consult--line-history)))
  :bind (("C-s" . init/consult-line-repeat)
         ("C-c h" . consult-history)
         ("C-c m" . consult-mode-command)
         ("C-x /" . init/project-search-live)
         ("C-x b" . consult-buffer)
         ("C-x 4 b" . consult-buffer-other-window)
         ("M-y" . consult-yank-pop)
         ("M-g g" . consult-goto-line)
         ("M-g i" . consult-imenu)
         ("M-s r" . consult-ripgrep)))

(use-package embark
  :ensure t
  :bind (("C-." . embark-act)
         ("C-;" . embark-dwim)
         ("C-h B" . embark-bindings))
  :init
  (setq prefix-help-command #'embark-prefix-help-command))

(use-package embark-consult
  :ensure t
  :after (embark consult))

(use-package yasnippet
  :ensure t
  :custom
  (yas-snippet-dirs '("~/.emacs.d/snippets"))
  :bind (("C-c ." . yas-insert-snippet))
  :hook ((text-mode
          prog-mode
          conf-mode
          snippet-mode) . yas-minor-mode-on))

(use-package yasnippet-snippets
  :ensure t
  :after (yasnippet))

;; which-key ships with Emacs 30; use the built-in copy.
(use-package which-key
  :ensure nil
  :commands (which-key-mode)
  :custom
  (which-key-idle-delay 0.35)
  (which-key-idle-secondary-delay 0.05)
  (which-key-sort-order 'which-key-key-order-alpha)
  (which-key-max-description-length 40)
  :init
  (run-with-idle-timer 1 nil #'which-key-mode))

(provide 'completion)
;;; completion.el ends here
