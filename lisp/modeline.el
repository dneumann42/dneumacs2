;;; modeline.el --- Modeline setup -*- lexical-binding: t; -*-

(use-package nerd-icons
  :defer t)

(use-package doom-modeline
  :init
  (doom-modeline-mode 1)
  :custom
  (doom-modeline-height 24)
  (doom-modeline-bar-width 3)
  (doom-modeline-buffer-file-name-style 'truncate-upto-project)
  (doom-modeline-minor-modes nil)
  (doom-modeline-enable-word-count nil)
  (doom-modeline-icon t)
  (doom-modeline-project-detection 'project))

(provide 'modeline)
;;; modeline.el ends here
