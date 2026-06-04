;;; init.el --- Entry point -*- lexical-binding: t; -*-

(add-to-list 'load-path (expand-file-name "lisp" user-emacs-directory))

(setq enable-local-variables :all)

(require 'package)
(require 'package-setup)
(require 'project)
(require 'ui)
(require 'modeline)
(require 'completion)
(require 'scheme-tools)
(require 'project-tools)
(require 'c-tools)
(require 'nim)
(require 'treemacs-setup)
(require 'init-common-lisp)

(setq custom-file (expand-file-name "custom.el" user-emacs-directory))
(load custom-file 'noerror)

;;; init.el ends here
