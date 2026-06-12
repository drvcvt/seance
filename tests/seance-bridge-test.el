;;; seance-bridge-test.el --- tests for seance-bridge -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'seance-test-helpers)
(require 'seance-acp)
(require 'seance-bridge)

(defun seance-bridge-test--call (tool args-plist)
  "Call dispatch like emacsclient would; return parsed (:ok :value) plist."
  (json-parse-string
   (seance-bridge-dispatch tool (and args-plist (json-serialize args-plist)))
   :object-type 'plist :null-object nil :false-object nil))

(ert-deftest seance-bridge-eval-returns-printed-result ()
  (let ((seance-permission-mode 'auto)
        (seance-acp--session nil))
    (let ((res (seance-bridge-test--call "emacs_eval" '(:form "(+ 1 2)"))))
      (should (eq (plist-get res :ok) t))
      (should (equal (plist-get res :value) "3")))))

(ert-deftest seance-bridge-eval-error-is-structured ()
  (let ((seance-permission-mode 'auto)
        (seance-acp--session nil))
    (let ((res (seance-bridge-test--call "emacs_eval" '(:form "(error \"boom\")"))))
      (should-not (plist-get res :ok))
      (should (string-match-p "boom" (plist-get res :value))))))

(ert-deftest seance-bridge-buffer-list-and-get ()
  (with-current-buffer (get-buffer-create "*seance-bridge-probe*")
    (erase-buffer)
    (insert "probe content"))
  (let ((res (seance-bridge-test--call "emacs_buffer_list" nil)))
    (should (string-match-p "\\*seance-bridge-probe\\*" (plist-get res :value))))
  (let ((res (seance-bridge-test--call "emacs_buffer_get"
                                       '(:name "*seance-bridge-probe*"))))
    (should (equal (plist-get res :value) "probe content")))
  (kill-buffer "*seance-bridge-probe*"))

(ert-deftest seance-bridge-describe-function ()
  (let ((res (seance-bridge-test--call "emacs_describe" '(:symbol "car"))))
    (should (eq (plist-get res :ok) t))
    (should (string-match-p "Function:" (plist-get res :value)))))

(ert-deftest seance-bridge-unknown-tool-errors ()
  (let ((res (seance-bridge-test--call "emacs_frobnicate" nil)))
    (should-not (plist-get res :ok))))

(ert-deftest seance-bridge-eval-gated-denied ()
  "In gated mode with the user answering no, eval must be refused."
  (let ((seance-permission-mode 'gated)
        (seance-acp--session nil))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_prompt) nil)))
      (let ((res (seance-bridge-test--call "emacs_eval" '(:form "(+ 1 1)"))))
        (should-not (plist-get res :ok))
        (should (string-match-p "denied" (plist-get res :value)))))))

(ert-deftest seance-bridge-eval-trailing-form-rejected ()
  "A form string with two sexps must error with a message about trailing content."
  (let ((seance-permission-mode 'auto)
        (seance-acp--session nil))
    (let ((res (seance-bridge-test--call "emacs_eval" '(:form "(+ 1 2) (+ 3 4)"))))
      (should (eq (plist-get res :ok) nil))
      (should (string-match-p "trailing" (plist-get res :value))))))

(ert-deftest seance-bridge-eval-trailing-whitespace-ok ()
  "A form with only trailing whitespace/newline must be accepted."
  (let ((seance-permission-mode 'auto)
        (seance-acp--session nil))
    (let ((res (seance-bridge-test--call "emacs_eval" '(:form "(+ 1 2)\n  "))))
      (should (eq (plist-get res :ok) t))
      (should (equal (plist-get res :value) "3")))))

(ert-deftest seance-bridge-eval-gated-logs-full-form ()
  "In gated mode, message must be called with the full form string before consent."
  (let ((seance-permission-mode 'gated)
        (seance-acp--session nil)
        (captured-messages nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) captured-messages)))
              ((symbol-function 'y-or-n-p) (lambda (_prompt) t)))
      (seance-bridge-test--call "emacs_eval" '(:form "(+ 10 20)")))
    (should (cl-some (lambda (s) (string-search "(+ 10 20)" s))
                     captured-messages))))

;;; MCP server spec (seance-bridge-mcp-servers)

(ert-deftest seance-bridge-mcp-servers-disabled ()
  "With the bridge disabled, no MCP servers are offered."
  (let ((seance-enable-bridge nil))
    (should (equal (seance-bridge-mcp-servers) []))))

(ert-deftest seance-bridge-mcp-servers-batch-without-server ()
  "In noninteractive Emacs with no running server, never auto-start one."
  (let ((seance-enable-bridge t)
        (started nil))
    (cl-letf (((symbol-function 'seance-bridge--server-live-p) (lambda () nil))
              ((symbol-function 'server-start)
               (lambda (&rest _) (setq started t))))
      (should (equal (seance-bridge-mcp-servers) []))
      (should-not started))))

(ert-deftest seance-bridge-mcp-servers-spec ()
  "Enabled + live server: one spec pointing at the bridge script.
SEANCE_SERVER carries the ABSOLUTE socket path (emacsclient -s accepts
a path), so the spec stays correct under non-default socket dirs."
  (let ((seance-enable-bridge t)
        (server-name "stub-server")
        (server-socket-dir "/tmp/stub-socket-dir"))
    (cl-letf (((symbol-function 'seance-bridge--server-live-p) (lambda () t))
              ((symbol-function 'server-start)
               (lambda (&rest _) (error "server-start must not be called"))))
      (let ((servers (seance-bridge-mcp-servers)))
        (should (= (length servers) 1))
        (let* ((spec (aref servers 0))
               (args (append (plist-get spec :args) nil)))
          (should (equal (plist-get spec :name) "seance-emacs"))
          (should (string-suffix-p "bin/seance-mcp-bridge.el" (car (last args))))
          (should (equal (aref (plist-get spec :env) 0)
                         '(:name "SEANCE_SERVER"
                           :value "/tmp/stub-socket-dir/stub-server"))))))))

(ert-deftest seance-bridge-mcp-servers-socket-collision ()
  "Another process owns the default socket: switch to a dedicated name.
The fix must rename to seance-<pid> BEFORE server-start, and the spec's
SEANCE_SERVER env must point at the renamed socket, not the foreign one."
  (let ((seance-enable-bridge t)
        (noninteractive nil)
        (server-name "server")
        (server-socket-dir "/tmp/stub-socket-dir")
        (started nil))
    (cl-letf (((symbol-function 'seance-bridge--server-live-p) (lambda () nil))
              ((symbol-function 'server-running-p) (lambda (&optional _name) t))
              ((symbol-function 'server-start)
               (lambda (&rest _) (setq started t))))
      (let* ((servers (seance-bridge-mcp-servers))
             (env (aref (plist-get (aref servers 0) :env) 0)))
        (should started)
        (should (string-suffix-p (format "seance-%d" (emacs-pid))
                                 (plist-get env :value)))))))

(ert-deftest seance-bridge-mcp-servers-no-collision-keeps-name ()
  "Free (or stale) default socket: keep the configured name unchanged."
  (let ((seance-enable-bridge t)
        (noninteractive nil)
        (server-name "server")
        (server-socket-dir "/tmp/stub-socket-dir")
        (started nil))
    (cl-letf (((symbol-function 'seance-bridge--server-live-p) (lambda () nil))
              ((symbol-function 'server-running-p) (lambda (&optional _name) nil))
              ((symbol-function 'server-start)
               (lambda (&rest _) (setq started t))))
      (let* ((servers (seance-bridge-mcp-servers))
             (env (aref (plist-get (aref servers 0) :env) 0)))
        (should started)
        (should (equal (plist-get env :value) "/tmp/stub-socket-dir/server"))))))

;;; End-to-end: the bin/seance-mcp-bridge.el script

(require 'seance-rpc)  ; reuse the ndjson transport to talk MCP to the script

(ert-deftest seance-bridge-mcp-script-end-to-end ()
  "Start a real Emacs server, run the bridge script, call emacs_eval through it.
The Emacs server lives in THIS batch test process: server connections
are plain process events, so they are served while `seance-test-wait'
sits in `accept-process-output' (verified to work on Linux).  The
socket goes into a fresh temp dir and the bridge subprocess gets its
ABSOLUTE path via SEANCE_SERVER -- emacsclient -s accepts a full socket
path -- which avoids any assumptions about the default socket dir and
keeps repeated runs isolated.  Permission mode is `auto' so the
emacs_eval dispatch never blocks on y-or-n-p."
  (require 'server)
  (let* ((server-name (format "seance-test-%d" (emacs-pid)))
         (server-socket-dir (make-temp-file "seance-server" t))
         (seance-permission-mode 'auto)
         (seance-acp--session nil))
    (server-start)
    (unwind-protect
        (let* ((process-environment
                (cons (concat "SEANCE_SERVER="
                              (expand-file-name server-name server-socket-dir))
                      process-environment))
               (got nil)
               (rpc (seance-rpc-start
                     (list seance-test-emacs "--batch" "--script"
                           (expand-file-name "../bin/seance-mcp-bridge.el"
                                             seance-test-dir))
                     :name "seance-mcp-bridge-test")))
          (unwind-protect
              (progn
                (seance-rpc-request
                 rpc "initialize"
                 '(:protocolVersion "2025-06-18"
                   :capabilities (:tools (:listChanged :json-false))
                   :clientInfo (:name "test" :version "0"))
                 (lambda (res _e) (setq got res)))
                (seance-test-wait (lambda () got) 10)
                (should (plist-get got :serverInfo))
                (setq got nil)
                (seance-rpc-request rpc "tools/list" nil
                                    (lambda (res _e) (setq got res)))
                (seance-test-wait (lambda () got) 10)
                (should (cl-find "emacs_eval" (append (plist-get got :tools) nil)
                                 :key (lambda (tool) (plist-get tool :name))
                                 :test #'equal))
                (setq got nil)
                (seance-rpc-request
                 rpc "tools/call"
                 '(:name "emacs_eval" :arguments (:form "(* 6 7)"))
                 (lambda (res _e) (setq got res)))
                (seance-test-wait (lambda () got) 10)
                (should (eq (plist-get got :isError) :json-false))
                (should (equal (plist-get (aref (plist-get got :content) 0) :text)
                               "42")))
            (seance-rpc-shutdown rpc)))
      (server-force-delete server-name)
      (delete-directory server-socket-dir t))))

;;; seance-bridge-test.el ends here
