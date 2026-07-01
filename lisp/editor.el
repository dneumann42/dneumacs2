;;; editor.el --- Core UI and editor defaults -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'subr-x)
(require 'url)

;;;; State variables

(defvar init/frame-alpha-opaque 100
  "Alpha-background value representing a fully opaque frame.")
(defvar init/frame-alpha-translucent 85
  "Alpha-background value used for translucent frames.")
(defvar init/compilation-frame nil
  "The live child frame displaying the compilation buffer, or nil.")
(defvar init/font-size 13
  "Default font size in points for the UI font.")
(defvar init/font-install-asked nil
  "Non-nil once the user has been asked to install the Cascadia font.")
(defvar init/pending-font-family nil
  "Font family awaiting application once a graphical frame is ready.")
(defvar init/font-apply-retried nil
  "Non-nil once a deferred font application has been scheduled.")

;;;; Fonts

(defconst init/cascadia-font-url
  "https://github.com/ryanoasis/nerd-fonts/releases/download/v3.4.0/CascadiaCode.zip"
  "Download URL for the Cascadia Code Nerd Font archive.")
(defconst init/cascadia-font-families
  '("CaskaydiaCove Nerd Font Mono"
    "CaskaydiaCove Nerd Font Propo"
    "CaskaydiaCove Nerd Font"
    "CaskaydiaCove NF"
    "CaskaydiaCove"
    "Cascadia Code Nerd Font Mono"
    "Cascadia Code Nerd Font Propo"
    "Cascadia Code Nerd Font"
    "Cascadia Code NF"
    "Cascadia Code")
  "Family names to probe for an installed Cascadia Nerd Font.")
(defconst init/cascadia-default-family "CaskaydiaCove Nerd Font Mono"
  "Preferred Cascadia family name to use once the font is installed.")
(defconst init/iosevka-font-families
  '("Iosevka NFM"
    "Iosevka Nerd Font Mono"
    "Iosevka Nerd Font"
    "Iosevka")
  "Family names to probe for an installed Iosevka font as a fallback.")
(defun init/font-available-p (families)
  "Return the first available font family from FAMILIES."
  (cl-find-if (lambda (family)
                (cl-find-if (lambda (installed)
                              (string-match-p (regexp-quote family) installed))
                            (font-family-list)))
              families))

(defun init/cascadia-font-installed-p ()
  "Return non-nil when the Cascadia font files are present on disk."
  (let ((font-dir (expand-file-name "~/.local/share/fonts/")))
    (cl-some (lambda (pattern)
               (file-expand-wildcards (expand-file-name pattern font-dir)))
             '("CaskaydiaCoveNerdFont*.ttf"
               "CaskaydiaCoveNerdFont*.otf"
               "CascadiaCodeNerdFont*.ttf"
               "CascadiaCodeNerdFont*.otf"))))

(defun init/apply-font-family (family)
  "Apply FAMILY as the default font for current and future frames."
  (add-to-list 'default-frame-alist `(font . ,family))
  (if (init/apply-font-family-now family)
      (setq init/pending-font-family nil
            init/font-apply-retried nil)
    (setq init/pending-font-family family)
    (unless init/font-apply-retried
      (setq init/font-apply-retried t)
      (run-at-time 1 nil #'init/apply-pending-font-family))
    (message "Font not available yet, will retry once")))

(defun init/apply-font-family-now (family)
  "Try to apply FAMILY immediately. Return non-nil on success."
  (condition-case err
      (progn
        (set-face-attribute 'default nil :family family :height (* init/font-size 10))
        (set-face-attribute 'fixed-pitch nil :family family :height (* init/font-size 10))
        t)
    (error
     (message "Font not available yet: %s" (error-message-string err))
     nil)))

(defun init/apply-pending-font-family ()
  "Retry applying the most recently requested font family."
  (when init/pending-font-family
    (let ((family init/pending-font-family))
      (setq init/pending-font-family nil)
      (init/apply-font-family-now family))))

(defun init/reset-font-cache ()
  "Refresh Emacs and system font caches after a font install."
  (when (fboundp 'clear-font-cache)
    (clear-font-cache))
  (when (eq system-type 'gnu/linux)
    (let ((status (call-process "fc-cache" nil nil nil "-f" "-r")))
      (unless (and (integerp status) (zerop status))
        (message "Font cache refresh failed with status %s" status)))))

(defun init/install-cascadia-font ()
  "Download and install Cascadia Nerd Font into the user font directory."
  (let* ((font-dir (expand-file-name "~/.local/share/fonts/"))
         (zip-file (expand-file-name "CascadiaCode.zip" temporary-file-directory)))
    (make-directory font-dir t)
    (when (file-exists-p zip-file)
      (delete-file zip-file))
    (unless (zerop (call-process "curl" nil nil nil
                                 "-L" "--fail" "--silent" "--show-error"
                                 "--output" zip-file
                                 init/cascadia-font-url))
      (error "Failed to download Cascadia font"))
    (unwind-protect
        (progn
          (unless (zerop (call-process "unzip" nil nil nil "-oq" zip-file "-d" font-dir))
            (error "Failed to extract Cascadia font"))
          (init/reset-font-cache)
          t)
      (when (file-exists-p zip-file)
        (delete-file zip-file)))))

(defun init/ensure-default-font ()
  "Use Cascadia when available, or install it on Linux if requested."
  (let ((family (or (init/font-available-p init/cascadia-font-families)
                    (and (init/cascadia-font-installed-p)
                         init/cascadia-default-family))))
    (unless family
      (when (and (eq system-type 'gnu/linux)
                 (not init/font-install-asked))
        (setq init/font-install-asked t)
        (when (y-or-n-p "Cascadia font is missing. Download and install it? ")
          (condition-case err
              (progn
                (init/install-cascadia-font)
                (setq family (or (init/font-available-p init/cascadia-font-families)
                                 (and (init/cascadia-font-installed-p)
                                      init/cascadia-default-family))))
            (error
             (message "Cascadia font install failed: %s"
                      (error-message-string err)))))))
    (unless family
      (setq family (init/font-available-p init/iosevka-font-families)))
    (when family
      (init/apply-font-family family))))

;;;; Electric pairs

(defun configure-electric-pair-mode ()
  "Configure each grouping opener with its matching closer."
  (setq electric-pair-pairs
        '((?\{ . ?\})
          (?\[ . ?\])
          (?\( . ?\))))
  (setq electric-pair-text-pairs electric-pair-pairs))

;;;; Frame transparency

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

;;;; Menu bar

(defvar init/menu-bar-auto-modes '(org-mode)
  "Major modes for which the menu bar is shown automatically.")

(defvar init/menu-bar-override nil
  "Manual override for the menu bar.
`on' forces it visible everywhere, `off' forces it hidden, and nil
defers to `init/menu-bar-auto-modes'.")

(defun init/menu-bar-relevant-buffer ()
  "Return the buffer whose mode should decide menu-bar visibility.
This is the buffer displayed in the frame's selected window, not
`current-buffer', which during window-change hooks is often a transient
or minibuffer buffer.  While the minibuffer is active, defer to the
window that was selected before it, so prompts do not flicker the menu."
  (window-buffer (or (minibuffer-selected-window) (selected-window))))

(defun init/menu-bar-desired-p ()
  "Return non-nil when the menu bar should be visible right now."
  (pcase init/menu-bar-override
    ('on t)
    ('off nil)
    (_ (with-current-buffer (init/menu-bar-relevant-buffer)
         (apply #'derived-mode-p init/menu-bar-auto-modes)))))

(defvar init/menu-bar--refresh-timer nil
  "Pending one-shot timer for `init/menu-bar-refresh', or nil.")

(defun init/menu-bar--apply ()
  "Show or hide the menu bar according to the selected buffer and override.
Runs outside of redisplay so the frame actually redraws the menu bar."
  (setq init/menu-bar--refresh-timer nil)
  (let ((want (init/menu-bar-desired-p))
        (cur (bound-and-true-p menu-bar-mode)))
    (unless (eq (and want t) (and cur t))
      (menu-bar-mode (if want 1 -1)))))

(defun init/menu-bar-refresh (&rest _)
  "Schedule a menu-bar refresh once the current command finishes.
The refresh is deferred (and debounced) because it is triggered from
window-change hooks that run during redisplay; toggling `menu-bar-mode'
there leaves the frame without a menu bar until the next redraw."
  (unless init/menu-bar--refresh-timer
    (setq init/menu-bar--refresh-timer
          (run-at-time 0 nil #'init/menu-bar--apply))))

(defun init/toggle-menu-bar ()
  "Toggle the menu bar and remember the manual choice.
This override takes precedence over the automatic per-mode behaviour
configured in `init/menu-bar-auto-modes'."
  (interactive)
  (setq init/menu-bar-override
        (if (bound-and-true-p menu-bar-mode) 'off 'on))
  (init/menu-bar-refresh)
  (message "Menu bar %s"
           (if (eq init/menu-bar-override 'on) "shown" "hidden")))

(defvar init/menu-bar-modeline-button
  (propertize
   " ☰ "
   'help-echo "mouse-1: Toggle menu bar"
   'mouse-face 'mode-line-highlight
   'local-map (let ((map (make-sparse-keymap)))
                (define-key map [mode-line mouse-1] #'init/toggle-menu-bar)
                map))
  "Clickable modeline segment that toggles the menu bar.")

;;;; Misc editor commands and helpers

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
  "Set the default UI font, installing Cascadia on Linux if requested."
  (init/ensure-default-font))

(defun init/git-repo-root (&optional dir)
  "Return the Git repository root for DIR, or nil if DIR is not in a repo."
  (let ((dir (file-name-as-directory (expand-file-name (or dir default-directory)))))
    (locate-dominating-file dir ".git")))

(defun init/set-default-directory-to-git-root ()
  "Make file-visiting buffers use the Git repository root as `default-directory'."
  (when buffer-file-name
    (when-let ((root (init/git-repo-root buffer-file-name)))
      (setq-local default-directory root))))

(defun init/maybe-apply-pending-font (&optional _frame)
  "Apply any pending font family if one exists."
  (when init/pending-font-family
    (init/apply-font-family-now init/pending-font-family)))

;;;; Package configuration

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
  ;; Keep point near the window edge instead of recentering when wheel
  ;; scrolling moves it outside the visible portion of the buffer.
  (setq scroll-conservatively 101)
  (setq scroll-preserve-screen-position 'always)
  (setq make-backup-files nil)
  (setq auto-save-default nil)
  (setq create-lockfiles nil)
  (setq auto-revert-verbose nil)
  (add-to-list 'default-frame-alist
               `(alpha-background . ,init/frame-alpha-translucent))
  (init/set-default-font)
  (init/apply-frame-transparency)
  (add-hook 'after-init-hook #'init/apply-pending-font-family)
  (add-hook 'after-make-frame-functions #'init/maybe-apply-pending-font)
  :config
  (configure-electric-pair-mode)
  (global-auto-revert-mode 1)
  (add-hook 'find-file-hook #'init/set-default-directory-to-git-root))

(use-package ace-window
  :bind (("C-0" . ace-window)))

(use-package avy
  :ensure t
  :config
  (global-set-key (kbd bind/avy-goto-char) 'avy-goto-char))

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
  "Return the newly selected window to Evil normal state when appropriate.
Skips the minibuffer and Treemacs so their own bindings keep working."
  (when (and (fboundp 'evil-normal-state)
             (bound-and-true-p evil-local-mode)
             (not (minibufferp))
             (not (eq major-mode 'treemacs-mode))
             (not (active-minibuffer-window)))
    (evil-normal-state)))

(add-hook 'window-selection-change-functions
          #'init/evil-normalize-on-window-change)

;;;; Compilation panel

(defun init/display-compilation-in-child-frame (buffer alist)
  "Display BUFFER in a child frame at top-right of the current frame.
ALIST is the `display-buffer' action alist; it is accepted for
protocol compatibility but not otherwise used."
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

(defun init/compilation--restore-focus (&rest _)
  "Return input focus to the parent frame after starting a compilation."
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

;;;; Menu bar activation

;; Menu bar: hidden by default, shown automatically in Org buffers, and
;; toggleable via keybinding or the clickable modeline segment.
(unless (member init/menu-bar-modeline-button global-mode-string)
  (setq global-mode-string
        (append global-mode-string (list init/menu-bar-modeline-button))))
(add-hook 'window-selection-change-functions #'init/menu-bar-refresh)
(add-hook 'window-buffer-change-functions #'init/menu-bar-refresh)
;; Show/hide as soon as a buffer's major mode is set (e.g. opening an
;; Org file), not only on the next window change.
(add-hook 'after-change-major-mode-hook #'init/menu-bar-refresh)

;;;; Keybindings

(global-set-key (kbd bind/toggle-menu-bar) #'init/toggle-menu-bar)
(global-set-key (kbd bind/toggle-frame-transparency) #'init/toggle-frame-transparency)
(global-set-key (kbd bind/reload-config) #'init/reload-config)
(global-set-key (kbd bind/compilation-toggle) #'init/compilation-toggle)
(global-set-key (kbd bind/compile) #'compile)
(global-set-key (kbd bind/forward-paragraph) 'forward-paragraph)
(global-set-key (kbd bind/backward-paragraph) 'backward-paragraph)
(global-set-key (kbd bind/repeat) #'repeat)

(provide 'editor)
;;; editor.el ends here
