;;; init-treemacs.el --- The file tree -*- lexical-binding: t; -*-

;;; Commentary:

;; Treemacs as a left side window, with a sticky toolbar in its header
;; line and a guard that keeps $HOME from ever becoming a project root.
;;
;; That guard matters: a Treemacs project rooted at $HOME makes Treemacs
;; walk the entire home directory -- every hidden cache, every GVFS mount
;; -- whenever the node is expanded or `treemacs-follow-mode' reveals a
;; file under it, which freezes Emacs, since almost every file lives under
;; $HOME.  Such a project keeps coming back through the persisted
;; workspace file, so it is stripped every time that file is read and
;; refused at the single point where projects are added.
;;
;; Which workspace was open is remembered across restarts too: Treemacs
;; persists the workspaces themselves, but not the choice between them.

;;; Code:

(require 'seq)
(require 'init-persist)
(require 'init-toolbar)

(declare-function treemacs "treemacs")
(declare-function treemacs-current-workspace "treemacs-workspaces")
(declare-function treemacs-default-buffer-name "treemacs")
(declare-function treemacs-do-switch-workspace "treemacs-workspaces")
(declare-function treemacs-filewatch-mode "treemacs")
(declare-function treemacs-find-workspace-by-name "treemacs-workspaces")
(declare-function treemacs-follow-mode "treemacs")
(declare-function treemacs-fringe-indicator-mode "treemacs")
(declare-function treemacs-get-local-window "treemacs-scope")
(declare-function treemacs-git-commit-diff-mode "treemacs")
(declare-function treemacs-git-mode "treemacs")
(declare-function treemacs-goto-file-node "treemacs-core-utils")
(declare-function treemacs-hide-gitignored-files-mode "treemacs")
(declare-function treemacs-pulse-on-failure "treemacs-logging")
(declare-function treemacs-pulse-on-success "treemacs-logging")
(declare-function treemacs-workspace->name "treemacs-workspaces")
(declare-function treemacs--find-project-for-path "treemacs-core-utils")

;;;; Header-line toolbar

(defun init/treemacs--editor-buffer ()
  "Return the most recently active file-visiting buffer outside Treemacs."
  (seq-find (lambda (buffer)
              (and (buffer-file-name buffer)
                   (not (eq (buffer-local-value 'major-mode buffer)
                            'treemacs-mode))))
            (buffer-list)))

(defun init/treemacs-focus-current-file ()
  "Reveal, in the Treemacs tree, the file of the last active editor buffer."
  (interactive)
  (let* ((buffer (init/treemacs--editor-buffer))
         (file (and buffer (buffer-file-name buffer)))
         (window (ignore-errors (treemacs-get-local-window))))
    (cond
     ((not file) (message "No file buffer to focus."))
     ((not window) (message "Treemacs window is not visible."))
     (t
      (with-selected-window window
        (let ((project (treemacs--find-project-for-path file)))
          (if (and project (treemacs-goto-file-node file project))
              (treemacs-pulse-on-success)
            (treemacs-pulse-on-failure
             "%s is not under any Treemacs project."
             (propertize file 'face 'font-lock-string-face)))))))))

(defun init/treemacs--workspace-menu ()
  "Return the toolbar button opening the workspace menu."
  (init/toolbar-menu-button
   "❏" "Workspaces: switch / create / edit"
   '(["Switch Workspace…" treemacs-switch-workspace]
     ["Next Workspace"    treemacs-next-workspace]
     "--"
     ["Create Workspace…" treemacs-create-workspace]
     ["Rename Workspace…" treemacs-rename-workspace]
     ["Remove Workspace…" treemacs-remove-workspace]
     "--"
     ["Edit Workspaces…"  treemacs-edit-workspaces])))

(defun init/treemacs--buttons-string ()
  "Build the sticky Treemacs toolbar row shown in its header line."
  (init/toolbar-string
   '("⌖" "Focus current file" init/treemacs-focus-current-file)
   '("⟳" "Refresh" treemacs-refresh)
   '("⊟" "Collapse all" treemacs-collapse-all-projects)
   '("＋" "Add project" treemacs-add-project-to-workspace)
   '("?" "Treemacs help" treemacs-common-helpful-hydra)
   (init/treemacs--workspace-menu)))

;;;; Configuration

(defun init/treemacs--configure ()
  "Apply the Treemacs settings for this configuration."
  (setq treemacs-buffer-name-function            #'treemacs-default-buffer-name
        treemacs-buffer-name-prefix              " *Treemacs-Buffer-"
        treemacs-deferred-git-apply-delay        0.5
        treemacs-directory-name-transformer      #'identity
        treemacs-display-in-side-window          t
        treemacs-eldoc-display                   'simple
        treemacs-expand-after-init               t
        treemacs-file-event-delay                2000
        treemacs-file-extension-regex            "\\.[^.]*\\'"
        treemacs-file-follow-delay               0.2
        treemacs-file-name-transformer           #'identity
        treemacs-find-workspace-method           'find-for-file-or-pick-first
        treemacs-follow-after-init               t
        treemacs-git-command-pipe                ""
        treemacs-goto-tag-strategy               'refetch-index
        treemacs-header-scroll-indicators         '(nil . "^^^^^^")
        treemacs-hide-dot-git-directory          t
        treemacs-hide-dot-jj-directory           t
        treemacs-indentation                     2
        treemacs-indentation-string              " "
        treemacs-is-never-other-window           nil
        treemacs-litter-directories              '("/node_modules" "/.venv" "/.cask")
        treemacs-max-git-entries                 5000
        treemacs-missing-project-action          'ask
        treemacs-move-files-by-mouse-dragging    t
        treemacs-move-forward-on-expand          nil
        treemacs-no-delete-other-windows         t
        treemacs-no-png-images                   nil
        treemacs-persist-file                    (expand-file-name
                                                  ".cache/treemacs-persist"
                                                  user-emacs-directory)
        treemacs-position                        'left
        treemacs-project-follow-cleanup          nil
        treemacs-project-follow-into-home        nil
        treemacs-read-string-input               'from-minibuffer
        treemacs-recenter-after-file-follow      nil
        treemacs-recenter-after-project-expand   'on-distance
        treemacs-recenter-after-project-jump     'always
        treemacs-recenter-after-tag-follow       nil
        treemacs-recenter-distance               0.1
        treemacs-select-when-already-in-treemacs 'move-back
        treemacs-show-cursor                     nil
        treemacs-show-hidden-files               t
        treemacs-silent-filewatch                nil
        treemacs-silent-refresh                  nil
        treemacs-sorting                         'alphabetic-asc
        treemacs-space-between-root-nodes        t
        treemacs-tag-follow-cleanup              t
        treemacs-tag-follow-delay                1.5
        treemacs-text-scale                      nil
        treemacs-user-header-line-format         '("%e" (:eval (init/treemacs--buttons-string)))
        treemacs-user-mode-line-format           nil
        treemacs-wide-toggle-width               70
        treemacs-width                           35
        treemacs-width-increment                 1
        treemacs-width-is-initially-locked       t
        treemacs-workspace-switch-cleanup        nil)

  ;; Collapsing several directory levels into one node needs the Python
  ;; helper; without it the walk happens in Lisp and is far too slow.
  (setq treemacs-collapse-dirs
        (if (bound-and-true-p treemacs-python-executable) 3 0))

  ;; Never descend into GVFS's virtual metadata and mount trees.  Their
  ;; readdir and stat calls can block for minutes, and with
  ;; `treemacs-collapse-dirs' walking several levels deep this once froze
  ;; startup for good when a project root sat above
  ;; ~/.local/share/gvfs-metadata.
  (add-to-list 'treemacs-ignored-file-predicates
               (lambda (file _absolute-path)
                 (member file '("gvfs-metadata" ".gvfs")))))

(defun init/treemacs--enable-modes ()
  "Turn on the Treemacs minor modes this configuration uses."
  (treemacs-follow-mode t)
  (treemacs-filewatch-mode t)
  (treemacs-fringe-indicator-mode 'always)
  (when (bound-and-true-p treemacs-python-executable)
    (treemacs-git-commit-diff-mode t))
  ;; Deferred git highlighting also needs the Python helper; plain
  ;; highlighting only needs git itself.
  (when (executable-find "git")
    (treemacs-git-mode
     (if (bound-and-true-p treemacs-python-executable) 'deferred 'simple)))
  (treemacs-hide-gitignored-files-mode nil))

;;;; Remembering the open workspace

;; Treemacs persists the workspaces but not the choice between them:
;; `treemacs-find-workspace-method' re-derives that on every start and
;; falls back to whichever workspace is first in the list.

(defvar init/treemacs-workspace nil
  "Name of the Treemacs workspace to reopen at startup.
Nil leaves the choice to `treemacs-find-workspace-method'.  A name that
matches no workspace is ignored.  Restored by `init/persist-load' before
this module loads.")

(init/persist-register 'init/treemacs-workspace)

(defun init/treemacs-remember-workspace (&rest _)
  "Record the current Treemacs workspace as the one to reopen.
Runs from the workspace switch and rename hooks, whose arguments are not
needed here."
  (when-let* ((workspace (ignore-errors (treemacs-current-workspace)))
              (name (treemacs-workspace->name workspace)))
    (unless (equal name init/treemacs-workspace)
      (init/persist-set 'init/treemacs-workspace name))))

(defun init/treemacs-restore-workspace ()
  "Reopen the workspace named by `init/treemacs-workspace'.
Deliberately does not record what it ends up on: when the name matches no
workspace, Treemacs falls back to its own choice, and writing that back
would discard the remembered name for good."
  (when init/treemacs-workspace
    ;; This call is what reads Treemacs's persist file, so the by-name
    ;; lookup it populates has to come after it.
    (let ((current (treemacs-current-workspace)))
      (when-let* ((workspace (treemacs-find-workspace-by-name
                             init/treemacs-workspace)))
        (unless (eq workspace current)
          (treemacs-do-switch-workspace workspace))))))

;; Not `treemacs-workspace-first-found-functions', the hook that looks
;; built for this: Treemacs runs it with the variable's value instead of
;; its symbol, so putting anything on it breaks every call to
;; `treemacs-current-workspace'.
(add-hook 'treemacs-switch-workspace-hook #'init/treemacs-remember-workspace)
(add-hook 'treemacs-rename-workspace-functions #'init/treemacs-remember-workspace)

(use-package treemacs
  :ensure t
  :defer t
  :bind (:map global-map
              ("C-x t 1"   . treemacs-delete-other-windows)
              ("C-x t t"   . treemacs)
              ("C-x t d"   . treemacs-select-directory)
              ("C-x t B"   . treemacs-bookmark)
              ("C-x t C-t" . treemacs-find-file)
              ("C-x t M-t" . treemacs-find-tag)
              ("M-0"       . treemacs-select-window))
  :config
  (init/treemacs--configure)
  (init/treemacs--enable-modes)
  ;; After the modes: switching workspaces consults
  ;; `treemacs-hide-gitignored-files-mode', which is only bound once
  ;; `init/treemacs--enable-modes' has run.
  (init/treemacs-restore-workspace))

;; Never `defvar' `treemacs-project-map' here as a fallback: Treemacs
;; defines it with a plain defvar in treemacs-mode.el, so a prior defvar
;; wins and Treemacs wires an empty keymap into its mode map, silently
;; breaking every p-prefixed project command.
(with-eval-after-load 'treemacs-mode
  (require 'treemacs-projectile nil t))

(use-package treemacs-icons-dired
  :ensure t
  :hook (dired-mode . treemacs-icons-dired-enable-once))

(use-package treemacs-magit
  :ensure t
  :after (treemacs magit))

;;;; Refusing $HOME as a project root

(defconst init/treemacs-home-block-log
  (expand-file-name ".cache/treemacs-home-block.log" user-emacs-directory)
  "File recording attempts to add $HOME as a Treemacs project.")

(defun init/treemacs--home-path-p (path)
  "Return non-nil when PATH resolves to $HOME."
  (and (stringp path)
       (equal (file-name-as-directory (expand-file-name path))
              (expand-file-name "~/"))))

(defun init/treemacs--workspace-blocks (lines)
  "Group persisted-workspace LINES into header-led blocks.
Each \"* workspace\" or \"** project\" line starts a new block that owns
the lines below it."
  (let (blocks current)
    (dolist (line lines)
      (when (or (string-prefix-p "* " line) (string-prefix-p "** " line))
        (when current (push (nreverse current) blocks))
        (setq current nil))
      (push line current))
    (when current (push (nreverse current) blocks))
    (nreverse blocks)))

(defun init/treemacs--home-project-block-p (block)
  "Return non-nil when persisted-workspace BLOCK describes a $HOME project."
  (seq-some (lambda (line)
              (and (string-match "\\`[[:space:]]*- path :: \\(.*\\)\\'" line)
                   (init/treemacs--home-path-p (match-string 1 line))))
            block))

(defun init/treemacs--reject-home-projects (lines)
  "Drop any $HOME-rooted project from persisted-workspace LINES.
LINES are as returned by `treemacs--read-persist-lines': one string per
non-blank line.  A workspace left with no projects is dropped whole, so
the result stays valid -- Treemacs requires at least one project per
workspace, and recreates a default workspace when the input is empty."
  (let (result pending-workspace)
    (dolist (block (init/treemacs--workspace-blocks lines))
      (let ((header (car block)))
        (cond
         ((string-prefix-p "* " header)
          ;; Hold the workspace header back until one of its projects
          ;; actually survives.
          (setq pending-workspace block))
         ((string-prefix-p "** " header)
          (unless (init/treemacs--home-project-block-p block)
            (when pending-workspace
              (dolist (line pending-workspace) (push line result))
              (setq pending-workspace nil))
            (dolist (line block) (push line result)))))))
    (nreverse result)))

(defun init/treemacs--log-home-block (name)
  "Append a backtrace for a refused $HOME project called NAME to the log."
  (ignore-errors
    (with-temp-buffer
      (insert (format "\n=== %s  blocked $HOME project add (name=%S) ===\n"
                      (format-time-string "%F %T") name))
      (insert (format "this-command=%S  real-this-command=%S\n"
                      this-command real-this-command))
      (dolist (frame (backtrace-frames))
        (insert (format "  %S\n" (nth 1 frame))))
      (append-to-file (point-min) (point-max) init/treemacs-home-block-log))))

(defun init/treemacs--block-home-project (original path name &rest args)
  "Refuse to add $HOME as a Treemacs project.
ORIGINAL is the wrapped project adder, called with PATH, NAME and ARGS
for every other path.  Filtering the persisted workspace only helps at
load time; something re-adds $HOME during a session and then persists it,
so the add is blocked at its single choke point regardless of the caller
and a backtrace is logged so the culprit is visible.  Returns the
documented `invalid-path' result, so callers stay happy."
  (if (init/treemacs--home-path-p path)
      (progn
        (init/treemacs--log-home-block name)
        (message "Treemacs: refused $HOME as a project root (see %s)"
                 (file-name-nondirectory init/treemacs-home-block-log))
        `(invalid-path "Refusing $HOME as a Treemacs project root."))
    (apply original path name args)))

(with-eval-after-load 'treemacs
  (advice-add 'treemacs--read-persist-lines
              :filter-return #'init/treemacs--reject-home-projects)
  (advice-add 'treemacs-do-add-project-to-workspace
              :around #'init/treemacs--block-home-project))

(provide 'init-treemacs)
;;; init-treemacs.el ends here
