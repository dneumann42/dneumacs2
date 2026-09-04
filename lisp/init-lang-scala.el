;;; init-lang-scala.el --- Scala -*- lexical-binding: t; -*-

;;; Commentary:

;; Scala, served by Metals -- the Scala language server the sbt, mill and
;; scala-cli toolchains are all built to talk to.  Nothing here assumes a
;; Scala installation already exists on the machine:
;; `init/scala-install-server' downloads Coursier, a JDK Metals is known
;; to support, Metals itself, and the sbt, scala-cli and scalafmt
;; launchers, all into `init/scala-server-directory'.  Opening a Scala
;; file while Metals is missing offers to run it.
;;
;; Metals runs on the JVM, so unlike kotlin-lsp it needs a JDK.  Fedora
;; and friends ship a headless JRE as `java', and a JDK newer than
;; `init/scala-java-releases' breaks the compilers Metals drives, so the
;; JDK is *chosen* rather than inherited from PATH: the newest installed
;; release Metals supports, else the one Coursier manages for us.  See
;; `init/scala--java-home'.
;;
;; Everything hangs off the major-mode hooks.  Metals wants a couple of
;; gigabytes of heap and indexes the whole build on first contact, so a
;; session that opens no Scala file pays for none of it.
;;
;; Like the Kotlin and Java module, the server is rooted at the *build* a
;; file belongs to -- the directory holding project/build.properties,
;; build.mill, .bsp and friends -- rather than at the enclosing
;; repository, through a buffer-local `project-find-functions' entry.
;; Project resolution in every other buffer is untouched.
;;
;; Run, test and build go through whichever build tool the root declares
;; (sbt, mill, scala-cli, Gradle or Maven) and address the sbt subproject
;; or mill module owning the buffer, so <f6> in
;; modules/core/src/test/scala/... runs that one test rather than the
;; build's whole suite.
;;
;; Scala 3 indentation is significant, so editing is handled here rather
;; than left to scala-mode, which was written for Scala 2 and reindents
;; as you type.  See the `;;;; Indentation-sensitive editing' section.
;;
;; Beyond plain LSP, three Metals extensions are wired up because they
;; are what make it feel like an IDE rather than a completion server:
;; `metals/status' reports what the build is doing,
;; `metals/didFocusTextDocument' makes it recompile the file you switched
;; to, and `metals/executeClientCommand' carries the Doctor's report and
;; the jump that follows "go to super method".

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'url)
(require 'init-ide)
(require 'init-keys)
(require 'init-lib)
;; For `init/jvm-installed-jdks': both modules have to pick a JDK off the
;; machine, and there is only one right way to look for one.
(require 'init-lang-jvm)

(declare-function cheatsheet-show "init-cheatsheet")
(declare-function dape "dape")
(declare-function eglot-current-server "eglot")
(declare-function eglot-ensure "eglot")
(declare-function eglot-execute "eglot")
(declare-function eglot-path-to-uri "eglot")
(declare-function eglot-uri-to-path "eglot")
(declare-function jsonrpc-notify "jsonrpc")
(declare-function shr-insert-document "shr")

(declare-function scala-indent:fix-scaladoc-close "scala-mode-indent")
(declare-function scala-indent:indent-on-parentheses "scala-mode-indent")
(declare-function scala-indent:indent-on-scaladoc-asterisk "scala-mode-indent")
(declare-function scala-indent:indent-on-special-words "scala-mode-indent")
(declare-function scala-indent:remove-indent-from-previous-empty-line
                  "scala-mode-indent")

(defvar eglot-server-programs)
(defvar scala-indent:step)
(defvar scala-mode-map)
(defvar scala-ts-indent-offset)
(defvar scala-ts-mode-map)

;;;; Where things live

(defgroup init/scala nil
  "Scala editing support."
  :group 'languages
  :prefix "init/scala-")

(defcustom init/scala-server-directory
  (expand-file-name "lsp-servers" user-emacs-directory)
  "Directory Metals and the Scala command-line tools are installed into."
  :type 'directory
  :group 'init/scala)

(defcustom init/scala-metals-artifact "org.scalameta:metals_2.13"
  "Maven coordinates of the Metals artifact, without a version.
Metals is published for Scala 2.13 whatever Scala version it serves."
  :type 'string
  :group 'init/scala)

(defcustom init/scala-metals-version nil
  "Metals release to install.
When nil the newest stable release is looked up at install time.
Coursier's own `latest.release' is not used: Maven's metadata names
milestones as the current release, and a Metals milestone is not what a
working editor should be pinned to."
  :type '(choice (const :tag "Newest stable release" nil) string)
  :group 'init/scala)

(defcustom init/scala-metals-heap "4g"
  "Maximum heap for the Metals server.
Applied by the launcher, so changing it needs `init/scala-install-server'
to be run again."
  :type 'string
  :group 'init/scala)

(defcustom init/scala-metals-metadata-url
  "https://repo1.maven.org/maven2/org/scalameta/metals_2.13/maven-metadata.xml"
  "Maven metadata listing the published Metals releases."
  :type 'string
  :group 'init/scala)

(defcustom init/scala-coursier-url nil
  "Archive the Coursier launcher is installed from.
When nil it is derived from the platform; set this to pin a build."
  :type '(choice (const :tag "Newest release for this platform" nil) string)
  :group 'init/scala)

(defcustom init/scala-tools '("sbt" "scala-cli" "scalafmt")
  "Coursier applications installed alongside Metals.
Metals shells out to the build tool to import a build, so sbt has to
exist for an sbt project to resolve at all.  They are installed into
`init/scala-tools-directory', which is put on `exec-path' rather than
into any shell profile."
  :type '(repeat string)
  :group 'init/scala)

(defun init/scala-coursier-command ()
  "Return the path of the Coursier launcher."
  (expand-file-name "coursier/cs" init/scala-server-directory))

(defun init/scala-metals-command ()
  "Return the path of the Metals launcher."
  (expand-file-name "metals/bin/metals" init/scala-server-directory))

(defun init/scala-tools-directory ()
  "Return the directory holding the Scala command-line tools."
  (expand-file-name "scala-tools" init/scala-server-directory))

(defun init/scala-server-installed-p ()
  "Return non-nil when Metals is installed."
  (file-executable-p (init/scala-metals-command)))

(defun init/scala--add-tools-to-path ()
  "Put the installed Scala tools on `exec-path' and PATH.
Metals starts the build tool itself, so this has to reach the
environment of Emacs and not merely of a compilation buffer."
  (init/prepend-to-path (init/scala-tools-directory)))

;;;; Indentation-sensitive editing

;; Scala 3 made indentation significant.  A `:' or `=' at the end of a
;; line opens a block that runs until the indentation comes back, and
;; nothing closes it -- so moving a line's indentation moves it into or
;; out of that block.  Indentation here is meaning, not layout, and two
;; things follow from that.  Nothing may reindent a line the author did
;; not ask to have reindented.  And RET has to leave the cursor where the
;; block just opened begins, because there is no closing token to align
;; to afterwards.
;;
;; scala-mode was written for Scala 2, where braces made reindenting
;; safe, so it reindents while you type: on parentheses, and on the words
;; `else', `catch', `finally' and `yield' -- which Scala 3 uses to open
;; blocks rather than to continue braced ones.  It also strips the
;; indentation off a line that has been indented but not yet typed on,
;; which is the one piece of state an indentation-based edit depends on.
;; `init/scala-editing-setup' turns all of that off and puts RET, DEL and
;; TAB in its place.

(defcustom init/scala-indent-offset 2
  "Columns one level of Scala indentation is worth.
Also given to whichever mode is editing the buffer, so that its own
indentation agrees with the commands here."
  :type 'integer
  :group 'init/scala)

(defconst init/scala--block-opener-regexp
  (concat "\\(?:"
          ;; `class Foo:', `if x then:' -- the Scala 3 block colon.
          ":"
          ;; A case or lambda arrow.
          "\\|=>"
          ;; The `=' of a definition, but not the tail of `==' or `<='.
          "\\|\\(?:\\`\\|[^=!<>+*/%^&|~-]\\)="
          ;; Keywords that open a block where they end a line.
          "\\|\\_<\\(?:then\\|else\\|do\\|yield\\|try\\|catch\\|finally"
          "\\|match\\|with\\)"
          "\\)\\'")
  "Regexp matching the end of a line that opens an indented block.
Anchored at the end, and matched against the line's code with any
trailing comment already removed.")

(defun init/scala--line-indent ()
  "Return the visible indentation of the current line."
  (save-excursion
    (back-to-indentation)
    (current-column)))

(defun init/scala--code-end ()
  "Return where the current line's code ends, before any trailing comment.
A comment says nothing about whether the line opened a block, so it is
not read as though it did."
  (save-excursion
    (goto-char (line-end-position))
    (let ((state (syntax-ppss)))
      (goto-char (if (nth 4 state)
                     (max (line-beginning-position) (nth 8 state))
                   (point))))
    (skip-chars-backward "[:space:]" (line-beginning-position))
    (point)))

(defun init/scala--opens-block-p (&optional limit)
  "Return non-nil when the line at point opens an indented block.
Only the code up to LIMIT is read, so a line split with RET is judged by
what stays behind rather than by what moves down."
  (save-excursion
    (let* ((end (min (or limit (point-max)) (init/scala--code-end)))
           (start (progn (back-to-indentation) (point))))
      (and (< start end)
           ;; Inside a multi-line string every character is text, and a
           ;; line of it ending in `:' opens nothing.
           (not (nth 3 (syntax-ppss start)))
           (not (nth 3 (syntax-ppss end)))
           (or
            ;; A bracket opened on this line and not closed on it.
            (> (car (syntax-ppss end)) (car (syntax-ppss start)))
            (string-match-p init/scala--block-opener-regexp
                            (buffer-substring-no-properties start end)))))))

(defun init/scala-newline (&optional count)
  "Insert COUNT newlines, keeping Scala 3's significant indentation.
The new line starts at the current line's indentation, one step deeper
where that line opened a block.  Nothing already written is reindented;
TAB is how an explicit recalculation is asked for."
  (interactive "p")
  (let ((indent (+ (init/scala--line-indent)
                   (if (init/scala--opens-block-p (point))
                       init/scala-indent-offset
                     0)))
        (electric-indent-inhibit t))
    ;; Whitespace at the split point would otherwise ride down and sit in
    ;; front of the indentation, putting the line one or two columns off
    ;; the level it was just given.  Inside a string it is content.
    (unless (nth 3 (syntax-ppss))
      (delete-horizontal-space))
    (dotimes (_ (or count 1))
      (newline)
      (indent-to indent))))

(defun init/scala-open-line-below ()
  "Open a line below the current one, at the indentation Scala wants there."
  (interactive)
  (end-of-line)
  (init/scala-newline))

(defun init/scala-open-line-above ()
  "Open a line above the current one, at this line's indentation."
  (interactive)
  (let ((indent (init/scala--line-indent)))
    (beginning-of-line)
    (insert "\n")
    (forward-line -1)
    (indent-to indent)))

(defun init/scala-backspace (arg)
  "Delete backward, dedenting by one level inside the leading whitespace.
ARG is passed through to `backward-delete-char-untabify' everywhere else."
  (interactive "*p")
  (if (and (not current-prefix-arg)
           (= (current-column) (current-indentation))
           (> (current-indentation) 0))
      (indent-line-to (max 0 (- (current-indentation) init/scala-indent-offset)))
    (backward-delete-char-untabify arg)))

(defun init/scala--shift (columns)
  "Shift the region, or the current line when there is none, by COLUMNS."
  (let ((start (if (use-region-p) (region-beginning) (line-beginning-position)))
        (end (if (use-region-p) (region-end) (line-end-position))))
    (indent-rigidly start end columns)
    ;; Keep the region alive, so a block can be moved several levels
    ;; without selecting it again.
    (setq deactivate-mark nil)))

(defun init/scala-shift-right (&optional count)
  "Indent the region, or the current line, COUNT levels deeper."
  (interactive "p")
  (init/scala--shift (* (or count 1) init/scala-indent-offset)))

(defun init/scala-shift-left (&optional count)
  "Indent the region, or the current line, COUNT levels shallower."
  (interactive "p")
  (init/scala--shift (- (* (or count 1) init/scala-indent-offset))))

(defvar-local init/scala--indent-function nil
  "The major mode's own `indent-line-function', before this module's.")

(defun init/scala--blank-line-p ()
  "Return non-nil when the current line holds nothing but whitespace."
  (save-excursion
    (beginning-of-line)
    (looking-at-p "[[:space:]]*$")))

(defun init/scala--indent-candidates ()
  "Return the columns this line could be indented to, deepest first.
One step deeper than the nearest line of code above -- where a block
opened there would begin -- then that line's own level and every level
enclosing it, down to the left margin."
  (save-excursion
    (beginning-of-line)
    (let ((levels (list 0))
          (nearest nil)
          (done nil))
      (while (and (not done) (not (bobp)))
        (forward-line -1)
        (unless (init/scala--blank-line-p)
          (let ((indent (current-indentation)))
            (unless nearest
              (setq nearest indent)
              (push (+ indent init/scala-indent-offset) levels))
            (push indent levels)
            (when (zerop indent) (setq done t)))))
      (sort (delete-dups levels) #'>))))

(defun init/scala--natural-indent ()
  "Return the column the code above this line puts it at.
The same rule RET follows, so the two never disagree: the nearest line
of code above, one level deeper where that line opened a block."
  (save-excursion
    (beginning-of-line)
    (let ((indent nil))
      (while (and (null indent) (not (bobp)))
        (forward-line -1)
        (unless (init/scala--blank-line-p)
          (setq indent (+ (current-indentation)
                          (if (init/scala--opens-block-p)
                              init/scala-indent-offset
                            0)))))
      (or indent 0))))

(defun init/scala--nested-context-p ()
  "Return non-nil when this line sits inside brackets, a string or a comment."
  (let ((state (syntax-ppss (line-beginning-position))))
    (or (> (car state) 0) (nth 3 state) (nth 4 state))))

(defun init/scala-indent-line ()
  "Indent this line, cycling through the plausible levels on a repeated TAB.
The first press takes the level the code above implies, which is the one
RET would have used.  Pressing again steps out a level at a time and
wraps round at the left margin -- which is how a block is closed in a
language where nothing else closes it, and so how `else', `case' and an
`end' marker are put back where they belong.

Inside brackets, a string or a comment the major mode is asked instead:
aligning under an open paren, a scaladoc asterisk or a string's `|'
margin is not something indentation levels alone can work out."
  (interactive)
  (cond
   ((and (eq this-command 'indent-for-tab-command)
         (eq last-command 'indent-for-tab-command))
    (let* ((current (current-indentation))
           (levels (init/scala--indent-candidates)))
      (indent-line-to (or (seq-find (lambda (level) (< level current)) levels)
                          (car levels)))))
   ((init/scala--nested-context-p)
    (funcall (or init/scala--indent-function #'indent-relative)))
   (t (indent-line-to (init/scala--natural-indent)))))

(defun init/scala-editing-setup ()
  "Make Scala editing conservative around Scala 3's significant indentation."
  (when (fboundp 'electric-indent-local-mode)
    (electric-indent-local-mode -1))
  (setq-local electric-indent-inhibit t
              electric-indent-chars nil
              indent-tabs-mode nil
              tab-width init/scala-indent-offset)
  (when (boundp 'scala-indent:step)
    (setq-local scala-indent:step init/scala-indent-offset))
  (when (boundp 'scala-ts-indent-offset)
    (setq-local scala-ts-indent-offset init/scala-indent-offset))
  ;; scala-mode reindents the line as these are typed.
  (dolist (function '(scala-indent:indent-on-parentheses
                      scala-indent:indent-on-special-words
                      scala-indent:indent-on-scaladoc-asterisk
                      scala-indent:fix-scaladoc-close))
    (remove-hook 'post-self-insert-hook function t))
  ;; And this one throws away the indentation of a line that has been
  ;; indented but not yet typed on -- the whole state of an unfinished
  ;; edit.  It is scala-mode's own function and hangs off the global
  ;; hook, so it is removed there.
  (remove-hook 'post-command-hook
               #'scala-indent:remove-indent-from-previous-empty-line)
  (unless (eq indent-line-function #'init/scala-indent-line)
    (setq-local init/scala--indent-function indent-line-function
                indent-line-function #'init/scala-indent-line)))

;;;; Build roots

(defcustom init/scala-build-markers
  '("project/build.properties" "build.mill" "build.sc" ".bsp"
    "settings.gradle.kts" "settings.gradle" "pom.xml")
  "Files marking the root of the build a Scala source file belongs to.
Only files that define a whole build belong here.  A subproject of an
sbt build carries its own build.sbt often enough that build.sbt is not
one of them -- project/build.properties is what an sbt *build* root
always has and a subproject never does."
  :type '(repeat string)
  :group 'init/scala)

(defcustom init/scala-module-markers
  '("build.sbt" "project.scala" "build.gradle.kts" "build.gradle")
  "Files marking one module inside a build.
Used as the build root only when no `init/scala-build-markers' match,
which is how a single-project build with no wrapper looks."
  :type '(repeat string)
  :group 'init/scala)

(defun init/scala--source-directory ()
  "Return the directory this buffer's build has to be resolved from.
File buffers get `default-directory' set to the Git repository root (see
init-editor.el), which in a monorepo sits far above the build, so the
walk upwards has to start at the file's own directory instead."
  (if buffer-file-name
      (file-name-directory buffer-file-name)
    default-directory))

(defun init/scala--build-root (&optional dir)
  "Return the root of the Scala build containing DIR, or nil."
  (let ((dir (or dir (init/scala--source-directory))))
    (or (init/locate-dominating-match init/scala-build-markers dir)
        (init/locate-dominating-match init/scala-module-markers dir))))

(defun init/scala-project-root (&optional dir)
  "Return the root of the Scala build containing DIR.
Falls back to the shared project root when DIR is in no build at all,
which is what a loose .sc script in a repository looks like."
  (expand-file-name
   (or (init/scala--build-root dir)
       (init/project-root (or dir (init/scala--source-directory))))))

(defun init/scala--project-try (dir)
  "Return the Scala build containing DIR as a project.el project, or nil.
Added buffer-locally to `project-find-functions' in Scala buffers only,
so Eglot roots Metals at the build while every other buffer keeps
resolving projects exactly as before.  A cons of `transient' and a
directory is project.el's own representation of a rootless project."
  (when-let* ((root (init/scala--build-root
                     (if buffer-file-name (init/scala--source-directory) dir))))
    (cons 'transient (expand-file-name root))))

(defconst init/scala--build-tools
  '((sbt "project/build.properties" "build.sbt")
    (mill "build.mill" "build.sc")
    (gradle "settings.gradle.kts" "settings.gradle"
            "build.gradle.kts" "build.gradle")
    (maven "pom.xml"))
  "Build tools, each with the files that name it at a build root.
Read in order, so a build carrying definitions for two of them is
attributed to the first -- which is the one Metals imports.")

(defun init/scala--build-tool (&optional directory)
  "Return the build tool governing DIRECTORY, as a symbol.
`scala-cli' is the answer for a directory with no build definition at
all, since it is the tool that compiles and runs plain Scala sources.

Written without a closure over the directory on purpose: a lexical
closure silently reads the *global* value of a variable that some other
package has made special, and `root' is a name common enough for that to
happen."
  (let ((where (or directory (init/scala-project-root))))
    (catch 'found
      (dolist (entry init/scala--build-tools)
        (dolist (marker (cdr entry))
          (when (file-exists-p (expand-file-name marker where))
            (throw 'found (car entry)))))
      'scala-cli)))

;;;; The JDK Metals runs on

(defcustom init/scala-java-releases '(21 17)
  "Java releases Metals may run on, in order of preference.
Metals drives the Scala and Java compilers through Bloop, both of which
reject a JDK newer than they were built against, so the newest JDK on
the machine is the wrong default.  When none of these is installed, the
release named in `init/scala-managed-jvm' is downloaded instead."
  :type '(repeat integer)
  :group 'init/scala)

(defcustom init/scala-managed-jvm "temurin:21"
  "JVM Coursier fetches when the machine has no JDK Metals supports.
Named the way Coursier names them: a distribution and a release."
  :type 'string
  :group 'init/scala)

(defvar init/scala--coursier-java-home 'unknown
  "Cached home of the Coursier-managed JDK, or `unknown'.
Asking Coursier costs a subprocess, and the answer cannot change while
Emacs runs unless the JDK is installed from within it -- which is what
`init/scala-install-server' invalidates this for.")

(defun init/scala--installed-java-home ()
  "Return an installed JDK Metals supports, or nil.
`init/scala-java-releases' is a preference order, so a machine carrying
both 17 and 21 is served by 21."
  (let ((jdks (init/jvm-installed-jdks)))
    (cdr (seq-some (lambda (release) (assq release jdks))
                   init/scala-java-releases))))

(defun init/scala--managed-java-home ()
  "Return the home of the Coursier-managed JDK, or nil.
Coursier prints the home of a JVM it manages and downloads it when it is
missing, so this answers only once the install step has run."
  (when (eq init/scala--coursier-java-home 'unknown)
    (setq init/scala--coursier-java-home
          (when (file-executable-p (init/scala-coursier-command))
            (with-temp-buffer
              (when (zerop (call-process (init/scala-coursier-command) nil t nil
                                         "java-home" "--jvm"
                                         init/scala-managed-jvm))
                ;; Coursier reports its downloads on the way to the
                ;; answer, so the home is the last line and not the
                ;; whole output.
                (let ((home (car (last (split-string (buffer-string)
                                                     "\n" t "[[:space:]]+")))))
                  (and home (file-directory-p home) home)))))))
  init/scala--coursier-java-home)

(defun init/scala--java-home ()
  "Return the JDK Metals and its build tools should run under, or nil.
Nil leaves whatever `java' leads to in charge, which is right only when
nothing better could be found."
  (or (init/scala--installed-java-home)
      (init/scala--managed-java-home)))

;;;; Installing Metals and the toolchain

(defconst init/scala--install-buffer-name "*Scala language server*"
  "Name of the buffer showing install progress.")

(defvar init/scala--install-declined nil
  "Non-nil once the install offer has been declined in this session.")

(defun init/scala--install-log (format-string &rest arguments)
  "Insert FORMAT-STRING formatted with ARGUMENTS into the install buffer."
  (with-current-buffer (get-buffer-create init/scala--install-buffer-name)
    (goto-char (point-max))
    (let ((inhibit-read-only t))
      (insert (apply #'format format-string arguments)))))

(defun init/scala--coursier-url ()
  "Return the URL of the Coursier launcher for this machine.
Coursier publishes one static binary per platform under a fixed name in
its newest release, so the URL can be built rather than looked up."
  (or init/scala-coursier-url
      (let ((arm (string-match-p "aarch64\\|arm" system-configuration)))
        (concat "https://github.com/coursier/coursier/releases/latest/download/cs-"
                (if arm "aarch64" "x86_64")
                (pcase system-type
                  ('darwin "-apple-darwin.gz")
                  (_ "-pc-linux.gz"))))))

(defun init/scala--newest-metals-version ()
  "Return the newest stable Metals release published to Maven Central.
Maven's metadata lists versions in release order, so the last one
carrying no pre-release suffix is the newest stable."
  (or init/scala-metals-version
      (let ((buffer (url-retrieve-synchronously
                     init/scala-metals-metadata-url t t 30))
            version)
        (unless buffer
          (user-error "Could not reach %s" init/scala-metals-metadata-url))
        (unwind-protect
            (with-current-buffer buffer
              (goto-char (point-min))
              (while (re-search-forward
                      "<version>\\([0-9][0-9.]*\\)</version>" nil t)
                (setq version (match-string 1)))
              (or version
                  (user-error "No stable Metals release found at %s"
                              init/scala-metals-metadata-url)))
          (kill-buffer buffer)))))

(defun init/scala--shell (&rest lines)
  "Return LINES as one shell script that stops at the first failure."
  (mapconcat #'identity (cons "set -e" (delq nil lines)) "\n"))

(defun init/scala--coursier-step ()
  "Return the install step fetching the Coursier launcher.
Coursier is a static binary needing no JVM of its own, which is what
makes it able to install the JDK the rest of this depends on."
  (let ((directory (expand-file-name "coursier" init/scala-server-directory))
        (url (init/scala--coursier-url)))
    (cons "Coursier launcher (~20 MB)"
          (init/scala--shell
           (format "mkdir -p %s" (shell-quote-argument directory))
           (format "curl -fL --progress-bar %s -o %s"
                   (shell-quote-argument url)
                   (shell-quote-argument (concat directory "/cs.gz")))
           (format "gzip -df %s" (shell-quote-argument (concat directory "/cs.gz")))
           (format "chmod +x %s" (shell-quote-argument (concat directory "/cs")))))))

(defun init/scala--jdk-step ()
  "Return the install step fetching a JDK Metals supports, or nil.
Skipped when the machine already has one, so the usual case downloads
nothing.  `java-home' both installs and prints the JDK, and unlike
Coursier's `setup' it writes to no shell profile."
  (unless (init/scala--installed-java-home)
    (cons (format "JDK for Metals (%s, ~180 MB)" init/scala-managed-jvm)
          (format "%s java-home --jvm %s"
                  (shell-quote-argument (init/scala-coursier-command))
                  (shell-quote-argument init/scala-managed-jvm)))))

(defun init/scala--metals-step ()
  "Return the install step bootstrapping Metals.
The bootstrap is a launcher that carries its own dependency list and
resolves it once, so starting the server later costs no downloads.  The
stack and heap sizes Metals asks for are baked in here because the
launcher is what applies them."
  (let* ((version (init/scala--newest-metals-version))
         (directory (expand-file-name "metals/bin" init/scala-server-directory)))
    (cons (format "Metals %s (~150 MB)" version)
          (init/scala--shell
           (format "mkdir -p %s" (shell-quote-argument directory))
           (format "%s bootstrap %s %s:%s -o %s -f"
                   (shell-quote-argument (init/scala-coursier-command))
                   (format "--java-opt -Xss4m --java-opt -Xms100m --java-opt -Xmx%s"
                           init/scala-metals-heap)
                   init/scala-metals-artifact
                   version
                   (shell-quote-argument (init/scala-metals-command)))))))

(defun init/scala--tools-step ()
  "Return the install step fetching the Scala command-line tools, or nil."
  (when init/scala-tools
    (cons (format "Scala tools (%s)" (string-join init/scala-tools ", "))
          (format "%s install --install-dir %s %s"
                  (shell-quote-argument (init/scala-coursier-command))
                  (shell-quote-argument (init/scala-tools-directory))
                  (mapconcat #'shell-quote-argument init/scala-tools " ")))))

(defun init/scala--install-run (steps)
  "Run STEPS in order, each only after the one before it succeeded.
Every step is a separate asynchronous process, so Emacs stays usable
through a download of several hundred megabytes."
  (if (null steps)
      (progn
        (init/scala--add-tools-to-path)
        (init/scala--install-log "\nDone.  Reopen your Scala buffer.\n"))
    (pcase-let ((`(,label . ,command) (car steps)))
      (init/scala--install-log "\n==> %s\n" label)
      (make-process
       :name "init/scala-install"
       :buffer (get-buffer-create init/scala--install-buffer-name)
       :command (list shell-file-name shell-command-switch command)
       :noquery t
       :sentinel
       (lambda (process event)
         (unless (process-live-p process)
           (if (zerop (process-exit-status process))
               (init/scala--install-run (cdr steps))
             (init/scala--install-log "\n%s failed: %s\n"
                                      label (string-trim event)))))))))

;;;###autoload
(defun init/scala-install-server (&optional tools-only)
  "Download and install Metals and the Scala command-line tools.
With TOOLS-ONLY, or a prefix argument, only the tools named in
`init/scala-tools' are installed.  Re-running replaces Metals and the
tools, so this is also how to update them; Coursier and the JDK are
fetched only when they are missing.  Progress is shown in
`init/scala--install-buffer-name'."
  (interactive "P")
  (unless (executable-find "curl")
    (user-error "curl is needed to download Metals"))
  (make-directory init/scala-server-directory t)
  (setq init/scala--install-declined nil
        init/scala--coursier-java-home 'unknown)
  (init/scala--install-log "Installing into %s\n" init/scala-server-directory)
  (display-buffer init/scala--install-buffer-name)
  (init/scala--install-run
   (delq nil (list (unless (file-executable-p (init/scala-coursier-command))
                     (init/scala--coursier-step))
                   (unless tools-only (init/scala--jdk-step))
                   (unless tools-only (init/scala--metals-step))
                   (init/scala--tools-step)))))

(defun init/scala--offer-install ()
  "Offer to install Metals when it is missing.
Return non-nil when the server is ready to be started."
  (cond
   ((init/scala-server-installed-p) t)
   (init/scala--install-declined nil)
   ((y-or-n-p "Metals, the Scala language server, is not installed.  \
Download it now? ")
    (init/scala-install-server)
    ;; The download is asynchronous, so this buffer gets no server; the
    ;; next one opened after it finishes does.
    nil)
   (t (setq init/scala--install-declined t) nil)))

;;;; Talking to Metals

(defcustom init/scala-connect-timeout 180
  "Seconds to wait for Metals to finish starting up.
A cold Metals imports the build and indexes its dependencies before it
answers, which on a large build takes far longer than Eglot's default of
30."
  :type 'number
  :group 'init/scala)

(defcustom init/scala-auto-import-build "all"
  "When Metals may import a build change without asking.
\"all\" imports every change, \"initial\" only the first import, \"off\"
always asks.  Asking arrives as a message request, which is answerable
but interrupts editing on every build file save."
  :type '(choice (const "all") (const "initial") (const "off"))
  :group 'init/scala)

(defcustom init/scala-inlay-hints t
  "Whether Metals annotates the buffer with inferred types and implicits.
Eglot renders these through `eglot-inlay-hints-mode'."
  :type 'boolean
  :group 'init/scala)

(defun init/scala--boolean (value)
  "Return VALUE as the JSON boolean Metals expects."
  (if value t :json-false))

(defun init/scala--workspace-configuration ()
  "Return the settings sent to Metals.
`javaHome' is the important one: it decides the JDK Bloop compiles the
project with, which without it would be whatever `java' leads to.

The names are the hyphenated ones Metals declares in its own
UserConfiguration, not the camelCase spellings its VS Code documentation
uses.  Metals will convert, but a name that is wrong in more than case
-- `auto-import-builds' is plural -- then silently does nothing."
  (let ((home (init/scala--java-home))
        (hints (init/scala--boolean init/scala-inlay-hints)))
    `(:metals
      (,@(when home (list :javaHome home))
       :auto-import-builds ,init/scala-auto-import-build
       ;; Eglot implements no semantic token support, so asking for it
       ;; only costs the server work whose answers are dropped.
       :enable-semantic-highlighting :json-false
       ;; Likewise code lenses: nothing renders them here, and the test
       ;; and run actions they carry are on the IDE keymap instead.
       :super-method-lenses-enabled :json-false
       :inlay-hints (:inferred-types (:enable ,hints)
                     :implicit-arguments (:enable ,hints)
                     :implicit-conversions (:enable ,hints)
                     :type-parameters (:enable ,hints)
                     :hints-in-pattern-match (:enable ,hints)
                     :by-name-parameters (:enable ,hints)
                     :named-parameters (:enable ,hints))))))

(defun init/scala--server-configuration (_server)
  "Return the settings Metals is sent, whichever buffer Eglot asks from."
  (init/scala--workspace-configuration))

(dolist (mode '(scala-mode scala-ts-mode))
  (setf (alist-get mode init/ide-workspace-configurations)
        #'init/scala--server-configuration))

(defun init/scala--metals-contact (_interactive &optional _project)
  "Return the command line starting Metals.
The launcher reads JAVA_HOME before PATH, which is how the server is
kept off a JDK its compilers cannot cope with."
  (let ((home (init/scala--java-home)))
    ;; A leading class name tells Eglot which server class to build, and
    ;; `init/scala-metals-server' is the one carrying the initialization
    ;; options and the Metals-specific notification handlers.
    (cons 'init/scala-metals-server
          (append (when home (list "env" (concat "JAVA_HOME=" home)))
                  (list (init/scala-metals-command))))))

;;;; Metals status, focus and client commands

(defvar init/scala--status nil
  "The last status line Metals reported, so a repeat is not re-announced.")

(defvar init/scala--focused-uri nil
  "The URI last announced to Metals as focused.")

(defconst init/scala--doctor-buffer-name "*Metals Doctor*"
  "Name of the buffer the Metals Doctor report is rendered into.")

(defun init/scala--render-html (html)
  "Render HTML into `init/scala--doctor-buffer-name' and show it.
Metals answers the Doctor and the stack trace analyser with a page
rather than with text, so it is rendered rather than dumped."
  (require 'shr)
  (let ((buffer (get-buffer-create init/scala--doctor-buffer-name)))
    (with-current-buffer buffer
      (let ((document (with-temp-buffer
                        (insert html)
                        (libxml-parse-html-region (point-min) (point-max))))
            (inhibit-read-only t))
        (special-mode)
        (erase-buffer)
        (if document
            (shr-insert-document document)
          (insert html))
        (goto-char (point-min))))
    (display-buffer buffer)))

(defun init/scala--goto-location (location)
  "Jump to LOCATION, an LSP Location Metals asked the editor to show."
  (when-let* ((uri (plist-get location :uri))
              (file (eglot-uri-to-path uri))
              (range (plist-get location :range))
              (start (plist-get range :start)))
    (find-file file)
    (goto-char (point-min))
    (forward-line (plist-get start :line))
    ;; A position past the end of its line is not worth an error in the
    ;; middle of a jump; the line is where the reader wanted to be.
    (forward-char (min (plist-get start :character)
                       (- (line-end-position) (point))))))

(defun init/scala--did-focus (&optional window)
  "Tell Metals the buffer of WINDOW is the one being looked at.
Metals compiles the build target of the focused file, so without this
notification a diagnostic in a file switched to stays stale until that
file is saved.  Eglot sends nothing of the sort itself, this being a
Metals extension rather than part of LSP.

Hung buffer-locally off the window hooks, which pass the window whose
buffer changed or whose selection did, so it costs nothing in any buffer
Metals is not managing."
  (with-current-buffer (if (window-live-p window)
                           (window-buffer window)
                         (current-buffer))
    (when-let* ((server (and buffer-file-name
                             (or (derived-mode-p 'scala-mode)
                                 (derived-mode-p 'scala-ts-mode))
                             (fboundp 'eglot-current-server)
                             (eglot-current-server)))
                (uri (eglot-path-to-uri buffer-file-name)))
      (unless (equal uri init/scala--focused-uri)
        (setq init/scala--focused-uri uri)
        (ignore-errors
          (jsonrpc-notify server :metals/didFocusTextDocument uri))))))

(defun init/scala--watch-focus ()
  "Have this buffer tell Metals when it is the one on screen."
  (add-hook 'window-buffer-change-functions #'init/scala--did-focus nil t)
  (add-hook 'window-selection-change-functions #'init/scala--did-focus nil t))

;;;; Eglot registration

;; Metals registers here rather than in init-ide.el because its command
;; line depends on which JDK the machine turned out to have, and because
;; the server class carrying its initialization options can only be
;; derived once Eglot has defined the class it derives from.
(with-eval-after-load 'eglot
  (defclass init/scala-metals-server (eglot-lsp-server) ()
    "The Eglot server class for Metals.
It exists to carry initialization options, which Metals reads to decide
which of its extensions the editor understands, and to hang the handlers
for those extensions off.")

  (cl-defmethod eglot-initialization-options ((_server init/scala-metals-server))
    "Return the options Metals is initialized with.
Each of these is a claim about what this editor can do, so a provider is
enabled only where something below actually handles it.  The ones left
off matter as much as the ones on: an editor that claims a quick pick or
an input box Metals then blocks on would hang the build import."
    (list :statusBarProvider "on"
          :executeClientCommandProvider t
          :didFocusProvider t
          :doctorProvider "html"
          ;; Metals serves the Doctor over its own HTTP server when one
          ;; is asked for, and only sends the report to the editor when
          ;; there is none.  Rendering it here is the point.
          :isHttpEnabled :json-false
          :icons "unicode"
          :quickPickProvider :json-false
          :inputBoxProvider :json-false
          :debuggingProvider t
          :decorationProvider :json-false
          :inlineDecorationProvider :json-false
          :slowTaskProvider :json-false
          :openFilesOnRenameProvider :json-false
          ;; Eglot indents a snippet itself; letting the compiler do it
          ;; too leaves a completion doubly indented.
          :compilerOptions (list :snippetAutoIndent :json-false)))

  (cl-defmethod eglot-handle-notification
    ((_server init/scala-metals-server) (_method (eql metals/status))
     &key text hide &allow-other-keys)
    "Report what Metals is doing in the echo area.
This is the only progress Metals gives for importing and indexing, which
is where all the waiting is, so it is worth showing.  Repeats are
dropped: the server resends the same line as it ticks."
    (let ((line (and (stringp text) (string-trim text))))
      (cond
       ((or (eq hide t) (null line) (string-empty-p line))
        (setq init/scala--status nil))
       ((equal line init/scala--status))
       (t (setq init/scala--status line)
          (message "%s" line)))))

  (cl-defmethod eglot-handle-notification
    ((_server init/scala-metals-server) (_method (eql metals/executeClientCommand))
     &key command arguments &allow-other-keys)
    "Carry out the client COMMAND Metals asked for, with ARGUMENTS.
Anything unrecognised is dropped rather than warned about: Metals sends
these for features this editor never claimed."
    (let ((argument (and (> (length arguments) 0) (aref arguments 0))))
      (pcase command
        ("metals-goto-location"
         (when argument (init/scala--goto-location argument)))
        ((or "metals-doctor-run" "metals-doctor-reload" "metals-show-stacktrace")
         (when (stringp argument) (init/scala--render-html argument)))
        (_ nil))))

  (add-to-list 'eglot-server-programs
               (cons '(scala-mode scala-ts-mode) #'init/scala--metals-contact)))

;;;; Metals commands

(defun init/scala--execute (command &rest arguments)
  "Ask Metals to run its COMMAND with ARGUMENTS, and return the answer."
  (let ((server (or (and (fboundp 'eglot-current-server) (eglot-current-server))
                    (user-error "No Metals server is running in this buffer"))))
    (eglot-execute server (list :command command
                                :arguments (vconcat arguments)))))

(defun init/scala-import-build ()
  "Re-read the build definition and hand Metals the new classpath.
The one to run after editing build.sbt, adding a dependency, or when a
symbol from another module stops resolving."
  (interactive)
  (init/scala--execute "build-import")
  (message "Importing the build..."))

(defun init/scala-restart-build ()
  "Restart the build server Metals compiles through.
The one to run when compilation has wedged rather than merely failed."
  (interactive)
  (init/scala--execute "build-restart")
  (message "Restarting the build server..."))

(defun init/scala-clean-compile ()
  "Recompile the whole build from scratch."
  (interactive)
  (init/scala--execute "compile-clean")
  (message "Recompiling from scratch..."))

(defun init/scala-cascade-compile ()
  "Compile this file and everything that depends on it.
Shows the errors a change causes elsewhere without building the world."
  (interactive)
  (init/scala--execute "compile-cascade"))

(defun init/scala-doctor ()
  "Show the Metals Doctor: what the build is, and what is not working.
The first thing to read when definitions do not resolve."
  (interactive)
  (init/scala--execute "doctor-run"))

(defun init/scala-goto-super-method ()
  "Jump to the definition this method overrides."
  (interactive)
  (init/scala--execute
   "goto-super-method"
   (list :document (eglot-path-to-uri buffer-file-name)
         :position (list :line (1- (line-number-at-pos nil t))
                         :character (- (point) (line-beginning-position))))))

(defun init/scala-organize-imports ()
  "Sort the import list and drop the unused ones."
  (interactive)
  (call-interactively #'eglot-code-action-organize-imports))

;;;; Reading the buffer

(defun init/scala--package-name ()
  "Return the package this file declares, or nil.
Scala allows the declaration to be split across several clauses, which
nest, so they are joined in the order they appear.  The line anchor is
what keeps `package object foo {' and the braced form out of it."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (let (parts)
        (while (re-search-forward
                "^[[:space:]]*package[[:space:]]+\\([[:alnum:]_.]+\\)[[:space:]]*$"
                8192 t)
          (push (match-string-no-properties 1) parts))
        (when parts (string-join (nreverse parts) "."))))))

(defconst init/scala--type-node-types
  '("class_definition" "object_definition" "trait_definition"
    "enum_definition")
  "Tree-sitter node types declaring a type in Scala.")

(defconst init/scala--type-regexp
  (concat "^[[:space:]]*"
          "\\(?:\\(?:final\\|sealed\\|abstract\\|case"
          "\\|implicit\\|private\\|protected\\)[[:space:]]+\\)*"
          "\\(?:class\\|object\\|trait\\|enum\\)"
          "[[:space:]]+\\([[:alnum:]_]+\\)")
  "Regexp matching a Scala type declaration, for buffers with no parser.")

(defun init/scala--enclosing-types ()
  "Return the names of the types around point, outermost first."
  (when (and (fboundp 'treesit-parser-list) (treesit-parser-list))
    (let ((node (treesit-node-at (point)))
          names)
      (while node
        (when (member (treesit-node-type node) init/scala--type-node-types)
          (when-let* ((name (treesit-node-child-by-field-name node "name")))
            (push (treesit-node-text name t) names)))
        (setq node (treesit-node-parent node)))
      (delq nil names))))

(defun init/scala--class-name ()
  "Return the type around point, nested types joined by `$'.
That is the spelling a test filter matches on.  Falls back to the
nearest declaration above point, and then to the file's own name."
  (or (when-let* ((names (init/scala--enclosing-types)))
        (string-join names "$"))
      (save-excursion
        (when (re-search-backward init/scala--type-regexp nil t)
          (match-string-no-properties 1)))
      (and buffer-file-name (file-name-base buffer-file-name))))

(defun init/scala--qualified-class ()
  "Return the fully qualified name of the type around point."
  (unless buffer-file-name
    (user-error "This buffer is not visiting a file"))
  (let ((class (init/scala--class-name))
        (package (init/scala--package-name)))
    (if package (concat package "." class) class)))

(defconst init/scala--test-name-regexp
  (concat
   ;; test("name"), it("name"), property("name"), describe("name")
   "\\_<\\(?:test\\|it\\|they\\|property\\|check\\|describe\\|scenario\\)"
   "[[:space:]]*([[:space:]]*\"\\([^\"]+\\)\""
   ;; it should "name" in { ... }
   "\\|\\_<\\(?:it\\|they\\)[[:space:]]+\\(?:should\\|must\\|can\\)"
   "[[:space:]]+\"\\([^\"]+\\)\""
   ;; "name" in { ... }, "name" should { ... }, "name" - { ... }
   "\\|\"\\([^\"]+\\)\"[[:space:]]*\\(?:in\\|should\\|must\\|can\\|-\\)"
   "[[:space:]]*[({]")
  "Regexp matching how the Scala test frameworks name a test.
Whichever group matched carries the name; the frameworks differ only in
where they put the string.")

(defun init/scala--test-name ()
  "Return the name of the test around point, or nil.
Scala tests are values registered by a call rather than named
declarations, so this is a search backwards for the nearest
registration, not a walk up the syntax tree."
  (save-excursion
    (when (re-search-backward init/scala--test-name-regexp nil t)
      (or (match-string-no-properties 1)
          (match-string-no-properties 2)
          (match-string-no-properties 3)))))

(defun init/scala--test-framework ()
  "Return the test framework this file is written against, as a symbol.
Read from the imports, and ScalaTest when nothing says otherwise, since
the frameworks disagree about how a single test is selected."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (cond
       ((re-search-forward "\\_<munit\\_>\\|\\_<MUnit\\_>" 8192 t) 'munit)
       ((re-search-forward "\\_<utest\\_>" 8192 t) 'utest)
       ((re-search-forward "\\_<specs2\\_>" 8192 t) 'specs2)
       (t 'scalatest)))))

(defun init/scala--test-selector (name)
  "Return the runner arguments selecting the test called NAME.
They follow the `--' that separates the build tool's own arguments from
the ones handed to the test framework, and are returned unquoted: every
build tool but sbt receives them as separate arguments already."
  (pcase (init/scala--test-framework)
    ('munit (list "--" (format "*%s*" name)))
    ('specs2 (list "--" "ex" name))
    ('utest (list "--" name))
    (_ (list "--" "-z" name))))

;;;; Build tool commands

(defcustom init/scala-sbt-client t
  "Whether sbt commands run through the sbt server rather than a new JVM.
`sbt --client' attaches to the server Metals already keeps warm, turning
a twenty-second cold start into an immediate one.  It needs sbt 1.4 or
newer."
  :type 'boolean
  :group 'init/scala)

(defun init/scala--program (name)
  "Return this build's wrapper script for NAME, or NAME itself.
A wrapper pins the tool's version for the project, so it is preferred
over whatever is on PATH.  It is looked for above the build root too,
since a component of a larger repository shares the one at the top."
  (or (when-let* ((dir (locate-dominating-file (init/scala-project-root) name)))
        (let ((file (expand-file-name name dir)))
          (and (file-executable-p file) file)))
      name))

(defun init/scala--sbt-projects ()
  "Return the sbt subprojects declared in build.sbt, as an alist.
Each entry maps a directory, relative to the build root, to the project
name a task has to be scoped with.  A project declares its directory
with `in file(\"...\")' and otherwise takes the name's own."
  (let ((file (expand-file-name "build.sbt" (init/scala-project-root)))
        projects)
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (re-search-forward
                (concat "^[[:space:]]*lazy[[:space:]]+val[[:space:]]+"
                        "\\([[:alnum:]_]+\\)[[:space:]]*=")
                nil t)
          (let* ((name (match-string-no-properties 1))
                 (start (point))
                 ;; A declaration runs until the next one; the settings
                 ;; chained onto it are frequently spread over many lines
                 ;; with `in file(...)' well below the name.
                 (end (save-excursion
                        (if (re-search-forward
                             "^[[:space:]]*lazy[[:space:]]+val\\_>" nil t)
                            (match-beginning 0)
                          (point-max))))
                 (body (buffer-substring-no-properties
                        start (min end (+ start 400)))))
            (when (string-match-p "\\_<project\\_>" body)
              (push (cons (if (string-match "file(\"\\([^\"]*\\)\")" body)
                              (match-string 1 body)
                            name)
                          name)
                    projects))))))
    projects))

(defun init/scala--sbt-project ()
  "Return the sbt project owning this buffer, or nil for the root one.
The innermost declared directory containing the file wins, so a file in
modules/core/src is scoped to the project rooted at modules/core rather
than to one rooted at modules."
  (when-let* ((file buffer-file-name)
              (relative-path (file-relative-name file (init/scala-project-root))))
    (unless (string-prefix-p ".." relative-path)
      (let ((owner nil)
            (depth -1))
        (dolist (entry (init/scala--sbt-projects) owner)
          (let ((directory (car entry)))
            (when (and (not (equal directory "."))
                       (string-prefix-p (file-name-as-directory directory)
                                        relative-path)
                       (> (length directory) depth))
              (setq owner (cdr entry)
                    depth (length directory)))))))))

(defun init/scala--sbt-word (word)
  "Return WORD as sbt's command parser will read it as a single word.
An sbt invocation carries its whole command as one shell argument, which
sbt then splits on whitespace of its own -- so a test name with a space
in it has to be quoted a second time, inside that argument."
  (if (string-match-p "[[:space:]]" word)
      (format "\"%s\"" word)
    word))

(defun init/scala--sbt-scope (task)
  "Return TASK scoped to the sbt project owning this buffer."
  (if-let* ((project (init/scala--sbt-project)))
      (concat project "/" task)
    task))

(defun init/scala--mill-module ()
  "Return the mill module owning this buffer, or nil.
Mill names a module after its directory, so the first path segment below
the build root is the module a task addresses."
  (when-let* ((file buffer-file-name)
              (relative (file-relative-name file (init/scala-project-root)))
              (segments (split-string relative "/" t)))
    (unless (or (string-prefix-p ".." relative) (< (length segments) 2))
      (car segments))))

(defun init/scala--mill-target (task)
  "Return mill TASK scoped to the module owning this buffer."
  (if-let* ((module (init/scala--mill-module)))
      (concat module "." task)
    (concat "__." task)))

(defun init/scala--command (action &optional class name)
  "Return the shell words running ACTION under this build's tool.
ACTION is one of `run', `build', `test-all', `test-class' or `repl'.
CLASS is the fully qualified test class an action needs, and NAME the
single test within it."
  (let* ((tool (init/scala--build-tool))
         (selector (and name (init/scala--test-selector name))))
    (pcase tool
      ('sbt
       (let ((sbt (append (list "sbt")
                          ;; The thin client talks to the sbt server
                          ;; Metals already keeps warm, which is what
                          ;; makes a task start at once.  A REPL is the
                          ;; exception: it wants a terminal of its own,
                          ;; which the client does not give it.
                          (when (and init/scala-sbt-client
                                     (not (eq action 'repl)))
                            (list "--client")))))
         (append sbt
                 (list (pcase action
                         ('run (init/scala--sbt-scope "run"))
                         ('build (init/scala--sbt-scope "Test/compile"))
                         ('test-all "test")
                         ('repl (init/scala--sbt-scope "console"))
                         ('test-class
                          (string-join
                           (mapcar #'init/scala--sbt-word
                                   (append (list (init/scala--sbt-scope "testOnly")
                                                 class)
                                           selector))
                           " ")))))))
      ('mill
       (let ((mill (init/scala--program "mill")))
         (pcase action
           ('run (list mill (init/scala--mill-target "run")))
           ('build (list mill (init/scala--mill-target "compile")))
           ('test-all (list mill "__.test"))
           ('repl (list mill "-i" (init/scala--mill-target "console")))
           ('test-class
            (append (list mill (init/scala--mill-target "test.testOnly") class)
                    selector)))))
      ('gradle
       (let ((gradle (init/scala--program "gradlew")))
         (pcase action
           ('run (list gradle "--console=plain" "run"))
           ('build (list gradle "--console=plain" "build" "-x" "test"))
           ('test-all (list gradle "--console=plain" "test"))
           ('repl (list "scala-cli" "repl" "."))
           ('test-class
            (list gradle "--console=plain" "test" "--tests"
                  (if name (concat class "." name) class))))))
      ('maven
       (pcase action
         ('run (list "mvn" "-q" "compile" "exec:java"))
         ('build (list "mvn" "-q" "compile"))
         ('test-all (list "mvn" "test"))
         ('repl (list "scala-cli" "repl" "."))
         ('test-class (list "mvn" "test" (concat "-Dtest=" class)))))
      (_
       (pcase action
         ('run (list "scala-cli" "run" "."))
         ('build (list "scala-cli" "compile" "."))
         ('test-all (list "scala-cli" "test" "."))
         ('repl (list "scala-cli" "repl" "."))
         ('test-class
          (append (list "scala-cli" "test" "." "--test-only" class)
                  selector)))))))

(defun init/scala--build-environment ()
  "Return `process-environment' with the JDK Metals uses put in front.
A build started from here then runs on the same JDK the language server
does, so a project cannot compile in one and fail in the other.  It
matters most where `java' on PATH is a headless JRE, which has no
compiler in it at all."
  (if-let* ((home (init/scala--java-home)))
      (append (list (concat "JAVA_HOME=" home)
                    (concat "PATH=" (expand-file-name "bin" home)
                            path-separator (getenv "PATH")))
              process-environment)
    process-environment))

(defun init/scala--compile (words)
  "Save the buffer and run WORDS from the build root."
  (unless words
    (user-error "This build tool has no such action"))
  (save-buffer)
  (let ((default-directory (init/scala-project-root))
        (process-environment (init/scala--build-environment)))
    (compile (mapconcat #'shell-quote-argument (delq nil words) " "))))

(defun init/scala-run ()
  "Run the module owning this buffer."
  (interactive)
  (init/scala--compile (init/scala--command 'run)))

(defun init/scala-build ()
  "Compile the build, main sources and tests alike."
  (interactive)
  (init/scala--compile (init/scala--command 'build)))

(defun init/scala-test-project ()
  "Run every test in this build."
  (interactive)
  (init/scala--compile (init/scala--command 'test-all)))

(defun init/scala-test-file ()
  "Run the tests in the class this file declares."
  (interactive)
  (init/scala--compile
   (init/scala--command 'test-class (init/scala--qualified-class))))

(defun init/scala-test-at-point ()
  "Run the single test around point, or the whole class when unsure."
  (interactive)
  (init/scala--compile
   (init/scala--command 'test-class
                        (init/scala--qualified-class)
                        (init/scala--test-name))))

(defun init/scala-build-task (task)
  "Run an arbitrary build tool TASK from this build's root.
Prefilled with this buffer's project scope, so completing it with a task
name runs that task for that project alone."
  (interactive
   (list (read-string
          "Task: "
          (pcase (init/scala--build-tool)
            ('sbt (init/scala--sbt-scope ""))
            ('mill (init/scala--mill-target ""))
            (_ "")))))
  (init/scala--compile
   (pcase (init/scala--build-tool)
     ('sbt (append (list "sbt")
                   (when init/scala-sbt-client (list "--client"))
                   (list task)))
     ('mill (list (init/scala--program "mill") task))
     ('gradle (list (init/scala--program "gradlew") "--console=plain" task))
     ('maven (list "mvn" task))
     (_ (list "scala-cli" task ".")))))

(defun init/scala-repl ()
  "Open a Scala REPL for this build, with its classpath on hand."
  (interactive)
  (let* ((default-directory (init/scala-project-root))
         (process-environment (init/scala--build-environment))
         (words (init/scala--command 'repl))
         (buffer (apply #'make-comint "scala" (car words) nil (cdr words))))
    (pop-to-buffer buffer)))

;;;; Starting a project

;; A machine with no Scala on it has no way to make the first project
;; either, and the tools that would scaffold one -- `sbt new', Giter8 --
;; want a network, a JVM start and a terminal of their own.  These
;; templates are written straight to disk instead: offline, immediate,
;; and shaped so that the build root, the test framework and the
;; formatter are the ones the rest of this module already understands.

(defcustom init/scala-version "3.3.8"
  "Scala release a new project is created with.
The 3.3 line is the long-term support one, which is what the compilers
Metals drives are best tested against."
  :type 'string
  :group 'init/scala)

(defcustom init/scala-sbt-version "1.13.0"
  "sbt release a new sbt project is created with.
Named in project/build.properties, which is what the sbt launcher reads
to decide which sbt to fetch, and what marks the build root."
  :type 'string
  :group 'init/scala)

(defcustom init/scala-munit-version "1.3.5"
  "MUnit release a new project's tests are written against.
MUnit rather than ScalaTest because its whole API is one class, and
because `init/scala--test-selector' can filter a single test in it."
  :type 'string
  :group 'init/scala)

(defcustom init/scala-scalafmt-version "3.11.5"
  "Scalafmt release a new project's .scalafmt.conf pins.
The file has to exist for Metals to format at all, and its presence is
what turns format-on-save on -- see `init/scala--formatter-configured-p'."
  :type 'string
  :group 'init/scala)

(defun init/scala--scalafmt-config ()
  "Return a .scalafmt.conf indenting by `init/scala-indent-offset'.
Scalafmt steps a wrapped parameter list, a constructor and an `extends'
clause by four columns whatever `indent.main' says.  That is the Scala 2
convention of setting a signature apart from the body it introduces --
but in Scala 3 the body is set apart by its indentation, so the only
result is a file that steps by four in one place and by two everywhere
else.  All three are named here; `indent.ctorSite' follows
`indent.defnSite' on its own."
  (format (concat "version = \"%s\"\n"
                  "runner.dialect = scala3\n"
                  "maxColumn = 100\n"
                  "indent.main = %d\n"
                  "indent.defnSite = %d\n"
                  "indent.extendSite = %d\n")
          init/scala-scalafmt-version
          init/scala-indent-offset
          init/scala-indent-offset
          init/scala-indent-offset))

;;;###autoload
(defun init/scala-write-scalafmt-config ()
  "Write this build a .scalafmt.conf that indents the way the editor does.
How a project is formatted is the project's business and not the
editor's -- Metals, the build and CI all read this one file -- so the fix
for a project that indents a signature by four is to change the file.
An existing one is replaced only after confirmation."
  (interactive)
  (let ((file (expand-file-name ".scalafmt.conf" (init/scala-project-root))))
    (when (or (not (file-exists-p file))
              (yes-or-no-p (format "Replace %s? " (abbreviate-file-name file))))
      (with-temp-file file (insert (init/scala--scalafmt-config)))
      (find-file file)
      (message "Indenting by %d; %s reformats the buffer with it."
               init/scala-indent-offset
               (key-description (kbd bind/ide-format))))))

(defun init/scala--package-path (package)
  "Return the source directory PACKAGE's files belong in."
  (replace-regexp-in-string "\\." "/" package))

(defun init/scala--suggest-package (name)
  "Return a package name derived from the project called NAME.
Scala package segments are identifiers, so anything that cannot appear
in one is dropped and a leading digit is prefixed away."
  (let ((clean (replace-regexp-in-string "[^[:alnum:]]" "" (downcase name))))
    (cond ((string-empty-p clean) "example")
          ((string-match-p "\\`[[:digit:]]" clean) (concat "app" clean))
          (t clean))))

(defun init/scala--main-source (package)
  "Return the contents of a new project's main source file in PACKAGE."
  (format "package %s

@main def run(): Unit =
  println(greeting(\"world\"))

def greeting(who: String): String =
  s\"Hello, $who!\"
" package))

(defun init/scala--test-source (package)
  "Return the contents of a new project's test source file in PACKAGE."
  (format "package %s

class MainSuite extends munit.FunSuite:

  test(\"greeting names the caller\") {
    assertEquals(greeting(\"world\"), \"Hello, world!\")
  }

  test(\"greeting is never empty\") {
    assert(greeting(\"x\").nonEmpty)
  }
" package))

(defun init/scala--template-files (template name package)
  "Return the files of a new TEMPLATE project called NAME, as an alist.
Each entry maps a path relative to the project root to its contents.
PACKAGE is the package the sources declare."
  (let ((path (init/scala--package-path package)))
    (append
     `((".gitignore" . ,(concat "target/\n.bloop/\n.bsp/\n.metals/\n"
                                ".scala-build/\n*.class\n"))
       (".scalafmt.conf" . ,(init/scala--scalafmt-config)))
     (pcase template
       ('sbt
        `(("build.sbt"
           . ,(format (concat "ThisBuild / scalaVersion := \"%s\"\n"
                              "\n"
                              "lazy val root = (project in file(\".\"))\n"
                              "  .settings(\n"
                              "    name := \"%s\",\n"
                              "    libraryDependencies +=\n"
                              "      \"org.scalameta\" %%%% \"munit\""
                              " %% \"%s\" %% Test\n"
                              "  )\n")
                      init/scala-version name init/scala-munit-version))
          ("project/build.properties"
           . ,(format "sbt.version=%s\n" init/scala-sbt-version))
          (,(format "src/main/scala/%s/Main.scala" path)
           . ,(init/scala--main-source package))
          (,(format "src/test/scala/%s/MainSuite.scala" path)
           . ,(init/scala--test-source package))))
       (_
        ;; scala-cli reads its build from directives, and calls a file a
        ;; test source by its name rather than by where it sits.
        `(("project.scala"
           . ,(format "//> using scala %s\n//> using test.dep org.scalameta::munit::%s\n"
                      init/scala-version init/scala-munit-version))
          (,(format "src/%s/Main.scala" path)
           . ,(init/scala--main-source package))
          (,(format "src/%s/MainSuite.test.scala" path)
           . ,(init/scala--test-source package))))))))

;;;###autoload
(defun init/scala-new-project (directory template package)
  "Create a Scala project in DIRECTORY and open its main source file.
TEMPLATE is `sbt', the build tool most Scala projects use, or
`scala-cli', which needs no build definition beyond a few directives at
the top of a file.  PACKAGE is the package the sources declare.

Everything the project needs is written here; nothing is downloaded
until the project is first built."
  (interactive
   (let* ((directory (read-directory-name "New Scala project (directory): "))
          (name (file-name-nondirectory (directory-file-name directory)))
          (template (intern (completing-read "Build with: " '("sbt" "scala-cli")
                                             nil t nil nil "sbt"))))
     (list directory template
           (read-string "Package: " (init/scala--suggest-package name)))))
  (let* ((root (file-name-as-directory (expand-file-name directory)))
         (name (file-name-nondirectory (directory-file-name root))))
    (when (and (file-directory-p root)
               (directory-files root nil directory-files-no-dot-files-regexp t))
      (user-error "%s already has something in it" root))
    (pcase-dolist (`(,relative . ,contents)
                   (init/scala--template-files template name package))
      (let ((file (expand-file-name relative root)))
        (make-directory (file-name-directory file) t)
        (with-temp-file file (insert contents))))
    ;; The tools the new project is about to be built with are the ones
    ;; installed here, which nothing has put on PATH yet in a session
    ;; that has opened no Scala file.
    (init/scala--add-tools-to-path)
    (find-file (expand-file-name
                (format (if (eq template 'sbt)
                            "src/main/scala/%s/Main.scala"
                          "src/%s/Main.scala")
                        (init/scala--package-path package))
                root))
    (message "%s project in %s.  %s runs it, %s runs its tests."
             template root
             (key-description (kbd bind/ide-run))
             (key-description (kbd bind/ide-test-project)))))

;;;; Debugging

(defun init/scala--debug-session (parameters)
  "Start a Metals debug adapter with PARAMETERS and attach dape to it.
Metals runs the debuggee itself and answers with the address its adapter
is listening on, so dape connects rather than launching anything."
  (let* ((session (init/scala--execute "debug-adapter-start" parameters))
         (uri (plist-get session :uri)))
    (unless (and (stringp uri)
                 (string-match "\\`[a-z]+://\\([^:/]+\\):\\([0-9]+\\)" uri))
      (user-error "Metals started no debug adapter"))
    (dape (list 'modes nil
                'host (match-string 1 uri)
                'port (string-to-number (match-string 2 uri))
                :request "launch"))))

(defun init/scala-debug-test ()
  "Debug the test class around point."
  (interactive)
  (init/scala--debug-session
   (list :testClass (init/scala--qualified-class))))

(defun init/scala-debug-main (class)
  "Debug the main CLASS around point."
  (interactive (list (read-string "Main class: " (init/scala--qualified-class))))
  (init/scala--debug-session (list :mainClass class :arguments [])))

(defun init/scala--test-source-p ()
  "Return non-nil when this buffer belongs to the build's test sources.
sbt and Gradle put them under src/test and mill under test/src, while
scala-cli goes by the file name alone; the naming convention catches a
test kept somewhere else again."
  (and buffer-file-name
       (string-match-p (concat "/src/test/\\|/test/src/\\|\\.test\\.scala\\'"
                               "\\|\\(?:Spec\\|Suite\\|Test\\)\\.scala\\'")
                       buffer-file-name)))

(defun init/scala-debug ()
  "Debug the class around point, as a test where this file is one."
  (interactive)
  (if (init/scala--test-source-p)
      (init/scala-debug-test)
    (call-interactively #'init/scala-debug-main)))

;;;; Compilation output

;; sbt prefixes every compiler line with its own log level, which is
;; enough to stop the built-in rules recognising a location, so the file
;; a Scala error is in never became clickable.  Scala 3 reports in a
;; banner form no rule knows at all.

(defconst init/scala--source-file-regexp
  "\\([^][ \n:]+\\.\\(?:scala\\|sc\\|sbt\\|java\\)\\)"
  "Regexp group matching the path of a file a compiler reports on.")

(defconst init/scala--compilation-rules
  `((scala-sbt
     ,(concat "^\\[\\(?:error\\|warn\\)\\][[:space:]]+"
              init/scala--source-file-regexp
              ":\\([0-9]+\\)\\(?::\\([0-9]+\\)\\)?")
     1 2 3)
    (scala3
     ,(concat "^\\(?:\\[[a-z]+\\][[:space:]]+\\)?"
              "-- \\(?:\\[E[0-9]+\\] \\)?[^:\n]*: "
              init/scala--source-file-regexp
              ":\\([0-9]+\\):\\([0-9]+\\)")
     1 2 3)
    (scalac
     ,(concat "^" init/scala--source-file-regexp
              ":\\([0-9]+\\):\\(?:\\([0-9]+\\):\\)?"
              "[[:space:]]*\\(?:error\\|warning\\)")
     1 2 3))
  "Rules teaching `compile' where a Scala error happened.
Each is a `compilation-error-regexp-alist-alist' entry.")

(with-eval-after-load 'compile
  (dolist (rule init/scala--compilation-rules)
    (add-to-list 'compilation-error-regexp-alist-alist rule)
    (add-to-list 'compilation-error-regexp-alist (car rule))))

;;;; Buffer setup

(defun init/scala--formatter-configured-p ()
  "Return non-nil when this build configures scalafmt.
Metals formats through scalafmt and offers to write a configuration when
there is none, which is not a prompt to raise on every save."
  (and buffer-file-name
       (locate-dominating-file (init/scala--source-directory) ".scalafmt.conf")))

(defun init/scala-setup ()
  "Set up Scala editing, Metals and the build actions in this buffer."
  (init/scala-editing-setup)
  ;; `eglot-connect-timeout' is read buffer-locally when Eglot connects
  ;; this buffer, so a slow cold start here is not made everyone's
  ;; problem.
  (setq-local eglot-connect-timeout init/scala-connect-timeout
              init/ide-run-function #'init/scala-run
              init/ide-test-at-point-function #'init/scala-test-at-point
              init/ide-test-file-function #'init/scala-test-file
              init/ide-test-project-function #'init/scala-test-project
              init/ide-repl-function #'init/scala-repl
              init/ide-debug-function #'init/scala-debug
              ;; Sync means "make the language server agree with the
              ;; build again", which for Metals is a build import.
              init/ide-sync-function #'init/scala-import-build)
  ;; Buffer-local, so only Scala buffers resolve their project as a build.
  (add-hook 'project-find-functions #'init/scala--project-try nil t)
  (init/scala--watch-focus)
  (init/scala--add-tools-to-path)
  ;; Metals resolves a file through the build target owning it, so it has
  ;; nothing to say about a buffer that is not on disk -- and starting it
  ;; there would only ask which project the buffer belongs to.
  (when (and buffer-file-name (init/scala--offer-install))
    (eglot-ensure)
    (init/ide-prefer-flycheck)
    (when (init/scala--formatter-configured-p)
      (init/ide-format-with-eglot-on-save)))
  (init/ide-mode 1))

(defun init/scala-show-keybindings ()
  "Show the cheatsheet covering the Scala commands."
  (interactive)
  (cheatsheet-show "Scala"))

;;;; Major modes

;; scala-mode is the fallback; `treesit-auto' remaps it to scala-ts-mode
;; wherever the Scala grammar is installed, and offers to install it
;; where it is not.  Both hooks run the same setup.  The worksheet
;; extensions are listed here because treesit-auto knows only .scala and
;; .sbt, while Metals serves .sc and build.mill as Scala too.
(use-package scala-mode
  :mode ("\\.scala\\'" "\\.sbt\\'" "\\.sc\\'" "\\.mill\\'")
  :hook (scala-mode . init/scala-setup))

(use-package scala-ts-mode
  :defer t
  :hook (scala-ts-mode . init/scala-setup))

;;;; Keybindings

(defun init/scala--bind (map)
  "Bind the Scala commands with no generic equivalent in MAP.
The editing keys are spelled out rather than named in init-keys.el for
the same reason Nim's are: they replace what RET, DEL and TAB already
mean, rather than adding a command of their own to find."
  (define-key map (kbd "RET") #'init/scala-newline)
  ;; The escape hatch: reindent this line the way the mode would.
  (define-key map (kbd "C-j") #'newline-and-indent)
  (define-key map (kbd "DEL") #'init/scala-backspace)
  (define-key map (kbd "C-<return>") #'init/scala-open-line-below)
  (define-key map (kbd "C-S-<return>") #'init/scala-open-line-above)
  (define-key map (kbd "<backtab>") #'init/scala-shift-left)
  (define-key map (kbd "C-c <") #'init/scala-shift-left)
  (define-key map (kbd "C-c >") #'init/scala-shift-right)
  (define-key map (kbd bind/jvm-build-task) #'init/scala-build-task)
  (define-key map (kbd bind/jvm-help) #'init/scala-show-keybindings)
  (define-key map (kbd bind/scala-new-project) #'init/scala-new-project)
  (define-key map (kbd bind/scala-build) #'init/scala-build)
  (define-key map (kbd bind/scala-import-build) #'init/scala-import-build)
  (define-key map (kbd bind/scala-restart-build) #'init/scala-restart-build)
  (define-key map (kbd bind/scala-clean-compile) #'init/scala-clean-compile)
  (define-key map (kbd bind/scala-cascade-compile) #'init/scala-cascade-compile)
  (define-key map (kbd bind/scala-doctor) #'init/scala-doctor)
  (define-key map (kbd bind/scala-organize-imports) #'init/scala-organize-imports)
  (define-key map (kbd bind/scala-goto-super) #'init/scala-goto-super-method))

(with-eval-after-load 'scala-mode
  (init/scala--bind scala-mode-map))

(with-eval-after-load 'scala-ts-mode
  (init/scala--bind scala-ts-mode-map))

(with-eval-after-load 'which-key
  (which-key-add-key-based-replacements
    bind/scala-new-project "new scala project"
    bind/scala-build "compile the build"
    bind/scala-import-build "import build"
    bind/scala-restart-build "restart build server"
    bind/scala-clean-compile "clean compile"
    bind/scala-cascade-compile "cascade compile"
    bind/scala-doctor "metals doctor"
    bind/scala-organize-imports "organize imports"
    bind/scala-goto-super "go to super method"))

(provide 'init-lang-scala)
;;; init-lang-scala.el ends here
