;;; seance-chat.el --- seance chat buffer -*- lexical-binding: t; -*-

;;; Commentary:
;; The chat major mode: transcript (read-only text properties) + an
;; editable input field at the end of the buffer.  Agent output streams
;; in just above the input prompt.

;;; Code:

(require 'cl-lib)
(require 'seance-acp)
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

(defun seance-chat--initialize ()
  "Insert the initial prompt and connect a session for this buffer."
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
                          (with-current-buffer buf (force-mode-line-update))))))))

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
  "Close the current streaming block, if any, with a blank-line separator."
  (when seance-chat--block
    (seance-chat--insert-output "\n\n")
    (setq seance-chat--block nil)))

(defun seance-chat--end-turn (err)
  "Close the streaming block at turn end; render ERR if non-nil."
  (seance-chat--close-block)
  (when err
    (seance-chat--insert-output (format "[error] %s\n\n" err))))

(defun seance-chat--prepare-prompt (text)
  "Return TEXT as the prompt to send (context injection hook, Task 12)."
  text)

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
  "Append TEXT to the current streaming block of TYPE (message/thought)."
  (when text
    (unless (eq seance-chat--block type)
      (unless (null seance-chat--block)
        (seance-chat--insert-output "\n\n"))
      (setq seance-chat--block type))
    (seance-chat--insert-output
     (if (eq type 'thought)
         (propertize text 'face 'seance-thought-face)
       text))))

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

;; keybindings are centralized in seance-keys.el (Task 6); minimal set now:
(define-key seance-chat-mode-map (kbd "RET") #'seance-chat-send)
(define-key seance-chat-mode-map (kbd "S-<return>") #'seance-chat-newline)
(define-key seance-chat-mode-map (kbd "M-p") #'seance-chat-history-prev)
(define-key seance-chat-mode-map (kbd "M-n") #'seance-chat-history-next)
(define-key seance-chat-mode-map (kbd "C-c C-k") #'seance-chat-cancel)
(define-key seance-chat-mode-map (kbd "TAB") #'seance-chat-toggle-detail)

(provide 'seance-chat)
;;; seance-chat.el ends here
