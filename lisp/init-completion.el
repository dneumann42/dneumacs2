;;; init-completion.el --- Minibuffer and in-buffer completion -*- lexical-binding: t; -*-

;;; Commentary:

;; The completion stack, minibuffer first:
;;
;;   vertico     vertical candidate list in the minibuffer
;;   orderless   space-separated, order-independent matching
;;   marginalia  annotations beside each candidate
;;   consult     search and jump commands built on completing-read
;;   embark      act on the candidate, or on the thing at point
;;
;; and in the buffer:
;;
;;   corfu       completion popup at point, with a documentation panel
;;   cape        extra completion-at-point sources merged into Corfu
;;   yasnippet   snippet expansion
;;   which-key   shows what follows a half-typed prefix

;;; Code:

(declare-function init/project-search-live "init-projects")

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
  :bind (:map vertico-map
              ("C-j" . vertico-next)
              ("C-p" . vertico-previous)
              ("C-f" . vertico-exit)
              ("M-RET" . vertico-exit-input)))

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
  ;; loads first wins harmlessly.  Without this, the (car ...) below is a
  ;; void-variable error when consult has not been loaded yet.
  (defvar consult--line-history nil
    "History of `consult-line' searches; see consult's own definition.")
  (defun init/consult-line-repeat ()
    "Search lines in this buffer, offering the most recent search first."
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
  ;; Documentation popup next to the highlighted candidate.
  (corfu-popupinfo-mode 1))

(use-package cape
  :init
  (add-hook 'completion-at-point-functions #'cape-file)
  (add-hook 'completion-at-point-functions #'cape-dabbrev))

(use-package yasnippet
  :ensure t
  :custom
  (yas-snippet-dirs (list (expand-file-name "snippets" user-emacs-directory)))
  (yas-prompt-functions '(yas-completing-prompt yas-no-prompt))
  :bind (("C-c ." . yas-insert-snippet))
  :hook ((text-mode prog-mode conf-mode snippet-mode org-mode)
         . yas-minor-mode-on)
  :config
  ;; Org already owns C-c . (timestamps) and TAB (cycling).
  (with-eval-after-load 'org
    (define-key org-mode-map (kbd "C-c y") #'yas-insert-snippet)
    (define-key org-mode-map (kbd "M-TAB") #'yas-expand)))

(use-package yasnippet-snippets
  :ensure t
  :after (yasnippet))

;; which-key ships with Emacs 30; use the built-in copy.  Enabling it from
;; an idle timer keeps its keymap scan off the startup path.
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

(provide 'init-completion)
;;; init-completion.el ends here
