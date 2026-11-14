# Panel notes

Facts about the panel app that were checked on a real system, with how.

## Is a microphone in use? (verified 2026-11-14, PipeWire 1.6.10 and WirePlumber 0.5.18 in the Fedora 44 build VM, ledger N-205)

The panel holds back its desktop notice for a waiting approval while a microphone is in use (a call is not interrupted).
"In use" is read from PipeWire with `pw-dump` (package `pipewire-utils`, required by the `nisse-panel` RPM).

Private PipeWire plus WirePlumber, a null source named `fakemic` (a virtual microphone) and a null sink `fakespk`, and
`pw-record` as the recording app. Node objects from `pw-dump`:

| Case | The capture node | Result |
|---|---|---|
| nothing recording | none | no `Stream/Input/Audio` node |
| `pw-record --target fakemic` | `media.class` `Stream/Input/Audio`, state `running` | in use |
| `pw-record --target fakespk -P stream.capture.sink=true` (records what the speakers play) | same class, state `running`, props `stream.capture.sink` true | not a microphone |
| a recorder frozen with SIGSTOP | seen once as `suspended`, once as `running` | unreliable; not used as a case |

Rule in `panel/src/MicWatcher.cpp`: a node of type `PipeWire:Interface:Node`, state `running`, `media.class`
`Stream/Input/Audio` and `stream.capture.sink` not true (boolean or the text `true`). Anything unreadable (pw-dump
missing, an error, bad JSON, over 2 seconds) counts as "not in use", so a notice is never lost to a failed check.
Real captures are the test fixtures in `panel/tests/fixtures/pwdump_*.json` (Node objects only).

Not verified: a real microphone with a real call app (Teams, Zoom, a browser) on hardware; a camera-only call; apps
that keep a capture stream `running` while muted (they would count as in use).

## Notification policy

- Panel window in the foreground: no notice (the Approvals tab already shows it).
- Panel in the background, microphone free: one notice, "nisse needs you", with the summary. Clicking it opens the
  panel on the Approvals tab.
- Microphone in use: the notice is held back; a timer looks again every 10 seconds. When the microphone is free and
  the panel is still in the background, one notice covers everything held ("3 approvals are waiting", or the summary
  when there is one). If the panel was opened meanwhile, or the approval was decided, nothing is sent.
- The notice goes out through `org.freedesktop.Notifications` (Plasma's notification service). The end-to-end test
  watches the bus for the `Notify` call; what Plasma then draws on screen is not checked until GATE 2.

## Tabs (N-206)

- The daemon owns the session list (`ListSessions`, `RenameSession`, `CloseSession`, signal `SessionsChanged`); the
  panel never makes up an id, an order or a name, so a second client sees the same tabs. Order is creation order.
- A tab with no name shows its creation date and time (for example "Nov 14, 14:32"); renaming (double-click) stores a
  name in the daemon, and an empty name goes back to the date and time. Names are at most 60 characters.
- Only the selected tab shows its transcript. A background tab shows its title and one status dot: red needs you (an
  approval is waiting on that session), amber working, green finished while you were elsewhere. Its text is kept and
  appears when the tab is selected.
- Closing a tab stops its running turn (one done signal), drops its queued messages, denies the approvals still waiting
  on it (decided by `daemon`, so a late answer is refused) and forgets the session.
- After a panel restart the tabs come back from the daemon with their names, but earlier messages are not shown (the
  tab says so). That needs the event replay of N-220.
- The panel's `needsYouCount` (approvals waiting) and `unreadCount` are what the taskbar badges (N-207) will show.

## Taskbar badge (N-207, verified 2026-11-14 in a live Plasma 6.6.4 session from the gate-1 image)

Decision (Bert): native badge only.

- Plasma's task manager listens for the Unity launcher-entry update (`com.canonical.Unity.LauncherEntry`, signal
  `Update(s app_uri, a{sv} props)`, properties `count`, `count-visible`, `urgent`) and draws a count badge on the matching
  pinned or running launcher. Seen with Konsole and with the panel launcher (`docs/look-spike/n207-native-badge.jpg`,
  `docs/look-spike/n207-real-badge.jpg`). The badge is a small dark circle with an Ember ring and the number at the icon's
  top-right; with `urgent` the whole task button takes an amber highlight. One style only: Plasma does not let an app pick a
  red or a green badge.
- Tried and rejected: painting the count into the window icon. For an app that matches a pinned launcher the task
  button keeps the launcher's icon and ignores the window icon; only an unpinned app shows it
  (`docs/look-spike/n207-painted-icon.jpg`).
- So the badge shows the number of approvals waiting (`DaemonClient::pendingCount`), urgent while any wait, and goes away at
  zero or when the panel exits (`panel/src/LauncherBadge.cpp`). Unread completions are shown only inside the panel's tabs
  (green dot, `SessionTabs.qml`).
- Checked: the message is built as above (`tst_badge`); only changes are sent; the end-to-end test watches the bus for the
  badge going 1 then 0 while an approval is requested and decided; a live Plasma showed the real `LauncherBadge` code's
  "3" on the pinned panel launcher and the badge gone after the app exited (`tools/vm/badge_spike.py --real`,
  `tools/vm/badge_probe.cpp`). Not verified: the font of the digit (it is the system font, which the nisse look sets to
  Nunito); a badge from the full panel app in a session with the daemon (GATE 2).

## After a reboot: three levels (N-208)

Decision (Bert): three levels with a click-cycle toggle, default "keep in library".

- Each session has a `keep` level: `always` (comes back as an open tab), `library` (the default: comes back in the
  library, not as a tab, to be reopened from the Library button) and `drop` (forgotten). The panel's toggle under the tab
  bar cycles library, always, drop and back; the daemon stores it, so every client sees the same choice.
- "After a reboot" means a daemon start (the daemon starts with the user session): `Daemon::with_state_file` applies the
  levels once, saves the result, and audits `sessions-at-boot` (kept open, moved to the library, dropped). A closed tab is
  still removed for good (Close, or Delete in the library).
- A library session is still known to the daemon: opening it, or sending it a message from any client, makes it a tab
  again. Its Claude Code conversation files are never touched (only the daemon's list forgets a dropped session), and
  its earlier messages are not shown until N-220 adds event replay.

## Remote access switch (N-209)

- One per-machine switch (panel tab "Remote", default off). On, the daemon runs `claude remote-control` (name
  `nisse-<host>`, in the home folder, the machine's settings file when installed, the permission mode of the authority
  switch read at each start: autonomous `bypassPermissions`, supervised `default`), restarts it with a wait of 5 seconds
  growing to 5 minutes when it dies, and stops it and everything it started when the switch goes off or the daemon exits.
  The switch stays on across a daemon restart (`remote.json` beside `sessions.json`).
- nisse records the one-time conditions: the home folder is marked trusted in `~/.claude.json` (only that key changes; a
  file that is not valid JSON is left alone and the server is not started) and the consent question is answered `y`.
- The sessions the server starts belong to Claude's own server: not tabs, and their approvals are not in the nisse
  approvals list. In supervised mode the phone asks. The panel says so next to the switch.
- Deviation from the ledger wording: the server is a child supervised by the daemon (itself a user service), not a second
  systemd unit; one less moving part, and it dies with the daemon.
- Not verified: a message from the phone or claude.ai into the server, and the guardrail hook on its sessions. In
  autonomous mode a phone session therefore has `bypassPermissions` and no confirmed guardrail: this is the first thing
  to check at GATE 2 with the phone.

## A session on its own backend (N-211)

- Each session can be pointed at one of the configured backends (`docs/backends-config.md`) from a picker under the tab
  bar ("Default (max)" or a backend name with where it is: Max account, this computer, another computer). The daemon
  stores the choice with the session (`SetSessionBackend`, `ListBackends`), so it survives a restart and every client
  sees it. Its next turn goes there: the daemon gives the CLI that backend's environment for that turn.
- With no choice, a session uses the default for chat: the `chat` route, or `main` when there is none.
- A session pointed at a backend that has left the configuration is never sent anywhere else: the turn fails with a plain
  message ("not in the configuration any more; pick another backend"), because choosing a local backend usually means
  keeping the work off the cloud. The picker note says the same.
- A conversation that already started continues on the new backend (the CLI resumes it from its own file); a smaller local
  model may cope less well with a long one.
- What happens when a remote backend is away is N-212 and N-213, not here.

## Usage in the status bar (N-214)

- The middle of the top bar reads "Usage: 5h 25% | 7d 54%" from the daemon's `GetUsage` JSON: the Max account's five-hour
  and seven-day windows. Amber from 80%, Ember red from 95% (of the fullest window that has not reset). A window whose
  reset time has passed since it was read shows "-" (the number would be stale); nothing known reads "Usage: unknown".
- Hover for the detail: each window with its reset in words ("resets in 2 h 1 min"), how old the reading is when it is
  over half an hour old, and the tokens used today per backend ("here: 12.3k, max: 41.6k"; cached tokens included), so a
  local backend's use is counted too. Clicking the bar reads the limits again.
- The numbers come from Claude Code itself (see `docs/claude-cli-notes.md`): the `rate_limit_event` of each turn and the
  `/usage` report (`RefreshUsage`, no model call). The daemon keeps them in `usage.json` beside the sessions file, and the
  token counts for 30 days. They are only as new as the last turn or refresh; a Max account used from another computer
  moves the real numbers in between.
- Not shown: the per-model weekly limits (the daemon keeps them under `others`), and any cost (the CLI's cost is a list-price
  estimate, and a subscription is not billed per token).

## Kill switch (N-215)

- A red "Stop all AI" button sits under the status bar. Clicking it, or any paired device calling `EngageKillSwitch(by,
  reason)` on D-Bus, stops everything at once: every running turn and everything it started (the whole process tree), queued
  messages, approvals waiting for an answer (denied, by the device that stopped it), and the remote access server.
  New sends are refused with a line saying who stopped it and why, and nothing new can start until `ReleaseKillSwitch`.
  Nothing is rolled back: what the AI already did stays done.
- While it is on, the bar shows a red banner ("AI activity is paused: stopped by phone (reason). Nothing was rolled back.")
  with a Resume button. Resume brings the remote access server back if its switch is on; it does not restart what was
  stopped.
- The state survives a daemon restart (`killswitch.json`), so a reboot does not quietly turn the AI back on. A file that
  cannot be read starts the switch ON (fail closed) and one click turns it off.
- It is a plain daemon method with a device name and no panel-only state (the pairing in N-221 will decide who may call it).
- Root actions (the privileged helper, N-602) do not exist yet; when they do they must stop and clean up under this switch
  too (a ledger note on N-602 says so).

## Settings tab (N-216)

- One tab for everything the person can set: how much the AI may do (autonomous or supervised, in words), how long an approval
  waits, backends and routes (see `docs/backends-config.md`), the fallback switch, and below them what lives in the daemon:
  the usage line, the remote access switch, the kill switch. The old "Remote" tab moved in here.
- It edits a copy and sends it back; Save is off until something changed, Revert goes back to what the daemon has, and a refusal
  from the daemon (for example a main backend that does not exist) shows in words and keeps the edits.
- A settings file that is missing or cannot be used is said at the top ("these are the defaults" or the reason, and that
  saving replaces it and keeps the old one as .bak).
- Plain words about terminal sessions: Claude Code sessions started in a terminal are recorded in the local audit log (marked
  terminal) but never limited, and deleting `/etc/claude-code/managed-settings.json` (which holds only nisse's two audit hooks)
  stops the recording. Checked against the RPM test (N-226).
