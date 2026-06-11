;;; seance-rpc-test.el --- tests for seance-rpc -*- lexical-binding: t; -*-

(require 'ert)
(require 'seance-test-helpers)
(require 'seance-rpc)

(ert-deftest seance-rpc-framing-partial-lines ()
  "Messages split across filter calls are reassembled; one dispatch per line."
  (let* ((seen nil)
         (rpc (seance-rpc--make
               :handler #'ignore
               :notifier (lambda (m p) (push (cons m p) seen)))))
    (seance-rpc--filter rpc "{\"jsonrpc\":\"2.0\",\"method\":\"a\",\"par")
    (should (null seen))
    (seance-rpc--filter rpc "ams\":{\"x\":1}}\n{\"jsonrpc\":\"2.0\",\"method\":\"b\"}\n")
    (should (equal (reverse seen) '(("a" . (:x 1)) ("b"))))))

(ert-deftest seance-rpc-response-dispatch ()
  "A response resolves and removes the pending callback."
  (let* ((got nil)
         (rpc (seance-rpc--make :handler #'ignore :notifier #'ignore)))
    (puthash 7 (lambda (res err) (setq got (list res err)))
             (seance-rpc-pending rpc))
    (seance-rpc--filter rpc "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"ok\":true}}\n")
    (should (equal got '((:ok t) nil)))
    (should (zerop (hash-table-count (seance-rpc-pending rpc))))))

(ert-deftest seance-rpc-echo-roundtrip ()
  "Round-trip request/response against a real subprocess."
  (let* ((result nil)
         (rpc (seance-rpc-start
               (list seance-test-emacs "--batch" "--script"
                     (expand-file-name "rpc-echo.el" seance-test-dir)))))
    (unwind-protect
        (progn
          (seance-rpc-request rpc "ping" '(:n 1)
                              (lambda (res _err) (setq result res)))
          (seance-test-wait (lambda () result))
          (should (equal (plist-get result :echo) "ping")))
      (seance-rpc-shutdown rpc))))

;;; seance-rpc-test.el ends here
