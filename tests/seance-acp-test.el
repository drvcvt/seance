;;; seance-acp-test.el --- tests for seance-acp -*- lexical-binding: t; -*-

(require 'ert)
(require 'seance-test-helpers)
(require 'seance-acp)

(defmacro seance-acp-test--with-session (scenario var updates-var &rest body)
  "Connect VAR to the mock agent playing SCENARIO, collect updates in UPDATES-VAR."
  (declare (indent 3))
  `(let* ((seance-codex-acp-command (seance-test-mock-command ,scenario))
          (,updates-var nil)
          (,var (seance-acp-connect
                 temporary-file-directory
                 :on-update (lambda (u) (push u ,updates-var)))))
     (unwind-protect
         (progn
           (seance-test-wait
            (lambda () (eq (seance-acp-session-status ,var) 'idle)))
           ,@body)
       (seance-acp-disconnect ,var))))

(ert-deftest seance-acp-connect-and-echo-turn ()
  (seance-acp-test--with-session "echo" sess updates
    (should (equal (seance-acp-session-id sess) "mock-session"))
    (let ((done nil))
      (seance-acp-prompt sess "hallo" (lambda (res _e) (setq done res)))
      (seance-test-wait (lambda () done))
      (should (equal (plist-get done :stopReason) "end_turn")))
    (let ((chunk (car updates)))
      (should (equal (plist-get chunk :sessionUpdate) "agent_message_chunk"))
      (should (equal (plist-get (plist-get chunk :content) :text) "echo: hallo")))))

(ert-deftest seance-acp-status-transitions ()
  (seance-acp-test--with-session "echo" sess updates
    (let ((done nil))
      (seance-acp-prompt sess "x" (lambda (_r _e) (setq done t)))
      ;; Asserting 'thinking synchronously is race-free: the status is set
      ;; before the request is sent, and no process output is pumped between
      ;; the `seance-acp-prompt' call and this assertion.
      (should (eq (seance-acp-session-status sess) 'thinking))
      (seance-test-wait (lambda () done))
      (should (eq (seance-acp-session-status sess) 'idle)))))

(ert-deftest seance-acp-disconnect-marks-status ()
  (let* ((seance-codex-acp-command (seance-test-mock-command "echo"))
         (sess (seance-acp-connect temporary-file-directory)))
    (unwind-protect
        (progn
          (seance-test-wait
           (lambda () (eq (seance-acp-session-status sess) 'idle)))
          (kill-process (seance-rpc-process (seance-acp-session-rpc sess)))
          (seance-test-wait
           (lambda () (eq (seance-acp-session-status sess) 'disconnected))))
      ;; Harmless after the kill: shutdown is idempotent.
      (seance-acp-disconnect sess))))

(ert-deftest seance-acp-init-error-shuts-down-adapter ()
  "A handshake error must mark the session 'error and kill the adapter."
  (let* ((seance-codex-acp-command (seance-test-mock-command "init-error"))
         (sess (seance-acp-connect temporary-file-directory)))
    (unwind-protect
        (seance-test-wait
         (lambda ()
           (and (eq (seance-acp-session-status sess) 'error)
                (not (seance-rpc-alive-p (seance-acp-session-rpc sess))))))
      (seance-acp-disconnect sess))))

(ert-deftest seance-acp-prompt-on-dead-session-errors ()
  "Prompting a disconnected session signals instead of wedging at 'thinking."
  (let* ((seance-codex-acp-command (seance-test-mock-command "echo"))
         (sess (seance-acp-connect temporary-file-directory)))
    (seance-test-wait (lambda () (eq (seance-acp-session-status sess) 'idle)))
    (seance-acp-disconnect sess)
    (should-error (seance-acp-prompt sess "x") :type 'user-error)
    (should (eq (seance-acp-session-status sess) 'disconnected))))

(ert-deftest seance-acp-fs-read-error-still-ends-turn ()
  "A failed fs/read reply must not crash the agent; the turn still ends."
  (seance-acp-test--with-session "fs" sess updates
    (let ((done nil))
      (seance-acp-prompt sess "/nonexistent/seance-no-such-file"
                         (lambda (res _e) (setq done res)))
      (seance-test-wait (lambda () done))
      (should (equal (plist-get done :stopReason) "end_turn")))))

;;; seance-acp-test.el ends here
