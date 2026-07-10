;;; package-setup.el --- Package setup -*- lexical-binding: t; -*-

(setq use-package-always-ensure t)

(require 'package)

(add-to-list
 'package-archives
 '("melpa" . "https://melpa.org/packages/")
 t)

(package-initialize)

(defun init/add-user-bin-to-path ()
  "Add common per-user binary directories to PATH and `exec-path'."
  (dolist (dir '("~/.local/bin"))
    (let ((expanded (expand-file-name dir)))
      (when (file-directory-p expanded)
        (add-to-list 'exec-path expanded)
        (let ((paths (split-string (or (getenv "PATH") "") path-separator t)))
          (unless (member expanded paths)
            (setenv "PATH"
                    (mapconcat #'identity (cons expanded paths)
                               path-separator))))))))

(init/add-user-bin-to-path)

(defun init/native-comp-deny (pattern)
  "Add PATTERN to native compilation deny lists when available."
  (when (boundp 'native-comp-jit-compilation-deny-list)
    (add-to-list 'native-comp-jit-compilation-deny-list pattern))
  (when (boundp 'native-comp-deferred-compilation-deny-list)
    (add-to-list 'native-comp-deferred-compilation-deny-list pattern)))

;; nim-mode's nimsuggest helper can emit noisy false-positive native-comp warnings.
;; Skip native-comp for this helper file.
(init/native-comp-deny ".*nim-suggest\\.el\\'")

;; Async native compilation of freshly installed packages (e.g. sly) emits
;; harmless "function X is not known to be defined" warnings because each
;; file is compiled in isolation. Log them to *Warnings* without popping
;; up the buffer.
(setq native-comp-async-report-warnings-errors 'silent)

;; Everything in elpa/ is third-party.  On a fresh install each package is
;; byte-compiled once, emitting a wall of warnings that live in upstream
;; sources and are not actionable here: obsolete functions (point-at-eol),
;; wide docstrings, deprecated `cl', unescaped quotes, cross-file "not known
;; to be defined", the benign embark-consult advisory, and so on.  Silence
;; that one-time noise so a fresh clone compiles cleanly.  Our own lisp/
;; files are loaded from source (never byte-compiled here), so this does not
;; hide warnings in this configuration.
(setq byte-compile-warnings nil)

;; `byte-compile-warnings' alone misses the newer defcustom `:type' lint
;; ("`list' without arguments") and the native-compiler notices, which are
;; routed through the warning system rather than the classic path.  Drop
;; those compile categories from the log entirely so the first-run
;; *Warnings* buffer never appears.  This is scoped to compilation types;
;; runtime warnings from our own configuration are untouched.
(with-eval-after-load 'warnings
  (dolist (type '(bytecomp comp native-compiler))
    (add-to-list 'warning-suppress-log-types (list type))))

(defun init/package-archive-stale-p (&optional max-age-days)
  "Return non-nil when package archive metadata is older than MAX-AGE-DAYS.
Defaults to 7 days."
  (let* ((max-age (or max-age-days 7))
         (archive-file (expand-file-name "elpa/archives/melpa/archive-contents"
                                         user-emacs-directory)))
    (or (not (file-exists-p archive-file))
        (> (/ (float-time
               (time-subtract (current-time)
                              (file-attribute-modification-time
                               (file-attributes archive-file))))
              86400.0)
           max-age))))

;; Refresh asynchronously: a stale archive must not block startup on
;; network I/O.  Freshly refreshed metadata is simply picked up next time.
(when (init/package-archive-stale-p)
  (package-refresh-contents t))

;; If your Emacs does not already have use-package built in:
(unless (package-installed-p 'use-package)
  (unless package-archive-contents
    (package-refresh-contents))
  (package-install 'use-package))

(require 'use-package)

(provide 'package-setup)
;;; package-setup.el ends here
