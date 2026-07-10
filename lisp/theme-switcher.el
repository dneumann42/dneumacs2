;;; theme-switcher.el --- Preview, install, and persist themes -*- lexical-binding: t; -*-

(require 'package)
(require 'url)
(require 'seq)
(require 'subr-x)
(require 'init-persist)

(defgroup init/theme-switcher nil
  "Interactive theme previews and installation."
  :group 'faces)

(defcustom init/theme-default 'wallust
  "Theme used until another theme has been selected."
  :type 'symbol)

(defconst init/theme-gallery-url "https://emacsthemes.com/themes/"
  "Index used by `init/theme-gallery'.")

(defvar init/selected-theme init/theme-default
  "Theme selected for this and future sessions.")
;; Restored early by `init/persist-load' (see init.el); registered here so
;; it is written back to the unified store whenever it changes.
(init/persist-register 'init/selected-theme)

(defvar init/theme--previewed nil)

(defvar init/theme--internal-load nil
  "Non-nil while the switcher is loading a temporary or startup theme.")

(defun init/theme--available-p (theme)
  "Return non-nil when THEME can be loaded."
  (memq theme (custom-available-themes)))

(defun init/theme--apply (theme)
  "Enable only THEME, without recording it as the user's choice."
  (mapc #'disable-theme custom-enabled-themes)
  (condition-case error-data
      (let ((init/theme--internal-load t))
        (load-theme theme t)
        (setq init/theme--previewed theme))
    (error
     (let ((init/theme--internal-load t))
       (load-theme init/theme-default t))
     (signal (car error-data) (cdr error-data)))))

(defun init/theme--save (theme)
  "Persist THEME as the selected theme for future sessions."
  (init/persist-set 'init/selected-theme theme))

(defun init/theme--load-theme-around (original theme &optional no-confirm no-enable)
  "Make an ordinary `load-theme' call exclusive and persistent.
ORIGINAL, THEME, NO-CONFIRM, and NO-ENABLE mirror `load-theme'.  Internal
preview and startup loads retain their temporary behavior."
  (if (or init/theme--internal-load no-enable)
      (funcall original theme no-confirm no-enable)
    (mapc #'disable-theme custom-enabled-themes)
    (condition-case error-data
        (prog1 (funcall original theme no-confirm no-enable)
          (setq init/selected-theme theme
                init/theme--previewed theme)
          (init/theme--save theme)
          (message "Theme %s selected and saved" theme))
      (error
       (when (init/theme--available-p init/selected-theme)
         (let ((init/theme--internal-load t))
           (load-theme init/selected-theme t)))
       (signal (car error-data) (cdr error-data))))))

(advice-add 'load-theme :around #'init/theme--load-theme-around)

(defun init/theme-load-selected ()
  "Load the persisted theme, falling back to `init/theme-default'."
  (let ((theme (if (init/theme--available-p init/selected-theme)
                   init/selected-theme
                 init/theme-default)))
    (unless (eq theme init/selected-theme)
      (display-warning 'theme-switcher
                       (format "Saved theme %s is unavailable; using %s"
                               init/selected-theme theme)))
    (init/theme--apply theme)))

(defun init/theme--put-line-face (label face sample)
  "Insert SAMPLE labeled LABEL and display it using FACE."
  (let ((start (point)))
    (insert (format "%-24s %s\n" label sample))
    (add-text-properties start (point) `(face ,face))))

(defun init/theme-preview-buffer ()
  "Show a comprehensive source-code and UI-face theme test buffer."
  (interactive)
  (let ((buffer (get-buffer-create "*Theme Preview*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (emacs-lisp-mode)
        (insert ";;; theme-preview.el --- A demanding theme specimen -*- lexical-binding: t; -*-\n\n"
                ";; Comments, documentation, punctuation, and syntax should all be distinct.\n"
                "(defcustom aurora-temperature 6500\n"
                "  \"Color temperature in kelvin; try 3200 or 9300.\"\n"
                "  :type '(integer :tag \"Kelvin\")\n"
                "  :group 'aurora)\n\n"
                "(cl-defstruct (aurora-pixel (:constructor aurora-pixel-create))\n"
                "  x y (rgba [255 128 0 0.85]))\n\n"
                "(defun aurora-render (name pixels &optional vivid-p)\n"
                "  \"Render PIXELS for NAME, preserving contrast when VIVID-P is nil.\"\n"
                "  (declare (indent 1) (pure nil))\n"
                "  (let* ((limit 0xff)\n"
                "         (ratio (/ 13.0 21.0))\n"
                "         (message-text (format \"Theme: %s → λ✓\" name)))\n"
                "    (condition-case err\n"
                "        (dolist (pixel pixels)\n"
                "          (pcase-let (((cl-struct aurora-pixel x y rgba) pixel))\n"
                "            (when (and vivid-p (> x ratio))\n"
                "              (message \"%s @ (%03d, %03d): %S\"\n"
                "                       message-text x y rgba))))\n"
                "      (wrong-type-argument\n"
                "       (user-error \"Invalid pixel: %s\" (error-message-string err))))))\n\n"
                "(font-lock-add-keywords nil '((\"FIXME:\" 0 font-lock-warning-face t)))\n"
                ";; FIXME: warnings must be impossible to overlook.\n"
                "(aurora-render \"café/night\"\n"
                "  (list (aurora-pixel-create :x 0.618 :y -42)))\n\n")
        (font-lock-ensure)
        (insert (propertize "FACE AND EDITOR STATES\n" 'face '(:height 1.35 :weight bold :underline t)))
        (dolist (spec '(("Default" default "Ordinary prose and 0123456789")
                        ("Variable pitch" variable-pitch "Readable proportional prose")
                        ("Fixed pitch" fixed-pitch "iIl1  mMwW  aligned")
                        ("Bold / italic" (:weight bold :slant italic) "Strong emphasis")
                        ("Link" link "https://emacsthemes.com/")
                        ("Visited link" link-visited "Previously followed link")
                        ("Region / selection" region "Selected text remains legible")
                        ("Highlight / hover" highlight "Pointer and transient highlight")
                        ("Search match" match "A successful search match")
                        ("Lazy search" isearch-lazy-highlight "Other search occurrences")
                        ("Active search" isearch "The current search occurrence")
                        ("Error" error "Error: compilation failed")
                        ("Warning" warning "Warning: suspicious expression")
                        ("Success" success "Success: all checks passed")
                        ("Shadow" shadow "Secondary metadata and hints")
                        ("Mode line active" mode-line " UTF-8  LF  Emacs-Lisp  42:17 ")
                        ("Mode line inactive" mode-line-inactive " inactive-window.el ")
                        ("Header line" header-line " Project › src › theme-preview.el ")
                        ("Fringe" fringe "breakpoint ● continuation ↪")
                        ("Line number" line-number "  41  ordinary line")
                        ("Current line number" line-number-current-line "  42  current line")
                        ("Trailing whitespace" trailing-whitespace "visible bad whitespace   ")
                        ("Escape / prompt" minibuffer-prompt "M-x choose-theme: ")))
          (apply #'init/theme--put-line-face spec))
        (insert "\n")
        (init/theme--put-line-face "Diff added" 'diff-added "+ const answer = 42;")
        (init/theme--put-line-face "Diff removed" 'diff-removed "- const answer = null;")
        (init/theme--put-line-face "Diff changed" 'diff-changed "! const answer = compute();")
        (insert (propertize "\nOrg hierarchy:  " 'face 'org-document-info-keyword)
                (propertize "* Heading 1  " 'face 'org-level-1)
                (propertize "** Heading 2  " 'face 'org-level-2)
                (propertize "*** Heading 3\n" 'face 'org-level-3)
                (propertize "TODO" 'face 'org-todo) " pending   "
                (propertize "DONE" 'face 'org-done) " complete   "
                (propertize "2026-07-05 Sun" 'face 'org-date) " date\n")
        (goto-char (point-min))
        (setq-local display-line-numbers t)
        (setq-local truncate-lines nil)
        (hl-line-mode 1)
        (setq buffer-read-only t
              buffer-undo-list t))
      (set-buffer-modified-p nil))
    (pop-to-buffer buffer)))

(defun init/theme--restore (themes)
  "Restore enabled THEMES after a cancelled preview."
  (mapc #'disable-theme custom-enabled-themes)
  (let ((init/theme--internal-load t))
    (dolist (theme (reverse themes))
      (when (init/theme--available-p theme)
        (load-theme theme t)))))

(defun init/theme--current-completion (names)
  "Return the currently highlighted completion among NAMES.
This supports both built-in completion and Vertico's highlighted row."
  (let ((candidate
         (if (and (bound-and-true-p vertico--input)
                  (fboundp 'vertico--candidate))
             (funcall #'vertico--candidate)
           (minibuffer-contents-no-properties))))
    (and (stringp candidate) (member candidate names) candidate)))

(defun init/theme--read-with-live-preview ()
  "Read a theme name with a live preview.
Pops up the theme specimen buffer and, as the highlighted candidate
moves through the completion list, applies that theme so the whole
frame previews it before selection.  Restores the previously enabled
themes when the read is cancelled.  Returns the chosen theme symbol."
  (init/theme-preview-buffer)
  (let* ((original (copy-sequence custom-enabled-themes))
         (names (sort (mapcar #'symbol-name (custom-available-themes))
                      #'string-lessp))
         (choice nil)
         (preview (lambda ()
                    (when-let* ((text (init/theme--current-completion names))
                                (theme (intern text)))
                      (unless (eq theme init/theme--previewed)
                        (ignore-errors (init/theme--apply theme)))))))
    (unwind-protect
        (minibuffer-with-setup-hook
            (lambda () (add-hook 'post-command-hook preview nil t))
          (setq choice (completing-read
                        "Preview theme (RET selects, C-g cancels): " names nil t)))
      (unless choice (init/theme--restore original)))
    (intern choice)))

(defun init/theme-select (theme)
  "Load THEME exclusively and make it the choice for future sessions.
Called interactively, show the theme specimen buffer and live-apply
each candidate to the whole frame as you move through the list, so you
see the theme before committing to it; press RET to keep the
highlighted one or C-g to cancel and restore the previous theme."
  (interactive (list (init/theme--read-with-live-preview)))
  (init/theme--apply theme)
  (setq init/selected-theme theme)
  (init/theme--save theme)
  (message "Theme %s selected and saved" theme))

;; Historical name; `init/theme-select' now does the live preview itself.
(defalias 'init/theme-preview-and-select 'init/theme-select)

(defun init/theme--gallery-entries ()
  "Fetch (DISPLAY-NAME . SLUG) entries from EmacsThemes."
  (let ((buffer (url-retrieve-synchronously init/theme-gallery-url t t 15)))
    (unless buffer (user-error "Could not retrieve %s" init/theme-gallery-url))
    (unwind-protect
        (with-current-buffer buffer
          (goto-char (point-min))
          (unless (re-search-forward "\r?\n\r?\n" nil t)
            (user-error "Invalid response from EmacsThemes"))
          (let (entries)
            (while (re-search-forward
                    "href=[\"']/?themes/\\([^\"'/?#]+\\)\\(?:\\.html\\)?[\"']"
                    nil t)
              (let ((slug (string-remove-suffix
                           ".html" (match-string-no-properties 1))))
                (unless (string= slug "index")
                  (push (cons (string-join
                               (mapcar #'capitalize (split-string slug "-" t)) " ")
                              slug)
                        entries))))
            (seq-uniq (nreverse entries) (lambda (a b) (equal (cdr a) (cdr b))))))
      (kill-buffer buffer))))

(defun init/theme--archive-descriptors ()
  "Return all current package archive descriptors."
  (apply #'append
         (mapcar (lambda (entry)
                   (let ((value (cdr entry)))
                     (if (package-desc-p value) (list value) value)))
                 package-archive-contents)))

(defun init/theme--package-candidates (slug)
  "Return archive packages likely to provide gallery theme SLUG."
  (let* ((base (string-remove-suffix "-theme" slug))
         (descriptors (init/theme--archive-descriptors))
         (exact (list slug (concat base "-theme") base))
         candidates)
    (dolist (desc descriptors)
      (let* ((name (symbol-name (package-desc-name desc)))
             (root (string-remove-suffix "-themes" name)))
        (when (or (member name exact)
                  (and (string-suffix-p "-themes" name)
                       (string-prefix-p root base)))
          (push (package-desc-name desc) candidates))))
    (delete-dups (nreverse candidates))))

(defun init/theme--themes-in-package (package)
  "Return themes declared by installed PACKAGE."
  (when-let* ((desc (cadr (assq package package-alist)))
              (dir (package-desc-dir desc)))
    (let (themes)
      (dolist (file (directory-files-recursively dir "-theme\\.el\\'"))
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (point-min))
          (while (re-search-forward "(\\(?:def\\|provide\\)-?theme[[:space:]]+'?\\([^()[:space:]]+\\)" nil t)
            (push (intern (match-string 1)) themes))))
      (delete-dups themes))))

(defun init/theme-gallery (&optional refresh-packages)
  "Pick a theme from EmacsThemes, install its package, and select it.
With prefix argument REFRESH-PACKAGES, refresh package metadata first."
  (interactive "P")
  (when (or refresh-packages (null package-archive-contents))
    (package-refresh-contents))
  (let* ((entries (init/theme--gallery-entries))
         (display (completing-read "EmacsThemes theme: " entries nil t))
         (slug (cdr (assoc display entries)))
         (candidates (init/theme--package-candidates slug))
         (package
          (cond ((= (length candidates) 1) (car candidates))
                (candidates
                 (intern (completing-read "Install package: "
                                          (mapcar #'symbol-name candidates) nil t)))
                (t
                 (intern (completing-read
                          "Package not inferred; install package: "
                          (mapcar (lambda (d) (symbol-name (package-desc-name d)))
                                  (init/theme--archive-descriptors))
                          nil t slug))))))
    (unless (package-installed-p package)
      (package-install package))
    (let* ((themes (or (init/theme--themes-in-package package)
                       (custom-available-themes)))
           (preferred (seq-find (lambda (theme)
                                  (equal (string-remove-suffix "-theme" slug)
                                         (string-remove-suffix "-theme"
                                                               (symbol-name theme))))
                                themes))
           (theme (or preferred
                      (intern (completing-read "Theme provided by package: "
                                               (mapcar #'symbol-name themes) nil t)))))
      (init/theme-preview-buffer)
      (init/theme-select theme))))

(defun init/theme-gallery-web ()
  "Open the EmacsThemes visual gallery in the default browser."
  (interactive)
  (browse-url init/theme-gallery-url))

(provide 'theme-switcher)
;;; theme-switcher.el ends here
