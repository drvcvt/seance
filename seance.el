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

(provide 'seance)
;;; seance.el ends here
