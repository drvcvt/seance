# seance — Codex ACP client for Emacs

Date: 2026-06-11
Status: approved design, pre-implementation

## Purpose

`seance` summons Codex (via the user's existing Codex subscription) into a
running Emacs as a first-class agentic coding tool. It is an ACP (Agent
Client Protocol) client written in pure Emacs Lisp. Beyond a chat UI and a
change-review workflow, the defining feature is deep integration with the
live Emacs instance: Codex knows it is operating inside an Elisp
environment, can introspect and evaluate code in the running editor, and can
therefore modify and immediately test seance itself.

## Goals

1. Chat buffer with streaming responses, readable markdown rendering, and
   collapsible tool-call entries.
2. Change review with two switchable modes: per-edit gating with diff
   accept/reject, and autonomous mode with an end-of-session review buffer.
3. Buffer-aware file access: Codex reads and writes files *through Emacs*,
   seeing unsaved buffer state.
4. Live-eval bridge: Codex gets MCP tools to evaluate Elisp, inspect
   buffers, and read documentation in the running Emacs.
5. Context injection: every session starts with a preamble describing the
   Emacs environment and the available Emacs tools.
6. Fully testable offline via a scripted mock ACP agent (no token usage).

## Non-goals (v1)

- Support for agents other than Codex (the ACP core should not preclude it,
  but nothing is built or tested for it).
- ACP terminal capability (Codex runs shell commands through its own
  sandbox; client-side terminals are a possible later phase).
- MELPA packaging, multi-Emacs-version support (target: Emacs 30+).
- Session persistence/replay across Emacs restarts.

## Architecture

```
┌─ Emacs (running instance) ─────────────────────────────┐
│  seance-chat (UI) ── seance-review (diffs/permissions) │
│        │                                               │
│  seance-acp (jsonrpc.el over stdio)                    │
└────────┼────────────────────────────▲──────────────────┘
         │ ACP / JSON-RPC stdio       │ emacsclient --eval
         ▼                            │
   codex-acp adapter ── spawns ──▶ MCP bridge
   (@zed-industries/codex-acp)     (emacs --batch script)
```

- Emacs spawns the `codex-acp` adapter as a subprocess and speaks ACP
  (JSON-RPC 2.0 over stdio, newline-delimited JSON framing) with it via a
  small own JSON-RPC layer (`seance-rpc.el`). The built-in `jsonrpc.el` is
  not used: it assumes Content-Length header framing and can only answer
  incoming requests synchronously, but ACP permission requests need
  asynchronous replies (the agent waits while the user reviews a diff).
- The adapter wraps Codex and uses the existing auth in `~/.codex`; no
  separate login flow is needed when the user is already logged in to the
  Codex CLI.
- At `session/new`, seance passes an MCP server spec for its own bridge: a
  batch-Emacs script that speaks MCP over stdio and forwards each tool call
  into the running Emacs via `emacsclient --eval`. Results flow back the
  same way. This keeps the entire stack Lisp.
- seance advertises the ACP client capabilities `fs.readTextFile` and
  `fs.writeTextFile`, so the agent's file reads/writes are served by Emacs
  (buffer-aware).

## Components

One package, several files. Public prefix `seance-`, private `seance--`.

### `seance.el` — entry point

Autoloaded commands: `seance` (open/focus chat, starting a session if
needed), `seance-stop`, `seance-toggle-permission-mode`, `seance-review`.
Defcustoms:

- `seance-codex-acp-command` — list, default `("npx" "@zed-industries/codex-acp")`.
- `seance-permission-mode` — `gated` (default) or `auto`.
- `seance-cwd-function` — returns session cwd; default: `project.el` root,
  falling back to `default-directory`.

### `seance-rpc.el` — JSON-RPC transport (no ACP knowledge)

Newline-delimited JSON-RPC 2.0 over a stdio subprocess: request/response
correlation, notifications in both directions, and asynchronous reply
callbacks for incoming requests. Pure transport; reusable for the mock
agent in tests.

### `seance-acp.el` — protocol core (no UI)

Owns the adapter process and the `seance-rpc` connection. Implements the
ACP subset seance needs:

- Outgoing requests: `initialize`, `session/new` (with `cwd` and
  `mcpServers`), `session/prompt`, `session/cancel`.
- Incoming notifications: `session/update` with kinds
  `agent_message_chunk`, `agent_thought_chunk`, `tool_call`,
  `tool_call_update`, `plan`.
- Incoming requests: `session/request_permission` (delegated to
  seance-review), `fs/read_text_file`, `fs/write_text_file` (served
  buffer-aware: if the file is open in a buffer, read from / write into the
  buffer; otherwise hit disk).

Exposes a small callback API (`seance-acp-on-update`, etc.) consumed by the
UI layers; no chat/review code lives here. Process death or jsonrpc errors
surface through a status callback; the chat header line shows connection
state and `seance` reconnects on demand.

### `seance-chat.el` — chat buffer

Custom major mode derived from `special-mode` with an editable input field
at the end of the buffer (text-property based field boundary).

- RET sends, S-RET inserts a newline, `M-p`/`M-n` cycle input history,
  `C-c C-k` cancels the in-flight turn.
- Agent output streams in above the input field. Markdown is rendered
  incrementally: fenced code blocks are fontified with the block's major
  mode; bold/inline-code/headings get faces.
- Tool calls render as one-line collapsible entries, e.g.
  `▸ edit seance-chat.el (+12 −3)`; TAB expands to the full
  content/diff. `tool_call_update` mutates the entry in place
  (status spinner → ✓/✗).
- Agent plan updates render as a compact checklist block that updates in
  place.
- The header line shows session state (idle/thinking/streaming/error) and
  the current permission mode.

### Binding help (discoverability)

Every seance buffer (chat, review buffer, permission diff window) binds `?`
to a `transient` menu (built into Emacs 28+) listing that buffer's bindings,
grouped by topic (input, navigation, tool calls, session, review) with a
short description per key. Entries are dispatchable: pressing the key inside
the menu runs the command, so the cheatsheet doubles as a command palette.
The header line hints at it (`? = help`). Keymaps and the transient are
defined from one shared table per mode so the help can never drift out of
sync with the actual bindings.

### `seance-review.el` — permissions and diffs

Gated mode: each `session/request_permission` for a file edit opens a side
window with the proposed diff in `diff-mode`. Keys: `a` allow once, `d`
deny, `A` allow all for the rest of the session (switches the session to
auto). The pending request blocks the agent until answered; the chat buffer
shows a "waiting for permission" marker.

Auto mode: permission requests are answered with "allow" automatically.
Every applied edit is recorded (file, before/after). `seance-review` opens
a session review buffer: a unified diff of everything the session changed,
in `diff-mode`, so standard hunk navigation and `diff-mode`'s apply/revert
work for selectively undoing hunks.

Both modes record into the same edit log; gated mode's accepted edits also
appear in the review buffer.

### `seance-bridge.el` + `bin/seance-mcp-bridge` — live-eval layer

`bin/seance-mcp-bridge` is an Elisp script run as `emacs --batch --script`.
It speaks MCP (stdio JSON-RPC) to the adapter and forwards each tool
invocation to the running Emacs with `emacsclient --eval
'(seance-bridge-dispatch ...)'`, returning the printed result.

`seance-bridge.el` (loaded in the main Emacs) implements the dispatch and
the tools:

- `emacs_eval` — evaluate an Elisp form, return result or error. Wrapped in
  `condition-case`; errors return as MCP tool errors, never propagate.
- `emacs_buffer_list` — buffer names, modes, file names, modified flags.
- `emacs_buffer_get` — full or ranged contents of a named buffer.
- `emacs_describe` — documentation and source location for a function or
  variable (what `describe-function`/`describe-variable` know).
- `emacs_state` — Emacs version, current buffer/mode, loaded features
  relevant to seance, tail of `*Messages*`.

Security stance: `emacs_eval` is exactly as powerful as the user at the
keyboard; that is the point of the project. In gated permission mode,
`emacs_eval` calls also go through a permission prompt; in auto mode they
run directly. The bridge requires `server-start`; seance starts the Emacs
server when the first session opens if it is not already running.

### `seance-context.el` — session preamble

The first prompt of every session is prefixed with a generated preamble:
Emacs version and flavor (Doom), the fact that the agent is operating
inside the user's live Emacs, the list and semantics of the `emacs_*`
tools, the location of seance's own source tree, and the advice that
changes to seance can be loaded and tested immediately via `emacs_eval`.

## Error handling

- Adapter process exit → status callback → chat header shows
  `disconnected`; next `seance` invocation or an explicit reconnect command
  restarts it. In-flight turn is marked failed in the chat.
- JSON-RPC errors on our requests render as error blocks in the chat.
- Bridge tool errors (eval failures, missing buffers) return structured
  errors to the agent; the running Emacs is never left in a broken state.
- `fs/write_text_file` to a buffer marks the buffer modified but does not
  save it unless the buffer was unmodified and visiting the file — exact
  save semantics: write into buffer, then save if the buffer had no
  unsaved user changes before the write; otherwise leave unsaved and let
  review/user decide.

## Testing

- ERT suite run headless via `scripts/test.sh` (`emacs --batch`).
- `tests/mock-agent.el`: a batch-Emacs script speaking enough ACP on stdio
  to drive scripted scenarios (streamed chunks, tool calls, permission
  requests, fs round-trips). Unit/integration tests run the real
  `seance-acp.el` against it — full client coverage with zero tokens.
- Bridge tests call `seance-bridge-dispatch` directly in-process, plus one
  test spawning the real batch bridge against a live `server-start`.
- A manual live smoke test (`scripts/smoke.sh` + checklist) against the
  real `codex-acp` adapter validates auth, streaming, and a real edit.

## Build phases

1. **Core + minimal chat** — spawn adapter, initialize, session/new,
   send prompt, stream plain text into the chat buffer.
2. **Tool calls + gated review** — tool-call rendering, permission flow,
   diff side window, `?` binding-help transients for all seance buffers.
3. **Buffer-aware fs** — serve `fs/read_text_file` / `fs/write_text_file`.
4. **Bridge + context** — MCP bridge script, `emacs_*` tools, preamble.
5. **Auto mode + review buffer + polish** — edit log, session diff review,
   markdown rendering polish, history, Doom keybinding snippet in README.

## License / repo

GPL-3.0-or-later (Emacs ecosystem standard). Repo: `~/projects/seance`.
