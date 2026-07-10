;;; nim-doc.el --- Browse the installed Nim documentation -*- lexical-binding: t; -*-

;;; Commentary:

;; Browse the HTML documentation of the *installed* Nim toolchain from
;; Emacs, so the docs always match the compiler you build with.
;;
;; Nim generates, next to every `module.html', a tab-separated `.idx'
;; index file listing each symbol's name, its exact HTML page + anchor,
;; and its full signature.  This module parses those idx files into one
;; searchable index and opens the matching doc page -- anchored at the
;; precise proc/type -- in EWW.
;;
;; Four ways in:
;;   `init/nim-doc-search'    fuzzy-search the whole stdlib index
;;   `init/nim-doc-at-point'  look up the symbol under point
;;   `init/nim-doc-module'    open a whole module's page
;;   `init/nim-doc-home'      the standard library overview
;; plus `init/nim-doc-refresh' to drop the cache after switching Nim
;; versions.
;;
;; The docs directory is detected from the active `nim' toolchain (via
;; `nim dump''s libpath, then a choosenim-by-version guess).  When no
;; local docs are found it falls back to the online docs at nim-lang.org,
;; where only whole-page browsing is possible (no local index).

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function eww "eww" (url &optional new-buffer))

(defgroup init/nim-doc nil
  "Browse the installed Nim toolchain's documentation."
  :group 'tools
  :prefix "init/nim-doc-")

(defcustom init/nim-doc-directory nil
  "Directory holding the Nim HTML docs (the `module.html' + `*.idx' files).
When nil, it is auto-detected from the active `nim' toolchain."
  :type '(choice (const :tag "Auto-detect" nil) directory)
  :group 'init/nim-doc)

(defcustom init/nim-doc-online-base "https://nim-lang.org/docs/"
  "Base URL used when no local Nim docs can be found.
Only whole-page browsing works against the online docs; the per-symbol
index requires the local `.idx' files."
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

;;;; Docs directory detection

(defvar init/nim-doc--dir 'unset
  "Cached docs directory: a directory string, or nil once detection failed.
The symbol `unset' means detection has not run yet.")

(defun init/nim-doc--nim-dump-libpath ()
  "Return the active Nim toolchain's library path, or nil.
Runs `nim dump' on a throwaway file and reads its JSON `libpath'."
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
                  (let ((data (json-parse-buffer :object-type 'alist
                                                 :null-object nil)))
                    (alist-get 'libpath data))))))
        (delete-file probe)))))

(defun init/nim-doc--nim-version ()
  "Return the active Nim compiler's version string, or nil."
  (when-let ((nim (executable-find "nim")))
    (with-temp-buffer
      (when (zerop (call-process nim nil (list t nil) nil "--version"))
        (goto-char (point-min))
        (when (re-search-forward "Version \\([0-9][0-9.]*\\)" nil t)
          (match-string 1))))))

(defun init/nim-doc--detect-dir ()
  "Detect the Nim HTML docs directory for the active toolchain, or nil."
  (or (and init/nim-doc-directory
           (file-directory-p init/nim-doc-directory)
           (file-name-as-directory init/nim-doc-directory))
      ;; Authoritative: docs live at <libpath>/../doc/html for any layout
      ;; (choosenim, distro package, or a manual build).
      (when-let* ((lib (init/nim-doc--nim-dump-libpath))
                  (dir (expand-file-name "../doc/html" lib)))
        (and (file-directory-p dir) (file-name-as-directory dir)))
      ;; Fallback: the choosenim toolchain layout keyed by version.
      (when-let* ((version (init/nim-doc--nim-version))
                  (dir (expand-file-name
                        (format "~/.choosenim/toolchains/nim-%s/doc/html"
                                version))))
        (and (file-directory-p dir) (file-name-as-directory dir)))))

(defun init/nim-doc-base ()
  "Return the docs base: the local docs directory, else the online URL."
  (when (eq init/nim-doc--dir 'unset)
    (setq init/nim-doc--dir (init/nim-doc--detect-dir)))
  (or init/nim-doc--dir init/nim-doc-online-base))

(defun init/nim-doc--remote-p (base)
  "Return non-nil when BASE is a remote (http) docs base rather than a dir."
  (string-match-p "\\`https?://" base))

;;;; Index parsing

(cl-defstruct (init/nim-doc-entry (:constructor init/nim-doc-entry-create))
  "One documentation index entry parsed from a Nim `.idx' file."
  name link desc module type)

(defun init/nim-doc--entry-module (link)
  "Return the module name for idx LINK (\"module.html#anchor\")."
  (file-name-base (car (split-string link "#"))))

(defun init/nim-doc--parse-idx-file (file)
  "Return the list of `init/nim-doc-entry' structs parsed from FILE."
  (let ((entries '()))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (while (not (eobp))
        (let ((cols (split-string
                     (buffer-substring-no-properties
                      (line-beginning-position) (line-end-position))
                     "\t")))
          (when (>= (length cols) 4)
            (let ((type (nth 0 cols))
                  (name (nth 1 cols))
                  (link (nth 2 cols))
                  (desc (string-trim (nth 3 cols))))
              (when (and (member type init/nim-doc-index-types)
                         (not (string-empty-p name))
                         (not (string-empty-p link)))
                (push (init/nim-doc-entry-create
                       :name name
                       :link link
                       :desc (if (string-empty-p desc) name desc)
                       :module (init/nim-doc--entry-module link)
                       :type type)
                      entries)))))
        (forward-line 1)))
    (nreverse entries)))

(defvar init/nim-doc--index 'unset
  "Cached list of `init/nim-doc-entry' structs, or nil when unavailable.")

(defun init/nim-doc-index ()
  "Return the parsed stdlib documentation index, or nil when unavailable.
The index is built once from the local `.idx' files and cached."
  (when (eq init/nim-doc--index 'unset)
    (let ((base (init/nim-doc-base)))
      (setq init/nim-doc--index
            (unless (init/nim-doc--remote-p base)
              (cl-loop for file in (directory-files base t "\\.idx\\'")
                       nconc (init/nim-doc--parse-idx-file file))))))
  init/nim-doc--index)

;;;; Selecting an entry

(defun init/nim-doc--display (entry)
  "Return the completion display string for ENTRY: signature plus module."
  (concat (init/nim-doc-entry-desc entry)
          "  "
          (propertize (init/nim-doc-entry-module entry) 'face 'shadow)))

(defun init/nim-doc--collection (entries)
  "Return (CANDIDATES . LOOKUP) for ENTRIES.
CANDIDATES is a list of unique display strings; LOOKUP is a hash mapping
each display string back to its `init/nim-doc-entry'."
  (let ((lookup (make-hash-table :test 'equal))
        (candidates '()))
    (dolist (entry entries)
      (let ((display (init/nim-doc--display entry))
            (n 2))
        ;; Distinct symbols can share a signature (e.g. an operator
        ;; defined in several modules); keep display strings unique so
        ;; the reverse lookup is unambiguous.
        (while (gethash display lookup)
          (setq display (format "%s<%d>" (init/nim-doc--display entry) n)
                n (1+ n)))
        (puthash display entry lookup)
        (push display candidates)))
    (cons (nreverse candidates) lookup)))

(defun init/nim-doc--read (prompt entries &optional initial)
  "Read one of ENTRIES with completion using PROMPT and INITIAL input.
Return the chosen `init/nim-doc-entry', or nil."
  (pcase-let* ((`(,candidates . ,lookup) (init/nim-doc--collection entries))
               (choice (completing-read prompt candidates nil t initial)))
    (gethash choice lookup)))

;;;; Opening docs in EWW

(defun init/nim-doc--url (link)
  "Return a browseable URL for idx LINK (\"module.html#anchor\")."
  (let ((base (init/nim-doc-base)))
    (if (init/nim-doc--remote-p base)
        (concat base link)
      ;; Expand only the page part; reattach the fragment verbatim so
      ;; anchors containing \"/\", \",\" or \"[]\" survive intact.
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
  "Open PAGE (a bare \"name.html\") in EWW, if it is reachable."
  (let ((base (init/nim-doc-base)))
    (if (or (init/nim-doc--remote-p base)
            (file-exists-p (expand-file-name page base)))
        (init/nim-doc--browse-link page)
      (user-error "Nim docs page not found: %s" page))))

;;;; Commands

;;;###autoload
(defun init/nim-doc-search (&optional initial)
  "Search the Nim standard library documentation index and open a symbol.
Matches on the full signature and module name, so you can find a symbol
without knowing its exact name.  With INITIAL, prefill the search."
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
index, fall back to searching the whole index, then to nimsuggest hover
documentation (which also covers your own project's symbols)."
  (interactive)
  (let* ((symbol (thing-at-point 'symbol t))
         (index (init/nim-doc-index)))
    (cond
     ((null index)
      (init/nim-doc-search))
     ((null symbol)
      (init/nim-doc-search))
     (t
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
          (_
           (if (fboundp 'init/nim-hover-doc)
               (init/nim-hover-doc)
             (init/nim-doc-search symbol)))))))))

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
Use after switching Nim versions so the next lookup re-detects them."
  (interactive)
  (setq init/nim-doc--dir 'unset
        init/nim-doc--index 'unset)
  (let ((base (init/nim-doc-base)))
    (message "Nim docs cache cleared (base: %s)" base)))

(provide 'nim-doc)
;;; nim-doc.el ends here
