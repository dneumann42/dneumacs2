;;; font-tools.el --- Shared font discovery and installation -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'init-persist)          ; for `init/atomic-write-file'

(defconst init/font-directory (expand-file-name "~/.local/share/fonts/")
  "Directory where downloaded user fonts are installed.")

(defvar init/font-install-asked (make-hash-table :test #'eq)
  "Font identifiers already offered for installation this session.")

(defun init/font-available-p (families)
  "Return the first installed font family matching FAMILIES."
  (let ((installed (font-family-list)))
    (cl-find-if
     (lambda (family)
       (cl-find-if (lambda (candidate)
                     (string-match-p (regexp-quote family) candidate))
                   installed))
     families)))

(defun init/font-files-installed-p (patterns)
  "Return non-nil when a file matching one of PATTERNS is installed."
  (cl-some (lambda (pattern)
             (file-expand-wildcards
              (expand-file-name pattern init/font-directory)))
           patterns))

(defun init/font-reset-cache ()
  "Refresh Emacs and system font caches after installing fonts."
  (when (fboundp 'clear-font-cache)
    (clear-font-cache))
  (when (eq system-type 'gnu/linux)
    (let ((status (call-process "fc-cache" nil nil nil "-f" "-r")))
      (unless (and (integerp status) (zerop status))
        (message "Font cache refresh failed with status %s" status)))))

(defun init/font--download (url target)
  "Download URL atomically to TARGET using curl."
  (init/atomic-write-file
   target
   (lambda (temporary)
     (unless (zerop (call-process
                     "curl" nil nil nil "-L" "--fail" "--silent"
                     "--show-error" "--output" temporary url))
       (error "Failed to download %s" url)))))

(defun init/font-install-files (files)
  "Install font FILES, an alist of destination names and download URLs."
  (make-directory init/font-directory t)
  (dolist (entry files)
    (init/font--download (cdr entry)
                         (expand-file-name (car entry) init/font-directory)))
  (init/font-reset-cache)
  t)

(defun init/font-install-zip (url archive-name)
  "Download font archive URL as ARCHIVE-NAME and extract it."
  (let ((archive (expand-file-name archive-name temporary-file-directory)))
    (unwind-protect
        (progn
          (init/font--download url archive)
          (make-directory init/font-directory t)
          (unless (zerop (call-process "unzip" nil nil nil "-oq" archive
                                       "-d" init/font-directory))
            (error "Failed to extract font archive %s" archive-name))
          (init/font-reset-cache)
          t)
      (when (file-exists-p archive)
        (delete-file archive)))))

(cl-defun init/font-ensure
    (id &key families file-patterns default-family prompt installer
        fallback-families require-graphic)
  "Resolve and optionally install font ID.
FAMILIES are probed in order.  FILE-PATTERNS and DEFAULT-FAMILY allow a
recently installed font to resolve before Emacs reports it.  PROMPT and
INSTALLER control the once-per-session installation offer.  Fall back to
FALLBACK-FAMILIES when supplied.  REQUIRE-GRAPHIC suppresses installation
outside graphical Emacs."
  (let ((resolve
         (lambda ()
           (or (init/font-available-p families)
               (and default-family file-patterns
                    (init/font-files-installed-p file-patterns)
                    default-family))))
        family)
    (setq family (funcall resolve))
    (unless family
      (when (and (eq system-type 'gnu/linux)
                 (or (not require-graphic) (display-graphic-p))
                 prompt installer
                 (not (gethash id init/font-install-asked)))
        (puthash id t init/font-install-asked)
        (when (y-or-n-p prompt)
          (condition-case err
              (progn
                (funcall installer)
                (setq family (funcall resolve)))
            (error
             (message "%s font install failed: %s"
                      id (error-message-string err)))))))
    (or family (init/font-available-p fallback-families))))

(provide 'font-tools)
;;; font-tools.el ends here
