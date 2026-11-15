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
| `AuditRecord` | one line of the append-only audit log: `ts`, `session`, `actor`, `kind`, `source` (`daemon` or `terminal`, absent means `daemon`), `detail` | `SearchAudit`, `ExportAudit`, `AuditTail` |
| `Event` | one thing that happened in a session, with a per-session number `seq` (see below): `type` is `user_message` or `chunk` (with `text`), `error` (with `message`) or `done` | `EventsSince`, the `SessionEvent` signal |
| `EventsPage` | the answer to "events since N": `session`, `events`, `after`, `last_seq`, `gap` | `EventsSince` |

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

| Signal | When |
|---|---|
| `SessionEvent(session, event_json)` | each event, as it is recorded |
| `SessionsChanged` | a session was made, renamed, closed, reopened or re-pointed |
| `ApprovalChanged(id, state)` | an approval was requested or decided |
| `KillSwitchChanged(status_json)` | the kill switch was turned on or off |
| `UsageChanged(usage_json)` | usage numbers changed |
| `RemoteAccessChanged(status_json)` | the remote access status changed |
| `MessageChunk(session, text)`, `SessionDone(session)`, `SessionError(session, message)` | the older per-kind signals; repeats of the events |

## Checking it

- `cargo test -p nisse-proto` round-trips every type and validates it against the schema.
- `cargo test -p nisse-daemon --test events` and the `protocol` tests in `tests/dbus.rs` check the numbering, the catch-up
  (every missed event once, in order, after a simulated drop-off), the restart and the shared types on the wire.
- `tests/repo/test_protocol_doc.sh` fails if a method or signal of the daemon is missing from this document.
- The end-to-end block `tests/e2e/events_inner.sh` runs a turn through the real daemon and panel client, across a restart.
