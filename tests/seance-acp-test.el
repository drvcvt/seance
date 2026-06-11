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
      (should (eq (seance-acp-session-status sess) 'thinking))
      (seance-test-wait (lambda () done))
      (should (eq (seance-acp-session-status sess) 'idle)))))

(ert-deftest seance-acp-disconnect-marks-status ()
  (let* ((seance-codex-acp-command (seance-test-mock-command "echo"))
         (sess (seance-acp-connect temporary-file-directory)))
    (seance-test-wait (lambda () (eq (seance-acp-session-status sess) 'idle)))
    (kill-process (seance-rpc-process (seance-acp-session-rpc sess)))
    (seance-test-wait
     (lambda () (eq (seance-acp-session-status sess) 'disconnected)))))

;;; seance-acp-test.el ends here
