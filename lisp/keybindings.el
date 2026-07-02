;;; keybindings.el --- Keybindings -*- lexical-binding: t; -*-

(defconst bind/avy-goto-char "C-:"
  "Key sequence for jumping to a character with Avy.")
(defconst bind/ocaml-start-repl "C-c o u"
  "Key sequence for starting the OCaml REPL.")

;;;; Editor
(defconst bind/toggle-frame-transparency "C-c t"
  "Key sequence for toggling frame transparency.")
(defconst bind/toggle-menu-bar "C-c M"
  "Key sequence for toggling the menu bar.")
(defconst bind/reload-config "C-c r"
  "Key sequence for reloading the Emacs configuration.")
(defconst bind/cheatsheet "C-c g"
  "Key sequence for opening a cheatsheet (guide).")
(defconst bind/compilation-toggle "C-c b"
  "Key sequence for toggling the compilation buffer.")
(defconst bind/project-panel "C-c P"
  "Key sequence for toggling the project panel.")
(defconst bind/doc-toolbar "C-c T"
  "Key sequence for toggling the document toolbar.")

;;;; Project run/build commands
;; Top-row F keys, chosen to avoid the taken ones: <f5> compile /
;; ide-run, <f6>/<S-f6>/<f7> ide tests, <f9> ide debug.
(defconst bind/project-run "<f2>"
  "Key sequence for running the project's run command.")
(defconst bind/project-build "<f3>"
  "Key sequence for running the project's build command.")
(defconst bind/project-command-switch "<f4>"
  "Key sequence for switching what run/build executes.")
(defconst bind/project-command-add "<f8>"
  "Key sequence for registering a new project command.")
(defconst bind/session-menu "C-c S"
  "Key sequence for opening the session menu.")

;;;; Bookmarks (bm)
;; Single-chord marks, like Vim's m/]'/['.  After M-] or M-[, repeat-mode
;; keeps plain ] and [ live so you can hop between bookmarks with one
;; keypress ("," drops a bookmark mid-hop).
(defconst bind/bm-toggle "C-,"
  "Key sequence for toggling a bookmark on the current line.")
(defconst bind/bm-next "M-]"
  "Key sequence for jumping to the next bookmark in the file.")
(defconst bind/bm-previous "M-["
  "Key sequence for jumping to the previous bookmark in the file.")
(defconst bind/bm-jump-project "C-M-,"
  "Key sequence for jumping to any bookmark in the project.")
(defconst bind/bm-jump-project-alt "M-g b"
  "Alternate key sequence for the project bookmark picker.")
(defconst bind/bm-clear-buffer "C-c ,"
  "Key sequence for removing all bookmarks in the current file.")

;;;; Surround (vim-surround style pair editing)
(defconst bind/surround "M-'"
  "Prefix key for the surround keymap (wrap/change/delete pairs).")
(defconst bind/compile "<f5>"
  "Key sequence for starting a compilation.")
(defconst bind/forward-paragraph "M-n"
  "Key sequence for moving forward one paragraph.")
(defconst bind/backward-paragraph "M-p"
  "Key sequence for moving backward one paragraph.")
(defconst bind/repeat "C-x z"
  "Key sequence for repeating the last command.")

;;;; Language IDE actions
;; Each IDE binding is at most two key events. These are bound locally in
;; language buffers, so overlaps with global editor bindings are intentional.
(defconst bind/ide-run "<f5>"
  "Key sequence for running the current program.")
(defconst bind/ide-test-at-point "<f6>"
  "Key sequence for running the test at point.")
(defconst bind/ide-test-file "<S-f6>"
  "Key sequence for running the tests in the current file.")
(defconst bind/ide-test-project "<f7>"
  "Key sequence for running the whole project's tests.")
(defconst bind/ide-actions "M-RET"
  "Key sequence for invoking available code actions.")
(defconst bind/ide-hover "C-c h"
  "Key sequence for showing hover documentation.")
(defconst bind/ide-diagnostics "C-c d"
  "Key sequence for listing buffer diagnostics.")
(defconst bind/ide-reconnect "C-c r"
  "Key sequence for reconnecting the language server.")
(defconst bind/ide-format "C-c f"
  "Key sequence for formatting the current buffer.")
(defconst bind/ide-fix "C-c x"
  "Key sequence for applying an automatic fix.")
(defconst bind/ide-repl "C-c z"
  "Key sequence for opening the language REPL.")
(defconst bind/ide-sync "C-c s"
  "Key sequence for syncing the project or language server.")
(defconst bind/ide-goto-definition "M-."
  "Key sequence for jumping to the definition at point.")
(defconst bind/ide-go-back "M-,"
  "Key sequence for jumping back after a definition jump.")
(defconst bind/ide-debug "<f9>"
  "Key sequence for starting a debugging session.")
(defconst bind/ide-project-symbols "M-g s"
  "Key sequence for searching symbols across the project.")

;;;; Language-specific IDE actions
;; Extra commands that have no generic equivalent, bound in their own
;; language buffers on top of the shared IDE keymap.
(defconst bind/ocaml-build "C-c o b"
  "Key sequence for `dune build' in OCaml buffers.")
(defconst bind/ocaml-test "C-c o t"
  "Key sequence for `dune test' in OCaml buffers.")
(defconst bind/ocaml-debug "C-c o d"
  "Key sequence for starting the OCaml debugger.")
(defconst bind/ocaml-help "C-c o ?"
  "Key sequence for the OCaml keybinding help buffer.")
(defconst bind/nim-mark-token "C-M-SPC"
  "Key sequence for marking the Nim token at point.")

;;;; Shared IDE minor mode
;; The common command layer lives in init-lsp.el; the commands are bound
;; here so every key sequence is defined in one file.  Keymaps may
;; reference commands that are defined later, so load order is fine.

(defvar init/ide-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd bind/ide-run) #'init/ide-run)
    (define-key map (kbd bind/ide-test-at-point) #'init/ide-test-at-point)
    (define-key map (kbd bind/ide-test-file) #'init/ide-test-file)
    (define-key map (kbd bind/ide-test-project) #'init/ide-test-project)
    (define-key map (kbd bind/ide-actions) #'init/ide-actions)
    (define-key map (kbd bind/ide-hover) #'init/ide-hover)
    (define-key map (kbd bind/ide-diagnostics) #'init/ide-diagnostics)
    (define-key map (kbd bind/ide-reconnect) #'init/ide-reconnect)
    (define-key map (kbd bind/ide-format) #'init/ide-format)
    (define-key map (kbd bind/ide-fix) #'init/ide-fix)
    (define-key map (kbd bind/ide-repl) #'init/ide-repl)
    (define-key map (kbd bind/ide-sync) #'init/ide-sync)
    (define-key map (kbd bind/ide-goto-definition) #'init/ide-goto-definition)
    (define-key map (kbd bind/ide-go-back) #'init/ide-go-back)
    (define-key map (kbd bind/ide-debug) #'init/ide-debug)
    (define-key map (kbd bind/ide-project-symbols) #'init/ide-project-symbols)
    map)
  "Keymap of common IDE actions shared by all language buffers.")

(define-minor-mode init/ide-mode
  "Provide a common set of IDE keybindings in language buffers.
Commands dispatch to buffer-local overrides set by each language, or to
a shared default (see init-lsp.el)."
  :lighter " IDE"
  :keymap init/ide-mode-map)

(provide 'keybindings)
;;; keybindings.el ends here
