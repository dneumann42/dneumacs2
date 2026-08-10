;;; some-nice-colors-theme.el --- Warm earthy pastels on a deep black background -*- lexical-binding: t; -*-
;;; Commentary:
;;; A blend of the old warm palette (dusty rose, sage, peach, dusty blue,
;;; maroon selection) with the fuller face coverage of the pastel rework.
;;; The old hues are kept but pushed brighter and more saturated so they
;;; read as warm and lively rather than dark and dull, and the cold neon
;;; monokai-ish accents are gone.
;;; Code:

(deftheme some-nice-colors
  "Warm, earthy pastels — rose, sage, peach and dusty blue on deep black.")

(let ((bg        "#0a0607")   ; deep black with a faint warm tint
      (bg-alt    "#17100f")   ; mode-line / block background (from old darkbg2)
      (bg-block  "#100a09")   ; org src blocks
      (fg        "#d9cabf")   ; warm light foreground (from old #c4b3ad, lifted)
      (fg-alt    "#b0a099")
      (faint     "#4a423d")   ; line numbers, org furniture (from old darkfg)
      (comment   "#8a7d74")   ; warm gray, brighter than the old #727272
      (cursor    "#fcc077")   ; peach
      (region    "#5a1d2c")   ; signature maroon selection (from old primary-dark)
      (rose      "#d582a4")   ; functions, headings   (old primary #ab6c8c, brighter)
      (rose-dim  "#b06f8b")
      (sage      "#bcd98f")   ; keywords, builtins-ish (old secondary #bccc9a, brighter)
      (peach     "#fcc077")   ; strings                (old yellowish, kept)
      (gold      "#f0c96a")   ; types — near peach but distinct for readability
      (blue      "#8ec6e0")   ; variables              (old blueish #84acbd, brighter)
      (teal      "#83d6bd")   ; constants — cool accent, muted so it stays warm-family
      (violet    "#bd9ad8")   ; builtins — richer separation from keywords
      (red       "#e86a76")   ; errors / warnings      (warm, from old #be4222 lineage)
      (green     "#96d99a"))  ; success
  (custom-theme-set-faces
   'some-nice-colors
   `(default ((t (:background ,bg :foreground ,fg))))
   `(cursor ((t (:background ,cursor))))
   `(fringe ((t (:background ,bg :foreground ,fg-alt))))
   `(region ((t (:background ,region))))
   `(highlight ((t (:background "#221417"))))
   `(shadow ((t (:foreground ,faint))))
   `(minibuffer-prompt ((t (:foreground ,peach :weight bold))))
   `(vertical-border ((t (:foreground "#241a19"))))
   `(link ((t (:foreground ,blue :underline t))))
   `(warning ((t (:foreground ,gold :weight bold))))
   `(error ((t (:foreground ,red :weight bold))))
   `(success ((t (:foreground ,green :weight bold))))
   `(mode-line ((t (:background ,bg-alt :foreground ,sage :box (:line-width -1 :color "#332320")))))
   `(mode-line-inactive ((t (:background "#0f0a09" :foreground ,fg-alt :box (:line-width -1 :color "#201614")))))
   `(font-lock-builtin-face ((t (:foreground ,violet))))
   `(font-lock-comment-face ((t (:foreground ,comment :slant italic))))
   `(font-lock-comment-delimiter-face ((t (:foreground "#6f645c"))))
   `(font-lock-constant-face ((t (:foreground ,teal))))
   `(font-lock-doc-face ((t (:foreground "#a89283"))))
   `(font-lock-function-name-face ((t (:foreground ,rose :weight semi-bold))))
   `(init/owl-function-name-face ((t (:foreground ,sage :weight bold))))
   `(font-lock-keyword-face ((t (:foreground ,sage :weight semi-bold))))
   `(font-lock-string-face ((t (:foreground ,peach))))
   `(font-lock-type-face ((t (:foreground ,gold))))
   `(font-lock-variable-name-face ((t (:foreground ,blue))))
   `(font-lock-warning-face ((t (:foreground ,red :weight bold))))
   `(highlight-numbers-number ((t (:foreground ,rose))))
   `(isearch ((t (:background ,peach :foreground ,bg :weight bold))))
   `(lazy-highlight ((t (:background "#3a2733" :foreground ,fg))))
   `(show-paren-match ((t (:background "#4a1a28" :foreground ,peach :weight bold))))
   `(show-paren-mismatch ((t (:background ,red :foreground ,bg :weight bold))))
   `(line-number ((t (:foreground ,faint :background ,bg))))
   `(line-number-current-line ((t (:foreground ,fg :background ,bg-alt))))
   `(header-line ((t (:background ,bg-alt :foreground ,fg-alt :box nil))))
   `(tab-bar ((t (:inherit default :box (:line-width (1 . -1) :color "#332320")))))
   `(tab-bar-tab ((t (:inherit default :weight bold
                      :box (:line-width (1 . -1) :color "#332320")))))
   `(tab-bar-tab-inactive ((t (:inherit default :foreground ,fg-alt :weight normal
                               :box (:line-width (1 . -1) :color "#332320")))))
   `(hl-line ((t (:background "#160f0e"))))
   `(secondary-selection ((t (:background "#2a1a1e"))))
   `(trailing-whitespace ((t (:background "#4a001f"))))
   `(company-tooltip ((t (:background "#160f0e" :foreground ,fg))))
   `(company-tooltip-selection ((t (:background ,region))))
   `(company-tooltip-common ((t (:foreground ,peach :weight bold))))
   `(company-scrollbar-bg ((t (:background "#160f0e"))))
   `(company-scrollbar-fg ((t (:background "#3a2b28"))))
   `(company-preview-common ((t (:foreground ,teal :background ,bg))))
   ;; org-mode — heading scale and colours carried over from the old theme
   `(org-block-begin-line ((t (:height 80 :foreground ,faint))))
   `(org-block-end-line ((t (:height 80 :foreground ,faint))))
   `(org-block ((t (:background ,bg-block))))
   `(org-level-1 ((t (:height 200 :foreground ,rose :weight bold))))
   `(org-level-2 ((t (:height 150 :foreground ,peach :weight bold))))
   `(org-level-3 ((t (:height 130 :foreground ,blue))))
   `(org-level-4 ((t (:height 120 :foreground ,sage))))
   `(org-level-5 ((t (:height 120 :foreground ,teal))))
   `(org-level-6 ((t (:height 120 :foreground ,violet))))
   `(org-document-title ((t (:height 220 :foreground ,blue :weight bold))))
   `(org-document-info ((t (:height 150 :foreground ,blue))))
   `(org-document-info-keyword ((t (:height 80 :foreground ,faint)))))

  (custom-theme-set-variables
   'some-nice-colors
   `(ansi-color-names-vector [,bg ,red ,sage ,gold ,blue ,rose ,teal ,fg])))

(provide-theme 'some-nice-colors)
;;; some-nice-colors-theme.el ends here
