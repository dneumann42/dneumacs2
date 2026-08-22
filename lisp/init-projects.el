;;; init-projects.el --- Projects, sessions and version control -*- lexical-binding: t; -*-

;;; Commentary:

;; Everything that treats a directory as a unit of work.
;;
;; Projectile is the one project system.  Its command map is reachable
;; from every project prefix -- the built-in C-x p, the classic C-c p, and
;; s-p -- so all three behave identically.  project.el still backs
;; `init/project-root' as a fallback.
;;
;; Sessions are per project: switching projects loads that project's
;; window and buffer layout when one has been saved, and starts a fresh
;; session otherwise.  Sessions auto-save, so a restart lands you back
;; where you were.
;;
;; The project panel is a side window over a small registry of git
;; remotes (the `repos' file in this directory, one SSH URL per line).
;; Registered repositories can be cloned, fetched, opened and dropped from
;; the panel, and every clone is kept registered with Projectile.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'transient)
(require 'init-keys)
(require 'init-lib)

(declare-function consult-ripgrep "consult")
(declare-function easysession-get-session-file-path "easysession")
(declare-function easysession-get-session-name "easysession")
(declare-function easysession-reset "easysession")
(declare-function easysession-save "easysession")
(declare-function easysession-switch-to "easysession")
(declare-function projectile-add-known-project "projectile")
(declare-function projectile-find-file "projectile")
(declare-function projectile-remove-known-project "projectile")
(declare-function projectile-switch-project-by-name "projectile")
(defvar consult--grep-history)
(defvar projectile-known-projects)

;;;; Packages

(use-package projectile
  :ensure t
  :demand t
  :bind-keymap (("C-x p" . projectile-command-map)
                ("C-c p" . projectile-command-map)
                ("s-p"   . projectile-command-map))
  :config
  (projectile-mode +1))

(use-package magit
  :bind (("C-x g" . magit-status)))

;; Changed, added and removed line indicators in the fringe, kept in sync
;; with Magit refreshes.
(use-package diff-hl
  :hook (((prog-mode conf-mode text-mode) . diff-hl-mode)
         (magit-post-refresh . diff-hl-magit-post-refresh)))

;; Per-project environments from .envrc via direnv.
(use-package envrc
  :if (executable-find "direnv")
  :hook (after-init . envrc-global-mode))

;; Editable grep buffers: embark-export or the pinned search buffer, then
;; C-c C-p to edit matches in place and apply the edits across files.
(use-package wgrep
  :after grep
  :custom
  (wgrep-auto-save-buffer t))

;;;; Searching a project

(defun init/project-search-live ()
  "Search the project incrementally, results updating as you type."
  (interactive)
  (consult-ripgrep (init/project-root)))

(defun init/project-search-repeat ()
  "Pick one of the previous searches and run it again live."
  (interactive)
  (unless consult--grep-history
    (user-error "No previous searches yet"))
  (consult-ripgrep (init/project-root)
                   (completing-read "Repeat search: " consult--grep-history
                                    nil nil nil 'consult--grep-history)))

(defun init/project-search-buffer (term)
  "Search the project for TERM, keeping every match in its own buffer.
The result is a `grep-mode' buffer named after TERM; it persists until
you kill it, and `g' re-runs the same search."
  (interactive
   (list (read-string "Search project (pinned buffer): "
                      (thing-at-point 'symbol t) 'consult--grep-history)))
  (let ((default-directory (init/project-root)))
    (grep (format (concat "rg --line-number --with-filename --no-heading"
                          " --color=never --smart-case -e %s .")
                  (shell-quote-argument term))))
  (when-let ((buffer (get-buffer "*grep*")))
    (with-current-buffer buffer
      (rename-buffer (format "*search: %s*" term) t))))

(transient-define-prefix init/project-search ()
  "Project search."
  ["Project search"
   ("s" "Search live (results as you type)" init/project-search-live)
   ("r" "Repeat a previous search"          init/project-search-repeat)
   ("b" "Search into a pinned buffer"       init/project-search-buffer)])

;;;; Sessions

(defconst init/session-rename-rewrites
  `((,(expand-file-name "~/.workspace/nest/src/nest/crowdsl.nim")
     . ,(expand-file-name "~/.workspace/nest/src/nest/owldsl.nim"))
    ("~/.workspace/nest/src/nest/crowdsl.nim"
     . "~/.workspace/nest/src/nest/owldsl.nim")
    (,(expand-file-name "~/.workspace/nest/tests/test_crowdsl.nim")
     . ,(expand-file-name "~/.workspace/nest/tests/test_owldsl.nim"))
    ("~/.workspace/nest/tests/test_crowdsl.nim"
     . "~/.workspace/nest/tests/test_owldsl.nim")
    ("crowdsl.nim" . "owldsl.nim")
    ("test_crowdsl.nim" . "test_owldsl.nim")
    ("init-lang-dsl.el" . "init-owl.el")
    (,(expand-file-name "~/.workspace/crow/src/crow.nim")
     . ,(expand-file-name "~/.workspace/owl/src/owl.nim"))
    ("~/.workspace/crow/src/crow.nim"
     . "~/.workspace/owl/src/owl.nim")
    (,(expand-file-name "~/.workspace/crow/src/crow/")
     . ,(expand-file-name "~/.workspace/owl/src/owl/"))
    ("~/.workspace/crow/src/crow/"
     . "~/.workspace/owl/src/owl/")
    (,(expand-file-name "~/.workspace/crow/")
     . ,(expand-file-name "~/.workspace/owl/"))
    ("~/.workspace/crow/" . "~/.workspace/owl/"))
  "Literal text rewrites for saved state from the crow to owl rename.")

(defun init/session-rewrite-text (text)
  "Return TEXT with stale crow/nest session references rewritten."
  (let ((rewritten text))
    (dolist (rewrite init/session-rename-rewrites)
      (setq rewritten
            (string-replace (car rewrite) (cdr rewrite) rewritten)))
    (setq rewritten
          (replace-regexp-in-string
           "\\(\\(?:~\\|/home/dneumann\\)/\\.workspace/\\(?:nest\\|owl\\)/\\(?:[^\"[:space:])#/]+/\\)*[^\"[:space:])#/.]+\\)\\.nest\\>"
           "\\1.owl"
           rewritten
           nil nil))
    (setq rewritten
          (replace-regexp-in-string
           "\\(#!home!dneumann!\\.workspace!\\(?:nest\\|owl\\)!\\(?:[^\"[:space:])#!]+!\\)*[^\"[:space:])#!.]+\\)\\.nest#"
           "\\1.owl#"
           rewritten
           nil nil))
    (replace-regexp-in-string "\\_<crow\\([.-]\\|dsl\\)" "owl\\1"
                              rewritten nil nil)))

(defun init/session-rewrite-file (file)
  "Rewrite stale crow/nest references in saved state FILE."
  (when (and (file-regular-p file)
             (file-readable-p file)
             (file-writable-p file))
    (with-temp-buffer
      (insert-file-contents file)
      (let* ((old (buffer-string))
             (new (init/session-rewrite-text old)))
        (unless (string= old new)
          (init/atomic-write-file
           file
           (lambda (temporary)
             (with-temp-file temporary
               (insert new)))))))))

(defun init/session-rewrite-renamed-paths ()
  "Rewrite saved Emacs state from the crow/nest names to owl names."
  (let* ((state-files (delq nil
                            (list (expand-file-name "recentf" user-emacs-directory)
                                  (expand-file-name "places" user-emacs-directory)
                                  (expand-file-name "history" user-emacs-directory))))
         (session-dir (expand-file-name "easysession" user-emacs-directory))
         (auto-save-list-dir (expand-file-name "auto-save-list" user-emacs-directory)))
    (dolist (file (append state-files
                          (when (file-directory-p session-dir)
                            (directory-files session-dir t "\\`[^.]"))
                          (when (file-directory-p auto-save-list-dir)
                            (directory-files auto-save-list-dir t "\\`\\.saves-"))))
      (init/session-rewrite-file file))))

(use-package easysession
  :ensure t
  :demand t
  :custom
  ;; Auto-save every 2 minutes, plus on exit and on every switch.
  (easysession-save-interval 120)
  (easysession-mode-line-misc-info t)
  ;; Project sessions are created programmatically; never prompt about it.
  (easysession-confirm-new-session nil)
  :config
  (init/session-rewrite-renamed-paths)
  ;; Restore the previous session, frame geometry included, and turn on
  ;; the auto-save mode.
  (easysession-setup))

;; Keep the *scratch* buffer's contents across restarts.  easysession is
;; configured never to kill it, so it follows you between sessions too.
(use-package persistent-scratch
  :ensure t
  :config
  (persistent-scratch-setup-default))

(defun init/session-exists-p (name)
  "Return non-nil when a session called NAME has been saved."
  (file-exists-p (easysession-get-session-file-path name)))

(defun init/session-new (name)
  "Save the current session and start a fresh, empty session called NAME.
Modified file buffers and special buffers, *scratch* included, are left
alone; everything else is closed."
  (interactive "sNew session name: ")
  (let ((name (string-trim name)))
    (when (string-empty-p name)
      (user-error "Session name must not be empty"))
    (when (init/session-exists-p name)
      (user-error "Session %s already exists; load it instead" name))
    (easysession-switch-to name)
    (easysession-reset)
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

(defun init/session-project-name (root)
  "Return the session name used for the project at ROOT."
  (concat "project: "
          (file-name-nondirectory (directory-file-name (expand-file-name root)))))

(defun init/session-projectile-switch-action ()
  "Open the selected project through its session.
Runs as `projectile-switch-project-action', with `default-directory' set
to the project root.  When the project already has a session, load it and
skip the find-file prompt.  Otherwise save the current session, start a
fresh one named after the project, and fall back to Projectile's
find-file."
  (let ((name (init/session-project-name default-directory))
        (root default-directory))
    (cond
     ;; Re-selecting the current project: do not reload, just find a file.
     ((equal name (easysession-get-session-name))
      (projectile-find-file))
     ((init/session-exists-p name)
      (easysession-switch-to name))
     (t
      (easysession-switch-to name)
      (easysession-reset)
      (let ((default-directory root))
        (projectile-find-file))))))

(with-eval-after-load 'projectile
  (setq projectile-switch-project-action
        #'init/session-projectile-switch-action))

;;;; The project panel

(defgroup init/project-panel nil
  "Panel for managing a registry of git repositories."
  :group 'tools)

(defcustom init/project-panel-repos-file
  (expand-file-name "repos" user-emacs-directory)
  "File recording the registered repository URLs, one per line.
Lines starting with # are comments.  It lives in the configuration
directory so the registry can be version controlled."
  :type 'file
  :group 'init/project-panel)

(defcustom init/project-panel-directory (expand-file-name "~/.projects")
  "Directory repositories are cloned into.
A registered repository counts as cloned when a directory with its name
exists here."
  :type 'directory
  :group 'init/project-panel)

(defconst init/project-panel-buffer-name "*Project Panel*"
  "Name of the project panel buffer.")

(defvar init/project-panel--pending (make-hash-table :test #'equal)
  "Map of repository URL to the label of an async git operation in flight.")

(defface init/project-panel-name
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for repository names in the project panel."
  :group 'init/project-panel)

(defface init/project-panel-url
  '((t :inherit shadow))
  "Face for repository URLs in the project panel."
  :group 'init/project-panel)

(defface init/project-panel-clean
  '((t :inherit success))
  "Face for the status of a clean repository."
  :group 'init/project-panel)

(defface init/project-panel-dirty
  '((t :inherit warning))
  "Face for the status of a dirty or outdated repository."
  :group 'init/project-panel)

(defface init/project-panel-busy
  '((t :inherit font-lock-builtin-face :slant italic))
  "Face for the status of a repository with an operation in flight."
  :group 'init/project-panel)

(defface init/project-panel-button
  '((t :inherit link :underline nil :weight bold))
  "Face for the action buttons in the project panel."
  :group 'init/project-panel)

;;;;; Registry

(defun init/project-panel--read-repos ()
  "Return the registered repository URLs as a list of strings."
  (when (file-exists-p init/project-panel-repos-file)
    (with-temp-buffer
      (insert-file-contents init/project-panel-repos-file)
      (cl-remove-if (lambda (line)
                      (or (string-empty-p line)
                          (string-prefix-p "#" line)))
                    (mapcar #'string-trim
                            (split-string (buffer-string) "\n"))))))

(defun init/project-panel--write-repos (urls)
  "Write URLS to `init/project-panel-repos-file', one per line."
  (with-temp-file init/project-panel-repos-file
    (insert "# Repositories managed by the Emacs project panel.\n")
    (dolist (url urls)
      (insert url "\n"))))

(defun init/project-panel--repo-name (url)
  "Return the repository name for URL: its last path component, sans .git.
Understands scp-style (git@host:user/repo.git) and URL-style
\(ssh://host/path/repo.git) remotes."
  (let* ((trimmed (string-trim-right (string-trim url) "/+"))
         (bare (if (string-suffix-p ".git" trimmed)
                   (substring trimmed 0 -4)
                 trimmed))
         (start (1+ (max (or (cl-position ?/ bare :from-end t) -1)
                         (or (cl-position ?: bare :from-end t) -1)))))
    (substring bare start)))

(defun init/project-panel--repo-path (url)
  "Return the directory URL is, or would be, cloned into."
  (expand-file-name (init/project-panel--repo-name url)
                    init/project-panel-directory))

(defun init/project-panel--cloned-p (url)
  "Return non-nil when URL has been cloned into the clone directory."
  (file-directory-p
   (expand-file-name ".git" (init/project-panel--repo-path url))))

;;;;; Projectile registration

(defun init/project-panel--known-root (path)
  "Return PATH in Projectile's canonical known-project spelling."
  (file-name-as-directory (abbreviate-file-name (expand-file-name path))))

(defun init/project-panel--sync-projectile ()
  "Keep Projectile's known projects in step with the panel's clones.
Registers every registered repository that is actually cloned under
`init/project-panel-directory', and drops panel-managed projects that are
no longer cloned or registered.  Projectile projects outside the clone
directory are never touched.  This runs on every panel change but only
writes when the set differs, so it is cheap to call repeatedly."
  (when (require 'projectile nil t)
    (let* ((clone-root (init/project-panel--known-root
                        init/project-panel-directory))
           (desired (delete-dups
                     (delq nil
                           (mapcar
                            (lambda (url)
                              (when (init/project-panel--cloned-p url)
                                (init/project-panel--known-root
                                 (init/project-panel--repo-path url))))
                            (init/project-panel--read-repos)))))
           (managed (seq-filter (lambda (path)
                                  (string-prefix-p clone-root path))
                                projectile-known-projects)))
      (dolist (path desired)
        (unless (member path projectile-known-projects)
          (projectile-add-known-project path)))
      (dolist (path managed)
        (unless (member path desired)
          (projectile-remove-known-project path))))))

;;;;; Repository status

(defun init/project-panel--git-output (directory &rest args)
  "Run git ARGS in DIRECTORY and return trimmed stdout, or nil on failure."
  (with-temp-buffer
    (when (eq 0 (apply #'call-process "git" nil (list t nil) nil
                       "-C" directory args))
      (string-trim (buffer-string)))))

(defun init/project-panel--clone-status (path)
  "Return a status plist describing the existing clone at PATH."
  (let* ((dirty (not (string-empty-p
                      (or (init/project-panel--git-output
                           path "status" "--porcelain")
                          ""))))
         (branch (init/project-panel--git-output
                  path "rev-parse" "--abbrev-ref" "HEAD"))
         (behind (init/project-panel--git-output
                  path "rev-list" "--count" "HEAD..@{upstream}"))
         (behind-count (and behind (string-to-number behind)))
         (behind-p (and behind-count (> behind-count 0)))
         (parts (delq nil
                      (list branch
                            (and dirty "dirty")
                            (and behind-p (format "behind %d" behind-count))
                            (and (not dirty) (not behind-p) "clean")))))
    (list :cloned t
          :label (string-join parts ", ")
          :face (if (or dirty behind-p)
                    'init/project-panel-dirty
                  'init/project-panel-clean))))

(defun init/project-panel--status (url)
  "Return a plist (:cloned :pending :label :face) describing URL's state."
  (let ((pending (gethash url init/project-panel--pending)))
    (cond
     (pending (list :pending t :label pending :face 'init/project-panel-busy))
     ((not (init/project-panel--cloned-p url))
      (list :label "not cloned" :face 'shadow))
     (t (init/project-panel--clone-status
         (init/project-panel--repo-path url))))))

;;;;; Asynchronous git operations

(defun init/project-panel--report (name label process)
  "Report the outcome of PROCESS, which ran LABEL for the repository NAME."
  (let ((succeeded (eq 0 (process-exit-status process)))
        (output (if (buffer-live-p (process-buffer process))
                    (with-current-buffer (process-buffer process)
                      (string-trim (buffer-string)))
                  "")))
    (when (buffer-live-p (process-buffer process))
      (kill-buffer (process-buffer process)))
    (if succeeded
        (message "%s: %s finished" name label)
      (message "%s: %s failed: %s" name label output))))

(defun init/project-panel--run (url label command directory)
  "Run COMMAND, a list, asynchronously in DIRECTORY for URL.
LABEL is shown as the repository's status while the process runs; the
panel re-renders when it finishes."
  (puthash url label init/project-panel--pending)
  (init/project-panel--render)
  (let* ((default-directory directory)
         (name (init/project-panel--repo-name url))
         (buffer (generate-new-buffer (format " *project-panel %s*" name))))
    (make-process
     :name (format "project-panel-%s" name)
     :buffer buffer
     :command command
     :noquery t
     :sentinel
     (lambda (process _event)
       (unless (process-live-p process)
         (remhash url init/project-panel--pending)
         (init/project-panel--report name label process)
         (init/project-panel--render))))))

;;;;; Panel commands

(defun init/project-panel--url-at-point ()
  "Return the repository URL of the panel entry at point, or signal."
  (or (get-text-property (point) 'init/project-panel-url)
      (user-error "No repository at point")))

(defun init/project-panel-add-repo (url)
  "Register the git remote URL in the project panel."
  (interactive "sRepository URL (git remote): ")
  (let ((url (string-trim url))
        (urls (init/project-panel--read-repos)))
    (when (string-empty-p url)
      (user-error "Repository URL must not be empty"))
    (if (member url urls)
        (message "%s is already registered" url)
      (init/project-panel--write-repos (append urls (list url)))
      (init/project-panel--render)
      (message "Registered %s" url))))

(defun init/project-panel-remove-repo (&optional url)
  "Remove URL, or the repository at point, from the registry.
The clone under `init/project-panel-directory' is left untouched."
  (interactive)
  (let ((url (or url (init/project-panel--url-at-point))))
    (when (y-or-n-p (format "Remove %s from the registry? " url))
      (init/project-panel--write-repos
       (delete url (init/project-panel--read-repos)))
      (init/project-panel--render)
      (message "Removed %s (any clone in %s is untouched)"
               url (abbreviate-file-name init/project-panel-directory)))))

(defun init/project-panel-clone (&optional url)
  "Clone URL, or the repository at point, into the clone directory."
  (interactive)
  (let* ((url (or url (init/project-panel--url-at-point)))
         (path (init/project-panel--repo-path url)))
    (when (file-directory-p path)
      (user-error "%s already exists" (abbreviate-file-name path)))
    (make-directory init/project-panel-directory t)
    (init/project-panel--run url "cloning"
                             (list "git" "clone" url path)
                             init/project-panel-directory)))

(defun init/project-panel-update (&optional url)
  "Fetch the latest changes for URL, or for the repository at point."
  (interactive)
  (let* ((url (or url (init/project-panel--url-at-point)))
         (path (init/project-panel--repo-path url)))
    (unless (file-directory-p path)
      (user-error "Not cloned yet; clone it first"))
    (init/project-panel--run url "fetching"
                             (list "git" "-C" path "fetch" "--all" "--prune")
                             path)))

(defun init/project-panel-open (&optional url)
  "Open URL's clone, or the repository at point, with Projectile.
Registers the project with Projectile when it is not already known."
  (interactive)
  (let* ((url (or url (init/project-panel--url-at-point)))
         (path (file-name-as-directory (init/project-panel--repo-path url))))
    (unless (file-directory-p path)
      (user-error "Not cloned yet; clone it first"))
    (require 'projectile)
    (projectile-add-known-project path)
    (projectile-switch-project-by-name path)))

(defun init/project-panel-refresh ()
  "Re-read the registry and the repository states."
  (interactive)
  (init/project-panel--render))

;;;;; Rendering

(defun init/project-panel--button (label action url help)
  "Insert a clickable LABEL running ACTION with URL.  HELP is the tooltip."
  (insert-text-button
   label
   'action (lambda (button)
             (funcall action (button-get button 'init/project-panel-url)))
   'init/project-panel-url url
   'face 'init/project-panel-button
   'follow-link t
   'help-echo help))

(defun init/project-panel--insert-actions (url status)
  "Insert the action buttons for URL, given its STATUS plist."
  (cond
   ;; No actions while a git process is running for this repository.
   ((plist-get status :pending))
   ((plist-get status :cloned)
    (init/project-panel--button "[open]" #'init/project-panel-open url
                                "Open with Projectile")
    (insert " ")
    (init/project-panel--button "[update]" #'init/project-panel-update url
                                "Fetch the latest changes")
    (insert " ")
    (init/project-panel--button "[remove]" #'init/project-panel-remove-repo url
                                "Remove from the registry"))
   (t
    (init/project-panel--button "[clone]" #'init/project-panel-clone url
                                (format "git clone into %s"
                                        (abbreviate-file-name
                                         init/project-panel-directory)))
    (insert " ")
    (init/project-panel--button "[remove]" #'init/project-panel-remove-repo url
                                "Remove from the registry"))))

(defun init/project-panel--insert-repo (url)
  "Insert the panel entry for URL at point."
  (let ((start (point))
        (status (init/project-panel--status url)))
    (insert " "
            (propertize (init/project-panel--repo-name url)
                        'face 'init/project-panel-name)
            "  "
            (propertize (format "(%s)" (plist-get status :label))
                        'face (plist-get status :face))
            "\n   "
            (propertize url 'face 'init/project-panel-url)
            "\n   ")
    (init/project-panel--insert-actions url status)
    (insert "\n\n")
    (add-text-properties start (point) (list 'init/project-panel-url url))))

(defun init/project-panel--insert-header ()
  "Insert the panel title and its global action buttons."
  (insert "\n "
          (propertize "Projects" 'face '(:weight bold :height 1.15))
          "  ")
  (init/project-panel--button
   "[+add]" (lambda (_) (call-interactively #'init/project-panel-add-repo))
   nil "Register a new repository URL")
  (insert " ")
  (init/project-panel--button
   "[refresh]" (lambda (_) (init/project-panel-refresh))
   nil "Re-read the registry and repository states")
  (insert "\n\n"))

(defun init/project-panel--render ()
  "Rebuild the panel buffer, keeping point on the same repository.
Also syncs the clone set into Projectile's known projects; that runs even
when the panel window is closed, so an asynchronous clone or fetch
finishing in the background still updates Projectile."
  (init/project-panel--sync-projectile)
  (let ((buffer (get-buffer init/project-panel-buffer-name)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((inhibit-read-only t)
              (at-url (get-text-property (point) 'init/project-panel-url))
              (urls (init/project-panel--read-repos)))
          (erase-buffer)
          (init/project-panel--insert-header)
          (if (null urls)
              (insert (propertize
                       (concat "  No repositories registered.\n"
                               "  Press a to add a git remote URL.\n")
                       'face 'shadow))
            (dolist (url urls)
              (init/project-panel--insert-repo url)))
          (insert (propertize
                   (format " clones: %s\n"
                           (abbreviate-file-name init/project-panel-directory))
                   'face 'shadow))
          (goto-char (point-min))
          (when at-url
            (when-let ((position (text-property-any
                                  (point-min) (point-max)
                                  'init/project-panel-url at-url)))
              (goto-char position))))))))

;;;;; Panel mode and window

(defvar init/project-panel-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "a") #'init/project-panel-add-repo)
    (define-key map (kbd "c") #'init/project-panel-clone)
    (define-key map (kbd "o") #'init/project-panel-open)
    (define-key map (kbd "RET") #'init/project-panel-open)
    (define-key map (kbd "u") #'init/project-panel-update)
    (define-key map (kbd "d") #'init/project-panel-remove-repo)
    (define-key map (kbd "g") #'init/project-panel-refresh)
    (define-key map (kbd "TAB") #'forward-button)
    (define-key map (kbd "<backtab>") #'backward-button)
    map)
  "Keymap for `init/project-panel-mode'.")

(define-derived-mode init/project-panel-mode special-mode "Projects"
  "Major mode for the project panel.

\\{init/project-panel-mode-map}"
  (setq-local truncate-lines t)
  (hl-line-mode 1))

(defun init/project-panel-show ()
  "Show the project panel in a side window and refresh it."
  (interactive)
  (let ((buffer (get-buffer-create init/project-panel-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'init/project-panel-mode)
        (init/project-panel-mode)))
    (init/project-panel--render)
    (select-window
     (display-buffer-in-side-window
      buffer
      '((side . right)
        (slot . 0)
        (window-width . 46)
        (window-parameters . ((no-delete-other-windows . t))))))))

(defun init/project-panel-toggle ()
  "Toggle the project panel side window."
  (interactive)
  (let* ((buffer (get-buffer init/project-panel-buffer-name))
         (window (and buffer (get-buffer-window buffer))))
    (if (window-live-p window)
        (delete-window window)
      (init/project-panel-show))))

;;;; Keybindings

(global-set-key (kbd bind/project-panel) #'init/project-panel-toggle)
(global-set-key (kbd bind/session-menu) #'init/session-menu)

(provide 'init-projects)
;;; init-projects.el ends here
