;;; seance-context.el --- session preamble for the agent -*- lexical-binding: t; -*-

;;; Commentary:
;; Builds the environment briefing that is prepended to the first prompt
;; of a session, so the agent knows it is embedded in a running Emacs.

;;; Code:

(require 'seance-acp)

(defun seance-context--tools-section ()
  "Describe the emacs_* MCP tools, honestly gated on the bridge setting."
  (if seance-enable-bridge
      "You have MCP tools that act inside that running Emacs:
- emacs_eval: evaluate any Elisp form and get the printed result. Use it to \
test code live and to reload files you changed: (load \"/path/file.el\").
- emacs_buffer_list / emacs_buffer_get: see open buffers including unsaved \
content.
- emacs_describe: docs, arity and source location of functions/variables.
- emacs_state: Emacs version, selected buffer, recent *Messages*."
    "The emacs_* live tools are disabled in this session."))

(defun seance-context-preamble (sess)
  "Environment briefing prepended to the first prompt of SESS."
  (format "\
You are running GNU Emacs %s%s as your host environment: this session is \
embedded in the user's live, running Emacs via the seance package, and the \
chat you are in IS an Emacs buffer.

%s

File reads/writes you perform also go THROUGH Emacs (you see unsaved buffer \
state). The seance package's own source lives at %s — you may modify and \
hot-reload it; the user will review your edits.

Session working directory: %s\n"
          emacs-version
          (if (boundp 'doom-version)
              (format " (Doom Emacs %s)" (symbol-value 'doom-version)) "")
          (seance-context--tools-section)
          (or (ignore-errors
                (directory-file-name
                 (file-name-directory (locate-library "seance"))))
              "an unknown location")
          (seance-acp-session-cwd sess)))

(defun seance-context-wrap (sess text)
  "Prepend the preamble to TEXT on the first turn of SESS only."
  (if (seance-acp-session-preamble-sent sess)
      text
    (setf (seance-acp-session-preamble-sent sess) t)
    (concat (seance-context-preamble sess) "\n---\n\n" text)))

(provide 'seance-context)
;;; seance-context.el ends here
