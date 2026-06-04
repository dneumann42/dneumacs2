;;; init-package.el --- Package setup -*- lexical-binding: t; -*-

(setq use-package-always-ensure t)

(require 'package)

(add-to-list
 'package-archives
 '("melpa" . "https://melpa.org/packages/")
 t)

(package-initialize)

(defun init/native-comp-deny (pattern)
  "Add PATTERN to native compilation deny lists when available."
  (when (boundp 'native-comp-jit-compilation-deny-list)
    (add-to-list 'native-comp-jit-compilation-deny-list pattern))
  (when (boundp 'native-comp-deferred-compilation-deny-list)
    (add-to-list 'native-comp-deferred-compilation-deny-list pattern)))

;; nim-mode's nimsuggest helper can emit noisy false-positive native-comp warnings.
;; We use Eglot for Nim LSP, so skip native-comp for this helper file.
(init/native-comp-deny ".*nim-suggest\\.el\\'")

;; Async native compilation of freshly installed packages (e.g. sly) emits
;; harmless "function X is not known to be defined" warnings because each
;; file is compiled in isolation. Log them to *Warnings* without popping
;; up the buffer.
(setq native-comp-async-report-warnings-errors 'silent)

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

(when (init/package-archive-stale-p)
  (package-refresh-contents))

;; If your Emacs does not already have use-package built in:
(unless (package-installed-p 'use-package)
  (unless package-archive-contents
    (package-refresh-contents))
  (package-install 'use-package))

(require 'use-package)

(provide 'init-package)
;;; init-package.el ends here
