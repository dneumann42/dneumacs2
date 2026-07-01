;;; bm-setup.el --- Visible bookmarks (bm) -*- lexical-binding: t; -*-

;;; Commentary:

;; Fast, visible bookmarks built on bm.el — the Vim-marks workflow:
;;
;;   C-,     toggle a bookmark on the current line
;;   M-]     jump to the next bookmark in the file (wraps)
;;   M-[     jump to the previous bookmark in the file (wraps)
;;   C-M-,   jump to ANY bookmark in the project (picker; also M-g b)
;;   C-c ,   remove every bookmark in the current file
;;
;; After M-] / M-[, repeat-mode keeps bare ] and [ active, so hopping
;; around a file is one keypress per jump ("," drops a bookmark
;; mid-hop).  Clicking the left fringe toggles a bookmark on that line.
;;
;; Bookmarks are persisted per file in `bm-repository-file' and restored
;; when a file is visited, so they survive restarts and play well with
;; sessions.  The project picker shows bookmarks from open buffers and
;; from project files that are not currently open (read from the
;; repository), and jumps on selection.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function bm-lists "bm")
(declare-function bm-buffer-save-all "bm")
(declare-function bm-repository-save "bm")
(defvar bm-repository)

(use-package bm
  :ensure t
  :commands (bm-toggle bm-toggle-mouse bm-next bm-previous
             bm-remove-all-current-buffer bm-buffer-restore bm-buffer-save
             bm-buffer-save-all bm-repository-save bm-show-all)
  :init
  ;; Must be set before bm loads: read the repository as part of loading.
  (setq bm-restore-repository-on-load t)
  :custom
  (bm-repository-file (expand-file-name "bm-repository" user-emacs-directory))
  ;; Fringe arrow plus a subtle line highlight.
  (bm-highlight-style 'bm-highlight-line-and-fringe)
  ;; <f3>/<f4> cycle within the file; cross-file jumps go through the picker.
  (bm-cycle-all-buffers nil)
  ;; Wrap around at the last bookmark instead of stopping.
  (bm-wrap-search t)
  (bm-wrap-immediately t)
  :hook
  ;; Restore a file's bookmarks when it is opened (sessions restore
  ;; buffers through find-file, so this covers session loads too) and
  ;; save them whenever the file or buffer goes away.
  ((find-file . bm-buffer-restore)
   (after-revert . bm-buffer-restore)
   (kill-buffer . bm-buffer-save)
   (after-save . bm-buffer-save)
   (vc-before-checkin . bm-buffer-save))
  :config
  ;; Persist bookmarks in every buffer without asking.
  (setq-default bm-buffer-persistence t)
  (add-hook 'kill-emacs-hook #'init/bm-save-everything))

(defun init/bm-save-everything ()
  "Save all buffers' bookmarks and write the repository to disk."
  (when (featurep 'bm)
    (bm-buffer-save-all)
    (bm-repository-save)))

;;;; Project-wide bookmark picker

(defun init/bm--line-at (pos)
  "Return the trimmed text of the line at POS in the current buffer."
  (save-excursion
    (goto-char pos)
    (string-trim (buffer-substring-no-properties
                  (line-beginning-position) (line-end-position)))))

(defun init/bm--buffer-candidates (buffer root)
  "Return picker candidates for the bm overlays in BUFFER.
Each candidate is (DISPLAY FILE BUFFER POS).  Only include BUFFER when
it visits a file under ROOT (or always, when ROOT is nil)."
  (with-current-buffer buffer
    (when (and buffer-file-name
               (or (null root) (file-in-directory-p buffer-file-name root))
               (featurep 'bm))
      (let ((lists (bm-lists)))
        (mapcar
         (lambda (overlay)
           (let* ((pos (overlay-start overlay))
                  (annotation (overlay-get overlay 'annotation))
                  (name (if root
                            (file-relative-name buffer-file-name root)
                          (abbreviate-file-name buffer-file-name))))
             (list (format "%s:%d  %s%s"
                           name
                           (line-number-at-pos pos)
                           (if annotation (format "[%s] " annotation) "")
                           (init/bm--line-at pos))
                   buffer-file-name buffer pos)))
         (append (car lists) (cdr lists)))))))

(defun init/bm--repository-candidates (root open-files)
  "Return picker candidates from the bm repository for unopened files.
Only include files under ROOT (all files when ROOT is nil), skipping
OPEN-FILES since their live overlays are authoritative."
  (let (candidates)
    (dolist (entry bm-repository)
      (let ((file (car entry)))
        (when (and (stringp file)
                   (not (string-prefix-p "[" file)) ; indirect-buffer entries
                   (not (member file open-files))
                   (or (null root) (file-in-directory-p file root))
                   (file-exists-p file))
          (dolist (bookmark (cdr (assoc 'bookmarks (cdr entry))))
            (let* ((pos (cdr (assoc 'position bookmark)))
                   (annotation (cdr (assoc 'annotation bookmark)))
                   (context (or (cdr (assoc 'after-context-string bookmark)) ""))
                   (name (if root
                             (file-relative-name file root)
                           (abbreviate-file-name file))))
              (push (list (format "%s:@%d  %s%s"
                                  name (or pos 1)
                                  (if annotation (format "[%s] " annotation) "")
                                  (string-trim (car (split-string context "\n"))))
                          file nil (or pos 1))
                    candidates))))))
    (nreverse candidates)))

(defun init/bm--project-candidates ()
  "Collect all bookmark candidates for the current project.
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
Includes bookmarks in files that are not currently open (restored from
the bm repository)."
  (interactive)
  (let ((candidates (init/bm--project-candidates)))
    (unless candidates
      (user-error "No bookmarks in this project yet (toggle one with %s)"
                  bind/bm-toggle))
    (pcase-let* ((choice (completing-read "Bookmark: " candidates nil t))
                 (`(,_ ,file ,buffer ,pos) (assoc choice candidates)))
      (if (buffer-live-p buffer)
          (switch-to-buffer buffer)
        (find-file file))
      (goto-char (min pos (point-max)))
      (when (fboundp 'pulse-momentary-highlight-one-line)
        (pulse-momentary-highlight-one-line (point))))))

;;;; Keybindings

;; After a bookmark jump, bare ]/[ keep jumping and "," toggles a
;; bookmark where you land.  bm-toggle itself is excluded from
;; *entering* the repeat state, so typing a comma right after C-,
;; still self-inserts.
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

(provide 'bm-setup)
;;; bm-setup.el ends here
