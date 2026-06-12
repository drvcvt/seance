;;; seance-bridge.el --- emacs_* tools dispatched from the MCP bridge -*- lexical-binding: t; -*-

;;; Commentary:
;; `seance-bridge-dispatch' is invoked via `emacsclient --eval' by the
;; bridge script (later task).  It returns a JSON string (:ok BOOL :value
;; STRING) so transport errors and tool errors stay distinguishable.

;;; Code:

(require 'json)
(require 'server)
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
    (message "seance: full eval form: %s" form-string)
    (unless (y-or-n-p (format "seance: Codex wants to eval %s — allow? "
                              (truncate-string-to-width form-string 80 nil nil "…")))
      (error "User denied evaluation")))
  (let* ((result (read-from-string form-string))
         (form (car result))
         (end-index (cdr result))
         (tail (substring form-string end-index)))
    (unless (string-match-p "\\`[[:space:]]*\\'" tail)
      (error "emacs_eval: trailing content after first form"))
    (let ((print-length 200)
          (print-level 20))
      (format "%S" (eval form t)))))

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

(defun seance-bridge--script-path ()
  "Absolute path of bin/seance-mcp-bridge.el.
Resolves the library file's truename first: package managers like
straight symlink the .el files into a build directory that does not
contain bin/, so the path must be anchored at the real source tree."
  (expand-file-name "bin/seance-mcp-bridge.el"
                    (file-name-directory
                     (file-truename (locate-library "seance-bridge")))))

(defun seance-bridge--server-live-p ()
  "Return non-nil if this Emacs has a live server process."
  (and server-process (process-live-p server-process)))

(defun seance-bridge-mcp-servers ()
  "Vector of MCP server specs to hand to ACP session/new.
Returns [] when `seance-enable-bridge' is nil.  In noninteractive
Emacs a server is never auto-started: batch sessions rarely want one
implicitly (and the test suite manages its own), so without an
already-running server this also returns [].  Interactively, the
server is started on demand.  SEANCE_SERVER carries the ABSOLUTE
socket path -- emacsclient -s accepts a full path as well as a bare
name -- so the bridge script finds the server even when
`server-socket-dir' is non-default."
  (cond
   ((not seance-enable-bridge) [])
   ((and noninteractive (not (seance-bridge--server-live-p))) [])
   (t
    (unless (seance-bridge--server-live-p)
      ;; Another process (e.g. an `emacs --fg-daemon') may already own
      ;; the configured socket name; `server-start' would then just warn
      ;; and leave this Emacs serverless, while SEANCE_SERVER below would
      ;; route the bridge's emacsclient calls into that foreign process.
      ;; Don't fight over the default socket: a dedicated name keeps the
      ;; daemon's emacsclient workflow untouched and routes the bridge
      ;; into THIS Emacs.  A stale dead socket is unaffected:
      ;; `server-running-p' returns nil and `server-start' reclaims it.
      ;; setq (not let) is deliberate so server.el's exit cleanup uses
      ;; the matching name; mutating `server-name' is safe because this
      ;; Emacs demonstrably had no server of its own.
      (when (server-running-p server-name)
        (setq server-name (format "seance-%d" (emacs-pid))))
      (server-start))
    (vector
     `(:name "seance-emacs"
       :command ,(expand-file-name invocation-name invocation-directory)
       :args ["--batch" "--script" ,(seance-bridge--script-path)]
       :env [(:name "SEANCE_SERVER"
              :value ,(expand-file-name server-name server-socket-dir))])))))

(provide 'seance-bridge)
;;; seance-bridge.el ends here
