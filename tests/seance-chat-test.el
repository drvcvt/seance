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

;;; seance-chat-test.el ends here
