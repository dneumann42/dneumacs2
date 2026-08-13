;;; init-bookmarks.el --- Visible per-file bookmarks -*- lexical-binding: t; -*-

;;; Commentary:

;; Fast, visible bookmarks built on bm.el — the Vim-marks workflow:
;;
;;   C-,     toggle a bookmark on the current line
;;   M-]     jump to the next bookmark in the file (wraps)
;;   M-[     jump to the previous bookmark in the file (wraps)
;;   C-M-,   jump to ANY bookmark in the project (picker; also M-g b)
;;   C-c ,   remove every bookmark in the current file
;;
;; After M-] or M-[, `repeat-mode' keeps bare ] and [ active, so hopping
;; around a file costs one keypress per jump ("," drops a bookmark
;; mid-hop).  Clicking the left fringe toggles a bookmark on that line.
;;
;; Bookmarks are persisted per file in `bm-repository-file' and restored
;; when a file is visited, so they survive restarts and play well with
;; sessions.  The project picker shows bookmarks from open buffers and
;; from project files that are not currently open, read straight from the
;; repository, and jumps on selection.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'init-keys)
(require 'init-lib)

(declare-function bm-lists "bm")
(declare-function bm-buffer-save-all "bm")
(declare-function bm-repository-save "bm")
(defvar bm-repository)

;;;; Saving

(defun init/bm-save-everything ()
  "Save every buffer's bookmarks and write the repository to disk."
  (when (featurep 'bm)
    (bm-buffer-save-all)
    (bm-repository-save)))

(use-package bm
  :ensure t
  :commands (bm-toggle bm-toggle-mouse bm-next bm-previous
             bm-remove-all-current-buffer bm-buffer-restore bm-buffer-save
             bm-buffer-save-all bm-repository-save bm-show-all)
  :init
  ;; Must be set before bm loads: it reads the repository as part of
  ;; loading.
  (setq bm-restore-repository-on-load t)
  :custom
  (bm-repository-file (expand-file-name "bm-repository" user-emacs-directory))
  ;; The repository is a list of per-file records, each carrying the text
  ;; around every bookmark in that file.  bm keeps a thousand files' worth
  ;; by default; a hundred is already far more history than the project
  ;; picker is ever asked for, and it keeps each write, and each in-memory
  ;; update on save, small.
  (bm-repository-size 100)
  ;; Errors only: bookmarks are a background convenience and their
  ;; progress messages just displace more useful ones.
  (bm-verbosity-level 1)
  ;; Fringe arrow plus a subtle line highlight.
  (bm-highlight-style 'bm-highlight-line-and-fringe)
  ;; M-] and M-[ cycle within the file; cross-file jumps go through the
  ;; project picker.
  (bm-cycle-all-buffers nil)
  ;; Wrap around at the last bookmark instead of stopping.
  (bm-wrap-search t)
  (bm-wrap-immediately t)
  ;; Restore a file's bookmarks when it is opened -- sessions restore
  ;; buffers through find-file, so this covers session loads too -- and
  ;; save them whenever the file or buffer goes away.
  :hook ((find-file . bm-buffer-restore)
         (after-revert . bm-buffer-restore)
         (kill-buffer . bm-buffer-save)
         (after-save . bm-buffer-save)
         (vc-before-checkin . bm-buffer-save))
  :config
  (setq-default bm-buffer-persistence t)
  ;; `bm-repository-save' pretty-prints the repository it has just
  ;; printed, which dominates the write; the file is read back with
  ;; `read', so the formatting buys nothing.
  (advice-add 'bm-repository-save :around #'init/write-state-file-fast)
  (add-hook 'kill-emacs-hook #'init/bm-save-everything))

;;;; Project-wide bookmark picker

(defun init/bm--line-at (position)
  "Return the trimmed text of the line at POSITION in the current buffer."
  (save-excursion
    (goto-char position)
    (string-trim (buffer-substring-no-properties
                  (line-beginning-position) (line-end-position)))))

(defun init/bm--display-name (file root)
  "Return FILE shown relative to ROOT, or abbreviated when ROOT is nil."
  (if root (file-relative-name file root) (abbreviate-file-name file)))

(defun init/bm--buffer-candidates (buffer root)
  "Return picker candidates for the bm overlays in BUFFER.
Each candidate is (DISPLAY FILE BUFFER POSITION).  BUFFER is skipped
unless it visits a file under ROOT, or ROOT is nil."
  (with-current-buffer buffer
    (when (and buffer-file-name
               (or (null root) (file-in-directory-p buffer-file-name root))
               (featurep 'bm))
      (let ((lists (bm-lists)))
        (mapcar
         (lambda (overlay)
           (let ((position (overlay-start overlay))
                 (annotation (overlay-get overlay 'annotation)))
             (list (format "%s:%d  %s%s"
                           (init/bm--display-name buffer-file-name root)
                           (line-number-at-pos position)
                           (if annotation (format "[%s] " annotation) "")
                           (init/bm--line-at position))
                   buffer-file-name buffer position)))
         (append (car lists) (cdr lists)))))))

(defun init/bm--repository-file-candidates (file bookmarks root)
  "Return picker candidates for BOOKMARKS recorded against FILE.
ROOT is the project root the display name is relative to."
  (mapcar
   (lambda (bookmark)
     (let ((position (or (cdr (assoc 'position bookmark)) 1))
           (annotation (cdr (assoc 'annotation bookmark)))
           (context (or (cdr (assoc 'after-context-string bookmark)) "")))
       (list (format "%s:@%d  %s%s"
                     (init/bm--display-name file root)
                     position
                     (if annotation (format "[%s] " annotation) "")
                     (string-trim (car (split-string context "\n"))))
             file nil position)))
   bookmarks))

(defun init/bm--repository-candidates (root open-files)
  "Return picker candidates from the bm repository for unopened files.
Only files under ROOT are included, or all files when ROOT is nil.
OPEN-FILES are skipped, since their live overlays are authoritative."
  (let (candidates)
    (dolist (entry bm-repository)
      (let ((file (car entry)))
        (when (and (stringp file)
                   ;; Indirect-buffer entries are keyed by "[name]".
                   (not (string-prefix-p "[" file))
                   (not (member file open-files))
                   (or (null root) (file-in-directory-p file root))
                   (file-exists-p file))
          (setq candidates
                (nconc candidates
                       (init/bm--repository-file-candidates
                        file (cdr (assoc 'bookmarks (cdr entry))) root))))))
    candidates))

(defun init/bm--project-candidates ()
  "Collect every bookmark candidate for the current project.
Falls back to every bookmark everywhere when not inside a project."
  (require 'bm)
  (let* ((root (ignore-errors (init/project-root)))
         (root (and root (file-name-as-directory (expand-file-name root))))
         (open (cl-loop for buffer in (buffer-list)
                        append (init/bm--buffer-candidates buffer root)))
         (open-files (delete-dups (mapcar #'cadr open))))
    (sort (append open (init/bm--repository-candidates root open-files))
          (lambda (a b) (string< (car a) (car b))))))

(defun init/bm-jump-project ()
  "Jump to any bookmark in the current project.
Includes bookmarks in files that are not currently open, restored from
the bm repository."
  (interactive)
  (let ((candidates (init/bm--project-candidates)))
    (unless candidates
      (user-error "No bookmarks in this project yet (toggle one with %s)"
                  bind/bm-toggle))
    (pcase-let* ((choice (completing-read "Bookmark: " candidates nil t))
                 (`(,_ ,file ,buffer ,position) (assoc choice candidates)))
      (if (buffer-live-p buffer)
          (switch-to-buffer buffer)
        (find-file file))
      (goto-char (min position (point-max)))
      (when (fboundp 'pulse-momentary-highlight-one-line)
        (pulse-momentary-highlight-one-line (point))))))

;;;; Keybindings

;; After a bookmark jump, bare ] and [ keep jumping and "," toggles a
;; bookmark where you land.  `bm-toggle' is excluded from *entering* the
;; repeat state, so typing a comma right after C-, still self-inserts.
(defvar-keymap init/bm-repeat-map
  :repeat (:exit (bm-toggle))
  "]" #'bm-next
  "[" #'bm-previous
  "," #'bm-toggle)

(global-set-key (kbd bind/bm-toggle) #'bm-toggle)
(global-set-key (kbd bind/bm-next) #'bm-next)
(global-set-key (kbd bind/bm-previous) #'bm-previous)
(global-set-key (kbd bind/bm-jump-project) #'init/bm-jump-project)
(global-set-key (kbd bind/bm-jump-project-alt) #'init/bm-jump-project)
(global-set-key (kbd bind/bm-clear-buffer) #'bm-remove-all-current-buffer)
(global-set-key (kbd "<left-fringe> <mouse-1>") #'bm-toggle-mouse)

(provide 'init-bookmarks)
;;; init-bookmarks.el ends here
