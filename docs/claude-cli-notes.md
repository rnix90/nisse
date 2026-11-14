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

## Remote control on headless sessions (verified 2026-11-14, CLI 2.1.325 in the Fedora 44 build VM, ledger N-202)

Signed in to the Max account inside the VM first (`claude auth login` prints a URL; the code from the page is pasted on
its stdin; `claude auth status` then shows `loggedIn: true`).

- **`claude -p --input-format stream-json ... --remote-control <name>` ignores the flag.** The prompt was answered normally
  (exit 0), but the debug log reads `remote=false ... nonInteractive=true` and no bridge was started. So the daemon's own
  `claude -p` children cannot be put under remote control, and a per-session checkbox on them cannot work.
- **`claude remote-control` (the standalone server) does work with no terminal**, with two one-time conditions:
  1. The folder must be trusted: otherwise it exits 1 with "Workspace not trusted. Please run `claude` in <dir> first".
     In the VM the trust entry was set in `~/.claude.json` (`projects.<dir>.hasTrustDialogAccepted`).
  2. It asks "Enable Remote Control? (y/n)" once. With no answer it exits 1; with `y` on stdin it carried on.
  Then it registered an environment (`POST /v1/environments/bridge` -> 200), printed a claude.ai/code link, created an
  initial session and began polling for work: "Connected", "Capacity: 1/32", and it spawned a session process it owns
  (`[bridge:session] Spawning ...`). `--spawn same-dir|worktree|session`, `--capacity`, `--permission-mode` and
  `--settings <file>` (the file is read once at start and applies to spawned sessions) exist on it.
- **Not verified:** a message actually sent from claude.ai or the phone into such a session (nobody drove the other end),
  whether `--settings` with the guardrail hook is honored by sessions the server spawns, and whether the nisse daemon
  can see or approve what those sessions do. Those sessions are children of the `claude remote-control` process, not of
  the daemon, so the daemon's approvals queue (the host protocol) does not cover them.
- Consequence for the panel: remote control is a per-machine switch (run one `claude remote-control` as a user service),
  not a per-session checkbox. N-209 was rewritten for that.
- Commands used: `claude remote-control --name nisse-probe --debug-file F` with `echo y` piped in, run for 25 seconds
  under `timeout`; the registered environment is left to expire on the account side.

## Live run of the host protocol (verified 2026-11-14, CLI 2.1.325 in the VM, ledger N-224)

The real `nisse-daemon` (built in the VM, no fake runner) on a private session bus with `authority = "supervised"` and
`approval_expiry_secs = 25`, one session, three messages each asking for one Bash call (`echo ... > /tmp/...`), driven
with `busctl` (SendMessage, ListApprovals, Approve, Deny):

| Case | What the daemon did | What the CLI did | Result |
|---|---|---|---|
| approve | a pending approval appeared (asked_by `desktop`, summary `Bash: echo approved > /tmp/live224/a.txt`, whole request in `detail`); `Approve` with a device name | ran the command | file written, reply `done`, signals `pending` then `approved`, audit `approval-approved` |
| deny | pending; `Deny` with a device name and reason | told the call was denied | file not written, reply `denied`, signals `pending` then `denied`, the reason `not today` stored |
| expire (25 s, no answer) | the sweeper set `expired` (decided_by `daemon`, reason "no answer in time") | told the call was denied | file not written, reply `denied`, signal `expired`, audit `approval-expired` |

- Repeat with `tools/claude-probe/live_host.sh` (header says how).
- The queue state, the three D-Bus signals and the audit kinds (requested x3, approved, denied, expired) matched the tests.
- The same session continued across the three turns (resume works in host mode).
- Difference found: in host mode the CLI emits **no `permission_denied` event** when the host answers deny, so the
  `[Bash was not allowed]` line from the one-shot mode never reached the chat; the panel saw only the model's own reply.
  Filed as N-225.
- A first attempt of the script mis-parsed busctl output and never answered; all three approvals then expired by
  themselves and the CLI carried on, which is the expiry case again (and the first live proof of it).

## Hooks for terminal sessions (verified 2026-11-14, CLI 2.1.325 in the VM, ledger N-226)

- A managed hook (`/etc/claude-code/managed-settings.json`) sees the same payload from a run with no daemon variable as from
  a daemon run: `session_id`, `cwd`, `hook_event_name`, `tool_name`, `tool_input`, `tool_use_id`, `permission_mode`,
  `transcript_path`, `prompt_id`, `effort`; PostToolUse adds `tool_response` and `duration_ms`.
- The environment of the `claude` process reaches the hook command, so `NISSE_SESSION` set by the daemon lets the managed
  hook (`nisse-audit-hook --managed`) skip daemon sessions.
- A managed hook whose command does not exist does not stop the run (exit 0, the model answered). A run with no tool call
  fires no hook at all.
- Real-CLI check with the shipped managed file and the built hook: a terminal-style call gave 2 records (PreToolUse,
  PostToolUse) with source `terminal`; a daemon-style call (`NISSE_SESSION` set, daemon `--settings` hook, managed file
  installed) gave exactly 2 records with source `daemon`.
- Limits: a `claude` that a daemon session starts itself (a Bash call running `claude`) inherits `NISSE_SESSION`, so the
  managed hook skips it; the outer Bash call is recorded, the inner run's own tool calls are not. An interactive (TUI)
  session was not driven in the VM (the pty run never reached a tool call in 2 minutes); check it on the GATE 2 image.
- The audit log holds tool inputs, which can contain secrets; it stays on the machine, and the RPM description says
  terminal sessions are recorded and how to stop it (remove the managed file).

## How long a PreToolUse hook may hold a call (verified 2026-11-14, CLI 2.1.325 in the VM, ledger N-204)

Each case: the hook sleeps, then prints a deny; the call is `echo ran > marker`; `--dangerously-skip-permissions`.

| Hook wait | Hook `timeout` setting | Result |
|---|---|---|
| 75 s | none | the deny was honored (call blocked) |
| 200 s | 1200 | the deny was honored |
| 930 s (longer than the 900 s default approval expiry) | 1200 | the deny was honored, the turn took 934 s |
| 20 s | 5 | the hook was killed at 5 s and **the call ran** |
| 620 s | none | the hook was killed at 600 s and **the call ran** |

- The default hook timeout is 600 seconds, and a hook that times out does not block: the call runs. So the guardrail hook
  must always set `timeout` explicitly and must stop waiting before it (it prints deny itself).
- The settings file ships `"timeout": 1200`, the longest wait checked here; the hook caps its own wait at 1100 s
  (`NISSE_GUARD_MAX_WAIT_SECS` overrides) and, on giving up, denies the approval in the queue so a late answer is refused.
  An `approval_expiry_secs` above 1100 is therefore cut at 1100 s for guardrail holds. Longer holds and larger timeouts
  are untested.
- Messages on the session bus can be cut off by the bus after its reply timeout, so the hook asks the daemon in slices:
  `WaitApprovalFor(id, seconds)` (at most 60; the hook uses 30) returns the approval as it is, still `pending` if nobody
  has answered, and the hook asks again.

## Guardrail hook against the real CLI (verified 2026-11-14, CLI 2.1.325 in the VM, ledger N-204)

The real `nisse-daemon` and the real `nisse-guard-hook` (in the daemon's `--settings`), `NISSE_CLI_HUNG_SECS=20`, driven
with `busctl`; the guarded call was `echo X > file; curl -s -m 2 -d x http://127.0.0.1:9/ ; true` (an outbound upload
that cannot reach anything):

| Case | Result |
|---|---|
| autonomous, held 60 s (three times the hung limit), then approved | one pending approval (asked_by `guardrail`, category `outbound`); still pending after 60 s with no error and no restart; after approval the file was written and the reply was `done` |
| autonomous, denied with a reason | file not written, reply `blocked`, reason stored |
| autonomous, a free call (`echo ... > file`) | no approval filed, file written |
| supervised, guarded call | exactly one approval (the guardrail's); after approving it the CLI did not ask again (the hook's allow replaced the CLI's own prompt); file written |

Repeat with `tools/claude-probe/live_guard.sh`.

- A hook `allow` therefore also answers the CLI's own permission prompt for that call. Not checked: whether it can
  override a deny rule in the user's own settings.

## Not yet verified

- An interactive terminal `claude` session recorded as `terminal` (GATE 2 image check); a message from claude.ai or the phone into a `claude remote-control` session; the guardrail hook on such sessions (N-209).
- Host answers held longer than 90 seconds (the 25 second expiry above is shorter), and a PreToolUse hook returning `ask`.
