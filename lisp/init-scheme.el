;;; init-scheme.el --- Scheme/Lisp tooling -*- lexical-binding: t; -*-

(use-package geiser
  :ensure t
  :custom
  (geiser-active-implementations '(guile))
  (geiser-repl-history-filename "~/.emacs.d/geiser-history"))

(use-package geiser-guile
  :ensure t
  :after geiser
  :custom
  (geiser-guile-binary "guile3.0"))

(use-package paredit
  :ensure t
  :hook
  ((emacs-lisp-mode . paredit-mode)
   (eval-expression-minibuffer-setup . paredit-mode)
   (ielm-mode . paredit-mode)
   (lisp-mode . paredit-mode)
   (lisp-interaction-mode . paredit-mode)
   (scheme-mode . paredit-mode)))

(provide 'init-scheme)
;;; init-scheme.el ends here
