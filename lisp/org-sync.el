;;; org-sync.el --- Automatic Git synchronization for Org files -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'subr-x)

(defgroup init/org-sync nil
  "Automatic synchronization of the personal Org repository."
  :group 'org)

(defcustom init/org-sync-directory (expand-file-name "~/.org/")
  "Local checkout containing personal Org files."
  :type 'directory)

(defcustom init/org-sync-remote
  "ssh://git@codeberg.org/dneumann42/org.git"
  "Git remote used to create `init/org-sync-directory'."
  :type 'string)

(defcustom init/org-sync-idle-delay 15
  "Idle seconds after a save before committing and pushing Org changes."
  :type 'number)

(defvar init/org-sync--timer nil)
(defvar init/org-sync--process nil)
(defvar init/org-sync--pending nil)
(defvar init/org-sync--inhibit nil)
(defvar init/org-sync--process-buffer " *org-git-sync*")

(defun init/org-sync--git (&rest arguments)
  "Run Git with ARGUMENTS in the Org repository.
Return a cons of exit status and trimmed combined output."
  (with-temp-buffer
    (let ((status (apply #'process-file "git" nil t nil
                         "-C" init/org-sync-directory arguments)))
      (cons status (string-trim (buffer-string))))))

(defun init/org-sync--git-success (&rest arguments)
  "Run Git with ARGUMENTS and return its output, signaling on failure."
  (pcase-let ((`(,status . ,output) (apply #'init/org-sync--git arguments)))
    (unless (and (integerp status) (zerop status))
      (error "git %s failed%s"
             (string-join arguments " ")
             (if (string-empty-p output) "" (concat ": " output))))
    output))

(defun init/org-sync-ensure-repository ()
  "Clone the Org repository when its checkout does not exist."
  (cond
   ((file-directory-p (expand-file-name ".git" init/org-sync-directory)) t)
   ((file-exists-p init/org-sync-directory)
    (error "%s exists but is not a Git checkout" init/org-sync-directory))
   (t
    (make-directory (file-name-directory
                     (directory-file-name init/org-sync-directory)) t)
    (with-temp-buffer
      (let ((status (process-file "git" nil t nil "clone"
                                  init/org-sync-remote
                                  (directory-file-name
                                   init/org-sync-directory))))
        (unless (and (integerp status) (zerop status))
          (error "Unable to clone Org repository: %s"
                 (string-trim (buffer-string))))))
    t)))

(defun init/org-sync--org-file-p (file)
  "Return non-nil when FILE is an Org file in the synchronized checkout."
  (and file
       (string-equal (downcase (or (file-name-extension file) "")) "org")
       (file-in-directory-p (expand-file-name file)
                            init/org-sync-directory)))

(defun init/org-sync--save-repository-buffers ()
  "Save modified file buffers belonging to the Org repository."
  (let ((init/org-sync--inhibit t))
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (and buffer-file-name
                   (buffer-modified-p)
                   (file-in-directory-p buffer-file-name
                                        init/org-sync-directory))
          (save-buffer))))))

(defun init/org-sync--modified-repository-buffers-p ()
  "Return non-nil when a repository file buffer has unsaved edits."
  (cl-some (lambda (buffer)
             (with-current-buffer buffer
               (and buffer-file-name
                    (buffer-modified-p)
                    (file-in-directory-p buffer-file-name
                                         init/org-sync-directory))))
           (buffer-list)))

(defun init/org-sync--unmerged-files ()
  "Return unresolved files in the Org repository."
  (cdr (init/org-sync--git "diff" "--name-only" "--diff-filter=U")))

(defun init/org-sync--operation-in-progress ()
  "Return the Git operation currently awaiting attention, or nil."
  (cl-loop for (name . marker) in '(("rebase" . "rebase-merge")
                                    ("rebase" . "rebase-apply")
                                    ("merge" . "MERGE_HEAD")
                                    ("cherry-pick" . "CHERRY_PICK_HEAD")
                                    ("revert" . "REVERT_HEAD"))
           for path = (cdr (init/org-sync--git "rev-parse" "--git-path" marker))
           when (and (not (string-empty-p path))
                     (file-exists-p
                      (if (file-name-absolute-p path)
                          path
                        (expand-file-name path init/org-sync-directory))))
           return name))

(defun init/org-sync--open-magit (reason)
  "Open Magit for the Org repository and report REASON."
  (message "Org sync needs attention: %s" reason)
  (require 'magit)
  (magit-status init/org-sync-directory))

(defun init/org-sync--ensure-no-conflict ()
  "Stop automatic synchronization while unresolved conflicts exist."
  (let ((files (init/org-sync--unmerged-files))
        (operation (init/org-sync--operation-in-progress)))
    (when (or operation (not (string-empty-p files)))
      (init/org-sync--open-magit
       (if (string-empty-p files)
           (format "finish the interrupted %s" operation)
         (format "resolve conflicts in %s" (string-replace "\n" ", " files))))
      (user-error "Resolve the Org Git conflict in Magit before editing"))))

(defun init/org-sync--upstream ()
  "Return the current branch's upstream, or nil."
  (pcase-let ((`(,status . ,output)
               (init/org-sync--git "rev-parse" "--abbrev-ref"
                                    "--symbolic-full-name" "@{upstream}")))
    (and (zerop status) (not (string-empty-p output)) output)))

(defun init/org-sync--commit-local-changes ()
  "Stage and commit local changes, amending an unpushed autosync commit."
  (init/org-sync--git-success "add" "--all")
  (unless (zerop (car (init/org-sync--git "diff" "--cached" "--quiet")))
    (let* ((upstream (init/org-sync--upstream))
           (ahead (and upstream
                       (string-to-number
                        (init/org-sync--git-success
                         "rev-list" "--count" (concat upstream "..HEAD")))))
           (subject (cdr (init/org-sync--git "log" "-1" "--format=%s")))
           (amend (and ahead (> ahead 0)
                       (string-prefix-p "autosync:" subject))))
      (if amend
          (init/org-sync--git-success "commit" "--amend" "--no-edit")
        (init/org-sync--git-success
         "commit" "-m" (format-time-string "autosync: %Y-%m-%d %H:%M:%S"))))))

(defun init/org-sync--pull-and-push ()
  "Synchronously fetch, rebase onto the upstream, and push."
  (init/org-sync--git-success "fetch" "--prune" "origin")
  (when-let ((upstream (init/org-sync--upstream)))
    (pcase-let ((`(,status . ,output)
                 (init/org-sync--git "rebase" upstream)))
      (unless (zerop status)
        (init/org-sync--open-magit
         (if (string-empty-p output) "rebase failed" output))
        (user-error "Org sync stopped at a Git conflict; resolve it in Magit"))))
  (init/org-sync--git-success "push"))

(defun init/org-sync-now ()
  "Synchronously save, commit, fetch, rebase, and push the Org repository."
  (interactive)
  (init/org-sync-ensure-repository)
  (init/org-sync--wait-for-process)
  (init/org-sync--ensure-no-conflict)
  (init/org-sync--save-repository-buffers)
  (condition-case err
      (progn
        (init/org-sync--commit-local-changes)
        (init/org-sync--pull-and-push)
        (init/org-sync--refresh-repository-buffers)
        (message "Org repository synchronized"))
    (error
     (unless (string-empty-p (init/org-sync--unmerged-files))
       (init/org-sync--open-magit (error-message-string err)))
     (signal (car err) (cdr err)))))

(defun init/org-sync--wait-for-process ()
  "Wait for an active asynchronous Org synchronization to finish."
  (when (timerp init/org-sync--timer)
    (cancel-timer init/org-sync--timer)
    (setq init/org-sync--timer nil))
  (while (and init/org-sync--process
              (process-live-p init/org-sync--process))
    (accept-process-output init/org-sync--process 0.1))
  (when (timerp init/org-sync--timer)
    (cancel-timer init/org-sync--timer)
    (setq init/org-sync--timer nil)))

(defun init/org-sync--start-process (arguments callback)
  "Run Git ARGUMENTS asynchronously, then call CALLBACK with status and output."
  (when-let ((buffer (get-buffer init/org-sync--process-buffer)))
    (kill-buffer buffer))
  (let ((buffer (get-buffer-create init/org-sync--process-buffer)))
    (setq init/org-sync--process
          (make-process
           :name "org-git-sync"
           :buffer buffer
           :command (append (list "git" "-C" init/org-sync-directory)
                            arguments)
           :noquery t
           :sentinel
           (lambda (process _event)
             (when (memq (process-status process) '(exit signal))
               (let ((status (process-exit-status process))
                     (output (with-current-buffer (process-buffer process)
                               (string-trim (buffer-string)))))
                 (funcall callback status output))))))))

(defun init/org-sync--async-finished (&optional error-message)
  "Finish an asynchronous sync, reporting optional ERROR-MESSAGE."
  (setq init/org-sync--process nil)
  (if error-message
      (progn
        (message "Org sync failed: %s" error-message)
        (when (or (init/org-sync--operation-in-progress)
                  (not (string-empty-p (init/org-sync--unmerged-files))))
          (init/org-sync--open-magit error-message)))
    (init/org-sync--refresh-repository-buffers)
    (message "Org repository synchronized"))
  (when init/org-sync--pending
    (setq init/org-sync--pending nil)
    (init/org-sync--schedule)))

(defun init/org-sync--async-fetch ()
  "Fetch asynchronously, then safely continue the asynchronous sync chain."
  (init/org-sync--start-process
   '("fetch" "--prune" "origin")
   (lambda (status output)
     (cond
      ((not (zerop status))
       (init/org-sync--async-finished output))
      ((init/org-sync--modified-repository-buffers-p)
       ;; The user resumed editing during the fetch.  Never rebase beneath
       ;; unsaved buffers; the next save/idle cycle will finish the sync.
      (setq init/org-sync--process nil
             init/org-sync--pending t)
       (init/org-sync--schedule))
      (t
       (init/org-sync--async-rebase))))))

(defun init/org-sync--async-rebase ()
  "Asynchronously rebase onto the upstream, then push."
  (if-let ((upstream (init/org-sync--upstream)))
      (init/org-sync--start-process
       (list "rebase" upstream)
       (lambda (status output)
         (if (zerop status)
             (init/org-sync--async-push)
           (init/org-sync--async-finished
            (if (string-empty-p output) "rebase failed" output)))))
    (init/org-sync--async-push)))

(defun init/org-sync--async-push ()
  "Push asynchronously and finish the current synchronization."
  (init/org-sync--start-process
   '("push")
   (lambda (status output)
     (if (zerop status)
         (init/org-sync--async-finished)
       (init/org-sync--async-finished
        (if (string-empty-p output) "push failed" output))))))

(defun init/org-sync--run-deferred ()
  "Commit pending Org changes and begin asynchronous network synchronization."
  (setq init/org-sync--timer nil)
  (if (and init/org-sync--process
           (process-live-p init/org-sync--process))
      (setq init/org-sync--pending t)
    (condition-case err
        (progn
          (init/org-sync--ensure-no-conflict)
          (init/org-sync--commit-local-changes)
          (init/org-sync--async-fetch))
      (error
       (init/org-sync--async-finished (error-message-string err))))))

(defun init/org-sync--schedule ()
  "Debounce an automatic Org commit and synchronization."
  (when (timerp init/org-sync--timer)
    (cancel-timer init/org-sync--timer))
  (setq init/org-sync--timer
        (run-with-idle-timer init/org-sync-idle-delay nil
                             #'init/org-sync--run-deferred)))

(defun init/org-sync-after-save ()
  "Schedule synchronization after saving an Org repository file."
  (when (and (not init/org-sync--inhibit)
             (init/org-sync--org-file-p buffer-file-name))
    (init/org-sync--schedule)))

(defun init/org-sync--refresh-buffer (buffer)
  "Revert BUFFER when synchronization changed its visited file."
  (when (and (buffer-live-p buffer)
             (with-current-buffer buffer
               (and buffer-file-name
                    (not (buffer-modified-p))
                    (not (verify-visited-file-modtime buffer)))))
    (with-current-buffer buffer
      (let ((init/org-sync--inhibit t))
        (revert-buffer :ignore-auto :noconfirm :preserve-modes)))))

(defun init/org-sync--refresh-repository-buffers ()
  "Refresh every clean visited file changed by a successful synchronization."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (and buffer-file-name
                 (file-in-directory-p buffer-file-name
                                      init/org-sync-directory))
        (init/org-sync--refresh-buffer buffer)))))

(defun init/org-sync--around-find-file (original filename &rest arguments)
  "Visit Org FILENAME through ORIGINAL and queue synchronization.
This deliberately does not block session restoration on network access."
  (if (or init/org-sync--inhibit
          (not (init/org-sync--org-file-p filename)))
      (apply original filename arguments)
    (init/org-sync--schedule)
    (let ((init/org-sync--inhibit t))
      (apply original filename arguments))))

(defun init/org-sync--around-org-entry (original &rest arguments)
  "Enter Org through ORIGINAL immediately and queue synchronization."
  (if init/org-sync--inhibit
      (apply original arguments)
    (init/org-sync--schedule)
    (let ((init/org-sync--inhibit t))
      (apply original arguments))))

(defun init/org-sync-install ()
  "Install automatic synchronization hooks for the Org repository."
  (condition-case err
      (init/org-sync-ensure-repository)
    (error
     ;; Keep startup usable while offline.  The first Org operation retries.
     (message "Org repository is not available yet: %s"
              (error-message-string err))))
  (add-hook 'after-save-hook #'init/org-sync-after-save)
  (unless (advice-member-p #'init/org-sync--around-find-file
                           'find-file-noselect)
    (advice-add 'find-file-noselect :around #'init/org-sync--around-find-file))
  (with-eval-after-load 'org-capture
    (unless (advice-member-p #'init/org-sync--around-org-entry 'org-capture)
      (advice-add 'org-capture :around #'init/org-sync--around-org-entry)))
  (with-eval-after-load 'org
    (unless (advice-member-p #'init/org-sync--around-org-entry
                             'init/org-goto-journal)
      (advice-add 'init/org-goto-journal :around
                  #'init/org-sync--around-org-entry)))
  (add-hook 'kill-emacs-hook #'init/org-sync--flush-on-exit))

(defun init/org-sync--flush-on-exit ()
  "Make a best effort to commit and push pending Org changes before exit."
  (condition-case err
      (when (or (timerp init/org-sync--timer)
                init/org-sync--process
                (init/org-sync--modified-repository-buffers-p))
        (init/org-sync-now))
    (error
     (message "Final Org sync failed; local work remains in Git: %s"
              (error-message-string err)))))

(provide 'org-sync)
;;; org-sync.el ends here
