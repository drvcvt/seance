;;; seance-rpc.el --- ndjson JSON-RPC 2.0 over stdio -*- lexical-binding: t; -*-

;;; Commentary:
;; Thin JSON-RPC transport: newline-delimited JSON over a subprocess.
;; Supports requests with async callbacks, notifications both ways, and
;; ASYNC replies to incoming requests (handler receives a REPLY closure).

;;; Code:

(require 'cl-lib)
(require 'json)

(cl-defstruct (seance-rpc (:constructor seance-rpc--make))
  "State for one ndjson JSON-RPC connection to a subprocess."
  process
  (next-id 0)
  (pending (make-hash-table :test #'eql))
  handler   ; (fn METHOD PARAMS REPLY); REPLY: (funcall reply RESULT &optional ERROR)
  notifier  ; (fn METHOD PARAMS)
  on-exit
  (residue ""))

(defun seance-rpc--parse (line)
  "Parse LINE as a JSON object into a plist."
  (json-parse-string line :object-type 'plist
                     :null-object nil :false-object :json-false))

(defun seance-rpc--send (rpc msg)
  "Serialize plist MSG and send it to RPC's subprocess as one line.
Serializes `:json-false' as false, mirroring `seance-rpc--parse', so
parsed values can round-trip back out."
  (process-send-string (seance-rpc-process rpc)
                       (concat (json-serialize msg :false-object :json-false)
                               "\n")))

(defun seance-rpc-request (rpc method params callback)
  "Send request METHOD with PARAMS plist over RPC; return the request id.
CALLBACK is called as (RESULT ERROR) when the response arrives."
  (let ((id (cl-incf (seance-rpc-next-id rpc))))
    (puthash id callback (seance-rpc-pending rpc))
    (seance-rpc--send rpc (append `(:jsonrpc "2.0" :id ,id :method ,method)
                                  (and params `(:params ,params))))
    id))

(defun seance-rpc-notify (rpc method params)
  "Send notification METHOD with PARAMS plist over RPC (no response expected)."
  (seance-rpc--send rpc (append `(:jsonrpc "2.0" :method ,method)
                                (and params `(:params ,params)))))

(defun seance-rpc--dispatch (rpc msg)
  "Route one parsed message plist MSG for RPC."
  (let ((id (plist-get msg :id))
        (method (plist-get msg :method)))
    (cond
     ((and method id)                   ; incoming request
      (let ((replied nil))
        (condition-case err
            (funcall (seance-rpc-handler rpc) method (plist-get msg :params)
                     (lambda (result &optional error)
                       (unless replied
                         (setq replied t)
                         (seance-rpc--send
                          rpc (if error
                                  `(:jsonrpc "2.0" :id ,id :error ,error)
                                `(:jsonrpc "2.0" :id ,id
                                  :result ,(or result :null)))))))
          (error
           (message "seance-rpc: handler error on %s: %s"
                    method (error-message-string err))
           (unless replied
             (setq replied t)
             (seance-rpc--send
              rpc `(:jsonrpc "2.0" :id ,id
                    :error (:code -32603
                            :message ,(error-message-string err)))))))))
     (method                            ; notification
      (funcall (seance-rpc-notifier rpc) method (plist-get msg :params)))
     (id                                ; response to our request
      (when-let* ((cb (gethash id (seance-rpc-pending rpc))))
        (remhash id (seance-rpc-pending rpc))
        (funcall cb (plist-get msg :result) (plist-get msg :error)))))))

(defun seance-rpc--filter (rpc string)
  "Accumulate STRING into RPC's residue; dispatch each complete line."
  (let* ((data (concat (seance-rpc-residue rpc) string))
         (lines (split-string data "\n")))
    (setf (seance-rpc-residue rpc) (car (last lines)))
    (dolist (line (butlast lines))
      (unless (string-empty-p line)
        (condition-case err
            (seance-rpc--dispatch rpc (seance-rpc--parse line))
          (error (message "seance-rpc: bad message dropped: %s"
                          (error-message-string err))))))))

(defun seance-rpc--fail-pending (rpc)
  "Reject every pending callback on RPC with a connection-closed error.
Clears the pending table first, so repeated calls are no-ops."
  (let ((pending (seance-rpc-pending rpc))
        (callbacks nil))
    (maphash (lambda (_id cb) (push cb callbacks)) pending)
    (clrhash pending)
    (dolist (cb callbacks)
      (funcall cb nil '(:code -32000 :message "seance-rpc: connection closed")))))

(defun seance-rpc-start (command &rest opts)
  "Start subprocess COMMAND (list of strings); return a `seance-rpc'.
OPTS plist: :handler :notifier :on-exit :name."
  (let* ((rpc (seance-rpc--make
               :handler (or (plist-get opts :handler) #'ignore)
               :notifier (or (plist-get opts :notifier) #'ignore)
               :on-exit (plist-get opts :on-exit)))
         (name (or (plist-get opts :name) "seance-rpc"))
         (proc (make-process
                :name name
                :command command
                :connection-type 'pipe
                :coding 'utf-8-unix
                :noquery t
                :stderr (get-buffer-create (format " *%s-stderr*" name))
                :filter (lambda (_p s) (seance-rpc--filter rpc s))
                :sentinel (lambda (p event)
                            (unless (process-live-p p)
                              (seance-rpc--fail-pending rpc))
                            (when-let* ((fn (seance-rpc-on-exit rpc)))
                              (funcall fn event))))))
    (setf (seance-rpc-process rpc) proc)
    rpc))

(defun seance-rpc-alive-p (rpc)
  "Return non-nil if RPC's subprocess is live."
  (and rpc (seance-rpc-process rpc)
       (process-live-p (seance-rpc-process rpc))))

(defun seance-rpc-shutdown (rpc)
  "Kill RPC's subprocess without firing its on-exit callback."
  (when (seance-rpc-alive-p rpc)
    (setf (seance-rpc-on-exit rpc) nil)
    (delete-process (seance-rpc-process rpc)))
  (seance-rpc--fail-pending rpc))

(provide 'seance-rpc)
;;; seance-rpc.el ends here
