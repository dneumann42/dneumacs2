;;; project-tools.el --- Project tooling -*- lexical-binding: t; -*-

(use-package projectile
  :ensure t
  :config
  (projectile-mode +1)
  (define-key projectile-mode-map (kbd "s-p") 'projectile-command-map)
  (define-key projectile-mode-map (kbd "C-c p") 'projectile-command-map))

(require 'transient)
(require 'grep)

(declare-function consult-ripgrep "consult")
(declare-function projectile-project-root "projectile")
(declare-function project-root "project")
(defvar consult--grep-history)

(defun init/project-root ()
  "Return the current project root, or `default-directory'."
  (or (and (fboundp 'projectile-project-root) (projectile-project-root))
      (when-let ((proj (project-current))) (project-root proj))
      default-directory))

(defun init/project-search-live ()
  "Search the project incrementally, results updating as you type."
  (interactive)
  (consult-ripgrep (init/project-root)))

(defun init/project-search-repeat ()
  "Pick one of the previous searches and run it again live."
  (interactive)
  (unless consult--grep-history
    (user-error "No previous searches yet"))
  (consult-ripgrep (init/project-root)
                   (completing-read "Repeat search: " consult--grep-history
                                    nil nil nil 'consult--grep-history)))

(defun init/project-search-buffer (term)
  "Search the project for TERM, keeping every match in its own buffer.
The result is a `grep-mode' buffer named after TERM; it persists until you
kill it, and `g' re-runs the same search."
  (interactive
   (list (read-string "Search project (pinned buffer): "
                      (thing-at-point 'symbol t) 'consult--grep-history)))
  (let ((default-directory (init/project-root)))
    (grep (format "rg --line-number --with-filename --no-heading --color=never --smart-case -e %s ."
                  (shell-quote-argument term))))
  (when-let ((buf (get-buffer "*grep*")))
    (with-current-buffer buf
      (rename-buffer (format "*search: %s*" term) t))))

(transient-define-prefix init/project-search ()
  "Project search."
  ["Project search"
   ("s" "Search live (results as you type)" init/project-search-live)
   ("r" "Repeat a previous search"          init/project-search-repeat)
   ("b" "Search into a pinned buffer"       init/project-search-buffer)])

(provide 'project-tools)
;;; project-tools.el ends here
