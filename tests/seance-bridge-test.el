;;; seance-bridge-test.el --- tests for seance-bridge -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'seance-test-helpers)
(require 'seance-acp)
(require 'seance-bridge)

(defun seance-bridge-test--call (tool args-plist)
  "Call dispatch like emacsclient would; return parsed (:ok :value) plist."
  (json-parse-string
   (seance-bridge-dispatch tool (and args-plist (json-serialize args-plist)))
   :object-type 'plist :null-object nil :false-object nil))

(ert-deftest seance-bridge-eval-returns-printed-result ()
  (let ((seance-permission-mode 'auto)
        (seance-acp--session nil))
    (let ((res (seance-bridge-test--call "emacs_eval" '(:form "(+ 1 2)"))))
      (should (eq (plist-get res :ok) t))
      (should (equal (plist-get res :value) "3")))))

(ert-deftest seance-bridge-eval-error-is-structured ()
  (let ((seance-permission-mode 'auto)
        (seance-acp--session nil))
    (let ((res (seance-bridge-test--call "emacs_eval" '(:form "(error \"boom\")"))))
      (should-not (plist-get res :ok))
      (should (string-match-p "boom" (plist-get res :value))))))

(ert-deftest seance-bridge-buffer-list-and-get ()
  (with-current-buffer (get-buffer-create "*seance-bridge-probe*")
    (erase-buffer)
    (insert "probe content"))
  (let ((res (seance-bridge-test--call "emacs_buffer_list" nil)))
    (should (string-match-p "\\*seance-bridge-probe\\*" (plist-get res :value))))
  (let ((res (seance-bridge-test--call "emacs_buffer_get"
                                       '(:name "*seance-bridge-probe*"))))
    (should (equal (plist-get res :value) "probe content")))
  (kill-buffer "*seance-bridge-probe*"))

(ert-deftest seance-bridge-describe-function ()
  (let ((res (seance-bridge-test--call "emacs_describe" '(:symbol "car"))))
    (should (eq (plist-get res :ok) t))
    (should (string-match-p "Function:" (plist-get res :value)))))

(ert-deftest seance-bridge-unknown-tool-errors ()
  (let ((res (seance-bridge-test--call "emacs_frobnicate" nil)))
    (should-not (plist-get res :ok))))

(ert-deftest seance-bridge-eval-gated-denied ()
  "In gated mode with the user answering no, eval must be refused."
  (let ((seance-permission-mode 'gated)
        (seance-acp--session nil))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_prompt) nil)))
      (let ((res (seance-bridge-test--call "emacs_eval" '(:form "(+ 1 1)"))))
        (should-not (plist-get res :ok))
        (should (string-match-p "denied" (plist-get res :value)))))))

;;; seance-bridge-test.el ends here
