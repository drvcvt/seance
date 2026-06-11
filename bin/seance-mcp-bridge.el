;;; seance-mcp-bridge.el --- MCP stdio server bridging into a running Emacs -*- lexical-binding: t; -*-

;;; Commentary:
;; Usage: emacs --batch --script bin/seance-mcp-bridge.el
;; Env: SEANCE_SERVER = Emacs server socket name or ABSOLUTE socket path
;;      (default "server").  emacsclient -s accepts both: a bare name is
;;      resolved against its default socket dir, a path is used as-is, so
;;      the host Emacs passes the full socket path to stay correct even
;;      when `server-socket-dir' is non-default.
;; Speaks MCP (ndjson JSON-RPC, protocol 2025-06-18) on stdio; forwards
;; tools/call into the running Emacs via emacsclient --eval
;; (seance-bridge-dispatch ...).  stdout carries ONLY protocol lines.

;;; Code:

(require 'json)

(defvar bridge-server (or (getenv "SEANCE_SERVER") "server")
  "Emacs server socket name or absolute socket path to dial.")

(defconst bridge-tools
  '[(:name "emacs_eval"
     :description "Evaluate an Emacs Lisp form in the user's RUNNING Emacs and return the printed result. Use this to test code live, reload changed files with (load ...), or inspect editor state."
     :inputSchema (:type "object"
                   :properties (:form (:type "string"
                                       :description "An Elisp form, e.g. (buffer-name)"))
                   :required ["form"]))
    (:name "emacs_buffer_list"
     :description "List all live buffers in the running Emacs: name, major mode, visited file, modified flag."
     :inputSchema (:type "object"))
    (:name "emacs_buffer_get"
     :description "Return the full text content of a named buffer in the running Emacs (including unsaved changes)."
     :inputSchema (:type "object"
                   :properties (:name (:type "string" :description "Buffer name"))
                   :required ["name"]))
    (:name "emacs_describe"
     :description "Documentation, arity and source location for an Emacs Lisp function or variable, like describe-function/describe-variable."
     :inputSchema (:type "object"
                   :properties (:symbol (:type "string" :description "Symbol name, e.g. find-file"))
                   :required ["symbol"]))
    (:name "emacs_state"
     :description "Snapshot of the running Emacs: version, selected buffer and mode, seance source location, recent *Messages*."
     :inputSchema (:type "object"))]
  "Static MCP tool definitions, mirroring `seance-bridge--run'.")

(defun bridge-send (msg)
  "Serialize plist MSG and write it to stdout as one ndjson line."
  (send-string-to-terminal
   (concat (json-serialize msg :false-object :json-false) "\n")))

(defun bridge-emacsclient (tool args-json)
  "Forward TOOL/ARGS-JSON into the running Emacs; return parsed result plist."
  (with-temp-buffer
    (let ((status (call-process "emacsclient" nil t nil
                                "-s" bridge-server "--eval"
                                (format "(seance-bridge-dispatch %S %S)"
                                        tool (or args-json "")))))
      (unless (eql status 0)
        (error "emacsclient failed (%s): %s" status (buffer-string)))
      ;; emacsclient prints the elisp value: a QUOTED elisp string
      ;; containing JSON; read-from-string recovers the JSON string.
      (json-parse-string (car (read-from-string (buffer-string)))
                         :object-type 'plist
                         :null-object nil :false-object nil))))

(defun bridge-handle (msg)
  "Dispatch one parsed MCP message plist MSG."
  (let ((id (plist-get msg :id))
        (method (plist-get msg :method))
        (params (plist-get msg :params)))
    (pcase method
      ("initialize"
       (bridge-send
        `(:jsonrpc "2.0" :id ,id
          :result (:protocolVersion "2025-06-18"
                   :capabilities (:tools (:listChanged :json-false))
                   :serverInfo (:name "seance-emacs" :version "0.1.0")))))
      ("notifications/initialized" nil)
      ("tools/list"
       (bridge-send `(:jsonrpc "2.0" :id ,id :result (:tools ,bridge-tools))))
      ("tools/call"
       (condition-case err
           (let* ((args (plist-get params :arguments))
                  (res (bridge-emacsclient (plist-get params :name)
                                           (and args (json-serialize
                                                      args :false-object :json-false)))))
             (bridge-send
              `(:jsonrpc "2.0" :id ,id
                :result (:content [(:type "text" :text ,(or (plist-get res :value) ""))]
                         :isError ,(if (eq (plist-get res :ok) t) :json-false t)))))
         (error
          (bridge-send
           `(:jsonrpc "2.0" :id ,id
             :result (:content [(:type "text" :text ,(error-message-string err))]
                      :isError t))))))
      (_ (when id
           (bridge-send `(:jsonrpc "2.0" :id ,id
                          :error (:code -32601 :message "Method not found"))))))))

;; Main loop: one JSON message per stdin line; EOF exits cleanly.
(while t
  (let ((line (condition-case nil (read-from-minibuffer "")
                (error (kill-emacs 0)))))
    (when (> (length line) 0)
      (bridge-handle (json-parse-string line :object-type 'plist
                                        :null-object nil
                                        :false-object :json-false)))))

;;; seance-mcp-bridge.el ends here
