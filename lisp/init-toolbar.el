;;; init-toolbar.el --- Clickable toolbars -*- lexical-binding: t; -*-

;;; Commentary:

;; Two things live here.
;;
;; First, a small API for fixed, clickable toolbars rendered in a
;; buffer's header line, used by the Treemacs, PDF, EWW and run/build
;; panel toolbars.  Build a toolbar function with `init/toolbar-string'
;; and attach it to a buffer with `init/toolbar-attach':
;;
;;   (defun my/toolbar ()
;;     (init/toolbar-string
;;      '("⟳" "Reload" my-reload-command)
;;      :sep
;;      #'my/dynamic-segment          ; function returning a string
;;      " raw text"))
;;
;;   (add-hook 'my-mode-hook (lambda () (init/toolbar-attach #'my/toolbar)))
;;
;; Item forms understood by `init/toolbar-string':
;;   (LABEL HELP COMMAND)  clickable button
;;   :sep                  group separator
;;   a function            called with no args, must return a string
;;   a string              inserted as-is
;;   nil                   skipped (handy for conditional items)
;;
;; Second, the one global toolbar for project and session tools.  Those
;; actions are frame-global, so instead of a header line per buffer there
;; is a single one-line bar in a top side window spanning the full frame
;; width, including above Treemacs (`window-sides-vertical' t).  Utilities
;; sit on the left edge; project tools are right-aligned by a
;; pixel-measured spacer.
;;
;; The global bar is hidden by default.  Toggle it with the ⚒ mode-line
;; button, `bind/doc-toolbar', or M-x `init/doc-toolbar-mode'.  Clicks on
;; the bar act on the most recently used ordinary window, never on the bar
;; itself.  It is independent of the tab-bar menu; with both enabled you
;; get two bars.

;;; Code:

(require 'seq)
(require 'init-keys)
(require 'init-persist)
(require 'init-pulldown)

;;;; Faces

(defface init/toolbar-button
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for clickable toolbar buttons."
  :group 'convenience)

(defface init/toolbar-info
  '((t :inherit shadow))
  "Face for informational toolbar segments."
  :group 'convenience)

;;;; Toolbar API

(defun init/toolbar--help-echo (help command)
  "Return a `help-echo' function combining HELP with COMMAND's keybinding.
The key is looked up when the tooltip is shown, in the hovered window's
buffer, so buffer-local bindings are reported correctly.  Unbound
commands are shown as M-x invocations."
  (lambda (window _object _pos)
    (let ((suffix
           (when (symbolp command)
             (let ((key (with-selected-window window
                          (where-is-internal command nil t))))
               (if key
                   (key-description key)
                 (format "M-x %s" command))))))
      (if suffix
          (format "%s  —  %s" help suffix)
        help))))

(defun init/toolbar--click-target (clicked)
  "Return the window a toolbar click in CLICKED should act on.
Clicks in a dedicated toolbar-bar window (window parameter
`init/toolbar-bar') are redirected to the selected window -- clicking a
button does not change the selection, so that is the window being
edited -- or to the most recently used window as a fallback.  Commands
like `find-file' therefore never open inside the bar."
  (cond
   ((not (window-parameter clicked 'init/toolbar-bar)) clicked)
   ((not (window-parameter (selected-window) 'init/toolbar-bar)) (selected-window))
   (t (or (get-mru-window nil nil t) clicked))))

(defun init/toolbar--keymap (command)
  "Return a keymap running COMMAND on a mouse-1 click.
Works both as a header-line segment and as buffer text.  The command
runs with the clicked (or redirected, see `init/toolbar--click-target')
window selected, so buffer-local commands act on the right buffer."
  (let ((map (make-sparse-keymap))
        (action (lambda (event)
                  (interactive "e")
                  (with-selected-window
                      (init/toolbar--click-target
                       (posn-window (event-start event)))
                    (call-interactively command)))))
    (define-key map [header-line mouse-1] action)
    (define-key map [mouse-1] action)
    map))

(defun init/toolbar-button (label help command)
  "Return a clickable toolbar LABEL that runs COMMAND.
HELP is shown as the tooltip, together with COMMAND's current
keybinding so the shortcut can be learned."
  (propertize label
              'help-echo (init/toolbar--help-echo help command)
              'mouse-face 'highlight
              'pointer 'hand
              'face 'init/toolbar-button
              'local-map (init/toolbar--keymap command)))

(defun init/toolbar-info (label &optional help command)
  "Return an informational toolbar segment showing LABEL.
With HELP, show it as a tooltip (including COMMAND's keybinding when
COMMAND is given).  With COMMAND, make the segment clickable too."
  (apply #'propertize label
         'face 'init/toolbar-info
         (append
          (when help
            (list 'help-echo (if command
                                 (init/toolbar--help-echo help command)
                               help)))
          (when command
            (list 'mouse-face 'highlight
                  'pointer 'hand
                  'local-map (init/toolbar--keymap command))))))

(defun init/toolbar-menu-button (label help menu)
  "Return a clickable toolbar LABEL that pops up MENU.
MENU is an `easy-menu' item list; HELP is the tooltip."
  (propertize label
              'help-echo help
              'mouse-face 'highlight
              'pointer 'hand
              'face 'init/toolbar-button
              'local-map
              (let ((map (make-sparse-keymap)))
                (define-key map [header-line mouse-1]
                            (lambda (event)
                              (interactive "e")
                              (with-selected-window
                                  (posn-window (event-start event))
                                (pulldown-menu-popup menu event))))
                map)))

(defun init/toolbar-separator ()
  "Return the separator drawn between toolbar groups."
  (propertize "│" 'face 'init/toolbar-info))

(defun init/toolbar--gap ()
  "Return the fixed-width gap drawn between toolbar items.
A `:width' display spec keeps the gap the same width regardless of which
fallback font renders the neighbouring symbol glyphs, so wide icons
cannot touch or overlap each other."
  (propertize " " 'display '(space :width 1.75)))

(defun init/toolbar--item (item)
  "Render one `init/toolbar-string' ITEM, or return nil to skip it."
  (cond
   ((null item) nil)
   ((eq item :sep) (init/toolbar-separator))
   ((stringp item) item)
   ((functionp item) (funcall item))
   ((listp item) (apply #'init/toolbar-button item))
   (t (error "Unknown toolbar item: %S" item))))

(defun init/toolbar-string (&rest items)
  "Compose ITEMS into a toolbar string.
See the Commentary for the accepted item forms."
  (concat
   " "
   (mapconcat #'identity
              (delq nil (mapcar #'init/toolbar--item items))
              (init/toolbar--gap))
   ;; Fill to the window's right edge so a single toolbar spans the full
   ;; header line.  Exactly one character, so callers that compose several
   ;; sections (see `init/doc-toolbar--toolbar') can strip it with a
   ;; one-character `substring'.  Stop one pixel short of the edge: a line
   ;; that exactly fills a `truncate-lines' window still gets a truncation
   ;; glyph drawn over its last column.
   (propertize " " 'display '(space :align-to (- right-fringe (1))))))

(defvar-local init/toolbar--function nil
  "Function producing this buffer's header-line toolbar.")

(defun init/toolbar-attach (function)
  "Show FUNCTION's toolbar in the current buffer's header line.
FUNCTION is called on every redisplay, so keep it cheap."
  (setq init/toolbar--function function)
  (setq-local header-line-format '(:eval (funcall init/toolbar--function))))

(defun init/toolbar-detach ()
  "Remove the toolbar from the current buffer's header line."
  (when init/toolbar--function
    (setq init/toolbar--function nil)
    (kill-local-variable 'header-line-format)))

;;;; The global toolbar bar

(defgroup init/doc-toolbar nil
  "The global toolbar shown across the top of the frame."
  :group 'convenience)

(declare-function init/project-run "init-compile")
(declare-function init/project-build "init-compile")
(declare-function init/project-command-switch "init-compile")
(declare-function init/project-command-add "init-compile")
(declare-function init/project-search "init-projects")
(declare-function init/project-panel-toggle "init-projects")
(declare-function init/session-menu "init-projects")
(declare-function init/toggle-frame-transparency "init-frame")
(declare-function init/reload-config "init-editor")
(declare-function projectile-switch-project "projectile")
(declare-function projectile-find-file "projectile")
(declare-function magit-status "magit")
(declare-function project-eshell "project")
(declare-function restart-emacs "restart-emacs")

(defconst init/doc-toolbar-buffer-name " *toolbar*"
  "Name of the buffer backing the global toolbar bar.")

(defconst init/doc-toolbar-documents-directory
  (expand-file-name "~/Documents")
  "Directory the toolbar's document buttons browse.")

;;;;; Commands unique to the bar

(defun init/doc-toolbar-find-pdf ()
  "Prompt for a PDF below `init/doc-toolbar-documents-directory' and open it."
  (interactive)
  (let ((root init/doc-toolbar-documents-directory))
    (unless (file-directory-p root)
      (user-error "Documents directory does not exist: %s" root))
    (let* ((case-fold-search t)
           (choices (mapcar (lambda (file)
                              (cons (file-relative-name file root) file))
                            (directory-files-recursively root "\\.pdf\\'"))))
      (unless choices
        (user-error "No PDFs found below %s" root))
      (find-file
       (cdr (assoc (completing-read "Open PDF: " choices nil t) choices))))))

(defun init/doc-toolbar-open-documents ()
  "Open `init/doc-toolbar-documents-directory' in Dired."
  (interactive)
  (dired init/doc-toolbar-documents-directory))

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

;;;;; Rendering

(defun init/doc-toolbar--utilities ()
  "Return the left-hand utility section of the global toolbar.
The section's own right-fringe fill is stripped; the alignment spacer in
`init/doc-toolbar--toolbar' fills the gap between the two sections."
  (substring
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
    '("⏻" "Restart Emacs" init/doc-toolbar-restart-emacs))
   0 -1))

(defun init/doc-toolbar--projects ()
  "Return the right-hand project section of the global toolbar.
The items are composed in reverse so they read left to right once the
section is right-aligned."
  (apply
   #'init/toolbar-string
   (reverse
    (list
     '("▶" "Run project (last run command)" init/project-run)
     '("⚙" "Build project (last build command)" init/project-build)
     '("⇄" "Switch what run/build executes" init/project-command-switch)
     '("＋" "Add a project command" init/project-command-add)
     :sep
     '("❒" "Open project" projectile-switch-project)
     '("▤" "Find file in project" projectile-find-file)
     '("⌕" "Project search" init/project-search)
     :sep
     '("⎇" "Magit status" magit-status)
     '("❯" "Project eshell" project-eshell)
     '("▦" "Toggle project panel" init/project-panel-toggle)
     '("⧉" "Sessions" init/session-menu)
     :sep
     '("◐" "Toggle transparency" init/toggle-frame-transparency)))))

(defun init/doc-toolbar--spacer (section)
  "Return a spacer pushing SECTION flush against the right window edge.
SECTION's true pixel width is measured rather than its column count,
which undercounts the symbol glyphs drawn by wider fallback fonts and
would push the section past the window edge, wrapping the bar.  The
trailing fill is dropped from the measurement -- its `:align-to' has no
width of its own -- but kept in the display, where it collapses to
nothing."
  (let ((width (string-pixel-width (substring section 0 -1))))
    (propertize
     " "
     ;; One pixel of headroom, matching the toolbar fill: a line ending
     ;; exactly at the window edge draws a truncation glyph.
     'display `(space :align-to (- right-fringe (,(1+ width)))))))

(defun init/doc-toolbar--toolbar ()
  "Return the full text of the global toolbar bar."
  (let ((utilities (init/doc-toolbar--utilities))
        (projects (init/doc-toolbar--projects)))
    (concat utilities (init/doc-toolbar--spacer projects) projects)))

;;;;; The bar window

(defun init/doc-toolbar--window ()
  "Return the live toolbar-bar window, or nil."
  (seq-find (lambda (window)
              (window-parameter window 'init/toolbar-bar))
            (window-list nil 'no-minibuffer)))

(defun init/doc-toolbar--buffer ()
  "Return the toolbar-bar buffer, re-rendering its contents."
  (let ((buffer (get-buffer-create init/doc-toolbar-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (init/doc-toolbar--toolbar))
        ;; Leave point at the start.  At the end of the line it drags the
        ;; window's display along -- auto-hscroll (or wrapping) scrolls the
        ;; bar to show the line's tail and the leading tools vanish off
        ;; the left edge.
        (goto-char (point-min)))
      (setq-local mode-line-format nil
                  cursor-type nil
                  buffer-read-only t
                  ;; Never wrap: a too-narrow window truncates the line
                  ;; instead of folding the bar onto a second row.
                  truncate-lines t
                  auto-hscroll-mode nil))
    buffer))

(defun init/doc-toolbar--configure-window (window)
  "Turn WINDOW into the dedicated, fixed-height toolbar bar window."
  (set-window-parameter window 'init/toolbar-bar t)
  (set-window-parameter window 'no-other-window t)
  (set-window-parameter window 'no-delete-other-windows t)
  (set-window-parameter window 'mode-line-format 'none)
  (set-window-dedicated-p window t)
  ;; A reused window may carry stale scroll state; show the bar from its
  ;; very first character.
  (set-window-point window 1)
  (set-window-hscroll window 0)
  ;; A nominal one-line window can clip the toolbar face's bottom border.
  ;; Fit the actual rendered line in pixels before fixing the height.
  (let ((window-resize-pixelwise t))
    (fit-window-to-buffer window 2 1 nil nil t))
  (with-current-buffer (window-buffer window)
    (setq-local window-size-fixed 'height))
  window)

(defun init/doc-toolbar--show ()
  "Display the toolbar bar in a one-line top side window."
  ;; Left and right side windows (Treemacs) keep the full frame height
  ;; when `window-sides-vertical' is t, so the bar spans everything
  ;; except the Treemacs column.
  (setq window-sides-vertical t)
  (unless (init/doc-toolbar--window)
    (when-let* ((window (display-buffer-in-side-window
                        (init/doc-toolbar--buffer)
                        '((side . top)
                          (slot . 0)
                          (window-height . 1)
                          (preserve-size . (nil . t))))))
      (when (window-live-p window)
        (init/doc-toolbar--configure-window window)))))

(defun init/doc-toolbar--hide ()
  "Remove the toolbar bar window."
  (when-let* ((window (init/doc-toolbar--window)))
    (delete-window window)))

;;;###autoload
(define-minor-mode init/doc-toolbar-mode
  "Show one global toolbar across the top of the frame.
Hidden by default; toggle with the ⚒ mode-line button."
  :group 'init/doc-toolbar
  :global t
  (if init/doc-toolbar-mode
      (init/doc-toolbar--show)
    (init/doc-toolbar--hide)))

;;;;; Persistence

(defvar init/doc-toolbar-persisted nil
  "Persisted desired state of `init/doc-toolbar-mode' (t when shown).")
;; Restored early by `init/persist-load'; registered here so it is written
;; back to the store whenever it changes.
(init/persist-register 'init/doc-toolbar-persisted)

(defun init/doc-toolbar--save ()
  "Persist whether the toolbar is currently shown."
  (setq init/doc-toolbar-persisted (and init/doc-toolbar-mode t))
  (init/persist-save-variable 'init/doc-toolbar-persisted))

;; The mode hook runs after the mode variable flips, on enable and
;; disable alike, so every toggle is recorded.
(add-hook 'init/doc-toolbar-mode-hook #'init/doc-toolbar--save)

(defun init/doc-toolbar--restore ()
  "Re-enable the toolbar at startup when it was shown last session."
  (when (and init/doc-toolbar-persisted (not init/doc-toolbar-mode))
    (init/doc-toolbar-mode 1)))

;; Showing the bar needs a live graphical frame, so defer until one exists.
(add-hook 'emacs-startup-hook #'init/doc-toolbar--restore)

(defun init/doc-toolbar--restore-after-session ()
  "Re-show the toolbar after a session restore rebuilt the window tree."
  (when init/doc-toolbar-mode
    (init/doc-toolbar--show)))

(with-eval-after-load 'easysession
  (add-hook 'easysession-after-load-hook #'init/doc-toolbar--restore-after-session))

(global-set-key (kbd bind/doc-toolbar) #'init/doc-toolbar-mode)

(provide 'init-toolbar)
;;; init-toolbar.el ends here
