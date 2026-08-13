;;; init-lang-jvm.el --- Kotlin and Java -*- lexical-binding: t; -*-

;;; Commentary:

;; Kotlin and Java, with their language servers treated as something to
;; install rather than something to assume:
;;
;;   Kotlin  JetBrains' kotlin-lsp, the IntelliJ analysis engine behind
;;           an LSP front end.  It carries its own JetBrains Runtime, so
;;           it needs no JDK on the machine.
;;   Java    Eclipse JDT LS, run on an installed JDK of at least
;;           `init/jvm-java-server-jdk' rather than on whatever `java'
;;           leads to, because its Gradle import breaks on a JDK newer
;;           than the Gradle it embeds.  It analyses Java files
;;           standalone unless `init/jvm-java-build-import' is set; see
;;           there for what that buys and what it costs.
;;
;; `init/jvm-install-servers' downloads both into
;; `init/jvm-server-directory', and opening a Kotlin or Java file while
;; they are missing offers to run it.  Nothing else here reaches the
;; network.
;;
;; The whole module hangs off the major-mode hooks.  These servers are
;; hundreds of megabytes and the JVMs behind them want gigabytes of heap,
;; so a session that opens no JVM file pays for none of it.
;;
;; Both servers are rooted at the *build* a file belongs to rather than
;; at the enclosing repository.  In a Gradle composite build -- an
;; umbrella whose components each carry their own settings file, the
;; shape of ~/Work/applications -- rooting at the repository would hand
;; the server every source file under it on every cold start.
;; `init/jvm-root-markers' names the files marking a build root, and a
;; *buffer-local* `project-find-functions' entry makes project.el, and
;; through it Eglot, agree.  Project resolution in every other buffer is
;; untouched, and so is the Projectile root that the run/build panel and
;; sessions are keyed on.
;;
;; Run, test and build go through the Gradle wrapper and address the
;; module owning the buffer, so <f6> in
;; arm/student-lookup/src/test/... runs that one test rather than the
;; build's whole suite.

;;; Code:

(require 'seq)
(require 'subr-x)
(require 'url)
(require 'which-func)
(require 'init-ide)
(require 'init-keys)
(require 'init-lib)

(declare-function cheatsheet-show "init-cheatsheet")
(declare-function eglot-current-server "eglot")
(declare-function eglot-ensure "eglot")
(declare-function jsonrpc-request "jsonrpc")

(defvar eglot-server-programs)
(defvar java-mode-map)
(defvar java-ts-mode-map)
(defvar kotlin-mode-map)
(defvar kotlin-ts-mode-map)

;;;; Where things live

(defgroup init/jvm nil
  "Kotlin and Java editing support."
  :group 'languages
  :prefix "init/jvm-")

(defcustom init/jvm-server-directory
  (expand-file-name "lsp-servers" user-emacs-directory)
  "Directory the Kotlin and Java language servers are installed into."
  :type 'directory
  :group 'init/jvm)

(defcustom init/jvm-cache-directory
  (expand-file-name "emacs/jvm-lsp"
                    (or (getenv "XDG_CACHE_HOME") "~/.cache"))
  "Directory holding each build's language server indexes and workspace.
This content is large and wholly derived from the sources, so it belongs
neither in the configuration nor in the projects themselves."
  :type 'directory
  :group 'init/jvm)

(defcustom init/jvm-kotlin-archive-url nil
  "Archive the Kotlin language server is installed from.
When nil the newest release is looked up at install time; set this to
pin a particular build."
  :type '(choice (const :tag "Newest release" nil) string)
  :group 'init/jvm)

(defcustom init/jvm-kotlin-release-url
  "https://api.github.com/repos/Kotlin/kotlin-lsp/releases/latest"
  "Release whose notes carry the Kotlin language server download links.
JetBrains publish the archives on their own CDN under a path naming the
build, so the URL has to be read from the release rather than built."
  :type 'string
  :group 'init/jvm)

(defcustom init/jvm-java-archive-url
  "https://download.eclipse.org/jdtls/snapshots/jdt-language-server-latest.tar.gz"
  "Archive the Java language server is installed from."
  :type 'string
  :group 'init/jvm)

(defun init/jvm-kotlin-server-command ()
  "Return the path of the Kotlin language server executable."
  (expand-file-name "kotlin-lsp/bin/intellij-server"
                    init/jvm-server-directory))

(defun init/jvm-java-server-command ()
  "Return the path of the Java language server launcher."
  (expand-file-name "jdtls/bin/jdtls" init/jvm-server-directory))

(defun init/jvm--server-command (kind)
  "Return the launcher path for the KIND language server.
KIND is either `kotlin' or `java'."
  (pcase kind
    ('kotlin (init/jvm-kotlin-server-command))
    ('java (init/jvm-java-server-command))))

(defun init/jvm-server-installed-p (kind)
  "Return non-nil when the KIND language server is installed."
  (let ((command (init/jvm--server-command kind)))
    (and command (file-executable-p command))))

;;;; Build roots

(defcustom init/jvm-root-markers
  '("settings.gradle.kts" "settings.gradle" "pom.xml")
  "Files marking the root of the build a JVM source file belongs to.
Only files that define a whole build belong here.  Every component of a
Gradle composite build carries its own settings file, so matching on
those roots the language server at the component rather than at the
umbrella above it."
  :type '(repeat string)
  :group 'init/jvm)

(defcustom init/jvm-module-markers
  '("build.gradle.kts" "build.gradle")
  "Files marking one module inside a build."
  :type '(repeat string)
  :group 'init/jvm)

(defun init/jvm--source-directory ()
  "Return the directory this buffer's build has to be resolved from.
File buffers get `default-directory' set to the Git repository root (see
init-editor.el), which in a monorepo sits far above the build, so the
walk upwards has to start at the file's own directory instead."
  (if buffer-file-name
      (file-name-directory buffer-file-name)
    default-directory))

(defun init/jvm--build-root (&optional dir)
  "Return the root of the JVM build containing DIR, or nil.
Falls back to a lone module when the build has no settings file, which is
how a single-project Gradle build looks."
  (let ((dir (or dir (init/jvm--source-directory))))
    (or (init/locate-dominating-match init/jvm-root-markers dir)
        (init/locate-dominating-match init/jvm-module-markers dir))))

(defun init/jvm-project-root (&optional dir)
  "Return the root of the JVM build containing DIR.
Falls back to the shared project root when DIR is in no build at all."
  (expand-file-name (or (init/jvm--build-root dir)
                        (init/project-root (or dir (init/jvm--source-directory))))))

(defun init/jvm--project-try (dir)
  "Return the JVM build containing DIR as a project.el project, or nil.
Added buffer-locally to `project-find-functions' in JVM buffers only, so
Eglot roots its server at the build while every other buffer keeps
resolving projects exactly as before.  A cons of `transient' and a
directory is project.el's own representation of a rootless project.

DIR arrives from `default-directory', which in a file buffer has been
moved to the Git root, so a visited file overrides it for the same
reason `init/jvm--source-directory' exists."
  (when-let ((root (init/jvm--build-root
                    (if buffer-file-name (init/jvm--source-directory) dir))))
    (cons 'transient (expand-file-name root))))

;;;; Installing the language servers

(defconst init/jvm--install-buffer-name "*JVM language servers*"
  "Name of the buffer showing language server install progress.")

(defvar init/jvm--install-declined nil
  "Server kinds whose install offer was declined.
Declining once is remembered, so opening further files of that language
does not ask again in this session.")

(defun init/jvm--install-log (format-string &rest arguments)
  "Insert FORMAT-STRING formatted with ARGUMENTS into the install buffer."
  (with-current-buffer (get-buffer-create init/jvm--install-buffer-name)
    (goto-char (point-max))
    (let ((inhibit-read-only t))
      (insert (apply #'format format-string arguments)))))

(defun init/jvm--kotlin-archive-url ()
  "Return the URL of the newest standalone Kotlin language server archive.
The release notes list one archive per platform, and the two Linux
archives differ only by an -aarch64 suffix, so the pattern pins the
architecture of this machine."
  (or init/jvm-kotlin-archive-url
      (let ((pattern
             (if (string-match-p "aarch64\\|arm" system-configuration)
                 "https://download-cdn\\.jetbrains\\.com/[^\")[:space:]]+-aarch64\\.tar\\.gz"
               "https://download-cdn\\.jetbrains\\.com/[^\")[:space:]]+[0-9]\\.tar\\.gz"))
            (buffer (url-retrieve-synchronously
                     init/jvm-kotlin-release-url t t 30)))
        (unless buffer
          (user-error "Could not reach %s" init/jvm-kotlin-release-url))
        (unwind-protect
            (with-current-buffer buffer
              (goto-char (point-min))
              (if (re-search-forward pattern nil t)
                  (match-string 0)
                (user-error
                 "The latest Kotlin LSP release lists no archive for %s"
                 system-configuration)))
          (kill-buffer buffer)))))

(defun init/jvm--install-command (url directory strip)
  "Return a shell command installing the archive at URL into DIRECTORY.
STRIP is the number of leading path components the archive carries.  The
archive unpacks beside DIRECTORY and is moved into place only once it is
complete, so an interrupted download never leaves a half-installed
server behind."
  (let ((staging (concat directory ".incoming"))
        (archive (concat directory ".tar.gz")))
    (mapconcat
     #'identity
     (list "set -e"
           (format "rm -rf %s %s"
                   (shell-quote-argument staging)
                   (shell-quote-argument archive))
           (format "mkdir -p %s" (shell-quote-argument staging))
           (format "curl -fL --progress-bar %s -o %s"
                   (shell-quote-argument url)
                   (shell-quote-argument archive))
           (format "tar -xzf %s -C %s --strip-components %d"
                   (shell-quote-argument archive)
                   (shell-quote-argument staging)
                   strip)
           (format "rm -f %s" (shell-quote-argument archive))
           (format "rm -rf %s" (shell-quote-argument directory))
           (format "mv %s %s"
                   (shell-quote-argument staging)
                   (shell-quote-argument directory)))
     "\n")))

(defconst init/jvm--server-labels
  '((kotlin . "Kotlin language server (JetBrains kotlin-lsp, ~400 MB)")
    (java . "Java language server (Eclipse JDT LS, ~50 MB)"))
  "How each language server is named when offering to download it.
The download is big enough that its size belongs in the offer.")

(defun init/jvm--server-label (kind)
  "Return the name the KIND language server is offered under."
  (alist-get kind init/jvm--server-labels))

(defun init/jvm--install-steps (kind)
  "Return the install steps for the KIND language server.
Each step is a cons of a label and a shell command."
  (pcase kind
    ('kotlin
     (list (cons (init/jvm--server-label 'kotlin)
                 (init/jvm--install-command
                  (init/jvm--kotlin-archive-url)
                  (expand-file-name "kotlin-lsp" init/jvm-server-directory)
                  1))))
    ('java
     (list (cons (init/jvm--server-label 'java)
                 (init/jvm--install-command
                  init/jvm-java-archive-url
                  (expand-file-name "jdtls" init/jvm-server-directory)
                  0))))))

(defun init/jvm--install-run (steps)
  "Run STEPS in order, each only after the one before it succeeded.
Every step is a separate asynchronous process, so Emacs stays usable
through a download of several hundred megabytes."
  (if (null steps)
      (init/jvm--install-log "\nDone.  Reopen your Kotlin or Java buffer.\n")
    (pcase-let ((`(,label . ,command) (car steps)))
      (init/jvm--install-log "\n==> %s\n" label)
      (make-process
       :name "init/jvm-install"
       :buffer (get-buffer-create init/jvm--install-buffer-name)
       :command (list shell-file-name shell-command-switch command)
       :noquery t
       :sentinel
       (lambda (process event)
         (unless (process-live-p process)
           (if (zerop (process-exit-status process))
               (init/jvm--install-run (cdr steps))
             (init/jvm--install-log "\n%s failed: %s\n"
                                    label (string-trim event)))))))))

;;;###autoload
(defun init/jvm-install-servers (&optional kind)
  "Download and install the Kotlin and Java language servers.
KIND limits the work to one of them; interactively it is prompted for.
Re-running replaces an existing install, so this is also how to update.
Progress is shown in `init/jvm--install-buffer-name'."
  (interactive
   (list (pcase (completing-read "Install language server: "
                                 '("both" "kotlin" "java") nil t nil nil "both")
           ("kotlin" 'kotlin)
           ("java" 'java)
           (_ nil))))
  (unless (executable-find "curl")
    (user-error "curl is needed to download the language servers"))
  (make-directory init/jvm-server-directory t)
  (setq init/jvm--install-declined nil)
  (init/jvm--install-log "Installing into %s\n" init/jvm-server-directory)
  (display-buffer init/jvm--install-buffer-name)
  (init/jvm--install-run
   (append (when (memq kind '(nil kotlin)) (init/jvm--install-steps 'kotlin))
           (when (memq kind '(nil java)) (init/jvm--install-steps 'java)))))

(defun init/jvm--offer-install (kind)
  "Offer to install the missing KIND language server.
Return non-nil when the server is ready to be started."
  (cond
   ((init/jvm-server-installed-p kind) t)
   ((memq kind init/jvm--install-declined) nil)
   ((y-or-n-p (format "Not installed: %s.  Download it now? "
                      (init/jvm--server-label kind)))
    (init/jvm-install-servers kind)
    ;; The download is asynchronous, so this buffer gets no server; the
    ;; next one opened after it finishes does.
    nil)
   (t (push kind init/jvm--install-declined) nil)))

;;;; Talking to the servers

(defcustom init/jvm-kotlin-heap "6g"
  "Maximum heap for the Kotlin language server.
Its bundled options ask for 2g, which a build of several thousand source
files exhausts while indexing."
  :type 'string
  :group 'init/jvm)

(defcustom init/jvm-java-heap "4g"
  "Maximum heap for the Java language server."
  :type 'string
  :group 'init/jvm)

(defcustom init/jvm-connect-timeout 180
  "Seconds to wait for a JVM language server to finish starting up.
A cold IntelliJ engine reads the whole build before it answers, which on
a large one takes far longer than Eglot's default of 30."
  :type 'number
  :group 'init/jvm)

(defcustom init/jvm-jdk-search-paths
  '("/usr/lib/jvm/*" "~/.sdkman/candidates/java/*" "~/.jdks/*")
  "Wildcard patterns searched for installed JDKs.
The Java server is told about every JDK found here, so a project can
target an older release than the one the server itself runs on."
  :type '(repeat string)
  :group 'init/jvm)

(defcustom init/jvm-java-server-jdk 21
  "Lowest Java release acceptable for running the Java language server.
The nearest installed release at or above this one is used, rather than
whatever `java' happens to be on PATH: JDT LS imports Gradle builds with
an embedded Gradle, and Gradle refuses to run on a JDK newer than it
knows about, failing the import with \"unsupported class file major
version\" and leaving the project with no classpath.  Nil accepts
whatever is on PATH."
  :type '(choice (const :tag "Whatever is on PATH" nil) integer)
  :group 'init/jvm)

(defun init/jvm--cache-directory (kind root)
  "Return the cache directory of KIND for the build at ROOT.
Each build gets its own, so servers running side by side never contend
for one index, and a single project's cache can be thrown away.  The
directory name keeps the build's own name for legibility and appends a
digest of its path to keep two same-named builds apart."
  (let* ((name (file-name-nondirectory (directory-file-name root)))
         (digest (substring (secure-hash 'sha1 (expand-file-name root)) 0 10)))
    (expand-file-name (format "%s/%s-%s" kind name digest)
                      init/jvm-cache-directory)))

(defun init/jvm--kotlin-contact (_interactive &optional _project)
  "Return the command line starting the Kotlin language server.
The heap is raised through IJ_JAVA_OPTIONS, which the JetBrains launcher
reads, rather than by editing the options file inside the install."
  (let ((root (init/jvm-project-root)))
    (list "env"
          (format "IJ_JAVA_OPTIONS=-Xmx%s" init/jvm-kotlin-heap)
          (init/jvm-kotlin-server-command)
          "--stdio"
          "--system-path" (init/jvm--cache-directory "kotlin" root))))

(defun init/jvm--java-contact (_interactive &optional _project)
  "Return the command line starting the Java language server.
JDT LS keeps mutable per-project state in its data directory and cannot
share one between projects, so each build is given its own.  Its
launcher picks the JVM from JAVA_HOME, which is how the server is kept
off a JDK its Gradle import cannot cope with."
  (let ((root (init/jvm-project-root))
        (home (init/jvm--java-server-home)))
    ;; A leading class name tells Eglot which server class to build, and
    ;; `init/jvm-jdtls-server' is the one carrying the initialization
    ;; options JDT LS needs.
    (cons 'init/jvm-jdtls-server
          (append (when home (list "env" (concat "JAVA_HOME=" home)))
                  (list (init/jvm-java-server-command)
                        "-data" (init/jvm--cache-directory "jdtls" root)
                        (format "--jvm-arg=-Xmx%s" init/jvm-java-heap))))))

(defun init/jvm--installed-jdks ()
  "Return the installed JDKs, as an alist of release number to directory.
Sorted by release, one directory per release, so `init/jvm-jdk-search-paths'
acts as a preference order.  Directories with no compiler, a bare JRE
among them, are not JDKs and are skipped."
  (let (jdks)
    (dolist (pattern init/jvm-jdk-search-paths)
      (dolist (directory (file-expand-wildcards (expand-file-name pattern) t))
        (when (file-exists-p (expand-file-name "bin/javac" directory))
          (let ((base (file-name-nondirectory (directory-file-name directory))))
            (when (string-match "\\([0-9]+\\)" base)
              (let ((release (string-to-number (match-string 1 base))))
                (unless (assq release jdks)
                  (push (cons release directory) jdks))))))))
    (sort jdks #'car-less-than-car)))

(defun init/jvm--java-runtimes ()
  "Return the installed JDKs in the form JDT LS expects.
Naming them all lets a project target an older release than the one the
server itself runs on."
  (vconcat (mapcar (lambda (jdk)
                     (list :name (format "JavaSE-%d" (car jdk))
                           :path (cdr jdk)))
                   (init/jvm--installed-jdks))))

(defun init/jvm--java-server-home ()
  "Return the JDK the Java server and its Gradle import should run under.
Gradle reads the class files of the JVM running it and rejects any
release newer than the one it was built against, so the newest JDK on
the machine fails an import that a supported LTS completes.  The lowest
installed release at or above `init/jvm-java-server-jdk' is chosen."
  (when init/jvm-java-server-jdk
    (cdr (seq-find (lambda (jdk) (>= (car jdk) init/jvm-java-server-jdk))
                   (init/jvm--installed-jdks)))))

(defun init/jvm--gradle-wrapper-version ()
  "Return the Gradle release this build's wrapper pins, or nil.
Found the same way as the wrapper script itself, so a component of a
composite build reports the umbrella's version rather than nothing."
  (when-let* ((relative "gradle/wrapper/gradle-wrapper.properties")
              (dir (locate-dominating-file (init/jvm-project-root) relative))
              (file (expand-file-name relative dir)))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (when (re-search-forward "gradle-\\([0-9][0-9.]*\\)-\\(?:bin\\|all\\)\\.zip"
                               nil t)
        (match-string 1)))))

(defcustom init/jvm-java-build-import nil
  "Whether the Java server may import a project's build system.
Importing gives a Java file the build's full classpath, so a symbol from
another module resolves.  It is off by default for two reasons: JDT LS
imports through Eclipse Buildship, which writes .project, .classpath and
.settings/ into the build it imports -- into the working tree, not into
its own workspace -- and the first import of a large composite build
takes many minutes.

With it off, Java files are handled as standalone sources: the file
itself analyses, the JDK resolves, and nothing is written to the
project.  Kotlin is unaffected either way, kotlin-lsp keeping its model
entirely outside the tree."
  :type 'boolean
  :group 'init/jvm)

(defun init/jvm--gradle-import-settings ()
  "Return the Gradle half of the Java server's workspace settings.
JDT LS imports with the Gradle Tooling API it bundles, which lags the
release many builds require, and it honours a wrapper only in the
project root -- which a component of a composite build does not have.
Naming the version the build's own wrapper pins keeps the import off a
Gradle too old to configure it.  The import is pinned to the JDK the
server runs on too, since it happens in a daemon of its own that would
otherwise take whatever `java' leads to."
  (if (not init/jvm-java-build-import)
      (list :enabled :json-false)
    (let ((version (init/jvm--gradle-wrapper-version))
          (home (init/jvm--java-server-home)))
      (append (list :enabled t :wrapper (list :enabled t))
              (when version (list :version version))
              (when home (list :java (list :home home)))))))

(defun init/jvm--java-workspace-configuration ()
  "Return the workspace settings sent to the Java language server."
  `(:java
    (:configuration (:runtimes ,(init/jvm--java-runtimes)
                     :updateBuildConfiguration "automatic")
     :import (:gradle ,(init/jvm--gradle-import-settings)
              :maven (:enabled ,(if init/jvm-java-build-import t :json-false)))
     :maxConcurrentBuilds 4
     :signatureHelp (:enabled t)
     :implementationsCodeLens (:enabled t)
     ;; Names the decompiler used to answer the jdt:// URIs handled below.
     :contentProvider (:preferred "fernflower"))))

;; Kotlin and Java register their servers here rather than in init-ide.el
;; because both command lines are computed per build: the data directory,
;; index location and heap depend on which build the buffer belongs to.
;; The Java class is defined here too, since it can only be derived once
;; Eglot has defined the class it derives from.
(with-eval-after-load 'eglot
  (defclass init/jvm-jdtls-server (eglot-lsp-server) ()
    "The Eglot server class for Eclipse JDT LS.
It exists to carry initialization options, which JDT LS needs before it
will resolve anything outside the file being edited.")

  (cl-defmethod eglot-initialization-options ((_server init/jvm-jdtls-server))
    "Return the options JDT LS is initialized with.
Its settings have to arrive here and not only through
`eglot-workspace-configuration': the build import runs during
initialization, so settings sent afterwards arrive too late to stop it.
`classFileContentsSupport' is what permits the jdt:// URIs the handler
above resolves -- without it JDT LS answers a symbol that lives in a jar
with nothing at all, rather than with a URI."
    (list :settings (init/jvm--java-workspace-configuration)
          :extendedClientCapabilities (list :classFileContentsSupport t)))

  (add-to-list 'eglot-server-programs
               (cons '(kotlin-mode kotlin-ts-mode) #'init/jvm--kotlin-contact))
  (add-to-list 'eglot-server-programs
               (cons '(java-mode java-ts-mode) #'init/jvm--java-contact)))

;;;; Library sources inside jars

;; `eglot-uri-to-path' passes URIs it does not recognise through
;; untouched, leaving them to `file-name-handler-alist'.  JDT LS answers
;; "go to definition" on a library symbol with a jdt:// URI whose
;; contents only the server can produce, so without a handler M-. onto
;; anything outside the project fails.  The regexp cannot match a real
;; file name, so this is inert for every other path Emacs opens.

(defconst init/jvm--jdt-uri-regexp "\\`jdt://"
  "Regexp matching the URIs JDT LS uses for classes inside jars.")

(defun init/jvm--jdt-server ()
  "Return an Eglot server that can decompile a class file, or nil.
`insert-file-contents' runs in the fresh buffer being filled, which no
server manages yet, so a Java server is looked for among all of them."
  (or (and (fboundp 'eglot-current-server) (eglot-current-server))
      (when (and (boundp 'eglot--servers-by-project)
                 (fboundp 'eglot--major-modes))
        (catch 'found
          (maphash (lambda (_project servers)
                     (dolist (server servers)
                       (when (seq-intersection '(java-mode java-ts-mode)
                                               (eglot--major-modes server))
                         (throw 'found server))))
                   eglot--servers-by-project)
          nil))))

(defun init/jvm--jdt-class-contents (uri)
  "Return the source JDT LS has for the class at URI."
  (let ((server (init/jvm--jdt-server)))
    (or (and server
             (ignore-errors
               (jsonrpc-request server :java/classFileContents (list :uri uri))))
        (format "// No Java language server could decompile\n// %s\n" uri))))

(defun init/jvm--jdt-file-handler (operation &rest arguments)
  "Handle file OPERATION with ARGUMENTS on a jdt:// URI.
Operations that would go to the file system are answered here, there
being no such file, and the URI is kept verbatim by the ones that would
otherwise rewrite it.  Everything else falls through to its ordinary
definition, which treats the URI as the plain string it is -- answering
nil instead would break callers as innocent as `file-name-extension'."
  (pcase operation
    ('insert-file-contents
     (pcase-let ((`(,uri ,visit . ,_) arguments))
       (when visit
         (setq buffer-file-name uri)
         (set-visited-file-modtime '(0 0)))
       (let ((contents (init/jvm--jdt-class-contents uri)))
         (insert contents)
         (list uri (length contents)))))
    ((or 'expand-file-name 'file-truename 'substitute-in-file-name
         'abbreviate-file-name)
     (car arguments))
    ;; Names the buffer after the class rather than after the percent
    ;; encoded tail of the URI, and gives it a .java extension for
    ;; anything that reasons about the name.
    ('file-name-nondirectory
     (let ((uri (car arguments)))
       (if (string-match "/\\([^/?]+\\.java\\)\\(?:\\?\\|\\'\\)" uri)
           (match-string 1 uri)
         uri)))
    ((or 'file-exists-p 'file-readable-p 'file-regular-p) t)
    ((or 'file-writable-p 'file-directory-p 'file-symlink-p 'file-remote-p
         'file-attributes 'file-locked-p 'vc-registered)
     nil)
    (_ (let ((inhibit-file-name-handlers
              (cons #'init/jvm--jdt-file-handler
                    (and (eq inhibit-file-name-operation operation)
                         inhibit-file-name-handlers)))
             (inhibit-file-name-operation operation))
         (apply operation arguments)))))

(add-to-list 'file-name-handler-alist
             (cons init/jvm--jdt-uri-regexp #'init/jvm--jdt-file-handler))

(defun init/jvm--jdt-prepare-buffer ()
  "Present a decompiled class as read-only Java source.
`set-auto-mode' cannot pick a mode from a URI, and the mode hooks are
skipped because the buffer is library source: Eglot already reaches it
through `eglot-extend-to-xref', and it must not start a second server."
  (when (and buffer-file-name
             (string-match-p init/jvm--jdt-uri-regexp buffer-file-name))
    (delay-mode-hooks
      (if (and (fboundp 'java-ts-mode) (treesit-ready-p 'java t))
          (java-ts-mode)
        (java-mode)))
    (setq buffer-read-only t)
    (set-buffer-modified-p nil)))

(add-hook 'find-file-hook #'init/jvm--jdt-prepare-buffer)

;;;; Gradle

(defcustom init/jvm-gradle-options '("--console=plain")
  "Options added to every Gradle invocation.
Gradle's rich console redraws itself with escape sequences meant for a
terminal, which the run/build panel shows as noise."
  :type '(repeat string)
  :group 'init/jvm)

(defun init/jvm--gradle-wrapper ()
  "Return the Gradle wrapper governing this buffer's build, or nil.
A component of a composite build usually has no wrapper of its own and
shares the umbrella's, so the search continues above the build root."
  (when-let ((dir (locate-dominating-file (init/jvm-project-root) "gradlew")))
    (expand-file-name "gradlew" dir)))

(defun init/jvm--module-path ()
  "Return the Gradle path of the module owning this buffer, or nil.
For arm/student-lookup/src/... this is \":student-lookup\", so a task
addresses that module alone.  Nil means the build's root project."
  (when-let* ((root (init/jvm-project-root))
              (module (init/locate-dominating-match
                       init/jvm-module-markers (init/jvm--source-directory)))
              (relative (file-relative-name (expand-file-name module) root)))
    (unless (string-prefix-p ".." relative)
      (when-let ((segments (split-string relative "/" t "\\.")))
        (concat ":" (string-join segments ":"))))))

(defun init/jvm--module-task (name)
  "Return the Gradle task NAME scoped to this buffer's module."
  (concat (or (init/jvm--module-path) "") ":" name))

(defun init/jvm--gradle (&rest arguments)
  "Save the buffer and run the Gradle wrapper with ARGUMENTS.
The wrapper runs from the build root, which is what tells Gradle which
build of a composite it is being asked about."
  (save-buffer)
  (let ((wrapper (or (init/jvm--gradle-wrapper)
                     (user-error "No gradlew found for this build")))
        (default-directory (init/jvm-project-root)))
    (compile (mapconcat #'shell-quote-argument
                        (append (list wrapper)
                                init/jvm-gradle-options
                                (delq nil arguments))
                        " "))))

(defun init/jvm--package-name ()
  "Return the package declared at the top of the buffer, or nil."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (when (re-search-forward
             "^[[:space:]]*package[[:space:]]+\\([[:alnum:]_.]+\\)" 8192 t)
        (match-string-no-properties 1)))))

(defconst init/jvm--function-node-types
  '("function_declaration" "method_declaration")
  "Tree-sitter node types declaring a function, in Kotlin and in Java.")

(defconst init/jvm--class-node-types
  '("class_declaration" "object_declaration")
  "Tree-sitter node types declaring a class, in Kotlin and in Java.")

(defconst init/jvm--name-node-types
  '("simple_identifier" "type_identifier" "identifier")
  "Tree-sitter node types carrying the name of a declaration.")

(defun init/jvm--node-name (node)
  "Return the name NODE declares, or nil.
Java's grammar puts it in a name field; Kotlin's has no fields here, so
the first identifier among the children is taken instead.  Kotlin allows
a name in backticks, which are quoting and not part of the name."
  (when-let* ((named (or (treesit-node-child-by-field-name node "name")
                         (seq-find (lambda (child)
                                     (member (treesit-node-type child)
                                             init/jvm--name-node-types))
                                   (treesit-node-children node)))))
    (string-trim (treesit-node-text named t) "`" "`")))

(defun init/jvm--enclosing (types)
  "Return the names of the ancestors of point whose type is in TYPES.
Outermost first, so a nesting can be rebuilt in source order.  Nil when
no tree-sitter parser is running in this buffer."
  (when (and (fboundp 'treesit-parser-list) (treesit-parser-list))
    (let ((node (treesit-node-at (point)))
          names)
      (while node
        (when (member (treesit-node-type node) types)
          (push (init/jvm--node-name node) names))
        (setq node (treesit-node-parent node)))
      (delq nil names))))

(defun init/jvm--class-name ()
  "Return the class around point, nested classes joined by `$'.
That is the spelling Gradle's --tests filter matches on.  Falls back to
the file's own name, which is what Kotlin and Java call the class a file
principally declares."
  (or (when-let ((names (init/jvm--enclosing init/jvm--class-node-types)))
        (string-join names "$"))
      (file-name-base buffer-file-name)))

(defun init/jvm--qualified-class ()
  "Return the fully qualified name of the class around point."
  (unless buffer-file-name
    (user-error "This buffer is not visiting a file"))
  (let ((class (init/jvm--class-name))
        (package (init/jvm--package-name)))
    (if package (concat package "." class) class)))

(defun init/jvm--test-name ()
  "Return the name of the test function around point, or nil.
`which-function' answers nil in the tree-sitter Kotlin mode, so the
enclosing function is read from the syntax tree, and `which-function' is
only the fallback for the modes that have no parser."
  (or (car (last (init/jvm--enclosing init/jvm--function-node-types)))
      (when-let ((name (which-function)))
        (string-trim (car (last (split-string name "\\."))) "`" "`"))))

(defun init/jvm-run ()
  "Run the Gradle `run' task for the module owning this buffer."
  (interactive)
  (init/jvm--gradle (init/jvm--module-task "run")))

(defun init/jvm-build ()
  "Assemble this build, skipping its tests."
  (interactive)
  (init/jvm--gradle "build" "-x" "test"))

(defun init/jvm-test-project ()
  "Run every test in this build."
  (interactive)
  (init/jvm--gradle "test"))

(defun init/jvm-test-file ()
  "Run the tests in the class this file declares."
  (interactive)
  (init/jvm--gradle (init/jvm--module-task "test")
                    "--tests" (init/jvm--qualified-class)))

(defun init/jvm-test-at-point ()
  "Run the single test around point, or the whole class when unsure."
  (interactive)
  (let ((class (init/jvm--qualified-class))
        (test (init/jvm--test-name)))
    (init/jvm--gradle (init/jvm--module-task "test")
                      "--tests" (if test (concat class "." test) class))))

(defun init/jvm-gradle-task (task)
  "Run an arbitrary Gradle TASK from this build's root.
Prefilled with this buffer's module path, so completing it with a task
name runs that task for the module alone."
  (interactive
   (list (read-string "Gradle task: " (concat (init/jvm--module-path) ":"))))
  (init/jvm--gradle task))

(defun init/jvm-show-keybindings ()
  "Show the cheatsheet covering the Kotlin and Java commands."
  (interactive)
  (cheatsheet-show "Kotlin & Java"))

;;;; Buffer setup

(defun init/jvm--setup (kind)
  "Set up a KIND buffer: indentation, Gradle actions and the language server."
  (setq-local indent-tabs-mode nil
              tab-width 4
              ;; Read buffer-locally when Eglot connects this buffer, so
              ;; a slow cold start elsewhere is not made everyone's
              ;; problem.
              eglot-connect-timeout init/jvm-connect-timeout
              init/ide-run-function #'init/jvm-run
              init/ide-test-at-point-function #'init/jvm-test-at-point
              init/ide-test-file-function #'init/jvm-test-file
              init/ide-test-project-function #'init/jvm-test-project
              init/ide-sync-function #'init/jvm-build)
  ;; Buffer-local, so only JVM buffers resolve their project as a build.
  (add-hook 'project-find-functions #'init/jvm--project-try nil t)
  (when (init/jvm--offer-install kind)
    (eglot-ensure)
    (init/ide-prefer-flycheck)
    (init/ide-format-with-eglot-on-save))
  (init/ide-mode 1))

(defun init/jvm-kotlin-setup ()
  "Set up Kotlin editing, LSP and diagnostics in the current buffer."
  (init/jvm--setup 'kotlin))

(defun init/jvm-java-setup ()
  "Set up Java editing, LSP and diagnostics in the current buffer."
  (setq-local eglot-workspace-configuration
              (init/jvm--java-workspace-configuration))
  (when (bound-and-true-p c-buffer-is-cc-mode)
    (c-set-style "java")
    (setq-local c-basic-offset 4))
  (init/jvm--setup 'java))

;;;; Major modes

;; kotlin-mode is the fallback; `treesit-auto' remaps it to kotlin-ts-mode
;; wherever the Kotlin grammar is installed, and offers to install it
;; where it is not.  Both hooks run the same setup.
(use-package kotlin-mode
  :mode ("\\.kt\\'" "\\.kts\\'")
  :hook (kotlin-mode . init/jvm-kotlin-setup))

(use-package kotlin-ts-mode
  :defer t
  :hook (kotlin-ts-mode . init/jvm-kotlin-setup))

(add-hook 'java-mode-hook #'init/jvm-java-setup)
(add-hook 'java-ts-mode-hook #'init/jvm-java-setup)

;;;; Keybindings

(with-eval-after-load 'kotlin-mode
  (define-key kotlin-mode-map (kbd bind/jvm-gradle-task) #'init/jvm-gradle-task)
  (define-key kotlin-mode-map (kbd bind/jvm-help) #'init/jvm-show-keybindings))

(with-eval-after-load 'kotlin-ts-mode
  (define-key kotlin-ts-mode-map (kbd bind/jvm-gradle-task)
              #'init/jvm-gradle-task)
  (define-key kotlin-ts-mode-map (kbd bind/jvm-help)
              #'init/jvm-show-keybindings))

(with-eval-after-load 'cc-mode
  (define-key java-mode-map (kbd bind/jvm-gradle-task) #'init/jvm-gradle-task)
  (define-key java-mode-map (kbd bind/jvm-help) #'init/jvm-show-keybindings))

(with-eval-after-load 'java-ts-mode
  (define-key java-ts-mode-map (kbd bind/jvm-gradle-task)
              #'init/jvm-gradle-task)
  (define-key java-ts-mode-map (kbd bind/jvm-help)
              #'init/jvm-show-keybindings))

(with-eval-after-load 'which-key
  (which-key-add-key-based-replacements
    "C-c j" "jvm"
    bind/jvm-gradle-task "gradle task"
    bind/jvm-help "kotlin/java cheatsheet"))

(provide 'init-lang-jvm)
;;; init-lang-jvm.el ends here
