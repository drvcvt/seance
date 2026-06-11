;;; seance-keys-test.el --- tests for seance-keys -*- lexical-binding: t; -*-

(require 'ert)
(require 'seance-keys)
(require 'seance-chat)

(ert-deftest seance-keys-table-installed-in-chat-map ()
  (should (eq (lookup-key seance-chat-mode-map (kbd "RET")) #'seance-chat-send))
  (should (eq (lookup-key seance-chat-mode-map (kbd "TAB")) #'seance-chat-toggle-detail))
  (should (eq (lookup-key seance-chat-mode-map (kbd "C-c C-p"))
              #'seance-toggle-permission-mode)))

(ert-deftest seance-keys-help-command-exists ()
  (should (commandp 'seance-chat-help))
  ;; ? dispatches: help outside the input field, self-insert inside
  (should (eq (lookup-key seance-chat-mode-map (kbd "?"))
              #'seance-chat-help-or-self-insert)))

(ert-deftest seance-keys-every-entry-has-description ()
  (dolist (group seance-keys-chat-table)
    (dolist (b (cdr group))
      (should (= (length b) 3))
      (should (stringp (nth 2 b)))
      (should (fboundp (nth 1 b))))))

;;; seance-keys-test.el ends here
