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
    (let ((text (buffer-string)))
      (should (string-match-p "Du › hallo" text))
      ;; first turn carries the environment preamble before the input
      (should (string-match-p "echo: You are running" text))
      (should (string-match-p "---\n\nhallo" text)))
    ;; input field is empty again and point can type there
    (should (= (point-max) (marker-position seance-chat--prompt-marker)))
    ;; second turn must NOT be re-wrapped: literal echo, no preamble
    (seance-chat-test--send-and-finish "zweite")
    (should (string-match-p "echo: zweite" (buffer-string)))))

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
  "Alternating thought/message blocks are separated by blank lines.
Adapted for Task 13: thought blocks now carry a ▸ Thinking… header line."
  (seance-chat-test--with-buffer "echo"
    (seance-chat--stream-chunk 'thought "a")
    (seance-chat--stream-chunk 'message "b")
    (seance-chat--stream-chunk 'thought "c")
    (should (string-match-p "▸ Thinking…\na\n\nb\n\n▸ Thinking…\nc"
                            (buffer-string)))))

(ert-deftest seance-chat-tool-call-renders-and-updates ()
  (seance-chat-test--with-buffer "tools"
    (seance-chat-test--send-and-finish "go")
    (let ((text (buffer-string)))
      ;; header line updated in place: completed icon, not two entries
      (should (string-match-p "✓ edit edit hello.el" text))
      (should-not (string-match-p "⏳" text))
      ;; plan block rendered
      (should (string-match-p "☑ step one" text))
      (should (string-match-p "☐ step two" text)))
    ;; detail (the diff) exists but is invisible until toggled
    (goto-char (point-min))
    (search-forward "✓ edit")
    (beginning-of-line)
    (let* ((id (get-text-property (point) 'seance-tool-id))
           (entry (gethash id seance-chat--tool-regions))
           (ov (plist-get entry :detail-ov)))
      (should (overlay-get ov 'invisible))
      (seance-chat-toggle-detail)
      (should-not (overlay-get ov 'invisible))
      (should (string-match-p "-old line" (buffer-substring-no-properties
                                           (overlay-start ov) (overlay-end ov)))))))

(ert-deftest seance-chat-fontifies-closed-code-fence ()
  (seance-chat-test--with-buffer "echo"
    ;; simulate streamed chunks forming a fenced block
    (seance-chat--stream-chunk 'message "look:\n```elisp\n(defun f ())\n")
    (seance-chat--stream-chunk 'message "```\ntail")
    (seance-chat--close-block)
    (goto-char (point-min))
    (search-forward "(defun")
    (backward-word)
    (should (eq (get-text-property (point) 'face) 'font-lock-keyword-face))))

(ert-deftest seance-chat-erroring-fence-mode-degrades-to-plain ()
  "A fence lang whose mode signals (image-mode in batch) must not
brick rendering: the close completes, the body text survives, and
later blocks still get their separators.  The lang is mapped explicitly
so the test exercises the erroring-mode path, not the unknown-lang one."
  (seance-chat-test--with-buffer "echo"
    (setq-local seance-chat-fence-modes
                (cons '("image" . image-mode) seance-chat-fence-modes))
    (seance-chat--stream-chunk 'message "look:\n```image\nnot an image\n")
    (seance-chat--stream-chunk 'message "```\ntail")
    (seance-chat--close-block)
    ;; block state was reset, body text is still there
    (should (null seance-chat--block))
    (should (string-match-p "not an image" (buffer-string)))
    ;; a subsequent stream/close cycle still renders separators
    (seance-chat--stream-chunk 'message "after")
    (seance-chat--close-block)
    (should (string-match-p "tail\n\nafter\n\n" (buffer-string)))))

(ert-deftest seance-chat-thought-block-collapsed-by-default ()
  (seance-chat-test--with-buffer "echo"
    (seance-chat--stream-chunk 'thought "secret reasoning")
    (seance-chat--stream-chunk 'message "visible answer")
    (let ((ov (seance-chat--thought-overlay-at
               (progn (goto-char (point-min))
                      (search-forward "Thinking")
                      (point)))))
      (should ov)
      (should (overlay-get ov 'invisible)))))

(ert-deftest seance-chat-toggle-thought-via-tab-command ()
  (seance-chat-test--with-buffer "echo"
    (seance-chat--stream-chunk 'thought "hidden words")
    (seance-chat--close-block)
    (goto-char (point-min))
    (search-forward "Thinking")
    (beginning-of-line)
    (seance-chat-toggle-thought)
    (let ((ov (seance-chat--thought-overlay-at (line-end-position))))
      (should ov)
      (should-not (overlay-get ov 'invisible)))))

;;; seance-chat-test.el ends here
