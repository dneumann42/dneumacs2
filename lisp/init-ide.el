;;; init-ide.el --- Language servers and the shared IDE layer -*- lexical-binding: t; -*-

;;; Commentary:

;; One place to configure every language server, and one command layer
;; shared by all language buffers.
;;
;; Each IDE concept -- run, test, hover, format, ... -- is a single
;; command bound once in `init/ide-mode-map'.  Running it calls the
;; buffer-local `init/ide-NAME-function' when the language module set
;; one, otherwise a shared default (usually Eglot), otherwise it reports
;; that the action is unavailable here.  So M-RET always means "code
;; actions" and <f5> always means "run", whatever the language, and a
;; language module only has to say where it differs.
;;
;; Language modules set those overrides and call `(init/ide-mode 1)' in
;; their major-mode hook; `init/ide-start-eglot',
;; `init/ide-prefer-flycheck' and `init/ide-format-with-eglot-on-save'
;; cover the setup steps most of them share.

;;; Code:

(require 'subr-x)
(require 'init-keys)

(declare-function consult-eglot-symbols "consult-eglot")
(declare-function dape "dape")
(declare-function eglot-code-actions "eglot")
(declare-function eglot-ensure "eglot")
(declare-function eglot-format-buffer "eglot")
(declare-function flycheck-mode "flycheck")
(declare-function flymake-mode "flymake")

;;;; Language server executables

(defgroup init/lsp nil
  "Language server executables and IDE behaviour."
  :group 'tools)

(defcustom init/rust-analyzer-command "rust-analyzer"
  "Command used to start rust-analyzer."
  :type 'string
  :group 'init/lsp)

(defcustom init/lua-lsp-server-command "lua-language-server"
  "Command used to start the Lua language server."
  :type 'string
  :group 'init/lsp)

(defcustom init/clangd-command
  '("clangd" "--fallback-style={BasedOnStyle: LLVM, IndentWidth: 4, TabWidth: 4, UseTab: Never}")
  "Command used to start clangd for C and C++."
  :type '(repeat string)
  :group 'init/lsp)

(defcustom init/ocaml-lsp-server-command "ocamllsp"
  "Command used to start the OCaml language server."
  :type 'string
  :group 'init/lsp)

(defcustom init/ruby-lsp-server-command "ruby-lsp"
  "Command used to start the Ruby language server."
  :type 'string
  :group 'init/lsp)

(defcustom init/python-uv-command "uv"
  "Command used to run uv, which also launches the Python language server."
  :type 'string
  :group 'init/lsp)

(defcustom init/python-language-server "basedpyright-langserver"
  "Python language server executable run inside the uv environment."
  :type 'string
  :group 'init/lsp)

(use-package eglot
  :ensure nil
  :commands (eglot eglot-ensure eglot-code-actions eglot-reconnect
                   eglot-format-buffer)
  :custom
  ;; Shut servers down once their last buffer is gone, and skip event
  ;; logging -- a large hidden buffer rewritten on every LSP message.
  (eglot-autoshutdown t)
  (eglot-events-buffer-config '(:size 0 :format full))
  ;; Keep the server attached to library sources jumped into from a
  ;; definition lookup; they lie outside the project and would otherwise
  ;; open unmanaged.  `eglot-current-server' reads this in the file
  ;; jumped *to*, so it cannot be set per language.
  (eglot-extend-to-xref t)
  :config
  ;; Kotlin and Java are absent from this list on purpose: their command
  ;; lines depend on which build the buffer belongs to, so
  ;; init-lang-jvm.el registers a function for each instead.
  (dolist (entry
           `(((c-mode c++-mode c-ts-mode c++-ts-mode) . ,init/clangd-command)
             ((rust-mode rust-ts-mode) . (,init/rust-analyzer-command))
             ((lua-mode lua-ts-mode) . (,init/lua-lsp-server-command))
             ((ruby-mode ruby-ts-mode) . (,init/ruby-lsp-server-command))
             ((tuareg-mode) . (,init/ocaml-lsp-server-command))
             ((python-mode python-ts-mode)
              . (,init/python-uv-command "run"
                 ,init/python-language-server "--stdio"))))
    (add-to-list 'eglot-server-programs entry)))

;;;; Diagnostics, documentation and debugging

(use-package flycheck
  :defer t)

(use-package flycheck-eglot
  :after (flycheck eglot)
  :hook (eglot-managed-mode . flycheck-eglot-mode))

;; The single flycheck-posframe configuration; language modules that want
;; a different popup turn this mode off buffer-locally instead of
;; declaring a second, conflicting one.
(use-package flycheck-posframe
  :after flycheck
  :hook (flycheck-mode . flycheck-posframe-mode)
  :custom
  (flycheck-posframe-position 'window-bottom-left-corner))

;; Hover documentation in a child frame at point instead of the echo area.
(use-package eldoc-box
  :defer t)

;; Project-wide symbol search through the language server.
(use-package consult-eglot
  :defer t)

;; DAP debugging (debugpy, codelldb, gdb, ...) on top of the same server
;; configuration Eglot uses.
(use-package dape
  :defer t
  :custom
  (dape-buffer-window-arrangement 'right))

;;;; Generic IDE command dispatch

(defun init/ide--invoke (function)
  "Call FUNCTION interactively when it is a command, otherwise plainly."
  (if (commandp function)
      (call-interactively function)
    (funcall function)))

(defun init/ide--dispatch (override default label)
  "Run OVERRIDE if non-nil, else DEFAULT; error with LABEL if neither."
  (let ((function (or override default)))
    (if function
        (init/ide--invoke function)
      (user-error "%s is not available in this buffer" label))))

(defun init/ide--default-hover ()
  "Show documentation for the symbol at point."
  (cond
   ((fboundp 'eldoc-box-help-at-point) (eldoc-box-help-at-point))
   ((fboundp 'eglot-help-at-point) (eglot-help-at-point))
   ((fboundp 'eldoc-print-current-symbol-info)
    (eldoc-print-current-symbol-info))
   (t (message "No hover documentation command available."))))

(defun init/ide--default-diagnostics ()
  "Show the buffer's diagnostics, preferring the Flycheck list."
  (cond
   ((fboundp 'flycheck-list-errors) (flycheck-list-errors))
   ((fboundp 'flymake-show-buffer-diagnostics)
    (flymake-show-buffer-diagnostics))
   (t (message "No diagnostics UI available."))))

(defun init/ide--default-actions ()
  "Offer code actions via Eglot."
  (if (fboundp 'eglot-code-actions)
      (call-interactively #'eglot-code-actions)
    (message "No code action command available.")))

(defun init/ide--default-fix ()
  "Offer quick fixes via Eglot, falling back to general code actions."
  (cond
   ((fboundp 'eglot-code-action-quickfix)
    (call-interactively #'eglot-code-action-quickfix))
   ((fboundp 'eglot-code-actions)
    (call-interactively #'eglot-code-actions))
   (t (message "No quick fix command available."))))

(defun init/ide--default-reconnect ()
  "Reconnect the Eglot server managing the current buffer, if any."
  (if (and (fboundp 'eglot-current-server)
           (eglot-current-server)
           (fboundp 'eglot-reconnect))
      (eglot-reconnect (eglot-current-server))
    (message "No active language server to reconnect.")))

(defun init/ide--default-format ()
  "Format the current buffer via Eglot when a server manages it."
  (if (and (fboundp 'eglot-managed-p)
           (eglot-managed-p)
           (fboundp 'eglot-format-buffer))
      (eglot-format-buffer)
    (message "No formatter available for this buffer.")))

(defmacro init/define-ide-command (name label &optional default)
  "Define the IDE command `init/ide-NAME' and its override variable.
LABEL names the action in messages.  DEFAULT is a function called when
the buffer-local `init/ide-NAME-function' is nil."
  (let ((variable (intern (format "init/ide-%s-function" name)))
        (command (intern (format "init/ide-%s" name))))
    `(progn
       (defvar-local ,variable nil
         ,(format "Buffer-local implementation of `%s'.\nWhen nil, a shared default is used."
                  command))
       (defun ,command ()
         ,(format "Run the %s IDE action for the current buffer." label)
         (interactive)
         (init/ide--dispatch ,variable ,default ,label)))))

(init/define-ide-command run             "run"                 nil)
(init/define-ide-command test-at-point   "test at point"       nil)
(init/define-ide-command test-file       "test file"           nil)
(init/define-ide-command test-project    "test project"        nil)
(init/define-ide-command repl            "REPL"                nil)
(init/define-ide-command sync            "sync"                nil)
(init/define-ide-command actions         "code actions"        #'init/ide--default-actions)
(init/define-ide-command fix             "quick fix"           #'init/ide--default-fix)
(init/define-ide-command hover           "hover documentation" #'init/ide--default-hover)
(init/define-ide-command diagnostics     "diagnostics"         #'init/ide--default-diagnostics)
(init/define-ide-command reconnect       "reconnect"           #'init/ide--default-reconnect)
(init/define-ide-command format          "format"              #'init/ide--default-format)
(init/define-ide-command goto-definition "go to definition"    #'xref-find-definitions)
(init/define-ide-command go-back         "go back"             #'xref-go-back)
(init/define-ide-command debug           "debugger"            #'dape)
(init/define-ide-command project-symbols "project symbols"     #'consult-eglot-symbols)

;;;; The shared IDE minor mode

(defvar init/ide-mode-map
  (let ((map (make-sparse-keymap)))
    (dolist (entry
             `((,bind/ide-run . init/ide-run)
               (,bind/ide-test-at-point . init/ide-test-at-point)
               (,bind/ide-test-file . init/ide-test-file)
               (,bind/ide-test-project . init/ide-test-project)
               (,bind/ide-actions . init/ide-actions)
               (,bind/ide-hover . init/ide-hover)
               (,bind/ide-diagnostics . init/ide-diagnostics)
               (,bind/ide-reconnect . init/ide-reconnect)
               (,bind/ide-format . init/ide-format)
               (,bind/ide-fix . init/ide-fix)
               (,bind/ide-repl . init/ide-repl)
               (,bind/ide-sync . init/ide-sync)
               (,bind/ide-goto-definition . init/ide-goto-definition)
               (,bind/ide-go-back . init/ide-go-back)
               (,bind/ide-debug . init/ide-debug)
               (,bind/ide-project-symbols . init/ide-project-symbols)))
      (define-key map (kbd (car entry)) (cdr entry)))
    map)
  "Keymap of the IDE actions shared by all language buffers.")

(define-minor-mode init/ide-mode
  "Provide a common set of IDE keybindings in language buffers.
Commands dispatch to the buffer-local overrides set by each language, or
to a shared default."
  :lighter " IDE"
  :keymap init/ide-mode-map)

;;;; Shared buffer setup

(defun init/ide--warn-missing-server (command hint)
  "Warn when COMMAND is not found on `exec-path'.
HINT suggests how to install it."
  (unless (executable-find command)
    (display-warning 'init/lsp
                     (format "%s not found in PATH. %s" command hint)
                     :warning)))

(defun init/ide-start-eglot (command hint)
  "Start Eglot for this buffer, warning first when COMMAND is missing.
HINT suggests how to install the server."
  (init/ide--warn-missing-server command hint)
  (when (fboundp 'eglot-ensure)
    (eglot-ensure)))

(defun init/ide-prefer-flycheck ()
  "Use Flycheck rather than Flymake for diagnostics in this buffer."
  (when (bound-and-true-p flymake-mode)
    (flymake-mode -1))
  (when (fboundp 'flycheck-mode)
    (flycheck-mode 1)))

(defun init/ide-eglot-format-on-save ()
  "Format the buffer with Eglot before saving, when a server manages it.
Intended for use in `before-save-hook'."
  (when (and (fboundp 'eglot-managed-p)
             (eglot-managed-p)
             (fboundp 'eglot-format-buffer))
    (eglot-format-buffer)))

(defun init/ide-format-with-eglot-on-save ()
  "Arrange for this buffer to be formatted by Eglot before every save."
  (add-hook 'before-save-hook #'init/ide-eglot-format-on-save nil t))

;;;; which-key labels

(with-eval-after-load 'which-key
  (which-key-add-key-based-replacements
    bind/ide-hover "hover doc"
    bind/ide-diagnostics "diagnostics"
    bind/ide-reconnect "reconnect lsp"
    bind/ide-format "format buffer"
    bind/ide-fix "quick fix"
    bind/ide-repl "repl"
    bind/ide-sync "sync"))

(provide 'init-ide)
;;; init-ide.el ends here
