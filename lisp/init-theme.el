;;; init-theme.el --- Fonts and colour themes -*- lexical-binding: t; -*-

;;; Commentary:

;; Everything that decides how Emacs looks before any buffer is drawn.
;;
;; Fonts: a shared discovery-and-installation flow (`init/font-ensure')
;; that probes for a family and falls back gracefully.  The UI font never
;; prompts during startup; it can be installed explicitly with
;; `init/install-cascadia-font'.  The prose font may be offered when a mode
;; that uses it is first opened.
;;
;; Themes: the selected theme is remembered across sessions in the
;; init-persist store, so it is known before any module that reads face
;; colours runs.  `load-theme' is advised to be exclusive (enabling one
;; theme disables the others) and to record the choice, so themes picked
;; through Customize behave like themes picked with `init/theme-select'.
;; `init/theme-select' previews candidates live on the whole frame, and
;; `init/theme-gallery' installs one straight from EmacsThemes.
;;
;; Finally, the generated Wallust theme is watched on disk so a new
;; wallpaper palette is picked up without restarting.

;;; Code:

(require 'cl-lib)
(require 'package)
(require 'seq)
(require 'subr-x)
(require 'url)
(require 'init-keys)
(require 'init-lib)
(require 'init-persist)

(add-to-list 'custom-theme-load-path
             (expand-file-name "themes" user-emacs-directory))

;;;; Font discovery and installation

(defconst init/font-directory (expand-file-name "~/.local/share/fonts/")
  "Directory where downloaded user fonts are installed.")

(defvar init/font-install-asked (make-hash-table :test #'eq)
  "Font identifiers already offered for installation this session.")

(defun init/font-available-p (families)
  "Return the first installed font family matching FAMILIES."
  (let ((installed (font-family-list)))
    (cl-find-if
     (lambda (family)
       (cl-find-if (lambda (candidate)
                     (string-match-p (regexp-quote family) candidate))
                   installed))
     families)))

(defun init/font-files-installed-p (patterns)
  "Return non-nil when a font file matching one of PATTERNS is installed."
  (cl-some (lambda (pattern)
             (file-expand-wildcards
              (expand-file-name pattern init/font-directory)))
           patterns))

(defun init/font-reset-cache ()
  "Refresh the Emacs and system font caches after installing fonts."
  (when (and (eq system-type 'gnu/linux) (executable-find "fc-cache"))
    (let ((status (call-process "fc-cache" nil nil nil "-f")))
      (unless (and (integerp status) (zerop status))
        (message "Font cache refresh failed with status %s" status))))
  ;; Clear Emacs' view only after fontconfig has learned about the new files.
  (when (fboundp 'clear-font-cache)
    (clear-font-cache)))

(defun init/font--download (url target)
  "Download URL atomically to TARGET using curl."
  (unless (executable-find "curl")
    (user-error "curl is required to download fonts"))
  (init/atomic-write-file
   target
   (lambda (temporary)
     (unless (zerop (call-process
                     "curl" nil nil nil "-L" "--fail" "--silent"
                     "--show-error" "--output" temporary url))
       (error "Failed to download %s" url)))))

(defun init/font-install-files (files)
  "Install font FILES, an alist of destination names and download URLs."
  (make-directory init/font-directory t)
  (dolist (entry files)
    (init/font--download (cdr entry)
                         (expand-file-name (car entry) init/font-directory)))
  (init/font-reset-cache)
  t)

(defun init/font--extract-zip (archive destination)
  "Extract zip ARCHIVE into DESTINATION using an available system tool."
  (let* ((unzip (executable-find "unzip"))
         (bsdtar (executable-find "bsdtar"))
         (status
          (cond
           (unzip
            (call-process unzip nil nil nil "-oq" archive "-d" destination))
           (bsdtar
            (call-process bsdtar nil nil nil "-xf" archive "-C" destination))
           (t
            (user-error
             "A zip extractor is required (install unzip or bsdtar)")))))
    (unless (and (integerp status) (zerop status))
      (error "Font archive extraction failed with status %s" status))))

(defun init/font-install-zip (url archive-name)
  "Download the font archive at URL as ARCHIVE-NAME and extract it."
  (let ((archive (make-temp-file "emacs-font-" nil
                                 (concat "-" archive-name))))
    (unwind-protect
        (progn
          (init/font--download url archive)
          (make-directory init/font-directory t)
          (init/font--extract-zip archive init/font-directory)
          (init/font-reset-cache)
          t)
      (when (file-exists-p archive)
        (delete-file archive)))))

(defun init/font--offer-install (id prompt installer)
  "Offer once per session to install font ID by running INSTALLER.
PROMPT is the question asked.  Return non-nil when INSTALLER ran."
  (when (and (eq system-type 'gnu/linux)
             prompt installer
             (not (gethash id init/font-install-asked)))
    (puthash id t init/font-install-asked)
    (when (y-or-n-p prompt)
      (condition-case err
          (progn (funcall installer) t)
        (error
         (message "%s font install failed: %s" id (error-message-string err))
         nil)))))

(cl-defun init/font-ensure
    (id &key families file-patterns default-family prompt installer
        fallback-families require-graphic)
  "Resolve, and optionally install, the font identified by ID.
FAMILIES are probed in order.  FILE-PATTERNS and DEFAULT-FAMILY let a
just-installed font resolve before Emacs reports it in
`font-family-list'.  PROMPT and INSTALLER control the once-per-session
installation offer, which REQUIRE-GRAPHIC restricts to graphical Emacs.
FALLBACK-FAMILIES are probed when the font is still unavailable.  Return
the family name to use, or nil."
  (cl-flet ((resolve ()
              (or (init/font-available-p families)
                  (and default-family file-patterns
                       (init/font-files-installed-p file-patterns)
                       default-family))))
    (or (resolve)
        (and (or (not require-graphic) (display-graphic-p))
             (init/font--offer-install id prompt installer)
             (resolve))
        (init/font-available-p fallback-families))))

;;;; The default UI font

(defconst init/cascadia-font-url
  "https://github.com/ryanoasis/nerd-fonts/releases/download/v3.4.0/CascadiaCode.zip"
  "Download URL for the Cascadia Code Nerd Font archive.")

(defconst init/cascadia-font-families
  '("CaskaydiaCove Nerd Font Mono"
    "CaskaydiaCove Nerd Font Propo"
    "CaskaydiaCove Nerd Font"
    "CaskaydiaCove NF"
    "CaskaydiaCove"
    "Cascadia Code Nerd Font Mono"
    "Cascadia Code Nerd Font Propo"
    "Cascadia Code Nerd Font"
    "Cascadia Code NF"
    "Cascadia Code")
  "Family names to probe for an installed Cascadia Nerd Font.")

(defconst init/cascadia-default-family "CaskaydiaCove Nerd Font Mono"
  "Preferred Cascadia family name to use once the font is installed.")

(defconst init/cascadia-font-files
  '("CaskaydiaCoveNerdFont*.ttf"
    "CaskaydiaCoveNerdFont*.otf"
    "CascadiaCodeNerdFont*.ttf"
    "CascadiaCodeNerdFont*.otf")
  "File patterns identifying an installed Cascadia Nerd Font.")

(defconst init/iosevka-font-families
  '("Iosevka NFM" "Iosevka Nerd Font Mono" "Iosevka Nerd Font" "Iosevka")
  "Family names to probe for an installed Iosevka font as a fallback.")

(defvar init/font-size 13
  "Default font size, in points, for the UI font.")

(defvar init/pending-font-family nil
  "Font family awaiting application once a graphical frame is ready.")

(defvar init/font-apply-retried nil
  "Non-nil once a deferred font application has been scheduled.")

(defun init/apply-font-family-now (family)
  "Try to apply FAMILY as the default font.  Return non-nil on success."
  (condition-case err
      (progn
        (set-face-attribute 'default nil
                            :family family :height (* init/font-size 10))
        (set-face-attribute 'fixed-pitch nil
                            :family family :height (* init/font-size 10))
        t)
    (error
     (message "Font not available yet: %s" (error-message-string err))
     nil)))

(defun init/apply-pending-font-family ()
  "Retry applying the most recently requested font family."
  (when init/pending-font-family
    (let ((family init/pending-font-family))
      (setq init/pending-font-family nil)
      (init/apply-font-family-now family))))

(defun init/apply-font-family (family)
  "Apply FAMILY as the default font for current and future frames.
A font can be unusable this early -- before the first graphical frame
exists -- so a failed attempt is retried once from a timer."
  ;; `set-face-attribute' with a nil FRAME updates all existing frames and the
  ;; defaults inherited by new frames.  Do not also put a `font-spec' in
  ;; `default-frame-alist': Emacs 31 rejects that value when posframe creates a
  ;; child frame, which can make diagnostic popups repeatedly signal errors.
  (setq default-frame-alist (assq-delete-all 'font default-frame-alist))
  (if (init/apply-font-family-now family)
      (setq init/pending-font-family nil
            init/font-apply-retried nil)
    (setq init/pending-font-family family)
    (unless init/font-apply-retried
      (setq init/font-apply-retried t)
      (run-at-time 1 nil #'init/apply-pending-font-family))
    (message "Font not available yet, will retry once")))

(defun init/maybe-apply-pending-font (&optional _frame)
  "Apply the pending font family, if there is one, to a new frame."
  (when init/pending-font-family
    (init/apply-font-family-now init/pending-font-family)))

(defun init/install-cascadia-font ()
  "Download and install Cascadia Nerd Font into the user font directory."
  (init/font-install-zip init/cascadia-font-url "CascadiaCode.zip"))

(defun init/ensure-default-font ()
  "Use an installed Cascadia or Iosevka font for the UI.
Do not prompt to download fonts during startup.  Cascadia can be installed
explicitly with `init/install-cascadia-font'."
  (when-let* ((family
              (init/font-ensure
               'cascadia
               :families init/cascadia-font-families
               :fallback-families init/iosevka-font-families)))
    (init/apply-font-family family)))

;;;; The writer font

;; EB Garamond (SIL OFL) is a revival of Claude Garamont's 16th-century
;; types: an elegant, bookish serif that makes Org and EWW read like a
;; page.  Org and EWW remap `variable-pitch' to it.

(defconst init/writer-font-family "EB Garamond"
  "Preferred font family for prose buffers.")

(defconst init/writer-font-families '("EB Garamond" "EBGaramond")
  "Family names to probe for an installed EB Garamond font.")

(defconst init/writer-font-files
  (let ((base (concat "https://raw.githubusercontent.com/octaviopardo/"
                      "EBGaramond12/master/fonts/ttf/")))
    (mapcar (lambda (file) (cons file (concat base file)))
            ;; SemiBold is included because the Org heading faces use it.
            '("EBGaramond-Regular.ttf"
              "EBGaramond-Italic.ttf"
              "EBGaramond-Bold.ttf"
              "EBGaramond-BoldItalic.ttf"
              "EBGaramond-SemiBold.ttf"
              "EBGaramond-SemiBoldItalic.ttf")))
  "Writer font files to download, as (FILE-NAME . URL).")

(defun init/install-writer-font ()
  "Download EB Garamond into the user font directory."
  (init/font-install-files init/writer-font-files))

(defun init/ensure-writer-font ()
  "Return an available writer font family, offering to install one.
Return nil when no such font is available."
  (init/font-ensure
   'writer
   :families init/writer-font-families
   :file-patterns '("EBGaramond*.ttf")
   :default-family init/writer-font-family
   :prompt "EB Garamond (prose font) is missing. Download and install it? "
   :installer #'init/install-writer-font
   :require-graphic t))

;;;; Theme selection and persistence

(defgroup init/theme nil
  "Interactive theme previews and installation."
  :group 'faces)

(defcustom init/theme-default 'wallust
  "Theme used until another theme has been selected."
  :type 'symbol
  :group 'init/theme)

(defconst init/theme-gallery-url "https://emacsthemes.com/themes/"
  "Index page used by `init/theme-gallery'.")

(defvar init/selected-theme init/theme-default
  "Theme selected for this and future sessions.")
;; Restored early by `init/persist-load'; registered here so it is written
;; back to the store whenever it changes.
(init/persist-register 'init/selected-theme)

(defvar init/theme--previewed nil
  "Theme most recently applied, whether as a preview or a selection.")

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
ORIGINAL, THEME, NO-CONFIRM and NO-ENABLE mirror `load-theme'.  Internal
preview and startup loads keep their temporary behaviour."
  (if (or init/theme--internal-load no-enable)
      (funcall original theme no-confirm no-enable)
    (mapc #'disable-theme custom-enabled-themes)
    (condition-case error-data
        (prog1 (funcall original theme no-confirm no-enable)
          (setq init/theme--previewed theme)
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
      (display-warning 'init/theme
                       (format "Saved theme %s is unavailable; using %s"
                               init/selected-theme theme)))
    (init/theme--apply theme)))

;;;; The theme specimen buffer

(defconst init/theme-specimen-code
  (concat
   ";;; theme-preview.el --- A demanding theme specimen -*- lexical-binding: t; -*-\n\n"
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
  "Source-code sample exercising the syntax faces of a theme.")

(defconst init/theme-specimen-faces
  '(("Default" default "Ordinary prose and 0123456789")
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
    ("Escape / prompt" minibuffer-prompt "M-x choose-theme: ")
    ("Diff added" diff-added "+ const answer = 42;")
    ("Diff removed" diff-removed "- const answer = null;")
    ("Diff changed" diff-changed "! const answer = compute();"))
  "UI faces shown in the theme specimen, as (LABEL FACE SAMPLE).")

(defun init/theme--insert-face-sample (label face sample)
  "Insert SAMPLE labelled LABEL, displayed using FACE."
  (let ((start (point)))
    (insert (format "%-24s %s\n" label sample))
    (add-text-properties start (point) `(face ,face))))

(defun init/theme--insert-org-sample ()
  "Insert a line exercising the Org heading and keyword faces."
  (insert (propertize "\nOrg hierarchy:  " 'face 'org-document-info-keyword)
          (propertize "* Heading 1  " 'face 'org-level-1)
          (propertize "** Heading 2  " 'face 'org-level-2)
          (propertize "*** Heading 3\n" 'face 'org-level-3)
          (propertize "TODO" 'face 'org-todo) " pending   "
          (propertize "DONE" 'face 'org-done) " complete   "
          (propertize "2026-07-05 Sun" 'face 'org-date) " date\n"))

(defun init/theme-preview-buffer ()
  "Show a demanding source-code and UI-face specimen of the current theme."
  (interactive)
  (let ((buffer (get-buffer-create "*Theme Preview*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (emacs-lisp-mode)
        (insert init/theme-specimen-code)
        (font-lock-ensure)
        (insert (propertize "FACE AND EDITOR STATES\n"
                            'face '(:height 1.35 :weight bold :underline t)))
        (dolist (spec init/theme-specimen-faces)
          (apply #'init/theme--insert-face-sample spec))
        (init/theme--insert-org-sample)
        (goto-char (point-min))
        (setq-local display-line-numbers t)
        (setq-local truncate-lines nil)
        (hl-line-mode 1)
        (setq buffer-read-only t
              buffer-undo-list t))
      (set-buffer-modified-p nil))
    (pop-to-buffer buffer)))

;;;; Selecting a theme with a live preview

(defun init/theme--restore (themes)
  "Restore the enabled THEMES after a cancelled preview."
  (mapc #'disable-theme custom-enabled-themes)
  (let ((init/theme--internal-load t))
    (dolist (theme (reverse themes))
      (when (init/theme--available-p theme)
        (load-theme theme t)))))

(defun init/theme--current-completion (names)
  "Return the currently highlighted completion among NAMES, or nil.
Understands both built-in completion and Vertico's highlighted row."
  (let ((candidate
         (if (and (bound-and-true-p vertico--input)
                  (fboundp 'vertico--candidate))
             (funcall #'vertico--candidate)
           (minibuffer-contents-no-properties))))
    (and (stringp candidate) (member candidate names) candidate)))

(defun init/theme--read-with-live-preview ()
  "Read a theme name, applying each highlighted candidate to the frame.
Pops up the specimen buffer, previews the theme under the completion
cursor, and restores the previously enabled themes when cancelled.
Return the chosen theme symbol."
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
                        "Preview theme (RET selects, C-g cancels): "
                        names nil t)))
      (unless choice (init/theme--restore original)))
    (intern choice)))

(defun init/theme-select (theme)
  "Load THEME exclusively and make it the choice for future sessions.
Called interactively, show the specimen buffer and live-apply each
candidate to the whole frame as you move through the list, so you see a
theme before committing to it: RET keeps the highlighted one, C-g
cancels and restores the previous theme."
  (interactive (list (init/theme--read-with-live-preview)))
  (init/theme--apply theme)
  (init/theme--save theme)
  (message "Theme %s selected and saved" theme))

;; Historical name; `init/theme-select' now does the live preview itself.
(defalias 'init/theme-preview-and-select 'init/theme-select)

;;;; Installing a theme from EmacsThemes

(defun init/theme--gallery-entries ()
  "Fetch (DISPLAY-NAME . SLUG) entries from the EmacsThemes index."
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
                               (mapcar #'capitalize (split-string slug "-" t))
                               " ")
                              slug)
                        entries))))
            (seq-uniq (nreverse entries)
                      (lambda (a b) (equal (cdr a) (cdr b))))))
      (kill-buffer buffer))))

(defun init/theme--archive-descriptors ()
  "Return every package descriptor in the current archive contents."
  (apply #'append
         (mapcar (lambda (entry)
                   (let ((value (cdr entry)))
                     (if (package-desc-p value) (list value) value)))
                 package-archive-contents)))

(defun init/theme--package-candidates (slug)
  "Return archive packages likely to provide the gallery theme SLUG."
  (let* ((base (string-remove-suffix "-theme" slug))
         (exact (list slug (concat base "-theme") base))
         candidates)
    (dolist (descriptor (init/theme--archive-descriptors))
      (let* ((name (symbol-name (package-desc-name descriptor)))
             (root (string-remove-suffix "-themes" name)))
        (when (or (member name exact)
                  (and (string-suffix-p "-themes" name)
                       (string-prefix-p root base)))
          (push (package-desc-name descriptor) candidates))))
    (delete-dups (nreverse candidates))))

(defun init/theme--read-package (slug)
  "Return the package to install for the gallery theme SLUG."
  (let ((candidates (init/theme--package-candidates slug)))
    (cond
     ((= (length candidates) 1) (car candidates))
     (candidates
      (intern (completing-read "Install package: "
                               (mapcar #'symbol-name candidates) nil t)))
     (t
      (intern (completing-read
               "Package not inferred; install package: "
               (mapcar (lambda (descriptor)
                         (symbol-name (package-desc-name descriptor)))
                       (init/theme--archive-descriptors))
               nil t slug))))))

(defun init/theme--themes-in-package (package)
  "Return the themes declared by the installed PACKAGE."
  (when-let* ((descriptor (cadr (assq package package-alist)))
              (directory (package-desc-dir descriptor)))
    (let (themes)
      (dolist (file (directory-files-recursively directory "-theme\\.el\\'"))
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (point-min))
          (while (re-search-forward
                  "(\\(?:def\\|provide\\)-?theme[[:space:]]+'?\\([^()[:space:]]+\\)"
                  nil t)
            (push (intern (match-string 1)) themes))))
      (delete-dups themes))))

(defun init/theme--read-theme-of-package (package slug)
  "Return the theme PACKAGE provides for the gallery entry SLUG."
  (let* ((themes (or (init/theme--themes-in-package package)
                     (custom-available-themes)))
         (wanted (string-remove-suffix "-theme" slug)))
    (or (seq-find (lambda (theme)
                    (equal wanted
                           (string-remove-suffix "-theme" (symbol-name theme))))
                  themes)
        (intern (completing-read "Theme provided by package: "
                                 (mapcar #'symbol-name themes) nil t)))))

(defun init/theme-gallery (&optional refresh-packages)
  "Pick a theme from EmacsThemes, install its package, and select it.
With prefix argument REFRESH-PACKAGES, refresh package metadata first."
  (interactive "P")
  (when (or refresh-packages (null package-archive-contents))
    (package-refresh-contents))
  (let* ((entries (init/theme--gallery-entries))
         (display (completing-read "EmacsThemes theme: " entries nil t))
         (slug (cdr (assoc display entries)))
         (package (init/theme--read-package slug)))
    (unless (package-installed-p package)
      (package-install package))
    (let ((theme (init/theme--read-theme-of-package package slug)))
      (init/theme-preview-buffer)
      (init/theme-select theme))))

(defun init/theme-gallery-web ()
  "Open the EmacsThemes visual gallery in the default browser."
  (interactive)
  (browse-url init/theme-gallery-url))

;;;; The generated Wallust theme

;; Wallust regenerates themes/wallust-theme.el from the current wallpaper
;; by writing a new file over the old one.  File notification misses that
;; atomic replacement often enough to be unreliable, so the file is polled
;; instead and the theme reloaded in place when it changes.

(defvar init/wallust-theme-watch-timer nil
  "Timer polling the generated Wallust theme file.")

(defvar init/wallust-theme-modification-time nil
  "Last observed modification time of the generated Wallust theme.")

(defun init/wallust-theme-file ()
  "Return the path of the generated Wallust theme."
  (expand-file-name "themes/wallust-theme.el" user-emacs-directory))

(defun init/reload-wallust-theme-if-active ()
  "Reload the generated Wallust theme without changing the selected theme."
  (when (custom-theme-enabled-p 'wallust)
    (disable-theme 'wallust)
    (load-theme 'wallust t)))

(defun init/check-wallust-theme-file ()
  "Reload the active Wallust theme after its generated file changed."
  (when-let* ((attributes (file-attributes (init/wallust-theme-file)))
              (modified (file-attribute-modification-time attributes)))
    (unless (equal modified init/wallust-theme-modification-time)
      (prog1
          (when init/wallust-theme-modification-time
            (init/reload-wallust-theme-if-active))
        (setq init/wallust-theme-modification-time modified)))))

(defun init/watch-wallust-theme ()
  "Start polling Wallust's theme file, if it is not already watched."
  (unless (timerp init/wallust-theme-watch-timer)
    (setq init/wallust-theme-modification-time
          (when-let* ((attributes (file-attributes (init/wallust-theme-file))))
            (file-attribute-modification-time attributes)))
    (setq init/wallust-theme-watch-timer
          (run-with-timer 1 1 #'init/check-wallust-theme-file))))

;;;; Activation

(init/watch-wallust-theme)
(init/theme-load-selected)
(init/ensure-default-font)

(add-hook 'after-init-hook #'init/apply-pending-font-family)
(add-hook 'after-make-frame-functions #'init/maybe-apply-pending-font)

(global-set-key (kbd bind/theme-preview) #'init/theme-preview-and-select)
(global-set-key (kbd bind/theme-gallery) #'init/theme-gallery)

(provide 'init-theme)
;;; init-theme.el ends here
