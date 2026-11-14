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
