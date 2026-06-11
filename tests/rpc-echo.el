;;; rpc-echo.el --- minimal JSON-RPC echo server for tests
;; Responds to any request with {"echo": <method>}. ndjson over stdio.
;; NOTE: send-string-to-terminal writes unbuffered; princ may be
;; block-buffered when stdout is a pipe.

(require 'json)

(while t
  (let ((line (condition-case nil (read-from-minibuffer "")
                (error (kill-emacs 0)))))
    (when (> (length line) 0)
      (let* ((msg (json-parse-string line :object-type 'plist
                                     :null-object nil :false-object :json-false))
             (id (plist-get msg :id)))
        (when id
          (send-string-to-terminal
           (concat (json-serialize
                    `(:jsonrpc "2.0" :id ,id
                      :result (:echo ,(plist-get msg :method))))
                   "\n")))))))
