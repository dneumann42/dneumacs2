;;; init.el --- Entry point -*- lexical-binding: t; -*-

(add-to-list 'load-path (expand-file-name "lisp" user-emacs-directory))

(require 'init-package)
(require 'init-ui)
(require 'init-modeline)
(require 'init-completion)
(require 'init-scheme)
(require 'init-project)
(require 'init-nim)
(require 'init-treemacs)

(setq custom-file (expand-file-name "custom.el" user-emacs-directory))
(load custom-file 'noerror)

;;; init.el ends here
