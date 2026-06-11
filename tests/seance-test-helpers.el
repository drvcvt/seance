;;; seance-test-helpers.el --- shared test utilities -*- lexical-binding: t; -*-

(require 'ert)

(defvar seance-test-dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Absolute path of the tests/ directory.")

(defvar seance-test-emacs
  (expand-file-name invocation-name invocation-directory)
  "The Emacs binary running this test, reused for subprocess scripts.")

(defun seance-test-wait (pred &optional timeout)
  "Pump process output until PRED returns non-nil or TIMEOUT (default 5s)."
  (let ((deadline (+ (float-time) (or timeout 5))))
    (while (and (not (funcall pred)) (< (float-time) deadline))
      (accept-process-output nil 0.05)))
  (unless (funcall pred)
    (ert-fail "seance-test-wait: timed out")))

(defun seance-test-mock-command (scenario)
  "Command list that starts tests/mock-agent.el playing SCENARIO."
  (setenv "SEANCE_MOCK_SCENARIO" scenario)
  (list seance-test-emacs "--batch" "--script"
        (expand-file-name "mock-agent.el" seance-test-dir)))

(provide 'seance-test-helpers)
;;; seance-test-helpers.el ends here
