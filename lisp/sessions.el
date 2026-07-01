;;; sessions.el --- VSCode-like session management -*- lexical-binding: t; -*-

;;; Commentary:

;; Session persistence built on easysession:
;;
;; - The window/buffer state auto-saves every 2 minutes, on exit, and
;;   whenever sessions are switched; reopening Emacs restores the last
;;   session including frame geometry.
;; - *scratch* persists across restarts via persistent-scratch, and
;;   easysession never kills it on switches or resets, so its contents
;;   follow you between sessions.
;; - Every project gets its own session: switching projects through
;;   Projectile (C-c p p, the mode-line ❒ button, or the project
;;   panel's [open]) loads the project's session when one exists —
;;   skipping the find-file prompt — and otherwise starts a fresh
;;   session for it.
;; - The ⧉ mode-line button (or `bind/session-menu') opens a menu to
;;   start a new empty session, load, save, rename, or delete sessions.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'transient)

(declare-function easysession-switch-to "easysession")
(declare-function easysession-save "easysession")
(declare-function easysession-reset "easysession")
(declare-function easysession-get-session-name "easysession")
(declare-function easysession-get-session-file-path "easysession")
(declare-function projectile-find-file "projectile")

(use-package easysession
  :ensure t
  :demand t
  :custom
  ;; Auto-save the session every 2 minutes (plus on exit and on switch).
  (easysession-save-interval 120)
  ;; Show the current session name in the mode line misc info.
  (easysession-mode-line-misc-info t)
  ;; Project sessions are created programmatically; never prompt about it.
  (easysession-confirm-new-session nil)
  :config
  ;; Restore the previous session (including frame geometry) at startup
  ;; and turn on the auto-save mode.
  (easysession-setup))

;; Keep *scratch* contents across Emacs restarts.
(use-package persistent-scratch
  :ensure t
  :config
  (persistent-scratch-setup-default))

;;;; Session commands

(defun init/session-exists-p (name)
  "Return non-nil when a session called NAME has been saved."
  (file-exists-p (easysession-get-session-file-path name)))

(defun init/session-new (name)
  "Save the current session and start a fresh, empty session called NAME.
Modified file buffers and special buffers (including *scratch*) are
left alone; everything else is closed."
  (interactive "sNew session name: ")
  (let ((name (string-trim name)))
    (when (string-empty-p name)
      (user-error "Session name must not be empty"))
    (when (init/session-exists-p name)
      (user-error "Session %s already exists; load it instead" name))
    (easysession-switch-to name)        ; saves the old session
    (easysession-reset)                 ; clean slate
    (easysession-save)
    (message "Started fresh session '%s'" name)))

(defun init/session-load ()
  "Save the current session and switch to a previously saved one."
  (interactive)
  (call-interactively #'easysession-switch-to))

(transient-define-prefix init/session-menu ()
  "Session management."
  ["Sessions"
   ("n" "New empty session"       init/session-new)
   ("l" "Load / switch session"   init/session-load)
   ("s" "Save current session"    easysession-save)
   ("r" "Rename current session"  easysession-rename)
   ("d" "Delete sessions"         easysession-delete)])

(global-set-key (kbd bind/session-menu) #'init/session-menu)

;;;; Per-project sessions

(defun init/session-project-name (root)
  "Return the session name used for the project at ROOT."
  (concat "project: "
          (file-name-nondirectory
           (directory-file-name (expand-file-name root)))))

(defun init/session-projectile-switch-action ()
  "Open the selected project through its session.
Runs as `projectile-switch-project-action', with `default-directory'
set to the project root.  When the project already has a session, load
it and skip the find-file prompt.  Otherwise save the current session,
start a fresh one named after the project, and fall back to
Projectile's find-file."
  (let ((name (init/session-project-name default-directory))
        (root default-directory))
    (cond
     ;; Re-selecting the current project: don't reload, just find a file.
     ((equal name (easysession-get-session-name))
      (projectile-find-file))
     ((init/session-exists-p name)
      (easysession-switch-to name))
     (t
      (easysession-switch-to name)     ; saves the previous session
      (easysession-reset)              ; project starts with a clean slate
      (let ((default-directory root))
        (projectile-find-file))))))

(with-eval-after-load 'projectile
  (setq projectile-switch-project-action
        #'init/session-projectile-switch-action))

(provide 'sessions)
;;; sessions.el ends here
