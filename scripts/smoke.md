# seance live smoke test (uses real Codex tokens)

Prereqs: `codex login` done; `npx @zed-industries/codex-acp --help` works.

1. `emacs -Q -L ~/projects/seance -l seance`, then `M-x seance`
   (or simply `M-x seance` in the daily Emacs).
2. Header line shows `idle · gated`.
3. Send: "What Emacs version are you running inside? Use emacs_state."
   - Expect a tool call entry and the correct version in the answer.
4. Send: "Eval (+ 40 2) in my Emacs." — gated mode must prompt y-or-n in
   the minibuffer; answer y; expect 42.
5. Send: "Create /tmp/seance-smoke.el with a defun hello returning :hi."
   - Expect the permission diff side window; press `a`; file appears.
6. `C-c C-r` — review buffer shows the diff for the file.
7. `C-c C-p` (auto), then ask for an edit to the same file — no prompt,
   edit lands, review buffer shows both edits coalesced.
8. `?` in chat and review buffers shows the transient help.
9. `M-x seance-stop`, header shows `disconnected`, `M-x seance` reconnects.
