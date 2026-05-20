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

;; static-chicken: load the editor helper shipped with a static-chicken app
;; whenever we open a .scm file inside one. Walks up from the buffer file
;; looking for vendor/static-chicken/editor/static-chicken.el; if found,
;; loads it and turns on static-chicken-mode (binds C-c C-c to save +
;; reload via the app's TCP REPL).
(defun my/static-chicken-maybe-enable ()
  (when buffer-file-name
    (when-let* ((root (locate-dominating-file
                       buffer-file-name
                       "vendor/static-chicken/editor/static-chicken.el"))
                (lib (expand-file-name
                      "vendor/static-chicken/editor/static-chicken.el"
                      root)))
      (when (file-exists-p lib)
        (add-to-list 'load-path (file-name-directory lib))
        (require 'static-chicken nil 'noerror)
        (when (fboundp 'static-chicken-mode)
          (static-chicken-mode 1))))))

(add-hook 'scheme-mode-hook #'my/static-chicken-maybe-enable)

(provide 'init-scheme)
;;; init-scheme.el ends here
