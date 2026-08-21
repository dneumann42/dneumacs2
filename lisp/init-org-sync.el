;;; init-org-sync.el --- Git synchronisation for the Org repository -*- lexical-binding: t; -*-

;;; Commentary:

;; The personal Org directory is a Git checkout that synchronises itself,
;; so notes written on one machine appear on the others without any
;; explicit commit or push.
;;
;; Saving an Org file schedules an idle commit; that commit is then
;; fetched, integrated and pushed asynchronously, so editing is never
;; blocked on the network.  A synchronous `init/org-sync-now' exists for
;; explicit use, and runs on exit to flush pending work.
;;
;; Conflicts are avoided rather than resolved.  Org files are merged with
;; Git's union driver, which keeps both sides of overlapping edits instead
;; of writing conflict markers -- the right behaviour for append-heavy
;; journals.  A rebase that fails is aborted and retried as a merge, so
;; the tree is never left half-finished.  Only a genuinely unmergeable
;; conflict stops automatic synchronisation, and that is handed to Magit.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function magit-status "magit")

;;;; Configuration

(defgroup init/org-sync nil
  "Automatic synchronisation of the personal Org repository."
  :group 'org)

(defcustom init/org-sync-directory (expand-file-name "~/.org/")
  "Local checkout containing the personal Org files."
  :type 'directory
  :group 'init/org-sync)

(defcustom init/org-sync-remote "ssh://git@codeberg.org/dneumann42/org.git"
  "Git remote used to create `init/org-sync-directory'."
  :type 'string
  :group 'init/org-sync)

(defcustom init/org-sync-idle-delay 15
  "Idle seconds after a save before committing and pushing Org changes."
  :type 'number
  :group 'init/org-sync)

(defcustom init/org-sync-merge-union t
  "When non-nil, merge Org files with Git's union driver.
Union merges keep both sides of overlapping edits instead of writing
conflict markers, which suits append-heavy journals and eliminates the
vast majority of spurious sync conflicts."
  :type 'boolean
  :group 'init/org-sync)

(defcustom init/org-sync-push-retries 3
  "How many times to re-integrate and retry a push the remote rejected.
A rejection normally means another machine pushed between our fetch and
our push; re-fetching and pushing again resolves it without a conflict."
  :type 'integer
  :group 'init/org-sync)

(defcustom init/org-sync-exit-timeout 5
  "Seconds the exit flush may spend pushing before it gives up.
The commit is already on disk when the push starts, so abandoning it costs
nothing but a delay: the next session sends it.  `process-file' cannot be
bounded -- it blocks Lisp, timers included -- so the exit push runs as a
real process."
  :type 'number
  :group 'init/org-sync)

(defcustom init/org-sync-fetch-interval 300
  "Minimum seconds between remote fetches during automatic synchronisation.
Local commits are always integrated and pushed promptly; this only
throttles how often an otherwise-idle checkout contacts the remote to
look for new changes, to be gentle on the Git host."
  :type 'number
  :group 'init/org-sync)

;;;; State

(defvar init/org-sync--timer nil
  "Idle timer scheduling the next deferred synchronisation.")

(defvar init/org-sync--process nil
  "The Git process of the synchronisation currently in flight, or nil.")

(defvar init/org-sync--pending nil
  "Non-nil when another synchronisation was requested mid-flight.")

(defvar init/org-sync--inhibit nil
  "Non-nil while this module itself is writing to the repository.
Prevents its own saves and reverts from scheduling more work.")

(defvar init/org-sync--push-attempt 0
  "Number of times the current push has been retried.")

(defvar init/org-sync--last-fetch nil
  "`float-time' of the last successful fetch, or nil when never fetched.")

(defconst init/org-sync--process-buffer " *org-git-sync*"
  "Buffer collecting the output of the asynchronous Git process.")

;;;; Running Git

(defun init/org-sync--git (&rest arguments)
  "Run Git with ARGUMENTS in the Org repository.
Return a cons of the exit status and the trimmed combined output."
  (with-temp-buffer
    (let ((status (apply #'process-file "git" nil t nil
                         "-C" init/org-sync-directory arguments)))
      (cons status (string-trim (buffer-string))))))

(defun init/org-sync--git-success (&rest arguments)
  "Run Git with ARGUMENTS and return its output, signalling on failure."
  (pcase-let ((`(,status . ,output) (apply #'init/org-sync--git arguments)))
    (unless (and (integerp status) (zerop status))
      (error "git %s failed%s"
             (string-join arguments " ")
             (if (string-empty-p output) "" (concat ": " output))))
    output))

(defun init/org-sync--start-process (arguments callback)
  "Run Git ARGUMENTS asynchronously, then CALLBACK with status and output."
  (when-let ((buffer (get-buffer init/org-sync--process-buffer)))
    (kill-buffer buffer))
  (let ((buffer (get-buffer-create init/org-sync--process-buffer)))
    (setq init/org-sync--process
          (make-process
           :name "org-git-sync"
           :buffer buffer
           :command (append (list "git" "-C" init/org-sync-directory) arguments)
           :noquery t
           :sentinel
           (lambda (process _event)
             (when (memq (process-status process) '(exit signal))
               (funcall callback
                        (process-exit-status process)
                        (with-current-buffer (process-buffer process)
                          (string-trim (buffer-string))))))))))

;;;; The repository

(defconst init/org-sync--gitattributes-line "*.org merge=union"
  "Attribute entry enabling conflict-free union merges for Org files.")

(defun init/org-sync--ensure-gitattributes ()
  "Ensure Org files are configured to merge with the union driver.
Idempotent, and leaves any existing .gitattributes content untouched."
  (when init/org-sync-merge-union
    (let* ((file (expand-file-name ".gitattributes" init/org-sync-directory))
           (existing (when (file-readable-p file)
                       (with-temp-buffer
                         (insert-file-contents file)
                         (buffer-string)))))
      (unless (and existing
                   (string-match-p
                    (concat "^[ \t]*"
                            (regexp-quote init/org-sync--gitattributes-line)
                            "[ \t]*$")
                    existing))
        (let ((init/org-sync--inhibit t))
          (with-temp-file file
            (when (and existing (not (string-empty-p existing)))
              (insert existing)
              (unless (string-suffix-p "\n" existing)
                (insert "\n")))
            (insert init/org-sync--gitattributes-line "\n")))))))

(defun init/org-sync--clone-if-missing ()
  "Clone the Org repository when its checkout does not exist."
  (cond
   ((file-directory-p (expand-file-name ".git" init/org-sync-directory)) t)
   ((file-exists-p init/org-sync-directory)
    (error "%s exists but is not a Git checkout" init/org-sync-directory))
   (t
    (make-directory
     (file-name-directory (directory-file-name init/org-sync-directory)) t)
    (with-temp-buffer
      (let ((status (process-file "git" nil t nil "clone"
                                  init/org-sync-remote
                                  (directory-file-name
                                   init/org-sync-directory))))
        (unless (and (integerp status) (zerop status))
          (error "Unable to clone Org repository: %s"
                 (string-trim (buffer-string))))))
    t)))

(defun init/org-sync-ensure-repository ()
  "Make sure the Org checkout exists and merges Org files with union."
  (prog1 (init/org-sync--clone-if-missing)
    (ignore-errors (init/org-sync--ensure-gitattributes))))

;;;; Repository state

(defun init/org-sync--org-file-p (file)
  "Return non-nil when FILE is an Org file in the synchronised checkout."
  (and file
       (string-equal (downcase (or (file-name-extension file) "")) "org")
       (file-in-directory-p (expand-file-name file) init/org-sync-directory)))

(defun init/org-sync--repository-buffer-p ()
  "Return non-nil when the current buffer visits a file in the checkout."
  (and buffer-file-name
       (file-in-directory-p buffer-file-name init/org-sync-directory)))

(defun init/org-sync--save-repository-buffers ()
  "Save modified file buffers belonging to the Org repository."
  (let ((init/org-sync--inhibit t))
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (and (init/org-sync--repository-buffer-p) (buffer-modified-p))
          (save-buffer))))))

(defun init/org-sync--modified-repository-buffers-p ()
  "Return non-nil when a repository file buffer has unsaved edits."
  (cl-some (lambda (buffer)
             (with-current-buffer buffer
               (and (init/org-sync--repository-buffer-p) (buffer-modified-p))))
           (buffer-list)))

(defun init/org-sync--unmerged-files ()
  "Return the unresolved files in the Org repository, newline separated."
  (cdr (init/org-sync--git "diff" "--name-only" "--diff-filter=U")))

(defun init/org-sync--dirty-p ()
  "Return non-nil when the working tree has uncommitted changes."
  (not (string-empty-p (cdr (init/org-sync--git "status" "--porcelain")))))

(defun init/org-sync--upstream ()
  "Return the current branch's upstream, or nil."
  (pcase-let ((`(,status . ,output)
               (init/org-sync--git "rev-parse" "--abbrev-ref"
                                   "--symbolic-full-name" "@{upstream}")))
    (and (zerop status) (not (string-empty-p output)) output)))

(defun init/org-sync--ahead-count ()
  "Return the number of local commits not yet on the upstream.
Return 0 when there is no upstream, or the count cannot be determined."
  (if-let ((upstream (init/org-sync--upstream)))
      (pcase-let ((`(,status . ,output)
                   (init/org-sync--git "rev-list" "--count"
                                       (concat upstream "..HEAD"))))
        (if (and (zerop status) (string-match-p "\\`[0-9]+\\'" output))
            (string-to-number output)
          0))
    0))

(defun init/org-sync--fetch-due-p ()
  "Return non-nil when enough time has passed to fetch the remote again."
  (or (null init/org-sync--last-fetch)
      (>= (- (float-time) init/org-sync--last-fetch)
          init/org-sync-fetch-interval)))

(defun init/org-sync--sync-needed-p ()
  "Return non-nil when synchronisation has real work to do.
That means local commits to push, unsaved or uncommitted local changes,
or a remote check that has become due."
  (or (> (init/org-sync--ahead-count) 0)
      (init/org-sync--modified-repository-buffers-p)
      (init/org-sync--dirty-p)
      (init/org-sync--fetch-due-p)))

;;;; Conflict recovery

(defconst init/org-sync--operation-markers
  '(("rebase" . "rebase-merge")
    ("rebase" . "rebase-apply")
    ("merge" . "MERGE_HEAD")
    ("cherry-pick" . "CHERRY_PICK_HEAD")
    ("revert" . "REVERT_HEAD"))
  "Git operations and the state file that marks each as in progress.")

(defun init/org-sync--operation-in-progress ()
  "Return the Git operation currently awaiting attention, or nil."
  (cl-loop for (name . marker) in init/org-sync--operation-markers
           for path = (cdr (init/org-sync--git "rev-parse" "--git-path" marker))
           when (and (not (string-empty-p path))
                     (file-exists-p
                      (if (file-name-absolute-p path)
                          path
                        (expand-file-name path init/org-sync-directory))))
           return name))

(defun init/org-sync--abort-operation ()
  "Abort any in-progress rebase, merge, cherry-pick or revert."
  (when-let ((operation (init/org-sync--operation-in-progress)))
    (init/org-sync--git operation "--abort")))

(defun init/org-sync--open-magit (reason)
  "Open Magit for the Org repository and report REASON."
  (message "Org sync needs attention: %s" reason)
  (require 'magit)
  (magit-status init/org-sync-directory))

(defun init/org-sync--ensure-no-conflict ()
  "Recover from interrupted Git operations before editing.
An operation left behind with a clean tree -- an aborted-but-not-cleaned
rebase, say -- is undone automatically; only a genuine unresolved
conflict stops automatic synchronisation and hands off to Magit."
  (let ((operation (init/org-sync--operation-in-progress))
        (files (init/org-sync--unmerged-files)))
    (when (and operation (string-empty-p files))
      (init/org-sync--abort-operation)
      (setq operation (init/org-sync--operation-in-progress)
            files (init/org-sync--unmerged-files)))
    (when (or operation (not (string-empty-p files)))
      (init/org-sync--open-magit
       (if (string-empty-p files)
           (format "finish the interrupted %s" operation)
         (format "resolve conflicts in %s" (string-replace "\n" ", " files))))
      (user-error "Resolve the Org Git conflict in Magit before editing"))))

(defun init/org-sync--push-rejected-p (output)
  "Return non-nil when push OUTPUT means the remote simply moved ahead."
  (and output
       (string-match-p
        "non-fast-forward\\|fetch first\\|\\[rejected\\]\\|stale info"
        output)))

;;;; Committing

(defun init/org-sync--amendable-p ()
  "Return non-nil when the last commit is an unpushed autosync commit.
Amending it keeps the history from filling with one commit per idle
pause."
  (when-let ((upstream (init/org-sync--upstream)))
    (and (> (string-to-number
             (init/org-sync--git-success "rev-list" "--count"
                                         (concat upstream "..HEAD")))
            0)
         (string-prefix-p "autosync:"
                          (cdr (init/org-sync--git "log" "-1" "--format=%s"))))))

(defun init/org-sync--commit-local-changes ()
  "Stage and commit local changes, amending an unpushed autosync commit."
  (init/org-sync--ensure-gitattributes)
  (init/org-sync--git-success "add" "--all")
  (unless (zerop (car (init/org-sync--git "diff" "--cached" "--quiet")))
    (if (init/org-sync--amendable-p)
        (init/org-sync--git-success "commit" "--amend" "--no-edit")
      (init/org-sync--git-success
       "commit" "-m" (format-time-string "autosync: %Y-%m-%d %H:%M:%S")))))

;;;; Synchronous synchronisation

(defun init/org-sync--integrate (upstream)
  "Integrate UPSTREAM into HEAD, recovering automatically from conflicts.
Tries a rebase first; if that fails it is aborted, so the tree is never
left in a half-finished state, then retried as a merge, which the union
driver resolves without markers.  Only a genuinely unmergeable conflict
is handed off to Magit."
  (pcase-let ((`(,status . ,output) (init/org-sync--git "rebase" upstream)))
    (unless (zerop status)
      (init/org-sync--git "rebase" "--abort")
      (pcase-let ((`(,merge-status . ,merge-output)
                   (init/org-sync--git "merge" "--no-edit" upstream)))
        (unless (zerop merge-status)
          (init/org-sync--open-magit
           (cond ((not (string-empty-p merge-output)) merge-output)
                 ((not (string-empty-p output)) output)
                 (t "merge failed")))
          (user-error
           "Org sync stopped at a Git conflict; resolve it in Magit"))))))

(defun init/org-sync--pull-and-push ()
  "Synchronously fetch, integrate the upstream, and push.
Retries when the remote advanced between the fetch and the push."
  (let ((attempts 0))
    (catch 'done
      (while t
        (init/org-sync--git-success "fetch" "--prune" "origin")
        (setq init/org-sync--last-fetch (float-time))
        (when-let ((upstream (init/org-sync--upstream)))
          (init/org-sync--integrate upstream))
        ;; Only reach for the network when there is something to send.
        (when (zerop (init/org-sync--ahead-count))
          (throw 'done t))
        (pcase-let ((`(,status . ,output) (init/org-sync--git "push")))
          (cond
           ((zerop status) (throw 'done t))
           ((and (< attempts init/org-sync-push-retries)
                 (init/org-sync--push-rejected-p output))
            (cl-incf attempts))
           (t (error "git push failed%s"
                     (if (string-empty-p output) ""
                       (concat ": " output))))))))))

(defun init/org-sync--cancel-timer ()
  "Cancel the pending idle synchronisation, if one is scheduled."
  (when (timerp init/org-sync--timer)
    (cancel-timer init/org-sync--timer)
    (setq init/org-sync--timer nil)))

(defun init/org-sync--wait-for-process ()
  "Wait for an active asynchronous Org synchronisation to finish."
  (init/org-sync--cancel-timer)
  (while (process-live-p init/org-sync--process)
    (accept-process-output init/org-sync--process 0.1))
  (init/org-sync--cancel-timer))

(defun init/org-sync--await-process (seconds)
  "Wait at most SECONDS for the asynchronous synchronisation to finish.
Return non-nil when nothing is running any more."
  (let ((deadline (+ (float-time) seconds)))
    (while (and (process-live-p init/org-sync--process)
                (< (float-time) deadline))
      (accept-process-output init/org-sync--process 0.05))
    (not (process-live-p init/org-sync--process))))

(defun init/org-sync--git-await (seconds &rest arguments)
  "Run Git ARGUMENTS, waiting at most SECONDS for them to finish.
Return a cons of exit status and trimmed output, as `init/org-sync--git'
does, or nil when the deadline passed -- the process is killed in that
case.  This exists for the exit path, which must not be able to hold
Emacs open on a slow or unreachable network."
  (let* ((buffer (generate-new-buffer " *org-sync-exit*"))
         (process (make-process
                   :name "org-git-exit"
                   :buffer buffer
                   :noquery t
                   :command (append (list "git" "-C" init/org-sync-directory)
                                    arguments)))
         (deadline (+ (float-time) seconds)))
    (unwind-protect
        (progn
          (while (and (process-live-p process) (< (float-time) deadline))
            (accept-process-output process 0.05))
          (if (process-live-p process)
              (progn (delete-process process) nil)
            (cons (process-exit-status process)
                  (string-trim (with-current-buffer buffer (buffer-string))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defun init/org-sync-now ()
  "Synchronously save, commit, fetch, rebase and push the Org repository."
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

;;;; Asynchronous synchronisation

;; The asynchronous path is a chain of callbacks: fetch, then rebase (or
;; merge), then push, each step scheduling the next from its sentinel so
;; editing is never blocked.

(defun init/org-sync--continue-pending ()
  "Reschedule a synchronisation that was requested while one was running."
  (when init/org-sync--pending
    (setq init/org-sync--pending nil)
    (init/org-sync--schedule)))

(defun init/org-sync--async-finished (&optional error-message)
  "Finish an asynchronous sync, reporting the optional ERROR-MESSAGE."
  (setq init/org-sync--process nil)
  (if error-message
      (progn
        (message "Org sync failed: %s" error-message)
        (when (or (init/org-sync--operation-in-progress)
                  (not (string-empty-p (init/org-sync--unmerged-files))))
          (init/org-sync--open-magit error-message)))
    (init/org-sync--refresh-repository-buffers)
    (message "Org repository synchronized"))
  (init/org-sync--continue-pending))

(defun init/org-sync--async-fetch ()
  "Fetch asynchronously, then continue the asynchronous sync chain."
  (init/org-sync--start-process
   '("fetch" "--prune" "origin")
   (lambda (status output)
     (cond
      ((not (zerop status))
       (init/org-sync--async-finished output))
      ((init/org-sync--modified-repository-buffers-p)
       ;; The user resumed editing during the fetch.  Never rebase beneath
       ;; unsaved buffers; the next save or idle cycle finishes the sync.
       (setq init/org-sync--process nil
             init/org-sync--pending t)
       (init/org-sync--schedule))
      (t
       (setq init/org-sync--last-fetch (float-time))
       (init/org-sync--async-rebase))))))

(defun init/org-sync--async-rebase ()
  "Asynchronously integrate the upstream, then push.
On a rebase conflict, abort and fall back to a merge so the tree is never
left mid-rebase; the union driver resolves overlapping edits."
  (if-let ((upstream (init/org-sync--upstream)))
      (init/org-sync--start-process
       (list "rebase" upstream)
       (lambda (status output)
         (if (zerop status)
             (init/org-sync--async-maybe-push)
           (init/org-sync--git "rebase" "--abort")
           (init/org-sync--async-merge upstream output))))
    (init/org-sync--async-maybe-push)))

(defun init/org-sync--async-merge (upstream rebase-output)
  "Fall back to merging UPSTREAM after a rebase failed with REBASE-OUTPUT."
  (init/org-sync--start-process
   (list "merge" "--no-edit" upstream)
   (lambda (status output)
     (if (zerop status)
         (init/org-sync--async-maybe-push)
       ;; A genuine, unmergeable conflict remains; leave it for Magit.
       (init/org-sync--async-finished
        (cond ((not (string-empty-p output)) output)
              ((not (string-empty-p rebase-output)) rebase-output)
              (t "merge failed")))))))

(defun init/org-sync--async-maybe-push ()
  "Push only when there are local commits the remote still lacks."
  (if (> (init/org-sync--ahead-count) 0)
      (init/org-sync--async-push)
    (init/org-sync--async-finished)))

(defun init/org-sync--async-push ()
  "Push asynchronously; re-integrate and retry if the remote advanced."
  (init/org-sync--start-process
   '("push")
   (lambda (status output)
     (cond
      ((zerop status)
       (setq init/org-sync--push-attempt 0)
       (init/org-sync--async-finished))
      ((and (< init/org-sync--push-attempt init/org-sync-push-retries)
            (init/org-sync--push-rejected-p output))
       (cl-incf init/org-sync--push-attempt)
       (init/org-sync--async-fetch))
      (t
       (setq init/org-sync--push-attempt 0)
       (init/org-sync--async-finished
        (if (string-empty-p output) "push failed" output)))))))

(defun init/org-sync--run-deferred ()
  "Commit pending Org changes and start asynchronous synchronisation."
  (setq init/org-sync--timer nil)
  (if (process-live-p init/org-sync--process)
      (setq init/org-sync--pending t)
    (condition-case err
        (if (not (init/org-sync--sync-needed-p))
            ;; Nothing to send and the remote was checked recently: stay
            ;; off the network entirely, and stay silent.
            (init/org-sync--continue-pending)
          (init/org-sync--ensure-no-conflict)
          (init/org-sync--commit-local-changes)
          (if (or (> (init/org-sync--ahead-count) 0)
                  (init/org-sync--fetch-due-p))
              (init/org-sync--async-fetch)
            (init/org-sync--continue-pending)))
      (error
       (init/org-sync--async-finished (error-message-string err))))))

(defun init/org-sync--schedule ()
  "Debounce an automatic Org commit and synchronisation."
  (when (timerp init/org-sync--timer)
    (cancel-timer init/org-sync--timer))
  (setq init/org-sync--timer
        (run-with-idle-timer init/org-sync-idle-delay nil
                             #'init/org-sync--run-deferred)))

;;;; Keeping buffers in step

(defun init/org-sync--refresh-buffer (buffer)
  "Revert BUFFER when synchronisation changed its visited file."
  (when (and (buffer-live-p buffer)
             (with-current-buffer buffer
               (and buffer-file-name
                    (not (buffer-modified-p))
                    (not (verify-visited-file-modtime buffer)))))
    (with-current-buffer buffer
      (let ((init/org-sync--inhibit t))
        (revert-buffer :ignore-auto :noconfirm :preserve-modes)))))

(defun init/org-sync--refresh-repository-buffers ()
  "Refresh every clean visited file a successful synchronisation changed."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (init/org-sync--repository-buffer-p)
        (init/org-sync--refresh-buffer buffer)))))

;;;; Hooks

(defun init/org-sync-after-save ()
  "Schedule synchronisation after saving a file in the Org repository."
  (when (and (not init/org-sync--inhibit)
             (init/org-sync--org-file-p buffer-file-name))
    (init/org-sync--schedule)))

(defun init/org-sync--around-find-file (original filename &rest arguments)
  "Visit Org FILENAME through ORIGINAL and queue synchronisation.
ARGUMENTS are passed through.  This deliberately does not block session
restoration on network access."
  (if (or init/org-sync--inhibit
          (not (init/org-sync--org-file-p filename)))
      (apply original filename arguments)
    (init/org-sync--schedule)
    (let ((init/org-sync--inhibit t))
      (apply original filename arguments))))

(defun init/org-sync--around-org-entry (original &rest arguments)
  "Enter Org through ORIGINAL immediately and queue synchronisation.
ARGUMENTS are passed through."
  (if init/org-sync--inhibit
      (apply original arguments)
    (init/org-sync--schedule)
    (let ((init/org-sync--inhibit t))
      (apply original arguments))))

(defun init/org-sync--pending-work-p ()
  "Return non-nil when there is local Org work the remote has not seen.
Cheapest test first: an unsaved buffer needs no Git at all, a dirty tree
needs one `git status', and only then is the upstream compared.

Deliberately not part of this: whether a fetch is due, and whether an idle
timer is armed.  Neither is local work -- and the timer is armed by merely
*visiting* an Org file, which a session restore does at every startup."
  (or (init/org-sync--modified-repository-buffers-p)
      (init/org-sync--dirty-p)
      (> (init/org-sync--ahead-count) 0)))

(defun init/org-sync--flush-on-exit ()
  "Commit and push pending Org work before Emacs exits.
Exit is not the place for a full synchronisation: a fetch on the way out is
discarded along with the process, and rebasing onto what it brought back
risks leaving a half-finished tree behind with nobody watching.  So this
commits only when there is something to commit, pushes only when the remote
is behind, never fetches, and gives the push
`init/org-sync-exit-timeout' seconds.  Anything not sent stays in Git and
goes out with the next session's background synchronisation."
  (condition-case err
      (progn
        (init/org-sync--cancel-timer)
        (when (and (init/org-sync--pending-work-p)
                   (init/org-sync--await-process init/org-sync-exit-timeout))
          (init/org-sync--save-repository-buffers)
          (init/org-sync--commit-local-changes)
          (when (> (init/org-sync--ahead-count) 0)
            (pcase (init/org-sync--git-await init/org-sync-exit-timeout "push")
              ('nil
               (message "Org push timed out; the commit goes out next session"))
              (`(,status . ,output)
               (unless (zerop status)
                 (message "Org push failed; the commit goes out next session%s"
                          (if (string-empty-p output) "" (concat ": " output)))))))))
    (error
     (message "Final Org sync failed; local work remains in Git: %s"
              (error-message-string err)))))

(defun init/org-sync-install ()
  "Install the automatic synchronisation hooks for the Org repository."
  (condition-case err
      (init/org-sync-ensure-repository)
    (error
     ;; Keep startup usable while offline; the first Org operation retries.
     (message "Org repository is not available yet: %s"
              (error-message-string err))))
  (add-hook 'after-save-hook #'init/org-sync-after-save)
  (add-hook 'kill-emacs-hook #'init/org-sync--flush-on-exit)
  (unless (advice-member-p #'init/org-sync--around-find-file 'find-file-noselect)
    (advice-add 'find-file-noselect :around #'init/org-sync--around-find-file))
  (with-eval-after-load 'org-capture
    (unless (advice-member-p #'init/org-sync--around-org-entry 'org-capture)
      (advice-add 'org-capture :around #'init/org-sync--around-org-entry)))
  (with-eval-after-load 'org
    (unless (advice-member-p #'init/org-sync--around-org-entry
                             'init/org-goto-journal)
      (advice-add 'init/org-goto-journal :around
                  #'init/org-sync--around-org-entry))))

(init/org-sync-install)

(provide 'init-org-sync)
;;; init-org-sync.el ends here
