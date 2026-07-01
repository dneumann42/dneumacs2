;;; cheatsheet.el --- A tiny API for building keybinding cheatsheets -*- lexical-binding: t; -*-

;;; Commentary:
;; A small framework for defining cheatsheets and viewing them.
;;
;; Define one with `cheatsheet-define'.  A cheatsheet is a named set of
;; sections, and each section is a list of rows.  A row usually names a
;; command; its key sequence is looked up *live* from the active keymaps
;; when the sheet is displayed, so the cheatsheet always reflects the
;; current bindings -- rebind a command and the sheet updates itself.
;;
;; Every registered cheatsheet shows up in the "Guides" menu on the menu
;; bar, and can be opened with `cheatsheet-show'.
;;
;; Row forms accepted inside a section:
;;
;;   (COMMAND "description")
;;       Show COMMAND's current binding (looked up in the global map).
;;
;;   (COMMAND "description" :in KEYMAP)
;;       Look the binding up inside KEYMAP (a keymap variable symbol),
;;       e.g. `org-mode-map'.  Use this for mode-local commands.
;;
;;   (COMMAND "description" :then "j")
;;       Show COMMAND's binding followed by the literal keys "j" (handy
;;       for things like a capture prefix plus a template selector).
;;
;;   (:keys "C-c a" "description")
;;       A literal key string that is not tied to a command.
;;
;;   (:note "free-form text")
;;       A plain descriptive line with no key column.

;;; Code:

(require 'cl-lib)
(require 'keybindings)

(defvar cheatsheet-registry nil
  "Alist mapping a cheatsheet name (string) to its list of sections.
Entries are kept in definition order.")

;;;; Defining cheatsheets

(defun cheatsheet-define (name &rest sections)
  "Define or replace the cheatsheet called NAME (a string).
Each SECTION is a list (TITLE ROW...).  See the Commentary for the
accepted ROW forms.  Registered cheatsheets appear in the Guides menu."
  (setq cheatsheet-registry
        (append (assoc-delete-all name cheatsheet-registry)
                (list (cons name sections))))
  (cheatsheet--rebuild-menu)
  name)

;;;; Resolving keys (always live, never hard-coded)

(defun cheatsheet--command-keys (command &optional keymap)
  "Return COMMAND's current key binding as a string.
When KEYMAP (a keymap variable symbol) is non-nil and bound, resolve the
binding within that keymap; otherwise use the active keymaps.  Falls back
to \"M-x COMMAND\" when COMMAND is not bound to any key."
  (condition-case nil
      (if (and keymap (boundp keymap))
          (substitute-command-keys (format "\\<%s>\\[%s]" keymap command))
        (substitute-command-keys (format "\\[%s]" command)))
    (error (format "M-x %s" command))))

(defun cheatsheet--parse-row (row)
  "Return a plist (:keys STR :desc STR :note BOOL) describing ROW."
  (pcase (car row)
    (:note (list :keys nil :desc (nth 1 row) :note t))
    (:keys (list :keys (nth 1 row) :desc (nth 2 row)))
    (command
     (let* ((desc (nth 1 row))
            (opts (nthcdr 2 row))
            (keymap (plist-get opts :in))
            (then (plist-get opts :then))
            (keys (cheatsheet--command-keys command keymap)))
       (list :keys (if then (concat keys " " then) keys)
             :desc desc)))))

;;;; Rendering and display

(define-derived-mode cheatsheet-mode special-mode "Cheatsheet"
  "Major mode for viewing a cheatsheet.")

(defun cheatsheet--render (name)
  "Insert the rendered cheatsheet NAME into the current buffer."
  (let* ((sections (cdr (assoc name cheatsheet-registry)))
         (parsed (mapcar (lambda (section)
                           (cons (car section)
                                 (mapcar #'cheatsheet--parse-row (cdr section))))
                         sections))
         (widths (cl-loop for section in parsed
                          append (cl-loop for row in (cdr section)
                                          for k = (plist-get row :keys)
                                          when k collect (length k))))
         (width (apply #'max 0 widths)))
    (insert (propertize name 'face '(:height 1.4 :weight bold)) "\n\n")
    (dolist (section parsed)
      (insert (propertize (car section) 'face '(:weight bold :underline t)) "\n")
      (dolist (row (cdr section))
        (let ((keys (plist-get row :keys))
              (desc (plist-get row :desc)))
          (if keys
              (insert (format "  %s   %s\n"
                              (propertize (string-pad keys width)
                                          'face 'help-key-binding)
                              desc))
            (insert (format "  %s\n" (propertize (or desc "") 'face 'italic))))))
      (insert "\n"))))

;;;###autoload
(defun cheatsheet-show (name)
  "Display the cheatsheet named NAME.
Interactively, prompt with completion over the registered cheatsheets."
  (interactive
   (list (completing-read "Cheatsheet: "
                          (mapcar #'car cheatsheet-registry) nil t)))
  (let ((buffer (get-buffer-create (format "*Cheatsheet: %s*" name))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (cheatsheet--render name)
        (goto-char (point-min)))
      (cheatsheet-mode))
    (pop-to-buffer buffer)))

;;;; Guides menu

(defvar cheatsheet-menu-map (make-sparse-keymap "Guides")
  "Keymap backing the \"Guides\" menu-bar entry.")

(defun cheatsheet--rebuild-menu ()
  "Rebuild the Guides menu from `cheatsheet-registry'."
  (setq cheatsheet-menu-map (make-sparse-keymap "Guides"))
  ;; Define in reverse so items display in registry (definition) order.
  (dolist (entry (reverse cheatsheet-registry))
    (let ((name (car entry)))
      (define-key cheatsheet-menu-map (vector (intern name))
                  `(menu-item ,name
                              (lambda () (interactive) (cheatsheet-show ,name))))))
  (define-key-after (lookup-key global-map [menu-bar]) [cheatsheet-guides]
    (cons "Guides" cheatsheet-menu-map) 'tools))

(global-set-key (kbd bind/cheatsheet) #'cheatsheet-show)

;;;; Cheatsheet definitions
;; Add your own cheatsheets below with `cheatsheet-define'.

(cheatsheet-define "Org & Agenda"
  '("Daily journal (one entry per day, keep editing it)"
    (init/org-goto-journal "Open today's entry and keep writing")
    (:note "With C-u first, pick a different day.")
    (:note "It is a normal Org buffer -- just save when done."))
  '("Capturing tasks"
    (org-capture "Open the capture menu")
    (org-capture "Quick TODO into the inbox" :then "t")
    (org-capture "Scheduled TODO"            :then "s"))
  '("The agenda"
    (org-agenda "Open the agenda dispatcher")
    (org-agenda "This week's calendar view"           :then "a")
    (org-agenda "List every TODO across all files"    :then "t"))
  '("Dating a heading (inside an Org buffer)"
    (org-schedule  "Schedule the heading at point"   :in org-mode-map)
    (org-deadline  "Give the heading a deadline"     :in org-mode-map)
    (org-todo      "Cycle the TODO state"            :in org-mode-map)
    (org-timestamp "Insert a plain date/time stamp"  :in org-mode-map))
  '("Inside the agenda view"
    (org-agenda-day-view    "Switch to day view"        :in org-agenda-mode-map)
    (org-agenda-week-view   "Switch to week view"       :in org-agenda-mode-map)
    (org-agenda-later       "Move forward in time"      :in org-agenda-mode-map)
    (org-agenda-earlier     "Move backward in time"     :in org-agenda-mode-map)
    (org-agenda-goto-today  "Jump back to today"        :in org-agenda-mode-map)
    (org-agenda-todo        "Change a task's state"     :in org-agenda-mode-map)
    (org-agenda-goto        "Jump to the item's file"   :in org-agenda-mode-map)
    (org-agenda-quit        "Close the agenda"          :in org-agenda-mode-map)))

(cheatsheet-define "Coding & LSP"
  '("Navigation"
    (init/ide-goto-definition "Jump to definition"        :in init/ide-mode-map)
    (init/ide-go-back         "Jump back"                 :in init/ide-mode-map)
    (init/ide-hover           "Docs for symbol at point"  :in init/ide-mode-map)
    (init/ide-project-symbols "Search symbols in project" :in init/ide-mode-map))
  '("Fixing code"
    (init/ide-actions     "Offer code actions"        :in init/ide-mode-map)
    (init/ide-fix         "Apply a quick fix"         :in init/ide-mode-map)
    (init/ide-format      "Format the buffer"         :in init/ide-mode-map)
    (init/ide-diagnostics "Show diagnostics"          :in init/ide-mode-map)
    (init/ide-reconnect   "Restart the language server" :in init/ide-mode-map))
  '("Running & testing"
    (init/ide-run          "Run the current program"       :in init/ide-mode-map)
    (init/ide-test-at-point "Run the test at point"        :in init/ide-mode-map)
    (init/ide-test-file    "Run the tests in this file"    :in init/ide-mode-map)
    (init/ide-test-project "Run the whole project's tests" :in init/ide-mode-map)
    (init/ide-repl         "Open the language REPL"        :in init/ide-mode-map)
    (init/ide-sync         "Sync project / language server" :in init/ide-mode-map)
    (init/ide-debug        "Start a debugging session (DAP)" :in init/ide-mode-map))
  '("Notes"
    (:note "These work in language buffers (init/ide-mode).")
    (:note "The action taken adapts to the current language.")))

(cheatsheet-define "Projects (Projectile)"
  '("Project panel (repo registry)"
    (init/project-panel-toggle "Toggle the panel (also ▦ in the mode line)")
    (:note "In the panel: a add, c clone, RET/o open, u fetch,")
    (:note "d remove, g refresh, TAB between buttons, q close."))
  '("Move around a project"
    (projectile-switch-project   "Switch to another project")
    (projectile-find-file        "Find a file in the project")
    (projectile-find-dir         "Find a directory")
    (projectile-switch-to-buffer "Switch to a project buffer")
    (projectile-find-other-file  "Toggle header / source")
    (projectile-recentf          "Recent files in this project")
    (projectile-dired            "Open the project root in Dired"))
  '("Search & replace"
    (projectile-ripgrep "Search the project (ripgrep)")
    (projectile-grep    "Search the project (grep)")
    (projectile-replace "Replace across the project"))
  '("Build / run / test"
    (projectile-compile-project "Compile the project")
    (projectile-run-project     "Run the project")
    (projectile-test-project    "Test the project"))
  '("Housekeeping"
    (projectile-kill-buffers      "Close all project buffers")
    (projectile-invalidate-cache  "Refresh the project file cache"))
  '("Notes"
    (:note "Every command lives under the C-c p (or s-p) prefix.")))

(cheatsheet-define "Treemacs (file tree)"
  '("Open & focus"
    (treemacs                     "Toggle the file tree")
    (treemacs-select-window       "Jump to / focus the tree")
    (treemacs-find-file           "Reveal the current file in the tree")
    (treemacs-delete-other-windows "Maximise the tree window")
    (treemacs-select-directory    "Add a directory to the tree")
    (treemacs-bookmark            "Jump to a bookmarked node"))
  '("Inside the tree"
    (treemacs-TAB-action    "Expand / collapse the node" :in treemacs-mode-map)
    (treemacs-next-line     "Next line"                  :in treemacs-mode-map)
    (treemacs-previous-line "Previous line"              :in treemacs-mode-map)
    (treemacs-visit-node-vertical-split   "Open in a vertical split"   :in treemacs-mode-map)
    (treemacs-visit-node-horizontal-split "Open in a horizontal split" :in treemacs-mode-map)
    (treemacs-refresh       "Refresh the tree"           :in treemacs-mode-map))
  '("Editing files from the tree"
    (treemacs-create-file "Create a file"              :in treemacs-mode-map)
    (treemacs-create-dir  "Create a directory"         :in treemacs-mode-map)
    (treemacs-rename-file "Rename the node at point"   :in treemacs-mode-map)
    (treemacs-delete-file "Delete the node at point"   :in treemacs-mode-map)
    (treemacs-toggle-show-dotfiles "Show / hide dotfiles" :in treemacs-mode-map))
  '("Notes"
    (:note "RET opens the file / expands the node at point.")
    (:note "Press ? in the tree for Treemacs's own command help.")))

(cheatsheet-define "Finding & Completion"
  '("Search & jump (Consult)"
    (init/consult-line-repeat "Search lines in this buffer")
    (consult-ripgrep   "Search the whole project")
    (consult-buffer    "Switch buffer / recent file / bookmark")
    (consult-goto-line "Go to a line number")
    (consult-imenu     "Jump to a definition in this buffer")
    (consult-yank-pop  "Paste from the kill ring"))
  '("Act on things (Embark)"
    (embark-act      "Act on the thing at point / candidate")
    (embark-dwim     "Do the obvious action")
    (embark-bindings "Show every binding under a prefix"))
  '("In the minibuffer (Vertico)"
    (vertico-next       "Next candidate"        :in vertico-map)
    (vertico-previous   "Previous candidate"    :in vertico-map)
    (vertico-exit       "Accept the selection"  :in vertico-map)
    (vertico-exit-input "Accept your raw input" :in vertico-map))
  '("In the completion popup (Corfu)"
    (corfu-next     "Next completion"          :in corfu-map)
    (corfu-previous "Previous completion"      :in corfu-map)
    (corfu-insert   "Insert the selection"     :in corfu-map)
    (corfu-complete "Complete common prefix"   :in corfu-map)
    (corfu-info-documentation "Show docs for the candidate" :in corfu-map)
    (corfu-quit     "Dismiss the popup"        :in corfu-map))
  '("Snippets"
    (yas-insert-snippet "Insert a snippet")))

(cheatsheet-define "Editor essentials"
  '("Config"
    (init/reload-config "Reload the whole configuration")
    (cheatsheet-show    "Open a cheatsheet"))
  '("Frame & UI"
    (init/toggle-menu-bar          "Show / hide the menu bar")
    (init/toggle-frame-transparency "Toggle frame transparency"))
  '("Moving & editing"
    (avy-goto-char     "Jump to a visible character")
    (forward-paragraph  "Move forward a paragraph")
    (backward-paragraph "Move backward a paragraph")
    (repeat            "Repeat the last command"))
  '("Compilation"
    (compile               "Run a compile command")
    (init/compilation-toggle "Toggle the compilation buffer")))

(provide 'cheatsheet)
;;; cheatsheet.el ends here
