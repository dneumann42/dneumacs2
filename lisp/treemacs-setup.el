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
          treemacs-user-header-line-format         '("%e" (:eval (init/treemacs--buttons-string)))
          treemacs-wide-toggle-width               70
          treemacs-width                           35
          treemacs-width-increment                 1
          treemacs-width-is-initially-locked       t
          treemacs-workspace-switch-cleanup        nil)

    (setq treemacs-collapse-dirs
          (if (bound-and-true-p treemacs-python-executable) 3 0))

    ;; Never descend into GVFS's virtual metadata/mount trees.  Their
    ;; `readdir'/`stat' calls can block for minutes, and with
    ;; `treemacs-collapse-dirs' walking several levels deep this once
    ;; froze startup for good when a project root sat above
    ;; ~/.local/share/gvfs-metadata.  Ignoring them keeps expansion,
    ;; collapse-dirs and filewatch from ever touching that path.
    (add-to-list 'treemacs-ignored-file-predicates
                 (lambda (file _absolute-path)
                   (member file '("gvfs-metadata" ".gvfs"))))

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

;; Note: do NOT defvar `treemacs-project-map' here as a fallback.
;; Treemacs defines it with a plain defvar in treemacs-mode.el, so a
;; prior defvar wins and Treemacs would wire an empty keymap into its
;; mode map, silently breaking every `p'-prefixed project command.
(with-eval-after-load 'treemacs-mode
  (require 'treemacs-projectile nil t))

(use-package treemacs-icons-dired
  :hook (dired-mode . treemacs-icons-dired-enable-once)
  :ensure t)

(use-package treemacs-magit
  :after (treemacs magit)
  :ensure t)

;;;; Treemacs buffer buttons

(declare-function treemacs-current-workspace "treemacs-workspaces")
(declare-function treemacs-default-buffer-name "treemacs")
(declare-function treemacs-find-file "treemacs")
(declare-function treemacs-find-file-node "treemacs-core-utils")
(declare-function treemacs-filewatch-mode "treemacs")
(declare-function treemacs-follow-mode "treemacs")
(declare-function treemacs-fringe-indicator-mode "treemacs")
(declare-function treemacs-get-local-window "treemacs-scope")
(declare-function treemacs-git-mode "treemacs")
(declare-function treemacs-goto-file-node "treemacs-core-utils")
(declare-function treemacs-hide-gitignored-files-mode "treemacs")
(declare-function treemacs--find-project-for-path "treemacs-core-utils")
(declare-function treemacs-pulse-on-success "treemacs-logging")
(declare-function treemacs-pulse-on-failure "treemacs-logging")

(defun init/treemacs--editor-buffer ()
  "Return the most recently active file-visiting buffer outside Treemacs."
  (seq-find (lambda (buf)
              (and (buffer-file-name buf)
                   (not (eq (buffer-local-value 'major-mode buf) 'treemacs-mode))))
            (buffer-list)))

(defun init/treemacs-focus-current-file ()
  "Reveal, in the Treemacs tree, the file of the last active editor buffer."
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

(defun init/treemacs--buttons-string ()
  "Build the sticky Treemacs toolbar row for the header line."
  (init/toolbar-string
   '("⌖" "Focus current file" init/treemacs-focus-current-file)
   '("⟳" "Refresh" treemacs-refresh)
   '("⊟" "Collapse all" treemacs-collapse-all-projects)
   '("＋" "Add project" treemacs-add-project-to-workspace)
   '("?" "Treemacs help" treemacs-common-helpful-hydra)
   (init/toolbar-menu-button
    "❏" "Workspaces: switch / create / edit"
    '(["Switch Workspace…" treemacs-switch-workspace]
      ["Next Workspace"    treemacs-next-workspace]
      "--"
      ["Create Workspace…" treemacs-create-workspace]
      ["Rename Workspace…" treemacs-rename-workspace]
      ["Remove Workspace…" treemacs-remove-workspace]
      "--"
      ["Edit Workspaces…"  treemacs-edit-workspaces]))))

;;;; Guard against a $HOME-rooted project

;; A Treemacs project whose root is $HOME forces Treemacs to walk the
;; entire home directory (every hidden cache, GVFS mount, ...) whenever
;; that node is expanded or `treemacs-follow-mode' reveals a file under
;; it -- which freezes Emacs, since almost every file lives under $HOME.
;; Such a project keeps coming back through the persisted workspace
;; file, so rather than edit that file (which a running Emacs rewrites
;; on exit) we strip it every time the workspace is read, before it is
;; ever parsed or expanded.

(defun init/treemacs--reject-home-projects (lines)
  "Drop any $HOME-rooted project from persisted-workspace LINES.
LINES are as returned by `treemacs--read-persist-lines': one string per
non-blank line.  A workspace left with no projects is dropped whole, so
the result stays valid (Treemacs requires at least one project per
workspace, and recreates a default workspace when the input is empty)."
  (let ((home (expand-file-name "~/"))
        (blocks '())
        (cur '()))
    ;; Split the lines into header-led blocks: each "* workspace" or
    ;; "** project" line starts a new block that owns the lines below it.
    (dolist (line lines)
      (when (or (string-prefix-p "* " line) (string-prefix-p "** " line))
        (when cur (push (nreverse cur) blocks))
        (setq cur '()))
      (push line cur))
    (when cur (push (nreverse cur) blocks))
    ;; Re-emit blocks, skipping $HOME projects and holding each workspace
    ;; header back until one of its projects actually survives.
    (let (out pending-ws)
      (dolist (block (nreverse blocks))
        (let ((header (car block)))
          (cond
           ((string-prefix-p "* " header)
            (setq pending-ws block))
           ((string-prefix-p "** " header)
            (unless (seq-some
                     (lambda (l)
                       (and (string-match "\\`[[:space:]]*- path :: \\(.*\\)\\'" l)
                            (equal (file-name-as-directory
                                    (expand-file-name (match-string 1 l)))
                                   home)))
                     block)
              (when pending-ws
                (dolist (l pending-ws) (push l out))
                (setq pending-ws nil))
              (dolist (l block) (push l out)))))))
      (nreverse out))))

(defun init/treemacs--home-path-p (path)
  "Return non-nil when PATH resolves to $HOME."
  (and (stringp path)
       (equal (file-name-as-directory (expand-file-name path))
              (expand-file-name "~/"))))

(defun init/treemacs--block-home-project (fn path name &rest args)
  "Refuse to add $HOME as a Treemacs project (FN is the wrapped adder).
Filtering the persisted workspace only helps at load time; something
re-adds $HOME during a session and then persists it.  This blocks the
add at its single choke point regardless of the caller, and appends a
backtrace to .cache/treemacs-home-block.log so the culprit is visible.
Returns the documented `invalid-path' result so callers stay happy."
  (if (init/treemacs--home-path-p path)
      (progn
        (ignore-errors
          (let ((log (expand-file-name ".cache/treemacs-home-block.log"
                                       user-emacs-directory)))
            (with-temp-buffer
              (insert (format "\n=== %s  blocked $HOME project add (name=%S) ===\n"
                              (format-time-string "%F %T") name))
              (insert (format "this-command=%S  real-this-command=%S\n"
                              this-command real-this-command))
              (dolist (frame (backtrace-frames))
                (insert (format "  %S\n" (nth 1 frame))))
              (append-to-file (point-min) (point-max) log))))
        (message "Treemacs: refused $HOME as a project root (see treemacs-home-block.log)")
        `(invalid-path "Refusing $HOME as a Treemacs project root."))
    (apply fn path name args)))

(with-eval-after-load 'treemacs
  (advice-add 'treemacs--read-persist-lines
              :filter-return #'init/treemacs--reject-home-projects)
  (advice-add 'treemacs-do-add-project-to-workspace
              :around #'init/treemacs--block-home-project))

(provide 'treemacs-setup)
;;; treemacs-setup.el ends here
