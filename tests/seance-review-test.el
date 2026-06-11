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

;;; seance-review-test.el ends here
