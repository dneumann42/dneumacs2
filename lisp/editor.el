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

;;;; Menu bar (rendered in the tab bar)

;; `tab-bar-mode' is enabled once at startup and never toggled: toggling it
;; while a side window (Treemacs) is displayed segfaults pgtk redisplay.  The
;; menu is shown/hidden purely by what `init/tab-bar-menu-format' returns.

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

(defun init/tab-bar--menu-entry (binding)
  "Return (LABEL . MENU-KEYMAP) for a top-level menu-bar BINDING, or nil.
Handles the `menu-item' form produced by `easy-menu-define' as well as the
simple (\"Name\" . KEYMAP) form used by plain `define-key' menus (such as
the cheatsheet Guides menu)."
  (cond
   ((eq (car-safe binding) 'menu-item)
    (let ((label (nth 1 binding))
          (menu (nth 2 binding)))
      (when (symbolp menu)
        (setq menu (cond
                    ((and (fboundp menu) (keymapp (symbol-function menu)))
                     (symbol-function menu))
                    ((and (boundp menu) (keymapp (symbol-value menu)))
                     (symbol-value menu))
                    (t menu))))
      (when (and (stringp label) (keymapp menu))
        (cons label menu))))
   ((and (consp binding) (stringp (car binding)) (keymapp (cdr binding)))
    (cons (car binding) (cdr binding)))
   ((keymapp binding)
    (cons (or (keymap-prompt binding) "Menu") binding))))

(defun init/tab-bar-menu-format ()
  "Return a clickable tab-bar button per top-level menu, or nil when hidden."
  (when (init/menu-bar-desired-p)
    (let (items)
      (map-keymap
       (lambda (key binding)
         (let ((entry (init/tab-bar--menu-entry binding)))
           (when entry
             (let ((label (car entry))
                   (menu (cdr entry)))
               (push
                `(,key menu-item
                       ,(propertize (concat " " label " ")
                                    'face 'tab-bar-tab-inactive
                                    'mouse-face 'highlight)
                       ,(lambda (event)
                          (interactive "e")
                          (popup-menu menu event))
                       :help ,label)
                items)))))
       (menu-bar-keymap))
      (nreverse items))))

(defun init/menu-bar-refresh (&rest _)
  "Show or hide the tab-bar menu by setting its height on visibility changes.
Adjusts `tab-bar-lines' (safe with a side window open) rather than toggling
`tab-bar-mode' (which crashes); only acts on an actual change."
  (when (bound-and-true-p tab-bar-mode)
    (let ((want (and (init/menu-bar-desired-p) t))
          (shown (> (or (frame-parameter nil 'tab-bar-lines) 0) 0)))
      (unless (eq want shown)
        (set-frame-parameter nil 'tab-bar-lines (if want 1 0))
        (force-mode-line-update t)))))

(defun init/toggle-menu-bar ()
  "Toggle the tab-bar menu on or off and remember the manual choice."
  (interactive)
  (setq init/menu-bar-override
        (if (init/menu-bar-desired-p) 'off 'on))
  (init/menu-bar-refresh)
  (message "Menu bar %s"
           (if (eq init/menu-bar-override 'on) "shown" "hidden")))

(declare-function treemacs "treemacs")
(declare-function projectile-switch-project "projectile")
(declare-function projectile-find-file "projectile")
(declare-function magit-status "magit")
(declare-function org-capture "org-capture")
(declare-function project-eshell "project")
(declare-function consult-ripgrep "consult")
(declare-function init/project-search "project-tools")

(defun init/modeline-button (glyph help command)
  "Return a clickable mode-line segment showing GLYPH that runs COMMAND."
  (propertize
   (format " %s " glyph)
   'help-echo (concat "mouse-1: " help)
   'mouse-face 'mode-line-highlight
   'local-map (let ((map (make-sparse-keymap)))
                (define-key map [mode-line mouse-1] command)
                map)))

(defun init/modeline-buttons ()
  "Return the clickable button strip shown in the mode line."
  (concat
   (init/modeline-button "☰" "Toggle menu bar" #'init/toggle-menu-bar)
   (init/modeline-button "◧" "Toggle Treemacs" #'treemacs)
   (init/modeline-button "❒" "Open project" #'projectile-switch-project)
   (init/modeline-button "⎇" "Magit status" #'magit-status)
   (init/modeline-button "❯" "Project eshell" #'project-eshell)
   (init/modeline-button "✎" "Org capture" #'org-capture)
   (init/modeline-button "◐" "Toggle transparency" #'init/toggle-frame-transparency)
   (init/modeline-button "▤" "Find file in project" #'projectile-find-file)
   (init/modeline-button "⌕" "Project search" #'init/project-search)))

;;;; Misc editor commands and helpers

(defun init/reload-config ()
  "Reload the configuration, re-evaluating the lisp/ modules too.
Loading `user-init-file' alone re-runs its `require' forms, but those are
no-ops for already-loaded features.  Dropping every feature whose file lives
under lisp/ from `features' first makes those requires re-load in order."
  (interactive)
  (condition-case err
      (let ((lisp-dir (file-name-as-directory
                       (expand-file-name "lisp" user-emacs-directory))))
        (setq features
              (seq-remove
               (lambda (feat)
                 (let ((file (locate-library (symbol-name feat))))
                   (and file (string-prefix-p lisp-dir (expand-file-name file)))))
               features))
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
  ;; Keep backups and auto-saves as a safety net, but out of working trees.
  (setq backup-directory-alist
        `(("." . ,(expand-file-name "backups" user-emacs-directory)))
        backup-by-copying t
        version-control t
        delete-old-versions t
        kept-new-versions 6
        kept-old-versions 2)
  (setq auto-save-file-name-transforms
        `((".*" ,(expand-file-name "auto-saves/" user-emacs-directory) t)))
  (make-directory (expand-file-name "auto-saves" user-emacs-directory) t)
  (setq create-lockfiles nil)
  (setq auto-revert-verbose nil)
  (setq use-short-answers t)
  (setq kill-do-not-save-duplicates t)
  (setq require-final-newline t)
  (setq xref-search-program 'ripgrep)
  (delete-selection-mode 1)
  (when (fboundp 'pixel-scroll-precision-mode)
    (pixel-scroll-precision-mode 1))
  (global-so-long-mode 1)
  (repeat-mode 1)
  (context-menu-mode 1)
  (save-place-mode 1)
  (add-hook 'prog-mode-hook #'display-line-numbers-mode)
  (add-hook 'prog-mode-hook #'hl-line-mode)
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

(use-package recentf
  :ensure nil
  :custom
  (recentf-max-saved-items 300)
  (recentf-exclude
   (list (regexp-quote (expand-file-name "elpa/" user-emacs-directory))
         (regexp-quote (expand-file-name "eln-cache/" user-emacs-directory))))
  :init
  (recentf-mode 1))

(use-package ace-window
  :bind (("C-0" . ace-window)))

(use-package avy
  :defer t
  :init
  (global-set-key (kbd bind/avy-goto-char) #'avy-goto-char))

;; Prefer tree-sitter major modes and offer to install missing grammars.
(use-package treesit-auto
  :custom
  (treesit-auto-install 'prompt)
  :config
  (treesit-auto-add-to-auto-mode-alist 'all)
  (global-treesit-auto-mode))

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

;; `tab-bar-auto-width' nil stops buttons being stretched to a 20-column min.
(setq tab-bar-format '(init/tab-bar-menu-format)
      tab-bar-show t
      tab-bar-auto-width nil)

;; Enable the tab bar once, before any side window exists; never toggle it.
(tab-bar-mode 1)

(unless (member '(:eval (init/modeline-buttons)) global-mode-string)
  (setq global-mode-string
        (append global-mode-string '((:eval (init/modeline-buttons))))))
(add-hook 'window-selection-change-functions #'init/menu-bar-refresh)
(add-hook 'window-buffer-change-functions #'init/menu-bar-refresh)
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
