;;; init-cheatsheet.el --- Live keybinding guides -*- lexical-binding: t; -*-

;;; Commentary:

;; A tiny framework for keybinding guides, plus the guides themselves.
;;
;; Define one with `cheatsheet-define'.  A cheatsheet is a named set of
;; sections, and each section is a list of rows.  A row usually names a
;; command; its key sequence is looked up *live* from the active keymaps
;; when the sheet is displayed, so a guide can never go stale -- rebind
;; the command and the sheet follows.
;;
;; Every registered cheatsheet appears in the "Guides" menu on the menu
;; bar, and can be opened with `cheatsheet-show'.
;;
;; Row forms accepted inside a section:
;;
;;   (COMMAND "description")
;;       Show COMMAND's current binding, looked up in the active keymaps.
;;
;;   (COMMAND "description" :in KEYMAP)
;;       Look the binding up inside KEYMAP, a keymap variable symbol such
;;       as `org-mode-map'.  Use this for mode-local commands.
;;
;;   (COMMAND "description" :then "j")
;;       Show COMMAND's binding followed by the literal keys "j", handy
;;       for a prefix plus a template selector.
;;
;;   (:keys "C-c a" "description")
;;       A literal key string that is not tied to a command.
;;
;;   (:note "free-form text")
;;       A plain descriptive line with no key column.

;;; Code:

(require 'cl-lib)
(require 'init-keys)

(defvar cheatsheet-registry nil
  "Alist mapping a cheatsheet name (a string) to its list of sections.
Entries are kept in definition order.")

;;;; Defining cheatsheets

(defun cheatsheet-define (name &rest sections)
  "Define, or replace, the cheatsheet called NAME (a string).
Each SECTION is a list (TITLE ROW...); see the Commentary for the
accepted row forms.  Registered cheatsheets appear in the Guides menu.
Return NAME."
  (setq cheatsheet-registry
        (append (assoc-delete-all name cheatsheet-registry)
                (list (cons name sections))))
  (cheatsheet--rebuild-menu)
  name)

;;;; Resolving keys, always live

(defun cheatsheet--command-keys (command &optional keymap)
  "Return COMMAND's current key binding as a string.
When KEYMAP, a keymap variable symbol, is non-nil and bound, resolve the
binding within that keymap; otherwise use the active keymaps.  Falls back
to \"M-x COMMAND\" when COMMAND is bound to no key at all."
  (condition-case nil
      (if (and keymap (boundp keymap))
          (substitute-command-keys (format "\\<%s>\\[%s]" keymap command))
        (substitute-command-keys (format "\\[%s]" command)))
    (error (format "M-x %s" command))))

(defun cheatsheet--parse-row (row)
  "Return a plist (:keys STRING :desc STRING) describing ROW."
  (pcase (car row)
    (:note (list :keys nil :desc (nth 1 row)))
    (:keys (list :keys (nth 1 row) :desc (nth 2 row)))
    (command
     (let* ((options (nthcdr 2 row))
            (then (plist-get options :then))
            (keys (cheatsheet--command-keys command (plist-get options :in))))
       (list :keys (if then (concat keys " " then) keys)
             :desc (nth 1 row))))))

;;;; Rendering

(define-derived-mode cheatsheet-mode special-mode "Cheatsheet"
  "Major mode for viewing a cheatsheet.")

(defun cheatsheet--key-column-width (sections)
  "Return the width of the key column across the parsed SECTIONS."
  (apply #'max 0
         (cl-loop for section in sections
                  append (cl-loop for row in (cdr section)
                                  for keys = (plist-get row :keys)
                                  when keys collect (length keys)))))

(defun cheatsheet--insert-row (row width)
  "Insert ROW, with its key column padded to WIDTH."
  (let ((keys (plist-get row :keys))
        (description (plist-get row :desc)))
    (if keys
        (insert (format "  %s   %s\n"
                        (propertize (string-pad keys width)
                                    'face 'help-key-binding)
                        description))
      (insert (format "  %s\n"
                      (propertize (or description "") 'face 'italic))))))

(defun cheatsheet--render (name)
  "Insert the rendered cheatsheet NAME into the current buffer."
  (let* ((sections (mapcar (lambda (section)
                             (cons (car section)
                                   (mapcar #'cheatsheet--parse-row
                                           (cdr section))))
                           (cdr (assoc name cheatsheet-registry))))
         (width (cheatsheet--key-column-width sections)))
    (insert (propertize name 'face '(:height 1.4 :weight bold)) "\n\n")
    (dolist (section sections)
      (insert (propertize (car section) 'face '(:weight bold :underline t))
              "\n")
      (dolist (row (cdr section))
        (cheatsheet--insert-row row width))
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

;;;; The Guides menu

(defvar cheatsheet-menu-map (make-sparse-keymap "Guides")
  "Keymap backing the \"Guides\" menu-bar entry.")

(defun cheatsheet--rebuild-menu ()
  "Rebuild the Guides menu from `cheatsheet-registry'."
  (setq cheatsheet-menu-map (make-sparse-keymap "Guides"))
  ;; Define in reverse so the items display in definition order.
  (dolist (entry (reverse cheatsheet-registry))
    (let ((name (car entry)))
      (define-key cheatsheet-menu-map (vector (intern name))
                  `(menu-item ,name
                              (lambda () (interactive) (cheatsheet-show ,name))))))
  (define-key-after (lookup-key global-map [menu-bar]) [cheatsheet-guides]
    (cons "Guides" cheatsheet-menu-map) 'tools))

(global-set-key (kbd bind/cheatsheet) #'cheatsheet-show)

;;;; The guides

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
    (org-agenda "This week's calendar view"        :then "a")
    (org-agenda "List every TODO across all files" :then "t"))
  '("Dating a heading (inside an Org buffer)"
    (org-schedule  "Schedule the heading at point"   :in org-mode-map)
    (org-deadline  "Give the heading a deadline"     :in org-mode-map)
    (org-todo      "Cycle the TODO state"            :in org-mode-map)
    (org-timestamp "Insert a plain date/time stamp"  :in org-mode-map))
  '("References"
    (init/org-open-reference-with-xref "Jump to the <<target>> at point"
                                       :in org-mode-map)
    (init/org-toggle-reference-popup "Preview it in a popup" :in org-mode-map)
    (:note "Hovering a reference with the mouse previews it too."))
  '("Inside the agenda view"
    (org-agenda-day-view    "Switch to day view"      :in org-agenda-mode-map)
    (org-agenda-week-view   "Switch to week view"     :in org-agenda-mode-map)
    (org-agenda-later       "Move forward in time"    :in org-agenda-mode-map)
    (org-agenda-earlier     "Move backward in time"   :in org-agenda-mode-map)
    (org-agenda-goto-today  "Jump back to today"      :in org-agenda-mode-map)
    (org-agenda-todo        "Change a task's state"   :in org-agenda-mode-map)
    (org-agenda-goto        "Jump to the item's file" :in org-agenda-mode-map)
    (org-agenda-quit        "Close the agenda"        :in org-agenda-mode-map)))

(cheatsheet-define "Coding & LSP"
  '("Navigation"
    (init/ide-goto-definition "Jump to definition"        :in init/ide-mode-map)
    (init/ide-go-back         "Jump back"                 :in init/ide-mode-map)
    (init/ide-hover           "Docs for symbol at point"  :in init/ide-mode-map)
    (init/ide-project-symbols "Search symbols in project" :in init/ide-mode-map))
  '("Fixing code"
    (init/ide-actions     "Offer code actions"          :in init/ide-mode-map)
    (init/ide-fix         "Apply a quick fix"           :in init/ide-mode-map)
    (init/ide-format      "Format the buffer"           :in init/ide-mode-map)
    (init/ide-diagnostics "Show diagnostics"            :in init/ide-mode-map)
    (init/ide-reconnect   "Restart the language server" :in init/ide-mode-map))
  '("Running & testing"
    (init/ide-run           "Run the current program"        :in init/ide-mode-map)
    (init/ide-test-at-point "Run the test at point"          :in init/ide-mode-map)
    (init/ide-test-file     "Run the tests in this file"     :in init/ide-mode-map)
    (init/ide-test-project  "Run the whole project's tests"  :in init/ide-mode-map)
    (init/ide-repl          "Open the language REPL"         :in init/ide-mode-map)
    (init/ide-sync          "Sync project / language server" :in init/ide-mode-map)
    (init/ide-debug         "Start a debugging session (DAP)" :in init/ide-mode-map))
  '("Notes"
    (:note "These work in language buffers (init/ide-mode).")
    (:note "The action taken adapts to the current language.")))

(cheatsheet-define "OCaml"
  '("Dune"
    (init/ocaml-build "Build the project (dune build)" :in tuareg-mode-map)
    (init/ocaml-test  "Run the tests (dune test)"      :in tuareg-mode-map)
    (init/ocaml-debug "Start the debugger"             :in tuareg-mode-map))
  '("REPL"
    (init/ocaml-start-repl "Start or switch to utop"))
  '("Notes"
    (:note "Everything else is the shared IDE keymap;")
    (:note "see the \"Coding & LSP\" guide.")))

(cheatsheet-define "Kotlin & Java"
  '("Gradle"
    (init/jvm-run          "Run the module's run task"       :in init/ide-mode-map)
    (init/jvm-build        "Build, skipping tests"           :in init/ide-mode-map)
    (init/jvm-test-at-point "Run the test around point"      :in init/ide-mode-map)
    (init/jvm-test-file    "Run this file's test class"      :in init/ide-mode-map)
    (init/jvm-test-project "Run every test in the build"     :in init/ide-mode-map)
    (init/jvm-gradle-task  "Run any Gradle task"))
  '("Language servers"
    (init/jvm-install-servers "Install or update the servers")
    (init/ide-reconnect    "Restart the server for this buffer"
                           :in init/ide-mode-map)
    (:note "Kotlin is served by JetBrains' kotlin-lsp, Java by Eclipse JDT LS.")
    (:note "Both install on first use and index in the background."))
  '("Notes"
    (:note "Tasks address the module owning the buffer, so a test")
    (:note "runs alone rather than through the whole build.")
    (:note "Everything else is the shared IDE keymap;")
    (:note "see the \"Coding & LSP\" guide.")))

(cheatsheet-define "Nim"
  '("Documentation"
    (init/nim-doc-search   "Search the stdlib index"  :in nim-mode-map)
    (init/nim-doc-at-point "Docs for the symbol at point" :in nim-mode-map)
    (init/nim-doc-module   "Open a module's page"     :in nim-mode-map)
    (init/nim-doc-home     "Standard library overview" :in nim-mode-map)
    (init/nim-doc-refresh  "Forget the cached docs index"))
  '("Editing"
    (init/nim-mark-token "Mark the token at point" :in nim-mode-map)
    (init/nim-new-test   "Create a new test file"))
  '("Notes"
    (:note "Nim uses nimsuggest, not Eglot, but the shared")
    (:note "IDE keys still apply; see \"Coding & LSP\".")))

(cheatsheet-define "Projects (Projectile)"
  '("Project panel (repo registry)"
    (init/project-panel-toggle "Toggle the panel (also ▦ in the toolbar)")
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
    (init/project-search        "Project search menu")
    (init/project-search-live   "Search live, as you type")
    (init/project-search-buffer "Search into a pinned buffer")
    (projectile-replace         "Replace across the project"))
  '("Run & build (saved per project, toolbar ▶ ⚙ ⇄ ＋)"
    (init/project-run            "Run the project's run command")
    (init/project-build          "Run the project's build command")
    (init/project-command-switch "Switch what run/build executes")
    (init/project-command-add    "Register a new project command")
    (:note "Commands live in .project-commands.eld at the project root.")
    (:note "Output opens in the run/build panel; it accepts program input."))
  '("Build / run / test"
    (projectile-compile-project "Compile the project")
    (projectile-run-project     "Run the project")
    (projectile-test-project    "Test the project"))
  '("Housekeeping"
    (projectile-kill-buffers     "Close all project buffers")
    (projectile-invalidate-cache "Refresh the project file cache"))
  '("Notes"
    (:note "Every command lives under the C-c p (or s-p) prefix.")))

(cheatsheet-define "Treemacs (file tree)"
  '("Open & focus"
    (treemacs                      "Toggle the file tree")
    (treemacs-select-window        "Jump to / focus the tree")
    (treemacs-find-file            "Reveal the current file in the tree")
    (treemacs-delete-other-windows "Maximise the tree window")
    (treemacs-select-directory     "Add a directory to the tree")
    (treemacs-bookmark             "Jump to a bookmarked node"))
  '("Inside the tree"
    (treemacs-TAB-action    "Expand / collapse the node" :in treemacs-mode-map)
    (treemacs-next-line     "Next line"                  :in treemacs-mode-map)
    (treemacs-previous-line "Previous line"              :in treemacs-mode-map)
    (treemacs-visit-node-vertical-split   "Open in a vertical split"
                                          :in treemacs-mode-map)
    (treemacs-visit-node-horizontal-split "Open in a horizontal split"
                                          :in treemacs-mode-map)
    (treemacs-refresh       "Refresh the tree"           :in treemacs-mode-map))
  '("Editing files from the tree"
    (treemacs-create-file "Create a file"            :in treemacs-mode-map)
    (treemacs-create-dir  "Create a directory"       :in treemacs-mode-map)
    (treemacs-rename-file "Rename the node at point" :in treemacs-mode-map)
    (treemacs-delete-file "Delete the node at point" :in treemacs-mode-map)
    (treemacs-toggle-show-dotfiles "Show / hide dotfiles"
                                   :in treemacs-mode-map))
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
    (corfu-next     "Next completion"        :in corfu-map)
    (corfu-previous "Previous completion"    :in corfu-map)
    (corfu-insert   "Insert the selection"   :in corfu-map)
    (corfu-complete "Complete common prefix" :in corfu-map)
    (corfu-info-documentation "Show docs for the candidate" :in corfu-map)
    (corfu-quit     "Dismiss the popup"      :in corfu-map))
  '("Snippets"
    (yas-insert-snippet "Insert a snippet")))

(cheatsheet-define "Editor essentials"
  '("Config"
    (init/reload-config "Reload the whole configuration")
    (cheatsheet-show    "Open a cheatsheet"))
  '("Frame & UI"
    (init/toggle-menu-bar           "Show / hide the menu bar")
    (init/menu-bar-open             "Open the menus from the keyboard")
    (init/doc-toolbar-mode          "Toggle the global toolbar (⚒)")
    (init/toggle-frame-transparency "Toggle frame transparency")
    (init/theme-select              "Preview and pick an installed theme")
    (init/theme-gallery             "Install a theme from EmacsThemes"))
  '("Sessions (also ⧉ in the toolbar)"
    (init/session-menu "Session menu: new / load / save / delete")
    (:note "Sessions auto-save and restore on restart.")
    (:note "Opening a project loads its own session automatically."))
  '("Moving & editing"
    (avy-goto-char      "Jump to a visible character")
    (forward-paragraph  "Move forward a paragraph")
    (backward-paragraph "Move backward a paragraph")
    (repeat             "Repeat the last command"))
  '("Surround: pairs () {} [] <> \"\" '' ``"
    (:keys "M-' s" "Wrap region / symbol with a pair")
    (:keys "M-' c" "Change the closest pair, e.g. ( to [")
    (:keys "M-' d" "Delete the closest pair")
    (:keys "M-' k" "Kill inside the pair (K: pair too)")
    (:keys "M-' i" "Mark inside the pair (o: pair too)")
    (:note "A bare pair key marks within it, e.g. M-' ("))
  '("Bookmarks (fringe click also toggles)"
    (bm-toggle            "Toggle a bookmark on this line")
    (bm-next              "Next bookmark in this file")
    (bm-previous          "Previous bookmark in this file")
    (init/bm-jump-project "Jump to any bookmark in the project")
    (bm-remove-all-current-buffer "Clear this file's bookmarks")
    (:note "Bookmarks persist per file across restarts."))
  '("Run / build panel"
    (compile                 "Run a compile command")
    (init/compilation-toggle "Show / hide the panel")
    (init/compilation-toggle-floating "Float or embed the panel")
    (:note "The panel has its own toolbar: rerun, kill, clear, resize."))
  '("PDFs (toolbar at the top of each PDF)"
    (:keys "n / p"     "Next / previous page")
    (:keys "+ / -"     "Zoom in / out, 0 resets")
    (:keys "W / H / P" "Fit width / height / page")
    (:keys "o"         "Outline (table of contents)")
    (:keys "C-s"       "Search inside the PDF")
    (:note "First PDF open offers to build the epdfinfo helper."))
  '("Web (EWW, toolbar at the top)"
    (eww           "Open a URL or search the web (DuckDuckGo)")
    (ddg           "Search DuckDuckGo (region / symbol at point)")
    (:keys "j"     "Jump to the main content")
    (:keys "R"     "Readable view (article only)")
    (:keys "l / r" "Back / forward")
    (:keys "b / B" "Bookmark page / list bookmarks")
    (:keys "&"     "Open the page in the external browser")))

(provide 'init-cheatsheet)
;;; init-cheatsheet.el ends here
