;;; doc-toolbar.el --- Global toolbar bar -*- lexical-binding: t; -*-

;;; Commentary:

;; One global toolbar for the project/session tools (open project, find
;; file, project search, Magit, eshell, project panel, sessions,
;; transparency).  These actions are frame-global, so instead of a
;; header line per buffer there is a single one-line bar in a top side
;; window, spanning the frame's width.  Left/right side windows keep
;; their full height (`window-sides-vertical' nil), so the bar stops at
;; the Treemacs edge instead of crossing it.
;;
;; Hidden by default.  Toggle with the ⚒ mode-line button,
;; `bind/doc-toolbar', or M-x init/doc-toolbar-mode.  Clicks on the bar
;; act on the most recently used ordinary window, never on the bar
;; itself.  Independent of the tab-bar menu (Agenda, Options, Guides,
;; ...) -- with both enabled you get two bars.

;;; Code:

(require 'toolbar)

(declare-function projectile-switch-project "projectile")
(declare-function projectile-find-file "projectile")
(declare-function magit-status "magit")
(declare-function project-eshell "project")
(declare-function init/project-search "project-tools")
(declare-function init/project-panel-toggle "project-panel")
(declare-function init/session-menu "sessions")
(declare-function init/toggle-frame-transparency "editor")

(defconst init/doc-toolbar-buffer-name " *toolbar*"
  "Name of the buffer backing the global toolbar bar.")

(defun init/doc-toolbar--toolbar ()
  "Build the global toolbar."
  (init/toolbar-string
   ;; Project
   '("❒" "Open project" projectile-switch-project)
   '("▤" "Find file in project" projectile-find-file)
   '("⌕" "Project search" init/project-search)
   :sep
   ;; Tools
   '("⎇" "Magit status" magit-status)
   '("❯" "Project eshell" project-eshell)
   '("▦" "Toggle project panel" init/project-panel-toggle)
   '("⧉" "Sessions" init/session-menu)
   :sep
   ;; Frame
   '("◐" "Toggle transparency" init/toggle-frame-transparency)))

(defun init/doc-toolbar--window ()
  "Return the live toolbar-bar window, or nil."
  (seq-find (lambda (window)
              (window-parameter window 'init/toolbar-bar))
            (window-list nil 'no-minibuffer)))

(defun init/doc-toolbar--buffer ()
  "Return the toolbar-bar buffer, (re)rendering its contents."
  (let ((buffer (get-buffer-create init/doc-toolbar-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (init/doc-toolbar--toolbar)))
      (setq-local mode-line-format nil
                  cursor-type nil
                  buffer-read-only t
                  window-size-fixed 'height))
    buffer))

(defun init/doc-toolbar--show ()
  "Display the toolbar bar in a one-line top side window."
  ;; Keep left/right side windows (Treemacs) full height so the top bar
  ;; spans the frame width without crossing them.
  (setq window-sides-vertical nil)
  (unless (init/doc-toolbar--window)
    (let ((window (display-buffer-in-side-window
                   (init/doc-toolbar--buffer)
                   '((side . top)
                     (slot . 0)
                     (window-height . 1)
                     (preserve-size . (nil . t))))))
      (when (window-live-p window)
        (set-window-parameter window 'init/toolbar-bar t)
        (set-window-parameter window 'no-other-window t)
        (set-window-parameter window 'no-delete-other-windows t)
        (set-window-parameter window 'mode-line-format 'none)
        (set-window-dedicated-p window t)
        window))))

(defun init/doc-toolbar--hide ()
  "Remove the toolbar bar window."
  (when-let ((window (init/doc-toolbar--window)))
    (delete-window window)))

;;;###autoload
(define-minor-mode init/doc-toolbar-mode
  "Show one global toolbar across the top of the frame.
Hidden by default; toggle with the ⚒ mode-line button."
  :global t
  (if init/doc-toolbar-mode
      (init/doc-toolbar--show)
    (init/doc-toolbar--hide)))

;; Session restores rebuild the window tree; re-show the bar when the
;; mode is on so it survives session switches.
(with-eval-after-load 'easysession
  (add-hook 'easysession-after-load-hook
            (lambda ()
              (when init/doc-toolbar-mode
                (init/doc-toolbar--show)))))

(global-set-key (kbd bind/doc-toolbar) #'init/doc-toolbar-mode)

(provide 'doc-toolbar)
;;; doc-toolbar.el ends here
