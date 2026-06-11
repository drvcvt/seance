;;; mock-agent.el --- scripted ACP agent for seance tests
;; Plays the agent side of ACP over stdio (ndjson). Scenario comes from
;; the SEANCE_MOCK_SCENARIO env var:
;; echo | tools | permission | fs | init-error.

(require 'json)
(require 'cl-lib)

(defvar mock-scenario (or (getenv "SEANCE_MOCK_SCENARIO") "echo"))
(defvar mock-next-id 1000)
(defvar mock-pending nil)  ; alist: our-request-id -> continuation (fn RESULT)

(defun mock-send (msg)
  (send-string-to-terminal
   (concat (json-serialize msg :false-object :json-false) "\n")))

(defun mock-result (id result)
  (mock-send `(:jsonrpc "2.0" :id ,id :result ,result)))

(defun mock-update (sid update)
  (mock-send `(:jsonrpc "2.0" :method "session/update"
               :params (:sessionId ,sid :update ,update))))

(defun mock-request (method params k)
  "Send a request to the client; call K with the result when it answers."
  (let ((id (cl-incf mock-next-id)))
    (push (cons id k) mock-pending)
    (mock-send `(:jsonrpc "2.0" :id ,id :method ,method :params ,params))))

(defun mock-end-turn (id)
  (mock-result id '(:stopReason "end_turn")))

(defun mock-prompt-text (params)
  (plist-get (aref (plist-get params :prompt) 0) :text))

(defun mock-run-scenario (id sid params)
  (pcase mock-scenario
    ("echo"
     (mock-update sid `(:sessionUpdate "agent_message_chunk"
                        :content (:type "text"
                                  :text ,(concat "echo: " (mock-prompt-text params)))))
     (mock-end-turn id))
    ("tools"
     (mock-update sid '(:sessionUpdate "tool_call" :toolCallId "tc-1"
                        :title "edit hello.el" :kind "edit" :status "pending"))
     (mock-update sid '(:sessionUpdate "tool_call_update" :toolCallId "tc-1"
                        :status "completed"
                        :content [(:type "diff" :path "hello.el"
                                   :oldText "old line\n" :newText "new line\n")]))
     (mock-update sid '(:sessionUpdate "plan"
                        :entries [(:content "step one" :priority "high" :status "completed")
                                  (:content "step two" :priority "high" :status "pending")]))
     (mock-update sid '(:sessionUpdate "agent_message_chunk"
                        :content (:type "text" :text "done")))
     (mock-end-turn id))
    ("permission"
     (mock-request
      "session/request_permission"
      `(:sessionId ,sid
        :toolCall (:toolCallId "tc-p1" :title "edit guarded.el" :kind "edit"
                   :content [(:type "diff" :path "guarded.el"
                              :oldText "before\n" :newText "after\n")])
        :options [(:optionId "opt-allow" :name "Allow" :kind "allow_once")
                  (:optionId "opt-allow-always" :name "Always" :kind "allow_always")
                  (:optionId "opt-reject" :name "Reject" :kind "reject_once")])
      (lambda (result)
        ;; RESULT is nil when the client answered with an error; report
        ;; "picked: none" so the turn still ends.
        (let ((opt (or (plist-get (plist-get result :outcome) :optionId)
                       "none")))
          (mock-update "mock-session"
                       `(:sessionUpdate "agent_message_chunk"
                         :content (:type "text" :text ,(concat "picked: " opt))))
          (mock-end-turn (get 'mock-state 'prompt-id)))))
     (put 'mock-state 'prompt-id id))
    ("fs"
     ;; prompt text is a file path: read it via the client, write it back
     ;; uppercased, echo the original content.
     (let ((path (mock-prompt-text params)))
       (mock-request
        "fs/read_text_file" `(:sessionId ,sid :path ,path)
        (lambda (result)
          ;; RESULT is nil when the read failed; skip the write, report the
          ;; failure, and still end the turn so client tests cannot hang.
          (let ((content (and result (plist-get result :content))))
            (if (null content)
                (progn
                  (mock-update "mock-session"
                               '(:sessionUpdate "agent_message_chunk"
                                 :content (:type "text" :text "read-error")))
                  (mock-end-turn (get 'mock-state 'prompt-id)))
              (mock-request
               "fs/write_text_file"
               `(:sessionId ,sid :path ,path :content ,(upcase content))
               (lambda (_)
                 (mock-update "mock-session"
                              `(:sessionUpdate "agent_message_chunk"
                                :content (:type "text" :text ,(concat "read: " content))))
                 (mock-end-turn (get 'mock-state 'prompt-id))))))))
       (put 'mock-state 'prompt-id id)))))

(defun mock-handle (msg)
  (let ((id (plist-get msg :id))
        (method (plist-get msg :method)))
    (cond
     ;; response to one of OUR requests; error responses continue with nil
     ((and id (not method))
      (when-let* ((entry (assq id mock-pending)))
        (setq mock-pending (delq entry mock-pending))
        (funcall (cdr entry) (and (not (plist-get msg :error))
                                  (plist-get msg :result)))))
     ((equal method "initialize")
      (if (equal mock-scenario "init-error")
          (mock-send (list :jsonrpc "2.0" :id id
                           :error '(:code -32600 :message "nope")))
        (mock-result id '(:protocolVersion 1
                          :agentCapabilities (:loadSession :json-false)))))
     ((equal method "session/new")
      (mock-result id '(:sessionId "mock-session")))
     ((equal method "session/prompt")
      (mock-run-scenario id (plist-get (plist-get msg :params) :sessionId)
                         (plist-get msg :params)))
     (id (mock-result id :null)))))

(while t
  (let ((line (condition-case nil (read-from-minibuffer "")
                (error (kill-emacs 0)))))
    (when (> (length line) 0)
      (mock-handle (json-parse-string line :object-type 'plist
                                      :null-object nil :false-object :json-false)))))
