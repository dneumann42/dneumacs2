;;; nim.el --- Nim language support -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'subr-x)
(require 'compile)
(eval-when-compile (require 'flycheck))
(declare-function flycheck-define-checker "flycheck")
(declare-function flycheck-define-command-checker "flycheck")
(declare-function flycheck-buffer "flycheck")
(declare-function flycheck-error-buffer "flycheck")
(declare-function flycheck-error-< "flycheck")
(declare-function flycheck-error-format "flycheck")
(declare-function flycheck-error-format-position "flycheck")
(declare-function flycheck-error-end-line "flycheck")
(declare-function flycheck-error-level-error-list-face "flycheck")
(declare-function project-root "project")

(defconst init/nim-nimble-bin (expand-file-name "~/.nimble/bin")
  "Directory where nimble installs user binaries.")

(defconst init/nim-local-bin (expand-file-name "bin" user-emacs-directory)
  "Directory for local wrapper scripts used by Nim integration.")

(defun init/nim--nimble-root (&optional dir)
  "Return the nearest Nimble project root above DIR, or nil."
  (locate-dominating-file
   (or dir default-directory)
   (lambda (candidate-dir)
     (cl-some (lambda (name)
                (string-match-p "\\.nimble\\'" name))
              (directory-files candidate-dir nil nil t)))))

(defun init/nim--nimble-file (&optional dir)
  "Return the first Nimble file in DIR's project root, or nil."
  (when-let ((nimble-root (init/nim--nimble-root dir)))
    (car (file-expand-wildcards (expand-file-name "*.nimble" nimble-root)))))

(defun init/nim--nimble-src-root (&optional dir)
  "Return the Nim source root for DIR if it is inside a Nimble project."
  (when-let* ((nimble-root (init/nim--nimble-root dir))
              (src-root (expand-file-name "src" nimble-root)))
    (when (file-directory-p src-root)
      src-root)))

(defun init/nim--project-root ()
  "Return the enclosing project root for the current Nim buffer."
  (or (when (fboundp 'project-current)
        (when-let ((project (project-current nil)))
          (project-root project)))
      default-directory))

(defun init/nim--bootstrap-project-name ()
  "Return a fallback name for a generated Nimble package."
  (let* ((file (or (buffer-file-name) "project"))
         (base (file-name-base file)))
    (if (string= base "") "project" base)))

(defun init/nim--write-file-if-missing (path content)
  "Write CONTENT to PATH if it does not already exist."
  (unless (file-exists-p path)
    (make-directory (file-name-directory path) t)
    (with-temp-file path
      (insert content))))

(defun init/nim--ensure-project-scaffold ()
  "Create minimal Nim project metadata if the project is not scaffolded yet."
  (when-let ((root (init/nim--project-root)))
    (unless (init/nim--nimble-root root)
      (let* ((name (init/nim--bootstrap-project-name))
             (nimble-file (expand-file-name (concat name ".nimble") root))
             (config-file (expand-file-name "config.nims" root))
             (paths-file (expand-file-name "nimble.paths" root)))
        (init/nim--write-file-if-missing
         nimble-file
         (format "# Package\n\nversion       = \"0.0.0\"\nauthor        = \"\"\ndescription   = \"Generated Nim project\"\nlicense       = \"MIT\"\nsrcDir        = \"src\"\nbin           = @[%S]\n\nrequires \"nim >= 2.2.10\"\n"
                 name))
        (init/nim--write-file-if-missing
         config-file
         "when fileExists(\"nimble.paths\"):\n  include \"nimble.paths\"\n")
        (init/nim--write-file-if-missing
         paths-file
         (format "--path:\"%s\"\n" (expand-file-name "src" root)))))))

(defun init/nim--ensure-nimble-path ()
  "Make nimble-installed tools visible to Emacs."
  (dolist (dir (list init/nim-nimble-bin init/nim-local-bin))
    (when (file-directory-p dir)
      (add-to-list 'exec-path dir)
      (let ((paths (split-string (or (getenv "PATH") "") path-separator t)))
        (unless (member dir paths)
          (setenv "PATH"
                  (mapconcat #'identity
                             (cons dir paths)
                             path-separator)))))))

(init/nim--ensure-nimble-path)

(require 'nim-suggest)

(require 'ansi-color)

(defun init/nim--colorize-compilation-output ()
  "Render ANSI color escape sequences in compilation buffers."
  (let ((inhibit-read-only t))
    (ansi-color-apply-on-region compilation-filter-start (point))))

(add-hook 'compilation-filter-hook #'init/nim--colorize-compilation-output)

(defconst init/nim-hover-buffer-name "*Nim hover*"
  "Name of the buffer used for Nim hover popups.")

(defconst init/nim-hover-background "#2b2b2b"
  "Background color for Nim hover popups.")

(defvar-local init/nim--hover-point nil
  "Point where the Nim hover popup was shown.")

(defvar-local init/nim--hover-source-buffer nil
  "Source buffer that owns the Nim hover popup.")

(defun init/nim--show-hover-buffer (content)
  "Display CONTENT in a wrapped popup near point."
  (save-selected-window
    (save-excursion
      (init/nim--hide-hover-buffer)
      (setq-local init/nim--hover-point (point))
      (setq-local init/nim--hover-source-buffer (current-buffer))
      (let ((buffer (get-buffer-create init/nim-hover-buffer-name)))
        (with-current-buffer buffer
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert content)
            (goto-char (point-min))
            (help-mode)
            (setq-local truncate-lines nil)
            (setq-local word-wrap t)
            (setq-local cursor-type nil)
            (setq-local buffer-read-only t)
            (visual-line-mode 1)))
        (cond
         ((fboundp 'posframe-show)
          (require 'posframe)
          (posframe-show
           buffer
           :poshandler 'posframe-poshandler-point-bottom-left-corner
           :max-width (max 60 (min 120 (floor (* (frame-width) 0.45))))
           :max-height 18
           :background-color init/nim-hover-background
           :cursor nil
           :accept-focus nil
           :internal-border-width 1
           :hidehandler #'init/nim--hover-hidehandler
           :override-parameters '((no-other-window . t)
                                   (no-delete-other-windows . t))))
         (t
          (let ((window (display-buffer
                         buffer
                         '((display-buffer-in-side-window)
                           (side . bottom)
                           (slot . 0)
                           (window-parameters . ((no-delete-other-windows . t)
                                                 (no-other-window . t)))))))
            (when (window-live-p window)
              (fit-window-to-buffer window 12)
              window))))))))

(defun init/nim--hover-hidehandler (info)
  "Hide the Nim hover when point or buffer changes."
  (when-let* ((parent (cdr (plist-get info :posframe-parent-buffer))))
    (when (buffer-live-p parent)
      (let ((source-buffer (buffer-local-value 'init/nim--hover-source-buffer parent))
            (source-point (buffer-local-value 'init/nim--hover-point parent)))
        (or (not (buffer-live-p source-buffer))
            (not (eq (current-buffer) source-buffer))
            (/= (point) source-point))))))

(defun init/nim--diagnostics-at-point ()
  "Return Flycheck diagnostics at point, sorted by severity."
  (when (and (bound-and-true-p flycheck-mode)
             (fboundp 'flycheck-overlay-errors-at))
    (let ((errors (flycheck-overlay-errors-at (point))))
      (when errors
        (sort (copy-sequence errors) #'flycheck-error-<)))))

(defun init/nim--format-diagnostics-at-point (errors)
  "Format ERRORS for wrapped display."
  (concat
   (propertize "Diagnostics at point\n" 'face 'bold)
   "\n"
   (string-join (mapcar #'init/nim--format-diagnostic-entry errors)
                "\n")))

(defun init/nim--format-diagnostic-entry (err)
  "Format ERR as a colored diagnostic block."
  (let* ((level (flycheck-error-level err))
         (severity (upcase (symbol-name level)))
         (severity-face (flycheck-error-level-error-list-face level))
         (position (flycheck-error-format-position err))
         (filename (flycheck-error-filename err))
         (message (or (flycheck-error-message err) "Unknown diagnostic"))
         (checker (flycheck-error-checker err))
         (location (if filename
                       (format "%s:%s" (file-relative-name filename) position)
                     position))
         (snippet (init/nim--error-snippet err))
         (highlighted-snippet (and snippet (init/nim--fontify-nim-text snippet))))
    (concat
     (propertize severity 'face severity-face)
     (propertize (format "  %s\n" location) 'face 'shadow)
     (propertize (format "%s\n" message) 'face 'default)
     (propertize (format "(%s)\n" checker) 'face 'shadow)
     (when highlighted-snippet
       (concat (propertize "code\n" 'face 'shadow)
               highlighted-snippet
               "\n")))))

(defun init/nim--error-snippet (err)
  "Return the source snippet for ERR, or nil."
  (when-let ((buffer (flycheck-error-buffer err)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (save-excursion
          (save-restriction
            (widen)
            (let* ((line (max 1 (or (flycheck-error-line err) 1)))
                   (end-line (max line (or (flycheck-error-end-line err) line)))
                   (start (progn
                            (goto-char (point-min))
                            (forward-line (1- line))
                            (line-beginning-position)))
                   (end (progn
                          (goto-char (point-min))
                          (forward-line (1- end-line))
                          (line-end-position))))
              (string-trim-right
               (buffer-substring-no-properties start end)))))))))

(defun init/nim--fontify-nim-text (text)
  "Return TEXT with Nim font-lock faces applied."
  (with-temp-buffer
    (insert text)
    (goto-char (point-min))
    (nim-mode)
    (font-lock-ensure)
    (buffer-substring (point-min) (point-max))))

(defun init/nim--project-search-paths (&optional dir)
  "Return likely search paths for a Nim project under DIR."
  (when-let ((root (init/nim--nimble-root dir)))
    (delete-dups
     (delq nil
           (list (let ((src (expand-file-name "src" root)))
                   (and (file-directory-p src) src))
                 root
                 (let ((lib (expand-file-name "lib" root)))
                   (and (file-directory-p lib) lib))
                 (let ((tests (expand-file-name "tests" root)))
                   (and (file-directory-p tests) tests))
                 (let ((examples (expand-file-name "examples" root)))
                   (and (file-directory-p examples) examples)))))))

(defun init/nim--nimsuggest-local-options (&optional dir)
  "Return buffer-local nimsuggest options for project under DIR."
  (mapcar (lambda (path) (concat "--path:" path))
          (init/nim--project-search-paths dir)))

(defun init/nim--flycheck-working-directory (_checker)
  "Return the directory Flycheck should use for Nim commands."
  (or (init/nim--nimble-root) (init/nim--project-root)))

(defun init/nim--flycheck-buffer-after-save ()
  "Refresh Nim diagnostics after the current buffer is saved."
  (when (and (derived-mode-p 'nim-mode)
             (bound-and-true-p flycheck-mode))
    (flycheck-buffer)))

(defun init/nim-hover-doc ()
  "Show documentation for symbol at point."
  (interactive)
  (cond
   ((fboundp 'nimsuggest-show-doc)
    (condition-case err
        (nimsuggest-show-doc)
      (error
       (message "%s" (error-message-string err)))))
   ((fboundp 'eldoc-print-current-symbol-info)
    (eldoc-print-current-symbol-info))
   (t
    (message "No hover documentation command available."))))

(defun init/nim-hover-diagnostics ()
  "Show diagnostics at point in a wrapped hover window."
  (interactive)
  (if-let ((errors (init/nim--diagnostics-at-point)))
      (init/nim--show-diagnostic-hover errors)
    (init/nim-hover-doc)))

(defun init/nim--show-diagnostic-hover (errors)
  "Display ERRORS in the Nim hover popup."
  (init/nim--show-hover-buffer
   (init/nim--format-diagnostics-at-point errors)))

(defun init/nim-goto-definition ()
  "Jump to the definition at point with the most reliable backend available."
  (interactive)
  (cond
   ((and (fboundp 'nimsuggest-find-definition)
         (bound-and-true-p nimsuggest-mode))
    (call-interactively #'nimsuggest-find-definition))
   ((fboundp 'xref-find-definitions)
    (call-interactively #'xref-find-definitions))
   (t
    (message "No definition backend available."))))

(defun init/nim-symbol-actions ()
  "Offer Nim navigation and documentation actions at point."
  (interactive)
  (pcase (completing-read
          "Nim action: "
          '("Definition" "References" "Documentation")
          nil t)
    ("Definition" (call-interactively #'init/nim-goto-definition))
    ("References" (condition-case err
                      (call-interactively #'xref-find-references)
                    (error (message "%s" (error-message-string err)))))
    ("Documentation" (call-interactively #'init/nim-hover-doc))))

(defun init/nim-show-diagnostics ()
  "Show diagnostics at point, preferring popup UI."
  (interactive)
  (if-let ((errors (init/nim--diagnostics-at-point)))
      (init/nim--show-diagnostic-hover errors)
    (if (fboundp 'flycheck-list-errors)
        (flycheck-list-errors)
      (message "No diagnostics UI available."))))

(defun init/nim-project-root ()
  "Return the current Nim project root, or `default-directory'."
  (or (init/nim--nimble-root)
      (init/nim--project-root)))

(defun init/nim--project-main-file (&optional dir)
  "Return the best Nim project entry point for DIR."
  (when-let* ((nimble-root (init/nim--nimble-root dir))
              (nimble-file (init/nim--nimble-file dir))
              (package-name (file-name-base nimble-file)))
    (cl-some (lambda (path)
               (when (and path (file-exists-p path))
                 path))
             (list
              (expand-file-name (concat package-name ".nim") nimble-root)
              (expand-file-name (concat "src/" package-name ".nim") nimble-root)
              (car (file-expand-wildcards (expand-file-name "*.nim" nimble-root)))
              (car (file-expand-wildcards (expand-file-name "src/*.nim" nimble-root)))))))

(defun init/nim--flycheck-source-file ()
  "Return the file Flycheck should compile for Nim diagnostics."
  (or (init/nim--project-main-file)
      buffer-file-name))

(defun init/nim--warn-if-missing-tools ()
  "Warn when core Nim tools are not available."
  (unless (executable-find "nim")
    (display-warning 'nim "nim not found in PATH; diagnostics and run commands will fail" :warning))
  (unless (executable-find "nimsuggest")
    (display-warning 'nim "nimsuggest not found in PATH; definition and hover will be limited" :warning)))

(defun init/nim--enable-nimsuggest ()
  "Enable nimsuggest when the binary is available."
  (setq-local nimsuggest-local-options (init/nim--nimsuggest-local-options))
  (when (and (fboundp 'nimsuggest-available-p)
             (nimsuggest-available-p))
    (nimsuggest-mode 1)))

(defun init/nim--hide-hover-buffer ()
  "Hide the Nim hover popup if it is visible."
  (setq init/nim--hover-point nil)
  (setq init/nim--hover-source-buffer nil)
  (if (fboundp 'posframe-hide)
      (progn
        (require 'posframe)
        (posframe-hide init/nim-hover-buffer-name))
    (let ((window (get-buffer-window init/nim-hover-buffer-name)))
      (when (window-live-p window)
        (quit-window nil window)))))

(defun init/nim-run ()
  "Save and run `nimble run' from the project root."
  (interactive)
  (save-buffer)
  (let ((default-directory (init/nim-project-root)))
    (compile "nimble run")))

(defun init/nim-setup ()
  "Set up Nim editing, diagnostics and navigation in current buffer."
  (init/nim--ensure-project-scaffold)
  (init/nim--warn-if-missing-tools)
  (setq-local flycheck-checker 'nim-check)
  (setq-local flycheck-check-syntax-automatically '(save mode-enabled))
  (when (bound-and-true-p flymake-mode)
    (flymake-mode -1))
  (when (fboundp 'flycheck-mode)
    (flycheck-mode 1))
  (add-hook 'after-save-hook #'init/nim--flycheck-buffer-after-save nil t)
  (when (bound-and-true-p flycheck-posframe-mode)
    (flycheck-posframe-mode -1))
  (setq-local flycheck-display-errors-function #'init/nim--show-diagnostic-hover)
  (setq-local flycheck-clear-displayed-errors-function #'init/nim--hide-hover-buffer)
  (init/nim--enable-nimsuggest)
  (local-set-key (kbd "C-c k") #'init/nim-hover-diagnostics)
  (local-set-key (kbd "C-c l d") #'init/nim-show-diagnostics)
  (local-set-key (kbd "C-c l a") #'init/nim-symbol-actions)
  (local-set-key (kbd "<f5>") #'init/nim-run)
  (local-set-key (kbd "M-RET") #'init/nim-symbol-actions)
  (local-set-key (kbd "M-.") #'init/nim-goto-definition)
  (local-set-key (kbd "M-,") #'xref-go-back))

(use-package nim-mode
  :mode ("\\.nim\\'" "\\.nims\\'" "\\.nimble\\'")
  :hook (nim-mode . init/nim-setup))

(use-package flycheck
  :defer t
  :commands (flycheck-mode flycheck-list-errors)
  :config
  (flycheck-define-checker nim-check
    "Check Nim source with a compile-only Nimble build."
    :command ("nimble" "--accept" "c"
              "--compileOnly"
              "--colors:off"
              "--listFullPaths:on"
              "--hints:off"
              "--nimcache:build/nimcache/flycheck"
              (eval (init/nim--flycheck-source-file)))
    :error-patterns
    ((error line-start (optional " Nim Output ") (file-name) "(" line ", " column ") Error: " (message) line-end)
     (warning line-start (optional " Nim Output ") (file-name) "(" line ", " column ") Warning: " (message) line-end))
    :modes (nim-mode)
    :working-directory init/nim--flycheck-working-directory))

(use-package flycheck-posframe
  :after flycheck
  :hook (flycheck-mode . flycheck-posframe-mode)
  :custom
  (flycheck-posframe-position 'point-bottom-left-corner))

(defun init/nim-new-test ()
  "Create a new test file in the current Nimble project.
Ensures tests/ directory and config.nims exist, then opens the new file."
  (interactive)
  (let* ((root (init/nim-project-root))
         (tests-dir (expand-file-name "tests" root))
         (config-nims (expand-file-name "config.nims" tests-dir))
         (name (read-string "Test name: " "test"))
         (file (expand-file-name (concat name ".nim") tests-dir)))
    (make-directory tests-dir t)
    (unless (file-exists-p config-nims)
      (with-temp-file config-nims
        (insert "--path:\"../src\"\n")))
    (unless (file-exists-p file)
      (with-temp-file file
        (insert (format "import unittest\n\n\nsuite \"%s\":\n\n  test \"\":\n    check true\n" name))))
    (find-file file)))

(provide 'nim)
;;; nim.el ends here
