;;; seance-review.el --- permission gating and session review -*- lexical-binding: t; -*-

;;; Commentary:
;; Gated mode: every session/request_permission opens a diff side window
;; (a=allow, d=deny, A=allow rest of session).  Auto mode: allow silently.
;; The session review buffer itself arrives in a later task.

;;; Code:

(require 'seance-acp)
(require 'seance-diff)
(require 'seance-keys)
(require 'diff-mode)

(defvar seance-review-permission-buffer "*seance permission*"
  "Name of the buffer showing pending permission requests.")

(defvar-local seance-review--reply nil
  "Pending REPLY closure for the displayed permission request.")
(defvar-local seance-review--options nil
  "Options vector of the displayed permission request.")
(defvar-local seance-review--session nil
  "Session the displayed permission request belongs to.")

(defun seance-review--pick-option (options &rest kinds)
  "Return the optionId of the first option in OPTIONS matching KINDS, in order.
Falls back to the first option when no kind matches."
  (catch 'found
    (dolist (kind kinds)
      (seq-doseq (opt options)
        (when (equal (plist-get opt :kind) kind)
          (throw 'found (plist-get opt :optionId)))))
    (plist-get (aref options 0) :optionId)))

(defun seance-review--outcome (option-id)
  "Build a session/request_permission result selecting OPTION-ID."
  `(:outcome (:outcome "selected" :optionId ,option-id)))

(defun seance-review-handle-permission (sess params reply)
  "ACP session/request_permission entry point.
SESS is the session, PARAMS the request params, REPLY the async
result continuation.  Auto mode allows immediately; gated mode
shows the diff side window and waits for the user."
  (if (eq (seance-acp-session-permission-mode sess) 'auto)
      (funcall reply (seance-review--outcome
                      (seance-review--pick-option
                       (plist-get params :options)
                       "allow_once" "allow_always")))
    (seance-review--show-permission sess params reply)))

(defun seance-review--permission-text (tool-call)
  "Human-readable description and diff for TOOL-CALL."
  (concat
   (format "Codex requests: %s\n\n" (or (plist-get tool-call :title) "tool call"))
   (mapconcat
    (lambda (item)
      (pcase (plist-get item :type)
        ("diff" (seance-diff-strings (or (plist-get item :oldText) "")
                                     (or (plist-get item :newText) "")
                                     (plist-get item :path)))
        (_ (format "%S\n" item))))
    (append (plist-get tool-call :content) nil)
    "\n")))

(defvar seance-keys-permission-table
  '((decision
     ("a" seance-review-allow "Allow once")
     ("d" seance-review-deny "Deny")
     ("A" seance-review-allow-all "Allow all (rest of session)")))
  "Binding table for the permission diff window.")

(seance-keys-make-help 'seance-permission-help "seance permission bindings"
                       seance-keys-permission-table)
;; Defined at load time by the form above; tell the byte-compiler.
(declare-function seance-permission-help "seance-review")

(defun seance-review--show-permission (sess params reply)
  "Display PARAMS' tool call in the permission buffer; REPLY answers later.
SESS is stored buffer-locally so `seance-review-allow-all' can flip
its permission mode."
  (let ((buf (get-buffer-create seance-review-permission-buffer)))
    (with-current-buffer buf
      ;; An unanswered earlier request would be orphaned by the rebuild
      ;; below (diff-mode wipes the buffer-locals holding its reply), so
      ;; answer it with the protocol's cancelled outcome first.
      (when seance-review--reply
        (let ((stale seance-review--reply))
          (setq seance-review--reply nil)
          (funcall stale '(:outcome (:outcome "cancelled")))))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (seance-review--permission-text (plist-get params :toolCall)))
        ;; The mode change wipes buffer-locals; set ours afterwards.
        (diff-mode)
        (let ((map (copy-keymap diff-mode-map)))
          (seance-keys-apply seance-keys-permission-table map)
          (define-key map (kbd "?") #'seance-permission-help)
          (use-local-map map))
        (setq buffer-read-only t)
        (setq seance-review--reply reply
              seance-review--options (plist-get params :options)
              seance-review--session sess)))
    (display-buffer buf '(display-buffer-in-side-window (side . right)))))

(defun seance-review--answer (&rest kinds)
  "Answer the pending permission request with the first option matching KINDS.
Kills the permission buffer: once answered it is stale UI, and its
existence doubles as the \"request pending\" signal."
  (unless seance-review--reply
    (user-error "No pending permission request"))
  (let ((reply seance-review--reply)
        (id (apply #'seance-review--pick-option seance-review--options kinds))
        (buf (current-buffer)))
    (setq seance-review--reply nil)
    (if-let* ((win (get-buffer-window buf)))
        (quit-window 'kill win)
      (kill-buffer buf))
    (funcall reply (seance-review--outcome id))))

(defun seance-review-allow ()
  "Allow this tool call once."
  (interactive)
  (seance-review--answer "allow_once" "allow_always"))

(defun seance-review-deny ()
  "Reject this tool call."
  (interactive)
  (seance-review--answer "reject_once" "reject_always"))

(defun seance-review-allow-all ()
  "Allow this and all further tool calls this session (switch to auto)."
  (interactive)
  ;; Read the session local before --answer kills the buffer; flip the
  ;; mode only after a successful answer (a failed answer must not
  ;; silently disable gating).
  (let ((sess seance-review--session))
    (seance-review--answer "allow_always" "allow_once")
    (setf (seance-acp-session-permission-mode sess) 'auto)))

;; Register as the ACP permission handler.
(setq seance-acp--permission-function #'seance-review-handle-permission)

;; --- buffer-aware fs + edit log -------------------------------------------

(defvar seance-review--edit-log nil
  "List of edits, newest first: plists (:path :before :after).")

(defun seance-review-read-file (path)
  "Content of PATH as the agent should see it: live buffer over disk."
  (if-let* ((buf (find-buffer-visiting path)))
      (with-current-buffer buf
        (buffer-substring-no-properties (point-min) (point-max)))
    (with-temp-buffer
      (insert-file-contents path)
      (buffer-string))))

(defun seance-review-write-file (path content)
  "Write CONTENT to PATH through Emacs, recording the edit.
If a buffer visits PATH: replace its content; save only when the buffer
had no unsaved user changes.  Otherwise write straight to disk.
The edit-log entry is pushed only after a successful write."
  (let ((before (if (or (find-buffer-visiting path) (file-exists-p path))
                    (seance-review-read-file path)
                  "")))
    (if-let* ((buf (find-buffer-visiting path)))
        (with-current-buffer buf
          (let ((was-clean (not (buffer-modified-p))))
            (let ((inhibit-read-only t))
              (let ((tmp (generate-new-buffer " *seance-write-tmp*")))
                (unwind-protect
                    (progn
                      (with-current-buffer tmp (insert content))
                      (replace-buffer-contents tmp))
                  (kill-buffer tmp))))
            (when was-clean
              (let ((inhibit-message t))
                (save-buffer)))))
      (let ((dir (file-name-directory (expand-file-name path))))
        (make-directory dir t))
      (write-region content nil path nil 'silent))
    (push (list :path path :before before :after content)
          seance-review--edit-log)))

(setq seance-acp--fs-read-function #'seance-review-read-file)
(setq seance-acp--fs-write-function #'seance-review-write-file)

;; --- session review buffer -------------------------------------------------

(defvar seance-review-buffer "*seance review*"
  "Name of the session review buffer.")

(defvar seance-keys-review-table
  '((review
     ("C-c C-a" diff-apply-hunk "Apply hunk (C-u: revert)")
     ("n" diff-hunk-next "Next hunk")
     ("p" diff-hunk-prev "Previous hunk")
     ("q" quit-window "Quit")))
  "Binding table shown in the review buffer's ? help.
These are diff-mode's own bindings; the table only documents them.")

(seance-keys-make-help 'seance-review-help "seance review bindings"
                       seance-keys-review-table)
;; Defined at load time by the form above; tell the byte-compiler.
(declare-function seance-review-help "seance-review")

(defun seance-review--coalesced ()
  "Edit log grouped per file: (PATH FIRST-BEFORE LAST-AFTER), one entry per file.
The log is newest-first, so per path: :before of the LAST entry seen is
the original, :after of the FIRST entry seen is the final state."
  (let ((per-file nil))  ; alist path -> (final-after original-before)
    (dolist (e seance-review--edit-log)
      (let* ((path (plist-get e :path))
             (cell (assoc path per-file)))
        (if cell
            (setcdr (cdr cell) (list (plist-get e :before)))  ; older entry: update original
          (push (cons path (list (plist-get e :after) (plist-get e :before)))
                per-file))))
    (mapcar (lambda (cell)
              (list (car cell) (nth 1 (cdr cell)) (nth 0 (cdr cell))))
            (nreverse per-file))))

;;;###autoload
(defun seance-review ()
  "Show everything this session changed, as one reviewable unified diff."
  (interactive)
  ;; Compute the base directory from the caller's context BEFORE entering the
  ;; review buffer, so the fallback is the invocation's default-directory, not
  ;; whatever stale value the buffer may have inherited.
  (let ((base-dir (or (and seance-acp--session
                           (seance-acp-session-cwd seance-acp--session))
                      default-directory))
        (buf (get-buffer-create seance-review-buffer)))
    (with-current-buffer buf
      (setq default-directory base-dir)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (let ((groups (seance-review--coalesced)))
          (if (null groups)
              (insert "No edits recorded in this session.\n")
            (dolist (g groups)
              (insert (seance-diff-strings
                       (nth 1 g) (nth 2 g)
                       (file-relative-name (nth 0 g) base-dir))))))
        (diff-mode)
        (let ((map (copy-keymap diff-mode-map)))
          (define-key map (kbd "?") #'seance-review-help)
          (use-local-map map))
        (setq buffer-read-only t)))
    (pop-to-buffer buf)))

(provide 'seance-review)
;;; seance-review.el ends here
