;;; modeline.el --- Modeline setup -*- lexical-binding: t; -*-

(use-package nerd-icons
  :defer t
  :init
  (defun init/nerd-icons-font-family ()
    "Return the first installed Nerd Font family we can use."
    (let ((families (font-family-list)))
      (catch 'found
        (dolist (font '("Symbols Nerd Font Mono"
                        "Symbols Nerd Font"
                        "MesloLGS Nerd Font Mono"
                        "MesloLGM Nerd Font Mono"
                        "MesloLGL Nerd Font Mono"
                        "FantasqueSansM Nerd Font Mono"))
          (when (member font families)
            (throw 'found font))))))

  (defun init/configure-nerd-icons-font (&optional frame)
    "Bind `nerd-icons' to an installed Nerd Font family.
FRAME is used when Emacs creates new frames after startup."
    (when (display-graphic-p frame)
      (let ((font (init/nerd-icons-font-family)))
        (when font
          (setq nerd-icons-font-family font)
          (when (fboundp 'nerd-icons-set-font)
            (nerd-icons-set-font font frame))))))

  (add-hook 'after-init-hook #'init/configure-nerd-icons-font)
  (add-hook 'after-make-frame-functions #'init/configure-nerd-icons-font))

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
