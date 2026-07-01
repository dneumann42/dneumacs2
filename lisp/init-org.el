;;; init-org.el --- Org mode configuration -*- lexical-binding: t; -*-

(require 'org)

(defvar-local init/org--adding-parent-cookie nil
  "Non-nil while adding a TODO statistics cookie to a parent heading.")

(defconst init/org-statistics-cookie-regexp
  "\\[[0-9]*\\(?:%\\|/[0-9]*\\)\\]"
  "Regexp matching an Org TODO statistics cookie, including `[/]'.")

(defun init/org-add-cookie-to-todo-parent ()
  "Add `[/]' to the TODO parent of the TODO heading at point.

Do nothing when either heading is not a TODO item or the parent already
has a statistics cookie."
  (when (and (derived-mode-p 'org-mode)
             (not init/org--adding-parent-cookie))
    (save-excursion
      (when (and (org-at-heading-p)
                 (org-get-todo-state)
                 (org-up-heading-safe)
                 (org-get-todo-state))
        (let ((title (org-get-heading t t t t)))
          (unless (string-match-p init/org-statistics-cookie-regexp title)
            (let ((init/org--adding-parent-cookie t)
                  (inhibit-modification-hooks t))
              (org-edit-headline (concat title " [/]"))
              (org-update-statistics-cookies nil))))))))

(defun init/org-add-parent-cookie-after-command ()
  "Check the heading at point for a manually typed TODO keyword."
  (save-excursion
    (beginning-of-line)
    (when (org-at-heading-p)
      (init/org-add-cookie-to-todo-parent))))

(defun init/org-enable-parent-cookie-tracking ()
  "Track manually typed TODO keywords in the current Org buffer."
  (add-hook 'post-command-hook
            #'init/org-add-parent-cookie-after-command nil t))

(defun org-summary-todo (n-done n-not-done)
  "Switch entry to DONE when all subentries are done, to TODO otherwise."
  (let (org-log-done org-todo-log-states)
    (org-todo (if (= n-not-done 0) "DONE" "TODO"))))

(defun init/org-set-heading-faces ()
  "Set the font scale for Org document titles and heading levels."
  (set-face-attribute 'org-document-title nil :height 1.8 :weight 'bold)
  (dolist (face-height '((org-level-1 . 1.45)
                         (org-level-2 . 1.35)
                         (org-level-3 . 1.25)
                         (org-level-4 . 1.15)
                         (org-level-5 . 1.10)
                         (org-level-6 . 1.05)
                         (org-level-7 . 1.00)
                         (org-level-8 . 1.00)))
    (set-face-attribute (car face-height) nil
                        :height (cdr face-height)
                        :weight 'semi-bold)))

(use-package org
  :ensure nil
  :hook (org-mode . init/org-enable-parent-cookie-tracking)
  :config
  (init/org-set-heading-faces)
  (add-hook 'org-after-todo-state-change-hook
            #'init/org-add-cookie-to-todo-parent)
  (add-hook 'org-after-todo-statistics-hook #'org-summary-todo))

(use-package org-superstar
  :hook (org-mode . org-superstar-mode)
  :custom
  (org-superstar-headline-bullets-list '(?◉ ?○ ?✸ ?✿ ?◆ ?◇ ?▶ ?▷))
  (org-superstar-special-todo-items t)
  (org-superstar-remove-leading-stars t))

(provide 'init-org)
;;; init-org.el ends here
