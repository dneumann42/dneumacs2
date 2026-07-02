;;; eww-setup.el --- Practical EWW browsing -*- lexical-binding: t; -*-

;;; Commentary:

;; EWW as a genuinely usable browser:
;;
;; - a fixed toolbar (same API as the Treemacs and PDF toolbars) with
;;   navigation, search, readable view, zoom, bookmarks, history, copy
;;   URL and open-externally buttons, plus the page title
;; - "jump to content" (toolbar ⤓ or `j'): skips the navigation-link
;;   soup at the top of most pages and lands on the first substantial
;;   paragraph of body text
;; - readable view (toolbar ◈ or `R'): re-renders just the article
;; - pages render in the writer font (EB Garamond) with theme colors
;;   instead of the site's, capped at a comfortable column width
;; - buffers are named after the page title, so several EWW buffers
;;   stay distinguishable

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function eww-current-url "eww")
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
  ;; Render with theme colors, not the site's; keep lines readable.
  (shr-use-colors nil)
  (shr-max-width 100)
  (shr-max-image-proportion 0.7)
  (shr-discard-aria-hidden t)
  :config
  (define-key eww-mode-map (kbd "j") #'init/eww-jump-to-content)
  (add-hook 'eww-mode-hook #'init/eww-setup)
  ;; EWW resets `header-line-format' to its own title/URL line on every
  ;; page render, clobbering anything the mode hook installed.  Override
  ;; the updater so each render (re)installs the toolbar instead -- the
  ;; title and URL are shown in the toolbar's info segment anyway.
  (advice-add 'eww-update-header-line-format :override
              #'init/eww--attach-toolbar))

;;;; DuckDuckGo search

(defvar init/ddg-history nil
  "Minibuffer history for `ddg' searches.")

(defun ddg (query)
  "Search DuckDuckGo for QUERY in EWW.
Interactively, default to the active region or the symbol at point.
Unlike `eww', the input is always treated as a search query, never as
a URL."
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

;;;; Jump to content

(defconst init/eww--content-min-words 25
  "Minimum word count for a paragraph to count as body content.")

(defconst init/eww--content-max-link-ratio 0.4
  "Maximum fraction of link characters for body content.
Navigation blocks are mostly links; article text is mostly not.")

(defun init/eww--content-paragraph-p (start end)
  "Return non-nil when START..END looks like a real content paragraph."
  (let ((length (- end start)))
    (and (> length 0)
         (>= (count-words start end) init/eww--content-min-words)
         (let ((link-chars 0)
               (pos start))
           (while (< pos end)
             (when (get-text-property pos 'shr-url)
               (setq link-chars (1+ link-chars)))
             (setq pos (1+ pos)))
           (< (/ (float link-chars) length)
              init/eww--content-max-link-ratio)))))

(defun init/eww-jump-to-content ()
  "Move past navigation junk to the first substantial paragraph.
Scans forward from the top of the page for the first paragraph with
enough words and few enough links to be body text."
  (interactive)
  (let ((origin (point))
        (found nil))
    (goto-char (point-min))
    (while (and (not found) (not (eobp)))
      (let ((start (progn (skip-chars-forward " \t\n") (point)))
            (end (progn (forward-paragraph) (point))))
        (if (init/eww--content-paragraph-p start end)
            (setq found start)
          (when (= end start) (forward-line 1)))))
    (if (not found)
        (progn (goto-char origin)
               (message "No obvious content paragraph found"))
      (goto-char found)
      (recenter 1)
      (when (fboundp 'pulse-momentary-highlight-one-line)
        (pulse-momentary-highlight-one-line (point))))))

;;;; Toolbar

(defun init/eww--toolbar-title ()
  "Return the page title (or URL) for the toolbar."
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
   ;; Navigation
   '("←" "Back" eww-back-url)
   '("→" "Forward" eww-forward-url)
   '("⟳" "Reload page" eww-reload)
   :sep
   ;; Getting places
   '("⌕" "Open URL or web search" eww)
   '("⤓" "Jump to the main content" init/eww-jump-to-content)
   '("◈" "Readable view (article only)" eww-readable)
   :sep
   ;; Text size
   '("−" "Smaller text" text-scale-decrease)
   '("＋" "Larger text" text-scale-increase)
   :sep
   ;; Bookmarks and history
   '("★" "Bookmark this page" eww-add-bookmark)
   '("≡" "List bookmarks" eww-list-bookmarks)
   '("↺" "Browsing history" eww-list-histories)
   :sep
   ;; Sharing
   '("❐" "Copy the page URL" eww-copy-page-url)
   '("⇗" "Open in the external browser" eww-browse-with-external-browser)
   :sep
   #'init/eww--toolbar-title))

;;;; Buffer setup

(defun init/eww--attach-toolbar ()
  "Install the EWW toolbar in the current buffer's header line.
Replaces `eww-update-header-line-format', which would otherwise reset
the header line on every page render."
  (init/toolbar-attach #'init/eww--toolbar))

(defun init/eww-setup ()
  "Per-buffer EWW setup: toolbar and writerly rendering."
  (init/eww--attach-toolbar)
  ;; Proportional text (shr's default) in the writer font, like Org.
  (when (and (fboundp 'init/org-ensure-writer-font)
             (display-graphic-p))
    (when-let ((family (init/org-ensure-writer-font)))
      (face-remap-add-relative 'variable-pitch
                               :family family
                               :height 1.2)))
  (setq-local line-spacing 0.1))

(provide 'eww-setup)
;;; eww-setup.el ends here
