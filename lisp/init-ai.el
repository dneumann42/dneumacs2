;;; init-ai.el --- Local language-model integration -*- lexical-binding: t; -*-

;;; Commentary:

;; gptel talks to the llama.cpp server managed by the user's servellm systemd
;; service.  The backend is local and unauthenticated, streams responses, and
;; uses the exact model identifier advertised by llama-server's /v1/models
;; endpoint.  Sampling parameters are intentionally left unset here so the
;; defaults in ~/.alatar/bin/servellm remain authoritative.
;;
;; Reasoning (thinking) text is redirected into its own buffer, shown in a
;; floating child frame pinned to the frame's right edge -- the run/build
;; panel (init-compile) floats at the top right, this one anchors at the
;; bottom right so the two never overlap.  The panel appears automatically
;; when a request starts producing reasoning, scrolls to the newest text
;; as it streams, and carries a small toolbar: follow newest text, clear,
;; copy, resize and dismiss.
;;
;; The LLM backend itself is switchable: `init/gptel-backend' is a
;; Customize option (servellm or opencode) and the pulldown menu at
;; C-c m picks one, applies it on the spot, and persists the choice.

;;; Code:

(require 'init-lib)
(require 'init-pulldown)
(require 'init-toolbar)

(defconst init/gptel-servellm-host "127.0.0.1:7999"
  "Host and port of the local servellm llama.cpp API.")

(defconst init/gptel-servellm-model
  'unsloth/Qwen3.6-35B-A3B-MTP-GGUF:UD-Q4_K_XL
  "Model identifier advertised by the local servellm API.")

;;;; Reasoning panel

;; The run/build panel (init-compile) floats a child frame at the top
;; right; the reasoning panel is the same idea anchored to the bottom
;; right.  gptel appends thinking text to `init/reasoning-buffer-name'
;; (see `gptel-include-reasoning' below); a child frame created by
;; `display-buffer-alist' shows that buffer, and every streamed chunk
;; reuses the existing frame, so the thinking updates live while a
;; request runs.

(defconst init/reasoning-buffer-name "*gptel-reasoning*"
  "Name of the buffer gptel streams reasoning text into.")

(defvar init/reasoning-frame nil
  "The live child frame showing the reasoning buffer, or nil.")

(defvar init/reasoning-frame-width 90
  "Width, in columns, of the floating reasoning panel.")

(defvar init/reasoning-frame-height 20
  "Height, in lines, of the floating reasoning panel.")

(defvar-keymap init/reasoning-mode-map
  "q" #'init/reasoning-dismiss
  "g" #'init/reasoning-follow
  "C-c C-l" #'init/reasoning-clear
  "C-c C-c" #'init/reasoning-copy)

(define-minor-mode init/reasoning-mode
  "Minor mode for the gptel reasoning buffer in its floating panel."
  :lighter " ✱"
  :keymap init/reasoning-mode-map)

(defvar-local init/reasoning--configured nil
  "Non-nil once the reasoning buffer has its toolbar and keymap.")

(defun init/reasoning--buffer ()
  "Return the live reasoning buffer, or nil."
  (get-buffer init/reasoning-buffer-name))

(defun init/reasoning--ensure-buffer ()
  "Return the reasoning buffer, configuring it on its first use."
  (let ((buffer (get-buffer-create init/reasoning-buffer-name)))
    (with-current-buffer buffer
      (unless init/reasoning--configured
        (init/reasoning-mode 1)
        (init/toolbar-attach #'init/reasoning--panel-toolbar)
        (setq-local init/reasoning--configured t)))
    buffer))

(defun init/display-reasoning-in-child-frame (buffer _alist)
  "Display BUFFER in a resizable child frame at the frame's bottom right.
_BUFFER's name must match `init/reasoning-buffer-name'.  _ALIST is
accepted for the `display-buffer' protocol.  An existing frame is
reused, so streamed chunks never tear the frame down and recreate it."
  (if (frame-live-p init/reasoning-frame)
      (progn
        (unless (eq (window-buffer (frame-root-window init/reasoning-frame))
                    buffer)
          (set-window-buffer (frame-root-window init/reasoning-frame) buffer))
        (raise-frame init/reasoning-frame)
        (frame-root-window init/reasoning-frame))
    (condition-case err
        (let* ((parent (selected-frame))
               (width (* init/reasoning-frame-width (frame-char-width parent)))
               (left (max 0 (- (frame-pixel-width parent) width 20)))
               (top (max 0 (- (frame-pixel-height parent)
                              (* init/reasoning-frame-height
                                 (frame-char-height parent))
                              80)))
               (frame (make-frame
                       `((parent-frame . ,parent)
                         (width . ,init/reasoning-frame-width)
                         (height . ,init/reasoning-frame-height)
                         (top . ,top)
                         (left . ,left)
                         (undecorated . t)
                         (internal-border-width . 6)
                         (drag-internal-border . t)))))
          (setq init/reasoning-frame frame)
          (set-window-buffer (frame-root-window frame) buffer)
          (raise-frame frame)
          (frame-root-window frame))
      (error
       (message "Reasoning panel: %s" (error-message-string err))
       nil))))

(add-to-list 'display-buffer-alist
             `(,(regexp-quote init/reasoning-buffer-name)
               (init/display-reasoning-in-child-frame)))

;;;; Reasoning panel commands

(defun init/reasoning-dismiss ()
  "Delete the floating reasoning child frame."
  (interactive)
  (when (frame-live-p init/reasoning-frame)
    (delete-frame init/reasoning-frame)
    (setq init/reasoning-frame nil)))

(defun init/reasoning-follow ()
  "Move point to the newest reasoning text."
  (interactive)
  (when-let* ((window (get-buffer-window (init/reasoning--buffer) t)))
    (with-selected-window window
      (goto-char (point-max)))))

(defun init/reasoning-clear ()
  "Erase the reasoning buffer."
  (interactive)
  (when-let* ((buffer (init/reasoning--buffer)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (message "Reasoning cleared")))

(defun init/reasoning-copy ()
  "Copy the reasoning buffer's contents to the kill ring."
  (interactive)
  (when-let* ((buffer (init/reasoning--buffer)))
    (with-current-buffer buffer
      (copy-region-as-kill (point-min) (point-max))
      (message "Copied %d characters of reasoning" (buffer-size)))))

(defun init/reasoning--resize (delta)
  "Grow (DELTA > 0) or shrink the floating reasoning panel by DELTA lines."
  (unless (frame-live-p init/reasoning-frame)
    (user-error "No floating reasoning panel is open"))
  (setq init/reasoning-frame-height
        (max 6 (+ init/reasoning-frame-height delta)))
  (set-frame-height init/reasoning-frame init/reasoning-frame-height))

(defun init/reasoning-enlarge ()
  "Make the floating reasoning panel taller."
  (interactive)
  (init/reasoning--resize 4))

(defun init/reasoning-shrink ()
  "Make the floating reasoning panel shorter."
  (interactive)
  (init/reasoning--resize -4))

;;;; Reasoning panel toolbar

(defun init/reasoning--status ()
  "Return the size segment for the reasoning panel toolbar."
  (init/toolbar-info
   (format "✱ %s chars" (buffer-size))
   "gptel reasoning buffer"))

(defun init/reasoning--panel-toolbar ()
  "Build the toolbar shown on the floating reasoning panel."
  (init/toolbar-string
   '("⤓" "Jump to the newest reasoning text" init/reasoning-follow)
   '("⌫" "Clear the reasoning buffer" init/reasoning-clear)
   '("⧉" "Copy all reasoning to the kill ring" init/reasoning-copy)
   :sep
   '("⤢" "Make the panel taller" init/reasoning-enlarge)
   '("⤡" "Make the panel shorter" init/reasoning-shrink)
   :sep
   '("✕" "Dismiss the reasoning panel" init/reasoning-dismiss)
   :sep
   #'init/reasoning--status))

(defun init/reasoning--auto-show (_text info)
  "Reveal the reasoning panel as soon as gptel streams thinking text.
INFO is gptel's request plist; _TEXT is ignored.  Only fires for
requests whose `:include-reasoning' targets this panel's buffer.
The window follows the newest text, so the thinking stays in view
while the request streams."
  (when (equal (plist-get info :include-reasoning)
               init/reasoning-buffer-name)
    (let* ((buffer (init/reasoning--ensure-buffer))
           (window (display-buffer buffer)))
      (when (and (window-live-p window)
                 (eq (window-buffer window) buffer))
        (with-selected-window window
          (goto-char (point-max))
          (recenter -1))))))

;;;; LLM backend selection

;; Which backend gptel talks to is a Customize option, so the normal
;; Customize machinery applies: `M-x customize-option init/gptel-backend',
;; `M-x init/gptel-backend-set', or the pulldown menu bound to
;; `bind/ai-backend-menu' (C-c m).  Setting it rebuilds `gptel-backend'
;; and `gptel-model' and rebases open chats immediately.

(defcustom init/gptel-opencode-key nil
  "Explicit OpenCode Zen API key, if you want one on file.
Normally the token is read automatically from opencode's own auth store
(`~/.local/share/opencode/auth.json', written by `opencode auth login'
or the TUI's /connect); set this only to pin a manual key, which then
takes precedence.  Got one at https://opencode.ai/auth."
  :type '(choice (const :tag "Use stored opencode auth" nil) string)
  :group 'gptel)

(defun init/gptel-opencode-auth-token ()
  "Return the OpenCode Zen API token from opencode's own auth store.
Reads `~/.local/share/opencode/auth.json' (or
$XDG_DATA_HOME/opencode/auth.json on Linux), the file that
`opencode auth login' and the TUI's /connect write.  Handles both
apikey credentials (`type' `api' => `key') and OAuth sessions
(`type' `oauth' => `access')."
  (let ((file (if (getenv "XDG_DATA_HOME")
                  (expand-file-name "opencode/auth.json"
                                    (getenv "XDG_DATA_HOME"))
                (expand-file-name
                 "~/.local/share/opencode/auth.json"))))
    (if-let* ((json (ignore-errors (json-read-file file)))
              (cred (alist-get 'opencode json))
              (token (pcase (alist-get 'type cred)
                       ("api" (alist-get 'key cred))
                       ("oauth" (alist-get 'access cred))
                       (_ nil))))
        token
      (user-error
       "No OpenCode Zen token in %s. Run `opencode auth login opencode', or set `init/gptel-opencode-key'"
       file))))

;; `init/gptel-backend' is defined as a defcustom further down; declare it
;; here so apply can reference it and keep the compiler quiet.
(defvar init/gptel-backend)

(defun init/gptel-opencode-header (_info)
  "Return HTTP headers for OpenCode Zen requests.

Zen's free tier rate-limits clients that don't identify
themselves the way the opencode CLI does (the 429-on-free-models
issue).  Send the same x-opencode-* identity headers the CLI
sends, with a fresh session/request id per call so Zen treats
gptel like a normal opencode client, plus the Authorization header
gptel would otherwise add (our :header overrides its default)."
  (append
   (when-let* ((key (gptel--get-api-key)))
     `(("Authorization" . ,(concat "Bearer " key))))
   `(("x-opencode-project" . "opencode")
     ("x-opencode-session" . ,(format "sess-%08x" (random (expt 2 32))))
     ("x-opencode-request" . ,(format "req-%08x" (random (expt 2 32))))
     ("x-opencode-client" . "tui")
     ("User-Agent" . "opencode/1.18.23")
     ("http-referer" . "https://opencode.ai/")
     ("x-title" . "opencode"))))

(defun init/gptel-backend--label (backend)
  "Return a short human label for BACKEND."
  (pcase backend
    ('servellm "ServeLLM")
    ('opencode "OpenCode Zen")
    (_ (symbol-name backend))))

(defun init/gptel-backend-apply ()
  "Rebuild `gptel-backend' and `gptel-model' for `init/gptel-backend'.
Also rebases every open gptel chat buffer, so the switch applies to
the conversation at hand, not just new chats."
  (pcase init/gptel-backend
    ('servellm
     (setq gptel-model init/gptel-servellm-model
           gptel-backend
           (gptel-make-openai "ServeLLM"
             :host init/gptel-servellm-host
             :protocol "http"
             :endpoint "/v1/chat/completions"
             :stream t
             :key nil
             :models
             `((,init/gptel-servellm-model
                :description "Local Qwen3.6 35B-A3B via llama.cpp"
                :capabilities (reasoning)
                :context-window 65.536)))))
    ('opencode
     (setq gptel-model 'big-pickle
           gptel-backend
           (gptel-make-openai "OpenCode Zen"
             :host "opencode.ai"
             :protocol "https"
             :endpoint "/zen/v1/chat/completions"
             :stream t
             :header #'init/gptel-opencode-header
             :key (lambda ()
                    (or init/gptel-opencode-key
                        (init/gptel-opencode-auth-token)))
             :models
             '((big-pickle
                :description "Big Pickle via OpenCode Zen"
                :capabilities (reasoning)
                :context-window 131072)))))
    (_ (user-error "Unknown gptel backend %S" init/gptel-backend)))
  ;; Chat buffers hold gptel-backend and gptel-model buffer-locally; point
  ;; them at the newly built objects so the switch is immediate.
  (dolist (buffer (buffer-list))
    (when (buffer-local-value 'gptel-mode buffer)
      (with-current-buffer buffer
        (setq gptel-backend (default-value 'gptel-backend)
              gptel-model (default-value 'gptel-model)))))
  (message "gptel backend: %s (%s)"
           (init/gptel-backend--label init/gptel-backend)
           (pcase init/gptel-backend
             ('servellm init/gptel-servellm-model)
             ('opencode 'big-pickle))))

(defcustom init/gptel-backend 'servellm
  "Which LLM backend gptel talks to.

`servellm' is the local llama.cpp server managed by the user's
servellm systemd service, sending the local Qwen model to
127.0.0.1:7999 with no authentication.

`opencode' is OpenCode Zen, the OpenAI-compatible gateway hosted
at opencode.ai, using the free Big Pickle model.  The API token is
picked up from opencode's own login (`opencode auth login opencode',
or the TUI's /connect), no manual key needed.

Switch with `init/gptel-backend-menu' or by setting this option."
  :type '(choice (const :tag "ServeLLM — local llama.cpp (127.0.0.1:7999)" servellm)
                 (const :tag "OpenCode Zen — big-pickle (opencode.ai)" opencode))
  :group 'gptel
  :set (lambda (sym val)
         (set-default sym val)
         (when (featurep 'gptel)
           (init/gptel-backend-apply))))

(defun init/gptel-backend-set (backend)
  "Set the gptel backend to BACKEND and apply it immediately.
BACKEND is one of `init/gptel-backend'\\'s choices (`servellm' or
`opencode').  The choice is saved with the Customize API, so it
survives restarts."
  (interactive
   (list (intern (completing-read
                  "gptel backend: "
                  '("servellm" "opencode") nil t))))
  (customize-save-variable 'init/gptel-backend backend))

(defun init/gptel-backend-menu (&optional event)
  "Popup a menu to switch the gptel LLM backend.
EVENT is the triggering mouse event, when called from the mouse."
  (interactive)
  (pulldown-menu-popup
   (list (format "LLM backend — now %s"
                 (init/gptel-backend--label init/gptel-backend))
         ["ServeLLM — local llama.cpp (127.0.0.1:7999)"
          (init/gptel-backend-set 'servellm)]
         ["OpenCode Zen — big-pickle (token from opencode auth)"
          (init/gptel-backend-set 'opencode)])
   event))

(global-set-key (kbd bind/ai-backend-menu) #'init/gptel-backend-menu)

;; Remove the former multi-key prefix when reloading this configuration.
(global-unset-key (kbd "C-c G"))

(use-package gptel
  :ensure t
  :commands (gptel gptel-send gptel-menu gptel-rewrite
                   gptel-add gptel-add-file gptel-abort)
  :bind (("C-c RET" . gptel-send)
         ("C-c e" . gptel)
         ("C-c w" . gptel-rewrite)
         ("C-c i" . gptel-add)
         ("C-c I" . gptel-add-file)
         ("C-c k" . gptel-abort))
  :custom
  ;; Dedicated chats are real Org buffers, so they inherit the writer font,
  ;; org-modern decorations, source-block styling and wrapping from init-org.
  (gptel-default-mode #'org-mode)
  (gptel-org-convert-response t)
  (gptel-use-curl t)
  (gptel-stream t)
  ;; Stream reasoning text into its own buffer instead of the chat.
  ;; The buffer is shown in a floating child frame at the bottom right,
  ;; live-updating and autoscrolling while the request runs.
  (gptel-include-reasoning init/reasoning-buffer-name)
  :config
  ;; Reveal the reasoning panel when a request starts producing thinking.
  (advice-add 'gptel--display-reasoning-stream :after #'init/reasoning--auto-show)
  ;; Make turns distinct Org headings.  gptel removes the prompt prefix before
  ;; sending it and converts the model's Markdown response into Org markup.
  (setf (alist-get 'org-mode gptel-prompt-prefix-alist) "*** You\n\n"
        (alist-get 'org-mode gptel-response-prefix-alist) "*** Assistant\n\n")
  ;; Build the backend and model for the Customize-chosen backend.
  (init/gptel-backend-apply))

(with-eval-after-load 'which-key
  (which-key-add-key-based-replacements
    "C-c RET" "send / options with C-u"
    "C-c e" "new AI chat"
    "C-c w" "AI rewrite region"
    "C-c i" "include AI context"
    "C-c I" "include AI context file"
    "C-c k" "cancel AI request"
    "C-c m" "switch LLM backend (servellm / opencode)"))

(provide 'init-ai)
;;; init-ai.el ends here
