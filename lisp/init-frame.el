;;; init-frame.el --- Frame chrome, menu bar and mode line -*- lexical-binding: t; -*-

;;; Commentary:

;; The furniture around the text: which widgets a frame is built with,
;; how transparent it is, the menu bar, and the mode line.
;;
;; The native menu bar, tool bar and scroll bars are all off.  The
;; menu-bar menus are instead rendered as themed pulldowns triggered from
;; buttons drawn in the tab bar, grouped by `init/tab-bar-menu-groups' so
;; the row stays short.  The bar is shown automatically in Org buffers and
;; can be forced on or off, a choice that persists across sessions.
;;
;; The mode line is doom-modeline plus a short strip of clickable buttons
;; for the toggles that are otherwise easy to forget.

;;; Code:

(require 'seq)
(require 'init-keys)
(require 'init-persist)
(require 'init-pulldown)
(require 'init-toolbar)

(declare-function treemacs "treemacs")
(declare-function org-capture "org-capture")
(declare-function init/org-find-file "init-org")

;;;; Frame chrome

(tool-bar-mode -1)
(menu-bar-mode -1)
(scroll-bar-mode -1)

;;;; Transparency

(defgroup init/frame-transparency nil
  "Background transparency (alpha) for Emacs frames."
  :group 'frames
  :prefix "init/frame-alpha-")

(defun init/frame-alpha--reapply ()
  "Apply the current translucent alpha to translucent and future frames.
The `alpha-background' entry in `default-frame-alist' is refreshed so new
frames honour the value, and every existing frame that is not fully
opaque is updated in place.  Frames sitting at the opaque level are left
alone, so a Customize change to `init/frame-alpha-translucent' is
reflected at once without forcing transparency onto frames the user
deliberately made opaque."
  (when (and (boundp 'init/frame-alpha-opaque)
             (boundp 'init/frame-alpha-translucent))
    (setf (alist-get 'alpha-background default-frame-alist)
          init/frame-alpha-translucent)
    (dolist (frame (frame-list))
      (let ((current (frame-parameter frame 'alpha-background)))
        (when (and current (< current init/frame-alpha-opaque))
          (set-frame-parameter frame 'alpha-background
                               init/frame-alpha-translucent))))))

(defun init/frame-alpha--set (symbol value)
  "Custom `:set' function: store VALUE in SYMBOL, then refresh frames live."
  (set-default symbol value)
  (init/frame-alpha--reapply))

(defcustom init/frame-alpha-opaque 100
  "Alpha-background percentage representing a fully opaque frame.
This is the baseline `init/toggle-frame-transparency' returns to; 100
means no transparency at all."
  :type '(integer :tag "Percent (0-100)")
  :set #'init/frame-alpha--set
  :group 'init/frame-transparency)

(defcustom init/frame-alpha-translucent 95
  "Alpha-background percentage used for translucent frames.
Lower is more see-through: 100 is fully opaque, 0 shows only whatever is
behind Emacs.  Change it with \\[customize-option] and translucent frames
update immediately."
  :type '(integer :tag "Percent (0-100)")
  :set #'init/frame-alpha--set
  :group 'init/frame-transparency)

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

(add-to-list 'default-frame-alist
             `(alpha-background . ,init/frame-alpha-translucent))
(init/apply-frame-transparency)

;;;; The menu bar, rendered in the tab bar

;; `tab-bar-mode' is enabled once at startup and never toggled: toggling
;; it while a side window (Treemacs) is displayed segfaults pgtk
;; redisplay.  The menu is shown and hidden purely by what
;; `init/tab-bar-menu-format' returns and by the frame's `tab-bar-lines'.

(defvar init/menu-bar-auto-modes '(org-mode)
  "Major modes for which the menu bar is shown automatically.")

(defvar init/menu-bar-override nil
  "Manual override for the menu bar.
`on' forces it visible everywhere, `off' forces it hidden, and nil defers
to `init/menu-bar-auto-modes'.")
;; Restored early by `init/persist-load'; registered here so it is written
;; back to the store whenever it changes.
(init/persist-register 'init/menu-bar-override)

(defconst init/tab-bar-menu-groups
  '((file "File" file buffer projectile)
    (edit "Edit" edit text table)
    (org "Org" agenda org headings show hide)
    (tools "Tools" tools options help-menu)
    (guides "Guides" cheatsheet-guides))
  "Top-level menu groups rendered in the tab bar.
Each entry is (KEY LABEL MENU-KEY...), where the remaining keys name
existing mode-sensitive menu-bar menus that become submenus.")

(defun init/menu-bar-relevant-buffer ()
  "Return the buffer whose mode should decide menu-bar visibility.
This is the buffer displayed in the frame's selected window, not
`current-buffer', which during window-change hooks is often a transient
or minibuffer buffer.  While the minibuffer is active, defer to the
window selected before it, so prompts do not flicker the menu."
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
Handles the `menu-item' form produced by `easy-menu-define' as well as
the simple (\"Name\" . KEYMAP) form used by plain `define-key' menus,
such as the cheatsheet Guides menu."
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

(defun init/tab-bar--menu-entries ()
  "Return an alist of (KEY . (LABEL . KEYMAP)) for the top-level menu bar."
  (let (entries)
    (map-keymap
     (lambda (key binding)
       (when-let* ((entry (init/tab-bar--menu-entry binding)))
         (push (cons key entry) entries)))
     (menu-bar-keymap))
    entries))

(defun init/tab-bar--group-menu (label members entries)
  "Build a menu named LABEL from the MEMBER keys found in ENTRIES."
  (let ((menu (make-sparse-keymap label)))
    ;; `define-key' prepends menu entries, hence the reverse iteration.
    (dolist (member (reverse members))
      (when-let* ((entry (alist-get member entries)))
        (define-key menu (vector member)
                    `(menu-item ,(car entry) ,(cdr entry)))))
    menu))

(defun init/tab-bar--map-groups (function)
  "Call FUNCTION with (KEY LABEL MENU) for each non-empty group, in order.
Groups are defined by `init/tab-bar-menu-groups'; this is shared by the
tab-bar buttons and by the keyboard entry point `init/menu-bar-open'."
  (let ((entries (init/tab-bar--menu-entries)))
    (dolist (group init/tab-bar-menu-groups)
      (pcase-let ((`(,key ,label . ,members) group))
        (let ((menu (init/tab-bar--group-menu label members entries)))
          (when (> (length menu) 2)
            (funcall function key label menu)))))))

(defun init/tab-bar--button (key label menu)
  "Return the tab-bar item for the menu group KEY, showing LABEL for MENU."
  `(,key menu-item
         ,(propertize (concat " " label " ")
                      'face 'tab-bar-tab-inactive
                      'mouse-face 'highlight)
         ,(lambda (event)
            (interactive "e")
            (pulldown-menu-popup menu event))
         :help ,label))

(defun init/tab-bar--filler ()
  "Return a stretch item filling the tab bar out to the right frame edge.
Without it the bar, and its bottom border, stop after the last button."
  `(init/tab-bar-filler menu-item
                        ,(propertize " "
                                     'display '(space :align-to right)
                                     'face 'tab-bar)
                        ignore))

(defun init/tab-bar-menu-format ()
  "Return the grouped menu-bar buttons for the tab bar, or nil when hidden."
  (when (init/menu-bar-desired-p)
    (let (items)
      (init/tab-bar--map-groups
       (lambda (key label menu)
         (push (init/tab-bar--button key label menu) items)))
      (when items
        (append (nreverse items) (list (init/tab-bar--filler)))))))

(defun init/menu-bar--combined-keymap ()
  "Return one keymap holding every menu-bar group as a submenu.
This lets the menu bar be opened and navigated entirely from the
keyboard."
  (let ((top (make-sparse-keymap "Menu")))
    (init/tab-bar--map-groups
     (lambda (key label menu)
       (define-key-after top (vector key) `(menu-item ,label ,menu))))
    top))

(defun init/menu-bar-open ()
  "Open the menu-bar menus as a keyboard-navigable themed pulldown.
Every group (File, Edit, ...) appears as a submenu, so all menu-bar menus
are reachable with the arrow keys from a single keypress."
  (interactive)
  (pulldown-menu-popup (init/menu-bar--combined-keymap)))

(defun init/menu-bar-refresh (&rest _)
  "Show or hide the tab-bar menu when the relevant buffer changes.
Adjusts `tab-bar-lines', which is safe with a side window open, rather
than toggling `tab-bar-mode', which crashes; only acts on a real change."
  (when (bound-and-true-p tab-bar-mode)
    (let ((want (and (init/menu-bar-desired-p) t))
          (shown (> (or (frame-parameter nil 'tab-bar-lines) 0) 0)))
      (unless (eq want shown)
        (set-frame-parameter nil 'tab-bar-lines (if want 1 0))
        (force-mode-line-update t)))))

(defun init/toggle-menu-bar ()
  "Toggle the tab-bar menu on or off and remember the manual choice."
  (interactive)
  (setq init/menu-bar-override (if (init/menu-bar-desired-p) 'off 'on))
  (init/persist-save-variable 'init/menu-bar-override)
  (init/menu-bar-refresh)
  (message "Menu bar %s" (if (eq init/menu-bar-override 'on) "shown" "hidden")))

;;;; Tab-bar faces

;; The built-in `tab-bar' face carries a light background that dark themes
;; often leave unstyled, so the menu bar shows up white on a dark frame.
;; Follow the theme's `default' colours instead, and reapply on every
;; theme switch.

(defun init/tab-bar--border-color ()
  "Return a themed colour for the menu bar's bottom border."
  (seq-some (lambda (spec)
              (let ((color (apply #'face-attribute spec)))
                (and (stringp color) color)))
            '((window-divider :foreground nil t)
              (vertical-border :foreground nil t)
              (mode-line :background nil t)
              (shadow :foreground nil t)
              (default :foreground nil t))))

(defun init/harmonize-tab-bar-faces (&rest _)
  "Match the tab-bar faces to the current theme, with a bottom border.
The border is an `:underline' set on both the bar fill (`tab-bar') and
the buttons (`tab-bar-tab-inactive') so it runs continuously across the
whole width; a `:box' would draw around each segment separately."
  (let ((background (face-attribute 'default :background nil t))
        (foreground (face-attribute 'default :foreground nil t))
        (border (init/tab-bar--border-color)))
    (when (stringp background)
      (let ((underline (and (stringp border) (list :color border))))
        (dolist (face '(tab-bar tab-bar-tab-inactive))
          (set-face-attribute face nil :inherit 'default
                              :background background :foreground foreground
                              :box nil :overline nil :underline underline))))))

(if (boundp 'enable-theme-functions)
    (add-hook 'enable-theme-functions #'init/harmonize-tab-bar-faces)
  (advice-add 'load-theme :after #'init/harmonize-tab-bar-faces))
(init/harmonize-tab-bar-faces)

;; `tab-bar-auto-width' nil stops buttons being stretched to a 20-column
;; minimum.
(setq tab-bar-format '(init/tab-bar-menu-format)
      tab-bar-show t
      tab-bar-auto-width nil)

;; Enable the tab bar once, before any side window exists; never toggle it.
(tab-bar-mode 1)

(add-hook 'window-selection-change-functions #'init/menu-bar-refresh)
(add-hook 'window-buffer-change-functions #'init/menu-bar-refresh)
(add-hook 'after-change-major-mode-hook #'init/menu-bar-refresh)

;;;; Context menus

;; Draw right-click (and keyboard) context menus with the themed
;; buffer-based pulldown instead of the native toolkit popup.  The mode
;; map binds `down-mouse-3' to a `menu-item' whose :filter Emacs renders
;; natively; replacing it with a command reroutes it through the pulldown.
(context-menu-mode 1)
(define-key context-menu-mode-map [down-mouse-3] #'pulldown-menu-context-menu)
(when (featurep 'ns)
  (define-key context-menu-mode-map [C-down-mouse-1] #'pulldown-menu-context-menu))
(advice-add 'context-menu-open :override #'pulldown-menu-context-menu-open)

;;;; Mode line

(defun init/modeline-button (glyph help command)
  "Return a clickable mode-line segment showing GLYPH that runs COMMAND.
The tooltip includes HELP and COMMAND's current keybinding, looked up in
the hovered window's buffer when the tooltip is shown."
  (propertize
   (format " %s " glyph)
   'help-echo (init/toolbar--help-echo help command)
   'mouse-face 'mode-line-highlight
   'local-map (let ((map (make-sparse-keymap)))
                (define-key map [mode-line mouse-1] command)
                map)))

(defun init/modeline-buttons ()
  "Return the clickable button strip shown in the mode line.
The project and session tools live in the global toolbar (⚒) instead."
  (concat
   (init/modeline-button "☰" "Toggle menu bar" #'init/toggle-menu-bar)
   (init/modeline-button "⚒" "Toggle toolbar" #'init/doc-toolbar-mode)
   (init/modeline-button "◧" "Toggle Treemacs" #'treemacs)
   (init/modeline-button "✎" "Org capture" #'org-capture)
   (init/modeline-button "⌕" "Org find file" #'init/org-find-file)))

(unless (member '(:eval (init/modeline-buttons)) global-mode-string)
  (setq global-mode-string
        (append global-mode-string '((:eval (init/modeline-buttons))))))

(use-package nerd-icons
  :defer t
  :init
  (defconst init/nerd-icons-font-families
    '("Symbols Nerd Font Mono"
      "Symbols Nerd Font"
      "MesloLGS Nerd Font Mono"
      "MesloLGM Nerd Font Mono"
      "MesloLGL Nerd Font Mono"
      "FantasqueSansM Nerd Font Mono")
    "Nerd Font families that can supply the mode-line icons.")

  (defun init/nerd-icons-font-family ()
    "Return the first installed family from `init/nerd-icons-font-families'."
    (let ((installed (font-family-list)))
      (seq-find (lambda (family) (member family installed))
                init/nerd-icons-font-families)))

  (defun init/configure-nerd-icons-font (&optional frame)
    "Bind `nerd-icons' to an installed Nerd Font family for FRAME."
    (when (display-graphic-p frame)
      (when-let* ((family (init/nerd-icons-font-family)))
        (setq nerd-icons-font-family family)
        (when (fboundp 'nerd-icons-set-font)
          (nerd-icons-set-font family frame)))))

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

;;;; Keybindings

(global-set-key (kbd bind/toggle-menu-bar) #'init/toggle-menu-bar)
(global-set-key (kbd bind/toggle-frame-transparency) #'init/toggle-frame-transparency)
(global-set-key (kbd bind/menu-bar-open) #'init/menu-bar-open)
(global-set-key (kbd bind/context-menu-open) #'context-menu-open)

(provide 'init-frame)
;;; init-frame.el ends here
