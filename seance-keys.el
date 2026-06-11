;;; seance-keys.el --- binding tables, keymaps, ? help -*- lexical-binding: t; -*-

;;; Commentary:
;; One table per mode drives BOTH the keymap and the `?' transient help,
;; so the help can never drift from the real bindings.
;; Table format: (GROUP-SYMBOL (KEY COMMAND DESCRIPTION)...)
;;
;; Verified empirically (Emacs 30.2): transient accepts all of our key
;; strings ("RET", "TAB", "S-<return>", "M-p", "C-c C-k", ...) verbatim
;; as suffix keys, including multi-key sequences -- they all resolve to
;; their commands in the keymap built by `transient--make-transient-map'
;; and do not clash with transient's own bindings (C-g, C-q, C-z, ...).
;; So the table keys are used unchanged for both keymap and menu.

;;; Code:

(require 'transient)

(defun seance-keys-apply (table keymap)
  "Install all bindings from TABLE into KEYMAP."
  (dolist (group table)
    (dolist (b (cdr group))
      (define-key keymap (kbd (nth 0 b)) (nth 1 b))))
  keymap)

(defun seance-keys--transient-groups (table)
  "Return TABLE's groups as transient group vectors."
  (mapcar (lambda (group)
            (apply #'vector
                   (capitalize (symbol-name (car group)))
                   (mapcar (lambda (b)
                             (list (nth 0 b) (nth 2 b) (nth 1 b)))
                           (cdr group))))
          table))

(defun seance-keys-make-help (name doc table)
  "Define transient prefix NAME (a symbol) showing TABLE's bindings.
DOC becomes the prefix command's docstring."
  (eval `(transient-define-prefix ,name ()
           ,doc
           ,@(seance-keys--transient-groups table))
        t))

(provide 'seance-keys)
;;; seance-keys.el ends here
