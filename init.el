;;; init.el --- Entry point -*- lexical-binding: t; -*-

;;; Commentary:

;; Loads the configuration modules from lisp/, in dependency order.
;; Every module is named `init-*' so it can never shadow a built-in or
;; third-party library, and every module provides the feature matching
;; its file name.
;;
;; The modules, in the order they load:
;;
;;   Foundation   shared helpers, persisted state, packages, key names
;;   Interface    menus, toolbars, fonts and themes, frame and mode line
;;   Editing      editor defaults, completion, bookmarks, compilation
;;   Workspace    projects and sessions, the file tree, documents, Org
;;   Languages    the shared IDE layer and the language modules
;;
;; The cheatsheets load last, since they describe everything above.

;;; Code:

(add-to-list 'load-path (expand-file-name "lisp" user-emacs-directory))

;;;; Foundation

(require 'init-lib)

;; Restore persisted state (theme, menu-bar and toolbar toggles) before
;; any module reads those values during startup.
(require 'init-persist)
(init/persist-load)

(require 'init-packages)
(require 'init-keys)

;;;; Interface

(require 'init-pulldown)
(require 'init-toolbar)
(require 'init-theme)
(require 'init-frame)

;;;; Editing

(require 'init-editor)
(require 'init-completion)
(require 'init-bookmarks)
(require 'init-compile)

;;;; Workspace

(require 'init-projects)
(require 'init-treemacs)
(require 'init-docs)
(require 'init-org-sync)
(require 'init-org)

;;;; Languages

(require 'init-ide)
(require 'init-lang-eglot)
(require 'init-lang-jvm)
(require 'init-lang-lisp)
(require 'init-lang-nim)
(require 'init-owl)

;;;; Guides

(require 'init-cheatsheet)

;;;; Customize

(setq custom-file (expand-file-name "custom.el" user-emacs-directory))
(load custom-file 'noerror)

;;; init.el ends here
