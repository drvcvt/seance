;;; seance-acp.el --- ACP protocol core -*- lexical-binding: t; -*-

;;; Commentary:
;; Owns the adapter subprocess and the ACP session lifecycle. No UI here:
;; consumers register :on-update / :on-status callbacks.

;;; Code:

(require 'cl-lib)
(require 'seance)
(require 'seance-rpc)

(defvar seance-acp--fs-read-function nil
  "When set, (fn PATH) -> string; serves fs/read_text_file.  Set in Task 8.")
(defvar seance-acp--fs-write-function nil
  "When set, (fn PATH CONTENT); serves fs/write_text_file.  Set in Task 8.")
(defvar seance-acp--permission-function nil
  "When set, (fn SESSION PARAMS REPLY); serves session/request_permission.
Set in Task 7.  Until then requests are answered with the first option.")
(defvar seance-acp--mcp-servers-function nil
  "When set, (fn) -> vector of MCP server specs for session/new.  Task 12.")

(cl-defstruct (seance-acp-session (:constructor seance-acp-session--make))
  "State for one ACP session backed by an adapter subprocess.
RPC is the underlying `seance-rpc' connection, ID the agent-assigned
session id, CWD the session's working directory.  STATUS is one of
`connecting', `idle', `thinking', `error', `disconnected'."
  rpc id cwd
  (permission-mode seance-permission-mode)
  (status 'connecting)
  (preamble-sent nil)
  on-update    ; (fn UPDATE-PLIST)
  on-status)   ; (fn STATUS-SYMBOL)

(defvar seance-acp--session nil
  "The current (single, v1) session.")

(defun seance-acp--set-status (sess status)
  "Set SESS's status to STATUS and notify its on-status callback."
  (setf (seance-acp-session-status sess) status)
  (when-let* ((fn (seance-acp-session-on-status sess)))
    (funcall fn status)))

(defun seance-acp-connect (cwd &rest opts)
  "Spawn the adapter and open an ACP session rooted at CWD.
OPTS: :on-update :on-status :on-ready (each optional)."
  (let* ((sess (seance-acp-session--make
                :cwd (expand-file-name cwd)
                :on-update (plist-get opts :on-update)
                :on-status (plist-get opts :on-status)))
         (rpc (seance-rpc-start
               seance-codex-acp-command
               :name "seance-acp"
               :notifier (lambda (method params)
                           (seance-acp--notification sess method params))
               :handler (lambda (method params reply)
                          (seance-acp--client-request sess method params reply))
               :on-exit (lambda (_event)
                          (seance-acp--set-status sess 'disconnected)))))
    (setf (seance-acp-session-rpc sess) rpc)
    (seance-rpc-request
     rpc "initialize"
     '(:protocolVersion 1
       :clientCapabilities (:fs (:readTextFile t :writeTextFile t)))
     (lambda (_result error)
       (if error
           (seance-acp--set-status sess 'error)
         (seance-rpc-request
          rpc "session/new"
          `(:cwd ,(seance-acp-session-cwd sess)
            :mcpServers ,(if seance-acp--mcp-servers-function
                             (funcall seance-acp--mcp-servers-function)
                           []))
          (lambda (result error)
            (if error
                (seance-acp--set-status sess 'error)
              (setf (seance-acp-session-id sess)
                    (plist-get result :sessionId))
              (seance-acp--set-status sess 'idle)
              (when-let* ((fn (plist-get opts :on-ready)))
                (funcall fn sess))))))))
    (setq seance-acp--session sess)
    sess))

(defun seance-acp-prompt (sess text &optional callback)
  "Send TEXT as a prompt turn on SESS.
CALLBACK gets (RESULT ERROR) at turn end."
  (seance-acp--set-status sess 'thinking)
  (seance-rpc-request
   (seance-acp-session-rpc sess) "session/prompt"
   `(:sessionId ,(seance-acp-session-id sess)
     :prompt ,(vector `(:type "text" :text ,text)))
   (lambda (result error)
     (seance-acp--set-status sess (if error 'error 'idle))
     (when callback (funcall callback result error)))))

(defun seance-acp-cancel (sess)
  "Cancel SESS's in-flight turn."
  (seance-rpc-notify (seance-acp-session-rpc sess) "session/cancel"
                     `(:sessionId ,(seance-acp-session-id sess))))

(defun seance-acp-disconnect (sess)
  "Shut down SESS's adapter subprocess and mark it disconnected."
  (seance-rpc-shutdown (seance-acp-session-rpc sess))
  (seance-acp--set-status sess 'disconnected))

(defun seance-acp--notification (sess method params)
  "Dispatch agent notification METHOD with PARAMS for SESS."
  (pcase method
    ("session/update"
     (when-let* ((fn (seance-acp-session-on-update sess)))
       (funcall fn (plist-get params :update))))))

(defun seance-acp--client-request (sess method params reply)
  "Serve agent-to-client request METHOD with PARAMS for SESS via REPLY."
  (pcase method
    ("session/request_permission"
     (if seance-acp--permission-function
         (funcall seance-acp--permission-function sess params reply)
       ;; placeholder until Task 7: pick the first option
       (funcall reply
                `(:outcome (:outcome "selected"
                            :optionId ,(plist-get (aref (plist-get params :options) 0)
                                                  :optionId))))))
    ("fs/read_text_file"
     (condition-case err
         (funcall reply `(:content ,(funcall (or seance-acp--fs-read-function
                                                 #'seance-acp--read-file-fallback)
                                             (plist-get params :path))))
       (error (funcall reply nil `(:code -32603
                                   :message ,(error-message-string err))))))
    ("fs/write_text_file"
     (condition-case err
         (progn
           (funcall (or seance-acp--fs-write-function
                        #'seance-acp--write-file-fallback)
                    (plist-get params :path) (plist-get params :content))
           (funcall reply nil))
       (error (funcall reply nil `(:code -32603
                                   :message ,(error-message-string err))))))
    (_ (funcall reply nil `(:code -32601
                            :message ,(format "Method not found: %s" method))))))

(defun seance-acp--read-file-fallback (path)
  "Return the contents of PATH as a string."
  (with-temp-buffer (insert-file-contents path) (buffer-string)))

(defun seance-acp--write-file-fallback (path content)
  "Write CONTENT to PATH, silently."
  (write-region content nil path nil 'silent))

(provide 'seance-acp)
;;; seance-acp.el ends here
