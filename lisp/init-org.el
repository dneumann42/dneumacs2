;;; init-org.el --- Org mode -*- lexical-binding: t; -*-

;;; Commentary:

;; Org configured as a place to write rather than a place to program:
;; prose is set in the writer font at a comfortable measure, while code
;; blocks, tables and metadata stay monospaced so they still line up.
;;
;; On top of the usual capture and agenda setup there are four additions:
;;
;;   * a daily journal that is edited rather than captured, so each day
;;     has exactly one entry (`init/org-goto-journal');
;;   * automatic `[/]' statistics cookies on TODO parents, added the
;;     moment a child TODO appears beneath one;
;;   * local `<<target>>' references that behave like code: M-. jumps
;;     through the xref stack, and hovering or C-c C-. shows the target
;;     in a popup without leaving the line;
;;   * headline tags drawn as rounded pills, floated flush to the right
;;     window edge.
;;
;; Org itself is deferred: the `use-package' block below autoloads it on
;; the first Org buffer, agenda or capture, so everything at top level
;; here has to work without Org loaded.

;;; Code:

(require 'seq)
(require 'subr-x)
(require 'init-lib)
(require 'init-org-sync)
(require 'init-theme)

(declare-function calendar-current-date "calendar")
(declare-function org-at-heading-p "org")
(declare-function org-datetree-find-date-create "org-datetree")
(declare-function org-edit-headline "org")
(declare-function org-element-context "org-element")
(declare-function org-element-property "org-element-ast")
(declare-function org-element-type "org-element-ast")
(declare-function org-end-of-subtree "org")
(declare-function org-fold-show-entry "org-fold")
(declare-function org-get-heading "org")
(declare-function org-get-todo-state "org")
(declare-function org-link-search "ol")
(declare-function org-narrow-to-subtree "org")
(declare-function org-open-at-point "org")
(declare-function org-read-date "org")
(declare-function org-todo "org")
(declare-function org-up-heading-safe "org")
(declare-function org-update-statistics-cookies "org")
(defvar org-babel-load-languages)
(defvar org-directory)
(defvar org-log-done)
(defvar org-mode-map)
(defvar org-src-block-faces)
(defvar org-src-fontify-natively)
(defvar org-todo-log-states)

;;;; Prose typography

(defconst init/org-writer-font-height 1.3
  "Relative height of Org prose in the writer font.")

(defconst init/org-fixed-pitch-font-height 1.0
  "Relative height of fixed-pitch regions in Org buffers.")

(defvar-local init/org--writer-font-remap nil
  "Face-remap cookie for the writer font in the current Org buffer.")

(defvar-local init/org--fixed-pitch-font-remap nil
  "Face-remap cookie for scaled fixed-pitch regions in Org buffers.")

(defvar-local init/org--source-font-lock-remaps nil
  "Face-remap cookies keeping source block syntax faces fixed-pitch.")

(defun init/org--text-scale-factor ()
  "Return the current buffer's text scale multiplier."
  (expt (if (boundp 'text-scale-mode-step) text-scale-mode-step 1.2)
        (if (boundp 'text-scale-mode-amount) text-scale-mode-amount 0)))

(defun init/org--refresh-fixed-pitch-remap ()
  "Keep fixed-pitch Org regions in step with the prose scaling."
  (when (derived-mode-p 'org-mode)
    (when init/org--fixed-pitch-font-remap
      (face-remap-remove-relative init/org--fixed-pitch-font-remap))
    (setq init/org--fixed-pitch-font-remap
          (face-remap-add-relative
           'fixed-pitch
           :height (* init/org-fixed-pitch-font-height
                      (init/org--text-scale-factor))))))

(defun init/org--refresh-after-text-scale (&rest _)
  "Refresh the Org font remaps and layout after a text-scale change."
  (when (derived-mode-p 'org-mode)
    (init/org--refresh-fixed-pitch-remap)
    ;; Floated tags carry a pixel width measured at fontification time.
    (font-lock-flush)
    (redisplay t)))

(defun init/org-writer-font-setup ()
  "Use the writer font and comfortable spacing in this Org buffer.
Code blocks, tables and metadata stay fixed-pitch through the face setup
in the `org' :config block."
  (when-let ((family (init/ensure-writer-font)))
    (setq init/org--writer-font-remap
          ;; Garamond has a small x-height; render it larger so body text
          ;; sits comfortably next to the monospace UI.
          (face-remap-add-relative 'variable-pitch
                                   :family family
                                   :height init/org-writer-font-height)))
  (init/org--refresh-fixed-pitch-remap)
  (variable-pitch-mode 1)
  (setq-local line-spacing 0.15))

(defun init/org-line-wrap-setup ()
  "Soft-wrap Org prose at the window edge, on word boundaries."
  (visual-line-mode 1))

(defun init/org-default-directory-setup ()
  "Keep Org file prompts anchored in `org-directory'.
This also covers Org popup buffers, which otherwise inherit whatever
temporary directory was current when they were created."
  (when (and (boundp 'org-directory)
             org-directory
             (file-directory-p org-directory)
             (or (not buffer-file-name)
                 (file-in-directory-p buffer-file-name org-directory)))
    (setq-local default-directory
                (file-name-as-directory (expand-file-name org-directory)))))

(defun init/org-set-heading-faces ()
  "Set the font scale for Org document titles and heading levels."
  (set-face-attribute 'org-document-title nil :height 1.8 :weight 'bold)
  (dolist (spec '((org-level-1 . 1.45)
                  (org-level-2 . 1.35)
                  (org-level-3 . 1.25)
                  (org-level-4 . 1.15)
                  (org-level-5 . 1.10)
                  (org-level-6 . 1.05)
                  (org-level-7 . 1.00)
                  (org-level-8 . 1.00)))
    (set-face-attribute (car spec) nil
                        :height (cdr spec)
                        :weight 'semi-bold)))

(defconst init/org-fixed-pitch-faces
  '((org-block . fixed-pitch)
    (org-inline-src-block . fixed-pitch)
    (org-table . fixed-pitch)
    (org-checkbox . fixed-pitch)
    (org-formula . fixed-pitch)
    (org-date . fixed-pitch)
    (org-code . (shadow fixed-pitch))
    (org-verbatim . (shadow fixed-pitch))
    (org-meta-line . (font-lock-comment-face fixed-pitch))
    (org-special-keyword . (font-lock-comment-face fixed-pitch))
    (org-document-info-keyword . (shadow fixed-pitch)))
  "Org faces kept monospaced under `variable-pitch-mode'.
Source blocks, tables and metadata only line up in a fixed-pitch font.")

(defconst init/org-source-font-lock-faces
  '(font-lock-builtin-face
    font-lock-comment-face
    font-lock-comment-delimiter-face
    font-lock-constant-face
    font-lock-doc-face
    font-lock-doc-markup-face
    font-lock-function-call-face
    font-lock-function-name-face
    font-lock-keyword-face
    font-lock-negation-char-face
    font-lock-number-face
    font-lock-operator-face
    font-lock-preprocessor-face
    font-lock-property-name-face
    font-lock-property-use-face
    font-lock-punctuation-face
    font-lock-regexp-grouping-backslash
    font-lock-regexp-grouping-construct
    font-lock-string-face
    font-lock-type-face
    font-lock-variable-name-face
    font-lock-variable-use-face
    font-lock-warning-face)
  "Syntax faces remapped to fixed-pitch inside Org buffers.")

(defun init/org-set-fixed-pitch-faces (&rest _)
  "Keep the technical parts of Org buffers monospaced."
  (dolist (spec init/org-fixed-pitch-faces)
    (set-face-attribute (car spec) nil :inherit (cdr spec))))

(defun init/org--remap-source-font-lock-faces ()
  "Keep natively fontified source-block faces monospaced in this Org buffer."
  (mapc #'face-remap-remove-relative init/org--source-font-lock-remaps)
  (setq init/org--source-font-lock-remaps
        (delq nil
              (mapcar (lambda (face)
                        (when (facep face)
                          (face-remap-add-relative face 'fixed-pitch)))
                      init/org-source-font-lock-faces))))

(defun init/org-source-block-display-setup ()
  "Keep Org source blocks monospaced and fully fontified."
  (setq-local org-src-fontify-natively t
              org-src-block-faces '((".*" (:inherit fixed-pitch)))
              jit-lock-chunk-size nil)
  (init/org--remap-source-font-lock-faces)
  (font-lock-flush)
  (font-lock-ensure))

;;;; Striped tables

(defface init/org-table-header
  '((default :inherit org-table :weight bold :extend t)
    (((background light))
     :background "#dfeaf7" :foreground "#172033" :overline "#9fb9d8")
    (t
     :background "#151f2a" :foreground "#d8ecff" :overline "#3d6f94"))
  "Face used for Org table header rows."
  :group 'org)

(defface init/org-table-stripe
  '((default :inherit org-table :extend t)
    (((background light)) :background "#f3f6fa")
    (t :background "#0b0f14"))
  "Face used for alternating Org table body rows."
  :group 'org)

(defun init/org--table-separator-line-p ()
  "Return non-nil when the current line is an Org table separator."
  (save-excursion
    (back-to-indentation)
    (looking-at-p "|[-+]+|?[ \t]*$")))

(defun init/org--table-line-p ()
  "Return non-nil when the current line is an Org table row."
  (save-excursion
    (back-to-indentation)
    (looking-at-p "|.*|[ \t]*$")))

(defun init/org--table-body-row-index ()
  "Return the zero-based body row index of the current Org table row.
Return nil when the row is above the table's header separator."
  (let ((target (line-beginning-position))
        (seen-separator nil)
        (row-index 0))
    (save-excursion
      (while (and (= 0 (forward-line -1)) (init/org--table-line-p)))
      (unless (init/org--table-line-p)
        (forward-line 1))
      (while (< (line-beginning-position) target)
        (if (init/org--table-separator-line-p)
            (setq seen-separator t)
          (when seen-separator
            (setq row-index (1+ row-index))))
        (forward-line 1)))
    (when seen-separator row-index)))

(defun init/org-table-row-face ()
  "Return the display face for the Org table row at point, or nil."
  (save-excursion
    (beginning-of-line)
    (cond
     ((init/org--table-separator-line-p) nil)
     ((save-excursion
        (and (= 0 (forward-line 1)) (init/org--table-separator-line-p)))
      'init/org-table-header)
     ((let ((row-index (init/org--table-body-row-index)))
        (and row-index (= 1 (% row-index 2))))
      'init/org-table-stripe))))

;;;; Statistics cookies on TODO parents

(defconst init/org-statistics-cookie-regexp
  "\\[[0-9]*\\(?:%\\|/[0-9]*\\)\\]"
  "Regexp matching an Org TODO statistics cookie, `[/]' included.")

(defvar-local init/org--adding-parent-cookie nil
  "Non-nil while adding a statistics cookie, to prevent re-entry.")

(defun init/org-add-cookie-to-todo-parent ()
  "Add `[/]' to the TODO parent of the TODO heading at point.
Does nothing when either heading is not a TODO item, or the parent
already has a statistics cookie."
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

(defun init/org-summary-todo (_n-done n-not-done)
  "Switch an entry to DONE when all N-NOT-DONE subentries are done.
Used as an `org-after-todo-statistics-hook' function."
  (let ((org-log-done nil)
        (org-todo-log-states nil))
    (org-todo (if (= n-not-done 0) "DONE" "TODO"))))

;;;; Journal and capture

(defun init/org--journal-date (prompt)
  "Return the datetree date list to visit.
With PROMPT non-nil, ask for a date instead of using today."
  (if prompt
      (let ((time (org-read-date nil t nil "Journal date")))
        (list (nth 4 (decode-time time))
              (nth 3 (decode-time time))
              (nth 5 (decode-time time))))
    (calendar-current-date)))

(defun init/org-goto-journal (&optional arg)
  "Visit today's entry in the journal datetree, creating it if needed.
Point is left at the end of that day's entry, so there is one entry per
day that you simply keep writing.  With a prefix ARG, prompt for a
different date."
  (interactive "P")
  (require 'org-datetree)
  (find-file (expand-file-name "journal.org" org-directory))
  (org-datetree-find-date-create (init/org--journal-date arg))
  (when (fboundp 'org-fold-show-entry) (org-fold-show-entry))
  (org-end-of-subtree)
  (unless (bolp) (insert "\n")))

(defun init/org-capture-todo ()
  "Capture a new TODO into the inbox."
  (interactive)
  (org-capture nil "t"))

(defun init/org-insert-src-block (language)
  "Insert an Org source block for LANGUAGE with useful defaults."
  (interactive
   (list (completing-read "Language: "
                          (delete-dups (mapcar #'car org-babel-load-languages))
                          nil nil nil nil "emacs-lisp")))
  (insert (format "#+begin_src %s :results value :exports both\n\n#+end_src"
                  language))
  (forward-line -1))

(defun init/org-find-file ()
  "Open one of the Org files below `org-directory', with completion."
  (interactive)
  (unless (and (boundp 'org-directory)
               org-directory
               (file-directory-p org-directory))
    (user-error "`org-directory' is not configured"))
  (let* ((root (file-name-as-directory (expand-file-name org-directory)))
         (files (directory-files-recursively root "\\.org\\(?:\\.gpg\\)?\\'"))
         (relative (mapcar (lambda (file) (file-relative-name file root)) files)))
    (find-file (expand-file-name (completing-read "Org file: " relative nil t)
                                 root))))

;;;; Local reference popups

;; A `<<target>>' or `#+CUSTOM_ID' reference behaves like a symbol in
;; code: M-. jumps to it through the xref marker stack, and hovering it
;; -- or C-c C-. -- shows the target's text in a popup, so a definition
;; can be read without leaving the line that mentions it.

(defconst init/org-reference-popup-buffer "*Org Reference*"
  "Buffer used for the Org reference popup.")

(defcustom init/org-reference-hover-delay 0.35
  "Idle delay before showing an Org reference popup under the mouse."
  :type 'number
  :group 'org)

(defvar init/org-reference--source-buffer nil
  "Org buffer that owns the visible reference popup.")

(defvar init/org-reference--source-point nil
  "Buffer position that opened the visible reference popup.")

(defvar init/org-reference--target nil
  "Org reference target shown in the visible popup.")

(defvar init/org-reference--trigger nil
  "How the visible Org reference popup was opened: `manual' or `hover'.")

(defvar init/org-reference--hover-timer nil
  "Idle timer showing Org reference popups on mouse hover.")

(defun init/org-reference--link-target (&optional position)
  "Return the local Org link target at POSITION, or at point."
  (save-excursion
    (when position (goto-char position))
    (let ((context (org-element-context)))
      (when (eq (org-element-type context) 'link)
        (let ((type (org-element-property :type context))
              (path (org-element-property :path context)))
          (when (and path (member type '("fuzzy" "custom-id")))
            path))))))

(defun init/org-reference--target-position (target)
  "Return the position of TARGET in the current Org buffer, or nil."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (cond
       ((re-search-forward (format "<<%s>>" (regexp-quote target)) nil t)
        (line-beginning-position))
       ((re-search-forward
         (format "^[[:space:]]*:CUSTOM_ID:[[:space:]]+%s[[:space:]]*$"
                 (regexp-quote target))
         nil t)
        (line-beginning-position))
       ((ignore-errors (org-link-search target) (point)))))))

(defun init/org-reference--content-end ()
  "Return the end of the reference content starting at point.
A heading contributes its subtree up to the first blank line; anything
else contributes up to the first blank line, or the end of its line."
  (save-excursion
    (if (org-at-heading-p)
        (save-restriction
          (org-narrow-to-subtree)
          (goto-char (point-min))
          (if (re-search-forward "^[[:space:]]*$" nil t)
              (line-beginning-position)
            (point-max)))
      (if (re-search-forward "^[[:space:]]*$" nil t)
          (line-beginning-position)
        (line-end-position)))))

(defun init/org-reference--content (target)
  "Return the display text for the local Org TARGET, or nil."
  (when-let ((position (init/org-reference--target-position target)))
    (save-excursion
      (save-restriction
        (widen)
        (goto-char position)
        (string-trim
         (replace-regexp-in-string
          (format "<<%s>>[[:space:]]*" (regexp-quote target))
          ""
          (buffer-substring-no-properties
           (point) (init/org-reference--content-end))))))))

(defun init/org-reference-popup-visible-p ()
  "Return non-nil when the Org reference popup is visible."
  (or init/org-reference--trigger
      (init/popup-visible-p init/org-reference-popup-buffer)))

(defun init/org-hide-reference-popup ()
  "Hide the Org reference popup."
  (interactive)
  (setq init/org-reference--source-buffer nil
        init/org-reference--source-point nil
        init/org-reference--target nil
        init/org-reference--trigger nil)
  (init/popup-hide init/org-reference-popup-buffer))

(defun init/org-reference--show (target trigger)
  "Show TARGET in a popup near point, opened by TRIGGER."
  (let ((content (or (init/org-reference--content target)
                     (user-error "No local reference found for %s" target))))
    (setq init/org-reference--source-buffer (current-buffer)
          init/org-reference--source-point (point)
          init/org-reference--target target
          init/org-reference--trigger trigger)
    (init/popup-show init/org-reference-popup-buffer content
                     :mode #'org-mode)))

(defun init/org-show-reference-popup ()
  "Show the Org reference linked at point in a popup near point."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Org reference popup is only available in Org buffers"))
  (init/org-reference--show
   (or (init/org-reference--link-target)
       (user-error "Point is not on a local Org reference link"))
   'manual))

(defun init/org-toggle-reference-popup ()
  "Toggle the Org reference popup for the local reference at point."
  (interactive)
  (if (and (init/org-reference-popup-visible-p)
           (eq init/org-reference--source-buffer (current-buffer))
           (= init/org-reference--source-point (point)))
      (init/org-hide-reference-popup)
    (init/org-show-reference-popup)))

(defun init/org-open-reference-with-xref ()
  "Open the local Org reference at point and push the xref marker stack."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Org reference navigation is only available in Org buffers"))
  (unless (init/org-reference--link-target)
    (user-error "Point is not on a local Org reference link"))
  (require 'xref)
  (xref-push-marker-stack)
  (org-open-at-point))

(defun init/org-reference-hide-on-point-move ()
  "Hide the Org reference popup once its source cursor moves away."
  (when (and init/org-reference--source-buffer
             (eq init/org-reference--source-buffer (current-buffer))
             init/org-reference--source-point
             (/= init/org-reference--source-point (point)))
    (init/org-hide-reference-popup)))

(defun init/org-reference--mouse-position ()
  "Return (BUFFER . POSITION) under the mouse pointer, or nil."
  (pcase-let ((`(,frame ,x . ,y) (mouse-pixel-position)))
    (when (and (frame-live-p frame) (integerp x) (integerp y))
      (let* ((posn (posn-at-x-y x y frame t))
             (window (and posn (posn-window posn)))
             (position (and posn (posn-point posn))))
        (when (and (window-live-p window) (integer-or-marker-p position))
          (cons (window-buffer window) position))))))

(defun init/org-reference--hover-hide ()
  "Hide the popup if it was opened by hovering."
  (when (eq init/org-reference--trigger 'hover)
    (init/org-hide-reference-popup)))

(defun init/org-reference--hover-stale-p (buffer position target)
  "Return non-nil when the visible popup does not already show TARGET.
BUFFER and POSITION are where the mouse now points."
  (or (not (eq init/org-reference--trigger 'hover))
      (not (eq init/org-reference--source-buffer buffer))
      (/= init/org-reference--source-point position)
      (not (equal init/org-reference--target target))))

(defun init/org-reference--hover-show (buffer position target)
  "Show TARGET for the link at POSITION in BUFFER, as a hover popup."
  (when-let ((window (get-buffer-window buffer t)))
    (save-selected-window
      (select-window window)
      (save-excursion
        (goto-char position)
        (init/org-reference--show target 'hover)))))

(defun init/org-reference-hover-check ()
  "Show or hide the Org reference popup for the link under the mouse."
  (pcase (init/org-reference--mouse-position)
    (`(,buffer . ,position)
     (if (not (buffer-live-p buffer))
         (init/org-reference--hover-hide)
       (with-current-buffer buffer
         (if (not (derived-mode-p 'org-mode))
             (init/org-reference--hover-hide)
           (let ((target (init/org-reference--link-target position)))
             (cond
              ((null target) (init/org-reference--hover-hide))
              ((init/org-reference--hover-stale-p buffer position target)
               (init/org-reference--hover-show buffer position target))))))))
    (_ (init/org-reference--hover-hide))))

(defun init/org-enable-reference-popups ()
  "Enable Org reference popup hiding and hover behaviour."
  (add-hook 'post-command-hook #'init/org-reference-hide-on-point-move nil t)
  (unless (timerp init/org-reference--hover-timer)
    (setq init/org-reference--hover-timer
          (run-with-idle-timer init/org-reference-hover-delay t
                               #'init/org-reference-hover-check))))

;;;; Org itself

(defconst init/org-text-scale-commands
  '(text-scale-adjust text-scale-increase text-scale-decrease text-scale-set)
  "Commands after which the Org layout has to be re-measured.")

(defun init/org--advise-text-scale-commands ()
  "Refresh the Org layout after every text-scale command."
  (dolist (command init/org-text-scale-commands)
    (unless (advice-member-p #'init/org--refresh-after-text-scale command)
      (advice-add command :after #'init/org--refresh-after-text-scale))))

(use-package org
  :ensure nil
  :hook ((org-mode . init/org-enable-parent-cookie-tracking)
         (org-mode . init/org-writer-font-setup)
         (org-mode . init/org-default-directory-setup)
         (org-mode . init/org-line-wrap-setup)
         (org-mode . init/org-source-block-display-setup)
         (org-mode . init/org-enable-reference-popups))
  :bind (("C-c a" . org-agenda)
         ("C-c c" . org-capture)
         ("C-c j" . init/org-goto-journal)
         ("C-c l" . org-store-link)
         :map org-mode-map
         ("C-c b" . init/org-insert-src-block)
         ("C-c C-." . init/org-toggle-reference-popup)
         ("M-." . init/org-open-reference-with-xref)
         ("M-," . xref-go-back))
  :custom
  (org-directory init/org-sync-directory)
  ;; Org loads every module listed here the first time an Org buffer opens,
  ;; and the default list drags in Gnus, MH-E, Rmail, BBDB, w3m, DocView and
  ;; BibTeX to provide link types for mail and browsers this setup does not
  ;; use.  That is 415ms of the 450ms `org-mode' spends on its first buffer,
  ;; and a session that restores an Org file pays it during startup.  `ol-doi'
  ;; and `ol-info' are cheap and keep doi: and info: links working.
  (org-modules '(ol-doi ol-info))
  ;; Scan the whole Org directory for TODOs, SCHEDULED and DEADLINE items.
  (org-agenda-files (list init/org-sync-directory))
  (org-log-done 'time)
  ;; Start the agenda on the current day and show one week.
  (org-agenda-start-on-weekday nil)
  (org-agenda-span 'week)
  ;; Prose-friendly display; org-modern draws the decorations.
  (org-hide-emphasis-markers t)
  (org-hide-leading-stars nil)
  (org-pretty-entities t)
  (org-ellipsis "…")
  ;; Tags are floated by `init/org--tag-float', not padded with spaces:
  ;; column padding never lines up under a proportional font.
  (org-auto-align-tags nil)
  (org-tags-column 0)
  (org-agenda-tags-column 0)
  (org-src-preserve-indentation t)
  (org-edit-src-content-indentation 0)
  ;; Paths are relative to `org-directory'.  The journal is one entry per
  ;; day, so it is edited through `init/org-goto-journal' rather than
  ;; captured -- capture always appends a new item.
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
  ;; Load the agenda now, so its keymap exists for the menus and
  ;; cheatsheets that look bindings up live.
  (require 'org-agenda)
  (init/org-set-heading-faces)
  (init/org-set-fixed-pitch-faces)
  (add-hook 'enable-theme-functions #'init/org-set-fixed-pitch-faces)
  (set-face-attribute 'org-level-1 nil :underline t)
  (font-lock-add-keywords
   'org-mode
   '(("^[ \t]*\\(|.*|\\)[ \t]*$" 0 (init/org-table-row-face) append))
   'append)
  (init/org--advise-text-scale-commands)
  (add-hook 'org-after-todo-state-change-hook #'init/org-add-cookie-to-todo-parent)
  (add-hook 'org-after-todo-statistics-hook #'init/org-summary-todo))

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

;;;; Tag pills

;; Two things happen to headline tags here.
;;
;; They are floated.  Org is told not to pad tags with real spaces, so the
;; single space it leaves before them is stretched to a measured pixel
;; width instead; the labels then sit flush against the right window edge
;; at any window width, font or text scale.
;;
;; And they are rounded.  Each label is replaced by a small SVG image of a
;; rounded rectangle with the tag inside.  Round ends cannot be had from a
;; face, because Emacs paints a face background over the full height of
;; the screen line -- which is why org-modern's own labels are as tall as
;; the headline they sit on -- and only an image can be both shorter than
;; the line and round.  Everything about the image is derived from the
;; face and the fixed-pitch font, so pills follow the theme and the text
;; scale.

(defface init/org-tag
  '((default :inherit org-modern-label)
    (((background light)) :background "#ece0ea" :foreground "#4a3446")
    (t :background "#3b2a35" :foreground "#e3c3d4"))
  "Face used for Org tag pills."
  :group 'org)

(defcustom init/org-tag-round t
  "Non-nil draws Org tag labels as rounded pills.
Needs a graphical frame with SVG support; org-modern's plain labels are
used otherwise."
  :type 'boolean
  :group 'org)

(defcustom init/org-tag-float t
  "Non-nil floats headline tags against the right window edge."
  :type 'boolean
  :group 'org)

(defcustom init/org-tag-right-margin 3.0
  "Gap kept to the right of floated tags, in default character widths.
The gap has to hold the fold ellipsis, which Org draws after the tags of
a folded headline; in the writer font that is a little over two
characters wide at the largest heading scale, and the headline wraps if
it does not fit."
  :type 'number
  :group 'org)

(defconst init/org-tag-pill-scale 0.8
  "Pill text size relative to the fixed-pitch font.
Matches the `org-modern-label' height, so a pill is lettered at the same
size as the TODO label beside it.")

(defconst init/org-tag-pill-padding 0.6
  "Padding at each end of a pill, in pill character widths.")

(defvar init/org--tag-image-cache (make-hash-table :test #'equal)
  "Rendered tag pills, keyed by label, colours and font metrics.")

(defvar init/org--tag-metrics-cache nil
  "Last measured pill font, as (KEY . METRICS).  See `init/org--tag-metrics'.")

(defun init/org--face-attribute (face attribute)
  "Return ATTRIBUTE as specified by FACE, or nil.
FACE is a face name, an attribute plist, or a list of either, as found in
the `face' text property."
  (cond
   ((keywordp (car-safe face)) (plist-get face attribute))
   ((consp face)
    (seq-some (lambda (one) (init/org--face-attribute one attribute)) face))
   ((and (symbolp face) (facep face))
    (let ((value (face-attribute face attribute nil t)))
      (unless (memq value '(nil unspecified)) value)))))

(defun init/org--tag-metrics ()
  "Return the pill font as (FAMILY SIZE ADVANCE ASCENT DESCENT), or nil.
SIZE, ADVANCE, ASCENT and DESCENT are in pixels.  The fixed-pitch font is
used, so a pill is exactly as wide as its label plus padding and scales
with the buffer like the rest of the Org text."
  (let* ((scale (init/org--text-scale-factor))
         (key (list (frame-char-height) (frame-char-width) scale)))
    (unless (equal (car init/org--tag-metrics-cache) key)
      (setq init/org--tag-metrics-cache
            (cons key
                  (ignore-errors
                    (let* ((family (face-attribute 'fixed-pitch :family nil t))
                           (pixels (aref (font-info (face-font 'fixed-pitch)) 2))
                           (size (max 6 (round (* init/org-tag-pill-scale
                                                  scale pixels))))
                           (info (font-info
                                  (format "%s:pixelsize=%d" family size))))
                      (when info
                        ;; size, space width, ascent, descent
                        (list family (aref info 2) (aref info 10)
                              (aref info 8) (aref info 9))))))))
    (cdr init/org--tag-metrics-cache)))

(defun init/org--tag-round-p ()
  "Return non-nil when tag labels can be drawn as pills."
  (and init/org-tag-round
       (display-graphic-p)
       (image-type-available-p 'svg)
       (init/org--tag-metrics)
       t))

(defconst init/org--tag-svg-format
  (concat "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%d\" height=\"%d\">"
          "<rect width=\"%d\" height=\"%d\" rx=\"%s\" fill=\"%s\"/>"
          "<text x=\"%d\" y=\"%d\" fill=\"%s\""
          " font-family=\"%s\" font-size=\"%dpx\">%s</text>"
          "</svg>")
  "Format string producing the SVG source of one rounded tag pill.")

(defun init/org--tag-image (label face)
  "Return a rounded pill image showing LABEL in the colours of FACE."
  (when-let ((metrics (init/org--tag-metrics)))
    (pcase-let* ((`(,family ,size ,advance ,ascent ,descent) metrics)
                 (background (or (init/org--face-attribute face :background)
                                 (face-attribute 'init/org-tag :background nil t)))
                 (foreground (or (init/org--face-attribute face :foreground)
                                 (face-attribute 'init/org-tag :foreground nil t)))
                 (key (list label family size background foreground)))
      (or (gethash key init/org--tag-image-cache)
          (puthash
           key
           (let* ((padding (max 2 (round (* init/org-tag-pill-padding advance))))
                  ;; A pixel of air above and below the letters keeps the
                  ;; label off the rounded edge.
                  (height (+ ascent descent 2))
                  (width (+ (* (string-width label) advance) (* 2 padding))))
             (create-image
              (format init/org--tag-svg-format
                      width height width height (/ height 2.0) background
                      padding (+ 1 ascent) foreground family size label)
              'svg t :ascent 'center :scale 1))
           init/org--tag-image-cache)))))

(defun init/org--tag-colon-positions (beg end)
  "Return the positions of the tag-delimiting colons between BEG and END."
  (let (colons)
    (save-excursion
      (goto-char beg)
      (while (search-forward ":" end t)
        (push (match-beginning 0) colons)))
    (nreverse colons)))

(defun init/org--tag-hide-colons (colons)
  "Replace the delimiting COLONS with the gaps drawn between pills.
The outer two are dropped entirely, so the labels sit flush."
  (let ((last (car (last colons)))
        (gap (propertize " " 'face 'default)))
    (dolist (colon colons)
      (put-text-property colon (1+ colon) 'display
                         (if (or (eq colon (car colons)) (eq colon last))
                             ""
                           gap)))))

(defun init/org--tag-draw-pills (colons)
  "Draw the label between each consecutive pair of COLONS as a pill."
  (while (cdr colons)
    (let* ((start (1+ (car colons)))
           (finish (cadr colons))
           (image (and (> finish start)
                       (init/org--tag-image
                        (buffer-substring-no-properties start finish)
                        (get-text-property start 'face)))))
      (when image
        ;; The label face would paint a full-height block behind the image
        ;; and square off its round corners.
        (put-text-property start finish 'face 'default)
        (put-text-property start finish 'display image)))
    (setq colons (cdr colons))))

(defun init/org--tag-pills (beg end)
  "Draw every tag label between BEG and END as a rounded pill."
  (let ((colons (init/org--tag-colon-positions beg end)))
    (when (cdr colons)
      (init/org--tag-hide-colons colons)
      (init/org--tag-draw-pills colons))))

(defun init/org--string-pixel-width (string)
  "Return the pixel width of STRING under this buffer's face remapping.
Like `string-pixel-width', which measures with the global faces and so
misses the writer-font remap of Org buffers."
  (let ((remapping face-remapping-alist))
    (with-temp-buffer
      (setq-local face-remapping-alist remapping)
      (setq-local display-line-numbers nil)
      (insert (propertize string 'line-prefix nil 'wrap-prefix nil))
      (car (buffer-text-pixel-size nil nil t)))))

(defun init/org--tag-pixel-width (beg end)
  "Return the rendered pixel width of the tag block between BEG and END."
  (let ((window (get-buffer-window (current-buffer) t)))
    (ignore-errors
      (if window
          (car (window-text-pixel-size window beg end))
        (init/org--string-pixel-width (buffer-substring beg end))))))

(defun init/org--tag-float (space-beg space-end tags-beg tags-end)
  "Stretch SPACE-BEG..SPACE-END so the tags end at the right window edge.
The tag block runs from TAGS-BEG to TAGS-END.  Only its width is baked
in; `:align-to' resolves the edge itself during redisplay, so the tags
follow the window as it is resized."
  (let ((width (init/org--tag-pixel-width tags-beg tags-end)))
    (when (and width (> width 0))
      ;; Plain face on the gap: the headline face would otherwise draw its
      ;; underline as a rule all the way out to the tags.
      (put-text-property space-beg space-end 'face 'default)
      (put-text-property
       space-beg space-end 'display
       `(space :align-to
               (- right (,(+ width (round (* init/org-tag-right-margin
                                             (frame-char-width)))))))))))

(defun init/org--tag-decorate (fontify &rest args)
  "Round tag pills and float headline tags, around FONTIFY.
FONTIFY is `org-modern--tag' called with ARGS; it is fed match data whose
group 1 is the space before the tags and group 2 the tag block.  Rounding
happens first, since it changes the width of the block that is then
measured for floating."
  (let ((headline (eq (char-after (match-beginning 0)) ?*))
        (space-beg (match-beginning 1))
        (space-end (match-end 1))
        (tags-beg (match-beginning 2))
        (tags-end (match-end 2)))
    (apply fontify args)
    (when (init/org--tag-round-p)
      (init/org--tag-pills tags-beg tags-end))
    ;; Agenda lines and #+filetags: keep their own alignment.
    (when (and init/org-tag-float headline (derived-mode-p 'org-mode))
      (init/org--tag-float space-beg space-end tags-beg tags-end))
    nil))

(defun init/org-refresh-tag-pills (&rest _)
  "Redraw and re-measure the tag pills of every Org buffer.
Their colours and width are baked in at fontification time, so a new
theme or font needs a refontification."
  (clrhash init/org--tag-image-cache)
  (setq init/org--tag-metrics-cache nil)
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (and (derived-mode-p 'org-mode) (bound-and-true-p font-lock-mode))
        (font-lock-flush)))))

;; Modern Org styling: heading bullets, TODO badges, tag pills, styled
;; tables, checkboxes and timestamps.
(use-package org-modern
  :hook ((org-mode . org-modern-mode)
         (org-agenda-finalize . org-modern-agenda))
  :custom
  (org-modern-star nil)
  (org-modern-replace-stars "◉○✸✿◆◇▶▷")
  (org-modern-table t)
  (org-modern-keyword t)
  (org-modern-checkbox '((?X . "☑") (?- . "◩") (?\s . "☐")))
  (org-modern-list '((?- . "•") (?+ . "◦") (?* . "▹")))
  ;; Colour every tag through `init/org-tag' instead of leaving them on
  ;; whatever `secondary-selection' the current theme happens to define.
  (org-modern-tag-faces '((t . init/org-tag)))
  :config
  (advice-add 'org-modern--tag :around #'init/org--tag-decorate)
  (add-hook 'enable-theme-functions #'init/org-refresh-tag-pills))

(provide 'init-org)
;;; init-org.el ends here
