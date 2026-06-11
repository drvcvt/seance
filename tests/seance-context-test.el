;;; seance-context-test.el --- tests for seance-context -*- lexical-binding: t; -*-

(require 'ert)
(require 'seance-test-helpers)
(require 'seance-context)
(require 'seance-acp)

(ert-deftest seance-context-preamble-mentions-environment ()
  (let* ((sess (seance-acp-session--make :cwd "/tmp/x"))
         (p (seance-context-preamble sess)))
    (should (string-match-p (regexp-quote emacs-version) p))
    (should (string-match-p "emacs_eval" p))
    (should (string-match-p "running GNU Emacs" p))))

(ert-deftest seance-context-preamble-honest-when-bridge-disabled ()
  (let* ((seance-enable-bridge nil)
         (sess (seance-acp-session--make :cwd "/tmp/x"))
         (p (seance-context-preamble sess)))
    (should-not (string-match-p "emacs_eval" p))
    (should (string-match-p "disabled in this session" p))))

(ert-deftest seance-context-wrap-only-first-turn ()
  (let ((sess (seance-acp-session--make :cwd "/tmp/x")))
    (let ((first (seance-context-wrap sess "hi")))
      (should (string-match-p "running GNU Emacs" first))
      (should (string-suffix-p "hi" first)))
    (should (equal (seance-context-wrap sess "again") "again"))))

;;; seance-context-test.el ends here
