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

(ert-deftest seance-acp-slice-lines ()
  "Line/limit slicing for fs/read_text_file."
  (let ((content "one\ntwo\nthree\n"))
    ;; neither param: identity
    (should (equal (seance-acp--slice-lines content nil nil) content))
    ;; both: lines [line-1, line-1+limit)
    (should (equal (seance-acp--slice-lines content 2 1) "two"))
    (should (equal (seance-acp--slice-lines content 1 2) "one\ntwo"))
    ;; only line: from line-1 to end (trailing newline survives via the
    ;; empty final split element)
    (should (equal (seance-acp--slice-lines content 2 nil) "two\nthree\n"))
    ;; only limit: first limit lines
    (should (equal (seance-acp--slice-lines content nil 2) "one\ntwo"))
    ;; limit reaching past EOF: whole rest
    (should (equal (seance-acp--slice-lines content 3 10) "three\n"))
    ;; line beyond EOF: empty string
    (should (equal (seance-acp--slice-lines content 99 nil) ""))
    (should (equal (seance-acp--slice-lines content 99 5) ""))))

(ert-deftest seance-acp-connect-resets-edit-log ()
  "Connecting a new session must clear the per-session edit log."
  (require 'seance-review)
  (let ((seance-review--edit-log
         '((:path "/tmp/stale.el" :before "a\n" :after "b\n"))))
    (seance-acp-test--with-session "echo" sess _updates
      (should (null seance-review--edit-log)))))

(ert-deftest seance-acp-connect-kills-stale-permission-buffer ()
  "Connecting a new session must kill a predecessor's permission buffer.
A lingering buffer holds a parked reply belonging to the old session."
  (require 'seance-review)
  (get-buffer-create seance-review-permission-buffer)
  (unwind-protect
      (seance-acp-test--with-session "echo" sess _updates
        (should-not (get-buffer seance-review-permission-buffer)))
    (when (get-buffer seance-review-permission-buffer)
      (kill-buffer seance-review-permission-buffer))))

(ert-deftest seance-acp-cancel-on-dead-session-errors ()
  "Cancelling a disconnected session signals `user-error', not a process error."
  (let* ((seance-codex-acp-command (seance-test-mock-command "echo"))
         (sess (seance-acp-connect temporary-file-directory)))
    (seance-test-wait (lambda () (eq (seance-acp-session-status sess) 'idle)))
    (seance-acp-disconnect sess)
    (should-error (seance-acp-cancel sess) :type 'user-error)))

(ert-deftest seance-acp-fs-read-error-still-ends-turn ()
  "A failed fs/read reply must not crash the agent; the turn still ends."
  (seance-acp-test--with-session "fs" sess updates
    (let ((done nil))
      (seance-acp-prompt sess "/nonexistent/seance-no-such-file"
                         (lambda (res _e) (setq done res)))
      (seance-test-wait (lambda () done))
      (should (equal (plist-get done :stopReason) "end_turn")))))

;;; seance-acp-test.el ends here
