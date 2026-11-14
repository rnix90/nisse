# Phase 0 Foundations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the decided fix-pass items and the image basics from `docs/roadmap.md` Phase 0 (items 0.1 to 0.5) so the AI layer and the look-and-feel work start from a solid base.

**Architecture:** Four independent areas, one commit per task: the hardware-routing script (Python, `hw/`), the daemon (Rust, `services/`), the QML panel (`panel/`), and packaging and image (RPM specs, presets, build scripts). Code tasks come first because their tests run in seconds; Task 11 rebuilds the ISO once and proves the packaging tasks on the real image.

**Tech Stack:** Python 3 + pytest (hw), Rust + tokio + zbus + serde (services), Qt 6 / QML + QtTest (panel), RPM specs, systemd presets, bash tests, kiwi-ng ISO build in the Fedora build VM (`docs/build-host.md`).

**Spec:** `docs/roadmap.md` (Phase 0), `docs/superpowers/specs/2026-10-28-nisse-os-design.md` (6.4 authority and guardrails), `docs/superpowers/specs/2026-10-29-kiwi-build-design.md`. Decisions are recorded in the ledger lines of `docs/milestone-1-decisions.md` (deferred minors of the Milestone 1 review) and in the roadmap.

## Global Constraints

- ASCII only in everything authored: no em dashes, smart quotes, arrows or emoji.
- No tokens, credentials or personal data in the repo or the image.
- Claude Code is never bundled in the image; it is fetched at first boot.
- TDD: every behaviour change gets a test that is run and seen to fail first.
- RPM changes bump the spec `Release` (kiwi may serve a cached RPM with the same name-version-release) and add a changelog entry dated with the real date, author `Bert <266182601+rnix90@users.noreply.github.com>`.
- Rust: `cargo fmt` and `cargo clippy -- -D warnings` stay clean in `services/`. Rust, QML and RPM tests run in the build VM (`bash tools/build/vm.sh sync` first, then `vm.sh ssh 'cd ~/nisse && ...'`); Python tests run on the host (`cd hw && python -m pytest -q`).
- Git commits end with the lines `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_012HaX4wM2HNi6CtaPcZCAUT`.
- Decisions already made (do not re-ask): authority is a config switch, default autonomous; the ISO uses the Fedora release repo only; Flatpak remotes are Fedora's plus Flathub; Fedora's full preset set is adopted except the exclusions named in Task 8.

## Review Focus

- Cancelling a running turn leaves no orphan `claude` process and the panel sees exactly one `SessionDone` and no "stopped unexpectedly" error (Task 5).
- A corrupt or unreadable `sessions.json` must not crash or hang the daemon: it starts empty, keeps the bad file for inspection, and audits a warning (Task 4).
- An unrecognised `authority` value in the config must fail closed to `supervised`, never open to `autonomous` (Task 3).
- No Python traceback reaches the journal from `nisse-hwroute` for a missing `dnf`, a broken profiles file or a failed command; after the attempt cap it stops retrying until `--retry` (Task 1).
- `nisse-release-common` and `nisse-hw` both touch `/usr/share/nisse`: installing both into the ISO must not produce a file conflict (Tasks 7 and 11).

---

### Task 1: hwroute errors and bounded retry

**Files:**
- Modify: `hw/nisse_hw/route.py`, `packaging/rpm/nisse-hw/nisse-hwroute.service`, `packaging/rpm/nisse-hw/nisse-hw.spec` (Release 2, changelog)
- Test: `hw/tests/test_route.py`, `tests/rpm/test_nisse_hw.sh`

**Interfaces:**
- Produces: `MAX_ATTEMPTS = 12` in `route.py`. `hw-profile.json` gains `"last_error": str` (one line, absent when status is `done`). `execute()` returns `0` done, `75` retry later, `1` gave up (status `failed`, attempts at the cap). `main()` returns `1` with a single stderr line beginning `nisse-hwroute: ` for any unexpected exception, never a traceback. New flag `--retry` sets the stored attempts back to 0 and exits 0.

- [ ] **Step 1: Write the failing tests** in `hw/tests/test_route.py`:
  - `test_execute_records_a_one_line_last_error`: runner returns 1 for the first command; state `last_error` contains that command's text and `status 1`, and has no newline.
  - `test_a_runner_that_cannot_start_dnf_is_a_retryable_error`: runner raises `FileNotFoundError("dnf")`; `execute` returns 75, `last_error` mentions `dnf`, no exception escapes.
  - `test_execute_gives_up_after_the_attempt_cap`: call `execute` with a failing runner `MAX_ATTEMPTS` times (75 each time until the last), the last call returns 1 and the state status is `failed`; one more call returns 1 without calling the runner at all.
  - `test_retry_flag_resets_the_attempt_count`: after a `failed` state, `main(["--retry", "--state-dir", str(tmp_path)])` returns 0 and the stored attempts are 0.
  - `test_main_prints_one_line_for_a_broken_profiles_file`: `main` with `--profiles` pointing at invalid TOML, `--state-dir tmp_path` and empty `--dmi-root`/`--pci-root` directories returns 1; captured stderr is exactly one line starting `nisse-hwroute: ` and does not contain `Traceback`.
  - `test_unit_stops_restarting_after_a_final_failure`: the unit text (`UNIT`) contains `RestartPreventExitStatus=1`.
- [ ] **Step 2: Run to verify they fail:** `cd hw && python -m pytest -q tests/test_route.py`. Expected: the six new tests FAIL (missing names or behaviour), existing tests pass.
- [ ] **Step 3: Implement** in `route.py`: `MAX_ATTEMPTS`; wrap each `runner(cmd)` call in `try/except OSError` and record `"{cmd text} exited with status {rc}"` or `"cannot run {cmd[0]}: {error}"`; write `last_error` through `_write_state`; check the attempts cap before running any command (stored attempts >= `MAX_ATTEMPTS` -> status `failed`, return 1, print `nisse-hwroute: giving up after N attempts: <last_error>` to stderr); add `--retry`; wrap `main` in `try/except Exception` printing one line to stderr and returning 1 (state status `error` is optional). Add `RestartPreventExitStatus=1` to the unit.
- [ ] **Step 4: Run to verify they pass:** `cd hw && python -m pytest -q`. Expected: all pass (45 existing plus the new ones).
- [ ] **Step 5: RPM test.** Add to `tests/rpm/test_nisse_hw.sh` an assertion that the packaged `nisse-hwroute.service` contains `RestartPreventExitStatus=1`; run it RED against the old RPM, bump the spec Release to 2 with a changelog line, rebuild (`tools/rpm/build-rpm.sh nisse-hw`), run it GREEN.
- [ ] **Step 6: Commit** `fix: nisse-hwroute reports one line, stops after a bounded number of attempts`.

---

### Task 2: CLI timeout

**Files:**
- Modify: `services/crates/nisse-daemon/src/runner.rs`, `services/crates/nisse-daemon/src/main.rs`
- Test: `services/crates/nisse-daemon/tests/runner.rs`

**Interfaces:**
- Produces: `pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(600)`; `ClaudeCliRunner::with_timeout(self, Duration) -> Self`; `main.rs` reads `NISSE_CLI_TIMEOUT_SECS` (positive integer) to override the default. When a turn exceeds the timeout the runner kills the child, sends `RunEvent::Error("Claude Code did not finish within N minutes and was stopped")` (N rounded up, at least 1) and then `RunEvent::Done`.

- [ ] **Step 1: Write the failing tests** in `tests/runner.rs`, using `fake_claude`:
  - `a_hung_cli_is_stopped_at_the_timeout`: the fake writes `$$` to a pid file inside its dir and then `exec sleep 30`; runner `with_timeout(300ms)`; `collect` ends within the helper's 10 s guard, the last two events are an `Error` containing `stopped` followed by `Done`, and afterwards `kill -0 <pid>` fails (no orphan).
  - `a_cli_that_finishes_in_time_is_unaffected`: a fake that prints the fixture and exits 0 under `with_timeout(5s)` yields the normal events and no `Error`.
- [ ] **Step 2: Run:** `cargo test -p nisse-daemon --test runner` in the VM. Expected: FAIL to compile (`with_timeout` missing).
- [ ] **Step 3: Implement** the timeout around the whole turn (spawn to exit) with `tokio::time::timeout`; on expiry `child.start_kill()`, `child.wait()`, then the two events. Keep the stderr-tail task from leaking.
- [ ] **Step 4: Run:** the whole `cargo test --workspace`, `cargo clippy --workspace -- -D warnings`, `cargo fmt --check`. Expected: all pass.
- [ ] **Step 5: Commit** `feat: stop a Claude CLI turn that runs longer than ten minutes`.

---

### Task 3: authority switch

**Files:**
- Modify: `services/crates/nisse-config/src/lib.rs`, `services/crates/nisse-daemon/src/runner.rs`, `services/crates/nisse-daemon/src/dbus.rs`, `docs/claude-cli-notes.md`
- Test: `services/crates/nisse-config/tests/config.rs`, `services/crates/nisse-daemon/tests/runner.rs`, `services/crates/nisse-daemon/tests/dbus.rs`

**Interfaces:**
- Produces: `nisse_config::Authority { Autonomous, Supervised }` with `as_str() -> &'static str` (`"autonomous"`, `"supervised"`); `Config.authority: Authority`, key `authority = "autonomous" | "supervised"` at the top level of `backends.toml`, default `Autonomous` when absent. Any other value loads as `Supervised` (fail closed). `RunRequest` gains `pub authority: Authority`; the runner uses `["--dangerously-skip-permissions"]` for Autonomous and `["--permission-mode", "default"]` for Supervised, and `ClaudeCliRunner` loses its fixed `permission_args`. D-Bus `GetAuthority() -> String` returns `Authority::as_str()` of the current config. `Daemon::send_message` passes the config's authority into each request.
- Note: until the approvals queue exists (roadmap 2.1), Supervised means the CLI's default permission mode in `-p` mode: actions that need a prompt are denied. That is intended.

- [ ] **Step 1: Write the failing tests:**
  - `config.rs`: `authority_defaults_to_autonomous`, `authority_supervised_is_read_from_the_file`, `an_unknown_authority_fails_closed_to_supervised`.
  - `runner.rs`: `autonomous_requests_skip_permissions` and `supervised_requests_use_the_default_permission_mode`: the fake `claude` writes `"$@"` to a file; assert the flag appears (and the other one does not).
  - `dbus.rs`: `get_authority_reports_the_configured_value` (write a config file with `authority = "supervised"`, call `GetAuthority`; and the default case without the key).
  - Update every existing `RunRequest { .. }` literal in tests with the new field (`Authority::Autonomous`).
- [ ] **Step 2: Run:** `cargo test --workspace` in the VM. Expected: FAIL to compile, then the new tests FAIL.
- [ ] **Step 3: Implement** as in Interfaces; keep `Config::default_max()` autonomous. Document the two modes in `docs/claude-cli-notes.md` next to the existing `--dangerously-skip-permissions` line.
- [ ] **Step 4: Run:** `cargo test --workspace`, clippy, fmt. Expected: all pass.
- [ ] **Step 5: Commit** `feat: config switch for AI authority (autonomous or supervised)`.

---

### Task 4: persistent daemon sessions

**Files:**
- Create: `services/crates/nisse-daemon/src/state.rs` (export it in `lib.rs`)
- Modify: `services/crates/nisse-daemon/src/dbus.rs`, `services/crates/nisse-daemon/src/main.rs`
- Test: `services/crates/nisse-daemon/tests/dbus.rs`

**Interfaces:**
- Produces: `state::default_state_path() -> PathBuf` (`$NISSE_STATE`, else `$XDG_STATE_HOME/nisse/sessions.json`, else `~/.local/state/nisse/sessions.json`); `Daemon::with_state_file(self, PathBuf) -> Daemon` loads the file and persists changes. File format `{"sessions": {"<id>": {"started": bool}}}`, written atomically (temp file in the same directory, then rename) on `NewSession` and on the `Started` event. A missing file means empty. An unreadable or invalid file is renamed to `sessions.json.bad`, the daemon starts empty, and an audit record of kind `state-warning` is written. `Daemon::new` keeps its current signature (in-memory only), so existing tests are unchanged.

- [ ] **Step 1: Write the failing tests** in `tests/dbus.rs` (the daemon in `setup` gets a state file in the scratch dir through a new optional parameter or a second helper):
  - `a_new_daemon_knows_the_sessions_of_the_old_one`: create a session, drop the daemon, build another on the same state file, `SendMessage` to the old id with a spy runner: no `session_error`, and the spy saw `resume == false` because no turn had started.
  - `a_started_session_is_resumed_after_a_restart`: runner emits `Started`; after restart the next request has `resume == true`.
  - `a_corrupt_state_file_is_set_aside_and_audited`: write `{not json` to the state file; daemon starts, `NewSession` works, `sessions.json.bad` exists, the audit log has a `state-warning` record.
- [ ] **Step 2: Run:** `cargo test -p nisse-daemon --test dbus`. Expected: FAIL (missing items).
- [ ] **Step 3: Implement** `state.rs` (load, save-atomic, path helper) and use it from `Daemon`; call `with_state_file(default_state_path())` in `main.rs`.
- [ ] **Step 4: Run:** `cargo test --workspace`, clippy, fmt, and `bash tests/e2e/panel_daemon.sh` (it builds nothing; run `cargo build` first). Expected: all pass.
- [ ] **Step 5: Commit** `feat: the daemon remembers its sessions across restarts`.

---

### Task 5: per-session queue and Cancel

**Files:**
- Modify: `services/crates/nisse-daemon/src/dbus.rs`, `services/crates/nisse-daemon/src/runner.rs` (only if a trait change is needed)
- Test: `services/crates/nisse-daemon/tests/dbus.rs`

**Interfaces:**
- Consumes: Task 4's session store, Task 3's `RunRequest.authority`.
- Produces: D-Bus `Cancel(session_id: String) -> bool` (true if a turn was running). Behaviour: a second `SendMessage` on a session that is running is queued and runs after the first turn ends, in order; each turn emits its own `MessageChunk`s and exactly one `SessionDone`. `Cancel` aborts the running turn (dropping the runner future so `kill_on_drop` stops the child), drops that session's queued messages, audits kind `cancel`, and emits exactly one `SessionDone` and no `SessionError`. `Cancel` on an idle or unknown session returns false and emits nothing.

- [ ] **Step 1: Write the failing tests** in `tests/dbus.rs` with spy runners:
  - `two_messages_on_one_session_never_run_at_once`: a runner that increments a shared counter on entry, sleeps 100 ms, records the maximum, decrements; two quick `SendMessage` calls; both replies arrive in order; the recorded maximum is 1; two `SessionDone` signals.
  - `cancel_stops_the_running_turn_and_signals_done_once`: a runner that holds a drop-guard and waits forever; after `Cancel` the guard's flag is set (the future was dropped), exactly one `SessionDone` arrives, no `SessionError` arrives within 500 ms.
  - `cancel_also_drops_queued_messages`: first message blocks, second is queued; after `Cancel` the second never reaches the runner.
  - `cancel_on_an_idle_session_returns_false`.
- [ ] **Step 2: Run:** `cargo test -p nisse-daemon --test dbus`. Expected: FAIL.
- [ ] **Step 3: Implement** a per-session state `{started, running, queue, abort_handle}` behind the existing mutex; the drain loop starts the next queued message when a turn ends; `Cancel` aborts and clears. Make sure the "agent stopped unexpectedly" error is not emitted for a cancelled turn.
- [ ] **Step 4: Run:** `cargo test --workspace`, clippy, fmt, `bash tests/e2e/panel_daemon.sh`. Expected: all pass.
- [ ] **Step 5: Commit** `feat: per-session message queue and Cancel in the daemon`.

---

### Task 6: panel Stop button and authority label

**Files:**
- Modify: `panel/src/DaemonClient.h`, `panel/src/DaemonClient.cpp`, `panel/qml/ChatView.qml`, `panel/qml/StatusBar.qml`, `panel/qml/Main.qml` (only to wire the label)
- Test: `panel/tests/tst_chat.qml` (and `panel/tests/tst_main.cpp` only if the build needs it)

**Interfaces:**
- Consumes: Task 5's `Cancel`, Task 3's `GetAuthority`.
- Produces: `Q_INVOKABLE void DaemonClient::cancel(const QString &session)` (async D-Bus `Cancel`); `Q_PROPERTY(QString authorityLabel READ authorityLabel NOTIFY authorityLabelChanged)` filled from `GetAuthority`, `"daemon offline"` when unreachable; `ChatView` shows a Stop button (`objectName: "stop"`) only while `busy`; clicking it calls `client.cancel(session)`; when `done` arrives `busy` is false and a `"Stopped."` note is appended if the stop was requested; `StatusBar` shows `Authority: <label>` next to the backend.

- [ ] **Step 1: Write the failing tests** in `tst_chat.qml` (the `stub` gains `property string authorityLabel: "autonomous"`, `property var cancelled: []` and `function cancel(session) { cancelled.push(session) }`):
  - `test_stop_button_is_visible_only_while_busy`.
  - `test_stop_calls_cancel_for_the_current_session`.
  - `test_done_after_stop_unlocks_the_input_and_notes_it`: after clicking Stop and emitting `done`, `busy` is false and the last message has role `note` and text `Stopped.`.
- [ ] **Step 2: Run:** in the VM `cmake -S panel -B /tmp/panel-build -G Ninja && cmake --build /tmp/panel-build && ctest --test-dir /tmp/panel-build --output-on-failure`. Expected: FAIL (new tests).
- [ ] **Step 3: Implement** the C++ method and property and the QML. Style: a `note` bubble uses a neutral background; no new colours outside what `ChatView.qml` already uses (the Ember palette arrives with roadmap 1.2).
- [ ] **Step 4: Run:** ctest, then `bash tests/e2e/panel_daemon.sh` (its self-test must still print `backend: max` and `reply: echo: ping`; extend `main.cpp --self-test` to also print `authority: autonomous` and assert it in the script). Expected: PASS.
- [ ] **Step 5: Commit** `feat: panel Stop button and authority label`.

---

### Task 7: os-release fields and `/usr/share/nisse` ownership

**Files:**
- Modify: `packaging/rpm/nisse-release/nisse-release.spec` (Release 3), `packaging/rpm/nisse-hw/nisse-hw.spec` (Release 3 if Task 1 made it 2)
- Test: `tests/rpm/test_nisse_release.sh`, `tests/rpm/test_nisse_hw.sh`

**Interfaces:**
- Produces: `/usr/lib/os-release` gains `DEFAULT_HOSTNAME=nisse`, `HOME_URL="https://github.com/rnix90/nisse"`, `BUG_REPORT_URL="https://github.com/rnix90/nisse/issues"`, `SUPPORT_URL="https://github.com/rnix90/nisse/discussions"`. `nisse-release-common` owns the directory `%dir %{_datadir}/nisse`; `nisse-hw` stops owning the parent (its `%files` lists `%{_datadir}/nisse/hw/` instead of `%{_datadir}/nisse/`) and `Requires: nisse-release-common`.

- [ ] **Step 1: Write the failing assertions:** in `test_nisse_release.sh` the four os-release lines and that `rpm -qpl "$common"` lists `/usr/share/nisse` as a directory (`rpm -qp --dump` shows mode starting with `04`); in `test_nisse_hw.sh` that `rpm -qpl` of nisse-hw does not list the bare `/usr/share/nisse` and that it requires `nisse-release-common`.
- [ ] **Step 2: Run:** both tests in the VM. Expected: FAIL.
- [ ] **Step 3: Implement** the spec edits and changelog entries; rebuild both RPMs and `tools/rpm/make-repo.sh`.
- [ ] **Step 4: Run:** both tests plus `tests/rpm/test_nisse_daemon.sh` (it ships a file in the shared directory). Expected: PASS.
- [ ] **Step 5: Commit** `fix: os-release fields and a single owner for /usr/share/nisse`.

---

### Task 8: adopt Fedora's full preset set

**Files:**
- Modify: `packaging/rpm/nisse-release/90-default.preset` (replace), `packaging/rpm/nisse-release/80-nisse-desktop.preset`, `packaging/rpm/nisse-release/85-display-manager.preset`, `packaging/rpm/nisse-release/README.md`, `packaging/rpm/nisse-release/nisse-release.spec` (Release 4)
- Test: `tests/rpm/test_nisse_release.sh`, `tests/iso/test_iso_contents.sh`

**Interfaces:**
- Produces: `90-default.preset` and `85-display-manager.preset` become Fedora's own files from `fedora-release-common 44-18` (MIT), taken byte for byte from the RPM (`dnf download fedora-release-common` in the VM, then `rpm2cpio | cpio`), with a header comment `# Derived from fedora-release-common 44-18 (MIT). See README.md.` as the first line. nisse's deviations live only in `80-nisse-desktop.preset` (it sorts first, so it wins): `disable plasma-setup.service` (Fedora's KDE first-boot wizard; nisse has its own first-boot flow, revisit with roadmap 1.12). `99-default-disable.preset` stays as is. Everything else Fedora enables is enabled, including `systemd-resolved`, `systemd-oomd`, `tuned`, `tuned-ppd`, `power-profiles-daemon`, `thermald`, `uresourced`, `fstrim.timer`, `logrotate.timer`, `plocate-updatedb.timer`, `audit-rules`, `flatpak-add-fedora-repos`, the modular libvirt sockets, `livesys*`, `nmstate`, `intel_lpmd`.
- If an enabled-by-preset pair of units conflicts in the installed image (for example `power-profiles-daemon` with `tuned-ppd`), the image decides by which package is installed; do not invent exclusions: record what is installed in the ledger.

- [ ] **Step 1: Write the failing tests.** `test_nisse_release.sh`: the packaged `90-default.preset` starts with the provenance line and contains each of these exact lines: `enable systemd-resolved.service`, `enable systemd-oomd.*`, `enable tuned.service`, `enable power-profiles-daemon.service`, `enable thermald.service`, `enable fstrim.timer`, `enable audit-rules.service`, `enable flatpak-add-fedora-repos.service`; `80-nisse-desktop.preset` contains `disable plasma-setup.service` and still has the three existing enables; the packaged `85-display-manager.preset` contains `enable plasmalogin.service`. `test_iso_contents.sh`: parse every glob-free `enable X` line of the packaged `90-default.preset` and `80-nisse-desktop.preset` from the RPM tree in the repo (`packaging/rpm/nisse-release/`), and for each unit whose file exists under `$root/usr/lib/systemd/system/` assert `systemctl --root="$root" is-enabled X` prints `enabled`; print the list of units skipped because the image does not contain them.
- [ ] **Step 2: Run:** the RPM test (RED) now; the ISO test goes RED against the existing ISO and is fully proven in Task 11.
- [ ] **Step 3: Implement:** fetch Fedora's files in the VM, prepend the provenance line, drop them into the package directory, edit the 80 preset, update `README.md` (what is Fedora's, what is nisse's, how to refresh when Fedora releases a new `fedora-release-common`), bump the spec Release and add the changelog line.
- [ ] **Step 4: Run:** `tests/rpm/test_nisse_release.sh` GREEN after `tools/rpm/build-rpm.sh nisse-release` and `tools/rpm/make-repo.sh`; also `rpmlint` output stays at 0 errors.
- [ ] **Step 5: Commit** `feat: adopt Fedora's full systemd preset set`.

---

### Task 9: first boot: no Claude fetch on live media, Flatpak remotes

**Files:**
- Create: `packaging/rpm/nisse-firstboot/nisse-flatpak-remotes`, `packaging/rpm/nisse-firstboot/nisse-flatpak-remotes.service`
- Modify: `packaging/rpm/nisse-firstboot/nisse-fetch-claude.service`, `packaging/rpm/nisse-firstboot/81-nisse-firstboot.preset`, `packaging/rpm/nisse-firstboot/nisse-firstboot.spec` (Release bump, files, `Requires: flatpak`)
- Test: `tests/rpm/test_nisse_firstboot.sh`, `tests/shell/test_flatpak_remotes.sh` (new)

**Interfaces:**
- Produces: `nisse-fetch-claude.service` gains `ConditionKernelCommandLine=!rd.live.image` (a live session no longer downloads Claude Code into RAM). `/usr/bin/nisse-flatpak-remotes` (POSIX sh): adds the `flathub` remote (`https://dl.flathub.org/repo/flathub.flatpakrepo`, system-wide, `--if-not-exists`); exit 0 done, 75 when offline, 1 on failure; `NISSE_FLATPAK` overrides the `flatpak` command and `NISSE_PROBE_URL` the connectivity probe, for tests (same pattern as `nisse-fetch-claude`). `nisse-flatpak-remotes.service`: a system unit, `Type=oneshot`, `After=network-online.target`, `ConditionKernelCommandLine=!rd.live.image`, `ConditionPathExists=!/var/lib/nisse/flatpak-remotes.done`, retries on 75 like the fetch unit, touches that done file on success; enabled by `81-nisse-firstboot.preset`. Fedora's own remote comes from `flatpak-add-fedora-repos.service` (Task 8).

- [ ] **Step 1: Write the failing tests:** `test_nisse_firstboot.sh` asserts the fetch unit has the live condition, the RPM ships the new script and unit, and the preset enables the unit. `tests/shell/test_flatpak_remotes.sh` (model it on `tests/shell/test_fetch_claude.sh`): with a stub `flatpak` that records its arguments, a reachable probe results in exit 0 and a `remote-add --if-not-exists flathub <url>` call; an unreachable probe exits 75 and calls nothing; a failing stub exits 1.
- [ ] **Step 2: Run:** both tests. Expected: FAIL (missing files).
- [ ] **Step 3: Implement** the script, unit, preset line and spec changes; rebuild the RPM.
- [ ] **Step 4: Run:** both tests, `tests/rpm/test_nisse_firstboot.sh` GREEN; rpmlint 0 errors.
- [ ] **Step 5: Commit** `feat: skip the Claude fetch on live media; add the Flathub remote at first boot`.

---

### Task 10: deferred minors from the kiwi review

**Files:**
- Modify: `build/build-iso.sh`, `build/render-kiwi.sh`, `tools/build/check-host.sh`, `tools/vm/smoke-boot.sh`, `tests/build/test_kiwi_description.sh`; git file modes of two vendored scripts
- Test: `tests/build/test_build_guards.sh`, `tests/build/test_kiwi_description.sh`

**Interfaces:**
- Produces: `build-iso.sh` prints `kiwi finished but produced no ISO in out/kiwi-build` (and exits 1) when kiwi leaves no ISO instead of aborting inside `ls | head`; its mount guard uses `grep -qF -- "$root/out/kiwi-build"` with `pwd -P`; `render-kiwi.sh` substitutes values containing `|`, `&` or `\` literally; the description test greps the whole rendered directory for `alias="updates"` and reads the release from `build/FEDORA_RELEASE` instead of hardcoding `nisse-44`; `check-host.sh` requires `distribution-gpg-keys` (exit 2 with the install hint); `build/kiwi/fedora/config.sh` and `editbootinstall_rpilegacy.sh` are mode 100755 in git (`git update-index --chmod=+x`), with the reproducibility test comparing modes too; `smoke-boot.sh`'s second screendump `printf` has its format string on one line (`'screendump %s -f png\n'`, written with the Edit tool because the Bash tool collapses backslashes).

- [ ] **Step 1: Write the failing tests:** in `test_build_guards.sh` a case where a stub `kiwi-ng` on `PATH` exits 0 without creating an ISO: `build-iso.sh` must exit 1 with that exact message (the script needs the stub, a fake repo with `repodata/repomd.xml`, and a stubbed `render-kiwi.sh`/`sudo`; use a scratch tree like the existing cases). In `test_kiwi_description.sh`: a render with `NISSE_KERNELCMDLINE='a|b&c'` leaves that exact string in `Nisse.kiwi`/`nisse-live.xml`; the vendored-mode check (`git ls-files -s` shows 100755 for the two scripts).
- [ ] **Step 2: Run:** both tests. Expected: FAIL on the new cases.
- [ ] **Step 3: Implement** the fixes listed under Interfaces.
- [ ] **Step 4: Run:** `bash tests/build/test_build_guards.sh` (host), `bash tests/build/test_kiwi_description.sh` (host part 1 and VM part 2), `bash tests/repo/test_tracked_files.sh`. Expected: PASS.
- [ ] **Step 5: Commit** `fix: deferred minors from the kiwi build review`.

---

### Task 11: rebuild the ISO and prove Phase 0 on the image

**Files:**
- Modify: `docs/roadmap.md` (mark 0.1 to 0.5 done, with the commit range), `docs/build-host.md` only if a step changed
- Test: the whole suite

- [ ] **Step 1:** Sync, build every RPM and the repo, rebuild the ISO in the VM: `bash tools/build/vm.sh sync` then `setsid nohup bash build/build-all.sh > out/build-all.log 2>&1 < /dev/null &` (about 35 minutes; check `out/build-all.log` for `== done`). Expected: ends with `== done` and a new `out/nisse-live.iso`.
- [ ] **Step 2:** `bash tests/iso/test_iso_contents.sh out/nisse-live.iso`. Expected: PASS including the new preset check (the skipped-units list printed). Also check in the image: `DEFAULT_HOSTNAME=nisse` and the three URLs in `usr/lib/os-release`; exactly one owner of `/usr/share/nisse` (`rpm -qf`).
- [ ] **Step 3:** Pull the ISO, `bash tools/vm/smoke-boot.sh ISO --out DIR --screenshot DIR/desktop.png --settle 60`; the screenshot must show the live desktop with "Welcome to nisse!". On the serial log confirm `nisse-fetch-claude` did not run (no fetch line) on the live boot.
- [ ] **Step 4:** `bash tests/e2e/test_hw_in_vm.sh ISO` (4 boots, leave the host idle). Expected: `PASS: hardware routing in VMs`.
- [ ] **Step 5:** Run the whole suite (hw pytest, `cargo test --workspace`, panel ctest, `tests/e2e/panel_daemon.sh`, every `tests/rpm/test_*.sh`, `tests/shell/*.sh`, `tests/build/*.sh`, `tests/repo/test_tracked_files.sh`). Expected: all PASS.
- [ ] **Step 6:** Update the roadmap statuses, commit `docs: Phase 0 done`, and push `daily`.

---

## Self-review notes

- **Spec coverage:** roadmap 0.1 (Tasks 1, 2, 4, 5, 6, 9), 0.2 (Task 7), 0.3 (Tasks 8, 9), 0.4 (Task 10), 0.5 (Tasks 3, 6). The remaining decided fix-pass item "skip the Claude fetch on live boots" is Task 9.
- **Rulings the executor settles and ledgers:** the exact attempt cap value and wording of errors, how Supervised maps onto the CLI flags if `--permission-mode default` behaves differently in `-p` mode than assumed, which of the power units are actually installed in the image, and whether kiwi needs `flatpak` added to the package list for Task 9's `Requires: flatpak`.
- **Not in this plan:** Plasma theming (Phase 1), approvals queue, tabs and backend routing (Phase 2), the `LiveInstall` profile spike, real-hardware work.
