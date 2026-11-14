# Claude Code CLI notes (checked 2026-10-29 on 2.1.312; permissions, hooks and managed settings re-checked 2026-11-13 on 2.1.325)

What the nisse daemon relies on. Re-check these when the CLI version changes. The probes in `tools/claude-probe/` re-run
the permission experiments (each run is a real prompt, a few seconds, a few cents of the Max plan).

## Flags in use

    claude -p "<prompt>" --output-format stream-json --verbose \
           --session-id <uuid> | --resume <uuid> \
           --settings <file> --dangerously-skip-permissions

- `-p/--print` runs one prompt and exits. `--output-format stream-json` needs `--verbose` with `-p`.
- `--session-id <uuid>` starts a conversation with a chosen id; `--resume <uuid>` continues it.
- `--settings <file>` merges extra settings (the audit hook) without touching the user's own files.
- The audit hook format was checked against the real CLI on 2026-10-29 (review decision 3): PreToolUse and PostToolUse
  both fire, and the payload carries `session_id`, `tool_name`, `tool_input` and `hook_event_name`.
- Authority is a config switch (`authority = "autonomous" | "supervised"` at the top of `backends.toml`, default
  autonomous; any other value, or a config file that cannot be read, counts as supervised):
  - autonomous passes `--dangerously-skip-permissions`, the mode the design asks for (design section 6.4).
  - supervised passes `--permission-mode default`. In `-p` mode with the prompt on the command line nothing can answer
    a permission prompt, so actions that need one are denied (verified 2026-11-13, see "Permission behavior" below).
    The approvals queue (N-203, N-204, N-222) replaces this with the host protocol described there.
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

## Permission behavior in -p mode (verified 2026-11-13, CLI 2.1.325, ledger N-201)

Method: one tiny session per row in a fresh empty folder, prompt "Use the Bash tool to run exactly this command:
`echo hello > made.txt`, then reply only `done`, or `denied` if the tool did not run", with
`-p --output-format stream-json --verbose --max-turns 4 --setting-sources project --strict-mcp-config`. Run on Windows
(the permission logic does not depend on the OS); `tools/claude-probe/probe_cli.py LABEL [flags]` repeats it.

| Flags | File made | What the CLI did |
|---|---|---|
| `--permission-mode default` (what supervised sends today) | no | The Bash call comes back as a tool error "Output redirection to '...' needs approval ...". A `{"type":"system","subtype":"permission_denied"}` event (tool_name, tool_use_id, message) is emitted at once. The last line is `result` with `subtype:"success"`, `is_error:false`, and `permission_denials:[{tool_name, tool_use_id, tool_input}]`. Exit code 0. The model carries on and answers. |
| `--permission-mode manual` | no | Identical to `default`. The help lists `acceptEdits, auto, bypassPermissions, manual, dontAsk, plan`; `default` is not listed but is still accepted (a hidden alias), `manual` is the documented name. |
| `--permission-mode dontAsk` | no | Denied; the message says the CLI is "running in don't ask mode". |
| `--permission-mode default --permission-prompts none` | no | Denied automatically with a clearer message: "this session has no approval surface ... will be denied the same way for the rest of this session". |
| `--permission-mode default --permission-prompts host`, prompt on the command line | no | Same as `default`: no host is asked. |
| `--permission-mode bypassPermissions` | yes | Runs. `permission_denials` is empty. The daemon's autonomous mode uses `--dangerously-skip-permissions`. |

A denial is not an error to the caller: exit 0, `is_error:false`. The daemon sees a denial only through the
`permission_denied` event or the `permission_denials` list, and by then the model has already been told "denied".

### Host protocol: the host answers permission prompts (the basis for the approvals queue)

    claude -p --input-format stream-json --output-format stream-json --verbose \
           --permission-mode default --permission-prompts host --permission-prompt-tool stdio

- `--permission-prompt-tool stdio` is required. With only `--permission-prompts host` the CLI never asks (row above).
- The host writes the prompt as one stdin line: `{"type":"user","message":{"role":"user","content":"..."}}`.
- When a call needs approval the CLI writes a `control_request` and waits:
  `{"type":"control_request","request_id":"...","request":{"subtype":"can_use_tool","tool_name","display_name","input","description","permission_suggestions":[...],"blocked_path","tool_use_id"}}`.
  `permission_suggestions` offers `addRules` (for example allow `Bash(echo hello *)` to `localSettings`) and
  `addDirectories` entries.
- The host answers on stdin: `{"type":"control_response","response":{"subtype":"success","request_id":"...","response":{"behavior":"allow","updatedInput":<the input>}}}`
  or `"response":{"behavior":"deny","message":"..."}`.
- allow: the command ran, `permission_denials` empty. deny: the tool result is an error carrying the host's message, and
  the call is listed in `permission_denials`. An answer held for 90 seconds worked; longer holds are untested.
- `tools/claude-probe/probe_host.py LABEL allow|deny|allow:SECONDS` repeats these.

### Hooks

A PreToolUse hook (a command; the call arrives as JSON on stdin with `hook_event_name`, `tool_name`, `session_id`,
`tool_input`) may print
`{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow|deny|ask","permissionDecisionReason":"..."}}`.
With `--settings` carrying the hook and a 6 second wait inside it:

- `--permission-mode default`, hook allows: the command ran (the hook's allow replaces the approval). Hook denies: blocked,
  tool error "PreToolUse:Bash hook error: <reason>". The CLI waited for the slow hook.
- `--dangerously-skip-permissions`, hook denies: still blocked. So a guardrail hook applies in autonomous mode (N-204).
- `ask` was not tested.
- A settings file given with `--settings` is resolved against the session's working directory: pass an absolute path.

## Managed settings (verified 2026-11-13, CLI 2.1.325 on Fedora 44, ledger N-201)

- Paths (docs, "Deploy managed settings"): Linux and WSL `/etc/claude-code/managed-settings.json`; macOS
  `/Library/Application Support/ClaudeCode/managed-settings.json`; Windows `C:\Program Files\ClaudeCode\managed-settings.json`.
  Managed skills, agents and commands live under `/etc/claude-code/.claude/`.
- Checked in the Fedora 44 build VM: `claude --debug --debug-file F -p hi` logs "missing file ... /etc/claude-code/managed-settings.json"
  and loads managed skills from `/etc/claude-code/.claude/skills`. The same CLI on Windows logs the Windows path.
  No `managed-settings.d` drop-in directory is mentioned by this version.
- Managed hooks run in `-p` even with no sign-in: with a managed file holding SessionStart and UserPromptSubmit hooks that
  append to a log, `claude -p hi` printed "Not logged in" and the log showed `managed-SessionStart` and `managed-UserPromptSubmit`.
- Hooks merge across sources: with a managed, a `--settings` and a user SessionStart hook, all three ran (managed first,
  then `--settings`, then user).
- With `"allowManagedHooksOnly": true` in the managed file, only the managed hook ran; the `--settings` and user hooks did not.
  That would switch off the daemon's own per-session audit hook, so nisse must not set it without moving the audit hook
  into the managed file.
- Precedence (docs): managed above `--settings` above project local, project and user settings.
- The managed file is machine-wide: it covers every `claude` run on the computer, including the user's own terminal sessions,
  and the user cannot change it without root. The daemon's `--settings` covers daemon sessions only.
- Commands used: `curl -fsSL https://claude.ai/install.sh | bash` (the same installer the first-boot script uses), then the
  runs above with `sudo tee /etc/claude-code/managed-settings.json`; the file and the test user settings were removed afterwards.

## Not yet verified

- `--remote-control` on headless or daemon-managed sessions (the panel's per-session checkbox assumes it works): N-202,
  needs Bert's sign-in.
- Host answers held longer than 90 seconds, and a PreToolUse hook returning `ask`.
