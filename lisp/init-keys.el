;;; init-keys.el --- Key sequences used by this configuration -*- lexical-binding: t; -*-

;;; Commentary:

;; Every key sequence bound to a command *defined in this configuration*
;; is named here, so the whole keymap can be read, and rebound, in one
;; place.  Modules bind the constant rather than a literal:
;;
;;   (global-set-key (kbd bind/reload-config) #'init/reload-config)
;;
;; Bindings for third-party commands stay in the `use-package' `:bind'
;; form of the package that owns them, where they belong.
;;
;; Language buffers bind their IDE actions through `init/ide-mode' (see
;; init-ide.el), so the `bind/ide-*' sequences below deliberately shadow
;; global ones such as `bind/reload-config'.

;;; Code:

;;;; Editor and frame

(defconst bind/reload-config "C-c r"
  "Key sequence for reloading the Emacs configuration.")
(defconst bind/cheatsheet "C-c g"
  "Key sequence for opening a cheatsheet (guide).")
(defconst bind/repeat "C-x z"
  "Key sequence for repeating the last command.")
(defconst bind/forward-paragraph "M-n"
  "Key sequence for moving forward one paragraph.")
(defconst bind/backward-paragraph "M-p"
  "Key sequence for moving backward one paragraph.")
(defconst bind/avy-goto-char "C-:"
  "Key sequence for jumping to a visible character with Avy.")
(defconst bind/surround "M-'"
  "Prefix key for the surround keymap (wrap, change and delete pairs).")

(defconst bind/rebalance-panes "C-c ="
  "Rebalance the size of panes.")

(defconst bind/toggle-frame-transparency "C-c t"
  "Key sequence for toggling frame transparency.")
(defconst bind/toggle-menu-bar "C-c M"
  "Key sequence for toggling the menu bar.")
(defconst bind/menu-bar-open "<f10>"
  "Key sequence for opening the menu bar as a keyboard-driven pulldown.")
(defconst bind/context-menu-open "<S-f10>"
  "Key sequence for opening the context menu at point.")
(defconst bind/doc-toolbar "C-c T"
  "Key sequence for toggling the global toolbar.")
(defconst bind/theme-preview "C-c M-t"
  "Key sequence for previewing and selecting an installed theme.")
(defconst bind/theme-gallery "C-c M-T"
  "Key sequence for installing a theme from EmacsThemes.")

;;;; Projects, sessions and the run/build panel

;; The run/build keys sit on the top F-key row, avoiding the ones the
;; IDE layer claims: <f5> run, <f6>/<S-f6>/<f7> tests, <f9> debug.
(defconst bind/project-run "<f2>"
  "Key sequence for running the project's run command.")
(defconst bind/project-build "<f3>"
  "Key sequence for running the project's build command.")
(defconst bind/project-command-switch "<f4>"
  "Key sequence for switching what run and build execute.")
(defconst bind/project-command-add "<f8>"
  "Key sequence for registering a new project command.")
(defconst bind/project-panel "C-c P"
  "Key sequence for toggling the project panel.")
(defconst bind/session-menu "C-c S"
  "Key sequence for opening the session menu.")

(defconst bind/compile "<f5>"
  "Key sequence for starting a compilation.")
(defconst bind/compilation-toggle "C-c b"
  "Key sequence for toggling the run/build panel.")
(defconst bind/compilation-toggle-fkey "<f12>"
  "Alternate key sequence for toggling the run/build panel.")

;;;; Bookmarks

;; Single-chord marks, like Vim's m, ]' and ['.  After M-] or M-[,
;; `repeat-mode' keeps plain ] and [ live, so hopping between bookmarks
;; costs one keypress ("," drops a bookmark mid-hop).
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

;;;; AI (gptel)

(defconst bind/ai-backend-menu "C-c m"
  "Key sequence for switching the gptel LLM backend.")

;;;; Shared IDE actions

;; Bound in `init/ide-mode-map' and therefore active in every language
;; buffer.  Each is at most two key events.
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

;;;; Language-specific actions

;; Extra commands with no generic equivalent, bound on top of the shared
;; IDE keymap in their own language buffers.
(defconst bind/ocaml-start-repl "C-c o u"
  "Key sequence for starting the OCaml REPL.")
(defconst bind/ocaml-build "C-c o b"
  "Key sequence for `dune build' in OCaml buffers.")
(defconst bind/ocaml-test "C-c o t"
  "Key sequence for `dune test' in OCaml buffers.")
(defconst bind/ocaml-debug "C-c o d"
  "Key sequence for starting the OCaml debugger.")
(defconst bind/ocaml-help "C-c o ?"
  "Key sequence for the OCaml cheatsheet.")

(defconst bind/jvm-build-task "C-c j t"
  "Key sequence for running an arbitrary build tool task.
Gradle in Kotlin and Java buffers, sbt or mill in Scala ones.")
(defconst bind/jvm-help "C-c j ?"
  "Key sequence for the cheatsheet of the JVM language being edited.")

;; Metals answers questions no other server here does, so Scala carries a
;; few commands of its own under the same JVM prefix.
(defconst bind/scala-new-project "C-c j n"
  "Key sequence for creating a new Scala project.
Also reachable as `M-x init/scala-new-project', since the first project
on a machine is made from a buffer that is not yet a Scala one.")
(defconst bind/scala-build "C-c j b"
  "Key sequence for compiling a Scala build, tests included.")
(defconst bind/scala-import-build "C-c j i"
  "Key sequence for re-importing the Scala build into Metals.")
(defconst bind/scala-restart-build "C-c j R"
  "Key sequence for restarting the build server Metals compiles through.")
(defconst bind/scala-clean-compile "C-c j c"
  "Key sequence for recompiling the Scala build from scratch.")
(defconst bind/scala-cascade-compile "C-c j C"
  "Key sequence for compiling this file and its dependents.")
(defconst bind/scala-doctor "C-c j d"
  "Key sequence for the Metals Doctor report.")
(defconst bind/scala-organize-imports "C-c j o"
  "Key sequence for sorting and pruning the Scala import list.")
(defconst bind/scala-goto-super "C-c j u"
  "Key sequence for jumping to the method this one overrides.")

(defconst bind/nim-mark-token "C-M-SPC"
  "Key sequence for marking the Nim token at point.")
(defconst bind/nim-doc-search "C-c n n"
  "Key sequence for searching the Nim documentation index.")
(defconst bind/nim-doc-at-point "C-c n d"
  "Key sequence for opening docs for the Nim symbol at point.")
(defconst bind/nim-doc-module "C-c n m"
  "Key sequence for opening a Nim module's documentation page.")
(defconst bind/nim-doc-home "C-c n h"
  "Key sequence for opening the Nim standard library overview.")

(provide 'init-keys)
;;; init-keys.el ends here
