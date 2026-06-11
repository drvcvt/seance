;;; seance-review-test.el --- tests for seance-review -*- lexical-binding: t; -*-

(require 'ert)
(require 'seance-test-helpers)
(require 'seance-acp)
(require 'seance-review)

(defconst seance-review-test--params
  '(:sessionId "s1"
    :toolCall (:toolCallId "tc-p1" :title "edit guarded.el" :kind "edit"
               :content [(:type "diff" :path "guarded.el"
                          :oldText "before\n" :newText "after\n")])
    :options [(:optionId "opt-allow" :name "Allow" :kind "allow_once")
              (:optionId "opt-allow-always" :name "Always" :kind "allow_always")
              (:optionId "opt-reject" :name "Reject" :kind "reject_once")]))

(defun seance-review-test--session (mode)
  (seance-acp-session--make :permission-mode mode :id "s1"))

(ert-deftest seance-review-auto-mode-allows-immediately ()
  (let ((answer nil))
    (seance-review-handle-permission
     (seance-review-test--session 'auto) seance-review-test--params
     (lambda (result &optional _err) (setq answer result)))
    (should (equal (plist-get (plist-get answer :outcome) :optionId) "opt-allow"))))

(ert-deftest seance-review-gated-shows-diff-and-allow-answers ()
  (let ((answer nil))
    (seance-review-handle-permission
     (seance-review-test--session 'gated) seance-review-test--params
     (lambda (result &optional _err) (setq answer result)))
    (should (null answer))                       ; still waiting on the user
    (with-current-buffer "*seance permission*"
      (should (string-match-p "-before" (buffer-string)))
      (should (string-match-p "\\+after" (buffer-string)))
      (seance-review-allow))
    (should (equal (plist-get (plist-get answer :outcome) :optionId) "opt-allow"))))

(ert-deftest seance-review-gated-deny ()
  (let ((answer nil))
    (seance-review-handle-permission
     (seance-review-test--session 'gated) seance-review-test--params
     (lambda (result &optional _err) (setq answer result)))
    (with-current-buffer "*seance permission*"
      (seance-review-deny))
    (should (equal (plist-get (plist-get answer :outcome) :optionId) "opt-reject"))))

(ert-deftest seance-review-overlapping-request-cancels-first ()
  "A second gated request must not orphan the first parked reply."
  (let ((first nil) (second nil)
        (sess (seance-review-test--session 'gated)))
    (seance-review-handle-permission
     sess seance-review-test--params
     (lambda (result &optional _err) (setq first result)))
    (seance-review-handle-permission
     sess seance-review-test--params
     (lambda (result &optional _err) (setq second result)))
    ;; First request was answered cancelled, not dropped.
    (should (equal (plist-get (plist-get first :outcome) :outcome) "cancelled"))
    ;; Second request is the live one; answering it works normally.
    (with-current-buffer "*seance permission*"
      (seance-review-allow))
    (should (equal (plist-get (plist-get second :outcome) :optionId)
                   "opt-allow"))))

(ert-deftest seance-review-allow-all-switches-session-to-auto ()
  (let ((answer nil)
        (sess (seance-review-test--session 'gated)))
    (seance-review-handle-permission
     sess seance-review-test--params
     (lambda (result &optional _err) (setq answer result)))
    (with-current-buffer "*seance permission*"
      (seance-review-allow-all))
    (should (equal (plist-get (plist-get answer :outcome) :optionId)
                   "opt-allow-always"))
    (should (eq (seance-acp-session-permission-mode sess) 'auto))))

(ert-deftest seance-review-end-to-end-against-mock ()
  "Full loop: mock requests permission, we allow, mock reports the pick."
  (let* ((seance-codex-acp-command (seance-test-mock-command "permission"))
         (updates nil)
         (sess (seance-acp-connect temporary-file-directory
                                   :on-update (lambda (u) (push u updates)))))
    (unwind-protect
        (progn
          (seance-test-wait (lambda () (eq (seance-acp-session-status sess) 'idle)))
          (setf (seance-acp-session-permission-mode sess) 'gated)
          (let ((done nil))
            (seance-acp-prompt sess "go" (lambda (_r _e) (setq done t)))
            (seance-test-wait (lambda () (get-buffer "*seance permission*")))
            (with-current-buffer "*seance permission*" (seance-review-allow))
            (seance-test-wait (lambda () done)))
          (should (cl-find-if
                   (lambda (u)
                     (equal (plist-get (plist-get u :content) :text)
                            "picked: opt-allow"))
                   updates)))
      (seance-acp-disconnect sess))))

(ert-deftest seance-review-fs-read-prefers-buffer ()
  (let ((file (make-temp-file "seance-fs" nil ".txt" "disk content\n")))
    (unwind-protect
        (with-current-buffer (find-file-noselect file)
          (goto-char (point-min))
          (insert "unsaved ")
          (should (equal (seance-review-read-file file)
                         "unsaved disk content\n"))
          (set-buffer-modified-p nil)
          (kill-buffer))
      (delete-file file))))

(ert-deftest seance-review-fs-write-into-clean-buffer-saves ()
  (let ((file (make-temp-file "seance-fs" nil ".txt" "old\n")))
    (unwind-protect
        (let ((buf (find-file-noselect file)))
          (seance-review-write-file file "new\n")
          (with-current-buffer buf
            (should (equal (buffer-string) "new\n"))
            (should-not (buffer-modified-p)))   ; was clean -> saved
          (should (equal (with-temp-buffer (insert-file-contents file)
                                           (buffer-string))
                         "new\n"))
          (kill-buffer buf))
      (delete-file file))))

(ert-deftest seance-review-fs-write-into-dirty-buffer-stays-unsaved ()
  (let ((file (make-temp-file "seance-fs" nil ".txt" "old\n")))
    (unwind-protect
        (let ((buf (find-file-noselect file)))
          (with-current-buffer buf (insert "dirty "))
          (seance-review-write-file file "new\n")
          (with-current-buffer buf
            (should (equal (buffer-string) "new\n"))
            (should (buffer-modified-p)))       ; had user edits -> not saved
          ;; disk still has the old content
          (should (equal (with-temp-buffer (insert-file-contents file)
                                           (buffer-string))
                         "old\n"))
          (with-current-buffer buf (set-buffer-modified-p nil) (kill-buffer)))
      (delete-file file))))

(ert-deftest seance-review-edit-log-records-before-after ()
  (let ((file (make-temp-file "seance-fs" nil ".txt" "v1\n"))
        (seance-review--edit-log nil))
    (unwind-protect
        (progn
          (seance-review-write-file file "v2\n")
          (let ((e (car seance-review--edit-log)))
            (should (equal (plist-get e :before) "v1\n"))
            (should (equal (plist-get e :after) "v2\n"))
            (should (equal (plist-get e :path) file))))
      (delete-file file))))

(ert-deftest seance-review-edit-log-not-updated-on-failed-write ()
  "A write to an unwritable path must not push a phantom log entry."
  (let ((seance-review--edit-log nil))
    (should-error (seance-review-write-file "/proc/seance-test/x.txt" "hi\n"))
    (should (null seance-review--edit-log))))

(ert-deftest seance-review-fs-end-to-end-against-mock ()
  "Mock reads a file through us, writes it back uppercased."
  (let* ((file (make-temp-file "seance-fs" nil ".txt" "hello\n"))
         (seance-review--edit-log nil)
         (seance-codex-acp-command (seance-test-mock-command "fs"))
         (updates nil)
         (sess (seance-acp-connect temporary-file-directory
                                   :on-update (lambda (u) (push u updates)))))
    (unwind-protect
        (progn
          (seance-test-wait (lambda () (eq (seance-acp-session-status sess) 'idle)))
          (let ((done nil))
            (seance-acp-prompt sess file (lambda (_r _e) (setq done t)))
            (seance-test-wait (lambda () done)))
          (should (equal (with-temp-buffer (insert-file-contents file)
                                           (buffer-string))
                         "HELLO\n"))
          (should (= (length seance-review--edit-log) 1)))
      (seance-acp-disconnect sess)
      (delete-file file))))

(ert-deftest seance-review-buffer-coalesces-per-file ()
  "Multiple edits to one file show as ONE diff: first before vs last after."
  (let ((seance-review--edit-log
         ;; newest first
         '((:path "/tmp/x/b.el" :before "b1\n" :after "b2\n")
           (:path "/tmp/x/a.el" :before "a2\n" :after "a3\n")
           (:path "/tmp/x/a.el" :before "a1\n" :after "a2\n"))))
    (seance-review)
    (with-current-buffer "*seance review*"
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "^-a1$" text))
        (should (string-match-p "^\\+a3$" text))
        (should-not (string-match-p "a2" text))   ; intermediate state hidden
        (should (string-match-p "^-b1$" text))
        (should (derived-mode-p 'diff-mode)))
      (kill-buffer))))

(ert-deftest seance-review-buffer-empty-log ()
  (let ((seance-review--edit-log nil))
    (seance-review)
    (with-current-buffer "*seance review*"
      (should (string-match-p "No edits recorded" (buffer-string)))
      (should (eq (lookup-key (current-local-map) (kbd "?"))
                  'seance-review-help))
      (kill-buffer))))

(ert-deftest seance-review-buffer-default-directory-anchored-to-session-cwd ()
  "The review buffer's default-directory must equal the session's cwd."
  (let ((seance-acp--session
         (seance-acp-session--make :cwd "/tmp/x/"))
        (seance-review--edit-log
         '((:path "/tmp/x/foo.el" :before "old\n" :after "new\n"))))
    (unwind-protect
        (progn
          (seance-review)
          (should (equal (with-current-buffer "*seance review*"
                           default-directory)
                         "/tmp/x/")))
      (when (get-buffer "*seance review*")
        (kill-buffer "*seance review*")))))

;;; seance-review-test.el ends here
