;;; init-ai.el --- Local language-model integration -*- lexical-binding: t; -*-

;;; Commentary:

;; gptel talks to the llama.cpp server managed by the user's servellm systemd
;; service.  The backend is local and unauthenticated, streams responses, and
;; uses the exact model identifier advertised by llama-server's /v1/models
;; endpoint.  Sampling parameters are intentionally left unset here so the
;; defaults in ~/.alatar/bin/servellm remain authoritative.

;;; Code:

(defconst init/gptel-servellm-host "127.0.0.1:7999"
  "Host and port of the local servellm llama.cpp API.")

(defconst init/gptel-servellm-model
  'unsloth/Qwen3.6-35B-A3B-MTP-GGUF:UD-Q4_K_XL
  "Model identifier advertised by the local servellm API.")

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
  ;; Keep reasoning visible in the response but omit it from later turns.
  (gptel-include-reasoning 'ignore)
  :config
  ;; Make turns distinct Org headings.  gptel removes the prompt prefix before
  ;; sending it and converts the model's Markdown response into Org markup.
  (setf (alist-get 'org-mode gptel-prompt-prefix-alist) "*** You\n\n"
        (alist-get 'org-mode gptel-response-prefix-alist) "*** Assistant\n\n")
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

(with-eval-after-load 'which-key
  (which-key-add-key-based-replacements
    "C-c RET" "send / options with C-u"
    "C-c e" "new AI chat"
    "C-c w" "AI rewrite region"
    "C-c i" "include AI context"
    "C-c I" "include AI context file"
    "C-c k" "cancel AI request"))

(provide 'init-ai)
;;; init-ai.el ends here
