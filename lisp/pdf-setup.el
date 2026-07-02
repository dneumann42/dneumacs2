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

;;;; Persistent, theme-aware dark (midnight) rendering

(defcustom init/pdf-midnight-enabled nil
  "Whether PDFs render in dark (midnight) mode.
Toggled by `init/pdf-toggle-midnight' and saved via Customize, so the
choice survives restarts."
  :type 'boolean
  :group 'pdf-tools)

(defun init/pdf--theme-midnight-colors ()
  "Return (FOREGROUND . BACKGROUND) taken from the current theme."
  (cons (face-attribute 'default :foreground nil t)
        (face-attribute 'default :background nil t)))

(defun init/pdf-toggle-midnight ()
  "Toggle dark rendering for PDFs and remember the choice.
The rendering colors come from the active theme, and the on/off state
persists across sessions."
  (interactive)
  (let ((enable (not (bound-and-true-p pdf-view-midnight-minor-mode))))
    (setq pdf-view-midnight-colors (init/pdf--theme-midnight-colors))
    (pdf-view-midnight-minor-mode (if enable 1 -1))
    (customize-save-variable 'init/pdf-midnight-enabled enable)
    (message "PDF dark mode %s (persisted)" (if enable "on" "off"))))

;;;; Toolbar (fixed header line, like the Treemacs buttons)

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
   ;; Navigation
   '("⇤" "First page" pdf-view-first-page)
   '("◀" "Previous page" pdf-view-previous-page-command)
   #'init/pdf--page-indicator
   '("▶" "Next page" pdf-view-next-page-command)
   '("⇥" "Last page" pdf-view-last-page)
   :sep
   ;; History
   '("↶" "Jump back (history)" pdf-history-backward)
   '("↷" "Jump forward (history)" pdf-history-forward)
   :sep
   ;; Zoom and fit
   '("−" "Zoom out" pdf-view-shrink)
   '("＋" "Zoom in" pdf-view-enlarge)
   '("⊙" "Reset zoom" pdf-view-scale-reset)
   '("↔" "Fit page width" pdf-view-fit-width-to-window)
   '("↕" "Fit whole page" pdf-view-fit-page-to-window)
   :sep
   ;; View
   '("⟳" "Rotate 90°" pdf-view-rotate)
   '("▣" "Toggle margin trimming (auto slice)" pdf-view-auto-slice-minor-mode)
   '("◐" "Toggle dark rendering (persists)" init/pdf-toggle-midnight)
   :sep
   ;; Tools
   '("☰" "Outline / table of contents" pdf-outline)
   '("⌕" "Search the document (occur)" pdf-occur)
   '("✎" "Highlight the selected text" pdf-annot-add-highlight-markup-annotation)
   '("❝" "Add a note at point" pdf-annot-add-text-annotation)
   '("≡" "List annotations" pdf-annot-list-annotations)
   '("⇗" "Open in the system viewer" init/pdf-open-externally)))

(defun init/pdf-view-setup ()
  "Per-buffer setup for pdf-view: toolbar, dark mode, comfort settings."
  (init/toolbar-attach #'init/pdf--toolbar)
  ;; Restore the persisted dark-mode choice with theme colors.
  (when init/pdf-midnight-enabled
    (setq pdf-view-midnight-colors (init/pdf--theme-midnight-colors))
    (pdf-view-midnight-minor-mode 1))
  ;; The blinking bar cursor is pointless on a rendered page.
  (setq-local cursor-type nil))

(provide 'pdf-setup)
;;; pdf-setup.el ends here
