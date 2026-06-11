;;; seance-bridge.el --- emacs_* tools dispatched from the MCP bridge -*- lexical-binding: t; -*-

;;; Commentary:
;; `seance-bridge-dispatch' is invoked via `emacsclient --eval' by the
;; bridge script (later task).  It returns a JSON string (:ok BOOL :value
;; STRING) so transport errors and tool errors stay distinguishable.

;;; Code:

(require 'json)
(require 'seance)

(declare-function seance-acp-session-permission-mode "seance-acp")

(defun seance-bridge--permission-mode ()
  "Effective permission mode: the active session's, else the defcustom."
  (if (and (boundp 'seance-acp--session)
           (symbol-value 'seance-acp--session))
      (seance-acp-session-permission-mode (symbol-value 'seance-acp--session))
    seance-permission-mode))

(defun seance-bridge-dispatch (tool args-json)
  "Run TOOL with ARGS-JSON (a JSON object string or nil); return JSON string."
  (condition-case err
      (let ((args (and args-json (not (string-empty-p args-json))
                       (json-parse-string args-json :object-type 'plist
                                          :null-object nil :false-object nil))))
        (json-serialize `(:ok t :value ,(seance-bridge--run tool args))))
    (error (json-serialize `(:ok :json-false
                             :value ,(error-message-string err))
                           :false-object :json-false))))

(defun seance-bridge--run (tool args)
  "Execute TOOL with parsed ARGS plist; return the result string."
  (pcase tool
    ("emacs_eval" (seance-bridge--eval (plist-get args :form)))
    ("emacs_buffer_list" (seance-bridge--buffer-list))
    ("emacs_buffer_get" (seance-bridge--buffer-get (plist-get args :name)))
    ("emacs_describe" (seance-bridge--describe (plist-get args :symbol)))
    ("emacs_state" (seance-bridge--state))
    (_ (error "Unknown tool: %s" tool))))

(defun seance-bridge--eval (form-string)
  "Read and eval FORM-STRING, gated by the permission mode."
  (unless form-string (error "emacs_eval needs a :form argument"))
  (when (eq (seance-bridge--permission-mode) 'gated)
    (unless (y-or-n-p (format "seance: Codex wants to eval %s — allow? "
                              (truncate-string-to-width form-string 80 nil nil "…")))
      (error "User denied evaluation")))
  (let ((print-length 200)
        (print-level 20))
    (format "%S" (eval (read form-string) t))))

(defun seance-bridge--buffer-list ()
  "One line per live buffer: name, major mode, file, modified flag."
  (mapconcat
   (lambda (b)
     (with-current-buffer b
       (format "%s | %s | %s%s"
               (buffer-name) major-mode
               (or (buffer-file-name) "no file")
               (if (buffer-modified-p) " [modified]" ""))))
   (buffer-list) "\n"))

(defun seance-bridge--buffer-get (name)
  "Return the full contents of the buffer named NAME."
  (let ((buf (get-buffer (or name ""))))
    (unless buf (error "No such buffer: %s" name))
    (with-current-buffer buf
      (buffer-substring-no-properties (point-min) (point-max)))))

(defun seance-bridge--describe (name)
  "Describe the symbol named NAME as function and/or variable."
  (let ((sym (intern-soft (or name ""))))
    (unless sym (error "Unknown symbol: %s" name))
    (let ((parts nil))
      (when (fboundp sym)
        (push (format "Function: %s\nDoc: %s%s"
                      (ignore-errors (prin1-to-string (func-arity sym)))
                      (or (ignore-errors (documentation sym)) "(no doc)")
                      (if-let* ((loc (ignore-errors
                                       (find-lisp-object-file-name
                                        sym (symbol-function sym)))))
                          (format "\nDefined in: %s" loc)
                        ""))
              parts))
      (when (boundp sym)
        (push (format "Variable value: %S\nDoc: %s"
                      (symbol-value sym)
                      (or (documentation-property sym 'variable-documentation)
                          "(no doc)"))
              parts))
      (unless parts (error "%s is neither bound nor fbound" name))
      (string-join (nreverse parts) "\n\n"))))

(defun seance-bridge--state ()
  "Summarize the running Emacs: version, selected buffer, recent messages."
  (format "Emacs %s%s\nSelected buffer: %s (%s)\nseance source: %s\nRecent *Messages*:\n%s"
          emacs-version
          (if (boundp 'doom-version)
              (format " / Doom %s" (symbol-value 'doom-version)) "")
          (buffer-name (window-buffer (selected-window)))
          (with-current-buffer (window-buffer (selected-window)) major-mode)
          (file-name-directory (locate-library "seance"))
          (if-let* ((msgs (get-buffer "*Messages*")))
              (with-current-buffer msgs
                (buffer-substring-no-properties
                 (max (point-min) (- (point-max) 2000)) (point-max)))
            "")))

(provide 'seance-bridge)
;;; seance-bridge.el ends here
