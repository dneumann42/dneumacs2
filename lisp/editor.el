;;; editor.el --- Core UI and editor defaults -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'subr-x)
(require 'font-tools)
(require 'toolbar)               ; for `init/toolbar--help-echo'
(require 'pulldown-menu)
(require 'init-persist)

;;;; State variables

(defvar init/frame-alpha-opaque 100
  "Alpha-background value representing a fully opaque frame.")
(defvar init/frame-alpha-translucent 95
  "Alpha-background value used for translucent frames.")
(defvar init/compilation-frame nil
  "The live child frame displaying the compilation buffer, or nil.")
(defvar init/font-size 13
  "Default font size in points for the UI font.")
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
(defconst init/cascadia-font-files
  '("CaskaydiaCoveNerdFont*.ttf"
    "CaskaydiaCoveNerdFont*.otf"
    "CascadiaCodeNerdFont*.ttf"
    "CascadiaCodeNerdFont*.otf")
  "File patterns identifying an installed Cascadia Nerd Font.")

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

(defun init/install-cascadia-font ()
  "Download and install Cascadia Nerd Font into the user font directory."
  (init/font-install-zip init/cascadia-font-url "CascadiaCode.zip"))

(defun init/ensure-default-font ()
  "Use Cascadia when available, or install it on Linux if requested."
  (let ((family
         (init/font-ensure
          'cascadia
          :families init/cascadia-font-families
          :file-patterns init/cascadia-font-files
          :default-family init/cascadia-default-family
          :prompt "Cascadia font is missing. Download and install it? "
          :installer #'init/install-cascadia-font
          :fallback-families init/iosevka-font-families)))
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
;; Restored early by `init/persist-load' (see init.el); registered here so
;; it is written back to the unified store whenever it changes.
(init/persist-register 'init/menu-bar-override)

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

(defconst init/tab-bar-menu-groups
  '((file "File" file buffer projectile)
    (edit "Edit" edit text table)
    (org "Org" agenda org headings show hide)
    (tools "Tools" tools options help-menu)
    (guides "Guides" cheatsheet-guides))
  "Top-level menu groups rendered in the tab bar.
Each entry is (KEY LABEL MENU-KEY...), where the remaining keys name
existing mode-sensitive menu-bar menus that become submenus.")

(defun init/tab-bar--group-menu (label members entries)
  "Build a menu named LABEL from MEMBER keys found in ENTRIES."
  (let ((menu (make-sparse-keymap label)))
    ;; `define-key' prepends menu entries, hence the reverse iteration.
    (dolist (member (reverse members))
      (when-let ((entry (alist-get member entries)))
        (define-key menu (vector member)
                    `(menu-item ,(car entry) ,(cdr entry)))))
    menu))

(defun init/tab-bar--menu-entries ()
  "Return an alist of (KEY . (LABEL . KEYMAP)) for the top-level menu bar."
  (let (entries)
    (map-keymap
     (lambda (key binding)
       (when-let ((entry (init/tab-bar--menu-entry binding)))
         (push (cons key entry) entries)))
     (menu-bar-keymap))
    entries))

(defun init/tab-bar--map-groups (fn)
  "Call FN with (KEY LABEL MENU) for each non-empty group, in order.
Groups are defined by `init/tab-bar-menu-groups'; shared by the tab-bar
buttons and the keyboard `init/menu-bar-open'."
  (let ((entries (init/tab-bar--menu-entries)))
    (dolist (group init/tab-bar-menu-groups)
      (pcase-let ((`(,key ,label . ,members) group))
        (let ((menu (init/tab-bar--group-menu label members entries)))
          (when (> (length menu) 2)
            (funcall fn key label menu)))))))

(defun init/tab-bar-menu-format ()
  "Return the grouped menu-bar buttons for the tab bar, or nil when hidden."
  (when (init/menu-bar-desired-p)
    (let (items)
      (init/tab-bar--map-groups
       (lambda (key label menu)
         (push `(,key menu-item
                      ,(propertize (concat " " label " ")
                                   'face 'tab-bar-tab-inactive
                                   'mouse-face 'highlight)
                      ,(lambda (event)
                         (interactive "e")
                         (pulldown-menu-popup menu event))
                      :help ,label)
               items)))
      ;; Append a stretch that fills to the right edge with the `tab-bar'
      ;; face, so the bar and its bottom border span the whole frame width
      ;; instead of stopping after the last button.
      (when items
        (append (nreverse items)
                (list `(init/tab-bar-filler menu-item
                        ,(propertize " "
                                     'display '(space :align-to right)
                                     'face 'tab-bar)
                        ignore)))))))

(defun init/menu-bar--combined-keymap ()
  "Return one keymap holding every menu-bar group as a submenu.
Lets the menu bar be opened and navigated entirely from the keyboard."
  (let ((top (make-sparse-keymap "Menu")))
    (init/tab-bar--map-groups
     (lambda (key label menu)
       (define-key-after top (vector key) `(menu-item ,label ,menu))))
    top))

(defun init/menu-bar-open ()
  "Open the menu-bar menus as a keyboard-navigable themed pulldown.
Every group (File, Edit, ...) appears as a submenu, so all menu-bar
menus are reachable with the arrow keys from a single keypress."
  (interactive)
  (pulldown-menu-popup (init/menu-bar--combined-keymap)))

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
  (init/persist-save-variable 'init/menu-bar-override)
  (init/menu-bar-refresh)
  (message "Menu bar %s"
           (if (eq init/menu-bar-override 'on) "shown" "hidden")))

(declare-function treemacs "treemacs")
(declare-function org-capture "org-capture")
(declare-function init/doc-toolbar-mode "doc-toolbar")

(defun init/modeline-button (glyph help command)
  "Return a clickable mode-line segment showing GLYPH that runs COMMAND.
The tooltip includes COMMAND's current keybinding, looked up in the
hovered window's buffer when the tooltip is shown."
  (propertize
   (format " %s " glyph)
   'help-echo (init/toolbar--help-echo help command)
   'mouse-face 'mode-line-highlight
   'local-map (let ((map (make-sparse-keymap)))
                (define-key map [mode-line mouse-1] command)
                map)))

(defun init/modeline-buttons ()
  "Return the clickable button strip shown in the mode line.
The project and session tools live in the document toolbar (⚒)."
  (concat
   (init/modeline-button "☰" "Toggle menu bar" #'init/toggle-menu-bar)
   (init/modeline-button "⚒" "Toggle toolbar" #'init/doc-toolbar-mode)
   (init/modeline-button "◧" "Toggle Treemacs" #'treemacs)
   (init/modeline-button "✎" "Org capture" #'org-capture)))

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

(defvar init/wallust-theme-watch-timer nil
  "Timer that checks whether Wallust replaced its generated theme.")

(defvar init/wallust-theme-modification-time nil
  "Last observed modification time of the generated Wallust theme.")

(defun init/wallust-theme-file ()
  "Return the generated Wallust theme filename."
  (expand-file-name "themes/wallust-theme.el" user-emacs-directory))

(defun init/reload-wallust-theme-if-active ()
  "Reload the generated Wallust theme without changing the selected theme."
  (when (custom-theme-enabled-p 'wallust)
    (disable-theme 'wallust)
    (load-theme 'wallust t)))

(defun init/check-wallust-theme-file ()
  "Reload the active Wallust theme after its generated file changes."
  (when-let* ((attributes (file-attributes (init/wallust-theme-file)))
              (modification-time (file-attribute-modification-time attributes)))
    (unless (equal modification-time init/wallust-theme-modification-time)
      (prog1
          (when init/wallust-theme-modification-time
            (init/reload-wallust-theme-if-active))
        (setq init/wallust-theme-modification-time modification-time)))))

(defun init/watch-wallust-theme ()
  "Poll Wallust's theme file so atomic replacements are detected reliably."
  (unless (timerp init/wallust-theme-watch-timer)
    (setq init/wallust-theme-modification-time
          (when-let ((attributes (file-attributes (init/wallust-theme-file))))
            (file-attribute-modification-time attributes)))
    (setq init/wallust-theme-watch-timer
          (run-with-timer 1 1 #'init/check-wallust-theme-file))))

(use-package emacs
  :ensure nil
  :init
  (add-to-list 'custom-theme-load-path
               (expand-file-name "themes" user-emacs-directory))
  (init/watch-wallust-theme)
  (tool-bar-mode -1)
  (menu-bar-mode -1)
  (scroll-bar-mode -1)
  (init/theme-load-selected)
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
  ;; Draw right-click (and keyboard) context menus with the themed
  ;; buffer-based pulldown instead of the native toolkit popup.  The mode
  ;; map binds `down-mouse-3' to a `menu-item' whose :filter Emacs renders
  ;; natively; replacing it with a command reroutes it through the pulldown.
  (define-key context-menu-mode-map [down-mouse-3] #'pulldown-menu-context-menu)
  (when (featurep 'ns)
    (define-key context-menu-mode-map [C-down-mouse-1] #'pulldown-menu-context-menu))
  (advice-add 'context-menu-open :override #'pulldown-menu-context-menu-open)
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

;; vim-surround style editing of pairs: () {} [] <> "" '' ``.
;; M-' s wraps the region (or symbol at point), M-' c changes the
;; closest pair to another, M-' d deletes it, M-' k / K kill inside /
;; including the pair, M-' i / o mark inside / including it, and a bare
;; pair key (e.g. M-' ( ) marks within that pair.
(use-package surround
  :ensure t
  :demand t
  :config
  (global-set-key (kbd bind/surround) surround-keymap))

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

;;;; Colorful mode
;; Hex and rgb colors rendered
(use-package colorful-mode
  ;; :diminish
  ;; :ensure t ; Optional
  :custom
  (colorful-use-prefix t)
  (colorful-only-strings 'only-prog)
  (css-fontify-colors nil)
  :config
  (global-colorful-mode t)
  (add-to-list 'global-colorful-modes 'helpful-mode))

;;;; Run/build panel

;; The *compilation* buffer -- plain `compile', nim run, and the
;; per-project run/build commands -- is shown in a dedicated panel that
;; can take one of two shapes, switchable at any time with
;; `init/compilation-toggle-floating' (or the panel toolbar's ⧉ button):
;;
;;   floating  a child frame at the top-right of the editing frame
;;   embedded  a bottom window split into the editing frame
;;
;; Output follows the tail as it arrives, but leaves point alone once you
;; scroll up -- both compilation-mode and comint set
;; `window-point-insertion-type', so a window sitting at the end tracks new
;; output while a scrolled-up window stays put; `compilation-scroll-output'
;; starts plain compilations at the bottom.  The panel is resizable from
;; the toolbar (⤢ / ⤡), and a floating panel can also be resized by
;; dragging its border.

(defconst init/compilation-buffer-name "*compilation*"
  "Name of the run/build panel buffer.")

(defcustom init/compilation-floating t
  "Non-nil shows the run/build panel as a floating child frame.
When nil, the panel is embedded as a bottom window in the editing frame.
Toggle at runtime with `init/compilation-toggle-floating'."
  :type 'boolean
  :group 'convenience)

(defvar init/compilation-frame-width 80
  "Width, in columns, of the floating run/build panel.")
(defvar init/compilation-frame-height 20
  "Height, in lines, of the floating run/build panel.")
(defvar init/compilation-window-height 15
  "Height, in lines, of the embedded run/build panel window.")

;; Follow output to the bottom as it appears (see the section comment).
(setq compilation-scroll-output t)

;;;;; Display

(defun init/display-compilation-in-child-frame (buffer _alist)
  "Display BUFFER in a resizable child frame at the frame's top-right.
_ALIST is accepted for `display-buffer' protocol compatibility."
  (condition-case err
      (progn
        (when (frame-live-p init/compilation-frame)
          (delete-frame init/compilation-frame))
        (let* ((parent (selected-frame))
               (child-width (* init/compilation-frame-width
                               (frame-char-width parent)))
               (left-pos (max 0 (- (frame-pixel-width parent) child-width 20)))
               (frame (make-frame
                       `((parent-frame . ,parent)
                         (width . ,init/compilation-frame-width)
                         (height . ,init/compilation-frame-height)
                         (top . 10)
                         (left . ,left-pos)
                         (undecorated . t)
                         (internal-border-width . 6)
                         (drag-internal-border . t)))))
          (setq init/compilation-frame frame)
          (set-window-buffer (frame-root-window frame) buffer)
          (raise-frame frame)
          (frame-root-window frame)))
    (error
     (message "Run panel: %s" (error-message-string err))
     nil)))

(defun init/display-compilation-in-side-window (buffer alist)
  "Display BUFFER as a bottom window spanning the editing frame."
  (display-buffer-in-side-window
   buffer
   (append alist
           `((side . bottom)
             (slot . 0)
             (window-height . ,init/compilation-window-height)
             (window-parameters . ((no-delete-other-windows . t)))))))

(defun init/compilation--display (buffer alist)
  "Route the run/build BUFFER to the floating or embedded panel."
  (if init/compilation-floating
      (init/display-compilation-in-child-frame buffer alist)
    (init/display-compilation-in-side-window buffer alist)))

(add-to-list 'display-buffer-alist
             `(,(regexp-quote init/compilation-buffer-name)
               (init/compilation--display)))

;;;;; Panel state

(defun init/compilation--buffer ()
  "Return the live run/build panel buffer, or nil."
  (get-buffer init/compilation-buffer-name))

(defun init/compilation--side-window ()
  "Return the embedded panel window, or nil."
  (when-let ((buffer (init/compilation--buffer)))
    (seq-find (lambda (window) (window-parameter window 'window-side))
              (get-buffer-window-list buffer nil t))))

(defun init/compilation--visible-p ()
  "Return non-nil when the run/build panel is on screen."
  (or (frame-live-p init/compilation-frame)
      (window-live-p (init/compilation--side-window))))

(defun init/compilation--show ()
  "Show the run/build panel for its existing buffer."
  (when-let ((buffer (init/compilation--buffer)))
    (display-buffer buffer)))

;;;;; Commands

(defun init/compilation-dismiss ()
  "Hide the run/build panel, whether floating or embedded."
  (interactive)
  (when (frame-live-p init/compilation-frame)
    (delete-frame init/compilation-frame)
    (setq init/compilation-frame nil))
  (when-let ((window (init/compilation--side-window)))
    (when (window-live-p window)
      (delete-window window))))

(defun init/compilation-focus ()
  "Give input focus to the run/build panel, if it is visible.
Selects the panel window -- the child frame's root window when floating,
the bottom window when embedded -- and moves point to the end so comint
input and the latest output are in view."
  (interactive)
  (let ((window (cond
                 ((frame-live-p init/compilation-frame)
                  (select-frame-set-input-focus init/compilation-frame)
                  (frame-root-window init/compilation-frame))
                 (t (init/compilation--side-window)))))
    (when (window-live-p window)
      (select-window window)
      (goto-char (point-max)))))

(defun init/compilation--focus-after (&rest _)
  "Advice: reveal and focus the run/build panel after a compilation starts.
Attached to `compile', so f5 and the language run commands focus the
panel; `init/project-commands--execute' calls `init/compilation-focus'
directly for the run/build (f2 / f3) comint flow."
  (init/compilation-focus))

(advice-add 'compile :after #'init/compilation--focus-after)

(defun init/compilation-toggle ()
  "Toggle the run/build panel on and off, focusing it when shown.
If no compilation buffer exists yet, start a new compilation."
  (interactive)
  (if (init/compilation--visible-p)
      (init/compilation-dismiss)
    (if (init/compilation--buffer)
        (progn
          (init/compilation--show)
          (init/compilation-focus))
      (call-interactively #'compile))))

(defun init/compilation-toggle-floating ()
  "Switch the run/build panel between a floating frame and an embedded split.
Keeps the panel (and any running process) visible across the switch."
  (interactive)
  (let ((was-visible (init/compilation--visible-p)))
    (init/compilation-dismiss)
    (setq init/compilation-floating (not init/compilation-floating))
    (when (and was-visible (init/compilation--buffer))
      (init/compilation--show))
    (message "Run panel: %s"
             (if init/compilation-floating "floating" "embedded"))))

(defun init/compilation--resize (delta)
  "Grow (DELTA > 0) or shrink the run/build panel by DELTA lines."
  (if init/compilation-floating
      (if (frame-live-p init/compilation-frame)
          (progn
            (setq init/compilation-frame-height
                  (max 6 (+ init/compilation-frame-height delta)))
            (set-frame-height init/compilation-frame
                              init/compilation-frame-height))
        (user-error "No floating run panel is open"))
    (let ((window (init/compilation--side-window)))
      (if (window-live-p window)
          (condition-case err
              (progn
                (window-resize window delta nil)
                (setq init/compilation-window-height (window-height window)))
            (error (user-error "%s" (error-message-string err))))
        (user-error "No embedded run panel is open")))))

(defun init/compilation-enlarge ()
  "Make the run/build panel taller."
  (interactive)
  (init/compilation--resize 4))

(defun init/compilation-shrink ()
  "Make the run/build panel shorter."
  (interactive)
  (init/compilation--resize -4))

(defun init/compilation-mode-hook ()
  "Bind q to dismiss the run/build panel."
  (define-key compilation-mode-map (kbd "q") #'init/compilation-dismiss))

(add-hook 'compilation-mode-hook #'init/compilation-mode-hook)

;;;; Menu bar activation

;; `tab-bar-auto-width' nil stops buttons being stretched to a 20-column min.
(setq tab-bar-format '(init/tab-bar-menu-format)
      tab-bar-show t
      tab-bar-auto-width nil)

;; The built-in `tab-bar' face carries a light background that dark themes
;; often leave unstyled, so the menu bar shows up white on a dark frame.
;; Follow the theme's `default' colors instead, and reapply on every theme
;; switch (`enable-theme-functions' runs after a theme is enabled).
(defun init/tab-bar--border-color ()
  "Return a themed color for the menu bar's bottom border."
  (seq-some (lambda (spec)
              (let ((c (apply #'face-attribute spec)))
                (and (stringp c) c)))
            '((window-divider :foreground nil t)
              (vertical-border :foreground nil t)
              (mode-line :background nil t)
              (shadow :foreground nil t)
              (default :foreground nil t))))

(defun init/harmonize-tab-bar-faces (&rest _)
  "Match the tab-bar faces to the current theme, with a bottom border.
The border is an `:underline' set on both the bar fill (`tab-bar') and
the buttons (`tab-bar-tab-inactive') so it runs continuously across the
whole width -- a `:box' would draw around each segment separately."
  (let ((bg (face-attribute 'default :background nil t))
        (fg (face-attribute 'default :foreground nil t))
        (border (init/tab-bar--border-color)))
    (when (stringp bg)
      (let ((underline (and (stringp border) (list :color border))))
        (set-face-attribute 'tab-bar nil :inherit 'default
                            :background bg :foreground fg :box nil
                            :overline nil :underline underline)
        (set-face-attribute 'tab-bar-tab-inactive nil :inherit 'default
                            :background bg :foreground fg :box nil
                            :overline nil :underline underline)))))

(if (boundp 'enable-theme-functions)
    (add-hook 'enable-theme-functions #'init/harmonize-tab-bar-faces)
  (advice-add 'load-theme :after #'init/harmonize-tab-bar-faces))
(init/harmonize-tab-bar-faces)

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
(global-set-key (kbd bind/compilation-toggle-fkey) #'init/compilation-toggle)
(global-set-key (kbd bind/compile) #'compile)
(global-set-key (kbd bind/forward-paragraph) 'forward-paragraph)
(global-set-key (kbd bind/backward-paragraph) 'backward-paragraph)
(global-set-key (kbd bind/repeat) #'repeat)
(global-set-key (kbd bind/theme-preview) #'init/theme-preview-and-select)
(global-set-key (kbd bind/theme-gallery) #'init/theme-gallery)

;; Keyboard entry points for the pulldown menus:
;;   <f10>   open the menu-bar menus (File, Edit, ...) as one pulldown
;;   S-<f10> open the right-click context menu at point (context-menu-open
;;           is advised to render through the themed pulldown)
(global-set-key (kbd "<f10>") #'init/menu-bar-open)
(global-set-key (kbd "<S-f10>") #'context-menu-open)

(provide 'editor)
;;; editor.el ends here
