;;; init-scheme.el --- Scheme/Lisp tooling -*- lexical-binding: t; -*-

(require 'seq)

(use-package geiser
  :ensure t
  :custom
  (geiser-active-implementations '(guile chicken))
  (geiser-repl-history-filename "~/.emacs.d/geiser-history"))

(with-eval-after-load 'geiser-repl
  ;; geiser-chicken has no debugger prompt.  Geiser 20260509 still tries
  ;; to match it unconditionally in the REPL output filter, which makes
  ;; loading files fail with "Wrong type argument: stringp, nil".
  (defun geiser-repl--matches-prompt-p (txt)
    (or (when-let ((prompt (geiser-con--connection-prompt
                            geiser-repl--connection)))
          (string-match-p prompt txt))
        (when-let ((debug-prompt (geiser-con--connection-debug-prompt
                                  geiser-repl--connection)))
          (string-match-p debug-prompt txt)))))

(use-package geiser-guile
  :ensure t
  :after geiser
  :custom
  (geiser-guile-binary "guile3.0"))

(use-package geiser-chicken
  :ensure t
  :after geiser
  :custom
  (geiser-chicken-binary "chicken-csi"))

(use-package paredit
  :ensure t
  :hook
  ((emacs-lisp-mode . paredit-mode)
   (eval-expression-minibuffer-setup . paredit-mode)
   (ielm-mode . paredit-mode)
   (lisp-mode . paredit-mode)
   (lisp-interaction-mode . paredit-mode)
   (scheme-mode . paredit-mode)))

(use-package paren-face
  :ensure t
  :hook (scheme-mode . paren-face-mode))

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
        (my/static-chicken-install-repl-reuse)
        (when (fboundp 'static-chicken-mode)
          (static-chicken-mode 1))))))

(defun my/static-chicken-repl-buffer-p (buffer)
  (string-match-p
   "\\`\\*\\(?:static-chicken-repl\\|Geiser.*REPL\\).*\\*"
   (buffer-name buffer)))

(defun my/static-chicken-clean-stale-repl-buffers (keep)
  (dolist (buffer (buffer-list))
    (when (and (not (eq buffer keep))
               (my/static-chicken-repl-buffer-p buffer)
               (not (process-live-p (get-buffer-process buffer))))
      (kill-buffer buffer))))

(defun my/static-chicken-live-repl-buffer ()
  (seq-find
   (lambda (buffer)
     (and (my/static-chicken-repl-buffer-p buffer)
          (process-live-p (get-buffer-process buffer))))
   (buffer-list)))

(defun my/static-chicken-install-repl-reuse ()
  (when (and (featurep 'static-chicken)
             (not (get 'my/static-chicken-install-repl-reuse 'installed)))
    (put 'my/static-chicken-install-repl-reuse 'installed t)
    (advice-add
     'static-chicken-connect-repl
     :around
     (lambda (orig &rest args)
       (let ((existing (or (get-buffer "*static-chicken-repl*")
                           (my/static-chicken-live-repl-buffer))))
         (my/static-chicken-clean-stale-repl-buffers existing)
         (if (and existing
                  (process-live-p (get-buffer-process existing)))
             (pop-to-buffer existing)
           (when (get-buffer "*static-chicken-repl*")
             (kill-buffer "*static-chicken-repl*"))
           (apply orig args)))))))

(add-hook 'scheme-mode-hook #'my/static-chicken-maybe-enable)

(provide 'init-scheme)
;;; init-scheme.el ends here
