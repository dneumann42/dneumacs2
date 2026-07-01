;;; early-init.el --- Pre-init setup -*- lexical-binding: t; -*-

;;; Commentary:

;; Runs before package activation and before the initial frame is
;; created.  Keep this file cheap: GC tuning, package activation
;; policy, and frame parameters only.

;;; Code:

;; Effectively disable GC during startup; emacs-startup-hook restores a
;; sane threshold once everything is loaded.
(setq gc-cons-threshold most-positive-fixnum
      gc-cons-percentage 0.6)
(add-hook 'emacs-startup-hook
          (lambda ()
            (setq gc-cons-threshold (* 32 1024 1024)
                  gc-cons-percentage 0.1)))

;; package-setup.el calls `package-initialize' itself; skipping the
;; automatic activation here avoids doing that work twice.
(setq package-enable-at-startup nil)

;; Build frames without the widgets editor.el turns off anyway, so they
;; are never constructed at all.
(push '(tool-bar-lines . 0) default-frame-alist)
(push '(menu-bar-lines . 0) default-frame-alist)
(push '(vertical-scroll-bars . nil) default-frame-alist)
(setq frame-inhibit-implied-resize t)

;; Read subprocess output in large chunks; language servers send
;; megabyte-sized JSON messages.
(setq read-process-output-max (* 4 1024 1024)
      process-adaptive-read-buffering nil)

;;; early-init.el ends here
