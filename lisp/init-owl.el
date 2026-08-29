;;; init-owl.el --- Major mode for Owl source files -*- lexical-binding: t; -*-

;;; Commentary:

;; Owl is indentation-structured.  A colon opens a layout block, increased
;; indentation groups continuation arguments, and parentheses can group forms
;; inline.  The command set comes from the Owl runtime plus Nest's Owl GUI DSL.
;;
;; The token rules below mirror `tokenize' in owl's src/owl/parser.nim, so
;; fontification agrees with what the lexer actually accepts:
;;
;;   atom start  any character except whitespace and  " ( ) [ ] , : = . ;
;;   atom rest   the same set, except `=' is allowed -- this is exactly why
;;               `+=' and `<=' lex as one atom while `a = 1' is three tokens
;;   `.'         atom-internal only between two digits; otherwise a selector
;;   string      single line; an unterminated quote is a lex error, not a
;;               string that swallows the rest of the file
;;   escape      exactly \" \\ \n \r \t -- anything else the lexer rejects
;;   \(          opens an interpolation, scanned to its matching `)' by paren
;;               depth, holding arbitrary Owl code
;;
;; Strings are applied as syntax-table properties rather than by the syntax
;; table, so a stray quote stays inert instead of stringifying the buffer, and
;; `;' inside a string never opens a comment.

;;; Code:

(require 'subr-x)
(require 'seq)

(defgroup owl nil
  "Editing support for Owl source files."
  :group 'languages)

(defcustom owl-indent-offset 2
  "Indentation step for `owl-mode'."
  :type 'integer
  :safe #'integerp
  :group 'owl)

;;;; Command vocabulary

;; Native commands, from `stdCommand'/`stdAlias' in src/owl/commands.nim.
(defcustom owl-core-command-names
  '("*" "*=" "+" "+=" "-" "-=" "/" "/=" "<" "<=" "=" ">" ">="
    "and" "or" "append" "append-value" "binding-symbol" "binding-value"
    "block-command" "body-of" "call" "command" "command-arg" "command-body"
    "command-define" "command-line-arguments" "command-symbol" "component"
    "concat" "cons" "define" "define-caller-value" "dict" "dict-from"
    "dict-get" "dict-put" "drop-front" "empty?" "error" "eval" "eval-file"
    "eval-source" "eval-with" "exit" "field" "first" "floor" "fn" "fun"
    "import" "index" "lambda" "length" "list" "list-from" "nth" "open-file"
    "open-string" "parse" "pick" "pop-front" "print" "record-constructor"
    "record-predicate" "repl" "rest" "set" "standard-commands" "statements"
    "symbol-text" "to-string" "use" "value-of" "when" "while" "with")
  "Native Owl commands known to the runtime."
  :type '(repeat string)
  :group 'owl)

;; Commands defined in src/owl/prelude.owl.
(defcustom owl-prelude-command-names
  '("not" "if" "else" "[]" "{}" "do" "record" "Stream" "cond" "cond-from"
    "close" "read" "read-line" "read-all" "write" "write-line"
    "range" "countdown" "iter" "once" "for" "for-each" "assert"
    "record-fields" "record-defaults" "field-value" "take-condition-result"
    "else-value" "unsupported-stream-operation")
  "Commands defined by Owl's prelude."
  :type '(repeat string)
  :group 'owl)

(defcustom owl-nest-command-names
  '("id" "clicked" "middleClicked" "focused" "submitted" "keyPressed"
    "external" "state" "send" "received" "receive"
    "perfOverlay" "togglePerfOverlay" "setPerfOverlay"
    "fill" "fit" "fixed" "hug" "prefer" "insets"
    "clock" "today-date" "redrawAfter"
    "pickFile" "pickDirectory" "pickFileEvent" "pickDirectoryEvent"
    "pickResult" "clearPickResult"
    "shell" "shellQuote" "copyText" "clipboardText"
    "windowWidth" "windowHeight" "shellAsync" "shellLaunch" "tsvCell"
    "swayWorkspaces" "swayWorkspaceSubscription"
    "swayActiveWindowSubscription" "swayWorkspaceCommand"
    "string" "textLines" "listAppend" "textFind" "textSlice"
    "lineCount" "lineTextAt" "pathBaseName" "formatNow"
    "editorText" "editorCursor" "setEditorCursor" "setEditorText"
    "clearEditor" "insertEditorText" "editorLine" "editorColumn"
    "setEditorLineColumn" "setEditorSelection" "selectEditorAll"
    "copyEditorSelection" "cutEditorSelection" "pasteEditorClipboard"
    "deleteEditorSelection" "undoEditor" "redoEditor"
    "date" "date-year" "date-month" "date-day" "date-days-in-month"
    "date-first-weekday" "date-month-name" "date-month-title"
    "date-add-months"
    "color" "theme-color" "mix-color"
    "openDialog" "toggleDialog" "dialogOpen?" "closeManagedDialog"
    "dialogResult" "clearDialogResult" "dialogData" "closeDialog"
    "events" "scope" "menuBar" "menu" "menuItem" "menuDivider"
    "menuResult" "clearMenuResult"
    "panel" "card" "dialogHeader" "table" "tableHeader" "tableRow"
    "tableCell" "row" "column" "overlay" "spacer" "label" "button"
    "checkbox" "lineInput" "modalDialog" "tabs" "editor" "image"
    "imageButton" "horizontalSlider" "verticalSlider")
  "Nest GUI commands available in Owl application files."
  :type '(repeat string)
  :group 'owl)

(defconst owl-constant-names
  '("true" "false" "T" "F" "nothing" "stdin" "stdout"
    "AlignAuto" "AlignStart" "AlignCenter" "AlignEnd" "AlignStretch"
    "JustifyStart" "JustifyCenter" "JustifyEnd")
  "Literal and conventional constant symbols in Owl source.")

(defconst owl-definition-command-names
  '("fun" "fn" "lambda" "command" "component" "block-command" "record")
  "Commands whose first argument introduces a callable or type name.")

(defconst owl-block-command-names
  '("define" "command-define" "set" "if" "else" "when" "while" "with"
    "cond" "for" "events" "scope" "menuBar" "menu" "panel" "card"
    "dialogHeader" "table" "tableHeader" "tableRow" "tableCell"
    "row" "column" "overlay" "modalDialog" "tabs")
  "Commands commonly used with colon blocks.")

(defconst owl-configuration-key-names
  '("main" "title" "width" "height" "layerShell" "layer" "namespace"
    "theme" "exclusiveZone" "marginTop" "marginRight" "marginBottom"
    "marginLeft" "gap" "padding" "paddingLeft" "paddingTop"
    "paddingRight" "paddingBottom" "alignItems" "justifyContent"
    "alignSelf" "scrollX" "scrollY" "textScroll" "lineNumbers"
    "scrollbars" "fontName" "fontSize" "buttonPadding" "syntax"
    "syntaxHighlighter" "background" "backgroundColor" "foreground"
    "foregroundColor" "border" "borderColor" "opacity")
  "Common binding names used by Owl project files and Nest UI configs.")

;;;; Token regexps

(defconst owl-identifier-regexp
  "[^][ \t\r\n\"(),:=.;][^][ \t\r\n\"(),:.;]*"
  "Regexp matching one Owl atom.
The first character follows `isAtomStartChar' and the rest
`isAtomPartChar', which is why `=' may appear after the first
character but never as the first one.")

(defconst owl-symbol-regexp
  (concat "\\(?:\\[\\]\\|{}\\|" owl-identifier-regexp "\\)")
  "Regexp matching an Owl atom or a structural command symbol.")

(defconst owl-number-regexp
  "\\_<-?[0-9]+\\(?:\\.[0-9]+\\)*\\_>"
  "Regexp matching Owl numbers.
A dot is only part of a number between two digits, matching
`isNumberDot' in the lexer.")

(defconst owl-selector-regexp
  (concat "\\.\\(" owl-identifier-regexp "\\)")
  "Regexp matching an Owl field selector.")

(defconst owl-delimiter-regexp
  (regexp-opt '("(" ")" "[" "]" ":" "," "."))
  "Regexp matching Owl structural delimiters.
Braces are absent on purpose: `{' and `}' are ordinary atom characters,
so `{}' is the dictionary command rather than a bracket pair.")

(defconst owl-valid-escape-regexp
  "\\\\[\"\\\\nrt]"
  "Regexp matching an escape the Owl lexer accepts.")

(defconst owl-invalid-escape-regexp
  "\\\\[^\"\\\\nrt(]"
  "Regexp matching a backslash escape the Owl lexer rejects.")

(defconst owl-interpolation-open-regexp
  "\\\\("
  "Regexp matching the opening delimiter of an Owl string interpolation.")

;;;; Faces

(defface owl-function-name-face
  '((((class color) (background dark))
     (:foreground "#8be9a8" :weight bold))
    (((class color) (background light))
     (:foreground "#087830" :weight bold))
    (t (:inherit font-lock-function-name-face :weight bold)))
  "Face for names introduced by Owl definition commands."
  :group 'owl)

(defface owl-delimiter-face
  '((t (:inherit font-lock-builtin-face :weight bold)))
  "Face for delimiters in Owl forms."
  :group 'owl)

(defface owl-selector-face
  '((t (:inherit font-lock-property-use-face)))
  "Face for Owl field selectors."
  :group 'owl)

(defface owl-binding-face
  '((t (:inherit font-lock-variable-name-face)))
  "Face for binding names in Owl assignment forms."
  :group 'owl)

(defface owl-escape-face
  '((t (:inherit font-lock-escape-face)))
  "Face for valid escapes inside Owl strings."
  :group 'owl)

(defface owl-invalid-escape-face
  '((t (:inherit font-lock-warning-face)))
  "Face for backslash escapes the Owl lexer rejects."
  :group 'owl)

(defface owl-interpolation-delimiter-face
  '((t (:inherit font-lock-escape-face :weight bold)))
  "Face for the \\( and ) delimiting an Owl string interpolation."
  :group 'owl)

(defface owl-interpolation-face
  '((t (:inherit font-lock-variable-use-face)))
  "Face for the code inside an Owl string interpolation."
  :group 'owl)

;;;; Syntax

(defvar owl-mode-syntax-table
  (let ((table (make-syntax-table prog-mode-syntax-table)))
    ;; Strings come from `owl-syntax-propertize', so a quote carries no
    ;; syntactic weight of its own and cannot run away.
    (modify-syntax-entry ?\" "." table)
    ;; A backslash is only meaningful inside a string, where the string
    ;; fences already delimit; leaving it as an escape would let a trailing
    ;; `\' escape the closing fence.
    (modify-syntax-entry ?\\ "." table)
    (modify-syntax-entry ?_ "w" table)
    (modify-syntax-entry ?- "w" table)
    (modify-syntax-entry ?? "w" table)
    (modify-syntax-entry ?/ "_" table)
    (modify-syntax-entry ?+ "_" table)
    (modify-syntax-entry ?* "_" table)
    (modify-syntax-entry ?< "_" table)
    (modify-syntax-entry ?> "_" table)
    (modify-syntax-entry ?! "_" table)
    ;; Braces are atom characters to the lexer, not a bracket pair.
    (modify-syntax-entry ?{ "_" table)
    (modify-syntax-entry ?} "_" table)
    (modify-syntax-entry ?\[ "(]" table)
    (modify-syntax-entry ?\] ")[" table)
    (modify-syntax-entry ?\( "()" table)
    (modify-syntax-entry ?\) ")(" table)
    (modify-syntax-entry ?. "." table)
    (modify-syntax-entry ?: "." table)
    (modify-syntax-entry ?= "." table)
    (modify-syntax-entry ?\; "<" table)
    (modify-syntax-entry ?\n ">" table)
    table)
  "Syntax table for `owl-mode'.")

(defun owl--string-end (start limit)
  "Return the position of the quote closing an Owl string, or nil.
START is just past the opening quote and LIMIT is the end of the line.
Escapes are skipped, and a `\\(' interpolation is skipped to its matching
`)' by paren depth, so quotes and semicolons inside one do not terminate
the string early."
  (let ((pos start)
        (end nil))
    (while (and (null end) (< pos limit))
      (pcase (char-after pos)
        (?\" (setq end pos))
        (?\\
         (setq pos (1+ pos))
         (if (eq (char-after pos) ?\()
             (let ((depth 1))
               (setq pos (1+ pos))
               (while (and (> depth 0) (< pos limit))
                 (pcase (char-after pos)
                   (?\( (setq depth (1+ depth)))
                   (?\) (setq depth (1- depth))))
                 (setq pos (1+ pos))))
           (setq pos (1+ pos))))
        (_ (setq pos (1+ pos)))))
    end))

(defun owl-syntax-propertize (start end)
  "Mark Owl strings between START and END with string fences.
Owl strings never span a newline, so an unterminated quote is left as
ordinary punctuation rather than turning the rest of the buffer into a
string."
  (goto-char start)
  (forward-line 0)
  (while (< (point) end)
    (let ((eol (line-end-position)))
      (catch 'owl--next-line
        (while (< (point) eol)
          (skip-chars-forward "^\";" eol)
          (when (>= (point) eol)
            (throw 'owl--next-line nil))
          ;; A comment runs to end of line, so any quote after it is text.
          (when (eq (char-after) ?\;)
            (throw 'owl--next-line nil))
          (let* ((open (point))
                 (close (owl--string-end (1+ open) eol)))
            (unless close
              (throw 'owl--next-line nil))
            (put-text-property open (1+ open)
                               'syntax-table (string-to-syntax "|"))
            (put-text-property close (1+ close)
                               'syntax-table (string-to-syntax "|"))
            (goto-char (1+ close))))))
    (forward-line 1)))

;;;; Font lock

(defun owl--all-command-names ()
  "Return all known Owl command names."
  (delete-dups
   (append owl-core-command-names owl-prelude-command-names
           owl-nest-command-names)))

(defun owl--identifier-like-p (name)
  "Return non-nil when NAME can be matched with symbol boundaries."
  (string-match-p "\\`[A-Za-z_][A-Za-z0-9_?/-]*\\'" name))

(defun owl--regexp-opt-symbols (symbols)
  "Return a regexp matching the identifier-like members of SYMBOLS."
  (let ((names (seq-filter #'owl--identifier-like-p symbols)))
    (if names
        (regexp-opt names 'symbols)
      regexp-unmatchable)))

(defun owl--regexp-opt-operators (symbols)
  "Return a regexp matching the operator-like members of SYMBOLS.
Operator names such as `+=' cannot use symbol boundaries, because `='
is punctuation in the syntax table, so they are bounded explicitly by
the characters the lexer treats as token separators."
  (let ((names (seq-remove #'owl--identifier-like-p symbols)))
    (if names
        (concat "\\(?:^\\|[][ \t(),:]\\)\\(" (regexp-opt names) "\\)"
                "\\(?:$\\|[][ \t(),:;]\\)")
      regexp-unmatchable)))

(defun owl--token-in-code-p (position)
  "Return non-nil when POSITION lies outside any Owl string or comment."
  (let ((state (save-excursion (save-match-data (syntax-ppss position)))))
    (not (or (nth 3 state) (nth 4 state)))))

(defun owl--token-in-string-p (position)
  "Return non-nil when POSITION lies inside an Owl string."
  (let ((state (save-excursion (save-match-data (syntax-ppss position)))))
    (and (nth 3 state) t)))

(defun owl--search-in-string (regexp limit)
  "Search forward for REGEXP before LIMIT, matching only inside strings."
  (catch 'owl--found
    (while (re-search-forward regexp limit t)
      (when (owl--token-in-string-p (match-beginning 0))
        (throw 'owl--found t)))
    nil))

(defun owl--match-valid-escape (limit)
  "Match a valid Owl string escape before LIMIT."
  (owl--search-in-string owl-valid-escape-regexp limit))

(defun owl--match-invalid-escape (limit)
  "Match a backslash escape the Owl lexer rejects, before LIMIT."
  (owl--search-in-string owl-invalid-escape-regexp limit))

(defun owl--match-interpolation (limit)
  "Match an Owl `\\(...)' string interpolation before LIMIT.
Group 1 is the opening `\\(', group 2 the interpolated code, and group 3
the closing `)'."
  (catch 'owl--found
    (while (re-search-forward owl-interpolation-open-regexp limit t)
      (let ((open (match-beginning 0)))
        (when (owl--token-in-string-p open)
          (let* ((eol (line-end-position))
                 (body (point))
                 (depth 1)
                 (pos body)
                 (close nil))
            (while (and (null close) (< pos eol))
              (pcase (char-after pos)
                (?\( (setq depth (1+ depth)))
                (?\) (setq depth (1- depth))))
              (if (zerop depth)
                  (setq close pos)
                (setq pos (1+ pos))))
            (when close
              (set-match-data
               (list open (1+ close)
                     open body
                     body close
                     close (1+ close)))
              (goto-char (1+ close))
              (throw 'owl--found t))))))
    nil))

(defun owl--match-selector (limit)
  "Match an Owl field selector before LIMIT.
A dot between two digits is part of a number rather than a selector,
matching `isNumberDot' in the lexer, so `1.5' is left alone."
  (catch 'owl--found
    (while (re-search-forward owl-selector-regexp limit t)
      (let* ((dot (match-beginning 0))
             (prev (and (> dot (point-min)) (char-before dot)))
             (next (char-after (1+ dot))))
        (unless (or (and prev next
                         (<= ?0 prev) (<= prev ?9)
                         (<= ?0 next) (<= next ?9))
                    (not (owl--token-in-code-p dot)))
          (throw 'owl--found t))))
    nil))

(defun owl--match-binding (limit)
  "Match an Owl binding name before LIMIT.
Group 1 is the bound symbol.  A binding needs whitespace before its `=',
because `=' is an atom character after the first position -- `a=1' is a
single atom to the lexer, not an assignment."
  (let ((regexp (concat "\\(?:^\\|[ \t([,]\\)\\(" owl-symbol-regexp
                        "\\)[ \t]+=\\(?:[ \t]\\|$\\)")))
    (catch 'owl--found
      (while (re-search-forward regexp limit t)
        (when (owl--token-in-code-p (match-beginning 1))
          (throw 'owl--found t)))
      nil)))

(defun owl--match-command-head (limit)
  "Search for a known command at the start of an Owl form before LIMIT."
  (let ((regexp (concat "\\(" (regexp-opt (owl--all-command-names)) "\\)"))
        (case-fold-search nil))
    (catch 'owl--found
      (while (re-search-forward regexp limit t)
        (let ((start (match-beginning 1)))
          (when (and (owl--token-in-code-p start)
                     (save-excursion
                       (goto-char start)
                       (skip-chars-backward " \t")
                       (or (bolp)
                           (eq (char-before) ?\()
                           (eq (char-before) ?\n)))
                     (save-excursion
                       (goto-char (match-end 1))
                       (or (eobp)
                           (looking-at-p "[][ \t\r\n(){}:;,.]"))))
            (throw 'owl--found t))))
      nil)))

(defvar-local owl-font-lock-keywords nil
  "Buffer-local Owl font-lock keywords.")

(defun owl--font-lock-keywords ()
  "Build Owl font-lock keywords from the configured command lists."
  `(;; Inside strings.  These run with `prepend' so they win over the
    ;; string face that syntactic fontification has already applied.
    (owl--match-interpolation
     (1 'owl-interpolation-delimiter-face prepend)
     (2 'owl-interpolation-face prepend)
     (3 'owl-interpolation-delimiter-face prepend))
    (owl--match-valid-escape (0 'owl-escape-face prepend))
    (owl--match-invalid-escape (0 'owl-invalid-escape-face prepend))
    ;; Code.
    (,(owl--regexp-opt-symbols owl-constant-names) . 'font-lock-constant-face)
    (,(owl--regexp-opt-symbols owl-block-command-names) . 'font-lock-keyword-face)
    (owl--match-binding 1 'owl-binding-face)
    (,(concat "\\_<\\(" (owl--regexp-opt-symbols owl-configuration-key-names)
              "\\)\\_>[ \t]+=\\(?:[ \t]\\|$\\)")
     1 'owl-binding-face)
    (,(concat "\\_<\\(" (owl--regexp-opt-symbols owl-definition-command-names)
              "\\)\\_>[ \t]+\\(?:(\\)?\\(" owl-symbol-regexp "\\)")
     (1 'font-lock-keyword-face)
     (2 'owl-function-name-face))
    (,owl-number-regexp . 'font-lock-constant-face)
    (owl--match-selector 1 'owl-selector-face)
    (owl--match-command-head 1 'font-lock-function-name-face)
    (,(owl--regexp-opt-symbols owl-core-command-names) . 'font-lock-builtin-face)
    (,(owl--regexp-opt-operators owl-core-command-names) 1 'font-lock-builtin-face)
    (,(owl--regexp-opt-symbols owl-prelude-command-names) . 'font-lock-builtin-face)
    (,(owl--regexp-opt-symbols owl-nest-command-names) . 'font-lock-function-name-face)
    (,owl-delimiter-regexp 0 'owl-delimiter-face)))

;;;; Indentation

(defun owl--line-opens-block-p ()
  "Return non-nil when the current line opens an Owl colon block."
  (save-excursion
    (end-of-line)
    (skip-chars-backward " \t")
    (and (eq (char-before) ?:)
         (owl--token-in-code-p (1- (point))))))

(defun owl--blank-or-comment-line-p ()
  "Return non-nil when the current Owl line is blank or a comment."
  (save-excursion
    (back-to-indentation)
    (or (eolp) (looking-at-p ";"))))

(defun owl--goto-previous-code-line ()
  "Move to the previous non-blank, non-comment line.
Return non-nil when such a line exists."
  (let (found)
    (while (and (not found) (> (line-number-at-pos) 1))
      (forward-line -1)
      (unless (owl--blank-or-comment-line-p)
        (setq found t)))
    found))

(defun owl--goto-previous-enclosing-line (indent)
  "Move to the previous code line indented less than INDENT.
Return non-nil when such a line exists."
  (let (found)
    (while (and (not found) (owl--goto-previous-code-line))
      (when (< (current-indentation) indent)
        (setq found t)))
    found))

(defun owl--indent-for-new-line ()
  "Return indentation for a fresh line after the previous code line."
  (save-excursion
    (if (owl--goto-previous-code-line)
        (+ (current-indentation)
           (if (owl--line-opens-block-p) owl-indent-offset 0))
      0)))

(defun owl--indent-for-existing-line (indent)
  "Return desired indentation for an existing line currently at INDENT."
  (if (zerop indent)
      0
    (save-excursion
      (if (owl--goto-previous-enclosing-line indent)
          (+ (current-indentation)
             (if (owl--line-opens-block-p) owl-indent-offset 0))
        indent))))

(defun owl-calculate-indentation ()
  "Return desired indentation for the current Owl line."
  (save-excursion
    (back-to-indentation)
    (let ((ppss (syntax-ppss)))
      (cond
       ;; Inside a string, leave the line exactly where it is.
       ((nth 3 ppss) (current-indentation))
       ;; A line starting with `)' closes its group, so it lines up with
       ;; the line that opened it.
       ((and (nth 1 ppss) (looking-at-p ")"))
        (goto-char (nth 1 ppss))
        (current-indentation))
       ;; Continuation lines inside a group hang off the opening line.
       ((nth 1 ppss)
        (goto-char (nth 1 ppss))
        (+ (current-indentation) owl-indent-offset))
       ((owl--blank-or-comment-line-p) (owl--indent-for-new-line))
       (t (owl--indent-for-existing-line (current-indentation)))))))

(defun owl-indent-line ()
  "Indent the current Owl line."
  (interactive)
  (let ((indent (owl-calculate-indentation))
        (offset (- (current-column) (current-indentation))))
    (indent-line-to indent)
    (when (> offset 0)
      (move-to-column (+ indent offset)))))

(defun owl-tab ()
  "Insert spaces up to the next Owl indentation column."
  (interactive)
  (insert (make-string (- owl-indent-offset
                          (% (current-column) owl-indent-offset))
                       ?\s)))

(defun owl-beginning-of-block ()
  "Move to the nearest previous line that opens an Owl block."
  (interactive)
  (let ((origin (point))
        found)
    (while (and (not found) (owl--goto-previous-code-line))
      (setq found (owl--line-opens-block-p)))
    (unless found
      (goto-char origin))))

;;;; Mode

(defvar owl-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "TAB") #'owl-tab)
    (define-key map (kbd "C-M-a") #'owl-beginning-of-block)
    map)
  "Keymap for `owl-mode'.")

;;;###autoload
(define-derived-mode owl-mode prog-mode "Owl"
  "Major mode for editing Owl source files."
  :syntax-table owl-mode-syntax-table
  (setq-local owl-font-lock-keywords (owl--font-lock-keywords))
  (setq-local font-lock-defaults '(owl-font-lock-keywords nil nil nil nil))
  (setq-local syntax-propertize-function #'owl-syntax-propertize)
  (setq-local parse-sexp-lookup-properties t)
  (setq-local indent-line-function #'owl-indent-line)
  (setq-local comment-start "; ")
  (setq-local comment-end "")
  (setq-local comment-start-skip ";+\\s-*")
  (setq-local tab-width owl-indent-offset)
  (setq-local indent-tabs-mode nil)
  (setq-local electric-indent-chars (append (list ?: 10) electric-indent-chars))
  (setq-local imenu-generic-expression
              `(("Definitions"
                 ,(concat "^[ \t]*"
                          (regexp-opt owl-definition-command-names)
                          "[ \t]+\\(?:(\\)?\\(" owl-symbol-regexp "\\)")
                 1)
                ("Bindings" ,(concat "^[ \t]*\\(" owl-identifier-regexp
                                     "\\)[ \t]+=")
                 1))))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.owl\\'" . owl-mode))

(provide 'init-owl)
;;; init-owl.el ends here
