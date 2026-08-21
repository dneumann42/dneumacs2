;;; init-lib.el --- Utilities shared across the configuration -*- lexical-binding: t; -*-

;;; Commentary:

;; Small, dependency-free helpers used by several modules: crash-safe
;; file writes, PATH manipulation, project-root lookup, and the popup
;; window used for hover documentation.
;;
;; Nothing here configures Emacs; it is loaded first so every later
;; module can rely on it.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(declare-function posframe-show "posframe")
(declare-function posframe-hide "posframe")
(declare-function project-root "project")
(declare-function projectile-project-root "projectile")

;;;; Files

(defun init/atomic-write-file (file writer)
  "Write FILE atomically by calling WRITER with a temporary file path.
Once WRITER returns, the temporary file is renamed onto FILE.  FILE is
never left partially written: if WRITER signals, or the rename fails,
the temporary file is removed and FILE is untouched."
  (let ((temporary (make-temp-file "emacs-atomic-")))
    (unwind-protect
        (progn
          (funcall writer temporary)
          (rename-file temporary file t))
      (when (file-exists-p temporary)
        (delete-file temporary)))))

;;;; State files

;; Saved places and bm's bookmark repository are written through `pp',
;; whose poor algorithmic complexity dominates shutdown once the file
;; holds a few hundred entries.  Both are read back with plain `read', so
;; the indentation is cosmetic.

(defmacro init/without-pretty-printing (&rest body)
  "Evaluate BODY with `pp' and `pp-buffer' reduced to a plain `prin1'.
Print limits are lifted as well, so a large structure can never be
silently truncated into the file it is being written to."
  (declare (indent 0) (debug t))
  `(let ((print-length nil)
         (print-level nil))
     (cl-letf (((symbol-function 'pp-buffer) #'ignore)
               ((symbol-function 'pp)
                (lambda (object &optional stream)
                  (let ((target (or stream standard-output)))
                    (prin1 object target)
                    (princ "\n" target)))))
       ,@body)))

(defun init/write-state-file-fast (original &rest arguments)
  "Call ORIGINAL with ARGUMENTS, pretty printing disabled.
Meant as `:around' advice on a function that writes a state file; see
`init/without-pretty-printing'."
  (init/without-pretty-printing (apply original arguments)))

;;;; Executable search path

(defun init/prepend-to-path (directory)
  "Put DIRECTORY at the front of `exec-path' and of the PATH environment.
Return DIRECTORY when it exists and is now searched, nil otherwise."
  (let ((dir (expand-file-name directory)))
    (when (file-directory-p dir)
      (add-to-list 'exec-path dir)
      (let ((entries (split-string (or (getenv "PATH") "") path-separator t)))
        (unless (member dir entries)
          (setenv "PATH" (string-join (cons dir entries) path-separator))))
      dir)))

;;;; Project roots

(defun init/git-repo-root (&optional dir)
  "Return the Git repository root above DIR, or nil when there is none."
  (locate-dominating-file
   (file-name-as-directory (expand-file-name (or dir default-directory)))
   ".git"))

(defun init/locate-dominating-match (patterns &optional dir)
  "Return the nearest directory at or above DIR holding a PATTERNS match.
PATTERNS is a list of file names or wildcard patterns as understood by
`file-expand-wildcards'.  Return nil when no such directory exists."
  (locate-dominating-file
   (or dir default-directory)
   (lambda (candidate)
     (seq-some (lambda (pattern)
                 (file-expand-wildcards (expand-file-name pattern candidate)))
               patterns))))

(defun init/project-root (&optional dir)
  "Return the project root containing DIR, or `default-directory'.
Projectile decides first, since it is the project system the project
commands and sessions are built on; project.el is the fallback."
  (let ((default-directory (or dir default-directory)))
    (or (and (fboundp 'projectile-project-root) (projectile-project-root))
        (when-let ((project (project-current nil)))
          (project-root project))
        default-directory)))

(defun init/project-root-for (patterns &optional dir)
  "Return the project root for DIR, preferring a directory holding PATTERNS.
Language modules pass their own build-file markers (`dune-project',
`pyproject.toml', ...) so a nested source tree resolves to the package
root rather than to whatever enclosing repository Projectile reports."
  (or (init/locate-dominating-match patterns dir)
      (init/project-root dir)))

;;;; Popups

;; Hover documentation is shown in a posframe child frame anchored under
;; point, falling back to a bottom side window where child frames are
;; unavailable (a terminal frame, or posframe not installed).

(defconst init/popup-frame-width-fraction 0.45
  "Fraction of the frame width a popup may occupy.")

(defun init/popup--width (minimum maximum)
  "Return a popup width in columns, clamped between MINIMUM and MAXIMUM."
  (max minimum
       (min maximum
            (floor (* (frame-width) init/popup-frame-width-fraction)))))

(defun init/popup--fill (buffer content mode)
  "Render CONTENT into BUFFER using major MODE and return BUFFER.
The buffer is left read-only, soft-wrapped and free of any mode line or
cursor, ready to be displayed as a popup."
  (with-current-buffer buffer
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert content)
      (goto-char (point-min))
      (funcall mode)
      (setq-local mode-line-format nil
                  cursor-type nil
                  truncate-lines nil
                  word-wrap t
                  buffer-read-only t)
      (visual-line-mode 1)))
  buffer)

(defun init/popup--show-in-side-window (buffer height)
  "Display BUFFER in a bottom side window at most HEIGHT lines tall."
  (let ((window (display-buffer
                 buffer
                 '((display-buffer-in-side-window)
                   (side . bottom)
                   (slot . 0)
                   (window-parameters . ((no-delete-other-windows . t)
                                         (no-other-window . t)))))))
    (when (window-live-p window)
      (fit-window-to-buffer window height)
      window)))

(cl-defun init/popup-show (name content &key (mode #'fundamental-mode)
                                (min-width 50) (max-width 90) (height 12)
                                background hidehandler)
  "Show CONTENT in a popup named NAME, anchored below point.
MODE renders the content.  MIN-WIDTH and MAX-WIDTH bound the popup
width in columns and HEIGHT bounds its height in lines.  BACKGROUND
overrides the popup background colour, and HIDEHANDLER is the posframe
predicate deciding when the popup dismisses itself."
  (let ((buffer (init/popup--fill (get-buffer-create name) content mode)))
    (if (and (display-graphic-p) (require 'posframe nil t))
        (apply #'posframe-show buffer
               :poshandler #'posframe-poshandler-point-bottom-left-corner
               :max-width (init/popup--width min-width max-width)
               :max-height height
               :cursor nil
               :accept-focus nil
               :internal-border-width 1
               :override-parameters '((no-other-window . t)
                                      (no-delete-other-windows . t))
               (append (when background (list :background-color background))
                       (when hidehandler (list :hidehandler hidehandler))))
      (init/popup--show-in-side-window buffer height))))

(defun init/popup-hide (name)
  "Hide the popup called NAME, however it is currently displayed."
  (if (fboundp 'posframe-hide)
      (posframe-hide name)
    (when-let ((window (get-buffer-window name t)))
      (quit-window nil window))))

(defun init/popup-visible-p (name)
  "Return non-nil when the popup called NAME is on screen."
  (and (get-buffer-window name t) t))

(provide 'init-lib)
;;; init-lib.el ends here
