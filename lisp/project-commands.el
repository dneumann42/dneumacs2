;;; project-commands.el --- Per-project run/build commands -*- lexical-binding: t; -*-

;;; Commentary:

;; Remembered run/build commands per project, driven from the global
;; toolbar (▶ ⚙ ⇄ ＋) or the F-key row:
;;
;;   <f2>  run    — execute the project's run command
;;   <f3>  build  — execute the project's build command
;;   <f4>  switch — choose which command run or build executes
;;   <f8>  add    — register a new command (optionally assign it)
;;
;; Commands are stored in .project-commands.eld at the project root (a
;; readable lisp-data file that can be committed).  Run and build always
;; execute their last assigned command without prompting; the first use
;; walks you through picking one.
;;
;; Execution goes through the standard compile flow: output lands in
;; the floating *compilation* child frame, but started in comint mode
;; so interactive command-line programs accept keyboard input.  The
;; panel carries its own toolbar: run/build/switch, rerun, kill,
;; clear, error navigation, focus-for-input and dismiss.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'toolbar)

(declare-function init/project-root "project-tools")
(declare-function init/compilation-dismiss "editor")
(declare-function init/compilation--restore-focus "editor")
(declare-function comint-clear-buffer "comint")
(declare-function compilation-start "compile")
(defvar compilation-arguments)

(defconst init/project-commands-file-name ".project-commands.eld"
  "Name of the per-project command metadata file.")

;;;; Metadata file

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
  "Write DATA (an alist) to the project's metadata file."
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
  "Add COMMAND to the project's command list if it is new."
  (let ((commands (init/project-commands--list)))
    (unless (member command commands)
      (init/project-commands--set 'commands (append commands (list command))))))

;;;; Commands

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
SLOT is `run' or `build'; prompted for when nil.  Entering a command
that is not in the list registers it too.  Returns the chosen command."
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
  "Return SLOT's assigned command, asking to pick one when unset."
  (or (init/project-commands--get slot)
      (init/project-command-switch slot)))

(defun init/project-commands--execute (command)
  "Run COMMAND from the project root in the floating comint panel."
  (require 'compile)
  (let ((default-directory (init/project-root)))
    ;; MODE t = comint buffer with compilation-shell-minor-mode, so
    ;; interactive programs accept input; errors stay clickable.
    (compilation-start command t))
  ;; Keep focus in the editing frame, like the plain compile flow.
  (when (fboundp 'init/compilation--restore-focus)
    (init/compilation--restore-focus)))

(defun init/project-run ()
  "Execute the project's run command in the floating panel."
  (interactive)
  (init/project-commands--execute (init/project-commands--ensure 'run)))

(defun init/project-build ()
  "Execute the project's build command in the floating panel."
  (interactive)
  (init/project-commands--execute (init/project-commands--ensure 'build)))

;;;; Panel helpers

(defun init/project-commands-focus-panel ()
  "Focus the run/build panel so keyboard input reaches the program."
  (interactive)
  (let* ((buffer (get-buffer "*compilation*"))
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
`comint-clear-buffer' truncates relative to the process mark, so it
only works while the process is alive; otherwise erase directly."
  (interactive)
  (if (and (derived-mode-p 'comint-mode)
           (process-live-p (get-buffer-process (current-buffer))))
      (comint-clear-buffer)
    (let ((inhibit-read-only t))
      (erase-buffer))))

;;;; Panel toolbar

(defun init/project-commands--panel-status ()
  "Return the command and process state for the panel toolbar."
  (let* ((process (get-buffer-process (current-buffer)))
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
   '("⌨" "Focus the panel to type program input" init/project-commands-focus-panel)
   '("⮌" "Back to the editor" init/project-commands-unfocus-panel)
   '("✕" "Dismiss the panel" init/compilation-dismiss)
   :sep
   #'init/project-commands--panel-status))

(defun init/project-commands--attach-panel-toolbar ()
  "Attach the panel toolbar to *compilation* buffers."
  (when (string-match-p "\\*compilation\\*" (buffer-name))
    (init/toolbar-attach #'init/project-commands--panel-toolbar)))

(add-hook 'compilation-mode-hook
          #'init/project-commands--attach-panel-toolbar)
(add-hook 'compilation-shell-minor-mode-hook
          #'init/project-commands--attach-panel-toolbar)

;;;; Keybindings

(global-set-key (kbd bind/project-run) #'init/project-run)
(global-set-key (kbd bind/project-build) #'init/project-build)
(global-set-key (kbd bind/project-command-switch) #'init/project-command-switch)
(global-set-key (kbd bind/project-command-add) #'init/project-command-add)

(provide 'project-commands)
;;; project-commands.el ends here
