;;; init-packages.el --- Package archives and use-package -*- lexical-binding: t; -*-

;;; Commentary:

;; Bootstraps package.el and use-package, puts user binary directories on
;; the search path, and silences the one-time compilation noise a fresh
;; clone produces while it builds the contents of elpa/.
;;
;; Loaded before every module that uses `use-package'.

;;; Code:

(require 'init-lib)
(require 'package)

;;;; Archives

(setq use-package-always-ensure t)

(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)

(package-initialize)

(defconst init/package-archive-max-age-days 7
  "Days after which package archive metadata is considered stale.")

(defun init/package-archive-stale-p ()
  "Return non-nil when the MELPA archive metadata needs refreshing."
  (let ((archive (expand-file-name "elpa/archives/melpa/archive-contents"
                                   user-emacs-directory)))
    (or (not (file-exists-p archive))
        (> (/ (float-time
               (time-subtract (current-time)
                              (file-attribute-modification-time
                               (file-attributes archive))))
              86400.0)
           init/package-archive-max-age-days))))

;; Refresh asynchronously: a stale archive must never block startup on
;; network I/O.  Freshly refreshed metadata is picked up next time.
(when (init/package-archive-stale-p)
  (package-refresh-contents t))

(unless (package-installed-p 'use-package)
  (unless package-archive-contents
    (package-refresh-contents))
  (package-install 'use-package))

(require 'use-package)

;;;; Search path

(init/prepend-to-path "~/.local/bin")

;;;; Native compilation

(defun init/native-comp-deny (pattern)
  "Skip native compilation of files matching PATTERN."
  (when (boundp 'native-comp-jit-compilation-deny-list)
    (add-to-list 'native-comp-jit-compilation-deny-list pattern))
  (when (boundp 'native-comp-deferred-compilation-deny-list)
    (add-to-list 'native-comp-deferred-compilation-deny-list pattern)))

;; nim-mode's nimsuggest helper emits noisy false-positive warnings.
(init/native-comp-deny ".*nim-suggest\\.el\\'")

(setq native-comp-async-report-warnings-errors 'silent)

;;;; Third-party compilation warnings

;; Everything in elpa/ is third-party.  On a fresh install each package is
;; byte-compiled once, emitting a wall of warnings that live in upstream
;; sources and are not actionable here: obsolete functions, wide
;; docstrings, deprecated `cl', unescaped quotes, cross-file "not known to
;; be defined", and so on.  The files in lisp/ are always loaded from
;; source, never byte-compiled, so this hides nothing of our own.
(setq byte-compile-warnings nil)

;; `byte-compile-warnings' alone misses the newer defcustom `:type' lint
;; and the native-compiler notices, which are routed through the warning
;; system rather than the classic path.  Dropping those categories from
;; the log keeps the first-run *Warnings* buffer from ever appearing.
;; Runtime warnings from this configuration are untouched.
(with-eval-after-load 'warnings
  (dolist (type '(bytecomp comp native-compiler))
    (add-to-list 'warning-suppress-log-types (list type))))

(provide 'init-packages)
;;; init-packages.el ends here
