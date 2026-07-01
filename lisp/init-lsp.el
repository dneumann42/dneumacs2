;;; init-lsp.el --- Central LSP config and shared IDE commands -*- lexical-binding: t; -*-

;;; Commentary:

;; One place to configure every language server and one common command
;; layer shared by all language buffers.  Language modules set a few
;; buffer-local `init/ide-*-function' overrides and enable `init/ide-mode'
;; (defined in keybindings.el); the generic `init/ide-*' commands here
;; dispatch to those overrides or to a shared default.

;;; Code:

(require 'subr-x)

;;;; Language server configuration

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

(defcustom init/ocaml-lsp-server-command "ocamllsp"
  "Command used to start the OCaml language server."
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

(defun init/ide--warn-missing-server (command hint)
  "Warn when COMMAND is not found on `exec-path'.
HINT suggests how to install it."
  (unless (executable-find command)
    (display-warning 'init/lsp
                     (format "%s not found in PATH. %s" command hint)
                     :warning)))

(defun init/ide-eglot-format-on-save ()
  "Format the buffer with Eglot before saving when a server manages it.
Intended for use in `before-save-hook'."
  (when (and (fboundp 'eglot-managed-p)
             (eglot-managed-p)
             (fboundp 'eglot-format-buffer))
    (eglot-format-buffer)))

(use-package eglot
  :ensure nil
  :commands (eglot eglot-ensure eglot-code-actions eglot-reconnect
                   eglot-format-buffer)
  :config
  (add-to-list 'eglot-server-programs
               '((c-mode c++-mode c-ts-mode c++-ts-mode) . ("clangd")))
  (add-to-list 'eglot-server-programs
               `((rust-mode rust-ts-mode) . (,init/rust-analyzer-command)))
  (add-to-list 'eglot-server-programs
               `((lua-mode lua-ts-mode) . (,init/lua-lsp-server-command)))
  (add-to-list 'eglot-server-programs
               `((tuareg-mode) . (,init/ocaml-lsp-server-command)))
  (add-to-list 'eglot-server-programs
               `((python-mode python-ts-mode)
                 . (,init/python-uv-command "run"
                    ,init/python-language-server "--stdio"))))

;;;; Shared diagnostics stack

(use-package flycheck
  :defer t)

(use-package flycheck-eglot
  :after (flycheck eglot)
  :hook (eglot-managed-mode . flycheck-eglot-mode))

(use-package flycheck-posframe
  :after flycheck
  :hook (flycheck-mode . flycheck-posframe-mode)
  :custom
  (flycheck-posframe-position 'window-bottom-left-corner))

;;;; Generic IDE command dispatch

;; Each IDE concept is one command bound once in `init/ide-mode-map'.  It
;; runs the buffer-local `init/ide-X-function' when a language sets one,
;; otherwise a shared default, otherwise it reports the action is
;; unavailable.  This replaces the per-language copies of hover,
;; diagnostics, code-actions and reconnect helpers.

(defun init/ide--invoke (fn)
  "Call FN interactively when it is a command, otherwise as a function."
  (if (commandp fn)
      (call-interactively fn)
    (funcall fn)))

(defun init/ide--dispatch (override default label)
  "Run OVERRIDE if non-nil, else DEFAULT; error with LABEL if neither."
  (let ((fn (or override default)))
    (if fn
        (init/ide--invoke fn)
      (user-error "%s is not available in this buffer" label))))

(defun init/ide--default-hover ()
  "Show documentation for the symbol at point."
  (cond
   ((fboundp 'eglot-help-at-point) (eglot-help-at-point))
   ((fboundp 'eldoc-print-current-symbol-info)
    (eldoc-print-current-symbol-info))
   (t (message "No hover documentation command available."))))

(defun init/ide--default-diagnostics ()
  "Show buffer diagnostics, preferring the flycheck popup UI."
  (cond
   ((fboundp 'flycheck-posframe-show-posframe)
    (flycheck-posframe-show-posframe))
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
  "Format the current buffer via Eglot when it is managed by a server."
  (if (and (fboundp 'eglot-managed-p)
           (eglot-managed-p)
           (fboundp 'eglot-format-buffer))
      (eglot-format-buffer)
    (message "No formatter available for this buffer.")))

(defmacro init/define-ide-command (name label &optional default)
  "Define generic IDE command `init/ide-NAME' and its override variable.
LABEL names the action in messages.  DEFAULT is a function called when
the buffer-local `init/ide-NAME-function' is nil."
  (let ((var (intern (format "init/ide-%s-function" name)))
        (cmd (intern (format "init/ide-%s" name))))
    `(progn
       (defvar-local ,var nil
         ,(format "Buffer-local implementation of `%s'.\nWhen nil, a shared default is used." cmd))
       (defun ,cmd ()
         ,(format "Run the %s IDE action for the current buffer." label)
         (interactive)
         (init/ide--dispatch ,var ,default ,label)))))

(init/define-ide-command run             "run"               nil)
(init/define-ide-command test-at-point   "test at point"     nil)
(init/define-ide-command test-file       "test file"         nil)
(init/define-ide-command test-project    "test project"      nil)
(init/define-ide-command actions         "code actions"      #'init/ide--default-actions)
(init/define-ide-command hover           "hover documentation" #'init/ide--default-hover)
(init/define-ide-command diagnostics     "diagnostics"       #'init/ide--default-diagnostics)
(init/define-ide-command reconnect       "reconnect"         #'init/ide--default-reconnect)
(init/define-ide-command format          "format"            #'init/ide--default-format)
(init/define-ide-command fix             "quick fix"         #'init/ide--default-fix)
(init/define-ide-command repl            "REPL"              nil)
(init/define-ide-command sync            "sync"              nil)
(init/define-ide-command goto-definition "go to definition"  #'xref-find-definitions)
(init/define-ide-command go-back         "go back"           #'xref-go-back)

;;;; which-key labels for the common set

(with-eval-after-load 'which-key
  (which-key-add-key-based-replacements
    "C-c h" "hover doc"
    "C-c d" "diagnostics"
    "C-c r" "reconnect lsp"
    "C-c f" "format buffer"
    "C-c x" "quick fix"
    "C-c z" "repl"
    "C-c s" "sync"))

(provide 'init-lsp)
;;; init-lsp.el ends here
