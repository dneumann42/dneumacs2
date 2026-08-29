;;; init-editor.el --- Editing defaults and general packages -*- lexical-binding: t; -*-

;;; Commentary:

;; How buffers behave once they are open: safety nets (backups,
;; auto-saves, saved places), scrolling, pairs, and the small set of
;; general-purpose editing packages that are not tied to any language.
;;
;; Anything about the frame around the buffer lives in init-frame.el;
;; anything about finding or completing text lives in init-completion.el.

;;; Code:

(require 'seq)
(require 'init-keys)
(require 'init-lib)

(declare-function treesit-auto--build-major-mode-remap-alist "treesit-auto")

;;;; Safety nets

;; Backups and auto-saves are kept -- they have saved real work -- but
;; out of the working tree, where they would pollute every project.
(setq backup-directory-alist
      `(("." . ,(expand-file-name "backups" user-emacs-directory)))
      backup-by-copying t
      version-control t
      delete-old-versions t
      kept-new-versions 6
      kept-old-versions 2)

(setq auto-save-file-name-transforms
      `((".*" ,(expand-file-name "auto-saves/" user-emacs-directory) t)))
(make-directory (expand-file-name "auto-saves" user-emacs-directory) t)

(setq create-lockfiles nil)

;; Dropping the readability check costs nothing -- a stale entry is
;; overwritten the next time that file is visited -- and saves a stat per
;; entry on exit, plus a stall whenever one of them sits on a remote path.
(setq save-place-limit 200
      save-place-forget-unreadable-files nil)
(advice-add 'save-place-alist-to-file :around #'init/write-state-file-fast)

(save-place-mode 1)

;;;; General behaviour

(setq use-short-answers t
      kill-do-not-save-duplicates t
      require-final-newline t
      xref-search-program 'ripgrep
      auto-revert-verbose nil)

;; Keep point near the window edge instead of recentering when wheel
;; scrolling moves it outside the visible portion of the buffer.
(setq scroll-conservatively 101
      scroll-preserve-screen-position 'always)

(delete-selection-mode 1)
(global-auto-revert-mode 1)
(global-so-long-mode 1)
(repeat-mode 1)
(when (fboundp 'pixel-scroll-precision-mode)
  (pixel-scroll-precision-mode 1))

(add-hook 'prog-mode-hook #'display-line-numbers-mode)
(add-hook 'prog-mode-hook #'hl-line-mode)

;;;; Leaving Emacs

;; With a project open there is always a language server alive, so this
;; prompt fired on every exit without ever saying anything useful.
;; Unsaved buffers are still prompted for.
(setq confirm-kill-processes nil)

;;;; Electric pairs

(setq electric-pair-pairs '((?\{ . ?\})
                            (?\[ . ?\])
                            (?\( . ?\))))
(setq electric-pair-text-pairs electric-pair-pairs)
(electric-pair-mode 1)

;;;; Working directory

(defun init/set-default-directory-to-git-root ()
  "Make a file-visiting buffer use its Git repository root as its directory.
Commands started from the buffer -- compilation, grep, shells -- then run
from the repository root rather than from the file's own directory."
  (when buffer-file-name
    (when-let* ((root (init/git-repo-root buffer-file-name)))
      (setq-local default-directory root))))

(add-hook 'find-file-hook #'init/set-default-directory-to-git-root)

;;;; Reloading the configuration

(defun init/config-module-p (feature)
  "Return non-nil when FEATURE was provided by a file under lisp/."
  (let ((directory (file-name-as-directory
                    (expand-file-name "lisp" user-emacs-directory)))
        (file (locate-library (symbol-name feature))))
    (and file (string-prefix-p directory (expand-file-name file)))))

(defun init/reload-config ()
  "Reload the configuration, re-evaluating the modules under lisp/ too.
Loading `user-init-file' alone re-runs its `require' forms, but those are
no-ops for features that are already loaded.  Dropping every module of
this configuration from `features' first makes those requires load again,
in order."
  (interactive)
  (condition-case err
      (progn
        (setq features (seq-remove #'init/config-module-p features))
        (load-file user-init-file)
        (message "Config reloaded: %s" user-init-file))
    (error
     (message "Config reload failed: %s" (error-message-string err)))))

;;;; Packages

;; The recent file list is what makes a narrow session workable: buffers a
;; session no longer restores are still one `consult-buffer' away.
(use-package recentf
  :ensure nil
  :custom
  (recentf-max-saved-items 300)
  ;; Prune on an idle timer; the default prunes when the mode is enabled,
  ;; stat-ing all 300 files during startup.
  (recentf-auto-cleanup 300)
  (recentf-exclude
   (list (regexp-quote (expand-file-name "elpa/" user-emacs-directory))
         (regexp-quote (expand-file-name "eln-cache/" user-emacs-directory))))
  :init
  (recentf-mode 1))

(use-package ace-window
  :bind (("C-0" . ace-window)))

(use-package avy
  :defer t
  :init
  (global-set-key (kbd bind/avy-goto-char) #'avy-goto-char))

;; vim-surround style editing of pairs: () {} [] <> "" '' ``.
;; M-' s wraps the region (or symbol at point), M-' c changes the closest
;; pair to another, M-' d deletes it, M-' k / K kill inside / including
;; the pair, M-' i / o mark inside / including it, and a bare pair key
;; (e.g. M-' () marks within that pair.
(use-package surround
  :ensure t
  :demand t
  :config
  (global-set-key (kbd bind/surround) surround-keymap))

;; Prefer tree-sitter major modes and offer to install missing grammars.

;; treesit-auto rebuilds `major-mode-remap-alist' from scratch inside every
;; `set-auto-mode-0' call, and building it asks all sixty-odd languages it
;; knows whether their grammar is available -- a shared-library load
;; apiece.  That is ~95ms added to every file visited, so a session restore
;; pays it once per buffer and so does every `find-file' afterwards.
;;
;; The answer only changes when a grammar is installed, so it is built once
;; and reused.  treesit-auto declines to cache it so that a grammar
;; installed mid-session is noticed; invalidating the cache after an install
;; keeps that property.

(defvar init/treesit--remap-alist 'stale
  "Cached `major-mode-remap-alist' from treesit-auto, or `stale'.")

(defun init/treesit-remap-alist ()
  "Return treesit-auto's mode remapping, building it at most once."
  (when (eq init/treesit--remap-alist 'stale)
    (setq init/treesit--remap-alist (treesit-auto--build-major-mode-remap-alist)))
  init/treesit--remap-alist)

(defun init/treesit-set-major-remap (&rest _)
  "Point `major-mode-remap-alist' at the cached remapping.
Overrides `treesit-auto--set-major-remap', which rebuilds it every time."
  (setq-local major-mode-remap-alist (init/treesit-remap-alist)))

(defun init/treesit-invalidate-remap (&rest _)
  "Forget the cached remapping so a newly installed grammar is picked up."
  (setq init/treesit--remap-alist 'stale))

(use-package treesit-auto
  :custom
  (treesit-auto-install 'prompt)
  :config
  (treesit-auto-add-to-auto-mode-alist 'all)
  (advice-add 'treesit-auto--set-major-remap
              :override #'init/treesit-set-major-remap)
  (advice-add 'treesit-install-language-grammar
              :after #'init/treesit-invalidate-remap)
  (global-treesit-auto-mode))

(use-package ligature
  :config
  (ligature-set-ligatures
   'prog-mode
   '("www" "**" "***" "**/" "*>" "*/" "\\\\" "\\\\\\"
     "{-" "[]" "::" ":::" ":=" "!!" "!=" "!==" "-}"
     "--" "---" "-->" "->" "->>" "-<" "-<<" "-~"
     "#{" "#[" "##" "###" "####" "#(" "#?" "#_" "#_("
     ".-" ".=" ".." "..<" "..." "?=" "??" ";;" "/*" "/**"
     "/=" "/==" "/>" "//" "///" "&&" "||" "||=" "|="
     "|>" "^=" "$>" "++" "+++" "+>" "=:=" "==" "==="
     "==>" "=>" "=>>" "<=" "=<<" "=/=" ">-" ">=" ">=>"
     ">>" ">>-" ">>=" ">>>" "<*" "<*>" "<|" "<|>" "<$"
     "<$>" "<!--" "<-" "<--" "<->" "<+" "<+>" "<=" "<=="
     "<=>" "<=<" "<>" "<<" "<<-" "<<=" "<<<" "<~" "<~~"
     "</" "</>" "~@" "~-" "~=" "~>" "~~" "~~>" "%%"))
  (global-ligature-mode t))

(use-package highlight-indent-guides
  :hook (prog-mode . highlight-indent-guides-mode)
  :custom
  (highlight-indent-guides-method 'character)
  (highlight-indent-guides-responsive 'top)
  (highlight-indent-guides-auto-enabled nil)
  :config
  (set-face-foreground 'highlight-indent-guides-character-face "#2a2a36")
  (set-face-foreground 'highlight-indent-guides-top-character-face "#5d6aa8")
  (set-face-foreground 'highlight-indent-guides-stack-character-face "#8a6a9f"))

;; Render hex and rgb colour literals in their own colour.
(use-package colorful-mode
  :custom
  (colorful-use-prefix t)
  (colorful-only-strings 'only-prog)
  (css-fontify-colors nil)
  :config
  (global-colorful-mode t)
  (add-to-list 'global-colorful-modes 'helpful-mode))

;;;; Keybindings

(global-set-key (kbd bind/reload-config) #'init/reload-config)
(global-set-key (kbd bind/forward-paragraph) #'forward-paragraph)
(global-set-key (kbd bind/backward-paragraph) #'backward-paragraph)
(global-set-key (kbd bind/repeat) #'repeat)

(provide 'init-editor)
;;; init-editor.el ends here
