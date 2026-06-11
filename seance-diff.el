;;; seance-diff.el --- unified diffs between strings -*- lexical-binding: t; -*-

;;; Commentary:
;; Small helper around the external diff program: produce a unified diff
;; between two in-memory strings, labeled like git (a/FILE, b/FILE).

;;; Code:

(require 'diff)

(defun seance-diff-strings (old new &optional label)
  "Unified diff between strings OLD and NEW, labeled a/LABEL b/LABEL.
Returns the empty string when OLD and NEW are equal.
Returns a one-line placeholder string on error (missing binary, etc.)."
  (let ((f1 (make-temp-file "seance-old"))
        (f2 (make-temp-file "seance-new"))
        (label (car (split-string (or label "file") "\n"))))
    (unwind-protect
        (condition-case err
            (progn
              (write-region old nil f1 nil 'silent)
              (write-region new nil f2 nil 'silent)
              (with-temp-buffer
                (let ((exit (call-process diff-command nil '(t nil) nil "-u"
                                          "--label" (concat "a/" label)
                                          "--label" (concat "b/" label)
                                          f1 f2)))
                  (if (memq exit '(0 1))
                      (buffer-string)
                    (format "[seance-diff failed: exit %s]\n" exit)))))
          (error (format "[seance-diff failed: %s]\n" (error-message-string err))))
      (ignore-errors (delete-file f1))
      (ignore-errors (delete-file f2)))))

(provide 'seance-diff)
;;; seance-diff.el ends here
