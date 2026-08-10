;;; early-init.el --- Pre-init setup -*- lexical-binding: t; -*-

;;; Commentary:

;; Runs before package activation and before the initial frame is
;; created.  Keep this file cheap: startup policy, GC tuning and frame
;; parameters only.

;;; Code:

(setq inhibit-startup-screen t)

;; Effectively disable garbage collection during startup; the hook below
;; restores a sane threshold once everything is loaded.
(setq gc-cons-threshold most-positive-fixnum
      gc-cons-percentage 0.6)

(defun init/restore-gc-threshold ()
  "Return garbage collection to normal after startup."
  (setq gc-cons-threshold (* 32 1024 1024)
        gc-cons-percentage 0.1))

(add-hook 'emacs-startup-hook #'init/restore-gc-threshold)

;; init-packages.el calls `package-initialize' itself; skipping the
;; automatic activation here avoids doing that work twice.
(setq package-enable-at-startup nil)

;; Build frames without the widgets init-frame.el turns off anyway, so
;; they are never constructed at all.
(push '(tool-bar-lines . 0) default-frame-alist)
(push '(menu-bar-lines . 0) default-frame-alist)
(push '(vertical-scroll-bars . nil) default-frame-alist)
(setq frame-inhibit-implied-resize t)

;; Read subprocess output in large chunks; language servers send
;; megabyte-sized JSON messages.
(setq read-process-output-max (* 4 1024 1024)
      process-adaptive-read-buffering nil)

;;; early-init.el ends here
