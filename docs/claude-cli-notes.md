# Claude Code CLI notes (checked 2026-10-29, Claude Code 2.1.312)

What the Nisse daemon relies on. Re-check these when the CLI version changes.

## Flags in use

    claude -p "<prompt>" --output-format stream-json --verbose \
           --session-id <uuid> | --resume <uuid> \
           --settings <file> --dangerously-skip-permissions

- `-p/--print` runs one prompt and exits. `--output-format stream-json` needs `--verbose` with `-p`.
- `--session-id <uuid>` starts a conversation with a chosen id; `--resume <uuid>` continues it.
- `--settings <file>` merges extra settings (the audit hook) without touching the user's own files.
- `--dangerously-skip-permissions` is the "autonomous" mode the design asks for (design section 6.4).
- Other flags that exist and may be used later: `--include-partial-messages`, `--input-format`,
  `--permission-mode`, `--mcp-config`, `--model`, `--remote-control [name]`,
  `--remote-control-session-name-prefix`, `--add-dir`, `--allowedTools`, `--disallowedTools`.
- With stdin attached the CLI waits 3 seconds for piped data. The daemon gives it a closed stdin.

## stream-json output (one JSON object per line)

- `{"type":"system","subtype":"hook_started"|"hook_response"|"init", ...}`: setup noise, ignored.
  `init` is large (tools, plugins, cwd); never commit a raw one.
- `{"type":"assistant","message":{"content":[{"type":"text","text":"..."}, {"type":"tool_use", ...}], ...}}`:
  the reply. Only `text` items are shown in the panel.
- `{"type":"rate_limit_event", ...}`: ignored.
- `{"type":"result","subtype":"success"|"error_*","is_error":bool,"result":"...","session_id":"..."}`:
  last line. `is_error: true` becomes an error in the panel.

`tests/fixtures/hello.jsonl` in nisse-daemon is a hand-reduced copy of a real capture (ids zeroed).

## Install location

The first-boot installer puts the binary at `~/.local/bin/claude`. The daemon looks at `NISSE_CLAUDE_BIN`,
then PATH, then that path.

## Not yet verified

- `--remote-control` on headless or daemon-managed sessions (the panel's per-session checkbox assumes it works).
- The managed-settings path for system-wide hooks. The daemon uses `--settings` instead.
