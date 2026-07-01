;;; pdf-setup.el --- PDF support (pdf-tools) -*- lexical-binding: t; -*-

;;; Commentary:

;; Full PDF support via pdf-tools, with a Treemacs-style clickable
;; toolbar in the header line of every PDF buffer.
;;
;; pdf-tools needs a small native helper (epdfinfo) compiled against
;; poppler.  Opening a PDF when the helper is missing offers to build
;; it automatically: pdf-tools' bundled `autobuild' script detects the
;; distribution (Fedora, Arch, Debian/Ubuntu, openSUSE, Gentoo, Void,
;; Alpine, NixOS, macOS, ...), installs the build dependencies with the
;; native package manager, compiles epdfinfo, and installs it into the
;; package directory.  The build runs in a terminal buffer so sudo can
;; prompt for a password; when it finishes, any PDFs that were waiting
;; open automatically.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function pdf-tools-install "pdf-tools")
(declare-function pdf-view-mode "pdf-view")
(declare-function pdf-view-current-page "pdf-view")
(declare-function pdf-cache-number-of-pages "pdf-cache")
(declare-function term-mode "term")
(declare-function term-char-mode "term")
(defvar pdf-info-epdfinfo-program)
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
  ;; pdf-isearch replaces the usual consult line search in PDFs.
  (define-key pdf-view-mode-map (kbd "C-s") #'isearch-forward)
  (add-hook 'pdf-view-mode-hook #'init/pdf-view-setup))

;;;; Opening PDFs (with automatic helper build)

(defun init/pdf-server-ready-p ()
  "Return non-nil when the epdfinfo helper is built and executable."
  (require 'pdf-tools)
  (and pdf-info-epdfinfo-program
       (file-executable-p pdf-info-epdfinfo-program)))

(defvar init/pdf--installed nil
  "Non-nil once `pdf-tools-install' has run in this session.")

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

(defvar init/pdf--build-pending-buffers nil
  "PDF buffers waiting for the epdfinfo build to finish.")

(defvar init/pdf--build-in-progress nil
  "Non-nil while the epdfinfo build is running.")

(defun init/pdf--autobuild-script ()
  "Return the path of pdf-tools' bundled autobuild script."
  (expand-file-name "build/server/autobuild"
                    (file-name-directory (locate-library "pdf-tools"))))

(defun init/pdf--request-build (pdf-buffer)
  "Queue PDF-BUFFER and offer to build the epdfinfo helper."
  (cl-pushnew pdf-buffer init/pdf--build-pending-buffers)
  (cond
   (init/pdf--build-in-progress
    (message "epdfinfo build already running; this PDF opens when it finishes"))
   ((y-or-n-p "PDF support needs the epdfinfo helper.  Build it now? (installs poppler/libpng dev packages via your package manager) ")
    (init/pdf-build-server))
   (t
    (message "PDF not rendered.  Run M-x init/pdf-build-server when ready."))))

(defun init/pdf-build-server ()
  "Build the epdfinfo helper, installing distro dependencies first.
Runs pdf-tools' autobuild script, which detects the distribution and
uses its package manager (dnf, apt, pacman, zypper, ...) for the build
dependencies.  Runs in a terminal buffer so sudo can ask for your
password.  PDFs opened in the meantime display once the build ends."
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
           (setq init/pdf--build-in-progress nil)
           (if (init/pdf-server-ready-p)
               (progn
                 (message "epdfinfo built; opening pending PDFs")
                 (when-let ((window (get-buffer-window (process-buffer process))))
                   (quit-window nil window))
                 (init/pdf--open-pending-buffers))
             (message "epdfinfo build failed; see the %s buffer"
                      (buffer-name (process-buffer process))))))))))

(defun init/pdf--open-pending-buffers ()
  "Turn every queued PDF buffer over to pdf-view."
  (dolist (buffer init/pdf--build-pending-buffers)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (init/pdf-open))))
  (setq init/pdf--build-pending-buffers nil))

;;;; Toolbar (fixed header line, like the Treemacs buttons)

(defface init/pdf-toolbar-button
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for the clickable buttons in the PDF toolbar."
  :group 'pdf-tools)

(defface init/pdf-toolbar-info
  '((t :inherit shadow))
  "Face for non-button text in the PDF toolbar."
  :group 'pdf-tools)

(defun init/pdf--toolbar-keymap (command)
  "Return a keymap running COMMAND on a header-line mouse-1 click."
  (let ((map (make-sparse-keymap)))
    (define-key map [header-line mouse-1]
                (lambda (event)
                  (interactive "e")
                  (with-selected-window (posn-window (event-start event))
                    (call-interactively command))))
    map))

(defun init/pdf--button (label help command)
  "Return a clickable toolbar LABEL running COMMAND.  HELP is the tooltip."
  (propertize label
              'help-echo help
              'mouse-face 'highlight
              'pointer 'hand
              'face 'init/pdf-toolbar-button
              'local-map (init/pdf--toolbar-keymap command)))

(defun init/pdf--toolbar-sep ()
  "Return the group separator used in the PDF toolbar."
  (propertize "  │  " 'face 'init/pdf-toolbar-info))

(defun init/pdf--page-indicator ()
  "Return a clickable current-page/page-count indicator."
  (let ((pages (ignore-errors (pdf-cache-number-of-pages))))
    (propertize (format " %d/%s "
                        (or (ignore-errors (pdf-view-current-page)) 0)
                        (or pages "?"))
                'help-echo "mouse-1: go to page…"
                'mouse-face 'highlight
                'face 'init/pdf-toolbar-info
                'local-map (init/pdf--toolbar-keymap #'pdf-view-goto-page))))

(defun init/pdf-open-externally ()
  "Open the current PDF in the system's default viewer."
  (interactive)
  (unless buffer-file-name
    (user-error "Buffer is not visiting a PDF file"))
  (browse-url-xdg-open buffer-file-name))

(defun init/pdf--toolbar ()
  "Build the PDF toolbar shown in the header line."
  (concat
   " "
   ;; Navigation
   (init/pdf--button "⇤" "First page" #'pdf-view-first-page) " "
   (init/pdf--button "◀" "Previous page" #'pdf-view-previous-page-command)
   (init/pdf--page-indicator)
   (init/pdf--button "▶" "Next page" #'pdf-view-next-page-command) " "
   (init/pdf--button "⇥" "Last page" #'pdf-view-last-page)
   (init/pdf--toolbar-sep)
   ;; History
   (init/pdf--button "↶" "Jump back (history)" #'pdf-history-backward) " "
   (init/pdf--button "↷" "Jump forward (history)" #'pdf-history-forward)
   (init/pdf--toolbar-sep)
   ;; Zoom and fit
   (init/pdf--button "−" "Zoom out" #'pdf-view-shrink) " "
   (init/pdf--button "＋" "Zoom in" #'pdf-view-enlarge) " "
   (init/pdf--button "⊙" "Reset zoom" #'pdf-view-scale-reset) " "
   (init/pdf--button "↔" "Fit page width" #'pdf-view-fit-width-to-window) " "
   (init/pdf--button "↕" "Fit whole page" #'pdf-view-fit-page-to-window)
   (init/pdf--toolbar-sep)
   ;; View
   (init/pdf--button "⟳" "Rotate 90°" #'pdf-view-rotate) " "
   (init/pdf--button "▣" "Toggle margin trimming (auto slice)"
                     #'pdf-view-auto-slice-minor-mode) " "
   (init/pdf--button "◐" "Toggle dark (midnight) rendering"
                     #'pdf-view-midnight-minor-mode)
   (init/pdf--toolbar-sep)
   ;; Tools
   (init/pdf--button "☰" "Outline / table of contents" #'pdf-outline) " "
   (init/pdf--button "⌕" "Search the document (occur)" #'pdf-occur) " "
   (init/pdf--button "✎" "Highlight the selected text"
                     #'pdf-annot-add-highlight-markup-annotation) " "
   (init/pdf--button "❝" "Add a note at point" #'pdf-annot-add-text-annotation) " "
   (init/pdf--button "≡" "List annotations" #'pdf-annot-list-annotations) " "
   (init/pdf--button "⇗" "Open in the system viewer" #'init/pdf-open-externally)))

(defun init/pdf-view-setup ()
  "Per-buffer setup for pdf-view: toolbar and comfort settings."
  (setq-local header-line-format '(:eval (init/pdf--toolbar)))
  ;; The blinking bar cursor is pointless on a rendered page.
  (setq-local cursor-type nil))

(provide 'pdf-setup)
;;; pdf-setup.el ends here
