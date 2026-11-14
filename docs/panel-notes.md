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
