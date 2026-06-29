;;; ocaml.el --- OCaml language support -*- lexical-binding: t; -*-

(require 'subr-x)
(require 'comint)

(let ((opam-site-lisp (expand-file-name "~/.opam/default/share/emacs/site-lisp"))
      (opam-bin (expand-file-name "~/.opam/default/bin")))
  (when (file-directory-p opam-site-lisp)
    (add-to-list 'load-path opam-site-lisp))
  (when (file-directory-p opam-bin)
    (setenv "PATH" (concat opam-bin path-separator (getenv "PATH")))
    (add-to-list 'exec-path opam-bin)))

(defun init/ocaml--apply-opam-env ()
  "Import the current opam switch environment into Emacs."
  (when (executable-find "opam")
    (dolist (line (split-string
                   (shell-command-to-string "opam env --switch default --shell=sh")
                   "\n" t))
      (when (string-match
             "^\\([A-Z0-9_]+\\)='\\(.*\\)'; export \\1;$" line)
        (setenv (match-string 1 line) (match-string 2 line))))))

(init/ocaml--apply-opam-env)

(require 'ocp-indent nil 'noerror)

(add-to-list 'display-buffer-alist
             '("\\*utop\\*"
               (display-buffer-same-window)))

(defgroup init/ocaml nil
  "OCaml editing support."
  :group 'languages)

(defcustom init/ocaml-lsp-server-command "ocamllsp"
  "Command used to start the OCaml LSP server."
  :type 'string
  :group 'init/ocaml)

(defcustom init/ocaml-utop-command "utop"
  "Command used to start the OCaml REPL."
  :type 'string
  :group 'init/ocaml)

(defcustom init/ocaml-debugger-command "ocamldebug"
  "Command used to start the OCaml debugger."
  :type 'string
  :group 'init/ocaml)

(defun init/ocaml-project-root (&optional dir)
  "Return the OCaml project root for DIR, or `default-directory'."
  (or (when (fboundp 'project-current)
        (when-let ((project (project-current nil dir)))
          (project-root project)))
      (when-let ((root (locate-dominating-file (or dir default-directory)
                                               "dune-project")))
        root)
      default-directory))

(defun init/ocaml--server-missing-warning ()
  "Warn if `ocamllsp' is not available in PATH."
  (unless (executable-find init/ocaml-lsp-server-command)
    (display-warning
     'ocaml
     (format "%s not found in PATH. Install ocaml-lsp-server for LSP support."
             init/ocaml-lsp-server-command)
     :warning)))

(defun init/ocaml-hover-doc ()
  "Show documentation for the symbol at point."
  (interactive)
  (cond
   ((fboundp 'eglot-help-at-point)
    (eglot-help-at-point))
   ((fboundp 'eldoc-print-current-symbol-info)
    (eldoc-print-current-symbol-info))
   (t
    (message "No hover documentation command available."))))

(defun init/ocaml-show-diagnostics ()
  "Show diagnostics at point."
  (interactive)
  (cond
   ((fboundp 'flycheck-list-errors)
    (flycheck-list-errors))
   ((fboundp 'flymake-show-diagnostics-buffer)
    (flymake-show-diagnostics-buffer))
   (t
    (message "No diagnostics UI available."))))

(defun init/ocaml-code-actions ()
  "Offer OCaml code actions and refactorings."
  (interactive)
  (cond
   ((fboundp 'eglot-code-action-quickfix)
    (call-interactively #'eglot-code-action-quickfix))
   ((fboundp 'eglot-code-actions)
    (call-interactively #'eglot-code-actions))
   (t
    (message "No code action command available."))))

(defun init/ocaml-format-buffer ()
  "Format the current buffer via Eglot when managed by LSP."
  (when (and (fboundp 'eglot-managed-p)
             (eglot-managed-p)
             (fboundp 'eglot-format-buffer))
    (eglot-format-buffer)))

(defun init/ocaml-reconnect ()
  "Reconnect the OCaml LSP server for the current buffer."
  (interactive)
  (if (and (fboundp 'eglot-current-server)
           (eglot-current-server)
           (fboundp 'eglot-reconnect))
      (eglot-reconnect (eglot-current-server))
    (message "No active Eglot server to reconnect.")))

(defun init/ocaml-build ()
  "Run `dune build' from the current OCaml project."
  (interactive)
  (save-buffer)
  (let ((default-directory (init/ocaml-project-root)))
    (compile "dune build")))

(defun init/ocaml-test ()
  "Run `dune test' from the current OCaml project."
  (interactive)
  (save-buffer)
  (let ((default-directory (init/ocaml-project-root)))
    (compile "dune test")))

(defun init/ocaml--repl-buffer ()
  "Return the OCaml REPL buffer, creating it if necessary."
  (get-buffer-create "*utop*"))

(defun init/ocaml--regular-frame ()
  "Return the nearest non-child frame to use for REPL display."
  (or (frame-parent (selected-frame))
      (selected-frame)))

(defun init/ocaml--select-regular-window ()
  "Select a normal editing window, closing the compile child frame if present."
  (when (fboundp 'init/compilation-dismiss)
    (init/compilation-dismiss))
  (let ((frame (init/ocaml--regular-frame)))
    (unless (eq frame (selected-frame))
      (select-frame-set-input-focus frame))
    (select-window (frame-selected-window frame))))

(defun init/ocaml-start-raw-utop ()
  "Start a terminal-style utop process in the regular `*utop*' buffer."
  (unless (executable-find init/ocaml-utop-command)
    (user-error "%s not found in PATH" init/ocaml-utop-command))
  (let ((buffer (init/ocaml--repl-buffer)))
    (unless (comint-check-proc buffer)
      (with-current-buffer buffer
        (when (derived-mode-p 'utop-mode)
          (let ((inhibit-read-only t))
            (erase-buffer)))
        (let ((process-connection-type t))
          (make-comint-in-buffer "utop" buffer
                                 init/ocaml-utop-command nil))
        (comint-mode)))
    buffer))

(defun init/ocaml-start-repl ()
  "Start or switch to an OCaml REPL."
  (interactive)
  (let ((default-directory (init/ocaml-project-root))
        (buffer (init/ocaml--repl-buffer)))
    (init/ocaml--select-regular-window)
    (cond
     ((comint-check-proc buffer)
      (switch-to-buffer buffer))
     ((executable-find init/ocaml-utop-command)
      (switch-to-buffer (init/ocaml-start-raw-utop)))
     (t
      (user-error "Install utop or Tuareg REPL support to start an OCaml REPL")))))

(global-set-key (kbd bind/ocaml-start-repl) #'init/ocaml-start-repl)

(defun init/ocaml-debug ()
  "Start an OCaml debugging session."
  (interactive)
  (save-buffer)
  (let ((default-directory (init/ocaml-project-root)))
    (cond
     ((fboundp 'tuareg-run-ocamldebug)
      (call-interactively #'tuareg-run-ocamldebug))
     ((executable-find init/ocaml-debugger-command)
      (let ((target (read-file-name "Program to debug: "
                                    (init/ocaml-project-root) nil t)))
        (compile (format "%s %s"
                         init/ocaml-debugger-command
                         (shell-quote-argument target)))))
     (t
      (user-error "Install ocamldebug or Tuareg debugger support to debug OCaml programs")))))

(defun init/ocaml-setup ()
  "Set up OCaml editing, LSP and buffer-local keybindings."
  (init/ocaml--server-missing-warning)
  (when (fboundp 'eglot-ensure)
    (eglot-ensure))
  (add-hook 'before-save-hook #'init/ocaml-format-buffer nil t)
  (local-set-key (kbd "C-c l h") #'init/ocaml-hover-doc)
  (local-set-key (kbd "C-c l a") #'init/ocaml-code-actions)
  (local-set-key (kbd "C-c l d") #'init/ocaml-show-diagnostics)
  (local-set-key (kbd "C-c l r") #'init/ocaml-reconnect)
  (local-set-key (kbd "C-c l f") #'init/ocaml-format-buffer)
  (local-set-key (kbd "C-c o u") #'init/ocaml-start-repl)
  (local-set-key (kbd "C-c o b") #'init/ocaml-build)
  (local-set-key (kbd "C-c o t") #'init/ocaml-test)
  (local-set-key (kbd "C-c o d") #'init/ocaml-debug)
  (local-set-key (kbd "C-c o ?") #'init/ocaml-show-keybindings)
  (local-set-key (kbd "M-RET") #'init/ocaml-code-actions)
  (local-set-key (kbd "M-.") #'xref-find-definitions)
  (local-set-key (kbd "M-,") #'xref-go-back))

(defun init/ocaml-show-keybindings ()
  "Show the OCaml keybindings for the current buffer."
  (interactive)
  (with-help-window "*OCaml Keys*"
    (princ "OCaml buffer keys\n\n")
    (princ "C-c l h  hover documentation\n")
    (princ "C-c l a  code actions / refactors\n")
    (princ "C-c l d  diagnostics\n")
    (princ "C-c l r  reconnect Eglot\n")
    (princ "C-c l f  format buffer\n")
    (princ "M-.      go to definition\n")
    (princ "M-,      go back\n\n")
    (princ "C-c o u  start or switch to utop\n")
    (princ "C-c o b  dune build\n")
    (princ "C-c o t  dune test\n")
    (princ "C-c o d  debugger\n")
    (princ "C-c o ?  this help buffer\n")))

(use-package tuareg
  :ensure t
  :mode (("\\.ml\\'" . tuareg-mode)
         ("\\.mli\\'" . tuareg-mode)
         ("\\.mll\\'" . tuareg-mode)
         ("\\.mly\\'" . tuareg-mode))
  :hook (tuareg-mode . init/ocaml-setup)
  :custom
  (tuareg-indent-align-with-first-arg nil)
  (tuareg-indent-ellipsis t))

(use-package eglot
  :ensure nil
  :commands (eglot eglot-ensure eglot-code-actions)
  :config
  (add-to-list 'eglot-server-programs
               `((tuareg-mode) . (,init/ocaml-lsp-server-command))))

(with-eval-after-load 'which-key
  (which-key-add-key-based-replacements
    "C-c l" "lsp"
    "C-c l h" "hover doc"
    "C-c l a" "code actions"
    "C-c l d" "diagnostics"
    "C-c l r" "restart lsp"
    "C-c l f" "format buffer"
    "C-c o" "ocaml"
    "C-c o u" "utop repl"
    "C-c o b" "dune build"
    "C-c o t" "dune test"
    "C-c o d" "debugger"))

(provide 'ocaml)
;;; ocaml.el ends here
