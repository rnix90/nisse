# The nisse daemon contract

The daemon is the one thing every nisse client talks to: the panel on this computer today, a phone later (N-D08, N-221). This
document is the contract between them. **The contract is the data, not D-Bus**: the types below, as JSON, with the rules for
numbering and catching up. D-Bus (the session bus, name `org.nisse.Daemon1`, path `/org/nisse/Daemon1`) is the first transport
that carries it; another transport carries the same JSON.

- The types are defined once, in the Rust crate `services/crates/nisse-proto`, and described by the checked-in JSON Schema
  `services/crates/nisse-proto/schema/daemon-protocol.schema.json`. The crate's tests round-trip every type through JSON and
  check what it produces against the schema, so the two cannot drift apart.
- Reading is lenient: a client ignores fields it does not know, so an older client keeps working against a newer daemon.
  Writing is exact: the schema forbids extra fields, so a change to a type changes the schema in the same commit.
- Times: `created_at` and `at_ms` are unix milliseconds; `asked_at`, `expires_at`, `decided_at` and `since` are unix seconds;
  audit `ts` is RFC 3339.

## The types

| Type | What it is | Where it comes from |
|---|---|---|
| `Session` | one conversation: `id`, `title` (null until renamed), `created_at`, `started`, `keep` (`always`, `library`, `drop`), `open`, `backend`, `running`, `pending_approvals` | `ListSessions` |
| `Approval` | something the AI wants to do that needs a person's yes: `id`, `session`, `asked_by`, `tool`, `summary`, `detail`, `asked_at`, `expires_at`, `state` (`pending`, `approved`, `denied`, `expired`), `decided_by`, `decided_at`, `reason` | `ListApprovals`, `Approve`, `Deny`, `WaitApproval` |
| `AuditRecord` | one line of the append-only audit log: `ts`, `session`, `actor`, `kind`, `source` (`daemon` or `terminal`, absent means `daemon`), `detail`, and `changed` (only when the log changed the record, see "The audit log never holds secrets") | `SearchAudit`, `ExportAudit`, `AuditTail` |
| `Event` | one thing that happened in a session, with a per-session number `seq` (see below): `type` is `user_message` or `chunk` (with `text`), `error` (with `message`) or `done` | `EventsSince`, the `SessionEvent` signal |
| `EventsPage` | the answer to "events since N": `session`, `events`, `after`, `last_seq`, `gap` | `EventsSince` |
| `Device` | a paired device: `id`, `name`, `role` (`full` or `approver`), `public_key_hex`, `created_at`, `last_seen`, `revoked_at` | `ListDevices`, `CompletePairing` |
| `SignedRequest` | a call from a paired device: `device_id`, `ts_ms`, `nonce`, `method`, `args_json`, `signature_hex` | `DeviceCall` |

## Events, and catching up

Every session has a log of events numbered 1, 2, 3 ... without gaps: the message a person sent (`user_message`), each piece of
the reply (`chunk`), anything that went wrong or was refused (`error`) and the end of the turn (`done`, exactly one per
message). Any client can send a message, so a phone sees what the desktop sent and the other way round.

- **Live**: each event is announced as it is recorded by the signal `SessionEvent(session, event_json)`.
- **Catching up**: a client remembers the number of the last event it saw. After a dropped connection, a restart, or being
  closed for a day, it calls `EventsSince(session, after_seq, limit)` and gets every event it missed, oldest first, **exactly
  once and in order**: ask again from the last `seq` of a full page to get more. Asking from the newest number returns
  nothing. `last_seq` is the newest number; `gap` is true when events right after `after_seq` have been dropped (a session
  keeps its newest 20,000 events), which tells the client that what it holds is incomplete.
- **Dedupe**: an event with a number at or below the newest one a client has seen is a repeat and is ignored. The panel does
  exactly this, which is also how it avoids showing the older per-kind signals (`MessageChunk`, `SessionDone`, `SessionError`)
  twice: they carry no number, and are only used for a session the client is not following through its events (a send to a
  session the daemon does not know has no events).
- **Keeping**: events are saved per session (`<state>/events/<session id>.jsonl`, one `Event` per line, appended as they
  happen), survive a daemon restart and the numbers go on after it; closing a session removes its events, and event files of
  sessions the daemon no longer knows are removed at its start.

## Paired devices (N-221)

The desktop panel talks to the daemon over the user's own session bus, which only that user can reach, so it is trusted as
"desktop". Any other client (a phone, later) is a **paired device**, and the daemon decides who may call it.

- **Pairing**: on the computer the person starts a pairing (`StartPairing(name, role)`); the daemon makes a one-time 8-digit
  code (works once, for five minutes; five wrong tries cancel it; kept in memory only, never in the audit log) and the panel
  shows it. The device sends the code and its own Ed25519 **public key** (`CompletePairing`); the daemon records the key and
  gives the device an id. Roles: `full` (the default: everything the desktop panel can do except pairing and revoking
  devices, which stay on the computer) and `approver` (see sessions, approvals and events; approve or deny; turn the kill
  switch ON, but not off). `ListDevices` lists them, `RevokeDevice(id, by)` revokes one at once (the record stays), and the
  signal `DevicesChanged` follows both.
- **Calls**: every call a device makes is a `SignedRequest` sent to `DeviceCall(request_json)`. The device signs, with its
  private key (which never leaves it), the bytes `nisse-v1`, `device_id`, `ts_ms`, `nonce`, `method` and `args_json`, one per
  line, joined by newlines; `args_json` is a JSON array and is signed exactly as sent. The daemon refuses the call unless the
  device is paired and not revoked, `ts_ms` is within a minute of the computer's clock, the signature verifies against the
  stored public key, the nonce (16 to 64 hex characters) has not been used, and the role allows the method. Nonces are
  remembered for two minutes, which is longer than a call could still look fresh. The daemon keeps only public keys, so a
  stolen state file cannot sign anything.
- **What it can call**: `ListSessions`, `EventsSince`, `ListApprovals`, `GetKillSwitch`, `GetUsage`, `GetBackend`,
  `GetAuthority`, `SearchAudit`, `Approve`, `Deny` and `EngageKillSwitch` (any device); and, for `full` devices, `NewSession`,
  `SendMessage`, `Cancel`, `RenameSession`, `CloseSession`, `ReleaseKillSwitch`, `RefreshUsage`, `GetConfig`, `SetConfig`,
  `GetRemoteAccess`, `SetRemoteAccess`, `ExportAudit`, `ListBackends`, `ResolveBackend`, `SetSessionBackend`, `SetKeepMode` and
  `OpenSession`. The answer is `{"ok": <what the method returns>}`. Pairing and revoking devices are never reachable this way.
- **Who did it**: an approval a device decides records the device's name as `decided_by`, the kill switch records it as `by`,
  and every call that changes something adds a `device-call` audit record with the device id and name. A refused call is a
  `device-refused` record with the reason; pairing and revoking are `device-pairing-started`, `device-paired` and
  `device-revoked`.
- **Not here**: no network listener exists. The way a phone reaches the daemon (and how it is told apart from anyone else on
  that path) is the transport choice of N-D08; this is the part that decides who may call once a transport carries the JSON.
  The mechanism was checked by building the signature crate in the build VM and by a loopback test client that signs and sends
  real calls over the bus (`services/crates/nisse-daemon/examples/device_probe.rs`).

## The D-Bus binding

Methods return JSON strings of the types above unless noted; an error is a D-Bus error with a message in words. `by` and `device`
arguments name the client device (required where listed); the pairing in N-221 will make the daemon check who is allowed.

| Method | What it does |
|---|---|
| `NewSession` | makes a session, returns its id |
| `ListSessions` | the sessions, oldest first (`Session` per string) |
| `SendMessage(session, text)` | sends a message; the answer arrives as events |
| `Cancel(session)` | stops the running turn |
| `RenameSession(session, title)` | names a session (empty goes back to none) |
| `CloseSession(session)` | closes and forgets a session, stops its turn, denies its approvals |
| `SetKeepMode(session, mode)` | `always`, `library` or `drop` for the next daemon start |
| `OpenSession(session)` | shows a library session as a tab again |
| `EventsSince(session, after_seq, limit)` | the `EventsPage` described above (limit 0 means 500, at most 1000) |
| `SetSessionBackend(session, backend)` | points a session at a configured backend (empty: the default) |
| `ListBackends` | the configured backends for a picker |
| `ResolveBackend(category)` | the backend a turn of that category would use right now |
| `GetBackend` | name, kind, address and model of the default backend for chat |
| `GetAuthority` | `autonomous` or `supervised` |
| `GetConfig` | the settings in use, whether from the file, the defaults or a broken file |
| `SetConfig(config_json, by)` | saves checked settings, keeping the old file as a backup |
| `GetSetupStatus` | state of the first-boot fetch of Claude Code |
| `GetUsage` | the account's limit windows and tokens per backend |
| `RefreshUsage` | reads the limits now (no model call) and returns the same JSON plus `refreshed` |
| `GetRemoteAccess` | whether remote access is on and its server is up |
| `SetRemoteAccess(enabled)` | turns remote access on or off |
| `GetKillSwitch` | whether all AI activity is stopped |
| `EngageKillSwitch(by, reason)` | stops everything at once |
| `ReleaseKillSwitch(by)` | lets work start again |
| `RequestApproval(session, asked_by, tool, summary, detail_json)` | files an approval, returns its id |
| `WaitApproval(id)` | blocks until the approval is decided or expires |
| `WaitApprovalFor(id, seconds)` | like `WaitApproval`, giving up after `seconds` (at most 60) with the approval as it is |
| `ListApprovals(state)` | the `Approval`s in a state (empty: all) |
| `Approve(id, device)` | approves; refused if already decided |
| `Deny(id, device, reason)` | denies |
| `SearchAudit(query_json)` | searches the audit log: `AuditRecord`s newest first, with `total` |
| `ExportAudit(query_json)` | every match as JSON lines (up to 50,000) |
| `AuditTail(n)` | the last `n` audit records |
| `StartPairing(name, role)` | on the computer: offers a pairing, returns the code and when it runs out |
| `CancelPairing` | cancels the pairing that is waiting |
| `CompletePairing(code, public_key_hex)` | a device presents the code and its public key; returns the `Device` |
| `ListDevices` | the paired devices (`Device` per string), revoked ones included |
| `RevokeDevice(id, by)` | revokes a device at once |
| `DeviceCall(request_json)` | a signed call from a paired device (see above) |
| `ListUndo` | the changes nisse made that a person can go back to (N-311), newest first, one `UndoEntry` JSON per string (see below); empty without the undo tool; a failing tool is an error in words |
| `Undo(snapshot, by)` | goes back to the state BEFORE the change `snapshot` (an entry's `id`) and restarts the computer at once; refused, in words, while any chat is working, for a number `ListUndo` does not list and for a snapshot that cannot boot; the audit record `rollback` is written first |

| Signal | When |
|---|---|
| `SessionEvent(session, event_json)` | each event, as it is recorded |
| `SessionsChanged` | a session was made, renamed, closed, reopened or re-pointed |
| `ApprovalChanged(id, state)` | an approval was requested or decided |
| `KillSwitchChanged(status_json)` | the kill switch was turned on or off |
| `UsageChanged(usage_json)` | usage numbers changed |
| `RemoteAccessChanged(status_json)` | the remote access status changed |
| `DevicesChanged` | a device was paired or revoked |
| `MessageChunk(session, text)`, `SessionDone(session)`, `SessionError(session, message)` | the older per-kind signals; repeats of the events |

### Undo (N-311)

`ListUndo` returns one JSON object per change; the daemon builds them from `nisse-rollback list` (run as root through `sudo -n`; in
limited sudo mode that exact command is passwordless) and its own sessions. An AI turn's before and after snapshots are one entry,
an update (`nisse=safe-apply`) and a package change (`nisse=package-transaction`) are one each. Going back to an entry means going
back to its BEFORE snapshot, so it also undoes everything made after it.

| Field | Meaning |
|---|---|
| `id` | the BEFORE snapshot: the number `Undo` takes |
| `kind` | `ai-turn`, `update` or `package` |
| `at` | unix milliseconds |
| `session`, `title` | for an AI turn, the chat and what the person called it (`null` when untitled or no longer known) |
| `post` | the AFTER snapshot, `null` when it was never taken |
| `bootable`, `reason` | false (with the reason) when the snapshot's kernel has left `/boot`, so it cannot be rolled back to |

An AI turn that is still running is not listed (its before snapshot is not a change yet). `Undo` runs `nisse-rollback run SNAPSHOT
--reason ... --reboot` through `sudo -A` (full mode needs no password; limited mode opens nisse's password popup) and answers
`{"snapshot": N, "restarting": true}`. Audit records: `rollback` (before the tool runs, with the snapshot, the kind and the chat) and
`rollback-failed` (with the error). A paired phone cannot undo or list: both are on the "this computer only" list, so a `DeviceCall` of either is refused with that
reason (the computer restarts, so it is for the person sitting at it). The AI cannot run `nisse-rollback` itself either: the
guardrail holds it for approval.

## The audit log never holds secrets (N-219c)

Every writer of the audit log (the Claude Code hook, the daemon, the turn hook) goes through `AuditLog::append` in the
`nisse-audit` library, which cleans a copy of the record before it is written. Two rules, both on every text value anywhere in
`detail` (never on field names, and never on `ts`, `session`, `actor` or `kind`):

1. **Secrets are replaced** by a marker, `[redacted: kind]`. Kinds: `api-key` (the public formats of Anthropic, OpenAI, AWS,
   GitHub, Slack, Google, Stripe, Hugging Face and npm keys and tokens), `jwt`, `bearer-token` (the value of an `Authorization:
   Bearer`, `Basic` or `Token` header), `private-key` (a whole `-----BEGIN ... PRIVATE KEY-----` block, or to the end of the text
   when it has no end), `url-credentials` (the password in `scheme://user:password@host`) and `credential` (the value of a
   `name=value` or `name: value` whose name ends in `password`, `secret`, `token`, `api_key` and the like, in shell, URLs, JSON and
   environment dumps; and a string field of a JSON object with such a name). A value that is a variable or a call (`$TOKEN`,
   `get_password()`) and a value under six characters are left alone, as is ordinary text (a git hash, a UUID, base64 data).
2. **Text is cut** at 8 KB (`FIELD_LIMIT`, one constant) on a character boundary, and ends with `[cut: N more bytes]`. Redaction
   comes first, so a secret that straddles the limit is gone, not half shown.

When either rule changed anything the record carries `changed`:

```json
"changed": {
  "redacted": [{"field": "detail.tool_input.command", "kind": "api-key", "count": 2}],
  "cut": [{"field": "detail.tool_response.stdout", "bytes": 12345}]
}
```

`field` is a path from the record (`detail.items[2].text`); `bytes` is how much was taken off after redaction. Either list is
absent when empty, and `changed` is absent on a record that needed nothing. Records written before N-219c are never rewritten
and have no `changed`; search matches the cleaned text, so a removed secret cannot be found. A client must never show a record that
carries `changed` as complete: the panel's audit view puts a note on the row, and the export keeps the field in every line.

Not covered: the per-session chat event files (the chat history files) are a separate store, and the shapes above are the list of known
formats, not a promise to catch every secret.

## Checking it

- `cargo test -p nisse-proto` round-trips every type and validates it against the schema.
- `cargo test -p nisse-daemon --test events` and the `protocol` tests in `tests/dbus.rs` check the numbering, the catch-up
  (every missed event once, in order, after a simulated drop-off), the restart and the shared types on the wire.
- `tests/repo/test_protocol_doc.sh` fails if a method or signal of the daemon is missing from this document.
- The end-to-end block `tests/e2e/events_inner.sh` runs a turn through the real daemon and panel client, across a restart.
