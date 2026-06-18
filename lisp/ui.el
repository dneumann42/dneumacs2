;;; ui.el --- Core UI and editor defaults -*- lexical-binding: t; -*-

(defun configure-electric-pair-mode ()
  (setq electric-pair-pairs
        '((?\< . ?\>)
          (?\{ . ?\})
          (?\[ . ?\])
          (?\( . ?\))))
  (setq electric-pair-text-pairs electric-pair-pairs))

(defvar init/frame-alpha-opaque 100)
(defvar init/frame-alpha-translucent 85)

(defun init/apply-frame-transparency (&optional frame)
  "Make FRAME use the configured translucent background alpha."
  (set-frame-parameter frame 'alpha-background init/frame-alpha-translucent))

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
  (setq auto-revert-verbose nil)
  (add-to-list 'default-frame-alist
               `(alpha-background . ,init/frame-alpha-translucent))
  (init/set-default-font)
  (global-set-key (kbd "C-c t") #'init/toggle-frame-transparency)
  (global-set-key (kbd "C-c r") #'init/reload-config)
  (init/apply-frame-transparency)
  :config
  (configure-electric-pair-mode)
  (global-auto-revert-mode 1))

(use-package ace-window
  :bind (("C-0" . ace-window)))

(use-package avy
  :ensure t
  :config
  (global-set-key (kbd "C-:") 'avy-goto-char))

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

;;; Floating compilation panel — child frame at top-right

(defvar init/compilation-frame nil
  "Child frame showing the compilation buffer at top-right.")

(defun init/display-compilation-in-child-frame (buffer alist)
  "Display BUFFER in a child frame at top-right of the current frame."
  (condition-case err
      (progn
        (when (and init/compilation-frame (frame-live-p init/compilation-frame))
          (delete-frame init/compilation-frame))
        (let* ((parent (selected-frame))
               (char-width (frame-char-width parent))
               (child-width (* 80 char-width))
               (parent-width (frame-pixel-width parent))
               (left-pos (- parent-width child-width 20))
               (frame (make-frame
                       `((parent-frame . ,parent)
                         (width . 80)
                         (height . 20)
                         (top . 10)
                         (left . ,left-pos)
                         (undecorated . t))))
               (window (frame-root-window frame)))
          (setq init/compilation-frame frame)
          (set-window-buffer window buffer)
          (raise-frame frame)
          (message "compile panel: frame pos=%s size=%dx%d visible=%s"
                   (frame-position frame)
                   (frame-pixel-width frame)
                   (frame-pixel-height frame)
                   (frame-visible-p frame))
          window))
    (error
     (message "compile panel: error: %s" (error-message-string err))
     nil)))

(add-to-list 'display-buffer-alist
             '("\\*compilation\\*"
               (init/display-compilation-in-child-frame)))

;; Restore focus to the original frame after compile finishes
(defun init/compilation--restore-focus (&rest _)
  (when (and init/compilation-frame (frame-live-p init/compilation-frame))
    (let ((parent (frame-parent init/compilation-frame)))
      (when (and parent (frame-live-p parent))
        (select-frame-set-input-focus parent)))))

(advice-add 'compile :after #'init/compilation--restore-focus)

(defun init/compilation-dismiss ()
  "Dismiss the compilation child frame."
  (interactive)
  (when (and init/compilation-frame (frame-live-p init/compilation-frame))
    (delete-frame init/compilation-frame)
    (setq init/compilation-frame nil)))

(defun init/compilation-toggle ()
  "Toggle the compilation child frame on and off.
If no compilation buffer exists, start a new compilation."
  (interactive)
  (if (and init/compilation-frame (frame-live-p init/compilation-frame))
      (init/compilation-dismiss)
    (let ((buf (get-buffer "*compilation*")))
      (if (buffer-live-p buf)
          (init/display-compilation-in-child-frame buf nil)
        (call-interactively #'compile)))))

(defun init/compilation-mode-hook ()
  "Bind q to dismiss the compilation child frame."
  (define-key compilation-mode-map (kbd "q") #'init/compilation-dismiss))

(add-hook 'compilation-mode-hook #'init/compilation-mode-hook)

(global-set-key (kbd "C-c c") #'init/compilation-toggle)
(global-set-key (kbd "<f5>") #'compile)

(provide 'ui)
;;; ui.el ends here
