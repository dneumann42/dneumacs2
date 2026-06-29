;;; init-python.el --- Python and uv development support -*- lexical-binding: t; -*-

(require 'compile)
(require 'flymake)
(require 'project)
(require 'python)
(require 'subr-x)
(require 'which-func)

(declare-function eglot-code-actions "eglot")
(declare-function eglot-ensure "eglot")
(declare-function eglot-help-at-point "eglot")
(declare-function eglot-reconnect "eglot")
(declare-function flycheck-list-errors "flycheck")
(declare-function flycheck-mode "flycheck")

(defgroup init/python nil
  "Python development with uv."
  :group 'languages)

(defcustom init/python-uv-command "uv"
  "Command used to run uv."
  :type 'string
  :group 'init/python)

(defcustom init/python-language-server "basedpyright-langserver"
  "Language server executable installed in the uv environment."
  :type 'string
  :group 'init/python)

(defun init/python-project-root ()
  "Return the current Python project root."
  (or (when-let ((file (or buffer-file-name default-directory)))
        (locate-dominating-file file
                                (lambda (dir)
                                  (or (file-exists-p (expand-file-name "uv.lock" dir))
                                      (file-exists-p (expand-file-name "pyproject.toml" dir))))))
      (when-let ((project (project-current nil)))
        (project-root project))
      default-directory))

(defun init/python--uv-command (&rest arguments)
  "Build a shell command that runs uv with ARGUMENTS."
  (mapconcat #'shell-quote-argument
             (cons init/python-uv-command arguments)
             " "))

(defun init/python--compile (&rest arguments)
  "Run uv with ARGUMENTS from the Python project root."
  (let ((default-directory (init/python-project-root)))
    (compile (apply #'init/python--uv-command arguments))))

(defun init/python-sync ()
  "Synchronize the current project's uv environment."
  (interactive)
  (init/python--compile "sync"))

(defun init/python-run-file ()
  "Save and run the current Python file through uv."
  (interactive)
  (save-buffer)
  (init/python--compile "run" "python" (file-relative-name buffer-file-name
                                                            (init/python-project-root))))

(defun init/python-test-project ()
  "Run the complete pytest suite through uv."
  (interactive)
  (init/python--compile "run" "pytest"))

(defun init/python-test-file ()
  "Run pytest for the current file through uv."
  (interactive)
  (save-buffer)
  (init/python--compile "run" "pytest"
                        (file-relative-name buffer-file-name
                                            (init/python-project-root))))

(defun init/python-test-at-point ()
  "Run the pytest test containing point through uv."
  (interactive)
  (save-buffer)
  (let* ((file (file-relative-name buffer-file-name (init/python-project-root)))
         (defun-name (which-function))
         (node-id (and defun-name
                       (string-replace "." "::" defun-name)))
         (target (if node-id (concat file "::" node-id) file)))
    (init/python--compile "run" "pytest" target)))

(defun init/python-format-buffer ()
  "Format the current buffer with Ruff from the uv environment."
  (interactive)
  (unless buffer-file-name
    (user-error "This buffer is not visiting a file"))
  (let* ((root (init/python-project-root))
         (default-directory root)
         (filename (file-relative-name buffer-file-name root))
         (output (generate-new-buffer " *ruff-format*"))
         (point (point))
         status)
    (unwind-protect
        (progn
          (setq status
                (call-process-region (point-min) (point-max)
                                     init/python-uv-command nil output nil
                                     "run" "ruff" "format"
                                     "--stdin-filename" filename "-"))
          (if (zerop status)
              (unless (string= (with-current-buffer output (buffer-string))
                               (buffer-string))
                (replace-buffer-contents output)
                (goto-char (min point (point-max))))
            (user-error "Ruff formatting failed: %s"
                        (string-trim (with-current-buffer output (buffer-string))))))
      (kill-buffer output))))

(defun init/python-format-buffer-on-save ()
  "Format the buffer before saving when Ruff is available."
  (when (and buffer-file-name (executable-find init/python-uv-command))
    (init/python-format-buffer)))

(defun init/python-ruff-fix ()
  "Apply Ruff's safe lint fixes to the current file."
  (interactive)
  (save-buffer)
  (init/python--compile "run" "ruff" "check" "--fix"
                        (file-relative-name buffer-file-name
                                            (init/python-project-root))))

(defun init/python-repl ()
  "Start or visit a Python REPL inside the uv environment."
  (interactive)
  (let ((default-directory (init/python-project-root))
        (python-shell-interpreter init/python-uv-command)
        (python-shell-interpreter-args "run python -i"))
    (call-interactively #'run-python)))

(defun init/python-show-diagnostics ()
  "Show Python diagnostics."
  (interactive)
  (if (fboundp 'flycheck-list-errors)
      (flycheck-list-errors)
    (flymake-show-buffer-diagnostics)))

(defun init/python-setup ()
  "Enable the Python IDE features in the current buffer."
  (setq-local indent-tabs-mode nil
              tab-width 4
              python-indent-offset 4
              python-shell-interpreter init/python-uv-command
              python-shell-interpreter-args "run python -i"
              eglot-workspace-configuration
              '(:basedpyright (:analysis (:typeCheckingMode "standard"
                                          :autoImportCompletions t
                                          :diagnosticMode "openFilesOnly"
                                          :inlayHints (:variableTypes t
                                                       :callArgumentNames t
                                                       :functionReturnTypes t
                                                       :genericTypes t)))))
  (when (fboundp 'eglot-ensure)
    (eglot-ensure))
  (when (bound-and-true-p flymake-mode)
    (flymake-mode -1))
  (when (fboundp 'flycheck-mode)
    (flycheck-mode 1))
  (add-hook 'before-save-hook #'init/python-format-buffer-on-save nil t)
  (local-set-key (kbd bind/ide-run) #'init/python-run-file)
  (local-set-key (kbd bind/ide-test-at-point) #'init/python-test-at-point)
  (local-set-key (kbd bind/ide-test-file) #'init/python-test-file)
  (local-set-key (kbd bind/ide-test-project) #'init/python-test-project)
  (local-set-key (kbd bind/ide-actions) #'eglot-code-actions)
  (local-set-key (kbd bind/ide-hover) #'eglot-help-at-point)
  (local-set-key (kbd bind/ide-diagnostics) #'init/python-show-diagnostics)
  (local-set-key (kbd bind/ide-reconnect) #'eglot-reconnect)
  (local-set-key (kbd bind/ide-format) #'init/python-format-buffer)
  (local-set-key (kbd bind/ide-fix) #'init/python-ruff-fix)
  (local-set-key (kbd bind/ide-repl) #'init/python-repl)
  (local-set-key (kbd bind/ide-sync) #'init/python-sync))

(use-package python
  :ensure nil
  :hook ((python-mode python-ts-mode) . init/python-setup))

(use-package eglot
  :ensure nil
  :commands (eglot eglot-ensure eglot-code-actions)
  :config
  (add-to-list 'eglot-server-programs
               `((python-mode python-ts-mode)
                 . (,init/python-uv-command "run"
                    ,init/python-language-server "--stdio"))))

(provide 'init-python)
;;; init-python.el ends here
