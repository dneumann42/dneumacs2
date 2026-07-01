;;; init-common-lisp.el --- Common Lisp tooling (SLY + SBCL) -*- lexical-binding: t; -*-

;; SLY connects to SBCL and injects its own Slynk server, so no
;; Lisp-side setup is needed. Quicklisp is loaded via ~/.sbclrc, and
;; ASDF finds projects registered in
;; ~/.config/common-lisp/source-registry.conf.d/, so from the REPL:
;;   (ql:quickload :cl-core)

(require 'cl-lib)
(require 'seq)

(use-package sly
  :ensure t
  :defer t
  :custom
  (inferior-lisp-program "sbcl")
  :config
  ;; Plain defvar in sly.el (not a defcustom), so :custom silently
  ;; fails to apply it -- must be set with setq.
  (setq sly-lisp-implementations
        '((sbcl ("sbcl" "--dynamic-space-size" "4096")))))

;;;; Alatar REPL frame management

(defconst my/alatar-repl-frame-name "alatar REPL"
  "Name given to the dedicated Alatar SLY REPL frame.")

(defun my/alatar-repl-buffer-p (buffer)
  "Return non-nil when BUFFER is a SLY mREPL buffer."
  (string-match-p "\\`\\*sly-mrepl" (buffer-name buffer)))

(defun my/alatar-live-repl-buffer ()
  "Return a SLY mREPL buffer with a live process, or nil."
  (seq-find
   (lambda (buffer)
     (and (my/alatar-repl-buffer-p buffer)
          (process-live-p (get-buffer-process buffer))))
   (buffer-list)))

(defun my/alatar-repl-frame ()
  "Return the dedicated Alatar REPL frame, or nil."
  (seq-find
   (lambda (frame)
     (frame-parameter frame 'my/alatar-repl-frame))
   (frame-list)))

(defun my/alatar-swaymsg (&rest args)
  "Run swaymsg with ARGS, ignoring errors outside Sway."
  (when (executable-find "swaymsg")
    (ignore-errors
      (apply #'call-process "swaymsg" nil nil nil args))))

(defun my/alatar-mark-emacs-frame-for-sway ()
  "Mark the current Emacs frame as the Sway anchor for Alatar."
  (my/alatar-swaymsg "--" "mark" "--add" "alatar-emacs-main"))

(defun my/alatar-arrange-sway-windows ()
  "Ask Sway to group the Alatar REPL and app windows."
  (my/alatar-swaymsg
   "exec"
   "/home/dneumann/.config/sway/scripts/alatar-layout.sh"))

(defun my/alatar-pop-to-repl-frame (buffer-or-name)
  "Show BUFFER-OR-NAME in a dedicated Alatar REPL frame."
  (let ((buffer (get-buffer-create buffer-or-name))
        window)
    (condition-case nil
        (progn
          (my/alatar-mark-emacs-frame-for-sway)
          (let ((frame (or (my/alatar-repl-frame)
                           (make-frame
                            `((name . ,my/alatar-repl-frame-name)
                              (title . ,my/alatar-repl-frame-name)
                              (alpha-background . 85)
                              (my/alatar-repl-frame . t))))))
            (setq window (frame-selected-window frame))
            (set-window-buffer window buffer))
          (select-frame-set-input-focus (window-frame window))
          (select-window window)
          (my/alatar-arrange-sway-windows)
          buffer)
      (error
       (switch-to-buffer buffer)
       buffer))))

(defun my/alatar-wrap-repl-display (orig display-action)
  "Advice for `sly-mrepl' routing display to the Alatar REPL frame.
ORIG is the wrapped function; DISPLAY-ACTION is ignored in favour of
`my/alatar-pop-to-repl-frame'."
  (funcall orig
           (lambda (buffer)
             (my/alatar-pop-to-repl-frame buffer))))

(defun my/alatar-wrap-repl-create (orig &rest args)
  "Advice for `sly-mrepl-new' popping the new REPL into the Alatar frame.
ORIG is the wrapped function and ARGS its arguments."
  (cl-letf (((symbol-function 'pop-to-buffer)
             (lambda (buffer-or-name &optional _action _norecord)
               (my/alatar-pop-to-repl-frame buffer-or-name))))
    (apply orig args)))

(with-eval-after-load 'sly-mrepl
  (unless (get 'my/alatar-wrap-repl-display 'installed)
    (put 'my/alatar-wrap-repl-display 'installed t)
    (advice-add 'sly-mrepl :around #'my/alatar-wrap-repl-display)
    (advice-add 'sly-mrepl-new :around #'my/alatar-wrap-repl-create)))

;;;; REPL structural editing

;; Structural editing in the SLY REPL too (file buffers are covered by
;; the lisp-mode paredit hook in scheme-tools.el).
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

;;;; Shared IDE keymap

(defun init/lisp-ide-setup ()
  "Enable the shared IDE keymap in Common Lisp buffers, mapped to SLY."
  (setq-local init/ide-hover-function #'sly-describe-symbol
              init/ide-actions-function #'sly-eval-defun
              init/ide-run-function #'sly-eval-buffer
              init/ide-repl-function #'sly-mrepl
              init/ide-diagnostics-function #'sly-goto-first-note
              init/ide-goto-definition-function #'sly-edit-definition
              init/ide-go-back-function #'sly-pop-find-definition-stack)
  (init/ide-mode 1))

(add-hook 'lisp-mode-hook #'init/lisp-ide-setup)

(provide 'init-common-lisp)
;;; init-common-lisp.el ends here
