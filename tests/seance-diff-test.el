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

(ert-deftest seance-diff-strings-missing-binary-returns-placeholder ()
  "A nonexistent diff binary yields the seance-diff failed placeholder."
  (let ((diff-command "/nonexistent-diff-binary"))
    (should (string-match-p "seance-diff failed"
                             (seance-diff-strings "a\n" "b\n" "f.el")))))

(ert-deftest seance-diff-strings-label-newline-sanitized ()
  "A label containing a newline only uses the first line in the header."
  (let ((diff (seance-diff-strings "a\n" "b\n" "some/file.el\nextra line")))
    (should (string-match-p "^--- a/some/file\\.el$" diff))
    (should-not (string-match-p "extra line" diff))))

;;; seance-diff-test.el ends here
