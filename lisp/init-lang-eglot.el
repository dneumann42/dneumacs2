;;; init-lang-eglot.el --- Languages served by Eglot -*- lexical-binding: t; -*-

;;; Commentary:

;; The languages whose support is essentially "start the language server
;; and enable the shared IDE keymap": C and C++, Lua, Rust, OCaml,
;; Python, Ruby and RON.
;;
;; Each has a setup function run from its major-mode hook.  They all
;; follow the same shape -- indentation, `init/ide-start-eglot', maybe
;; Flycheck and format-on-save, then any `init/ide-*-function' overrides
;; and `(init/ide-mode 1)' -- so what is left in each is only what makes
;; that language different.
;;
;; Languages with substantial support of their own live in their own
;; files: init-lang-lisp.el, init-lang-nim.el and init-owl.el.

;;; Code:

(require 'subr-x)
(require 'init-ide)
(require 'init-keys)
(require 'init-lib)

(declare-function cheatsheet-show "init-cheatsheet")

;;; C and C++

(defcustom init/c-auto-create-clang-format t
  "When non-nil, create a project .clang-format for C and C++ buffers."
  :type 'boolean
  :group 'init/lsp)

(defcustom init/c-auto-create-compile-flags t
  "When non-nil, create project compile_flags.txt for C and C++ buffers."
  :type 'boolean
  :group 'init/lsp)

(defconst init/c-default-clang-format
  "BasedOnStyle: LLVM
IndentWidth: 4
TabWidth: 4
UseTab: Never
"
  "Default clang-format style written for C and C++ projects.")

(defconst init/c-default-compile-flags
  '("-Wall"
    "-Wextra"
    "-Isrc"
    "-Ibuild/tcc")
  "Default clangd flags written for small C and C++ projects.")

(defun init/c-project-root ()
  "Return the root for the current C or C++ project."
  (or (and buffer-file-name (init/git-repo-root buffer-file-name))
      (init/project-root-for '("compile_commands.json"
                               "compile_flags.txt"
                               "CMakeLists.txt"
                               "Makefile"
                               "meson.build"
                               "configure.ac"
                               "configure"))))

(defun init/c-ensure-clang-format ()
  "Create a default .clang-format at the C or C++ project root when absent."
  (when (and init/c-auto-create-clang-format buffer-file-name)
    (let* ((root (file-name-as-directory (expand-file-name (init/c-project-root))))
           (style-file (expand-file-name ".clang-format" root)))
      (unless (or (locate-dominating-file buffer-file-name ".clang-format")
                  (file-exists-p style-file))
        (make-directory root t)
        (init/atomic-write-file
         style-file
         (lambda (temporary)
           (with-temp-file temporary
             (insert init/c-default-clang-format))))))))

(defun init/c-ensure-compile-flags ()
  "Create compile_flags.txt at the C or C++ project root when no compile DB exists."
  (when (and init/c-auto-create-compile-flags buffer-file-name)
    (let* ((root (file-name-as-directory (expand-file-name (init/c-project-root))))
           (compile-db (expand-file-name "compile_commands.json" root))
           (flags-file (expand-file-name "compile_flags.txt" root)))
      (unless (or (file-exists-p compile-db) (file-exists-p flags-file))
        (make-directory root t)
        (init/atomic-write-file
         flags-file
         (lambda (temporary)
           (with-temp-file temporary
             (dolist (flag init/c-default-compile-flags)
               (insert flag "\n")))))))))

(defun init/c-format-buffer ()
  "Format the current C or C++ buffer with clang-format and project style."
  (interactive)
  (unless buffer-file-name
    (user-error "This buffer is not visiting a file"))
  (unless (executable-find "clang-format")
    (user-error "clang-format not found in PATH"))
  (init/c-ensure-clang-format)
  (let ((output (generate-new-buffer " *clang-format output*")))
    (unwind-protect
        (let ((status (call-process-region
                       (point-min) (point-max) "clang-format" nil
                       output nil
                       "--style=file"
                       (concat "--assume-filename=" buffer-file-name))))
          (unless (zerop status)
            (with-current-buffer output
              (user-error "clang-format failed: %s" (string-trim (buffer-string)))))
          (replace-buffer-contents output))
      (kill-buffer output))))

(defun init/c-setup ()
  "Set up C and C++ editing, LSP and diagnostics in the current buffer."
  ;; `c-set-style' only works in a real CC Mode buffer, and it signals
  ;; otherwise.  Emacs 30 makes `c-ts-mode' report as derived from
  ;; `c-mode', so deriving-mode is not a safe test: ask CC Mode itself.
  (when (bound-and-true-p c-buffer-is-cc-mode)
    (c-set-style "linux"))
  (setq-local c-basic-offset 4
              tab-width 4
              indent-tabs-mode nil)
  (when (boundp 'c-ts-mode-indent-offset)
    (setq-local c-ts-mode-indent-offset 4))
  (init/c-ensure-clang-format)
  (init/c-ensure-compile-flags)
  (init/ide-start-eglot (car init/clangd-command)
                        "Install clangd for C LSP support.")
  (init/ide-prefer-flycheck)
  (add-hook 'before-save-hook #'init/c-format-buffer nil t)
  (setq-local init/ide-format-function #'init/c-format-buffer)
  (init/ide-mode 1))

(use-package cc-mode
  :ensure nil
  :mode (("\\.c\\'" . c-mode)
         ("\\.h\\'" . c-mode))
  :hook ((c-mode c++-mode) . init/c-setup))

(add-hook 'c-ts-mode-hook #'init/c-setup)
(add-hook 'c++-ts-mode-hook #'init/c-setup)

;;; Lua

(defconst init/lua-workspace-configuration
  '(("Lua" . (("format" . (("defaultConfig" . (("indent_style" . "space")
                                               ("indent_size" . "4"))))))))
  "Workspace settings sent to the Lua language server.")

(defun init/lua-setup ()
  "Set up Lua editing, LSP and diagnostics in the current buffer."
  (setq-local lua-indent-level 4
              tab-width 4
              indent-tabs-mode nil
              eglot-workspace-configuration init/lua-workspace-configuration)
  (when (boundp 'lua-ts-mode-indent-offset)
    (setq-local lua-ts-mode-indent-offset 4))
  (init/ide-start-eglot init/lua-lsp-server-command
                        "Install lua-language-server for Lua LSP support.")
  (init/ide-prefer-flycheck)
  (init/ide-format-with-eglot-on-save)
  (init/ide-mode 1))

(use-package lua-mode
  :mode (("\\.lua\\'" . lua-mode)
         ("\\.rockspec\\'" . lua-mode))
  :interpreter ("lua" . lua-mode)
  :hook (lua-mode . init/lua-setup))

;;; Rust

(defgroup init/rust nil
  "Rust editing support."
  :group 'languages)

(defcustom init/rust-cargo-bin-directory (expand-file-name "~/.cargo/bin")
  "Directory containing Cargo-installed Rust tools."
  :type 'directory
  :group 'init/rust)

(defun init/rust-project-root ()
  "Return the root of the Cargo package containing the current buffer."
  (init/project-root-for '("Cargo.toml")))

(defun init/rust-run ()
  "Save the current buffer and run `cargo run' from the project root."
  (interactive)
  (save-buffer)
  (let ((default-directory (init/rust-project-root)))
    (compile "cargo run")))

(defun init/rust-setup ()
  "Set up Rust editing, LSP and diagnostics in the current buffer."
  (init/prepend-to-path init/rust-cargo-bin-directory)
  (init/ide-start-eglot init/rust-analyzer-command
                        "Install rust-analyzer for Rust LSP support.")
  (setq-local init/ide-run-function #'init/rust-run)
  (init/ide-mode 1))

(use-package rust-mode
  :mode ("\\.rs\\'" . rust-mode)
  :hook (rust-mode . init/rust-setup))

;;; OCaml

(defgroup init/ocaml nil
  "OCaml editing support."
  :group 'languages)

(defcustom init/ocaml-utop-command "utop"
  "Command used to start the OCaml REPL."
  :type 'string
  :group 'init/ocaml)

(defcustom init/ocaml-debugger-command "ocamldebug"
  "Command used to start the OCaml debugger."
  :type 'string
  :group 'init/ocaml)

(init/prepend-to-path "~/.opam/default/bin")

(let ((site-lisp (expand-file-name "~/.opam/default/share/emacs/site-lisp")))
  (when (file-directory-p site-lisp)
    (add-to-list 'load-path site-lisp)))

(defvar init/ocaml--opam-env-applied nil
  "Non-nil once the opam environment has been imported this session.")

(defun init/ocaml--apply-opam-env ()
  "Import the current opam switch environment into Emacs, once.
Runs `opam env' in a subprocess, so the cost is paid on the first OCaml
buffer rather than on every startup."
  (unless init/ocaml--opam-env-applied
    (setq init/ocaml--opam-env-applied t)
    (when (executable-find "opam")
      (dolist (line (split-string
                     (shell-command-to-string
                      "opam env --switch default --shell=sh")
                     "\n" t))
        (when (string-match "^\\([A-Z0-9_]+\\)='\\(.*\\)'; export \\1;$" line)
          (setenv (match-string 1 line) (match-string 2 line)))))))

(defun init/ocaml-project-root ()
  "Return the root of the dune project containing the current buffer."
  (init/project-root-for '("dune-project")))

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

(defun init/ocaml--select-regular-window ()
  "Select a normal editing window, dismissing the run/build panel first.
The REPL must not land in the floating compilation child frame."
  (when (fboundp 'init/compilation-dismiss)
    (init/compilation-dismiss))
  (let ((frame (or (frame-parent (selected-frame)) (selected-frame))))
    (unless (eq frame (selected-frame))
      (select-frame-set-input-focus frame))
    (select-window (frame-selected-window frame))))

(defun init/ocaml-start-raw-utop ()
  "Start a terminal-style utop process in the `*utop*' buffer.
Return that buffer."
  (unless (executable-find init/ocaml-utop-command)
    (user-error "%s not found in PATH" init/ocaml-utop-command))
  (let ((buffer (init/ocaml--repl-buffer)))
    (unless (comint-check-proc buffer)
      (with-current-buffer buffer
        (when (derived-mode-p 'utop-mode)
          (let ((inhibit-read-only t))
            (erase-buffer)))
        (let ((process-connection-type t))
          (make-comint-in-buffer "utop" buffer init/ocaml-utop-command nil))
        (comint-mode)))
    buffer))

(defun init/ocaml-start-repl ()
  "Start, or switch to, an OCaml REPL."
  (interactive)
  (let ((default-directory (init/ocaml-project-root))
        (buffer (init/ocaml--repl-buffer)))
    (init/ocaml--select-regular-window)
    (cond
     ((comint-check-proc buffer) (switch-to-buffer buffer))
     ((executable-find init/ocaml-utop-command)
      (switch-to-buffer (init/ocaml-start-raw-utop)))
     (t (user-error "Install utop to start an OCaml REPL")))))

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
     (t (user-error "Install ocamldebug or Tuareg debugger support")))))

(defun init/ocaml-show-keybindings ()
  "Show the cheatsheet covering the OCaml commands."
  (interactive)
  (cheatsheet-show "OCaml"))

(defun init/ocaml-setup ()
  "Set up OCaml editing, LSP and buffer-local keybindings."
  (init/ocaml--apply-opam-env)
  (init/ide-start-eglot init/ocaml-lsp-server-command
                        "Install ocaml-lsp-server for OCaml LSP support.")
  (init/ide-format-with-eglot-on-save)
  (setq-local init/ide-repl-function #'init/ocaml-start-repl
              init/ide-test-project-function #'init/ocaml-test
              init/ide-sync-function #'init/ocaml-build)
  (init/ide-mode 1))

(use-package tuareg
  :ensure t
  :mode (("\\.ml\\'" . tuareg-mode)
         ("\\.mli\\'" . tuareg-mode)
         ("\\.mll\\'" . tuareg-mode)
         ("\\.mly\\'" . tuareg-mode))
  :hook (tuareg-mode . init/ocaml-setup)
  :custom
  (tuareg-indent-align-with-first-arg nil)
  (tuareg-indent-ellipsis t)
  :config
  (require 'ocp-indent nil 'noerror)
  ;; OCaml extras with no generic IDE equivalent.
  (define-key tuareg-mode-map (kbd bind/ocaml-build) #'init/ocaml-build)
  (define-key tuareg-mode-map (kbd bind/ocaml-test) #'init/ocaml-test)
  (define-key tuareg-mode-map (kbd bind/ocaml-debug) #'init/ocaml-debug)
  (define-key tuareg-mode-map (kbd bind/ocaml-help) #'init/ocaml-show-keybindings))

;; utop replaces the buffer it is shown in rather than splitting.
(add-to-list 'display-buffer-alist '("\\*utop\\*" (display-buffer-same-window)))

(global-set-key (kbd bind/ocaml-start-repl) #'init/ocaml-start-repl)

(with-eval-after-load 'which-key
  (which-key-add-key-based-replacements
    "C-c o" "ocaml"
    bind/ocaml-start-repl "utop repl"
    bind/ocaml-build "dune build"
    bind/ocaml-test "dune test"
    bind/ocaml-debug "debugger"))

;;; Python

;; `which-function' identifies the pytest node id for the test at point.
(require 'which-func)

(defconst init/python-workspace-configuration
  '(:basedpyright
    (:analysis (:typeCheckingMode "standard"
                :autoImportCompletions t
                :diagnosticMode "openFilesOnly"
                :inlayHints (:variableTypes t
                             :callArgumentNames t
                             :functionReturnTypes t
                             :genericTypes t))))
  "Workspace settings sent to the Python language server.")

(defun init/python-project-root ()
  "Return the root of the Python project containing the current buffer."
  (init/project-root-for '("uv.lock" "pyproject.toml")))

(defun init/python--compile (&rest arguments)
  "Run uv with ARGUMENTS from the Python project root."
  (let ((default-directory (init/python-project-root)))
    (compile (mapconcat #'shell-quote-argument
                        (cons init/python-uv-command arguments)
                        " "))))

(defun init/python--relative-file ()
  "Return the current file relative to the Python project root."
  (unless buffer-file-name
    (user-error "This buffer is not visiting a file"))
  (file-relative-name buffer-file-name (init/python-project-root)))

(defun init/python-sync ()
  "Synchronise the current project's uv environment."
  (interactive)
  (init/python--compile "sync"))

(defun init/python-run-file ()
  "Save and run the current Python file through uv."
  (interactive)
  (save-buffer)
  (init/python--compile "run" "python" (init/python--relative-file)))

(defun init/python-test-project ()
  "Run the complete pytest suite through uv."
  (interactive)
  (init/python--compile "run" "pytest"))

(defun init/python-test-file ()
  "Run pytest for the current file through uv."
  (interactive)
  (save-buffer)
  (init/python--compile "run" "pytest" (init/python--relative-file)))

(defun init/python-test-at-point ()
  "Run the pytest test containing point through uv."
  (interactive)
  (save-buffer)
  (let* ((file (init/python--relative-file))
         (function-name (which-function))
         (node-id (and function-name (string-replace "." "::" function-name))))
    (init/python--compile "run" "pytest"
                          (if node-id (concat file "::" node-id) file))))

(defun init/python-ruff-fix ()
  "Apply Ruff's safe lint fixes to the current file."
  (interactive)
  (save-buffer)
  (init/python--compile "run" "ruff" "check" "--fix"
                        (init/python--relative-file)))

(defun init/python-format-buffer ()
  "Format the current buffer with Ruff from the uv environment."
  (interactive)
  (let* ((filename (init/python--relative-file))
         (default-directory (init/python-project-root))
         (output (generate-new-buffer " *ruff-format*"))
         (origin (point)))
    (unwind-protect
        (if (zerop (call-process-region (point-min) (point-max)
                                        init/python-uv-command nil output nil
                                        "run" "ruff" "format"
                                        "--stdin-filename" filename "-"))
            (unless (string= (with-current-buffer output (buffer-string))
                             (buffer-string))
              (replace-buffer-contents output)
              (goto-char (min origin (point-max))))
          (user-error "Ruff formatting failed: %s"
                      (string-trim (with-current-buffer output (buffer-string)))))
      (kill-buffer output))))

(defun init/python-format-buffer-on-save ()
  "Format the buffer with Ruff before saving, when uv is available."
  (when (and buffer-file-name (executable-find init/python-uv-command))
    (init/python-format-buffer)))

(defun init/python-repl ()
  "Start, or visit, a Python REPL inside the uv environment."
  (interactive)
  (let ((default-directory (init/python-project-root))
        (python-shell-interpreter init/python-uv-command)
        (python-shell-interpreter-args "run python -i"))
    (call-interactively #'run-python)))

(defun init/python-setup ()
  "Enable the Python IDE features in the current buffer."
  (setq-local indent-tabs-mode nil
              tab-width 4
              python-indent-offset 4
              python-shell-interpreter init/python-uv-command
              python-shell-interpreter-args "run python -i"
              eglot-workspace-configuration init/python-workspace-configuration)
  (when (fboundp 'eglot-ensure)
    (eglot-ensure))
  (init/ide-prefer-flycheck)
  (add-hook 'before-save-hook #'init/python-format-buffer-on-save nil t)
  (setq-local init/ide-run-function #'init/python-run-file
              init/ide-test-at-point-function #'init/python-test-at-point
              init/ide-test-file-function #'init/python-test-file
              init/ide-test-project-function #'init/python-test-project
              init/ide-format-function #'init/python-format-buffer
              init/ide-fix-function #'init/python-ruff-fix
              init/ide-repl-function #'init/python-repl
              init/ide-sync-function #'init/python-sync)
  (init/ide-mode 1))

(use-package python
  :ensure nil
  :hook ((python-mode python-ts-mode) . init/python-setup))

;;; Ruby

(defconst init/ruby-file-patterns
  '("\\.rb\\'" "\\.rake\\'" "\\.gemspec\\'" "Gemfile\\'" "Rakefile\\'"
    "Guardfile\\'" "Podfile\\'" "\\.irbrc\\'" "\\.pryrc\\'")
  "File name patterns handled by the Ruby major modes.")

(defvar init/ruby--gem-user-bin nil
  "User gem executable directory for the active Ruby, when known.")

(defun init/ruby--detect-gem-user-bin ()
  "Return the user gem executable directory for the active Ruby, or nil."
  (when (executable-find "ruby")
    (with-temp-buffer
      (when (zerop (call-process
                    "ruby" nil t nil
                    "-rrubygems" "-e" "print File.join(Gem.user_dir, 'bin')"))
        (let ((directory (string-trim (buffer-string))))
          (when (file-directory-p directory)
            directory))))))

(defun init/ruby--ensure-gem-path ()
  "Make user-installed Ruby gem executables visible to Emacs.
The detection runs Ruby, so it is done once, on the first Ruby buffer."
  (when-let* ((directory (or init/ruby--gem-user-bin
                            (setq init/ruby--gem-user-bin
                                  (init/ruby--detect-gem-user-bin)))))
    (init/prepend-to-path directory)))

(defun init/ruby-setup ()
  "Set up Ruby editing, LSP and navigation in the current buffer."
  (setq-local ruby-indent-level 2
              tab-width 2
              indent-tabs-mode nil)
  (init/ruby--ensure-gem-path)
  (init/ide-start-eglot init/ruby-lsp-server-command
                        "Install the ruby-lsp gem for Ruby LSP support.")
  (init/ide-mode 1))

(dolist (pattern init/ruby-file-patterns)
  (add-to-list 'auto-mode-alist (cons pattern #'ruby-mode)))
(add-to-list 'interpreter-mode-alist '("ruby" . ruby-mode))
(add-hook 'ruby-mode-hook #'init/ruby-setup)

;;; RON

(use-package ron-mode
  :mode ("\\.ron\\'" . ron-mode))

;;; Tree-sitter variants

;; The tree-sitter modes are preferred where the grammar is installed.
;; `treesit-auto' remaps most of them; these entries add the hook that
;; runs the same setup function, and the file patterns `treesit-auto'
;; does not know about.

(defun init/treesit-ready-p (language)
  "Return non-nil when a tree-sitter grammar for LANGUAGE is installed."
  (and (fboundp 'treesit-language-available-p)
       (treesit-language-available-p language)))

(when (and (fboundp 'rust-ts-mode) (init/treesit-ready-p 'rust))
  (add-to-list 'auto-mode-alist '("\\.rs\\'" . rust-ts-mode))
  (add-hook 'rust-ts-mode-hook #'init/rust-setup))

(when (and (fboundp 'lua-ts-mode) (init/treesit-ready-p 'lua))
  (add-to-list 'auto-mode-alist '("\\.lua\\'" . lua-ts-mode))
  (add-hook 'lua-ts-mode-hook #'init/lua-setup))

(when (and (fboundp 'ruby-ts-mode) (init/treesit-ready-p 'ruby))
  (dolist (pattern init/ruby-file-patterns)
    (add-to-list 'auto-mode-alist (cons pattern #'ruby-ts-mode)))
  (add-hook 'ruby-ts-mode-hook #'init/ruby-setup))

(provide 'init-lang-eglot)
;;; init-lang-eglot.el ends here
