;;; init-lang-nim.el --- Nim -*- lexical-binding: t; -*-

;;; Commentary:

;; Nim editing: project scaffolding, nimsuggest integration, Flycheck
;; diagnostics shown in a hover popup, token-based motion commands, nph
;; formatting, run and test helpers, and a browser for the installed
;; toolchain's documentation.
;;
;; Nim is the one language here that does not use Eglot.  nimsuggest is
;; queried directly, so most `init/ide-*' actions are overridden.
;;
;; The documentation browser reads the tab-separated .idx index files Nim
;; generates next to every module.html, so search results carry the exact
;; page, anchor and signature and always match the compiler in use.  When
;; no local docs are found it falls back to nim-lang.org, where only
;; whole-page browsing is possible.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'init-ide)
(require 'init-keys)
(require 'init-lib)

(declare-function eww "eww" (url &optional new-buffer))
(declare-function flycheck-buffer "flycheck")
(declare-function flycheck-error-buffer "flycheck")
(declare-function flycheck-error-checker "flycheck")
(declare-function flycheck-error-end-line "flycheck")
(declare-function flycheck-error-filename "flycheck")
(declare-function flycheck-error-format-position "flycheck")
(declare-function flycheck-error-level "flycheck")
(declare-function flycheck-error-level-error-list-face "flycheck")
(declare-function flycheck-error-line "flycheck")
(declare-function flycheck-error-message "flycheck")
(declare-function flycheck-error-< "flycheck")
(declare-function flycheck-list-errors "flycheck")
(declare-function flycheck-overlay-errors-at "flycheck")
(declare-function nim-mode "nim-mode")
(declare-function nimsuggest-available-p "nim-suggest")
(declare-function nimsuggest-mode "nim-suggest")
(declare-function nimsuggest-show-doc "nim-suggest")
(declare-function nimsuggest--call-epc "nim-suggest")
(declare-function nim--epc-column "nim-suggest")
(declare-function nim--epc-file "nim-suggest")
(declare-function nim--epc-line "nim-suggest")
(defvar nim-mode-map)
(defvar nimsuggest-local-options)
(defvar nimsuggest-path)

;;;; Toolchain paths and project layout

(defconst init/nim-nimble-bin (expand-file-name "~/.nimble/bin")
  "Directory where nimble installs user binaries.")

(defconst init/nim-local-bin (expand-file-name "bin" user-emacs-directory)
  "Directory holding local wrapper scripts for the Nim integration.")

(defun init/nim--ensure-nimble-path ()
  "Make nimble-installed tools visible to Emacs."
  (init/prepend-to-path init/nim-nimble-bin)
  (init/prepend-to-path init/nim-local-bin))

(init/nim--ensure-nimble-path)

;; nim-suggest requires nim-mode and the whole epc stack; loading it here
;; would drag all of that in at startup even when no Nim file is opened.
(with-eval-after-load 'nim-mode
  (require 'nim-suggest))

(defun init/nim--nimble-root (&optional dir)
  "Return the nearest Nimble project root above DIR, or nil."
  (init/locate-dominating-match '("*.nimble") dir))

(defun init/nim--nimble-file (&optional dir)
  "Return the first Nimble file in DIR's project root, or nil."
  (when-let ((root (init/nim--nimble-root dir)))
    (car (file-expand-wildcards (expand-file-name "*.nimble" root)))))

(defun init/nim-project-root ()
  "Return the current Nim project root."
  (init/project-root-for '("*.nimble")))

(defconst init/nim-source-subdirectories '("src" nil "lib" "tests" "examples")
  "Project subdirectories searched for Nim sources, in precedence order.
A nil entry stands for the project root itself.")

(defun init/nim--project-search-paths (&optional dir)
  "Return the likely source search paths of the Nim project above DIR."
  (when-let ((root (init/nim--nimble-root dir)))
    (delete-dups
     (delq nil
           (mapcar (lambda (name)
                     (if (null name)
                         root
                       (let ((path (expand-file-name name root)))
                         (and (file-directory-p path) path))))
                   init/nim-source-subdirectories)))))

(defun init/nim--project-main-file (&optional dir)
  "Return the best Nim entry point for the project above DIR, or nil."
  (when-let* ((root (init/nim--nimble-root dir))
              (nimble-file (init/nim--nimble-file dir))
              (package (file-name-base nimble-file)))
    (cl-some (lambda (path) (and path (file-exists-p path) path))
             (list
              (expand-file-name (concat package ".nim") root)
              (expand-file-name (concat "src/" package ".nim") root)
              (car (file-expand-wildcards (expand-file-name "*.nim" root)))
              (car (file-expand-wildcards
                    (expand-file-name "src/*.nim" root)))))))

;;;; Project scaffolding

(defconst init/nim-scaffold-nimble-template
  (concat "# Package\n\n"
          "version       = \"0.0.0\"\n"
          "author        = \"\"\n"
          "description   = \"Generated Nim project\"\n"
          "license       = \"MIT\"\n"
          "srcDir        = \"src\"\n"
          "bin           = @[%S]\n\n"
          "requires \"nim >= 2.2.10\"\n")
  "Format string for a generated .nimble file; %S is the package name.")

(defun init/nim--bootstrap-project-name ()
  "Return a fallback name for a generated Nimble package."
  (let ((base (file-name-base (or (buffer-file-name) "project"))))
    (if (string-empty-p base) "project" base)))

(defun init/nim--write-file-if-missing (path content)
  "Write CONTENT to PATH unless PATH already exists."
  (unless (file-exists-p path)
    (make-directory (file-name-directory path) t)
    (with-temp-file path
      (insert content))))

(defun init/nim--ensure-project-scaffold ()
  "Create minimal Nim project metadata when the project has none."
  (let ((root (init/nim-project-root)))
    (unless (init/nim--nimble-root root)
      (let ((name (init/nim--bootstrap-project-name)))
        (init/nim--write-file-if-missing
         (expand-file-name (concat name ".nimble") root)
         (format init/nim-scaffold-nimble-template name))
        (init/nim--write-file-if-missing
         (expand-file-name "config.nims" root)
         "when fileExists(\"nimble.paths\"):\n  include \"nimble.paths\"\n")
        (init/nim--write-file-if-missing
         (expand-file-name "nimble.paths" root)
         (format "--path:\"%s\"\n" (expand-file-name "src" root)))))))

(defun init/nim-new-test ()
  "Create a new test file in the current Nimble project and open it."
  (interactive)
  (let* ((root (init/nim-project-root))
         (tests-dir (expand-file-name "tests" root))
         (config (expand-file-name "config.nims" tests-dir))
         (name (read-string "Test name: " "test"))
         (file (expand-file-name (concat name ".nim") tests-dir)))
    (make-directory tests-dir t)
    (init/nim--write-file-if-missing config "--path:\"../src\"\n")
    (init/nim--write-file-if-missing
     file
     (format "import unittest\n\n\nsuite \"%s\":\n\n  test \"\":\n    check true\n"
             name))
    (find-file file)))

;;;; Hover popup

(defconst init/nim-hover-buffer-name "*Nim hover*"
  "Name of the buffer used for Nim hover popups.")

(defconst init/nim-hover-background "#2b2b2b"
  "Background colour for Nim hover popups.")

(defvar-local init/nim--hover-point nil
  "Point at which the Nim hover popup was shown.")

(defvar-local init/nim--hover-source-buffer nil
  "Source buffer that owns the Nim hover popup.")

(defun init/nim--hover-hidehandler (info)
  "Return non-nil when the hover popup described by INFO should be hidden.
INFO is posframe's plist; the popup is dismissed as soon as point leaves
the position it was opened at, or the source buffer is left."
  (when-let* ((parent (cdr (plist-get info :posframe-parent-buffer))))
    (when (buffer-live-p parent)
      (let ((source (buffer-local-value 'init/nim--hover-source-buffer parent))
            (position (buffer-local-value 'init/nim--hover-point parent)))
        (or (not (buffer-live-p source))
            (not (eq (current-buffer) source))
            (/= (point) position))))))

(defun init/nim--hide-hover ()
  "Hide the Nim hover popup if it is visible."
  (setq init/nim--hover-point nil
        init/nim--hover-source-buffer nil)
  (init/popup-hide init/nim-hover-buffer-name))

(defun init/nim--show-hover (content)
  "Display CONTENT in a wrapped popup near point."
  (init/nim--hide-hover)
  (setq-local init/nim--hover-point (point))
  (setq-local init/nim--hover-source-buffer (current-buffer))
  (init/popup-show init/nim-hover-buffer-name content
                   :mode #'help-mode
                   :min-width 60
                   :max-width 120
                   :height 18
                   :background init/nim-hover-background
                   :hidehandler #'init/nim--hover-hidehandler))

;;;; Diagnostics

(defun init/nim--diagnostics-at-point ()
  "Return the Flycheck diagnostics at point, sorted by severity."
  (when (and (bound-and-true-p flycheck-mode)
             (fboundp 'flycheck-overlay-errors-at))
    (when-let ((errors (flycheck-overlay-errors-at (point))))
      (sort (copy-sequence errors) #'flycheck-error-<))))

(defun init/nim--error-snippet (error)
  "Return the source lines ERROR points at, or nil."
  (when-let ((buffer (flycheck-error-buffer error)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (save-excursion
          (save-restriction
            (widen)
            (let* ((line (max 1 (or (flycheck-error-line error) 1)))
                   (end-line (max line (or (flycheck-error-end-line error) line)))
                   (start (progn (goto-char (point-min))
                                 (forward-line (1- line))
                                 (line-beginning-position)))
                   (end (progn (goto-char (point-min))
                               (forward-line (1- end-line))
                               (line-end-position))))
              (string-trim-right
               (buffer-substring-no-properties start end)))))))))

(defun init/nim--fontify (text)
  "Return TEXT with Nim font-lock faces applied."
  (with-temp-buffer
    (insert text)
    (goto-char (point-min))
    (nim-mode)
    (font-lock-ensure)
    (buffer-substring (point-min) (point-max))))

(defun init/nim--format-diagnostic (error)
  "Format ERROR as a coloured diagnostic block."
  (let* ((level (flycheck-error-level error))
         (position (flycheck-error-format-position error))
         (filename (flycheck-error-filename error))
         (snippet (init/nim--error-snippet error)))
    (concat
     (propertize (upcase (symbol-name level))
                 'face (flycheck-error-level-error-list-face level))
     (propertize (format "  %s\n"
                         (if filename
                             (format "%s:%s" (file-relative-name filename)
                                     position)
                           position))
                 'face 'shadow)
     (propertize (format "%s\n"
                         (or (flycheck-error-message error)
                             "Unknown diagnostic"))
                 'face 'default)
     (propertize (format "(%s)\n" (flycheck-error-checker error)) 'face 'shadow)
     (when snippet
       (concat (propertize "code\n" 'face 'shadow)
               (init/nim--fontify snippet)
               "\n")))))

(defun init/nim--show-diagnostics (errors)
  "Display ERRORS in the Nim hover popup."
  (init/nim--show-hover
   (concat (propertize "Diagnostics at point\n" 'face 'bold)
           "\n"
           (string-join (mapcar #'init/nim--format-diagnostic errors) "\n"))))

(defun init/nim-hover-doc ()
  "Show documentation for the symbol at point."
  (interactive)
  (cond
   ((fboundp 'nimsuggest-show-doc)
    (condition-case err
        (nimsuggest-show-doc)
      (error (message "%s" (error-message-string err)))))
   ((fboundp 'eldoc-print-current-symbol-info)
    (eldoc-print-current-symbol-info))
   (t (message "No hover documentation command available."))))

(defun init/nim-hover-diagnostics ()
  "Show the diagnostics at point, or documentation when there are none."
  (interactive)
  (if-let ((errors (init/nim--diagnostics-at-point)))
      (init/nim--show-diagnostics errors)
    (init/nim-hover-doc)))

(defun init/nim-show-diagnostics ()
  "Show the diagnostics at point, or the whole error list when there are none."
  (interactive)
  (if-let ((errors (init/nim--diagnostics-at-point)))
      (init/nim--show-diagnostics errors)
    (if (fboundp 'flycheck-list-errors)
        (flycheck-list-errors)
      (message "No diagnostics UI available."))))

;;;; nimsuggest

(defcustom init/nim-goto-definition-timeout 6.0
  "Seconds to wait for nimsuggest to answer a definition query.
Generous enough to cover a cold nimsuggest server start."
  :type 'number
  :group 'tools)

(defun init/nim--ensure-nimsuggest-path ()
  "Point `nimsuggest-path' at an executable nimsuggest when one exists.
The variable is computed once when nim-suggest loads, so it is
re-detected in case nimsuggest was installed, or added to PATH,
afterwards."
  (unless (and (boundp 'nimsuggest-path)
               nimsuggest-path
               (file-executable-p nimsuggest-path))
    (init/nim--ensure-nimble-path)
    (when-let ((path (executable-find "nimsuggest")))
      (setq nimsuggest-path path))))

(defun init/nim--enable-nimsuggest ()
  "Discover nimsuggest and enable `nimsuggest-mode' in the current buffer."
  (init/nim--ensure-nimsuggest-path)
  (setq-local nimsuggest-local-options
              (mapcar (lambda (path) (concat "--path:" path))
                      (init/nim--project-search-paths)))
  (when (and (fboundp 'nimsuggest-available-p)
             (nimsuggest-available-p)
             (not (bound-and-true-p nimsuggest-mode)))
    (nimsuggest-mode 1)))

(defun init/nim--prewarm-nimsuggest ()
  "Start the nimsuggest server early so the first jump is responsive."
  (when (and buffer-file-name
             (fboundp 'nimsuggest-available-p)
             (nimsuggest-available-p))
    (ignore-errors
      (nimsuggest--call-epc 'sug #'ignore))))

(defun init/nim--suggest-def-locations ()
  "Query nimsuggest for the definition at point.
Return a list of `nim--epc' structs, or nil.  Waits up to
`init/nim-goto-definition-timeout' seconds, re-issuing the request while
the server progresses from not-started through connecting to ready: a
query made while it is merely connecting schedules no callback, so it has
to be asked again once it is ready."
  (let ((buffer (current-buffer))
        (deadline (+ (float-time) init/nim-goto-definition-timeout))
        (result 'pending)
        (last-issue 0.0))
    (while (and (eq result 'pending) (< (float-time) deadline))
      (when (> (- (float-time) last-issue) 0.3)
        (setq last-issue (float-time))
        (ignore-errors
          (nimsuggest--call-epc
           'def
           (lambda (definitions)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (setq result definitions)))))))
      (sleep-for 0.05))
    (and (not (eq result 'pending)) result)))

(defun init/nim--visit-definition (definition)
  "Jump to DEFINITION, an epc result returned by nimsuggest."
  (let ((file (nim--epc-file definition))
        (line (nim--epc-line definition))
        (column (nim--epc-column definition)))
    (unless (and file (file-exists-p file))
      (user-error "nimsuggest returned no valid file for the definition"))
    (xref-push-marker-stack)
    (find-file file)
    (goto-char (point-min))
    (when (natnump line) (forward-line (1- line)))
    (when (natnump column) (move-to-column column))))

(defun init/nim-goto-definition ()
  "Jump to the definition of the symbol at point using nimsuggest.
Ensures nimsuggest is discovered and running, queries it directly, and
pushes the xref marker stack so \\[xref-go-back] returns here."
  (interactive)
  (unless buffer-file-name
    (user-error "Buffer is not visiting a file; nimsuggest needs a file"))
  (init/nim--enable-nimsuggest)
  (unless (and (fboundp 'nimsuggest-available-p) (nimsuggest-available-p))
    (user-error "nimsuggest not found; install it (nimble install nimsuggest)"))
  (let ((definitions (init/nim--suggest-def-locations)))
    (unless definitions
      (user-error "nimsuggest found no definition here (try again if it was just starting)"))
    (init/nim--visit-definition (car definitions))))

(defun init/nim-symbol-actions ()
  "Offer the Nim navigation and documentation actions for point."
  (interactive)
  (pcase (completing-read "Nim action: "
                          '("Definition" "References" "Documentation") nil t)
    ("Definition" (call-interactively #'init/nim-goto-definition))
    ("References" (condition-case err
                      (call-interactively #'xref-find-references)
                    (error (message "%s" (error-message-string err)))))
    ("Documentation" (call-interactively #'init/nim-hover-doc))))

;;;; Token motion

(defconst init/nim-operator-token-chars "+-*/\\=<>@$~&%|!?^.:"
  "Characters that form Nim operator tokens.")

(defconst init/nim-delimiter-token-chars "()[]{};,"
  "Characters that form single-character Nim delimiter tokens.")

(defun init/nim--at-token-char-p (chars)
  "Return non-nil when the character after point is one of CHARS."
  (and (not (eobp)) (memq (char-after) (string-to-list chars))))

(defun init/nim--after-token-char-p (chars)
  "Return non-nil when the character before point is one of CHARS."
  (and (not (bobp)) (memq (char-before) (string-to-list chars))))

(defun init/nim--forward-one-token ()
  "Move forward across one Nim lexical token."
  (forward-comment (buffer-size))
  (cond
   ((eobp) (user-error "No next Nim token"))
   ((looking-at-p "`")
    (forward-char 1)
    (unless (search-forward "`" nil t)
      (goto-char (point-max))))
   ((looking-at-p "[[:alpha:]_]") (skip-chars-forward "[:alnum:]_"))
   ((looking-at-p "[[:digit:]]") (skip-chars-forward "[:alnum:]_'."))
   ((nth 3 (syntax-ppss))
    (goto-char (nth 8 (syntax-ppss)))
    (forward-sexp 1))
   ((looking-at-p "\"\\|'") (forward-sexp 1))
   ((init/nim--at-token-char-p init/nim-delimiter-token-chars) (forward-char 1))
   ((init/nim--at-token-char-p init/nim-operator-token-chars)
    (skip-chars-forward init/nim-operator-token-chars))
   (t (forward-char 1))))

(defun init/nim--backward-one-token ()
  "Move backward across one Nim lexical token."
  (forward-comment (- (buffer-size)))
  (cond
   ((bobp) (user-error "No previous Nim token"))
   ((init/nim--after-token-char-p init/nim-delimiter-token-chars)
    (backward-char 1))
   ((save-excursion (backward-char 1) (looking-at-p "`")) (backward-char 1))
   ((save-excursion (backward-char 1) (looking-at-p "[[:alnum:]_]"))
    (skip-chars-backward "[:alnum:]_"))
   ((nth 3 (syntax-ppss)) (goto-char (nth 8 (syntax-ppss))))
   ((save-excursion (backward-char 1) (looking-at-p "\"\\|'")) (backward-sexp 1))
   ((init/nim--after-token-char-p init/nim-operator-token-chars)
    (skip-chars-backward init/nim-operator-token-chars))
   (t (backward-char 1))))

(defun init/nim-forward-token (&optional arg)
  "Move forward across ARG Nim lexical tokens."
  (interactive "p")
  (dotimes (_ (or arg 1))
    (init/nim--forward-one-token)))

(defun init/nim-backward-token (&optional arg)
  "Move backward across ARG Nim lexical tokens."
  (interactive "p")
  (dotimes (_ (or arg 1))
    (init/nim--backward-one-token)))

(defun init/nim--move-token (count)
  "Move across COUNT Nim lexical tokens, backwards when COUNT is negative."
  (if (< count 0)
      (init/nim-backward-token (- count))
    (init/nim-forward-token count)))

(defun init/nim-mark-token (&optional arg allow-extend)
  "Set mark ARG Nim lexical tokens from point, or extend an active mark.
This follows `mark-sexp': point stays anchored while mark moves, and
repeated invocations extend the active region by one token at a time.
ALLOW-EXTEND is non-nil when called interactively."
  (interactive (list current-prefix-arg t))
  (let* ((active (and allow-extend (region-active-p)))
         (count (if (and active (null arg))
                    (if (>= (mark) (point)) 1 -1)
                  (prefix-numeric-value arg)))
         (origin (if active (mark) (point)))
         (target (save-excursion
                   (goto-char origin)
                   (init/nim--move-token count)
                   (point))))
    (set-mark target)
    (activate-mark)))

;;;; Formatting and running

(defun init/nim--formatter-extension ()
  "Return a Nim-like file extension for the temporary formatter input."
  (or (and buffer-file-name (file-name-extension buffer-file-name t))
      ".nim"))

(defun init/nim--apply-formatted-file (file)
  "Replace the buffer's contents with those of FILE, preserving point."
  (let ((formatted (generate-new-buffer " *nph formatted*")))
    (unwind-protect
        (progn
          (with-current-buffer formatted
            (insert-file-contents file))
          (replace-buffer-contents formatted))
      (kill-buffer formatted))))

(defun init/nim--report-format-failure (output status)
  "Warn that nph failed with exit STATUS, quoting the OUTPUT buffer."
  (let ((message (with-current-buffer output (string-trim (buffer-string)))))
    (display-warning
     'nim
     (if (string-empty-p message)
         (format "nph failed with exit status %s" status)
       message)
     :warning)))

(defun init/nim-format-buffer ()
  "Format the current Nim buffer with nph, when it is installed."
  (interactive)
  (when-let ((nph (executable-find "nph")))
    (let* ((source (make-temp-file "emacs-nph-" nil
                                   (init/nim--formatter-extension)))
           (output (generate-new-buffer " *nph output*"))
           (coding-system-for-read buffer-file-coding-system)
           (coding-system-for-write buffer-file-coding-system))
      (unwind-protect
          (progn
            (write-region nil nil source nil 'silent)
            (let ((status (call-process nph nil output nil source)))
              (if (zerop status)
                  (init/nim--apply-formatted-file source)
                (init/nim--report-format-failure output status))))
        (when (file-exists-p source)
          (delete-file source))
        (kill-buffer output)))))

(defun init/nim-run ()
  "Save the buffer and run `nimble run' from the project root."
  (interactive)
  (save-buffer)
  (let ((default-directory (init/nim-project-root)))
    (compile "nimble run")))

;;;; Flycheck checker

(defun init/nim--flycheck-source-file ()
  "Return the file Flycheck should compile for Nim diagnostics."
  (or (init/nim--project-main-file) buffer-file-name))

(defun init/nim--flycheck-working-directory (_checker)
  "Return the directory Flycheck should run Nim commands in."
  (init/nim-project-root))

(defun init/nim--flycheck-after-save ()
  "Refresh the Nim diagnostics after the current buffer is saved."
  (when (and (derived-mode-p 'nim-mode)
             (bound-and-true-p flycheck-mode))
    (flycheck-buffer)))

(with-eval-after-load 'flycheck
  (flycheck-define-checker nim-check
    "Check Nim source with a compile-only Nimble build."
    :command ("nimble" "--accept" "c"
              "--compileOnly"
              "--colors:off"
              "--listFullPaths:on"
              "--hints:off"
              "--nimcache:build/nimcache/flycheck"
              (eval (init/nim--flycheck-source-file)))
    :error-patterns
    ((error line-start (optional " Nim Output ") (file-name)
            "(" line ", " column ") Error: " (message) line-end)
     (warning line-start (optional " Nim Output ") (file-name)
              "(" line ", " column ") Warning: " (message) line-end))
    :modes (nim-mode)
    :working-directory init/nim--flycheck-working-directory))

;;;; Buffer setup

(defun init/nim--warn-if-missing-tools ()
  "Warn when the core Nim tools are not on the search path."
  (unless (executable-find "nim")
    (display-warning
     'nim "nim not found in PATH; diagnostics and run commands will fail"
     :warning))
  (unless (executable-find "nimsuggest")
    (display-warning
     'nim "nimsuggest not found in PATH; definition and hover will be limited"
     :warning)))

(defun init/nim--setup-diagnostics ()
  "Set up Flycheck for the current Nim buffer, with hover popups."
  (setq-local flycheck-checker 'nim-check
              flycheck-check-syntax-automatically '(save mode-enabled))
  (init/ide-prefer-flycheck)
  ;; The shared flycheck-posframe popup is replaced by the richer Nim
  ;; hover, which fontifies the offending source line.
  (when (bound-and-true-p flycheck-posframe-mode)
    (flycheck-posframe-mode -1))
  (setq-local flycheck-display-errors-function #'init/nim--show-diagnostics
              flycheck-clear-displayed-errors-function #'init/nim--hide-hover)
  (add-hook 'after-save-hook #'init/nim--flycheck-after-save nil t))

(defun init/nim-setup ()
  "Set up Nim editing, diagnostics and navigation in the current buffer."
  (init/nim--ensure-project-scaffold)
  (init/nim--warn-if-missing-tools)
  (init/nim--setup-diagnostics)
  (when (executable-find "nph")
    (add-hook 'before-save-hook #'init/nim-format-buffer nil t))
  (init/nim--enable-nimsuggest)
  (init/nim--prewarm-nimsuggest)
  ;; Nim uses nimsuggest rather than Eglot, so it overrides most actions.
  (setq-local init/ide-hover-function #'init/nim-hover-diagnostics
              init/ide-diagnostics-function #'init/nim-show-diagnostics
              init/ide-actions-function #'init/nim-symbol-actions
              init/ide-format-function #'init/nim-format-buffer
              init/ide-run-function #'init/nim-run
              init/ide-goto-definition-function #'init/nim-goto-definition)
  (init/ide-mode 1))

(use-package nim-mode
  :mode ("\\.nim\\'" "\\.nims\\'" "\\.nimble\\'")
  :hook (nim-mode . init/nim-setup)
  :config
  (define-key nim-mode-map (kbd bind/nim-mark-token) #'init/nim-mark-token)
  (define-key nim-mode-map (kbd bind/nim-doc-search) #'init/nim-doc-search)
  (define-key nim-mode-map (kbd bind/nim-doc-at-point) #'init/nim-doc-at-point)
  (define-key nim-mode-map (kbd bind/nim-doc-module) #'init/nim-doc-module)
  (define-key nim-mode-map (kbd bind/nim-doc-home) #'init/nim-doc-home))

(with-eval-after-load 'which-key
  (which-key-add-major-mode-key-based-replacements 'nim-mode
    "C-c n" "nim docs"
    bind/nim-doc-search "search docs index"
    bind/nim-doc-at-point "docs at point"
    bind/nim-doc-module "module docs"
    bind/nim-doc-home "stdlib overview"))

;;;; Documentation browser

(defgroup init/nim-doc nil
  "Browse the installed Nim toolchain's documentation."
  :group 'tools
  :prefix "init/nim-doc-")

(defcustom init/nim-doc-directory nil
  "Directory holding the Nim HTML docs (the module.html and .idx files).
When nil, it is detected from the active `nim' toolchain."
  :type '(choice (const :tag "Auto-detect" nil) directory)
  :group 'init/nim-doc)

(defcustom init/nim-doc-online-base "https://nim-lang.org/docs/"
  "Base URL used when no local Nim docs can be found.
Only whole-page browsing works against the online docs; the per-symbol
index requires the local .idx files."
  :type 'string
  :group 'init/nim-doc)

(defcustom init/nim-doc-index-types '("nim")
  "Which kinds of idx entries to include in the searchable index.
The idx files tag each entry with a type; the useful ones are:
  \"nim\"      exported symbols (procs, types, templates, ...)
  \"nimgrp\"   overload groups (one anchor per overloaded name)
  \"heading\"  documentation section headings
  \"idx\"      manually indexed prose terms
The default is just symbols, which keeps the search focused."
  :type '(repeat string)
  :group 'init/nim-doc)

(defvar init/nim-doc--directory 'unset
  "Cached docs directory: a directory string, or nil once detection failed.
The symbol `unset' means detection has not run yet.")

(defvar init/nim-doc--index 'unset
  "Cached list of `init/nim-doc-entry' structs, or nil when unavailable.")

(defun init/nim-doc--libpath ()
  "Return the active Nim toolchain's library path, or nil.
Runs `nim dump' on a throwaway file and reads its JSON libpath."
  (when-let ((nim (executable-find "nim")))
    (let ((probe (make-temp-file "nim-doc-probe-" nil ".nim")))
      (unwind-protect
          (with-temp-buffer
            ;; Real output to this buffer, stderr (hints) discarded.
            (when (zerop (call-process nim nil (list t nil) nil
                                       "--dump.format:json" "dump" probe))
              (goto-char (point-min))
              (when (re-search-forward "{" nil t)
                (goto-char (match-beginning 0))
                (ignore-errors
                  (alist-get 'libpath
                             (json-parse-buffer :object-type 'alist
                                                :null-object nil))))))
        (delete-file probe)))))

(defun init/nim-doc--compiler-version ()
  "Return the active Nim compiler's version string, or nil."
  (when-let ((nim (executable-find "nim")))
    (with-temp-buffer
      (when (zerop (call-process nim nil (list t nil) nil "--version"))
        (goto-char (point-min))
        (when (re-search-forward "Version \\([0-9][0-9.]*\\)" nil t)
          (match-string 1))))))

(defun init/nim-doc--existing-directory (path)
  "Return PATH as a directory name when it exists, else nil."
  (and path (file-directory-p path) (file-name-as-directory path)))

(defun init/nim-doc--detect-directory ()
  "Detect the Nim HTML docs directory for the active toolchain, or nil."
  (or (init/nim-doc--existing-directory init/nim-doc-directory)
      ;; Authoritative: docs live at <libpath>/../doc/html for every
      ;; layout, be it choosenim, a distribution package or a manual build.
      (when-let ((libpath (init/nim-doc--libpath)))
        (init/nim-doc--existing-directory
         (expand-file-name "../doc/html" libpath)))
      ;; Fallback: the choosenim toolchain layout, keyed by version.
      (when-let ((version (init/nim-doc--compiler-version)))
        (init/nim-doc--existing-directory
         (expand-file-name
          (format "~/.choosenim/toolchains/nim-%s/doc/html" version))))))

(defun init/nim-doc-base ()
  "Return the docs base: the local docs directory, else the online URL."
  (when (eq init/nim-doc--directory 'unset)
    (setq init/nim-doc--directory (init/nim-doc--detect-directory)))
  (or init/nim-doc--directory init/nim-doc-online-base))

(defun init/nim-doc--remote-p (base)
  "Return non-nil when BASE is a remote docs base rather than a directory."
  (string-match-p "\\`https?://" base))

(cl-defstruct (init/nim-doc-entry (:constructor init/nim-doc-entry-create))
  "One documentation index entry parsed from a Nim .idx file."
  name link desc module type)

(defun init/nim-doc--entry-module (link)
  "Return the module name for idx LINK (\"module.html#anchor\")."
  (file-name-base (car (split-string link "#"))))

(defun init/nim-doc--parse-idx-line (line)
  "Return the `init/nim-doc-entry' parsed from idx LINE, or nil."
  (let ((columns (split-string line "\t")))
    (when (>= (length columns) 4)
      (let ((type (nth 0 columns))
            (name (nth 1 columns))
            (link (nth 2 columns))
            (desc (string-trim (nth 3 columns))))
        (when (and (member type init/nim-doc-index-types)
                   (not (string-empty-p name))
                   (not (string-empty-p link)))
          (init/nim-doc-entry-create
           :name name
           :link link
           :desc (if (string-empty-p desc) name desc)
           :module (init/nim-doc--entry-module link)
           :type type))))))

(defun init/nim-doc--parse-idx-file (file)
  "Return the list of `init/nim-doc-entry' structs parsed from FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (let (entries)
      (while (not (eobp))
        (when-let ((entry (init/nim-doc--parse-idx-line
                           (buffer-substring-no-properties
                            (line-beginning-position) (line-end-position)))))
          (push entry entries))
        (forward-line 1))
      (nreverse entries))))

(defun init/nim-doc-index ()
  "Return the parsed stdlib documentation index, or nil when unavailable.
The index is built once from the local .idx files and cached."
  (when (eq init/nim-doc--index 'unset)
    (let ((base (init/nim-doc-base)))
      (setq init/nim-doc--index
            (unless (init/nim-doc--remote-p base)
              (cl-loop for file in (directory-files base t "\\.idx\\'")
                       nconc (init/nim-doc--parse-idx-file file))))))
  init/nim-doc--index)

(defun init/nim-doc--display (entry)
  "Return the completion display string for ENTRY: signature plus module."
  (concat (init/nim-doc-entry-desc entry)
          "  "
          (propertize (init/nim-doc-entry-module entry) 'face 'shadow)))

(defun init/nim-doc--collection (entries)
  "Return (CANDIDATES . LOOKUP) for ENTRIES.
CANDIDATES is a list of unique display strings; LOOKUP maps each display
string back to its `init/nim-doc-entry'.  Distinct symbols can share a
signature -- an operator defined in several modules, say -- so display
strings are made unique to keep the reverse lookup unambiguous."
  (let ((lookup (make-hash-table :test 'equal))
        candidates)
    (dolist (entry entries)
      (let ((display (init/nim-doc--display entry))
            (suffix 2))
        (while (gethash display lookup)
          (setq display (format "%s<%d>" (init/nim-doc--display entry) suffix)
                suffix (1+ suffix)))
        (puthash display entry lookup)
        (push display candidates)))
    (cons (nreverse candidates) lookup)))

(defun init/nim-doc--read (prompt entries &optional initial)
  "Read one of ENTRIES with completion, using PROMPT and INITIAL input.
Return the chosen `init/nim-doc-entry', or nil."
  (pcase-let* ((`(,candidates . ,lookup) (init/nim-doc--collection entries))
               (choice (completing-read prompt candidates nil t initial)))
    (gethash choice lookup)))

(defun init/nim-doc--url (link)
  "Return a browseable URL for idx LINK (\"module.html#anchor\")."
  (let ((base (init/nim-doc-base)))
    (if (init/nim-doc--remote-p base)
        (concat base link)
      ;; Expand only the page part and reattach the fragment verbatim, so
      ;; anchors containing "/", "," or "[]" survive intact.
      (let* ((hash (string-search "#" link))
             (page (if hash (substring link 0 hash) link))
             (fragment (if hash (substring link hash) "")))
        (concat "file://" (expand-file-name page base) fragment)))))

(defun init/nim-doc--browse-link (link)
  "Open idx LINK in EWW."
  (require 'eww)
  (eww (init/nim-doc--url link)))

(defun init/nim-doc--browse-entry (entry)
  "Open ENTRY's documentation in EWW."
  (when entry
    (init/nim-doc--browse-link (init/nim-doc-entry-link entry))))

(defun init/nim-doc--browse-page (page)
  "Open PAGE, a bare \"name.html\", in EWW if it is reachable."
  (let ((base (init/nim-doc-base)))
    (if (or (init/nim-doc--remote-p base)
            (file-exists-p (expand-file-name page base)))
        (init/nim-doc--browse-link page)
      (user-error "Nim docs page not found: %s" page))))

;;;###autoload
(defun init/nim-doc-search (&optional initial)
  "Search the Nim standard library documentation index and open a symbol.
Matches on the full signature and module name, so a symbol can be found
without knowing its exact name.  INITIAL prefills the search."
  (interactive)
  (let ((index (init/nim-doc-index)))
    (if (null index)
        (progn
          (message "No local Nim docs index; opening the online index")
          (init/nim-doc--browse-page "theindex.html"))
      (init/nim-doc--browse-entry
       (or (init/nim-doc--read "Nim docs: " index initial)
           (user-error "No documentation selected"))))))

;;;###autoload
(defun init/nim-doc-at-point ()
  "Open the Nim documentation for the symbol at point.
Overloaded names offer a picker.  When the symbol is not in the stdlib
index, fall back to nimsuggest hover documentation, which also covers
this project's own symbols."
  (interactive)
  (let ((symbol (thing-at-point 'symbol t))
        (index (init/nim-doc-index)))
    (if (or (null index) (null symbol))
        (init/nim-doc-search)
      (let ((matches (cl-remove-if-not
                      (lambda (entry)
                        (string-equal-ignore-case
                         (init/nim-doc-entry-name entry) symbol))
                      index)))
        (pcase (length matches)
          (1 (init/nim-doc--browse-entry (car matches)))
          ((pred (< 1))
           (init/nim-doc--browse-entry
            (init/nim-doc--read (format "Docs for `%s': " symbol) matches)))
          (_ (init/nim-hover-doc)))))))

;;;###autoload
(defun init/nim-doc-module ()
  "Open a whole Nim module's documentation page in EWW."
  (interactive)
  (let ((base (init/nim-doc-base)))
    (if (init/nim-doc--remote-p base)
        (init/nim-doc--browse-page "lib.html")
      (let* ((modules (sort (mapcar #'file-name-base
                                    (directory-files base nil "\\.idx\\'"))
                            #'string<))
             (module (completing-read "Nim module: " modules nil t)))
        (init/nim-doc--browse-page (concat module ".html"))))))

;;;###autoload
(defun init/nim-doc-home ()
  "Open the Nim standard library documentation overview in EWW."
  (interactive)
  (init/nim-doc--browse-page "lib.html"))

;;;###autoload
(defun init/nim-doc-refresh ()
  "Clear the cached Nim docs directory and index.
Use this after switching Nim versions, so the next lookup re-detects them."
  (interactive)
  (setq init/nim-doc--directory 'unset
        init/nim-doc--index 'unset)
  (message "Nim docs cache cleared (base: %s)" (init/nim-doc-base)))

(provide 'init-lang-nim)
;;; init-lang-nim.el ends here
