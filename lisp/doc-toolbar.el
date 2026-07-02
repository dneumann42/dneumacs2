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

(declare-function init/project-run "project-commands")
(declare-function init/project-build "project-commands")
(declare-function init/project-command-switch "project-commands")
(declare-function init/project-command-add "project-commands")
(declare-function projectile-switch-project "projectile")
(declare-function projectile-find-file "projectile")
(declare-function magit-status "magit")
(declare-function project-eshell "project")
(declare-function init/project-search "project-tools")
(declare-function init/project-panel-toggle "project-panel")
(declare-function init/session-menu "sessions")
(declare-function init/toggle-frame-transparency "editor")
(declare-function init/reload-config "editor")
(declare-function restart-emacs "restart-emacs")

(defconst init/doc-toolbar-buffer-name " *toolbar*"
  "Name of the buffer backing the global toolbar bar.")

(defun init/doc-toolbar-find-pdf ()
  "Prompt for a PDF below ~/Documents and open it.
The prompt uses `completing-read', and is therefore handled by Vertico
when Vertico mode is enabled."
  (interactive)
  (let ((root (expand-file-name "~/Documents")))
    (unless (file-directory-p root)
      (user-error "Documents directory does not exist: %s" root))
    (let* ((case-fold-search t)
           (files (directory-files-recursively root "\\.pdf\\'"))
           (choices (mapcar (lambda (file)
                              (cons (file-relative-name file root) file))
                            files)))
      (unless choices
        (user-error "No PDFs found below %s" root))
      (find-file
       (cdr (assoc (completing-read "Open PDF: " choices nil t) choices))))))

(defun init/doc-toolbar-open-documents ()
  "Open ~/Documents in Dired."
  (interactive)
  (dired (expand-file-name "~/Documents")))

(defun init/doc-toolbar-open-scratch ()
  "Switch to the persistent *scratch* buffer."
  (interactive)
  (switch-to-buffer (get-buffer-create "*scratch*")))

(defun init/doc-toolbar-restart-emacs ()
  "Restart Emacs after explicit confirmation."
  (interactive)
  (unless (fboundp 'restart-emacs)
    (user-error "The restart-emacs command is unavailable"))
  (when (yes-or-no-p "Restart Emacs now? ")
    (restart-emacs)))

(defun init/doc-toolbar--toolbar ()
  "Build left utility and right project sections of the global toolbar."
  (let* ((utilities
          (init/toolbar-string
           '("PDF" "Find a PDF below ~/Documents" init/doc-toolbar-find-pdf)
           '("◴" "Open a recent file" recentf-open-files)
           '("⌂" "Open ~/Documents in Dired" init/doc-toolbar-open-documents)
           '("✱" "Open the persistent scratch buffer" init/doc-toolbar-open-scratch)
           :sep
           '("=" "Open Calc" calc)
           '("▣" "Open Calendar" calendar)
           '("☷" "Open the process viewer" proced)
           :sep
           '("↻" "Reload the Emacs configuration" init/reload-config)
           '("⏻" "Restart Emacs" init/doc-toolbar-restart-emacs)))
         ;; Remove this section's right-fringe fill; the shared alignment
         ;; spacer below fills the gap between the two sections instead.
         (utilities (substring utilities 0 -1))
         (projects
          (apply
           #'init/toolbar-string
           (reverse
            (list
             ;; Run & build
             '("▶" "Run project (last run command)" init/project-run)
             '("⚙" "Build project (last build command)" init/project-build)
             '("⇄" "Switch what run/build executes" init/project-command-switch)
             '("＋" "Add a project command" init/project-command-add)
             :sep
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
             '("◐" "Toggle transparency" init/toggle-frame-transparency)))))
         (spacer
          (propertize
           " "
           'display `(space :align-to (- right-fringe ,(string-width projects)))
           'face '((:height 1.0) init/toolbar-border))))
    (concat utilities spacer projects)))

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
                  buffer-read-only t))
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
        ;; A nominal one-line window can clip the toolbar face's bottom
        ;; border.  Fit the actual rendered line in pixels before fixing
        ;; and preserving the window height.
        (let ((window-resize-pixelwise t))
          (fit-window-to-buffer window 2 1 nil nil t))
        (with-current-buffer (window-buffer window)
          (setq-local window-size-fixed 'height))
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
