;;; init-markdown.el --- Markdown editing and rendering -*- lexical-binding: t; -*-

(defgroup init/markdown nil
  "Markdown editing defaults."
  :group 'text)

(defcustom init/markdown-fill-column 96
  "Visual line width for Markdown buffers."
  :type 'integer
  :group 'init/markdown)

(defcustom init/markdown-command-candidates
  '(("pandoc" . "pandoc -f markdown -t html")
    ("multimarkdown" . "multimarkdown")
    ("markdown" . "markdown"))
  "Markdown renderers to try for in-Emacs HTML preview."
  :type '(alist :key-type string :value-type string)
  :group 'init/markdown)

(defun init/markdown-command ()
  "Return the first available Markdown rendering command."
  (catch 'command
    (dolist (candidate init/markdown-command-candidates)
      (when (executable-find (car candidate))
        (throw 'command (cdr candidate))))))

(defun init/markdown-setup ()
  "Enable comfortable Markdown editing defaults for the current buffer."
  (setq-local markdown-fontify-code-blocks-natively t)
  (setq-local markdown-hide-markup t)
  (setq-local markdown-enable-wiki-links t)
  (setq-local fill-column init/markdown-fill-column)
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

(use-package markdown-mode
  :mode (("\\.md\\'" . gfm-mode)
         ("\\.markdown\\'" . markdown-mode)
         ("README\\(?:\\.md\\)?\\'" . gfm-mode))
  :commands (markdown-mode gfm-mode markdown-live-preview-mode)
  :hook ((markdown-mode . init/markdown-setup)
         (gfm-mode . init/markdown-setup))
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
  (set-face-attribute 'markdown-header-face nil
                      :inherit 'font-lock-function-name-face
                      :weight 'bold)
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
                      :inherit 'font-lock-doc-face
                      :slant 'italic)
  (set-face-attribute 'markdown-link-face nil
                      :inherit 'link
                      :underline nil
                      :weight 'semi-bold)
  (set-face-attribute 'markdown-url-face nil
                      :inherit 'shadow))

(use-package visual-fill-column
  :hook ((markdown-mode . visual-fill-column-mode)
         (gfm-mode . visual-fill-column-mode))
  :custom
  (visual-fill-column-center-text t)
  (visual-fill-column-width init/markdown-fill-column))

(provide 'init-markdown)
;;; init-markdown.el ends here
