;;; treemacs-setup.el --- Treemacs setup -*- lexical-binding: t; -*-

(use-package treemacs
  :ensure t
  :defer t
  :config
  (progn
    (setq treemacs-buffer-name-function            #'treemacs-default-buffer-name
          treemacs-buffer-name-prefix              " *Treemacs-Buffer-"
          treemacs-deferred-git-apply-delay        0.5
          treemacs-directory-name-transformer      #'identity
          treemacs-display-in-side-window          t
          treemacs-eldoc-display                   'simple
          treemacs-file-event-delay                2000
          treemacs-file-extension-regex            "\\.[^.]*\\'"
          treemacs-file-follow-delay               0.2
          treemacs-file-name-transformer           #'identity
          treemacs-follow-after-init               t
          treemacs-expand-after-init               t
          treemacs-find-workspace-method           'find-for-file-or-pick-first
          treemacs-git-command-pipe                ""
          treemacs-goto-tag-strategy               'refetch-index
          treemacs-header-scroll-indicators        '(nil . "^^^^^^")
          treemacs-hide-dot-git-directory          t
          treemacs-hide-dot-jj-directory           t
          treemacs-indentation                     2
          treemacs-indentation-string              " "
          treemacs-is-never-other-window           nil
          treemacs-max-git-entries                 5000
          treemacs-missing-project-action          'ask
          treemacs-move-files-by-mouse-dragging    t
          treemacs-move-forward-on-expand          nil
          treemacs-no-png-images                   nil
          treemacs-no-delete-other-windows         t
          treemacs-project-follow-cleanup          nil
          treemacs-persist-file                    (expand-file-name ".cache/treemacs-persist" user-emacs-directory)
          treemacs-position                        'left
          treemacs-read-string-input               'from-minibuffer
          treemacs-recenter-distance               0.1
          treemacs-recenter-after-file-follow      nil
          treemacs-recenter-after-tag-follow       nil
          treemacs-recenter-after-project-jump     'always
          treemacs-recenter-after-project-expand   'on-distance
          treemacs-litter-directories              '("/node_modules" "/.venv" "/.cask")
          treemacs-project-follow-into-home        nil
          treemacs-show-cursor                     nil
          treemacs-show-hidden-files               t
          treemacs-silent-filewatch                nil
          treemacs-silent-refresh                  nil
          treemacs-sorting                         'alphabetic-asc
          treemacs-select-when-already-in-treemacs 'move-back
          treemacs-space-between-root-nodes        t
          treemacs-tag-follow-cleanup              t
          treemacs-tag-follow-delay                1.5
          treemacs-text-scale                      nil
          treemacs-user-mode-line-format           nil
          treemacs-user-header-line-format         nil
          treemacs-wide-toggle-width               70
          treemacs-width                           35
          treemacs-width-increment                 1
          treemacs-width-is-initially-locked       t
          treemacs-workspace-switch-cleanup        nil)

    (setq treemacs-collapse-dirs
          (if (bound-and-true-p treemacs-python-executable) 3 0))

    ;; The default width and height of the icons is 22 pixels. If you are
    ;; using a Hi-DPI display, uncomment this to double the icon size.
    ;;(treemacs-resize-icons 44)

    (treemacs-follow-mode t)
    (treemacs-filewatch-mode t)
    (treemacs-fringe-indicator-mode 'always)
    (when (bound-and-true-p treemacs-python-executable)
      (treemacs-git-commit-diff-mode t))

    (pcase (cons (not (null (executable-find "git")))
                 (not (null (bound-and-true-p treemacs-python-executable))))
      (`(t . t)
       (treemacs-git-mode 'deferred))
      (`(t . _)
       (treemacs-git-mode 'simple)))

    (treemacs-hide-gitignored-files-mode nil))
  :bind
  (:map global-map
        ("C-x t 1"   . treemacs-delete-other-windows)
        ("C-x t t"   . treemacs)
        ("C-x t d"   . treemacs-select-directory)
        ("C-x t B"   . treemacs-bookmark)
        ("C-x t C-t" . treemacs-find-file)
        ("C-x t M-t" . treemacs-find-tag)
        ("M-0"       . treemacs-select-window)))

(use-package treemacs-evil
  :after (treemacs evil)
  :ensure t)

(defvar treemacs-project-map (make-sparse-keymap)
  "Fallback Treemacs project keymap, used until Treemacs initializes it.")

(with-eval-after-load 'treemacs-mode
  (require 'treemacs-projectile nil t))

(use-package treemacs-icons-dired
  :hook (dired-mode . treemacs-icons-dired-enable-once)
  :ensure t)

(use-package treemacs-magit
  :after (treemacs magit)
  :ensure t)

;; NOTE: Treemacs uses the default `treemacs-frame-scope' (one tree per
;; frame), which is stable for this configuration.  We deliberately do NOT
;; enable the tab-bar or perspective scopes:
;;   * treemacs-tab-bar keys the scope on the current tab's *name*, which --
;;     because `tab-bar-mode' here is only a menu bar with a single, unnamed
;;     tab -- tracks the current buffer's name.  The tree then gets registered
;;     under one scope key and looked up under another, so
;;     `treemacs-get-local-buffer' returns nil after switching buffers.  That
;;     silently breaks every command that resolves the tree by scope rather
;;     than by window (collapse-all, the helpful hydra, follow cleanup, ...).
;;   * treemacs-persp is pointless without `persp-mode', which is not used.

;; Avoid startup focus grabs that can leave Evil in an unexpected state.
;; Open Treemacs manually with `C-x t t`.

;;;; Treemacs buffer buttons

(declare-function treemacs-find-file "treemacs")
(declare-function treemacs-get-local-window "treemacs-scope")
(declare-function treemacs-goto-file-node "treemacs-core-utils")
(declare-function treemacs--find-project-for-path "treemacs-core-utils")
(declare-function treemacs-pulse-on-success "treemacs-logging")
(declare-function treemacs-pulse-on-failure "treemacs-logging")

(defface init/treemacs-button
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for the clickable buttons at the top of the Treemacs buffer.")

(defvar-local init/treemacs--buttons-overlay nil
  "Overlay whose `before-string' holds the Treemacs button row.")

(defun init/treemacs--editor-buffer ()
  "Return the most recently active file-visiting buffer outside Treemacs.
`buffer-list' is ordered most-recently-selected first, so this is the
last buffer that had focus before Treemacs did."
  (seq-find (lambda (buf)
              (and (buffer-file-name buf)
                   (not (eq (buffer-local-value 'major-mode buf) 'treemacs-mode))))
            (buffer-list)))

(defun init/treemacs-focus-current-file ()
  "Reveal, in the Treemacs tree, the file of the last active editor buffer.
Drives the live Treemacs window directly rather than going through
`treemacs-find-file'.  That matters because `treemacs-find-file' reads
the file from `current-buffer' (which, when invoked from a button in the
Treemacs window, is the non-file Treemacs buffer) and its window/visibility
dance can leave the goto running in a buffer whose buffer-local
`treemacs-dom' is nil -- the source of the `hash-table-p, nil' crash.
Selecting the already-rendered Treemacs window guarantees a live dom."
  (interactive)
  (let* ((buf  (init/treemacs--editor-buffer))
         (file (and buf (buffer-file-name buf)))
         (win  (ignore-errors (treemacs-get-local-window))))
    (cond
     ((not file) (message "No file buffer to focus."))
     ((not win)  (message "Treemacs window is not visible."))
     (t
      (with-selected-window win
        (let ((project (treemacs--find-project-for-path file)))
          (if (and project (treemacs-goto-file-node file project))
              (treemacs-pulse-on-success)
            (treemacs-pulse-on-failure
             "%s is not under any Treemacs project."
             (propertize file 'face 'font-lock-string-face)))))))))

(defun init/treemacs--button-keymap (on-click)
  "Return a keymap that runs ON-CLICK on `mouse-1'.
Treemacs binds `down-mouse-1' in its mode map to a handler that selects
the window and moves point.  Because that runs on button *press*, it
would otherwise swallow the first click on our buttons and force the user
to click repeatedly.  Shadowing the down/drag/double events here (this
keymap takes precedence over the major-mode map) makes every click land
on ON-CLICK the first time."
  (let ((m (make-sparse-keymap)))
    (define-key m [down-mouse-1]   #'ignore)
    (define-key m [drag-mouse-1]   #'ignore)
    (define-key m [double-mouse-1] #'ignore)
    (define-key m [mouse-1] on-click)
    m))

(defun init/treemacs--button (label help command)
  "Return a clickable LABEL string running COMMAND on `mouse-1'."
  (propertize
   label
   'help-echo help 'mouse-face 'highlight 'face 'init/treemacs-button 'pointer 'hand
   'keymap (init/treemacs--button-keymap
            (lambda (event)
              (interactive "e")
              (with-selected-window (posn-window (event-start event))
                (call-interactively command))))))

(defun init/treemacs--menu-button (label help menu)
  "Return a clickable LABEL string that pops up MENU on `mouse-1'."
  (propertize
   label
   'help-echo help 'mouse-face 'highlight 'face 'init/treemacs-button 'pointer 'hand
   'keymap (init/treemacs--button-keymap
            (lambda (event)
              (interactive "e")
              (let* ((km (easy-menu-create-menu nil menu))
                     (choice (x-popup-menu event km)))
                (when choice
                  (let ((cmd (lookup-key km (apply #'vector choice))))
                    (when (commandp cmd)
                      (with-selected-window (posn-window (event-start event))
                        (call-interactively cmd))))))))))

(defun init/treemacs--buttons-string ()
  "Build the Treemacs button row shown at the top of the buffer."
  (concat
   " "
   (init/treemacs--button "⌖" "Focus current file" #'init/treemacs-focus-current-file) " "
   (init/treemacs--button "⟳" "Refresh" #'treemacs-refresh) " "
   (init/treemacs--button "⊟" "Collapse all" #'treemacs-collapse-all-projects) " "
   (init/treemacs--button "＋" "Add project" #'treemacs-add-project-to-workspace) " "
   (init/treemacs--button "?" "Treemacs help" #'treemacs-common-helpful-hydra) "  "
   (init/treemacs--menu-button
    "❏" "Workspaces: switch / create / edit"
    '(["Switch Workspace…" treemacs-switch-workspace]
      ["Next Workspace"    treemacs-next-workspace]
      "--"
      ["Create Workspace…" treemacs-create-workspace]
      ["Rename Workspace…" treemacs-rename-workspace]
      ["Remove Workspace…" treemacs-remove-workspace]
      "--"
      ["Edit Workspaces…"  treemacs-edit-workspaces]))
   "\n\n"))

(defun init/treemacs-refresh-buttons (&rest _)
  "Ensure the button row overlay exists at the top of the Treemacs buffer."
  (when (derived-mode-p 'treemacs-mode)
    (unless (and (overlayp init/treemacs--buttons-overlay)
                 (overlay-buffer init/treemacs--buttons-overlay))
      (setq init/treemacs--buttons-overlay (make-overlay (point-min) (point-min))))
    (overlay-put init/treemacs--buttons-overlay 'before-string
                 (init/treemacs--buttons-string))))

(add-hook 'treemacs-post-buffer-init-hook #'init/treemacs-refresh-buttons)
(add-hook 'treemacs-post-refresh-hook #'init/treemacs-refresh-buttons)

(provide 'treemacs-setup)
;;; treemacs-setup.el ends here
