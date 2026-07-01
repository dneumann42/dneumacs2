;;; keybindings.el --- Keybindings -*- lexical-binding: t; -*-

(defconst bind/avy-goto-char "C-:")
(defconst bind/ocaml-start-repl "C-c o u")

;; Editor
(defconst bind/toggle-frame-transparency "C-c t")
(defconst bind/toggle-menu-bar "C-c M")
(defconst bind/reload-config "C-c r")
(defconst bind/compilation-toggle "C-c c")
(defconst bind/compile "<f5>")
(defconst bind/forward-paragraph "M-n")
(defconst bind/backward-paragraph "M-p")
(defconst bind/repeat "C-x z")

;; Language IDE actions: at most two key events each.
(defconst bind/ide-run "<f5>")
(defconst bind/ide-test-at-point "<f6>")
(defconst bind/ide-test-file "<S-f6>")
(defconst bind/ide-test-project "<f7>")
(defconst bind/ide-actions "M-RET")
(defconst bind/ide-hover "C-c h")
(defconst bind/ide-diagnostics "C-c d")
(defconst bind/ide-reconnect "C-c r")
(defconst bind/ide-format "C-c f")
(defconst bind/ide-fix "C-c x")
(defconst bind/ide-repl "C-c z")
(defconst bind/ide-sync "C-c s")

(provide 'keybindings)
;;; keybindings.el ends here
