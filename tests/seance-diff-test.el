;;; seance-diff-test.el --- tests for seance-diff -*- lexical-binding: t; -*-

(require 'ert)
(require 'seance-diff)

(ert-deftest seance-diff-strings-unified ()
  (let ((diff (seance-diff-strings "a\nb\n" "a\nc\n" "f.el")))
    (should (string-match-p "^--- a/f.el" diff))
    (should (string-match-p "^\\+\\+\\+ b/f.el" diff))
    (should (string-match-p "^-b$" diff))
    (should (string-match-p "^\\+c$" diff))))

(ert-deftest seance-diff-strings-equal-inputs-empty ()
  (should (string-empty-p (seance-diff-strings "same\n" "same\n" "f"))))

;;; seance-diff-test.el ends here
