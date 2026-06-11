;;; seance.el --- Codex ACP client for Emacs -*- lexical-binding: t; -*-

;; Author: dracut
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; Keywords: tools, convenience
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; seance summons Codex into a running Emacs via the Agent Client
;; Protocol (ACP), using the @zed-industries/codex-acp adapter.

;;; Code:

(require 'project)

(defgroup seance nil
  "Codex ACP client for Emacs."
  :group 'tools
  :prefix "seance-")

(defcustom seance-codex-acp-command '("npx" "@zed-industries/codex-acp")
  "Command (list of strings) that starts the ACP agent adapter."
  :type '(repeat string))

(defcustom seance-permission-mode 'gated
  "How tool permissions are handled.
`gated' asks per request with a diff; `auto' allows everything and
collects edits for later review."
  :type '(choice (const gated) (const auto)))

(defcustom seance-enable-bridge t
  "If non-nil, expose the emacs_* MCP tools (live-eval bridge) to the agent."
  :type 'boolean)

(defcustom seance-cwd-function #'seance--default-cwd
  "Function returning the working directory for new sessions."
  :type 'function)

(defun seance--default-cwd ()
  "Project root of `default-directory', else `default-directory'."
  (if-let* ((proj (project-current nil)))
      (project-root proj)
    default-directory))

;; Entry commands.  seance-chat/seance-acp are required lazily inside the
;; commands: a top-level require would be circular (seance-chat ->
;; seance-acp -> seance).  Declarations below keep byte-compilation clean.

(declare-function seance-chat-mode "seance-chat" ())
(declare-function seance-chat--initialize "seance-chat" ())
(declare-function seance-acp-disconnect "seance-acp" (sess))
(declare-function seance-acp-toggle-permission-mode "seance-acp" (sess))
(declare-function seance-acp-session-rpc "seance-acp" (cl-x))
(declare-function seance-rpc-alive-p "seance-rpc" (conn))
(defvar seance-chat-buffer-name)
(defvar seance-chat--session)
(defvar seance-acp--session)

;;;###autoload
(defun seance ()
  "Open the seance chat buffer, connecting a session if needed."
  (interactive)
  (require 'seance-chat)
  (let ((buf (get-buffer-create seance-chat-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'seance-chat-mode)
        (seance-chat-mode))
      (unless (and seance-chat--session
                   (seance-rpc-alive-p
                    (seance-acp-session-rpc seance-chat--session)))
        (seance-chat--initialize)))
    (pop-to-buffer buf)))

(defun seance-stop ()
  "Disconnect the current seance session."
  (interactive)
  (require 'seance-chat)
  (when-let* ((buf (get-buffer seance-chat-buffer-name)))
    (with-current-buffer buf
      (when seance-chat--session
        (seance-acp-disconnect seance-chat--session)
        (when (eq seance-acp--session seance-chat--session)
          (setq seance-acp--session nil))))))

(defun seance-toggle-permission-mode ()
  "Toggle the chat buffer's session between gated and auto permission mode."
  (interactive)
  (require 'seance-chat)
  (if-let* ((buf (get-buffer seance-chat-buffer-name))
            (sess (buffer-local-value 'seance-chat--session buf)))
      (progn
        (message "seance: permission mode is now %s"
                 (seance-acp-toggle-permission-mode sess))
        (force-mode-line-update t))
    (user-error "No active seance session")))

;; Deliberately NOT a plain `autoload': transient force-loads autoloaded
;; suffix commands when the `?' help menu opens (transient--init-suffix
;; calls `autoload-do-load'), which would signal file-missing until
;; seance-review.el exists (Task 9).  This trampoline keeps the menu
;; openable now; loading seance-review.el replaces it with the real
;; command, after which the recursive call below dispatches to it.
(defun seance-review ()
  "Open the seance session review buffer."
  (interactive)
  (require 'seance-review)
  (seance-review))

(provide 'seance)
;;; seance.el ends here
