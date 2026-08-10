;;; init-lang-lisp.el --- Emacs Lisp, Scheme and Common Lisp -*- lexical-binding: t; -*-

;;; Commentary:

;; The Lisp family, which shares structural editing (paredit), delimiter
;; colouring, and a REPL-centred workflow.
;;
;; Scheme goes through Geiser, with Guile and CHICKEN both configured.
;; The implementation chosen at a prompt is written into the repository's
;; .dir-locals.el, so it is only ever asked once per project.  Two project
;; integrations hook in: static-chicken applications, whose bundled editor
;; helper is loaded when one is opened, and G-Golf GTK projects, where
;; C-c C-c reloads the running UI.
;;
;; Common Lisp goes through SLY talking to SBCL.
;;
;; Both of those REPLs are put in a dedicated frame that Sway is asked to
;; place next to the running application, so editing and the live program
;; sit side by side.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'init-ide)

(declare-function geiser-con--connection-debug-prompt "geiser-connection")
(declare-function geiser-con--connection-prompt "geiser-connection")
(declare-function geiser-connect "geiser-repl")
(declare-function geiser-doc-symbol-at-point "geiser-doc")
(declare-function geiser-edit-symbol-at-point "geiser-edit")
(declare-function geiser-eval-buffer "geiser-eval")
(declare-function geiser-eval-definition "geiser-eval")
(declare-function geiser-mode-switch-to-repl "geiser-mode")
(declare-function geiser-repl--repl/impl "geiser-repl")
(declare-function geiser-repl--send "geiser-repl")
(declare-function sly-describe-symbol "sly")
(declare-function sly-edit-definition "sly")
(declare-function sly-eval-buffer "sly")
(declare-function sly-eval-defun "sly")
(declare-function sly-goto-first-note "sly")
(declare-function sly-mrepl "sly-mrepl")
(declare-function sly-mrepl-return "sly-mrepl")
(declare-function sly-pop-find-definition-stack "sly")
(declare-function static-chicken-mode "static-chicken")
(defvar geiser-mode-map)
(defvar geiser-repl--connection)
(defvar geiser-scheme-implementation)
(defvar paredit-mode-map)

;;;; Structural editing

(defun init/paredit-transpose-sexps-backward ()
  "Transpose the sexp before point with the one before it."
  (interactive)
  (transpose-sexps -1))

(use-package paredit
  :ensure t
  :hook ((emacs-lisp-mode
          eval-expression-minibuffer-setup
          ielm-mode
          lisp-mode
          lisp-interaction-mode
          scheme-mode)
         . paredit-mode)
  :config
  (define-key paredit-mode-map (kbd "C-M-S-t")
              #'init/paredit-transpose-sexps-backward))

(use-package paren-face
  :ensure t
  :hook (scheme-mode . paren-face-mode))

(use-package rainbow-delimiters
  :ensure t
  :hook ((emacs-lisp-mode
          lisp-mode
          lisp-interaction-mode
          scheme-mode
          ielm-mode)
         . rainbow-delimiters-mode))

;;;; REPLs in a dedicated, Sway-placed frame

;; A live-coding REPL is most useful beside the program it is driving, so
;; it gets its own frame and Sway is asked to arrange the two.  Everything
;; here degrades to a plain `switch-to-buffer' when Sway is absent or the
;; frame cannot be created.

(defun init/sway-msg (&rest args)
  "Run swaymsg with ARGS, ignoring errors outside Sway."
  (when (executable-find "swaymsg")
    (ignore-errors
      (apply #'call-process "swaymsg" nil nil nil args))))

(defun init/repl-live-buffer (regexp)
  "Return a buffer whose name matches REGEXP and has a live process, or nil."
  (seq-find (lambda (buffer)
              (and (string-match-p regexp (buffer-name buffer))
                   (process-live-p (get-buffer-process buffer))))
            (buffer-list)))

(defun init/repl-kill-dead-buffers (regexp keep)
  "Kill process-less buffers whose names match REGEXP, except KEEP."
  (dolist (buffer (buffer-list))
    (when (and (not (eq buffer keep))
               (string-match-p regexp (buffer-name buffer))
               (not (process-live-p (get-buffer-process buffer))))
      (kill-buffer buffer))))

(defun init/repl-frame--find (parameter)
  "Return the frame carrying the non-nil frame PARAMETER, or nil."
  (seq-find (lambda (frame) (frame-parameter frame parameter)) (frame-list)))

(cl-defun init/repl-frame-display (buffer-or-name &key name parameter mark script)
  "Show BUFFER-OR-NAME in a dedicated frame titled NAME, and return it.
PARAMETER is the frame parameter marking that frame as the REPL frame,
MARK is the Sway mark applied to the Emacs frame so the layout script can
find it, and SCRIPT is that layout script.  Falls back to displaying the
buffer in the current frame if anything goes wrong."
  (let ((buffer (get-buffer-create buffer-or-name)))
    (condition-case nil
        (let* ((frame (or (init/repl-frame--find parameter)
                          (make-frame `((name . ,name)
                                        (title . ,name)
                                        (alpha-background . 85)
                                        (,parameter . t)))))
               (window (frame-selected-window frame)))
          (init/sway-msg "--" "mark" "--add" mark)
          (set-window-buffer window buffer)
          (select-frame-set-input-focus (window-frame window))
          (select-window window)
          (init/sway-msg "exec" script)
          buffer)
      (error
       (switch-to-buffer buffer)
       buffer))))

;;;; Scheme: Geiser

;; The wikid project is developed against a checkout rather than an
;; installed copy, so its source directory joins Guile's load path.
(let* ((wikid-source (expand-file-name "~/.projects/wikid/src"))
       (load-path-value (getenv "GUILE_LOAD_PATH"))
       (entries (and load-path-value
                     (split-string load-path-value path-separator t))))
  (unless (member wikid-source entries)
    (setenv "GUILE_LOAD_PATH"
            (if load-path-value
                (concat wikid-source path-separator load-path-value)
              wikid-source))))

(use-package geiser
  :ensure t
  :defer t
  :custom
  (geiser-active-implementations '(guile chicken))
  (geiser-debug-jump-to-debug nil)
  (geiser-debug-show-debug t)
  (geiser-repl-history-filename
   (expand-file-name "geiser-history" user-emacs-directory)))

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

(defun init/geiser--persist-implementation (implementation)
  "Save IMPLEMENTATION as the Scheme implementation for the current repo.
Writes it into the repository's .dir-locals.el and applies it to the
Scheme buffers already open there, so the prompt is only answered once."
  (when-let* ((source (or buffer-file-name default-directory))
              (root (locate-dominating-file source ".git"))
              (locals-file (expand-file-name dir-locals-file root)))
    (let* ((existing-buffer (get-file-buffer locals-file))
           (locals-buffer existing-buffer))
      (if (and existing-buffer (buffer-modified-p existing-buffer))
          (message "Geiser: not updating %s because it has unsaved changes"
                   locals-file)
        (unwind-protect
            (save-current-buffer
              (save-window-excursion
                (require 'files-x)
                (add-dir-local-variable
                 'scheme-mode 'geiser-scheme-implementation implementation
                 locals-file)
                (setq locals-buffer (get-file-buffer locals-file))
                (with-current-buffer locals-buffer
                  (save-buffer)))
              (dolist (buffer (buffer-list))
                (with-current-buffer buffer
                  (when (and buffer-file-name
                             (derived-mode-p 'scheme-mode)
                             (file-in-directory-p buffer-file-name root))
                    (setq-local geiser-scheme-implementation implementation))))
              (message "Geiser: saved %s for Scheme files under %s"
                       implementation (abbreviate-file-name root)))
          (when (and locals-buffer (not existing-buffer))
            (kill-buffer locals-buffer)))))))

(defun init/geiser--remember-implementation (implementation)
  "Remember a prompted Geiser IMPLEMENTATION and return it unchanged."
  (when implementation
    (init/geiser--persist-implementation implementation))
  implementation)

(with-eval-after-load 'geiser-impl
  (unless (advice-member-p #'init/geiser--remember-implementation
                           'geiser-impl--read-impl)
    (advice-add 'geiser-impl--read-impl :filter-return
                #'init/geiser--remember-implementation)))

(with-eval-after-load 'geiser-repl
  ;; geiser-chicken has no debugger prompt, but Geiser 20260509 still
  ;; matches one unconditionally in the REPL output filter, which makes
  ;; loading a file fail with "Wrong type argument: stringp, nil".
  ;; Redefine the predicate to tolerate a missing debug prompt.
  (defun geiser-repl--matches-prompt-p (text)
    "Return non-nil when TEXT contains the REPL or debugger prompt."
    (or (when-let ((prompt (geiser-con--connection-prompt
                            geiser-repl--connection)))
          (string-match-p prompt text))
        (when-let ((debug-prompt (geiser-con--connection-debug-prompt
                                  geiser-repl--connection)))
          (string-match-p debug-prompt text)))))

;;;; Scheme: static-chicken applications

;; A static-chicken application ships an editor helper next to its
;; sources.  Opening a .scm file inside one loads that helper and turns on
;; `static-chicken-mode', which binds C-c C-c to save-and-reload through
;; the application's TCP REPL.

(defconst init/static-chicken-helper-path
  "vendor/static-chicken/editor/static-chicken.el"
  "Path, relative to the project root, of the bundled editor helper.")

(defconst init/static-chicken-repl-buffer-regexp
  "\\`\\*\\(?:static-chicken-repl\\|Geiser.*REPL\\).*\\*"
  "Regexp matching static-chicken and Geiser REPL buffer names.")

(defconst init/static-chicken-repl-frame-name "static-chicken REPL"
  "Name given to the dedicated static-chicken REPL frame.")

(defun init/static-chicken--pop-to-repl-frame (buffer-or-name)
  "Show BUFFER-OR-NAME in the dedicated static-chicken REPL frame."
  (init/repl-frame-display
   buffer-or-name
   :name init/static-chicken-repl-frame-name
   :parameter 'init/static-chicken-repl-frame
   :mark "static-chicken-emacs-main"
   :script "/home/dneumann/.config/sway/scripts/static-chicken-layout.sh"))

(defun init/static-chicken--connect-repl (original &rest args)
  "Reuse a live static-chicken REPL instead of spawning a duplicate.
ORIGINAL is `static-chicken-connect-repl' and ARGS its arguments."
  (let ((existing (or (get-buffer "*static-chicken-repl*")
                      (init/repl-live-buffer
                       init/static-chicken-repl-buffer-regexp))))
    (init/repl-kill-dead-buffers init/static-chicken-repl-buffer-regexp existing)
    (if (and existing (process-live-p (get-buffer-process existing)))
        (init/static-chicken--pop-to-repl-frame existing)
      (when (get-buffer "*static-chicken-repl*")
        (kill-buffer "*static-chicken-repl*"))
      (cl-letf (((symbol-function 'pop-to-buffer)
                 (lambda (buffer-or-name &optional _action _norecord)
                   (init/static-chicken--pop-to-repl-frame buffer-or-name))))
        (apply original args)))))

(defun init/static-chicken--install-repl-reuse ()
  "Advise `static-chicken-connect-repl' to reuse a live REPL frame, once."
  (when (and (featurep 'static-chicken)
             (not (get 'init/static-chicken--install-repl-reuse 'installed)))
    (put 'init/static-chicken--install-repl-reuse 'installed t)
    (advice-add 'static-chicken-connect-repl :around
                #'init/static-chicken--connect-repl)))

(defun init/static-chicken-maybe-enable ()
  "Load and enable static-chicken support when inside such a project."
  (when buffer-file-name
    (when-let* ((root (locate-dominating-file buffer-file-name
                                              init/static-chicken-helper-path))
                (helper (expand-file-name init/static-chicken-helper-path root)))
      (when (file-exists-p helper)
        (add-to-list 'load-path (file-name-directory helper))
        (require 'static-chicken nil 'noerror)
        (init/static-chicken--install-repl-reuse)
        (when (fboundp 'static-chicken-mode)
          (static-chicken-mode 1))))))

;;;; Scheme: G-Golf GTK projects

(defcustom init/g-golf-repl-port 37146
  "TCP port for the running G-Golf Guile REPL server."
  :type 'integer
  :group 'geiser)

(defun init/g-golf-connect (&optional host port)
  "Connect Geiser to a running G-Golf Guile REPL server.
HOST defaults to 127.0.0.1 and PORT to `init/g-golf-repl-port'."
  (interactive)
  (geiser-connect 'guile
                  (or host "127.0.0.1")
                  (or port init/g-golf-repl-port)))

(defun init/g-golf-project-root (&optional dir)
  "Return the G-Golf project root above DIR, or nil.
A project qualifies when the .envrc found above DIR mentions g-golf."
  (when-let* ((dir (or dir (and buffer-file-name
                                (file-name-directory buffer-file-name))))
              (root (locate-dominating-file dir ".envrc")))
    (with-temp-buffer
      (insert-file-contents (expand-file-name ".envrc" root))
      (when (save-excursion (search-forward "g-golf" nil t))
        root))))

(defun init/g-golf-reload ()
  "Save the buffer and send (reload) to the connected Geiser REPL."
  (interactive)
  (save-buffer)
  (require 'geiser-repl nil 'noerror)
  (if-let ((repl (geiser-repl--repl/impl 'guile)))
      (with-current-buffer repl
        (geiser-repl--send "(reload)" t))
    (user-error "No Geiser REPL connected.  Use C-c C-g first")))

(defun init/g-golf-install-override ()
  "Rebind C-c C-c in `geiser-mode-map' to reload a G-Golf UI.
`make-local-variable' alone leaves the shared keymap object in place, so
`define-key' would mutate it for every buffer; the map is copied first so
the rebinding really is buffer-local."
  (when (init/g-golf-project-root)
    (setq-local geiser-mode-map (copy-keymap geiser-mode-map))
    (define-key geiser-mode-map (kbd "C-c C-c") #'init/g-golf-reload)))

(defun init/g-golf-maybe-enable ()
  "Bind C-c C-g to connect when visiting a G-Golf project file."
  (when (and buffer-file-name (init/g-golf-project-root))
    (local-set-key (kbd "C-c C-g") #'init/g-golf-connect)))

;;;; Scheme: IDE keymap and hooks

(defun init/scheme-ide-setup ()
  "Enable the shared IDE keymap in Scheme buffers, mapped onto Geiser."
  (setq-local init/ide-hover-function #'geiser-doc-symbol-at-point
              init/ide-actions-function #'geiser-eval-definition
              init/ide-run-function #'geiser-eval-buffer
              init/ide-repl-function #'geiser-mode-switch-to-repl
              init/ide-goto-definition-function #'geiser-edit-symbol-at-point)
  (init/ide-mode 1))

(add-hook 'scheme-mode-hook #'init/static-chicken-maybe-enable)
(add-hook 'scheme-mode-hook #'init/g-golf-maybe-enable)
(add-hook 'scheme-mode-hook #'init/scheme-ide-setup)
(add-hook 'geiser-mode-hook #'init/g-golf-install-override)

;;;; Common Lisp: SLY

;; SLY connects to SBCL and injects its own Slynk server, so no Lisp-side
;; setup is needed.  Quicklisp is loaded from ~/.sbclrc and ASDF finds
;; projects registered in
;; ~/.config/common-lisp/source-registry.conf.d/, so from the REPL a
;; project loads with (ql:quickload :cl-core).

(use-package sly
  :ensure t
  :defer t
  :custom
  (inferior-lisp-program "sbcl")
  :config
  ;; A plain defvar in sly.el rather than a defcustom, so `:custom' would
  ;; silently fail to apply it.
  (setq sly-lisp-implementations
        '((sbcl ("sbcl" "--dynamic-space-size" "4096")))))

(defconst init/alatar-repl-buffer-regexp "\\`\\*sly-mrepl"
  "Regexp matching SLY mREPL buffer names.")

(defconst init/alatar-repl-frame-name "alatar REPL"
  "Name given to the dedicated Alatar SLY REPL frame.")

(defun init/alatar--pop-to-repl-frame (buffer-or-name)
  "Show BUFFER-OR-NAME in the dedicated Alatar REPL frame."
  (init/repl-frame-display
   buffer-or-name
   :name init/alatar-repl-frame-name
   :parameter 'init/alatar-repl-frame
   :mark "alatar-emacs-main"
   :script "/home/dneumann/.config/sway/scripts/alatar-layout.sh"))

(defun init/alatar--wrap-repl-display (original _display-action)
  "Route `sly-mrepl' display into the Alatar REPL frame.
ORIGINAL is the wrapped function; _DISPLAY-ACTION is replaced."
  (funcall original #'init/alatar--pop-to-repl-frame))

(defun init/alatar--wrap-repl-create (original &rest args)
  "Pop a newly created SLY REPL into the Alatar frame.
ORIGINAL is `sly-mrepl-new' and ARGS its arguments."
  (cl-letf (((symbol-function 'pop-to-buffer)
             (lambda (buffer-or-name &optional _action _norecord)
               (init/alatar--pop-to-repl-frame buffer-or-name))))
    (apply original args)))

(defun init/sly-mrepl-paredit ()
  "Enable paredit in the SLY REPL, keeping RET as submit.
paredit >= 25 binds RET in its minor-mode map, which shadows the
major-mode map (`local-set-key' is not enough), so it is shadowed back
through `minor-mode-overriding-map-alist'."
  (paredit-mode 1)
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map paredit-mode-map)
    (define-key map (kbd "RET") #'sly-mrepl-return)
    (setq-local minor-mode-overriding-map-alist `((paredit-mode . ,map)))))

(with-eval-after-load 'sly-mrepl
  (unless (get 'init/alatar--wrap-repl-display 'installed)
    (put 'init/alatar--wrap-repl-display 'installed t)
    (advice-add 'sly-mrepl :around #'init/alatar--wrap-repl-display)
    (advice-add 'sly-mrepl-new :around #'init/alatar--wrap-repl-create))
  (add-hook 'sly-mrepl-mode-hook #'init/sly-mrepl-paredit))

(defun init/lisp-ide-setup ()
  "Enable the shared IDE keymap in Common Lisp buffers, mapped onto SLY."
  (setq-local init/ide-hover-function #'sly-describe-symbol
              init/ide-actions-function #'sly-eval-defun
              init/ide-run-function #'sly-eval-buffer
              init/ide-repl-function #'sly-mrepl
              init/ide-diagnostics-function #'sly-goto-first-note
              init/ide-goto-definition-function #'sly-edit-definition
              init/ide-go-back-function #'sly-pop-find-definition-stack)
  (init/ide-mode 1))

(add-hook 'lisp-mode-hook #'init/lisp-ide-setup)

(provide 'init-lang-lisp)
;;; init-lang-lisp.el ends here
