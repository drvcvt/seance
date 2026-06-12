;;; seance-chat.el --- seance chat buffer -*- lexical-binding: t; -*-

;;; Commentary:
;; The chat major mode: transcript (read-only text properties) + an
;; editable input field at the end of the buffer.  Agent output streams
;; in just above the input prompt.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'seance-acp)
(require 'seance-context)
(require 'seance-diff)

(defvar seance-chat-buffer-name "*seance*"
  "Name of the seance chat buffer.")

(defface seance-user-face '((t :inherit font-lock-keyword-face :weight bold))
  "Face for the user's lines in the transcript.")
(defface seance-prompt-face '((t :inherit minibuffer-prompt))
  "Face for the input prompt.")
(defface seance-thought-face '((t :inherit shadow))
  "Face for agent thinking output.")
(defface seance-tool-face '((t :inherit font-lock-function-name-face))
  "Face for tool-call header lines.")

(defvar-local seance-chat--session nil
  "The `seance-acp-session' backing this chat buffer.")
(defvar-local seance-chat--output-marker nil
  "Insertion point for agent/transcript output (before the prompt).")
(defvar-local seance-chat--prompt-marker nil
  "Position right after the input prompt string; input lives from here to eob.")
(defvar-local seance-chat--history nil
  "List of previously sent prompts, most recent first.")
(defvar-local seance-chat--history-pos nil
  "Index into `seance-chat--history' while cycling, nil when not cycling.")
(defvar-local seance-chat--history-stash nil
  "Input field content stashed when history cycling started.")
(defvar-local seance-chat--block nil
  "Type of the currently streaming block: nil, `message' or `thought'.")
(defvar-local seance-chat--block-start nil
  "Marker: start of the currently streaming block (for finalize passes).")
(defvar-local seance-chat--thought-ov nil
  "Overlay hiding the current thought block's body.")
(defvar-local seance-chat--tool-regions nil
  "Hash table toolCallId -> plist (:start MARKER :end MARKER :detail-ov OVERLAY).")
(defvar-local seance-chat--tool-cache nil
  "Hash table toolCallId -> last merged tool plist (updates may be partial).")
(defvar-local seance-chat--plan-start nil
  "Start marker of the rendered plan block, nil before the first plan.")
(defvar-local seance-chat--plan-end nil
  "End marker of the rendered plan block, nil before the first plan.")

(defconst seance-chat--status-icons
  '(("pending" . "⏳") ("in_progress" . "⏳")
    ("completed" . "✓") ("failed" . "✗"))
  "Alist mapping tool-call status strings to display icons.")

(defvar seance-chat-mode-map (make-sparse-keymap)
  "Keymap for `seance-chat-mode'.")

(define-derived-mode seance-chat-mode fundamental-mode "seance"
  "Major mode for the seance chat buffer."
  (setq-local seance-chat--tool-regions (make-hash-table :test #'equal))
  (setq-local truncate-lines nil)
  (setq header-line-format '((:eval (seance-chat--header)))))

(defun seance-chat--header ()
  "Return the header line string for the chat buffer."
  (let ((sess seance-chat--session))
    (format " seance: %s · %s · %s · ? = help"
            (if sess (seance-acp-session-status sess) "off")
            (if sess (seance-acp-session-permission-mode sess) seance-permission-mode)
            (abbreviate-file-name (or (and sess (seance-acp-session-cwd sess))
                                      default-directory)))))

(defun seance-chat--initialize (&optional mode)
  "Insert the initial prompt and connect a session for this buffer.
When MODE is non-nil, set the new session's permission mode to it
right after connecting (e.g. `auto' for a yolo session)."
  (let ((inhibit-read-only t)
        (buf (current-buffer)))
    (erase-buffer)
    (insert (propertize "❯ " 'face 'seance-prompt-face
                        'read-only t 'rear-nonsticky t 'front-sticky t))
    (setq seance-chat--prompt-marker (point-marker))
    ;; Created after the prompt insert: insertion-type t would otherwise
    ;; let the prompt push this marker past itself.
    (setq seance-chat--output-marker (copy-marker (point-min) t))
    (setq seance-chat--session
          (seance-acp-connect
           (funcall seance-cwd-function)
           :on-update (lambda (u)
                        (when (buffer-live-p buf)
                          (with-current-buffer buf (seance-chat--on-update u))))
           :on-status (lambda (_s)
                        (when (buffer-live-p buf)
                          (with-current-buffer buf (force-mode-line-update))))))
    (when mode
      (setf (seance-acp-session-permission-mode seance-chat--session) mode))))

(defun seance-chat--insert-output (string)
  "Insert STRING into the transcript, above the input prompt."
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char seance-chat--output-marker)
      (insert (propertize string 'read-only t
                          'front-sticky '(read-only) 'rear-nonsticky t)))))

(defun seance-chat--input-text ()
  "Return the current content of the input field."
  (buffer-substring-no-properties seance-chat--prompt-marker (point-max)))

(defun seance-chat--set-input (text)
  "Replace the input field content with TEXT, leaving point at eob."
  (let ((inhibit-read-only t))
    (delete-region seance-chat--prompt-marker (point-max))
    (goto-char (point-max))
    (insert text)))

(defun seance-chat-send ()
  "Send the input field content as the next prompt."
  (interactive)
  (let ((text (string-trim (seance-chat--input-text)))
        (buf (current-buffer)))
    (cond
     ((string-empty-p text) (message "seance: nothing to send"))
     ((not (and seance-chat--session
                (eq (seance-acp-session-status seance-chat--session) 'idle)))
      (message "seance: not ready (%s)"
               (and seance-chat--session
                    (seance-acp-session-status seance-chat--session))))
     (t
      (seance-chat--set-input "")
      (push text seance-chat--history)
      (setq seance-chat--history-pos nil)
      (seance-chat--insert-output
       (concat (propertize (concat "Du › " text) 'face 'seance-user-face)
               "\n\n"))
      (seance-acp-prompt seance-chat--session
                         (seance-chat--prepare-prompt text)
                         (lambda (_res err)
                           (when (buffer-live-p buf)
                             (with-current-buffer buf
                               (seance-chat--end-turn err)))))))))

(defun seance-chat--close-block ()
  "Close the open streaming block: finalize rendering, separate, reset.
Completed message blocks get their markdown code fences fontified."
  (when (and (eq seance-chat--block 'message) seance-chat--block-start)
    (seance-chat--fontify-markdown (marker-position seance-chat--block-start)
                                   (marker-position seance-chat--output-marker)))
  (when seance-chat--block
    (seance-chat--insert-output "\n\n"))
  (when seance-chat--block-start
    (set-marker seance-chat--block-start nil))
  (setq seance-chat--block nil
        seance-chat--block-start nil
        seance-chat--thought-ov nil))

(defun seance-chat--end-turn (err)
  "Close the streaming block at turn end; render ERR if non-nil."
  (seance-chat--close-block)
  (when err
    (seance-chat--insert-output (format "[error] %s\n\n" err))))

(defun seance-chat--prepare-prompt (text)
  "Wrap TEXT with the environment preamble on the session's first turn."
  (seance-context-wrap seance-chat--session text))

(defun seance-chat-newline ()
  "Insert a newline into the input field."
  (interactive)
  (insert "\n"))

(defun seance-chat-cancel ()
  "Cancel the in-flight turn."
  (interactive)
  (when seance-chat--session
    (seance-acp-cancel seance-chat--session)))

(defun seance-chat-history-prev ()
  "Replace the input field with the previous (older) history entry."
  (interactive)
  (when seance-chat--history
    (unless seance-chat--history-pos
      (setq seance-chat--history-stash (seance-chat--input-text))
      (setq seance-chat--history-pos -1))
    (when (< seance-chat--history-pos (1- (length seance-chat--history)))
      (cl-incf seance-chat--history-pos)
      (seance-chat--set-input (nth seance-chat--history-pos seance-chat--history)))))

(defun seance-chat-history-next ()
  "Replace the input field with the next (newer) history entry."
  (interactive)
  (when seance-chat--history-pos
    (if (zerop seance-chat--history-pos)
        (progn (setq seance-chat--history-pos nil)
               (seance-chat--set-input seance-chat--history-stash))
      (cl-decf seance-chat--history-pos)
      (seance-chat--set-input (nth seance-chat--history-pos seance-chat--history)))))

;; --- session/update rendering -------------------------------------------

(defun seance-chat--on-update (update)
  "Render the session UPDATE plist into the transcript."
  (pcase (plist-get update :sessionUpdate)
    ("agent_message_chunk"
     (seance-chat--stream-chunk
      'message (plist-get (plist-get update :content) :text)))
    ("agent_thought_chunk"
     (seance-chat--stream-chunk
      'thought (plist-get (plist-get update :content) :text)))
    ("tool_call" (seance-chat--render-tool update))
    ("tool_call_update" (seance-chat--render-tool update))
    ("plan" (seance-chat--render-plan update))
    (_ nil)))

(defun seance-chat--stream-chunk (type text)
  "Append TEXT to the current streaming block of TYPE (message/thought).
Thought blocks render as a collapsed \"▸ Thinking…\" header whose
streamed body is hidden by an invisible overlay (TAB toggles it)."
  (when text
    (unless (eq seance-chat--block type)
      (seance-chat--close-block)
      (setq seance-chat--block type)
      (setq seance-chat--block-start
            (copy-marker seance-chat--output-marker nil))
      (when (eq type 'thought)
        (seance-chat--insert-output
         (propertize "▸ Thinking…\n" 'face 'seance-thought-face
                     'seance-thought-header t))
        (let ((pos (marker-position seance-chat--output-marker)))
          (setq seance-chat--thought-ov (make-overlay pos pos))
          (overlay-put seance-chat--thought-ov 'seance-thought t)
          (overlay-put seance-chat--thought-ov 'invisible t))))
    (seance-chat--insert-output
     (if (eq type 'thought)
         (propertize text 'face 'seance-thought-face)
       text))
    (when (and (eq type 'thought) seance-chat--thought-ov)
      ;; Grow the hiding overlay to cover the streamed body.  The "\n\n"
      ;; separator inserted later at the overlay's end does NOT extend it
      ;; (rear-advance is nil), so the separator stays visible.
      (move-overlay seance-chat--thought-ov
                    (overlay-start seance-chat--thought-ov)
                    (marker-position seance-chat--output-marker)))))

(defun seance-chat--thought-overlay-at (pos)
  "Return the thought-hiding overlay at or shortly after POS, if any.
Among several candidates the one starting earliest wins; the order of
`overlays-in' is unspecified before Emacs 29."
  (let (best)
    (dolist (ov (overlays-in pos (min (point-max) (+ pos 2000))))
      (when (and (overlay-get ov 'seance-thought)
                 (or (null best)
                     (< (overlay-start ov) (overlay-start best))))
        (setq best ov)))
    best))

(defun seance-chat-toggle-thought ()
  "Toggle the thought block at point; fall back to tool-call details."
  (interactive)
  (if-let* ((ov (and (get-text-property (line-beginning-position)
                                        'seance-thought-header)
                     (seance-chat--thought-overlay-at (line-end-position)))))
      (overlay-put ov 'invisible (not (overlay-get ov 'invisible)))
    (seance-chat-toggle-detail)))

(defun seance-chat--fontify-markdown (start end)
  "Fontify completed markdown code fences between START and END."
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char start)
      (while (re-search-forward "^```\\([a-zA-Z-]*\\)\n" end t)
        (let* ((lang (match-string 1))
               (body-start (point))
               (close-end (re-search-forward "^```$" end t)))
          (when close-end
            ;; The fontify pass replaces the body with an equal-length
            ;; string, so CLOSE-END stays valid afterwards.
            (seance-chat--fontify-region-as
             body-start (match-beginning 0) lang)
            (goto-char close-end)))))))

(defcustom seance-chat-fence-modes
  '(("elisp" . emacs-lisp-mode) ("emacs-lisp" . emacs-lisp-mode)
    ("lisp" . emacs-lisp-mode)
    ("c" . c-mode) ("h" . c-mode)
    ("py" . python-mode) ("python" . python-mode)
    ("sh" . sh-mode) ("bash" . sh-mode) ("shell" . sh-mode)
    ("js" . js-mode) ("javascript" . js-mode)
    ("json" . js-json-mode)
    ("rust" . rust-mode) ("rs" . rust-mode))
  "Alist mapping markdown fence language strings to major mode symbols.
The fence language comes from the agent, so fontification never derives
a function name from it: only modes listed here are ever called.
Unknown languages render as plain text.  Entries whose mode symbol is
not bound (e.g. an uninstalled `rust-mode') are ignored.  Extend this
alist to fontify additional languages."
  :type '(alist :key-type string :value-type symbol)
  :group 'seance)

(defun seance-chat--fontify-region-as (start end lang)
  "Apply LANG mode font-lock faces to the region START..END.
LANG is looked up in `seance-chat-fence-modes'; unknown languages and
any error during fontification degrade to the plain unfontified text."
  (let* ((text (buffer-substring-no-properties start end))
         (mode (cdr (assoc lang seance-chat-fence-modes)))
         (fontified
          (if (and mode (fboundp mode))
              (condition-case nil
                  (with-temp-buffer
                    (insert text)
                    (delay-mode-hooks (funcall mode))
                    (font-lock-ensure)
                    ;; normalize font-lock-face → face so it renders without font-lock
                    (let ((pos (point-min)))
                      (while (< pos (point-max))
                        (let ((f (or (get-text-property pos 'face)
                                     (get-text-property pos 'font-lock-face)))
                              (next (or (next-single-property-change pos 'face)
                                        (point-max))))
                          (when f (put-text-property pos next 'face f))
                          (setq pos next))))
                    (buffer-string))
                (error text))
            text)))
    (delete-region start end)
    (goto-char start)
    (insert (propertize fontified 'read-only t 'rear-nonsticky t
                        'front-sticky '(read-only)))))

;; --- tool calls and plan ---------------------------------------------------

(defun seance-chat--tool-merged (update)
  "Merge UPDATE into the cached state for its toolCallId; return merged plist."
  (unless seance-chat--tool-cache
    (setq seance-chat--tool-cache (make-hash-table :test #'equal)))
  (let* ((id (plist-get update :toolCallId))
         (old (gethash id seance-chat--tool-cache))
         (merged (copy-sequence (or old '()))))
    (cl-loop for (k v) on update by #'cddr
             do (setq merged (plist-put merged k v)))
    (puthash id merged seance-chat--tool-cache)
    merged))

(defun seance-chat--tool-header-line (tool)
  "Return the propertized one-line header for the TOOL plist."
  (let* ((status (or (plist-get tool :status) "pending"))
         (icon (or (cdr (assoc status seance-chat--status-icons)) "·")))
    (propertize
     (format "▸ %s %s %s" icon (or (plist-get tool :kind) "tool")
             (or (plist-get tool :title) (plist-get tool :toolCallId)))
     'face 'seance-tool-face)))

(defun seance-chat--tool-detail (tool)
  "Multi-line detail text for TOOL: diffs and text content."
  (mapconcat
   (lambda (item)
     (pcase (plist-get item :type)
       ("diff" (seance-diff-strings (or (plist-get item :oldText) "")
                                    (or (plist-get item :newText) "")
                                    (plist-get item :path)))
       ("content" (or (plist-get (plist-get item :content) :text) ""))
       (_ (format "%S" item))))
   (append (plist-get tool :content) nil)
   "\n"))

(defun seance-chat--render-tool (update)
  "Render or in-place update the entry for UPDATE's toolCallId."
  (seance-chat--close-block)
  (let* ((tool (seance-chat--tool-merged update))
         (id (plist-get tool :toolCallId))
         (entry (gethash id seance-chat--tool-regions))
         (header (seance-chat--tool-header-line tool))
         (detail (seance-chat--tool-detail tool))
         (inhibit-read-only t))
    (when entry  ; wipe the old region (markers + overlay)
      (delete-overlay (plist-get entry :detail-ov))
      (delete-region (plist-get entry :start) (plist-get entry :end))
      (set-marker (plist-get entry :start) nil)
      (set-marker (plist-get entry :end) nil))
    (save-excursion
      (goto-char seance-chat--output-marker)
      (let ((start (point-marker)))
        (set-marker-insertion-type start nil)
        (insert (propertize (concat header "\n")
                            'seance-tool-id id 'read-only t
                            'front-sticky '(read-only) 'rear-nonsticky t))
        (let ((dstart (point)))
          (unless (string-empty-p detail)
            (insert (propertize (concat detail "\n")
                                'seance-tool-id id 'read-only t
                                'front-sticky '(read-only) 'rear-nonsticky t)))
          (let ((ov (make-overlay dstart (point)))
                (end (point-marker)))
            (overlay-put ov 'invisible
                         (if entry  ; preserve user's toggle state across updates
                             (overlay-get (plist-get entry :detail-ov) 'invisible)
                           t))
            (overlay-put ov 'evaporate nil)
            (puthash id (list :start start :end end :detail-ov ov)
                     seance-chat--tool-regions)))))))

(defun seance-chat-toggle-detail ()
  "Toggle visibility of the tool-call detail at point."
  (interactive)
  (if-let* ((id (get-text-property (line-beginning-position) 'seance-tool-id))
            (entry (gethash id seance-chat--tool-regions))
            (ov (plist-get entry :detail-ov)))
      (overlay-put ov 'invisible (not (overlay-get ov 'invisible)))
    (message "seance: no tool call at point")))

(defun seance-chat--render-plan (update)
  "Render UPDATE's plan block, replacing the previous one in place."
  (seance-chat--close-block)
  (let* ((text (concat "Plan\n"
                       (mapconcat
                        (lambda (e)
                          (format " %s %s"
                                  (pcase (plist-get e :status)
                                    ("completed" "☑")
                                    ("in_progress" "◐")
                                    (_ "☐"))
                                  (plist-get e :content)))
                        (append (plist-get update :entries) nil) "\n")
                       "\n"))
         (inhibit-read-only t))
    (when seance-chat--plan-start
      (delete-region seance-chat--plan-start seance-chat--plan-end)
      (set-marker seance-chat--plan-start nil)
      (set-marker seance-chat--plan-end nil))
    (save-excursion
      (goto-char seance-chat--output-marker)
      (let ((start (point-marker)))
        (set-marker-insertion-type start nil)
        (insert (propertize text 'read-only t
                            'front-sticky '(read-only) 'rear-nonsticky t
                            'face 'seance-thought-face))
        (setq seance-chat--plan-start start
              seance-chat--plan-end (point-marker))))))

;; --- waiting-for-permission marker -----------------------------------------

;; seance-chat deliberately does not require seance-review (review requires
;; acp; chat stays out of that cluster).  These `defvar's keep the
;; byte-compiler quiet; the notifiers register once review is loaded below.
(defvar seance-review-on-pending)
(defvar seance-review-on-answered)
(defvar seance-review-permission-buffer)

(defvar-local seance-chat--permission-region nil
  "Cons (START . END) of markers around the waiting-for-permission line.")

(defun seance-chat--live-chat-buffer ()
  "Return the live, initialized chat buffer, or nil."
  (when-let* ((buf (get-buffer seance-chat-buffer-name)))
    (and (buffer-live-p buf)
         (buffer-local-value 'seance-chat--output-marker buf)
         buf)))

(defun seance-chat--permission-pending (title)
  "Show a waiting-for-permission line for the tool call TITLE.
Replaces any marker still present from an overlapping earlier request."
  (when-let* ((buf (seance-chat--live-chat-buffer)))
    (with-current-buffer buf
      (seance-chat--permission-answered)
      (let ((start (copy-marker seance-chat--output-marker nil)))
        (seance-chat--insert-output
         (propertize
          (format "⏸ Codex requests: %s — C-c C-c allow · C-c C-d deny · C-c C-v diff\n"
                  title)
          'face 'seance-thought-face))
        (setq seance-chat--permission-region
              (cons start (copy-marker seance-chat--output-marker nil)))))))

(defun seance-chat--permission-answered ()
  "Remove the waiting-for-permission line from the chat transcript."
  (when-let* ((buf (seance-chat--live-chat-buffer)))
    (with-current-buffer buf
      (when seance-chat--permission-region
        (let ((inhibit-read-only t)
              (start (car seance-chat--permission-region))
              (end (cdr seance-chat--permission-region)))
          (delete-region start end)
          (set-marker start nil)
          (set-marker end nil))
        (setq seance-chat--permission-region nil)))))

(with-eval-after-load 'seance-review
  (setq seance-review-on-pending #'seance-chat--permission-pending
        seance-review-on-answered #'seance-chat--permission-answered))

;; Chat-side answer commands.  They run the review commands inside the
;; permission buffer, so the user never has to leave the chat window.
;; seance-review is necessarily loaded whenever a request is pending (the
;; permission buffer exists only then), hence the guarded declarations.
(declare-function seance-review-allow "seance-review" ())
(declare-function seance-review-deny "seance-review" ())

(defun seance-chat--permission-buffer ()
  "Return the buffer holding the pending permission request, or signal.
The buffer exists exactly while a request is pending; when seance-review
was never loaded there cannot be one."
  (or (and (boundp 'seance-review-permission-buffer)
           (get-buffer seance-review-permission-buffer))
      (user-error "seance: no pending permission request")))

(defun seance-chat-approve ()
  "Allow the pending tool call without leaving the chat buffer."
  (interactive)
  (with-current-buffer (seance-chat--permission-buffer)
    (seance-review-allow)))

(defun seance-chat-deny ()
  "Deny the pending tool call without leaving the chat buffer."
  (interactive)
  (with-current-buffer (seance-chat--permission-buffer)
    (seance-review-deny)))

(defun seance-chat-show-permission ()
  "Display the pending permission diff in the right side window.
The window no longer pops up automatically (unless
`seance-permission-popup' is set); this brings it up on demand."
  (interactive)
  (display-buffer (seance-chat--permission-buffer)
                  '(display-buffer-in-side-window (side . right))))

;; --- bindings: one table drives the keymap AND the ? help ----------------

(require 'seance-keys)

(defvar seance-keys-chat-table
  '((input
     ("RET" seance-chat-send "Send prompt")
     ("S-<return>" seance-chat-newline "Insert newline")
     ("M-p" seance-chat-history-prev "Previous input")
     ("M-n" seance-chat-history-next "Next input"))
    (conversation
     ("TAB" seance-chat-toggle-thought "Toggle thought/tool detail at point")
     ("C-c C-k" seance-chat-cancel "Cancel current turn"))
    (permission
     ("C-c C-c" seance-chat-approve "Allow pending tool call")
     ("C-c C-d" seance-chat-deny "Deny pending tool call")
     ("C-c C-v" seance-chat-show-permission "Show pending permission diff"))
    (session
     ("C-c C-p" seance-toggle-permission-mode "Toggle gated/auto")
     ("C-c C-r" seance-review "Open session review")
     ("C-c C-q" seance-stop "Stop session")))
  "Binding table for `seance-chat-mode' (drives keymap AND ? help).")

(seance-keys-apply seance-keys-chat-table seance-chat-mode-map)
(seance-keys-make-help 'seance-chat-help "seance chat bindings"
                       seance-keys-chat-table)

;; The transient prefix above is defined at load time via `eval'; the
;; byte-compiler cannot see it, hence the declaration.
(declare-function seance-chat-help "seance-chat")

(defun seance-chat-help-or-self-insert (n)
  "Open the binding help, unless point is in the input field (then type ?).
N is the prefix-argument repeat count for `self-insert-command'."
  (interactive "p")
  (if (and seance-chat--prompt-marker
           (>= (point) seance-chat--prompt-marker))
      (self-insert-command n ??)
    (seance-chat-help)))

(define-key seance-chat-mode-map (kbd "?") #'seance-chat-help-or-self-insert)

(provide 'seance-chat)
;;; seance-chat.el ends here
