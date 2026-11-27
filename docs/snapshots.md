# Snapshots around package changes (N-305)

The `nisse-snapshots` package takes a btrfs snapshot pair around every package transaction, keeps 20 pairs for 14 days,
and does nothing on live media or on a non-btrfs root. This page records what was verified, what was decided and how it
is wired. The root layout it sits on is `docs/storage-spike.md` (N-302).

## What was verified (Fedora 44 build VM, snapper 0.13.0, dnf5 5.4)

| Question | Finding |
|---|---|
| Does Fedora offer a package-manager snapshot hook for dnf5? | No. `python3-dnf-plugin-snapper` is a dnf4 plugin. dnf5 has the `actions` plugin (`libdnf5-plugin-actions`), which runs a command before and after each transaction. nisse uses that. |
| How does snapper count "20 pairs"? | `NUMBER_LIMIT` counts every pre and every post snapshot separately and keeps a pair together. Limit 5 left 6 snapshots (3 pairs) in a test of 8 pairs. 20 pairs is `NUMBER_LIMIT=40`; a test of 25 pairs left exactly 20 pairs. |
| Is there a "delete after N days" setting? | No. The number algorithm only keeps the youngest N. The 14-day rule is a small daily job (`nisse-snapshot-prune`). |
| Can the 5 GiB cap be a plain `SPACE_LIMIT=5G`? | The value is accepted and needs a btrfs quota group (`snapper setup-quota`). With quotas on and about 88 MB pinned against a 30 MB limit, snapper's `cleanup number` removed nothing, so enforcement could not be verified. |
| Can a size check work without quotas? | No. `btrfs filesystem du` reports "set shared" data that includes what the live system still uses, so it cannot tell what deleting the snapshots would free. Quota group `1/0` did show the right number (88 MB for about 84 MB pinned). |
| Does editing the config file take effect at once? | No. `snapperd` caches configs. The scripts call `snapper --no-dbus` so they always read the file. |

## Decisions (Bert, 2026-11-18)

1. **14-day age limit:** a daily prune timer deletes snapshot pairs older than 14 days (snapper's own hourly cleanup
   keeps the 20-pair count).
2. **5 GiB cap: dropped.** The only reliable measure needs btrfs quotas, which cost performance, and snapper's own
   enforcement is unverified. The N-302 retention decision is amended to **20 pairs and 14 days**. Instead of a size cap,
   the hook skips the pre snapshot (and says so in dnf's log) when `/` has less than 10% free, so snapshots do not fill
   a small disk. Quotas can be added later by a new decision if disks turn out to fill.

## How it is wired

| Piece | What it does |
|---|---|
| `nisse-snapshot-setup.service` | First boot of an installed system, once: if `/` is btrfs and there is no snapper `root` config, `snapper create-config /` and apply `/usr/share/nisse/snapshots/root.conf`. If applying fails the new config is deleted so the next boot retries. Skipped on live media. It never edits snapper's own `/etc/sysconfig/snapper`: `create-config` does that. |
| `root.conf` | Timed snapshots off, `NUMBER_LIMIT=40`, empty pre/post pairs removed after an hour. |
| `nisse-snapshots.actions` | `pre_transaction` and `post_transaction` lines for the dnf5 actions plugin, `enabled=host-only` so an image build in another installroot is not snapshotted. |
| `nisse-snapshot-hook pre` / `post` | Takes the pre snapshot (tagged `number`, userdata `nisse=package-transaction`), remembers its number in `/run/nisse-snapshots`, and takes the paired post snapshot. Never fails the transaction: a problem is a `log.WARNING` line and exit 0. |
| `nisse-snapshot-prune` (daily timer) | Deletes number-tagged pairs whose post snapshot is older than 14 days and unpaired old pre snapshots; never the active or default snapshot, never snapshots nisse did not make. |
| Presets | Enable the setup service, the prune timer and `snapper-cleanup.timer`; disable `snapper-timeline.timer` and `snapper-boot.timer`. |

## Tests

| Test | Where it runs | What it proves |
|---|---|---|
| `tests/shell/test_snapshot_scripts.sh` | anywhere | the three scripts against a fake snapper: skips, pairing, never failing a transaction, the age rule |
| `tests/rpm/test_nisse_snapshots.sh` | build VM | the package contents, requirements, units, presets, rpmlint |
| `tests/e2e/test_snapshots_btrfs.sh` | build VM (sudo) | the real snapper on a loop btrfs: setup applies the template, the hook brackets a change, 25 pairs shrink to 20, prune removes old pairs only |
| `tests/e2e/test_snapshots_dnf_hook.sh` | build VM (sudo) | dnf5 calls a hook once before and once after install and remove, in order |
| `tests/iso/test_iso_contents.sh` | ISO rebuild | the package, snapper, the actions plugin and the presets are in the image; no root config ships; no timed snapshots |

## A snapshot pair around every AI turn (N-306)

The nisse daemon takes the same kind of pair around each AI turn (one message through Claude Code). Decisions (Bert,
2026-11-18):

1. **A batch is a turn.** The pre snapshot is taken before the CLI starts and the post snapshot when it ends. The daemon
   watches the turn's stream for tool calls: a turn that called only Read, Glob, Grep, LS, WebFetch, WebSearch, TodoWrite,
   ToolSearch or AskUserQuestion has its pre snapshot removed at once, so chat does not use up the 20-pair limit. Anything
   else keeps the pair, `Bash` always (it can be `ls` or `rm -rf`), and so does any tool the list has never heard of
   (MCP tools included): a wrong guess only keeps a pair.
2. **sudo.** The daemon is a user service and snapshots are root's, so it runs `sudo -n /usr/libexec/nisse/nisse-snapshot-batch`.
   nisse is passwordless for its user by default (`docs/sudo.md`, N-306a); in the optional limited mode the helper is
   the one thing that stays passwordless, and if sudo ever asks for a password the daemon says so. I verified the alternative (snapper's own
   `ALLOW_GROUPS=wheel`, which lets a wheel user take snapshots with no sudo) in `tools/spike/snapper_user_spike.sh`; it
   works and is the way back if the sudo policy changes.
3. **No snapshot, the turn still runs.** Live media and a non-btrfs root (the helper exits 10) are only audited. A real
   failure (no sudo rights, under 10% free, snapper error) is audited and the chat gets one plain line per session:
   `[No snapshot was taken, so this turn cannot be rolled back: <reason>]`.

**The helper.** `nisse-snapshot-batch pre SESSION | post PRE SESSION | drop PRE [POST]` runs as root, so it checks its
arguments before anything else (numbers are digits, the session id is letters, digits and dashes) and `drop` refuses any
snapshot that is not a lone pre or a pre/post pair this helper made (userdata `nisse=ai-batch`). Snapshots are number-tagged
with userdata `nisse=ai-batch,session=<id>`, so snapper's hourly cleanup, the 20-pair limit and the daily 14-day prune
treat them like the package pairs.

**Audit log.** Records of kind `snapshot`, actor `daemon`, with the session id:

| `detail.phase` | When | Other fields |
|---|---|---|
| `pre` | the pre snapshot exists | `snapshot` |
| `post` | the turn changed things | `pre`, `snapshot` (both ids in one record) |
| `dropped` | the turn only read things | `pre`, `reason` |
| `skipped` | no snapshot could be taken | `reason`, `told` (whether the chat was told) |
| `post-failed`, `drop-failed` | the helper failed after the turn | `pre`, `error` |

A turn that is cancelled still gets a post snapshot (it may have changed things whose tool call was never read).

**Settings (daemon environment):** `NISSE_NO_SNAPSHOTS=1` turns it off, `NISSE_SNAPSHOT_BATCH` names another helper,
`NISSE_SNAPSHOT_SUDO=0` runs the helper without sudo. The fake runner (`NISSE_FAKE_RUNNER=1`) never snapshots.

**Not covered by the daemon:** `claude` runs a person starts in a terminal and sessions of the remote-access server are not
turns of this daemon; they are covered by the turn hook below (N-306b).

| Test | Where it runs | What it proves |
|---|---|---|
| `tests/shell/test_snapshot_scripts.sh` | anywhere | the helper against a fake snapper: answers, exit codes, argument checks, what `drop` refuses |
| `services/crates/nisse-daemon/tests/snapshots.rs` | build VM (cargo) | tool classification, the stream parser, the helper's exit codes, and the daemon around a turn: order, read-only drop, quiet skip, one notice per session, cancel, concurrent sessions |
| `tests/e2e/test_snapshots_btrfs.sh` | build VM (sudo) | the helper on the real snapper: pre, post and drop, and a foreign pair refused |
| `tests/e2e/test_daemon_snapshots.sh` | build VM (sudo, cargo) | the daemon code with the real helper, real `sudo -n` and real snapper on a loop btrfs |

## Terminal and remote-access sessions (N-306b)

The machine-wide managed settings (`/etc/claude-code/managed-settings.json`, the file that already makes every `claude` run on the
computer write the audit log) now also run `nisse-turn-hook` (package nisse-daemon) for three events of every turn:

| Event | What the hook does |
|---|---|
| `UserPromptSubmit` (the turn starts) | takes the pre snapshot; first closes the turn of that session that never got its `Stop` (an interrupt), as a pair if it changed things, else removed |
| `PreToolUse` | notes whether the turn calls a tool that can change the computer (same list as the daemon: Read, Glob, Grep, LS, WebFetch, WebSearch, TodoWrite, ToolSearch, AskUserQuestion are read-only, everything else counts) |
| `Stop` (the turn ends) | takes the post snapshot, or removes the pre snapshot when the turn only read things |

The facts it rests on are in `docs/claude-cli-notes.md` (every turn fires `UserPromptSubmit` and `Stop`, even with no tool).
The policy is the N-306 one: the same helper through `sudo -n`, the same audit records (kind `snapshot`, source `terminal`, both ids
in the post record), the turn goes ahead whether or not a snapshot exists, a real failure shows once per session as a
`systemMessage` notice and a machine with nothing to snapshot only audits. Sessions the daemon started (`NISSE_SESSION` is set)
are skipped, since the daemon takes their pair. The open turn of each session is kept in
`$XDG_RUNTIME_DIR/nisse-turns/<session>.json` (private directory, cleared at logout), because each hook call is its own process.
`NISSE_NO_SNAPSHOTS=1` turns the hook off; removing the managed settings file stops the audit and the snapshots for terminal
sessions. The hook never decides anything and always exits 0.

Remote-access sessions (`claude remote-control`) read the same managed settings and have no `NISSE_SESSION`, so the same hook
should cover them; that is not verified (it needs claude.ai or the phone) and is a hand check at GATE 3, together with an
interactive terminal session (Esc interrupts, one turn per message). A SIGKILL leaves a pre snapshot with no post: the daily prune
removes an old unpaired pre, and the next prompt of the same session closes it.

| Test | Where it runs | What it proves |
|---|---|---|
| `services/crates/nisse-daemon/tests/turn_hook.rs` | build VM (cargo) | the binary as Claude Code runs it, with a fake helper: pre, post and drop, audit ids, daemon sessions skipped, the notice once per session, interrupted turns, two sessions, junk input, always exit 0 |
| `tests/e2e/test_terminal_snapshots.sh` | build VM, signed in (3 tiny prompts) | the real `claude`, real managed settings, real helper through sudo, real snapper: a chat turn leaves nothing, a file-changing turn leaves a pair that brackets the change and carries the session id, a daemon-flagged turn is skipped |
| `tests/rpm/test_nisse_daemon.sh`, `tests/iso/test_iso_contents.sh` | build VM, ISO rebuild | the managed file holds only the audit and turn hooks (never a limit), the hook is installed |

## Not yet verified

- A real package install on an installed btrfs nisse system taking a real pair through dnf5 (the install-to-disk
  harness, `docs/install-harness.md`); queued with the next ISO rebuild.
- That `snapper create-config /` works on the installer's `root` subvolume layout at first boot (same queue).
- Discover (PackageKit) transactions run the same actions plugin: CHECKED at N-508b with PackageKit 1.4.0 in the build VM
  (`tools/spike/pk_actions_probe.sh`: a `pkcon` install fired the pre and post hooks like `dnf` did); not rerun on the image's 1.3.4.
  Moot for the image, which leaves Discover's RPM backend out (`docs/discover-spike.md`).
- `/boot` is outside the snapshots (N-307 to N-310).
- An AI turn on an installed btrfs nisse system taking a real pair through the packaged daemon and `sudo` (the install-to-disk
  harness, then a message to the panel); queued with the next ISO rebuild.
