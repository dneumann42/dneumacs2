;;; init-common-lisp.el --- Common Lisp tooling (SLY + SBCL) -*- lexical-binding: t; -*-

;; SLY connects to SBCL and injects its own Slynk server, so no
;; Lisp-side setup is needed. Quicklisp is loaded via ~/.sbclrc, and
;; ASDF finds projects registered in
;; ~/.config/common-lisp/source-registry.conf.d/, so from the REPL:
;;   (ql:quickload :cl-core)

(use-package sly
  :ensure t
  :custom
  (inferior-lisp-program "sbcl")
  :config
  ;; Plain defvar in sly.el (not a defcustom), so :custom silently
  ;; fails to apply it -- must be set with setq.
  (setq sly-lisp-implementations
        '((sbcl ("sbcl" "--dynamic-space-size" "4096")))))

;; Structural editing in the SLY REPL too (file buffers are covered by
;; the lisp-mode paredit hook in init-scheme.el).
(defun init/sly-mrepl-paredit ()
  "Enable paredit in the SLY REPL, keeping RET as submit.
paredit >= 25 binds RET in its minor-mode map, which shadows the
major-mode map (`local-set-key' is not enough), so shadow it back
via `minor-mode-overriding-map-alist'."
  (paredit-mode 1)
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map paredit-mode-map)
    (define-key map (kbd "RET") #'sly-mrepl-return)
    (setq-local minor-mode-overriding-map-alist
                `((paredit-mode . ,map)))))

(with-eval-after-load 'sly-mrepl
  (add-hook 'sly-mrepl-mode-hook #'init/sly-mrepl-paredit))

(provide 'init-common-lisp)
;;; init-common-lisp.el ends here
