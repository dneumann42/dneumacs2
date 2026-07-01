;;; init.el --- Entry point -*- lexical-binding: t; -*-

(add-to-list 'load-path (expand-file-name "lisp" user-emacs-directory))

(setq enable-local-variables :all)
(setq inhibit-startup-screen t)

(require 'keybindings)
(require 'package)
(require 'package-setup)
(require 'project)
(require 'editor)
(require 'modeline)
(require 'completion)
(require 'init-org)
(require 'init-markdown)
(require 'scheme-tools)
(require 'project-tools)
(require 'c-tools)
(require 'nim)
(require 'rust)
(require 'init-python)
(require 'lua)
(require 'ocaml)
(require 'ron)
(require 'treemacs-setup)
(require 'init-common-lisp)
(require 'owl)

(setq custom-file (expand-file-name "custom.el" user-emacs-directory))
(load custom-file 'noerror)

;;; init.el ends here
