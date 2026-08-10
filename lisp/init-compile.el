;;; init-compile.el --- The run/build panel and project commands -*- lexical-binding: t; -*-

;;; Commentary:

;; Compilation output is shown in a single dedicated panel, either a
;; floating child frame at the top right of the frame or an embedded
;; window across the bottom (`init/compilation-toggle-floating' switches
;; between the two).  The panel carries its own toolbar: run, build,
;; switch, rerun, kill, clear, error navigation, resize, float/embed,
;; focus-for-input and dismiss.
;;
;; On top of that sit remembered run and build commands per project,
;; driven from the global toolbar (▶ ⚙ ⇄ ＋) or the F-key row:
;;
;;   <f2>  run    — execute the project's run command
;;   <f3>  build  — execute the project's build command
;;   <f4>  switch — choose which command run or build executes
;;   <f8>  add    — register a new command (optionally assign it)
;;
;; The commands are stored in .project-commands.eld at the project root,
;; a readable lisp-data file that can be committed.  Run and build always
;; execute their last assigned command without prompting; the first use
;; walks you through picking one.  Execution goes through
;; `compilation-start' in comint mode, so interactive command-line
;; programs accept keyboard input while errors stay clickable.

;;; Code:

(require 'ansi-color)
(require 'compile)
(require 'subr-x)
(require 'init-keys)
(require 'init-lib)
(require 'init-toolbar)

(declare-function comint-clear-buffer "comint")

;;;; Panel configuration

(defconst init/compilation-buffer-name "*compilation*"
  "Name of the run/build panel buffer.")

(defcustom init/compilation-floating t
  "Non-nil shows the run/build panel as a floating child frame.
When nil, the panel is embedded as a bottom window in the editing frame.
Toggle at runtime with `init/compilation-toggle-floating'."
  :type 'boolean
  :group 'convenience)

(defvar init/compilation-frame nil
  "The live child frame displaying the compilation buffer, or nil.")

(defvar init/compilation-frame-width 80
  "Width, in columns, of the floating run/build panel.")

(defvar init/compilation-frame-height 20
  "Height, in lines, of the floating run/build panel.")

(defvar init/compilation-window-height 15
  "Height, in lines, of the embedded run/build panel window.")

;; Follow output to the bottom as it arrives, and render the ANSI colour
;; escapes that most build tools emit.
(setq compilation-scroll-output t)

(defun init/compilation--colorize-output ()
  "Render ANSI colour escape sequences in the compilation buffer."
  (let ((inhibit-read-only t))
    (ansi-color-apply-on-region compilation-filter-start (point))))

(add-hook 'compilation-filter-hook #'init/compilation--colorize-output)

;;;; Displaying the panel

(defun init/display-compilation-in-child-frame (buffer _alist)
  "Display BUFFER in a resizable child frame at the frame's top right.
_ALIST is accepted for `display-buffer' protocol compatibility."
  (condition-case err
      (progn
        (when (frame-live-p init/compilation-frame)
          (delete-frame init/compilation-frame))
        (let* ((parent (selected-frame))
               (width (* init/compilation-frame-width (frame-char-width parent)))
               (left (max 0 (- (frame-pixel-width parent) width 20)))
               (frame (make-frame
                       `((parent-frame . ,parent)
                         (width . ,init/compilation-frame-width)
                         (height . ,init/compilation-frame-height)
                         (top . 10)
                         (left . ,left)
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
  "Display BUFFER as a bottom window spanning the editing frame.
ALIST is the `display-buffer' action alist to extend."
  (display-buffer-in-side-window
   buffer
   (append alist
           `((side . bottom)
             (slot . 0)
             (window-height . ,init/compilation-window-height)
             (window-parameters . ((no-delete-other-windows . t)))))))

(defun init/compilation--display (buffer alist)
  "Route the run/build BUFFER to the floating or embedded panel.
ALIST is the `display-buffer' action alist."
  (if init/compilation-floating
      (init/display-compilation-in-child-frame buffer alist)
    (init/display-compilation-in-side-window buffer alist)))

(add-to-list 'display-buffer-alist
             `(,(regexp-quote init/compilation-buffer-name)
               (init/compilation--display)))

;;;; Panel state

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

;;;; Panel commands

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
the bottom window when embedded -- and moves point to the end, so comint
input and the latest output are in view."
  (interactive)
  (let ((window (if (frame-live-p init/compilation-frame)
                    (progn
                      (select-frame-set-input-focus init/compilation-frame)
                      (frame-root-window init/compilation-frame))
                  (init/compilation--side-window))))
    (when (window-live-p window)
      (select-window window)
      (goto-char (point-max)))))

(defun init/compilation--focus-after (&rest _)
  "Reveal and focus the run/build panel after a compilation starts.
Advises `compile', so <f5> and the language run commands focus the panel;
`init/project-commands--execute' calls `init/compilation-focus' directly
for the run/build comint flow."
  (init/compilation-focus))

(advice-add 'compile :after #'init/compilation--focus-after)

(defun init/compilation-toggle ()
  "Toggle the run/build panel on and off, focusing it when shown.
Starts a new compilation when no compilation buffer exists yet."
  (interactive)
  (cond
   ((init/compilation--visible-p) (init/compilation-dismiss))
   ((init/compilation--buffer)
    (init/compilation--show)
    (init/compilation-focus))
   (t (call-interactively #'compile))))

(defun init/compilation-toggle-floating ()
  "Switch the run/build panel between a floating frame and an embedded split.
Keeps the panel, and any running process, visible across the switch."
  (interactive)
  (let ((was-visible (init/compilation--visible-p)))
    (init/compilation-dismiss)
    (setq init/compilation-floating (not init/compilation-floating))
    (when (and was-visible (init/compilation--buffer))
      (init/compilation--show))
    (message "Run panel: %s"
             (if init/compilation-floating "floating" "embedded"))))

(defun init/compilation--resize-frame (delta)
  "Grow (DELTA > 0) or shrink the floating run/build panel by DELTA lines."
  (unless (frame-live-p init/compilation-frame)
    (user-error "No floating run panel is open"))
  (setq init/compilation-frame-height
        (max 6 (+ init/compilation-frame-height delta)))
  (set-frame-height init/compilation-frame init/compilation-frame-height))

(defun init/compilation--resize-window (delta)
  "Grow (DELTA > 0) or shrink the embedded run/build panel by DELTA lines."
  (let ((window (init/compilation--side-window)))
    (unless (window-live-p window)
      (user-error "No embedded run panel is open"))
    (condition-case err
        (progn
          (window-resize window delta nil)
          (setq init/compilation-window-height (window-height window)))
      (error (user-error "%s" (error-message-string err))))))

(defun init/compilation--resize (delta)
  "Resize whichever run/build panel is open by DELTA lines."
  (if init/compilation-floating
      (init/compilation--resize-frame delta)
    (init/compilation--resize-window delta)))

(defun init/compilation-enlarge ()
  "Make the run/build panel taller."
  (interactive)
  (init/compilation--resize 4))

(defun init/compilation-shrink ()
  "Make the run/build panel shorter."
  (interactive)
  (init/compilation--resize -4))

(with-eval-after-load 'compile
  (define-key compilation-mode-map (kbd "q") #'init/compilation-dismiss))

;;;; Per-project command metadata

(defconst init/project-commands-file-name ".project-commands.eld"
  "Name of the per-project command metadata file.")

(defun init/project-commands--file ()
  "Return the metadata file path for the current project."
  (expand-file-name init/project-commands-file-name (init/project-root)))

(defun init/project-commands--read ()
  "Return the project's command metadata alist, or nil."
  (let ((file (init/project-commands--file)))
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (condition-case nil
            (read (current-buffer))
          (error nil))))))

(defun init/project-commands--write (data)
  "Write DATA, an alist, to the project's metadata file."
  (with-temp-file (init/project-commands--file)
    (insert ";;; -*- lisp-data -*-\n")
    (pp data (current-buffer))))

(defun init/project-commands--get (key)
  "Return the value stored under KEY for the current project."
  (cdr (assq key (init/project-commands--read))))

(defun init/project-commands--set (key value)
  "Store VALUE under KEY in the current project's metadata."
  (let ((data (assq-delete-all key (init/project-commands--read))))
    (init/project-commands--write (cons (cons key value) data))))

(defun init/project-commands--list ()
  "Return the project's registered commands."
  (init/project-commands--get 'commands))

(defun init/project-commands--register (command)
  "Add COMMAND to the project's command list if it is not there yet."
  (let ((commands (init/project-commands--list)))
    (unless (member command commands)
      (init/project-commands--set 'commands (append commands (list command))))))

;;;; Project run and build commands

(defun init/project-command-add (command)
  "Register COMMAND for this project and optionally assign it.
Prompts whether the new command becomes the run command, the build
command, or just joins the list."
  (interactive (list (read-string "Add project command: ")))
  (let ((command (string-trim command)))
    (when (string-empty-p command)
      (user-error "Command must not be empty"))
    (init/project-commands--register command)
    (pcase (completing-read (format "Assign %S to: " command)
                            '("run" "build" "none") nil t)
      ("run" (init/project-commands--set 'run command)
       (message "run (▶ / %s) now executes: %s" bind/project-run command))
      ("build" (init/project-commands--set 'build command)
       (message "build (⚙ / %s) now executes: %s" bind/project-build command))
      (_ (message "Added %s" command)))
    command))

(defun init/project-command-switch (&optional slot)
  "Change which registered command run or build executes.
SLOT is `run' or `build', and is prompted for when nil.  Entering a
command that is not in the list registers it too.  Return the chosen
command."
  (interactive)
  (let* ((slot (or slot
                   (intern (completing-read "Switch command for: "
                                            '("run" "build") nil t))))
         (current (init/project-commands--get slot))
         (choice (string-trim
                  (completing-read
                   (format "%s command%s: "
                           (capitalize (symbol-name slot))
                           (if current (format " (now: %s)" current) ""))
                   (init/project-commands--list)))))
    (when (string-empty-p choice)
      (user-error "No command chosen"))
    (init/project-commands--register choice)
    (init/project-commands--set slot choice)
    (message "%s now executes: %s" slot choice)
    choice))

(defun init/project-commands--ensure (slot)
  "Return SLOT's assigned command, asking to pick one when it is unset."
  (or (init/project-commands--get slot)
      (init/project-command-switch slot)))

(defun init/project-commands--execute (command)
  "Run COMMAND from the project root in the run/build panel."
  (let ((default-directory (init/project-root)))
    ;; MODE t means a comint buffer with `compilation-shell-minor-mode',
    ;; so interactive programs accept input and errors stay clickable.
    (compilation-start command t))
  ;; Reveal and focus the panel so keyboard input reaches the program.
  (init/compilation-focus))

(defun init/project-run ()
  "Execute the project's run command in the run/build panel."
  (interactive)
  (init/project-commands--execute (init/project-commands--ensure 'run)))

(defun init/project-build ()
  "Execute the project's build command in the run/build panel."
  (interactive)
  (init/project-commands--execute (init/project-commands--ensure 'build)))

;;;; Panel input helpers

(defun init/project-commands-focus-panel ()
  "Focus the run/build panel so keyboard input reaches the program."
  (interactive)
  (let* ((buffer (init/compilation--buffer))
         (window (and buffer (get-buffer-window buffer t))))
    (unless window
      (user-error "No run/build panel is open"))
    (select-frame-set-input-focus (window-frame window))
    (select-window window)
    (goto-char (point-max))))

(defun init/project-commands-unfocus-panel ()
  "Return focus from the panel to the editing frame."
  (interactive)
  (if-let ((parent (frame-parent (selected-frame))))
      (select-frame-set-input-focus parent)
    (other-window 1)))

(defun init/project-commands-clear-panel ()
  "Erase the panel's output.
`comint-clear-buffer' truncates relative to the process mark, so it only
works while the process is alive; otherwise erase the buffer directly."
  (interactive)
  (if (and (derived-mode-p 'comint-mode)
           (process-live-p (get-buffer-process (current-buffer))))
      (comint-clear-buffer)
    (let ((inhibit-read-only t))
      (erase-buffer))))

;;;; Panel toolbar

(defun init/project-commands--panel-status ()
  "Return the command and process state segment for the panel toolbar."
  (let ((process (get-buffer-process (current-buffer)))
        (command (car-safe (bound-and-true-p compilation-arguments))))
    (init/toolbar-info
     (concat (if process "● " "■ ")
             (truncate-string-to-width (or command "") 40 nil nil "…"))
     (if process "Process running" "Process finished"))))

(defun init/project-commands--panel-toolbar ()
  "Build the toolbar shown on the run/build panel."
  (init/toolbar-string
   '("▶" "Run the project's run command" init/project-run)
   '("⚙" "Run the project's build command" init/project-build)
   '("⇄" "Switch what run/build executes" init/project-command-switch)
   :sep
   '("⟳" "Rerun this command" recompile)
   '("⏹" "Kill the running process" kill-compilation)
   '("⌫" "Clear the output" init/project-commands-clear-panel)
   :sep
   '("↓" "Next error" compilation-next-error)
   '("↑" "Previous error" compilation-previous-error)
   :sep
   '("⤢" "Make the panel taller" init/compilation-enlarge)
   '("⤡" "Make the panel shorter" init/compilation-shrink)
   '("⧉" "Toggle floating / embedded panel" init/compilation-toggle-floating)
   :sep
   '("⌨" "Focus the panel to type program input" init/project-commands-focus-panel)
   '("⮌" "Back to the editor" init/project-commands-unfocus-panel)
   '("✕" "Dismiss the panel" init/compilation-dismiss)
   :sep
   #'init/project-commands--panel-status))

(defun init/project-commands--attach-panel-toolbar ()
  "Attach the panel toolbar to the run/build panel buffer."
  (when (string-prefix-p init/compilation-buffer-name (buffer-name))
    (init/toolbar-attach #'init/project-commands--panel-toolbar)))

(add-hook 'compilation-mode-hook #'init/project-commands--attach-panel-toolbar)
(add-hook 'compilation-shell-minor-mode-hook
          #'init/project-commands--attach-panel-toolbar)

;;;; Keybindings

(global-set-key (kbd bind/compile) #'compile)
(global-set-key (kbd bind/compilation-toggle) #'init/compilation-toggle)
(global-set-key (kbd bind/compilation-toggle-fkey) #'init/compilation-toggle)
(global-set-key (kbd bind/project-run) #'init/project-run)
(global-set-key (kbd bind/project-build) #'init/project-build)
(global-set-key (kbd bind/project-command-switch) #'init/project-command-switch)
(global-set-key (kbd bind/project-command-add) #'init/project-command-add)

(provide 'init-compile)
;;; init-compile.el ends here
