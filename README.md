# seance

seance summons Codex into a running Emacs. It is a pure-Elisp client for the
Agent Client Protocol (ACP) that spawns the `@zed-industries/codex-acp`
adapter as a subprocess and talks to it over stdio — no extra daemon, no
Emacs packages beyond what ships with Emacs 30. The agent does not just edit
your files: through an MCP bridge it can evaluate Elisp in your live session,
inspect your buffers (including unsaved state), and hot-reload its own client.

```
Emacs (chat buffer, permission UI, review buffer)
  |  stdio: ACP (ndjson JSON-RPC)
  v
npx @zed-industries/codex-acp  <-->  Codex (auth from your ~/.codex login)
  |  stdio: MCP
  v
bin/seance-mcp-bridge.el (emacs --batch MCP server, spawned by the adapter)
  |  emacsclient --eval over the Emacs server's Unix socket
  v
the same running Emacs (seance-bridge-dispatch: the emacs_* tools)
```

File reads and writes also route through Emacs: the agent's ACP fs requests
are served from live buffer state, and its writes land in your buffers.

## Requirements

- Emacs 30.1 or newer (transient ships with it; nothing else is needed)
- Node.js with `npx` — the adapter is fetched/run as `npx @zed-industries/codex-acp`
- A logged-in Codex CLI: run `codex login` once; the adapter reuses `~/.codex`
- `diff` in `PATH` (used for permission and review diffs)

## Install

Doom Emacs:

```elisp
;; packages.el
(package! seance :recipe (:local-repo "~/projects/seance"))
;; config.el
(use-package! seance
  :commands (seance)
  :config (setq seance-permission-mode 'gated))
(map! :leader :desc "seance chat" "o x" #'seance)
```

Vanilla Emacs:

```elisp
(add-to-list 'load-path "~/projects/seance")
(require 'seance)
(setq seance-permission-mode 'gated)
```

or with use-package:

```elisp
(use-package seance
  :load-path "~/projects/seance"
  :commands (seance)
  :config (setq seance-permission-mode 'gated))
```

## Usage

`M-x seance` opens the chat buffer and connects a session rooted at the
current project (see `seance-cwd-function`). The header line shows the
session status, the permission mode, and the working directory.
`C-u M-x seance` (Doom: `C-u SPC o x`) starts the session in auto
permission mode — or switches an already running session to auto.

Commands:

- `seance` — open the chat buffer, connecting a session if needed
  (with prefix argument: in auto permission mode)
- `seance-stop` — disconnect the session
- `seance-toggle-permission-mode` — flip gated/auto for the active session
- `seance-review` — open the session review buffer

Chat buffer keys:

| Key | Action |
|---|---|
| `RET` | Send prompt |
| `S-RET` | Insert newline in the input field |
| `M-p` / `M-n` | Cycle input history |
| `TAB` | Fold/unfold the thought block or tool-call detail at point |
| `C-c C-k` | Cancel the in-flight turn |
| `C-c C-c` | Allow the pending tool call (without leaving the chat) |
| `C-c C-d` | Deny the pending tool call |
| `C-c C-p` | Toggle gated/auto permission mode |
| `C-c C-r` | Open the session review buffer |
| `C-c C-q` | Stop the session |
| `?` | Binding help (in the transcript; in the input field it types `?`) |

`?` opens a transient menu listing the live bindings in every seance buffer:
the chat buffer, the permission side window, and the review buffer. The menu
is generated from the same tables that build the keymaps, so it cannot drift.

Permission modes:

- `gated` (default): every agent tool call that needs permission opens a
  diff side window. Answer straight from the chat buffer with `C-c C-c`
  (allow) / `C-c C-d` (deny), or in the diff window with `a` to allow
  once, `d` to deny, `A` to allow everything for the rest of the session
  (switches the session to auto).
- `auto`: tool calls are allowed silently; edits are still recorded for
  review.

Review buffer (`C-c C-r` / `M-x seance-review`): everything the session
changed, coalesced per file into one unified diff (first original against
last result, intermediate steps folded away), shown in `diff-mode`. To
revert a hunk the agent applied, put point on it and press `C-u C-c C-a`
(`diff-apply-hunk` reversed). `n`/`p` move between hunks, `q` quits.

## The emacs_* tools

When `seance-enable-bridge` is non-nil (default), the agent gets MCP tools
that act inside your running Emacs:

| Tool | What it does |
|---|---|
| `emacs_eval` | Evaluate one Elisp form, return the printed result |
| `emacs_buffer_list` | List live buffers: name, mode, file, modified flag |
| `emacs_buffer_get` | Full text of a named buffer, including unsaved changes |
| `emacs_describe` | Doc, arity and source location of a function/variable |
| `emacs_state` | Emacs version, selected buffer, recent `*Messages*` |

The bridge needs the Emacs server (`M-x server-start`); in an interactive
Emacs it is started automatically when a session connects. In batch Emacs
the bridge is offered only if a server is already running.

Security model, honestly: `emacs_eval` is exactly as powerful as you at the
keyboard — it can do anything Elisp can do, and that is the point of the
package. What seance gives you is consent and visibility, not a sandbox: in
gated mode every eval prompts y-or-n in the minibuffer and the full form is
logged to `*Messages*` before you answer; in auto mode you have explicitly
opted out of the prompt. The one place where agent-supplied strings could
otherwise reach `funcall` is code-fence fontification, and that lookup is
restricted to the `seance-chat-fence-modes` alist — an unknown fence
language renders as plain text, never as a derived function name.

## Customization

- `seance-codex-acp-command` — command list that starts the adapter
  (default `("npx" "@zed-industries/codex-acp")`)
- `seance-permission-mode` — default permission mode for new sessions,
  `gated` or `auto`
- `seance-enable-bridge` — whether to expose the emacs_* tools at all
- `seance-cwd-function` — function returning the working directory for new
  sessions (default: current project root, else `default-directory`)
- `seance-chat-fence-modes` — alist mapping markdown fence languages to
  major modes for transcript fontification

## Testing

```sh
./scripts/test.sh
```

Runs the full ERT suite headlessly against a mock ACP agent — no network,
no Codex tokens. A manual end-to-end checklist that does use real tokens is
in `scripts/smoke.md`.

## Limitations

- One session at a time (single chat buffer) in v1.
- The bridge only supports the local Unix-socket Emacs server; `server-use-tcp`
  is not supported.
- Code-fence fontification covers only the languages in
  `seance-chat-fence-modes`; extend the alist for more.
