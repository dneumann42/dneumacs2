;;; toolbar.el --- Generic header-line toolbars -*- lexical-binding: t; -*-

;;; Commentary:

;; A small API for fixed, clickable toolbars rendered in a buffer's
;; header line, used by the Treemacs, PDF and EWW toolbars.
;;
;; Build a toolbar function with `init/toolbar-string' and attach it to
;; a buffer with `init/toolbar-attach':
;;
;;   (defun my/toolbar ()
;;     (init/toolbar-string
;;      '("⟳" "Reload" my-reload-command)
;;      :sep
;;      #'my/dynamic-segment          ; function returning a string
;;      " raw text"))
;;
;;   (add-hook 'my-mode-hook (lambda () (init/toolbar-attach #'my/toolbar)))
;;
;; Item forms understood by `init/toolbar-string':
;;   (LABEL HELP COMMAND)  clickable button
;;   :sep                  group separator
;;   a function            called with no args, must return a string
;;   a string              inserted as-is
;;   nil                   skipped (handy for conditional items)

;;; Code:

(require 'cl-lib)

(defface init/toolbar-button
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for clickable toolbar buttons."
  :group 'convenience)

(defface init/toolbar-info
  '((t :inherit shadow))
  "Face for informational toolbar segments."
  :group 'convenience)

(defface init/toolbar-border
  '((t :inherit shadow :box (:line-width -1)))
  "Face used to draw the full-width edge of a toolbar."
  :group 'convenience)

(defun init/toolbar--help-echo (help command)
  "Return a `help-echo' function combining HELP with COMMAND's keybinding.
The key is looked up when the tooltip is shown, in the hovered window's
buffer, so buffer-local bindings are reported correctly.  Unbound
commands are shown as M-x invocations."
  (lambda (window _object _pos)
    (let ((suffix
           (when (symbolp command)
             (let ((key (with-selected-window window
                          (where-is-internal command nil t))))
               (if key
                   (key-description key)
                 (format "M-x %s" command))))))
      (if suffix
          (format "%s  —  %s" help suffix)
        help))))

(defun init/toolbar--click-target (clicked)
  "Return the window a toolbar click in CLICKED should act on.
Clicks in a dedicated toolbar-bar window (window parameter
`init/toolbar-bar') are redirected to the selected window -- clicking a
button does not change the selection, so that is the window being
edited -- or to the most recently used window as a fallback.  Commands
like find-file therefore never open inside the bar."
  (cond
   ((not (window-parameter clicked 'init/toolbar-bar))
    clicked)
   ((not (window-parameter (selected-window) 'init/toolbar-bar))
    (selected-window))
   (t
    (or (get-mru-window nil nil t) clicked))))

(defun init/toolbar--keymap (command)
  "Return a keymap running COMMAND on a mouse-1 click.
Works both as a header-line segment and as buffer text.  The command
runs with the clicked (or redirected, see `init/toolbar--click-target')
window selected, so buffer-local commands act on the right buffer."
  (let ((map (make-sparse-keymap))
        (action (lambda (event)
                  (interactive "e")
                  (with-selected-window
                      (init/toolbar--click-target
                       (posn-window (event-start event)))
                    (call-interactively command)))))
    (define-key map [header-line mouse-1] action)
    (define-key map [mouse-1] action)
    map))

(defun init/toolbar-button (label help command)
  "Return a clickable toolbar LABEL that runs COMMAND.
HELP is shown as the tooltip, together with COMMAND's current
keybinding so the shortcut can be learned."
  (propertize label
              'help-echo (init/toolbar--help-echo help command)
              'mouse-face 'highlight
              'pointer 'hand
              'face 'init/toolbar-button
              'local-map (init/toolbar--keymap command)))

(defun init/toolbar-info (label &optional help command)
  "Return an informational toolbar segment showing LABEL.
With HELP, show it as a tooltip (including COMMAND's keybinding when
COMMAND is given).  With COMMAND, make the segment clickable too."
  (apply #'propertize label
         'face 'init/toolbar-info
         (append
          (when help
            (list 'help-echo (if command
                                 (init/toolbar--help-echo help command)
                               help)))
          (when command
            (list 'mouse-face 'highlight
                  'pointer 'hand
                  'local-map (init/toolbar--keymap command))))))

(defun init/toolbar-menu-button (label help menu)
  "Return a clickable toolbar LABEL that pops up MENU.
MENU is an easy-menu item list; HELP is the tooltip."
  (propertize label
              'help-echo help
              'mouse-face 'highlight
              'pointer 'hand
              'face 'init/toolbar-button
              'local-map
              (let ((map (make-sparse-keymap)))
                (define-key map [header-line mouse-1]
                            (lambda (event)
                              (interactive "e")
                              (let* ((keymap (easy-menu-create-menu nil menu))
                                     (choice (x-popup-menu event keymap)))
                                (when choice
                                  (let ((cmd (lookup-key keymap (apply #'vector choice))))
                                    (when (commandp cmd)
                                      (with-selected-window (posn-window (event-start event))
                                        (call-interactively cmd))))))))
                map)))

(defun init/toolbar-separator ()
  "Return the separator drawn between toolbar groups."
  (propertize " │ " 'face 'init/toolbar-info))

(defun init/toolbar-string (&rest items)
  "Compose ITEMS into a toolbar string.
See the Commentary for the accepted item forms."
  (let ((toolbar
         (concat
          " "
          (mapconcat
           #'identity
           (delq nil
                 (mapcar (lambda (item)
                           (cond
                            ((null item) nil)
                            ((eq item :sep) (init/toolbar-separator))
                            ((stringp item) item)
                            ((functionp item) (funcall item))
                            ((listp item) (apply #'init/toolbar-button item))
                            (t (error "Unknown toolbar item: %S" item))))
                         items))
           " ")
          ;; Fill the remainder of either a header line or the dedicated
          ;; toolbar window, so the border spans the complete bar.  The
          ;; taller invisible space adds vertical padding to the line box;
          ;; unlike a thicker `:box', it does not enlarge the border.
          (propertize " " 'display
                      '(space :align-to right-fringe :height 1.2 :ascent 80)))))
    ;; Keep every segment at the same height and draw a bar edge rather
    ;; than underlining the text itself.
    (add-face-text-property 0 (length toolbar) '(:height 1.0) nil toolbar)
    (add-face-text-property 0 (length toolbar) 'init/toolbar-border t toolbar)
    toolbar))

(defvar-local init/toolbar--function nil
  "Function producing this buffer's header-line toolbar.")

(defun init/toolbar-attach (function)
  "Show FUNCTION's toolbar in the current buffer's header line.
FUNCTION is called on every redisplay, so keep it cheap."
  (setq init/toolbar--function function)
  (setq-local header-line-format '(:eval (funcall init/toolbar--function))))

(defun init/toolbar-detach ()
  "Remove the toolbar from the current buffer's header line."
  (when init/toolbar--function
    (setq init/toolbar--function nil)
    (kill-local-variable 'header-line-format)))

(provide 'toolbar)
;;; toolbar.el ends here
