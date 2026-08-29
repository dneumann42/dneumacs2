;;; init-docs.el --- Reading documents: PDF, web and Markdown -*- lexical-binding: t; -*-

;;; Commentary:

;; The three document formats that are read rather than programmed, each
;; given a header-line toolbar and prose-friendly rendering.
;;
;; PDF, via pdf-tools.  pdf-tools needs a small native helper, epdfinfo,
;; compiled against poppler.  Opening a PDF without it offers to build it:
;; pdf-tools' bundled autobuild script detects the distribution, installs
;; the build dependencies with the native package manager, compiles the
;; helper and installs it.  The build runs in a terminal buffer so sudo
;; can prompt for a password, and PDFs opened meanwhile display when it
;; finishes.
;;
;; Web, via EWW: a toolbar, a "jump to content" command that skips the
;; navigation-link soup at the top of most pages, readable view, and
;; pages rendered in the writer font with theme colours instead of the
;; site's own.
;;
;; Markdown, via markdown-mode: soft-wrapped, centred, proportional prose
;; with monospaced code, tables and links.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'init-theme)
(require 'init-toolbar)

;;; PDF

(declare-function pdf-cache-number-of-pages "pdf-cache")
(declare-function pdf-tools-install "pdf-tools")
(declare-function pdf-view-current-page "pdf-view")
(declare-function pdf-view-goto-page "pdf-view")
(declare-function pdf-view-midnight-minor-mode "pdf-view")
(declare-function pdf-view-mode "pdf-view")
(declare-function term-char-mode "term")
(declare-function term-mode "term")
(defvar pdf-info-epdfinfo-program)
(defvar pdf-view-midnight-colors)
(defvar pdf-view-mode-map)

(use-package pdf-tools
  :ensure t
  :defer t
  :custom
  (pdf-view-display-size 'fit-page)
  (pdf-view-resize-factor 1.1)
  (pdf-view-use-scaling t)
  ;; Pop annotations open right after creating them.
  (pdf-annot-activate-created-annotations t)
  :config
  ;; pdf-isearch replaces the usual consult line search inside PDFs.
  (define-key pdf-view-mode-map (kbd "C-s") #'isearch-forward)
  (add-hook 'pdf-view-mode-hook #'init/pdf-view-setup))

;;;; Opening a PDF, building the helper on demand

(defvar init/pdf--installed nil
  "Non-nil once `pdf-tools-install' has run in this session.")

(defvar init/pdf--build-pending-buffers nil
  "PDF buffers waiting for the epdfinfo build to finish.")

(defvar init/pdf--build-in-progress nil
  "Non-nil while the epdfinfo build is running.")

(defun init/pdf-server-ready-p ()
  "Return non-nil when the epdfinfo helper is built and executable."
  (require 'pdf-tools)
  (and pdf-info-epdfinfo-program
       (file-executable-p pdf-info-epdfinfo-program)))

(defun init/pdf-open ()
  "Open the current buffer with pdf-view, building epdfinfo if needed.
Used as the `auto-mode-alist' handler for PDF files."
  (require 'pdf-tools)
  (if (init/pdf-server-ready-p)
      (progn
        (unless init/pdf--installed
          (setq init/pdf--installed t)
          (pdf-tools-install :no-query))
        (pdf-view-mode))
    (fundamental-mode)
    (init/pdf--request-build (current-buffer))))

(add-to-list 'auto-mode-alist '("\\.[pP][dD][fF]\\'" . init/pdf-open))
(add-to-list 'magic-mode-alist '("%PDF" . init/pdf-open))

(defun init/pdf--autobuild-script ()
  "Return the path of pdf-tools' bundled autobuild script."
  (expand-file-name "build/server/autobuild"
                    (file-name-directory (locate-library "pdf-tools"))))

(defun init/pdf--request-build (buffer)
  "Queue the PDF BUFFER and offer to build the epdfinfo helper."
  (cl-pushnew buffer init/pdf--build-pending-buffers)
  (cond
   (init/pdf--build-in-progress
    (message "epdfinfo build already running; this PDF opens when it finishes"))
   ((y-or-n-p (concat "PDF support needs the epdfinfo helper.  Build it now? "
                      "(installs poppler/libpng dev packages via your "
                      "package manager) "))
    (init/pdf-build-server))
   (t
    (message "PDF not rendered.  Run M-x init/pdf-build-server when ready."))))

(defun init/pdf--open-pending-buffers ()
  "Turn every queued PDF buffer over to pdf-view."
  (dolist (buffer init/pdf--build-pending-buffers)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (init/pdf-open))))
  (setq init/pdf--build-pending-buffers nil))

(defun init/pdf--build-finished (process)
  "Handle the end of the epdfinfo build PROCESS."
  (setq init/pdf--build-in-progress nil)
  (if (init/pdf-server-ready-p)
      (progn
        (message "epdfinfo built; opening pending PDFs")
        (when-let* ((window (get-buffer-window (process-buffer process))))
          (quit-window nil window))
        (init/pdf--open-pending-buffers))
    (message "epdfinfo build failed; see the %s buffer"
             (buffer-name (process-buffer process)))))

(defun init/pdf-build-server ()
  "Build the epdfinfo helper, installing distribution dependencies first.
Runs pdf-tools' autobuild script, which detects the distribution and uses
its package manager for the build dependencies.  It runs in a terminal
buffer so sudo can ask for a password.  PDFs opened in the meantime
display once the build ends."
  (interactive)
  (require 'pdf-tools)
  (require 'term)
  (let ((script (init/pdf--autobuild-script))
        (target (directory-file-name
                 (file-name-directory pdf-info-epdfinfo-program))))
    (unless (file-exists-p script)
      (user-error "autobuild script not found at %s" script))
    (setq init/pdf--build-in-progress t)
    (let ((buffer (make-term "epdfinfo build" "bash" nil script "-i" target)))
      (with-current-buffer buffer
        (term-mode)
        (term-char-mode))
      (pop-to-buffer buffer)
      (set-process-sentinel
       (get-buffer-process buffer)
       (lambda (process _event)
         (unless (process-live-p process)
           (init/pdf--build-finished process)))))))

;;;; Dark rendering

(defcustom init/pdf-midnight-enabled nil
  "Whether PDFs render in dark (midnight) mode.
Toggled by `init/pdf-toggle-midnight' and saved through Customize, so the
choice survives restarts."
  :type 'boolean
  :group 'pdf-tools)

(defun init/pdf--theme-midnight-colors ()
  "Return (FOREGROUND . BACKGROUND) taken from the current theme."
  (cons (face-attribute 'default :foreground nil t)
        (face-attribute 'default :background nil t)))

(defun init/pdf-toggle-midnight ()
  "Toggle dark rendering for PDFs and remember the choice.
The rendering colours come from the active theme, and the on/off state
persists across sessions."
  (interactive)
  (let ((enable (not (bound-and-true-p pdf-view-midnight-minor-mode))))
    (setq pdf-view-midnight-colors (init/pdf--theme-midnight-colors))
    (pdf-view-midnight-minor-mode (if enable 1 -1))
    (customize-save-variable 'init/pdf-midnight-enabled enable)
    (message "PDF dark mode %s (persisted)" (if enable "on" "off"))))

;;;; PDF toolbar

(defun init/pdf--page-indicator ()
  "Return a clickable current-page/page-count indicator."
  (init/toolbar-info
   (format "%d/%s"
           (or (ignore-errors (pdf-view-current-page)) 0)
           (or (ignore-errors (pdf-cache-number-of-pages)) "?"))
   "mouse-1: go to page…"
   #'pdf-view-goto-page))

(defun init/pdf-open-externally ()
  "Open the current PDF in the system's default viewer."
  (interactive)
  (unless buffer-file-name
    (user-error "Buffer is not visiting a PDF file"))
  (browse-url-xdg-open buffer-file-name))

(defun init/pdf--toolbar ()
  "Build the PDF toolbar shown in the header line."
  (init/toolbar-string
   '("⇤" "First page" pdf-view-first-page)
   '("◀" "Previous page" pdf-view-previous-page-command)
   #'init/pdf--page-indicator
   '("▶" "Next page" pdf-view-next-page-command)
   '("⇥" "Last page" pdf-view-last-page)
   :sep
   '("↶" "Jump back (history)" pdf-history-backward)
   '("↷" "Jump forward (history)" pdf-history-forward)
   :sep
   '("−" "Zoom out" pdf-view-shrink)
   '("＋" "Zoom in" pdf-view-enlarge)
   '("⊙" "Reset zoom" pdf-view-scale-reset)
   '("↔" "Fit page width" pdf-view-fit-width-to-window)
   '("↕" "Fit whole page" pdf-view-fit-page-to-window)
   :sep
   '("⟳" "Rotate 90°" pdf-view-rotate)
   '("▣" "Toggle margin trimming (auto slice)" pdf-view-auto-slice-minor-mode)
   '("◐" "Toggle dark rendering (persists)" init/pdf-toggle-midnight)
   :sep
   '("☰" "Outline / table of contents" pdf-outline)
   '("⌕" "Search the document (occur)" pdf-occur)
   '("✎" "Highlight the selected text" pdf-annot-add-highlight-markup-annotation)
   '("❝" "Add a note at point" pdf-annot-add-text-annotation)
   '("≡" "List annotations" pdf-annot-list-annotations)
   '("⇗" "Open in the system viewer" init/pdf-open-externally)))

(defun init/pdf-view-setup ()
  "Set up a pdf-view buffer: toolbar, dark mode, comfort settings."
  (init/toolbar-attach #'init/pdf--toolbar)
  (when init/pdf-midnight-enabled
    (setq pdf-view-midnight-colors (init/pdf--theme-midnight-colors))
    (pdf-view-midnight-minor-mode 1))
  ;; A blinking bar cursor is pointless on a rendered page.
  (setq-local cursor-type nil))

;;; Web

(declare-function eww "eww" (url &optional new-buffer))
(defvar eww-data)
(defvar eww-mode-map)
(defvar eww-search-prefix)

(use-package eww
  :ensure nil
  :defer t
  :custom
  (eww-search-prefix "https://duckduckgo.com/html/?q=")
  ;; Name buffers after the page: *eww: Some Title*.
  (eww-auto-rename-buffer 'title)
  (eww-history-limit 150)
  ;; Render with theme colours, not the site's; keep lines readable.
  (shr-use-colors nil)
  (shr-max-width 100)
  (shr-max-image-proportion 0.7)
  (shr-discard-aria-hidden t)
  :config
  (define-key eww-mode-map (kbd "j") #'init/eww-jump-to-content)
  (add-hook 'eww-mode-hook #'init/eww-setup)
  ;; EWW resets `header-line-format' to its own title/URL line on every
  ;; page render, clobbering anything the mode hook installed.  Override
  ;; the updater so each render (re)installs the toolbar instead; the
  ;; title and URL are shown in the toolbar's info segment anyway.
  (advice-add 'eww-update-header-line-format :override
              #'init/eww--attach-toolbar))

(defvar init/ddg-history nil
  "Minibuffer history for `ddg' searches.")

(defun ddg (query)
  "Search DuckDuckGo for QUERY in EWW.
Interactively, default to the active region or the symbol at point.
Unlike `eww', the input is always treated as a search query, never as a
URL."
  (interactive
   (let ((default (if (use-region-p)
                      (buffer-substring-no-properties
                       (region-beginning) (region-end))
                    (thing-at-point 'symbol t))))
     (list (read-string (format-prompt "DuckDuckGo" default)
                        nil 'init/ddg-history default))))
  (when (string-empty-p (string-trim query))
    (user-error "Nothing to search for"))
  (eww (concat eww-search-prefix (url-hexify-string query))))

;;;; Jumping past the navigation

(defconst init/eww-content-min-words 25
  "Minimum word count for a paragraph to count as body content.")

(defconst init/eww-content-max-link-ratio 0.4
  "Maximum fraction of link characters for body content.
Navigation blocks are mostly links; article text is mostly not.")

(defun init/eww--link-ratio (start end)
  "Return the fraction of characters between START and END that are links."
  (let ((links 0))
    (cl-loop for position from start below end
             when (get-text-property position 'shr-url)
             do (cl-incf links))
    (/ (float links) (- end start))))

(defun init/eww--content-paragraph-p (start end)
  "Return non-nil when START..END looks like a real content paragraph."
  (and (> end start)
       (>= (count-words start end) init/eww-content-min-words)
       (< (init/eww--link-ratio start end) init/eww-content-max-link-ratio)))

(defun init/eww--find-content ()
  "Return the position of the first body-text paragraph, or nil."
  (save-excursion
    (goto-char (point-min))
    (let (found)
      (while (and (not found) (not (eobp)))
        (let ((start (progn (skip-chars-forward " \t\n") (point)))
              (end (progn (forward-paragraph) (point))))
          (if (init/eww--content-paragraph-p start end)
              (setq found start)
            ;; A zero-length paragraph would loop forever.
            (when (= end start) (forward-line 1)))))
      found)))

(defun init/eww-jump-to-content ()
  "Move past navigation junk to the first substantial paragraph.
Scans from the top of the page for the first paragraph with enough words,
and few enough links, to be body text."
  (interactive)
  (if-let* ((position (init/eww--find-content)))
      (progn
        (goto-char position)
        (recenter 1)
        (when (fboundp 'pulse-momentary-highlight-one-line)
          (pulse-momentary-highlight-one-line (point))))
    (message "No obvious content paragraph found")))

;;;; EWW toolbar

(defun init/eww--toolbar-title ()
  "Return the page title, or its URL, as a toolbar segment."
  (let ((title (plist-get eww-data :title))
        (url (plist-get eww-data :url)))
    (init/toolbar-info
     (truncate-string-to-width
      (if (and title (not (string-empty-p title))) title (or url ""))
      50 nil nil "…")
     (or url "No page loaded"))))

(defun init/eww--toolbar ()
  "Build the EWW toolbar shown in the header line."
  (init/toolbar-string
   '("←" "Back" eww-back-url)
   '("→" "Forward" eww-forward-url)
   '("⟳" "Reload page" eww-reload)
   :sep
   '("⌕" "Open URL or web search" eww)
   '("⤓" "Jump to the main content" init/eww-jump-to-content)
   '("◈" "Readable view (article only)" eww-readable)
   :sep
   '("−" "Smaller text" text-scale-decrease)
   '("＋" "Larger text" text-scale-increase)
   :sep
   '("★" "Bookmark this page" eww-add-bookmark)
   '("≡" "List bookmarks" eww-list-bookmarks)
   '("↺" "Browsing history" eww-list-histories)
   :sep
   '("❐" "Copy the page URL" eww-copy-page-url)
   '("⇗" "Open in the external browser" eww-browse-with-external-browser)
   :sep
   #'init/eww--toolbar-title))

(defun init/eww--attach-toolbar ()
  "Install the EWW toolbar in the current buffer's header line."
  (init/toolbar-attach #'init/eww--toolbar))

(defun init/eww-setup ()
  "Set up an EWW buffer: toolbar and writerly rendering."
  (init/eww--attach-toolbar)
  ;; Proportional text (shr's default) in the writer font, like Org.
  (when (display-graphic-p)
    (when-let* ((family (init/ensure-writer-font)))
      (face-remap-add-relative 'variable-pitch :family family :height 1.2)))
  (setq-local line-spacing 0.1))

;;; Markdown

(defgroup init/markdown nil
  "Markdown editing defaults."
  :group 'text)

(defvar markdown-command)

(defcustom init/markdown-fill-column 96
  "Visual line width for Markdown buffers."
  :type 'integer
  :group 'init/markdown)

(defcustom init/markdown-command-candidates
  '(("pandoc" . "pandoc -f markdown -t html")
    ("multimarkdown" . "multimarkdown")
    ("markdown" . "markdown"))
  "Markdown renderers to try for the in-Emacs HTML preview."
  :type '(alist :key-type string :value-type string)
  :group 'init/markdown)

(defun init/markdown-command ()
  "Return the first available Markdown rendering command, or nil."
  (cdr (seq-find (lambda (candidate) (executable-find (car candidate)))
                 init/markdown-command-candidates)))

(defun init/markdown-setup ()
  "Enable comfortable Markdown editing defaults for the current buffer."
  (setq-local markdown-fontify-code-blocks-natively t
              markdown-hide-markup t
              markdown-enable-wiki-links t
              fill-column init/markdown-fill-column)
  (visual-line-mode 1)
  (variable-pitch-mode 1)
  (when (fboundp 'visual-fill-column-mode)
    (visual-fill-column-mode 1)))

(defun init/markdown-preview ()
  "Preview the current Markdown buffer inside Emacs."
  (interactive)
  (unless markdown-command
    (user-error "Install pandoc, multimarkdown, or markdown for live preview"))
  (markdown-live-preview-mode 'toggle))

(defun init/markdown--set-faces ()
  "Style the Markdown faces: proportional prose, monospaced structure."
  (set-face-attribute 'markdown-header-face nil
                      :inherit 'font-lock-function-name-face :weight 'bold)
  (set-face-attribute 'markdown-header-face-1 nil :height 1.35)
  (set-face-attribute 'markdown-header-face-2 nil :height 1.22)
  (set-face-attribute 'markdown-header-face-3 nil :height 1.12)
  (set-face-attribute 'markdown-code-face nil
                      :inherit '(fixed-pitch font-lock-constant-face))
  (set-face-attribute 'markdown-pre-face nil
                      :inherit '(fixed-pitch font-lock-string-face))
  (set-face-attribute 'markdown-table-face nil
                      :inherit '(fixed-pitch font-lock-builtin-face))
  (set-face-attribute 'markdown-blockquote-face nil
                      :inherit 'font-lock-doc-face :slant 'italic)
  (set-face-attribute 'markdown-link-face nil
                      :inherit 'link :underline nil :weight 'semi-bold)
  (set-face-attribute 'markdown-url-face nil :inherit 'shadow))

(use-package markdown-mode
  :mode (("\\.md\\'" . gfm-mode)
         ("\\.markdown\\'" . markdown-mode)
         ("README\\(?:\\.md\\)?\\'" . gfm-mode))
  :commands (markdown-mode gfm-mode markdown-live-preview-mode)
  :hook ((markdown-mode gfm-mode) . init/markdown-setup)
  :bind (:map markdown-mode-map
              ("C-c C-p" . init/markdown-preview)
              :map gfm-mode-map
              ("C-c C-p" . init/markdown-preview))
  :custom
  (markdown-command (init/markdown-command))
  (markdown-fontify-code-blocks-natively t)
  (markdown-gfm-uppercase-checkbox t)
  (markdown-header-scaling t)
  (markdown-hide-urls t)
  (markdown-list-indent-width 2)
  (markdown-make-gfm-checkboxes-buttons t)
  :config
  (init/markdown--set-faces))

(use-package visual-fill-column
  :hook ((markdown-mode gfm-mode) . visual-fill-column-mode)
  :custom
  (visual-fill-column-center-text t)
  (visual-fill-column-width init/markdown-fill-column))

(provide 'init-docs)
;;; init-docs.el ends here
