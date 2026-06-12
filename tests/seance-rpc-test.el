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

(ert-deftest seance-rpc-handler-error-sends-error-response ()
  "A handler that signals produces a -32603 error response, not a hang."
  (let* ((sent nil)
         (rpc (seance-rpc--make
               :handler (lambda (_method _params _reply) (error "boom"))
               :notifier #'ignore)))
    (cl-letf (((symbol-function 'seance-rpc--send)
               (lambda (_rpc msg) (push msg sent))))
      (seance-rpc--filter rpc "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"x\"}\n"))
    (should (= (length sent) 1))
    (let ((msg (car sent)))
      (should (equal (plist-get msg :id) 3))
      (should (equal (plist-get (plist-get msg :error) :code) -32603)))))

(ert-deftest seance-rpc-double-reply-is-noop ()
  "Calling the reply closure a second time sends nothing."
  (let* ((sent nil)
         (rpc (seance-rpc--make
               :handler (lambda (_method _params reply)
                          (funcall reply '(:n 1))
                          (funcall reply '(:n 2)))
               :notifier #'ignore)))
    (cl-letf (((symbol-function 'seance-rpc--send)
               (lambda (_rpc msg) (push msg sent))))
      (seance-rpc--filter rpc "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"x\"}\n"))
    (should (= (length sent) 1))
    (should (equal (plist-get (plist-get (car sent) :result) :n) 1))))

(ert-deftest seance-rpc-process-death-rejects-pending ()
  "Killing the subprocess fails every pending callback with -32000."
  (let* ((got nil)
         (rpc (seance-rpc-start
               (list seance-test-emacs "--batch" "--script"
                     (expand-file-name "rpc-echo.el" seance-test-dir)))))
    (unwind-protect
        (progn
          (puthash 99 (lambda (res err) (setq got (list res err)))
                   (seance-rpc-pending rpc))
          (kill-process (seance-rpc-process rpc))
          (seance-test-wait (lambda () got))
          (should (null (car got)))
          (should (equal (plist-get (cadr got) :code) -32000))
          (should (zerop (hash-table-count (seance-rpc-pending rpc)))))
      (seance-rpc-shutdown rpc))))

(ert-deftest seance-rpc-parked-reply-to-dead-process-is-noop ()
  "Funcalling a parked reply closure after the process died must not signal.
Production chain: a permission reply parked in UI outlives its session;
the adapter is SIGKILLed; the stale reply is later consumed as cleanup.
That send must be dropped, not raise a process error."
  (let* ((stashed nil)
         (rpc (seance-rpc-start
               (list seance-test-emacs "--batch" "--script"
                     (expand-file-name "rpc-echo.el" seance-test-dir))
               :handler (lambda (_method _params reply) (setq stashed reply)))))
    (unwind-protect
        (progn
          (seance-rpc--filter rpc "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"x\"}\n")
          (should stashed)
          (kill-process (seance-rpc-process rpc))
          (seance-test-wait
           (lambda () (not (process-live-p (seance-rpc-process rpc)))))
          ;; Must return without sending; a signal here fails the test.
          (funcall stashed '(:ok t)))
      (seance-rpc-shutdown rpc))))

(ert-deftest seance-rpc-stderr-buffer-per-connection ()
  "Each connection gets its own stderr buffer named from :name."
  (let ((rpc (seance-rpc-start
              (list seance-test-emacs "--batch" "--script"
                    (expand-file-name "rpc-echo.el" seance-test-dir))
              :name "seance-test-conn")))
    (unwind-protect
        (should (buffer-live-p (get-buffer " *seance-test-conn-stderr*")))
      (seance-rpc-shutdown rpc))))

;;; seance-rpc-test.el ends here
