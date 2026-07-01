;;; project-panel.el --- Repo registry and project panel -*- lexical-binding: t; -*-

;;; Commentary:

;; A side-window panel managing a small registry of git remotes.
;;
;; The registry is a plain-text file (`init/project-panel-repos-file',
;; one SSH URL per line, # comments allowed) kept inside .emacs.d so it
;; can be version controlled alongside the config.
;;
;; Repositories are cloned into `init/project-panel-directory'
;; (~/.projects); a repo counts as cloned when a directory with its
;; name exists there.  Each entry shows its state (not cloned, branch,
;; clean/dirty, behind upstream) and offers buttons to clone, open via
;; Projectile (registering the project if Projectile does not know it),
;; fetch, and remove.  Clones and fetches run asynchronously.
;;
;; Toggle the panel with the ▦ mode-line button or `bind/project-panel'.
;; Inside the panel: a add, c clone, RET/o open, u fetch, d remove,
;; g refresh, TAB between buttons, q close.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function projectile-add-known-project "projectile")
(declare-function projectile-switch-project-by-name "projectile")

;;;; Customization

(defgroup init/project-panel nil
  "Panel for managing a registry of git repositories."
  :group 'tools)

(defcustom init/project-panel-repos-file
  (expand-file-name "repos" user-emacs-directory)
  "File recording the registered repository URLs, one per line.
Lines starting with # are comments.  Lives in the config directory so
the registry can be version controlled."
  :type 'file
  :group 'init/project-panel)

(defcustom init/project-panel-directory
  (expand-file-name "~/.projects")
  "Directory repositories are cloned into.
A registered repo is considered cloned when a directory with its name
exists here."
  :type 'directory
  :group 'init/project-panel)

(defconst init/project-panel-buffer-name "*Project Panel*"
  "Name of the project panel buffer.")

(defvar init/project-panel--pending (make-hash-table :test #'equal)
  "Map of repo URL to the label of an async git operation in flight.")

;;;; Faces

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

;;;; Registry persistence

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
  "Return the repository name for URL: last path component, sans .git.
Understands scp-style (git@host:user/repo.git) and URL-style
\(ssh://host/path/repo.git) remotes."
  (let* ((trimmed (string-trim-right (string-trim url) "/+"))
         (no-git (if (string-suffix-p ".git" trimmed)
                     (substring trimmed 0 -4)
                   trimmed))
         (start (1+ (max (or (cl-position ?/ no-git :from-end t) -1)
                         (or (cl-position ?: no-git :from-end t) -1)))))
    (substring no-git start)))

(defun init/project-panel--repo-path (url)
  "Return the directory URL is (or would be) cloned into."
  (expand-file-name (init/project-panel--repo-name url)
                    init/project-panel-directory))

;;;; Git status

(defun init/project-panel--git-output (dir &rest args)
  "Run git ARGS in DIR and return trimmed stdout, or nil on failure."
  (with-temp-buffer
    (when (eq 0 (apply #'call-process "git" nil (list t nil) nil
                       "-C" dir args))
      (string-trim (buffer-string)))))

(defun init/project-panel--status (url)
  "Return a plist (:cloned :pending :label :face) describing URL's state."
  (let ((path (init/project-panel--repo-path url))
        (pending (gethash url init/project-panel--pending)))
    (cond
     (pending
      (list :pending t :label pending :face 'init/project-panel-busy))
     ((not (file-directory-p (expand-file-name ".git" path)))
      (list :label "not cloned" :face 'shadow))
     (t
      (let* ((dirty (not (string-empty-p
                          (or (init/project-panel--git-output
                               path "status" "--porcelain")
                              ""))))
             (branch (init/project-panel--git-output
                      path "rev-parse" "--abbrev-ref" "HEAD"))
             (behind (init/project-panel--git-output
                      path "rev-list" "--count" "HEAD..@{upstream}"))
             (behind-n (and behind (string-to-number behind)))
             (behind-p (and behind-n (> behind-n 0)))
             (parts (delq nil
                          (list branch
                                (and dirty "dirty")
                                (and behind-p (format "behind %d" behind-n))
                                (and (not dirty) (not behind-p) "clean")))))
        (list :cloned t
              :label (string-join parts ", ")
              :face (if (or dirty behind-p)
                        'init/project-panel-dirty
                      'init/project-panel-clean)))))))

;;;; Async git operations

(defun init/project-panel--run (url label command dir)
  "Run COMMAND (a list) asynchronously in DIR for URL.
LABEL is shown as the repo's status while the process runs; the panel
re-renders when it finishes."
  (puthash url label init/project-panel--pending)
  (init/project-panel--render)
  (let* ((default-directory dir)
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
         (let ((ok (eq 0 (process-exit-status process)))
               (output (if (buffer-live-p (process-buffer process))
                           (with-current-buffer (process-buffer process)
                             (string-trim (buffer-string)))
                         "")))
           (when (buffer-live-p (process-buffer process))
             (kill-buffer (process-buffer process)))
           (if ok
               (message "%s: %s finished" name label)
             (message "%s: %s failed: %s" name label output)))
         (init/project-panel--render))))))

;;;; Commands

(defun init/project-panel--url-at-point ()
  "Return the repo URL of the panel entry at point, or signal an error."
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
  "Remove URL (or the repo at point) from the registry.
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
  "Clone URL (or the repo at point) into `init/project-panel-directory'."
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
  "Fetch the latest changes for URL (or the repo at point)."
  (interactive)
  (let* ((url (or url (init/project-panel--url-at-point)))
         (path (init/project-panel--repo-path url)))
    (unless (file-directory-p path)
      (user-error "Not cloned yet; clone it first"))
    (init/project-panel--run url "fetching"
                             (list "git" "-C" path "fetch" "--all" "--prune")
                             path)))

(defun init/project-panel-open (&optional url)
  "Open URL's clone (or the repo at point) with Projectile.
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
  "Re-read the registry and repository states."
  (interactive)
  (init/project-panel--render))

;;;; Rendering

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

(defun init/project-panel--insert-repo (url)
  "Insert the panel entry for URL at point."
  (let* ((start (point))
         (name (init/project-panel--repo-name url))
         (status (init/project-panel--status url)))
    (insert " " (propertize name 'face 'init/project-panel-name)
            "  "
            (propertize (format "(%s)" (plist-get status :label))
                        'face (plist-get status :face))
            "\n   "
            (propertize url 'face 'init/project-panel-url)
            "\n   ")
    (cond
     ((plist-get status :pending))     ; no actions while git is running
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
                                  "Remove from the registry")))
    (insert "\n\n")
    (add-text-properties start (point)
                         (list 'init/project-panel-url url))))

(defun init/project-panel--render ()
  "Rebuild the panel buffer, keeping point on the same repo if possible."
  (let ((buffer (get-buffer init/project-panel-buffer-name)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((inhibit-read-only t)
              (at-url (get-text-property (point) 'init/project-panel-url))
              (urls (init/project-panel--read-repos)))
          (erase-buffer)
          (insert "\n " (propertize "Projects" 'face '(:weight bold :height 1.15))
                  "  ")
          (init/project-panel--button
           "[+add]"
           (lambda (_) (call-interactively #'init/project-panel-add-repo))
           nil "Register a new repository URL")
          (insert " ")
          (init/project-panel--button
           "[refresh]"
           (lambda (_) (init/project-panel-refresh))
           nil "Re-read the registry and repo states")
          (insert "\n\n")
          (if (null urls)
              (insert (propertize
                       "  No repositories registered.\n  Press a to add a git remote URL.\n"
                       'face 'shadow))
            (dolist (url urls)
              (init/project-panel--insert-repo url)))
          (insert (propertize
                   (format " clones: %s\n"
                           (abbreviate-file-name init/project-panel-directory))
                   'face 'shadow))
          (goto-char (point-min))
          (when at-url
            (when-let ((pos (text-property-any (point-min) (point-max)
                                               'init/project-panel-url at-url)))
              (goto-char pos))))))))

;;;; Mode and panel window

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

(global-set-key (kbd bind/project-panel) #'init/project-panel-toggle)

(provide 'project-panel)
;;; project-panel.el ends here
