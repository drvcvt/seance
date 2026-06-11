;;; seance-chat-test.el --- tests for seance-chat -*- lexical-binding: t; -*-

(require 'ert)
(require 'seance-test-helpers)
(require 'seance-chat)

(defmacro seance-chat-test--with-buffer (scenario &rest body)
  "Run BODY in a fresh, connected chat buffer against mock SCENARIO."
  (declare (indent 1))
  `(let ((seance-codex-acp-command (seance-test-mock-command ,scenario))
         (seance-chat-buffer-name "*seance-test*"))
     (with-current-buffer (get-buffer-create seance-chat-buffer-name)
       (unwind-protect
           (progn
             (seance-chat-mode)
             (seance-chat--initialize)
             (seance-test-wait
              (lambda () (eq (seance-acp-session-status seance-chat--session) 'idle)))
             ,@body)
         (when seance-chat--session
           (seance-acp-disconnect seance-chat--session))
         (kill-buffer)))))

(defun seance-chat-test--send-and-finish (text)
  "Type TEXT into the input field, send it, and wait for the turn to end."
  (goto-char (point-max))
  (insert text)
  (seance-chat-send)
  (seance-test-wait
   (lambda () (eq (seance-acp-session-status seance-chat--session) 'idle))))

(ert-deftest seance-chat-echo-turn-renders ()
  (seance-chat-test--with-buffer "echo"
    (seance-chat-test--send-and-finish "hallo")
    (should (string-match-p "Du › hallo" (buffer-string)))
    (should (string-match-p "echo: hallo" (buffer-string)))
    ;; input field is empty again and point can type there
    (should (= (point-max) (marker-position seance-chat--prompt-marker)))))

(ert-deftest seance-chat-transcript-is-read-only ()
  (seance-chat-test--with-buffer "echo"
    (seance-chat-test--send-and-finish "hallo")
    (goto-char (point-min))
    (should-error (insert "x") :type 'text-read-only)))

(ert-deftest seance-chat-history-cycles ()
  (seance-chat-test--with-buffer "echo"
    (seance-chat-test--send-and-finish "first")
    (seance-chat-test--send-and-finish "second")
    (goto-char (point-max))
    (seance-chat-history-prev)
    (should (equal (seance-chat--input-text) "second"))
    (seance-chat-history-prev)
    (should (equal (seance-chat--input-text) "first"))
    (seance-chat-history-next)
    (should (equal (seance-chat--input-text) "second"))))

(ert-deftest seance-chat-toggle-permission-mode-uses-buffer-session ()
  "`seance-toggle-permission-mode' acts on the chat buffer's session,
even when the global `seance-acp--session' pointer is stale."
  (seance-chat-test--with-buffer "echo"
    (let ((seance-acp--session nil))
      (should (eq (seance-acp-session-permission-mode seance-chat--session)
                  'gated))
      (seance-toggle-permission-mode)
      (should (eq (seance-acp-session-permission-mode seance-chat--session)
                  'auto)))))

(ert-deftest seance-chat-stop-clears-global-session ()
  "`seance-stop' clears `seance-acp--session' when it points at the
session being disconnected."
  (seance-chat-test--with-buffer "echo"
    (should (eq seance-acp--session seance-chat--session))
    (seance-stop)
    (should (eq (seance-acp-session-status seance-chat--session)
                'disconnected))
    (should (null seance-acp--session))))

(ert-deftest seance-chat-thought-message-thought-separation ()
  "Alternating thought/message blocks are separated by blank lines."
  (seance-chat-test--with-buffer "echo"
    (seance-chat--stream-chunk 'thought "a")
    (seance-chat--stream-chunk 'message "b")
    (seance-chat--stream-chunk 'thought "c")
    (should (string-match-p "a\n\nb\n\nc" (buffer-string)))))

;;; seance-chat-test.el ends here
