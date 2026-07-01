;;; init-org.el --- Org mode configuration -*- lexical-binding: t; -*-

;; Org itself is deferred: the use-package block below autoloads it on
;; the first Org buffer, agenda, or capture.  Everything at top level
;; here must work without Org loaded.

;;;; Writerly font (EB Garamond), applied only in Org buffers

;; Installs like the Cascadia flow in editor.el: probe for the family,
;; offer to download it into ~/.local/share/fonts on first use.
;; EB Garamond (SIL OFL) is a revival of Claude Garamont's 16th-century
;; types -- an elegant, bookish serif that makes Org read like a page.

(defconst init/org-writer-font-family "EB Garamond"
  "Preferred writer font family for Org buffers.")

(defconst init/org-writer-font-families
  '("EB Garamond" "EBGaramond")
  "Family names to probe for an installed EB Garamond font.")

(defconst init/org-writer-font-files
  (let ((base "https://raw.githubusercontent.com/octaviopardo/EBGaramond12/master/fonts/ttf/"))
    (mapcar (lambda (file) (cons file (concat base file)))
            ;; SemiBold included: the Org heading faces use semi-bold.
            '("EBGaramond-Regular.ttf"
              "EBGaramond-Italic.ttf"
              "EBGaramond-Bold.ttf"
              "EBGaramond-BoldItalic.ttf"
              "EBGaramond-SemiBold.ttf"
              "EBGaramond-SemiBoldItalic.ttf")))
  "Font files to download for the Org writer font, as (FILE . URL).")

(defvar init/org-writer-font-asked nil
  "Non-nil once the user has been asked to install the writer font.")

(defun init/org-writer-font-installed-p ()
  "Return non-nil when the writer font files are present on disk."
  (file-expand-wildcards
   (expand-file-name "EBGaramond*.ttf" "~/.local/share/fonts/")))

(defun init/org-install-writer-font ()
  "Download EB Garamond into the user font directory."
  (let ((font-dir (expand-file-name "~/.local/share/fonts/")))
    (make-directory font-dir t)
    (dolist (entry init/org-writer-font-files)
      (let ((target (expand-file-name (car entry) font-dir)))
        (unless (zerop (call-process "curl" nil nil nil
                                     "-L" "--fail" "--silent" "--show-error"
                                     "--output" target (cdr entry)))
          (error "Failed to download %s" (car entry)))))
    (init/reset-font-cache)
    t))

(defun init/org-ensure-writer-font ()
  "Return an available writer font family, offering to install one.
Mirrors the Cascadia install flow: on Linux, ask once per session and
download into ~/.local/share/fonts.  Returns nil when unavailable."
  (or (init/font-available-p init/org-writer-font-families)
      (and (init/org-writer-font-installed-p)
           init/org-writer-font-family)
      (when (and (eq system-type 'gnu/linux)
                 (display-graphic-p)
                 (not init/org-writer-font-asked))
        (setq init/org-writer-font-asked t)
        (when (y-or-n-p "EB Garamond (Org writing font) is missing. Download and install it? ")
          (condition-case err
              (progn
                (init/org-install-writer-font)
                (or (init/font-available-p init/org-writer-font-families)
                    init/org-writer-font-family))
            (error
             (message "Writer font install failed: %s"
                      (error-message-string err))
             nil))))))

(defvar-local init/org--writer-font-remap nil
  "Face-remap cookie for the writer font in the current Org buffer.")

(defun init/org-writer-font-setup ()
  "Use the writerly font and comfortable spacing in this Org buffer only.
Code blocks, tables and metadata stay fixed-pitch via the face setup in
the org :config block."
  (when-let ((family (init/org-ensure-writer-font)))
    (setq init/org--writer-font-remap
          ;; Garamond has a small x-height; render it larger so body
          ;; text sits comfortably next to the monospace UI.
          (face-remap-add-relative 'variable-pitch
                                   :family family
                                   :height 1.3)))
  (variable-pitch-mode 1)
  (setq-local line-spacing 0.15))

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
  :hook ((org-mode . init/org-enable-parent-cookie-tracking)
         (org-mode . init/org-writer-font-setup))
  :bind (("C-c a" . org-agenda)
         ("C-c c" . org-capture)
         ("C-c j" . init/org-goto-journal)
         ("C-c l" . org-store-link))
  :custom
  (org-directory "~/.org")
  ;; Scan the whole org directory for TODOs, SCHEDULED and DEADLINE items.
  (org-agenda-files (list "~/.org"))
  ;; Record a timestamp when a task is marked DONE.
  (org-log-done 'time)
  ;; Start the agenda on the current day and show one week.
  (org-agenda-start-on-weekday nil)
  (org-agenda-span 'week)
  ;; Prose-friendly display; org-modern draws the decorations.
  (org-hide-emphasis-markers t)
  (org-pretty-entities t)
  (org-ellipsis "…")
  (org-auto-align-tags nil)
  (org-tags-column 0)
  (org-agenda-tags-column 0)
  ;; File names below are relative to `org-directory'.  The journal is a
  ;; single entry per day, so it is edited via `init/org-goto-journal'
  ;; rather than captured (capture always appends a new item).
  (org-capture-templates
   '(("t" "TODO (inbox)" entry
      (file+headline "tasks.org" "Inbox")
      "* TODO %?\n%U"
      :empty-lines 1)
     ("s" "Scheduled TODO" entry
      (file+headline "tasks.org" "Inbox")
      "* TODO %?\nSCHEDULED: %^{Schedule}t\n%U"
      :empty-lines 1)))
  :config
  ;; Load the agenda now so its keymap exists for menus and cheatsheets.
  (require 'org-agenda)
  (init/org-set-heading-faces)
  ;; Keep the technical parts of Org buffers monospaced so source
  ;; blocks, tables and metadata line up under variable-pitch-mode.
  (dolist (spec '((org-block . fixed-pitch)
                  (org-table . fixed-pitch)
                  (org-checkbox . fixed-pitch)
                  (org-formula . fixed-pitch)
                  (org-date . fixed-pitch)
                  (org-code . (shadow fixed-pitch))
                  (org-verbatim . (shadow fixed-pitch))
                  (org-meta-line . (font-lock-comment-face fixed-pitch))
                  (org-special-keyword . (font-lock-comment-face fixed-pitch))
                  (org-document-info-keyword . (shadow fixed-pitch))))
    (set-face-attribute (car spec) nil :inherit (cdr spec)))
  (add-hook 'org-after-todo-state-change-hook
            #'init/org-add-cookie-to-todo-parent)
  (add-hook 'org-after-todo-statistics-hook #'org-summary-todo))

;;;; Agenda menu

(defun init/org-goto-journal (&optional arg)
  "Visit today's entry in the journal datetree, creating it if needed.
Point is left at the end of that day's entry so you keep a single entry
per day and just keep writing.  With a prefix ARG, prompt for a
different date instead of using today."
  (interactive "P")
  (require 'org-datetree)
  (find-file (expand-file-name "journal.org" org-directory))
  (org-datetree-find-date-create
   (if arg
       (let ((time (org-read-date nil t nil "Journal date")))
         (list (nth 4 (decode-time time))
               (nth 3 (decode-time time))
               (nth 5 (decode-time time))))
     (calendar-current-date)))
  (when (fboundp 'org-fold-show-entry) (org-fold-show-entry))
  (org-end-of-subtree)
  (unless (bolp) (insert "\n")))

(defun init/org-capture-todo ()
  "Capture a new TODO into the inbox."
  (interactive)
  (org-capture nil "t"))

(easy-menu-define init/agenda-menu global-map
  "Agenda and capture actions."
  '("Agenda"
    ["Open agenda dispatcher..." org-agenda t]
    ["This week's agenda" org-agenda-list t]
    ["Global TODO list" org-todo-list t]
    "---"
    ["Open today's journal" init/org-goto-journal t]
    ["Capture..." org-capture t]
    ["New TODO" init/org-capture-todo t]
    "---"
    ["Schedule heading at point" org-schedule
     :active (derived-mode-p 'org-mode)]
    ["Set deadline on heading" org-deadline
     :active (derived-mode-p 'org-mode)]))

;; Modern Org styling: heading bullets, todo badges, tag pills, styled
;; tables, checkboxes and timestamps.  Replaces org-superstar.
(use-package org-modern
  :hook ((org-mode . org-modern-mode)
         (org-agenda-finalize . org-modern-agenda))
  :custom
  (org-modern-star 'replace)
  (org-modern-replace-stars "◉○✸✿◆◇▶▷")
  (org-modern-table t)
  (org-modern-keyword t)
  (org-modern-checkbox '((?X . "☑") (?- . "◩") (?\s . "☐")))
  (org-modern-list '((?- . "•") (?+ . "◦") (?* . "▹"))))

(provide 'init-org)
;;; init-org.el ends here
