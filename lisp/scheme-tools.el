;;; scheme-tools.el --- Scheme/Lisp tooling -*- lexical-binding: t; -*-

(require 'seq)
(require 'cl-lib)

(defun my/paredit-transpose-sexps-backward ()
  (interactive)
  (transpose-sexps -1))

(with-eval-after-load 'paredit
  (define-key paredit-mode-map (kbd "C-M-S-t")
              #'my/paredit-transpose-sexps-backward))

(global-set-key (kbd "C-x z") #'repeat)

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
  (geiser-guile-binary "guile"))

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

(defconst my/static-chicken-repl-frame-name "static-chicken REPL")

(defun my/static-chicken-repl-frame ()
  (seq-find
   (lambda (frame)
     (frame-parameter frame 'my/static-chicken-repl-frame))
   (frame-list)))

(defun my/static-chicken-swaymsg (&rest args)
  "Run swaymsg with ARGS, ignoring errors outside Sway."
  (when (executable-find "swaymsg")
    (ignore-errors
      (apply #'call-process "swaymsg" nil nil nil args))))

(defun my/static-chicken-mark-emacs-frame-for-sway ()
  "Mark the current Emacs frame as the Sway anchor for static-chicken windows."
  (my/static-chicken-swaymsg "--" "mark" "--add" "static-chicken-emacs-main"))

(defun my/static-chicken-arrange-sway-windows ()
  "Ask Sway to group the static-chicken REPL and app windows."
  (my/static-chicken-swaymsg
   "exec"
   "/home/dneumann/.config/sway/scripts/static-chicken-layout.sh"))

(defun my/static-chicken-pop-to-repl-frame (buffer-or-name)
  "Show BUFFER-OR-NAME in a dedicated static-chicken REPL frame."
  (let ((buffer (get-buffer-create buffer-or-name))
        window)
    (condition-case nil
        (progn
          (my/static-chicken-mark-emacs-frame-for-sway)
          (let ((frame (or (my/static-chicken-repl-frame)
                           (make-frame
                            `((name . ,my/static-chicken-repl-frame-name)
                              (title . ,my/static-chicken-repl-frame-name)
                              (alpha-background . 85)
                              (my/static-chicken-repl-frame . t))))))
            (setq window (frame-selected-window frame))
            (set-window-buffer window buffer))
          (select-frame-set-input-focus (window-frame window))
          (select-window window)
          (my/static-chicken-arrange-sway-windows)
          buffer)
      (error
       (switch-to-buffer buffer)
       buffer))))

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
             (my/static-chicken-pop-to-repl-frame existing)
           (when (get-buffer "*static-chicken-repl*")
             (kill-buffer "*static-chicken-repl*"))
           (cl-letf (((symbol-function 'pop-to-buffer)
                      (lambda (buffer-or-name &optional _action _norecord)
                        (my/static-chicken-pop-to-repl-frame buffer-or-name))))
             (apply orig args))))))))

;; ── g-golf / Guile GTK live coding ──────────────────────────

(defcustom my/g-golf-guile-repl-port 37146
  "TCP port for the running G-Golf Guile REPL server."
  :type 'integer
  :group 'geiser)

(defun my/g-golf-guile-connect (&optional host port)
  "Connect Geiser to a running G-Golf Guile REPL server.
Default HOST is 127.0.0.1, default PORT is `my/g-golf-guile-repl-port'."
  (interactive)
  (let ((host (or host "127.0.0.1"))
        (port (or port my/g-golf-guile-repl-port)))
    (geiser-connect 'guile host port)))

(defun my/g-golf-project-root (&optional dir)
  "Return the g-golf project root directory, or nil.
Looks for a .envrc containing \"g-golf\" when walking up from DIR."
  (when-let* ((dir (or dir (and buffer-file-name
                                (file-name-directory buffer-file-name))))
              (root (locate-dominating-file dir ".envrc")))
    (when root
      (with-temp-buffer
        (insert-file-contents (expand-file-name ".envrc" root))
        (when (save-excursion (search-forward "g-golf" nil t))
          root)))))

(defun my/g-golf-reload ()
  "Save buffer and send (reload) to the connected Geiser REPL."
  (interactive)
  (save-buffer)
  (require 'geiser-repl nil 'noerror)
  (if-let* ((repl (geiser-repl--repl/impl 'guile)))
      (with-current-buffer repl
        (geiser-repl--send "(reload)" t))
    (user-error "No Geiser REPL connected. Use C-c C-g first")))

(defun my/g-golf-install-override ()
  "Buffer-local override of C-c C-c in geiser-mode-map for g-golf projects."
  (when (my/g-golf-project-root)
    (make-local-variable 'geiser-mode-map)
    (define-key geiser-mode-map (kbd "C-c C-c") #'my/g-golf-reload)))

(defun my/g-golf-maybe-enable ()
  "Enable G-Golf integration when visiting a g-golf project file.
Binds C-c C-g to connect,  C-c C-c to reload UI (via geiser-mode-hook)."
  (when (and buffer-file-name (my/g-golf-project-root))
    (local-set-key (kbd "C-c C-g") #'my/g-golf-guile-connect)))

(add-hook 'scheme-mode-hook #'my/static-chicken-maybe-enable)
(add-hook 'scheme-mode-hook #'my/g-golf-maybe-enable)
(add-hook 'geiser-mode-hook #'my/g-golf-install-override)

(provide 'scheme-tools)
;;; scheme-tools.el ends here
