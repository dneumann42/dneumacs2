;;; init-ui.el --- Core UI and editor defaults -*- lexical-binding: t; -*-

(defun configure-electric-pair-mode ()
  (setq electric-pair-pairs
        '((?\< . ?\>)
          (?\{ . ?\})
          (?\[ . ?\])
          (?\( . ?\))))
  (setq electric-pair-text-pairs electric-pair-pairs))

(defvar init/frame-alpha-opaque 100)
(defvar init/frame-alpha-translucent 85)

(defun init/toggle-frame-transparency ()
  "Toggle the current frame between opaque and translucent."
  (interactive)
  (let* ((current (or (frame-parameter nil 'alpha-background) 100))
         (next (if (>= current init/frame-alpha-opaque)
                   init/frame-alpha-translucent
                 init/frame-alpha-opaque)))
    (set-frame-parameter nil 'alpha-background next)
    (message "Frame transparency: %s%%" next)))

(defun init/reload-config ()
  "Reload the full Emacs configuration from `user-init-file'."
  (interactive)
  (condition-case err
      (progn
        (load-file user-init-file)
        (message "Config reloaded: %s" user-init-file))
    (error
     (message "Config reload failed: %s" (error-message-string err)))))

(defun init/set-default-font ()
  "Set the default UI font if available."
  (let ((font "Iosevka NFM-13"))
    (when (member "Iosevka NFM" (font-family-list))
      (add-to-list 'default-frame-alist `(font . ,font))
      (set-face-attribute 'default nil :font font)
      (set-face-attribute 'fixed-pitch nil :font font))))

(use-package emacs
  :ensure nil
  :init
  (add-to-list 'custom-theme-load-path
               (expand-file-name "themes" user-emacs-directory))
  (tool-bar-mode -1)
  (menu-bar-mode -1)
  (scroll-bar-mode -1)
  (load-theme 'some-nice-colors t)
  (electric-pair-mode 1)
  (setq make-backup-files nil)
  (setq auto-save-default nil)
  (setq create-lockfiles nil)
  (init/set-default-font)
  (global-set-key (kbd "C-c t") #'init/toggle-frame-transparency)
  (global-set-key (kbd "C-c r") #'init/reload-config)
  :config
  (configure-electric-pair-mode))

(use-package ligature
  :config
  (ligature-set-ligatures
   'prog-mode
   '("www" "**" "***" "**/" "*>" "*/" "\\\\" "\\\\\\"
     "{-" "[]" "::" ":::" ":=" "!!" "!=" "!==" "-}"
     "--" "---" "-->" "->" "->>" "-<" "-<<" "-~"
     "#{" "#[" "##" "###" "####" "#(" "#?" "#_" "#_("
     ".-" ".=" ".." "..<" "..." "?=" "??" ";;" "/*" "/**"
     "/=" "/==" "/>" "//" "///" "&&" "||" "||=" "|="
     "|>" "^=" "$>" "++" "+++" "+>" "=:=" "==" "==="
     "==>" "=>" "=>>" "<=" "=<<" "=/=" ">-" ">=" ">=>"
     ">>" ">>-" ">>=" ">>>" "<*" "<*>" "<|" "<|>" "<$"
     "<$>" "<!--" "<-" "<--" "<->" "<+" "<+>" "<=" "<=="
     "<=>" "<=<" "<>" "<<" "<<-" "<<=" "<<<" "<~" "<~~"
     "</" "</>" "~@" "~-" "~=" "~>" "~~" "~~>" "%%"))
  (global-ligature-mode t))

(use-package highlight-indent-guides
  :hook (prog-mode . highlight-indent-guides-mode)
  :custom
  (highlight-indent-guides-method 'character)
  (highlight-indent-guides-responsive 'top)
  (highlight-indent-guides-auto-enabled nil)
  :config
  (set-face-foreground 'highlight-indent-guides-character-face "#2a2a36")
  (set-face-foreground 'highlight-indent-guides-top-character-face "#5d6aa8")
  (set-face-foreground 'highlight-indent-guides-stack-character-face "#8a6a9f"))

;; Keep Evil out of sticky non-edit states after window/workspace changes.
(defun init/evil-normalize-on-window-change (&rest _)
  (when (and (fboundp 'evil-normal-state)
             (bound-and-true-p evil-local-mode)
             (not (minibufferp))
             (not (eq major-mode 'treemacs-mode))
             (not (active-minibuffer-window)))
    (evil-normal-state)))

(add-hook 'window-selection-change-functions
          #'init/evil-normalize-on-window-change)

(provide 'init-ui)
;;; init-ui.el ends here
