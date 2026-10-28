# Nisse Milestone 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A bootable, branded Nisse live/install ISO whose installed system picks a kernel by hardware (Surface, T2 MacBook, pre-T2 MacBook, generic) and ships a bare-bones AI panel talking to a Rust daemon that drives Claude Code.

**Architecture:** Our own RPMs (`nisse-release`, `nisse-branding`, `nisse-fonts-nunito`, `nisse-hw`, `nisse-firstboot`, `nisse-daemon`, `nisse-panel`) are built into a local repo and pulled into a Fedora KDE kickstart that produces the ISO with `livemedia-creator`. Hardware detection is a pure Python library with a thin `nisse-hwroute` executor. The daemon is a Rust user service exposing a small D-Bus API; the panel is a Qt6/QML app that calls it. QEMU with spoofed SMBIOS stands in for real hardware.

**Tech Stack:** Fedora (version in `build/FEDORA_RELEASE`), kickstart, livemedia-creator, rpmbuild, createrepo_c, QEMU+OVMF, Python 3 + pytest, Rust (tokio, zbus, serde, toml), Qt6 Quick (QML) with thin C++ glue, shell.

**Spec:** `docs/superpowers/specs/2026-10-28-nisse-os-design.md`

## Global Constraints

- Base is Fedora, latest stable release, classic RPM remix built with kickstart and Anaconda. Not image-based.
- One x86_64 image for desktop, laptop, Surface Go and Intel MacBooks.
- Surface: linux-surface kernel. T2-era MacBooks (about 2018-2020): t2linux kernel, Secure Boot off. Pre-T2 MacBooks (2017 and older): stock kernel plus Broadcom Wi-Fi and FaceTime camera driver packages.
- Claude Code is fetched from Anthropic's own installer at first boot. It is never inside the ISO. No network at first boot is not a failure: retry until it works.
- Build host is WSL2 or a VM on RN-DESKTOP, run by hand. No CI.
- Code split: shell and Python for installer/kickstart glue; Rust for services and MCP servers; QML for panel UI.
- License GPL-2.0-or-later with an SPDX header in every source file. Bundled Nunito is SIL OFL 1.1.
- Plain ASCII in everything authored. Nothing personal (hostnames, credentials, homelab) in the repo or image.
- Channel (`stable` default, `daily`) is chosen by the `nisse-release` package. Work lands on the `daily` branch.

## Review Focus

- Blank, junk or missing DMI data (VMs, "To Be Filled By O.E.M.") must yield `generic`, never a crash or a wrong kernel. Owner: Task 4.
- A pre-T2 MacBook must never be routed to the T2 kernel, and an unlisted Apple model must not crash detection. Owner: Task 4.
- hwroute run with no network must finish without failing the boot and retry later. Owner: Task 5.
- Claude CLI missing, exiting non-zero, or printing malformed JSON must surface as an error in the panel, not hang or crash the daemon. Owner: Task 7.
- Audit log with a truncated last line (power loss) or a missing file must still read, and later appends must be intact. Owner: Task 6.

Out of scope for this plan, each gets its own plan later: snapper/safe-apply rollback and btrfs layout; approvals queue, tabs, rollback button, per-category routing UI and the Plasma widget; mediated root tools and enforced guardrails; the first-boot config-prompt ingestion layer; signing keys, MOK enrollment and the GitHub-hosted channels; the VM fault-injection suite; encryption and Secure Boot prompts.

## File Structure

- `build/` : kickstarts, `FEDORA_RELEASE`, `build-iso.sh`
- `packaging/rpm/<name>/` : one spec (and payload files) per RPM
- `hw/nisse_hw/` + `hw/tests/` : detection and routing (Python)
- `services/` : Rust workspace (`nisse-audit`, `nisse-config`, `nisse-daemon`)
- `panel/` : Qt6/QML app
- `tools/rpm/`, `tools/vm/`, `tools/build/` : helper scripts
- `tests/` : shell tests that span components (rpm, iso, e2e)

All commands run inside the Fedora build environment from Task 0 unless a step says otherwise.

---

### Task 0: Build host check and Fedora pin

**Files:**
- Create: `tools/build/check-host.sh`, `build/FEDORA_RELEASE`, `docs/build-host.md`

**Interfaces:**
- Produces: `build/FEDORA_RELEASE` (a single integer, no newline issues, read by every build script); `check-host.sh` exits 0 only on a ready host.

- [ ] **Step 1:** Write `tools/build/check-host.sh`: exit 1 with "not Fedora" unless `/etc/os-release` has `ID=fedora`; then require `livemedia-creator rpmbuild createrepo_c qemu-system-x86_64 xorriso unsquashfs ksflatten` on PATH and `/usr/share/edk2/ovmf/OVMF_CODE.fd`; on any miss print one `sudo dnf install ...` line naming the packages and exit 2.
- [ ] **Step 2:** Run it in Git Bash on Windows. Expected: exit 1, "not Fedora".
- [ ] **Step 3:** Try WSL2 Fedora first. Verify loop devices work: `truncate -s 1G /tmp/t.img && mkfs.ext4 -F /tmp/t.img && sudo mount -o loop /tmp/t.img /mnt`. If that fails, use a Fedora VM instead. Install the packages the script names. Run the script. Expected: exit 0.
- [ ] **Step 4:** Query `https://fedoraproject.org/releases.json` for the newest stable Fedora Workstation/KDE release number and write it to `build/FEDORA_RELEASE`.
- [ ] **Step 5:** Record the chosen host (WSL2 or VM), why, and how to enter it in `docs/build-host.md`. Commit `build: host check and Fedora pin`.

### Task 1: RPM tooling and `nisse-release`

**Files:**
- Create: `tools/rpm/build-rpm.sh`, `tools/rpm/make-repo.sh`, `packaging/rpm/nisse-release/{nisse-release.spec,os-release,nisse-stable.repo,nisse-daily.repo,channel}`, `tests/rpm/test_nisse_release.sh`

**Interfaces:**
- Produces: `tools/rpm/build-rpm.sh NAME` builds `packaging/rpm/NAME/NAME.spec` into `out/rpmbuild/RPMS/`; `tools/rpm/make-repo.sh` runs `createrepo_c out/repo` after copying all built RPMs there. Later tasks call both.

- [ ] **Step 1:** Write `tests/rpm/test_nisse_release.sh` asserting on the built RPM: `os-release` content has `ID=nisse`, `ID_LIKE="fedora"`, `LOGO=distributor-logo-nisse`, `VERSION_ID=$(cat build/FEDORA_RELEASE)`; `rpm -qp --provides` contains `system-release`; `rpm -qp --conflicts` contains `fedora-release`; `/etc/nisse/channel` contains exactly `stable`; both `.repo` files exist and contain `enabled=0` (no remote repo exists yet; the GitHub plan flips stable to 1); `rpmlint` reports no errors.
- [ ] **Step 2:** Run it. Expected: FAIL, RPM not found.
- [ ] **Step 3:** Write the two helper scripts and the spec. Model the spec on Fedora's `generic-release` (fetch its spec from Fedora dist-git as reference). Repo `baseurl` values use the placeholder host `https://REPO_HOST_TBD/nisse/{stable,daily}/$basearch`, and both repo files ship `enabled=0` until the GitHub plan fills in the real URL.
- [ ] **Step 4:** Run the test. Expected: PASS.
- [ ] **Step 5:** Commit `rpm: tooling and nisse-release`.

### Task 2: Branding and font RPMs

**Files:**
- Create: `packaging/rpm/nisse-branding/nisse-branding.spec`, `packaging/rpm/nisse-fonts-nunito/nisse-fonts-nunito.spec`, `tests/rpm/test_branding.sh`

**Interfaces:**
- Consumes: Task 1 tooling; `assets/logo/linux/hicolor/**`; `assets/fonts/Nunito/*`.
- Produces: RPM `nisse-branding` (hicolor icons incl. `distributor-logo-nisse` at all sizes, scalable and symbolic); RPM `nisse-fonts-nunito` (variable TTFs in `/usr/share/fonts/nunito/`, `OFL.txt` as `%license`, `Provides: font(nunito)`).

- [ ] **Step 1:** Write `tests/rpm/test_branding.sh`: `rpm -qlp` of branding contains `/usr/share/icons/hicolor/48x48/apps/distributor-logo-nisse.png`, `/usr/share/icons/hicolor/scalable/apps/distributor-logo-nisse.svg` and `/usr/share/icons/hicolor/symbolic/apps/distributor-logo-nisse-symbolic.svg`; fonts RPM lists both TTFs and a license file; `License: OFL-1.1` on fonts, `GPL-2.0-or-later` on branding.
- [ ] **Step 2:** Run it. Expected: FAIL.
- [ ] **Step 3:** Write both specs (sources taken from the repo tree via the Task 1 tar step). Run `gtk-update-icon-cache`/`fc-cache` in `%post` via standard scriptlet macros.
- [ ] **Step 4:** Run the test. Expected: PASS.
- [ ] **Step 5:** Commit `rpm: branding and Nunito font packages`.

### Task 3: Kickstart, ISO build and boot smoke

**Files:**
- Create: `build/kickstart/fedora-live-kde.flat.ks` (vendored), `build/kickstart/nisse-live.ks`, `build/build-iso.sh`, `tools/vm/smoke-boot.sh`, `tests/iso/test_iso_contents.sh`

**Interfaces:**
- Consumes: `out/repo` (Tasks 1-2), `build/FEDORA_RELEASE`.
- Produces: `out/nisse-live.iso`; `tools/vm/smoke-boot.sh ISO [--smbios-product P --smbios-vendor V]` boots it headless under QEMU+OVMF with serial to `out/vm/serial.log`, exits 0 if the log shows "Graphical Interface" within 300 s. Later tasks reuse the SMBIOS flags.

- [ ] **Step 1:** Write `tests/iso/test_iso_contents.sh ISO`: unpack the root filesystem with `unsquashfs`, assert `/usr/lib/os-release` has `ID=nisse`, `/usr/share/fonts/nunito/` exists, and no file named `claude` exists anywhere in it (Claude Code must not be bundled).
- [ ] **Step 2:** Write `smoke-boot.sh` first and run it against the stock Fedora KDE live ISO to prove the harness works. Expected: PASS ("Graphical Interface" seen).
- [ ] **Step 3:** Vendor the flattened kickstart: `ksflatten -c fedora-live-kde.ks` from the `fedora-kickstarts` branch matching `FEDORA_RELEASE`; record source branch and commit in a header comment. Write `nisse-live.ks`: `%include` the flat file, add `repo --name=nisse --baseurl=file:///$PWD/out/repo` (path injected by `build-iso.sh`), remove `fedora-release*`, add `nisse-release nisse-branding nisse-fonts-nunito`.
- [ ] **Step 4:** Write `build-iso.sh`: run `livemedia-creator --ks build/kickstart/nisse-live.ks --no-virt --make-iso --project Nisse --releasever $(cat build/FEDORA_RELEASE) --volid Nisse --iso-only --iso-name nisse-live.iso --extra-boot-args "console=ttyS0 systemd.log_target=console" --resultdir out/iso`, then copy to `out/nisse-live.iso`.
- [ ] **Step 5:** Run `build-iso.sh`, then `test_iso_contents.sh out/nisse-live.iso` and `smoke-boot.sh out/nisse-live.iso`. Expected: both PASS. If `fedora-release` conflicts break the transaction, fix package exclusions until the build passes.
- [ ] **Step 6:** Commit `build: branded live ISO and boot smoke test`.

### Task 4: Hardware detection library

**Files:**
- Create: `hw/nisse_hw/__init__.py`, `hw/nisse_hw/detect.py`, `hw/tests/test_detect.py`, `hw/tests/fixtures/<name>/` (fake `/sys/class/dmi/id` trees), `hw/pyproject.toml`

**Interfaces:**
- Produces (all in `nisse_hw.detect`):
  - `@dataclass(frozen=True) class DmiInfo: sys_vendor: str; product_name: str; product_family: str; product_version: str` (empty string when missing)
  - `class Profile(str, Enum): GENERIC="generic"; SURFACE="surface"; APPLE_T2="apple-t2"; APPLE_PRE_T2="apple-pre-t2"`
  - `read_dmi(root: Path = Path("/sys/class/dmi/id")) -> DmiInfo`
  - `read_pci_ids(root: Path = Path("/sys/bus/pci/devices")) -> frozenset[str]` ("vvvv:dddd" lowercase)
  - `detect(dmi: DmiInfo, pci_ids: frozenset[str] = frozenset()) -> Profile`
  - CLI `python -m nisse_hw.detect [--dmi-root P] [--pci-root P] [--json]`: prints the profile name, or `{"profile": ..., "dmi": {...}}` with `--json`.

- [ ] **Step 1:** Write `hw/tests/test_detect.py` with these cases (assert on `detect(...)`):
  - Surface Go: vendor "Microsoft Corporation", name "Surface Go" -> `Profile.SURFACE`; Surface Laptop 4 (family "Surface") -> `SURFACE`.
  - Apple "MacBookPro15,2" -> `APPLE_T2`; "MacBookAir8,1" -> `APPLE_T2`; "MacBookPro16,1" -> `APPLE_T2`.
  - Apple "MacBookPro13,1" -> `APPLE_PRE_T2`; "MacBookAir7,2" -> `APPLE_PRE_T2`.
  - Apple "MacBookPro99,9" with `frozenset({"106b:1801"})` -> `APPLE_T2`; the same model without PCI IDs -> `APPLE_PRE_T2`.
  - Apple "iMac12,1" -> `GENERIC`.
  - `DmiInfo("", "", "", "")` -> `GENERIC`; vendor "To Be Filled By O.E.M." -> `GENERIC`; QEMU ("QEMU", "Standard PC (Q35 + ICH9, 2009)") -> `GENERIC`.
  - `read_dmi` on a fixture directory missing most files returns empty strings; on an empty/nonexistent directory returns an all-empty `DmiInfo`.
  - CLI on a fixture prints exactly `surface\n`.
- [ ] **Step 2:** Run `pytest hw -v`. Expected: FAIL, import error.
- [ ] **Step 3:** Implement the interfaces. Rules: Surface = vendor "Microsoft Corporation" and (`product_family` or `product_name` starts with "Surface"); Apple = vendor "Apple Inc." and `product_name` matches `^MacBook(Pro|Air)\d+,\d+$`, then T2 if the name is in a constant `T2_MODELS` (MacBookPro15,1-4; MacBookPro16,1-4; MacBookAir8,1-2; MacBookAir9,1) or `"106b:1801"` is in `pci_ids`, else pre-T2; everything else `GENERIC`. Check `T2_MODELS` against the t2linux supported-device list before committing and note the source in a comment.
- [ ] **Step 4:** Run `pytest hw -v`. Expected: PASS.
- [ ] **Step 5:** Commit `hw: hardware detection library`.

### Task 5: Hardware routing executor

**Files:**
- Create: `hw/nisse_hw/route.py`, `hw/nisse_hw/profiles.toml`, `hw/tests/test_route.py`, `packaging/rpm/nisse-hw/{nisse-hw.spec,nisse-hwroute.service}`

**Interfaces:**
- Consumes: `Profile`, `detect` (Task 4).
- Produces (in `nisse_hw.route`):
  - `@dataclass(frozen=True) class Plan: profile: Profile; commands: tuple[tuple[str, ...], ...]; notes: tuple[str, ...]`
  - `plan(profile: Profile, profiles_toml: Path) -> Plan`
  - `execute(plan: Plan, runner: Callable[[Sequence[str]], int], state_dir: Path) -> int` returns 0 on done, 75 on pending; writes `state_dir/hw-profile.json` as `{"profile": str, "status": "done"|"pending", "attempts": int}`
  - CLI `nisse-hwroute [--dry-run] [--state-dir /var/lib/nisse] [--profiles /usr/share/nisse/hw/profiles.toml]` (dry-run prints one command per line, exits 0)
  - systemd unit `nisse-hwroute.service` (oneshot, `After=network-online.target`, `Restart=on-failure`, `RestartSec=300`, `RestartForceExitStatus=75`, `ConditionPathExists=!/var/lib/nisse/hwroute.done`)

- [ ] **Step 1:** Write `hw/tests/test_route.py` using a fake `runner`:
  - `plan(SURFACE, toml)` commands include `("dnf","config-manager","addrepo","--from-repofile=<surface repo url>")` and a `dnf install -y` containing `kernel-surface`.
  - `plan(APPLE_T2, toml)` includes `("dnf","copr","enable","-y","<t2linux copr>")` and installs the t2 kernel; `notes` mentions Secure Boot must be off.
  - `plan(APPLE_PRE_T2, toml)` installs the Broadcom Wi-Fi and FaceTime camera packages and never a kernel package.
  - `plan(GENERIC, toml)` has empty `commands`.
  - `execute` with a runner returning 0: returns 0, state file `status == "done"`, `attempts == 1`, creates `hwroute.done`.
  - `execute` with a runner returning 1 (offline): returns 75, `status == "pending"`, no `hwroute.done`; a second call increments `attempts` to 2.
  - `execute` for a generic plan returns 0 and writes `done` without calling the runner.
- [ ] **Step 2:** Run `pytest hw/tests/test_route.py -v`. Expected: FAIL.
- [ ] **Step 3:** Implement. `profiles.toml` has a table per profile with `repo_urls`, `copr`, `packages`, `notes`. Before filling it, verify against current docs and record the source in comments: the linux-surface Fedora repo file URL and package names; the t2linux Fedora COPR name and kernel package; the RPM Fusion and COPR sources for the Broadcom Wi-Fi and FaceTime camera packages.
- [ ] **Step 4:** Run `pytest hw -v`. Expected: PASS.
- [ ] **Step 5:** Write `nisse-hw.spec` (installs the Python package, `profiles.toml` to `/usr/share/nisse/hw/`, the unit, `%systemd_post`, and a preset enabling the unit). Build it with Task 1 tooling.
- [ ] **Step 6:** Commit `hw: kernel routing executor and service`.

### Task 6: Audit log and backend config (Rust)

**Files:**
- Create: `services/Cargo.toml` (workspace), `services/crates/nisse-audit/{Cargo.toml,src/lib.rs,src/bin/nisse-audit-hook.rs,tests/audit.rs}`, `services/crates/nisse-config/{Cargo.toml,src/lib.rs,tests/config.rs}`

**Interfaces:**
- Produces, `nisse_audit`:
  - `pub struct AuditRecord { pub ts: String, pub session: Option<String>, pub actor: String, pub kind: String, pub detail: serde_json::Value }` (serde)
  - `pub struct AuditLog` with `pub fn open(path: impl Into<PathBuf>) -> io::Result<AuditLog>` and `pub fn append(&self, rec: &AuditRecord) -> io::Result<()>`
  - `pub fn tail(path: &Path, n: usize) -> io::Result<Vec<AuditRecord>>`
  - binary `nisse-audit-hook`: reads a Claude Code hook JSON object on stdin and appends a record with `kind: "tool"`; always exits 0.
- Produces, `nisse_config`:
  - `pub enum BackendKind { Max, Ollama }`; `pub struct Backend { pub name: String, pub kind: BackendKind, pub base_url: Option<String>, pub model: Option<String> }`
  - `pub struct Config { pub main: String, pub backends: Vec<Backend>, pub routes: BTreeMap<String, String> }`
  - `pub fn load(path: &Path) -> Result<Config, ConfigError>`; `Config::default_max() -> Config`; `Config::main_backend(&self) -> &Backend`
  - `pub fn claude_env(b: &Backend) -> Vec<(String, String)>`: Max gives an empty vec; Ollama gives `ANTHROPIC_BASE_URL`=base_url, `ANTHROPIC_AUTH_TOKEN`="ollama", `ANTHROPIC_API_KEY`="", `ANTHROPIC_MODEL`=model.

- [ ] **Step 1:** Write `tests/audit.rs`: append 3 records, `tail(path, 2)` returns the last two in order; a file whose last line is truncated JSON returns the parsed lines before it and a later `append` still yields a parsable new record; `tail` on a nonexistent path returns `Ok(vec![])`; two threads appending 100 records each produce 200 parsable lines.
- [ ] **Step 2:** Write `tests/config.rs`: a TOML with `main = "max"` and an Ollama backend at `http://192.0.2.10:11434` round-trips; `claude_env` for that backend contains the four variables above; `load` on a missing file returns `ConfigError::NotFound` and `Config::default_max().main_backend().kind == BackendKind::Max`; a `main` naming an unknown backend returns `ConfigError::UnknownMain`; `routes` entries pointing at unknown backends return `ConfigError::UnknownRoute`. (Routes are parsed and validated only; nothing uses them yet.)
- [ ] **Step 3:** Run `cargo test --workspace` in `services/`. Expected: FAIL.
- [ ] **Step 4:** Implement both crates. Append is one `write_all` of the line plus `\n` to a file opened with `O_APPEND`; `tail` skips lines that fail to parse.
- [ ] **Step 5:** Run `cargo test --workspace`. Expected: PASS. Run `cargo clippy --workspace -- -D warnings`. Expected: clean.
- [ ] **Step 6:** Commit `services: audit log and backend config`.

### Task 7: Daemon

**Files:**
- Create: `services/crates/nisse-daemon/{Cargo.toml,src/main.rs,src/runner.rs,src/dbus.rs,tests/dbus.rs,tests/fixtures/hello.jsonl}`, `docs/claude-cli-notes.md`, `packaging/rpm/nisse-daemon/{nisse-daemon.spec,nisse-daemon.service,claude-settings.json}`

**Interfaces:**
- Consumes: `nisse_audit::{AuditLog, AuditRecord, tail}`, `nisse_config::{load, Config, claude_env}`.
- Produces:
  - `pub enum RunEvent { Text(String), Done, Error(String) }`; `pub struct RunRequest { pub session_id: String, pub prompt: String, pub env: Vec<(String, String)>, pub resume: bool }`
  - `#[async_trait] pub trait AgentRunner: Send + Sync { async fn run(&self, req: RunRequest, tx: tokio::sync::mpsc::Sender<RunEvent>); }`
  - `pub struct ClaudeCliRunner` (spawns `claude`, parses its stream JSON) and `pub struct FakeRunner` (echoes the prompt as `Text`, then `Done`)
  - D-Bus (session bus) name `org.nisse.Daemon1`, path `/org/nisse/Daemon1`, interface `org.nisse.Daemon1`: `NewSession() -> s`; `SendMessage(s session_id, s text)`; signals `MessageChunk(s session_id, s text)`, `SessionDone(s session_id)`, `SessionError(s session_id, s message)`; `GetBackend() -> (s name, s kind, s base_url, s model)`; `AuditTail(u n) -> as` (JSON lines).
  - Env `NISSE_FAKE_RUNNER=1` selects `FakeRunner`; `NISSE_CONFIG` and `NISSE_AUDIT_LOG` override paths.

- [ ] **Step 1:** Run `claude --help` and one real call `claude -p "say hi" --output-format stream-json --verbose`; save the output as `tests/fixtures/hello.jsonl` and record the exact flags, the `--settings` and `--resume` behavior, and the managed-settings path in `docs/claude-cli-notes.md`. Adjust the runner's argument list to what actually works.
- [ ] **Step 2:** Write unit tests in `runner.rs`: parsing `hello.jsonl` yields at least one `Text` and ends with `Done`; a malformed line yields `Error` and does not panic; a spawn failure with `NotFound` yields `Error("Claude Code is not installed yet; waiting for first-boot download")`; a non-zero exit yields `Error` containing the exit code.
- [ ] **Step 3:** Write `tests/dbus.rs`: using zbus peer-to-peer over a socket pair with `FakeRunner`, `NewSession` returns a non-empty id; `SendMessage(id, "hello")` emits `MessageChunk` containing "hello" then `SessionDone`; `GetBackend` returns the default Max backend when no config exists; after `SendMessage`, `AuditTail(10)` has a record whose `kind` is `"message"`; sending to an unknown session id emits `SessionError`.
- [ ] **Step 4:** Run `cargo test -p nisse-daemon`. Expected: FAIL.
- [ ] **Step 5:** Implement. Per message: write an audit record, build env from `claude_env(main_backend)`, spawn the runner on a tokio task, forward events as signals. `ClaudeCliRunner` passes `--settings` pointing at `claude-settings.json`, which registers `nisse-audit-hook` as a post-tool hook.
- [ ] **Step 6:** Run `cargo test --workspace` and `cargo clippy --workspace -- -D warnings`. Expected: PASS, clean.
- [ ] **Step 7:** Write the spec and a user unit `nisse-daemon.service` (`Type=dbus`, `BusName=org.nisse.Daemon1`) with a D-Bus service file so it activates on demand. Commit `services: nisse-daemon`.

### Task 8: Panel app

**Files:**
- Create: `panel/CMakeLists.txt`, `panel/src/{main.cpp,DaemonClient.h,DaemonClient.cpp}`, `panel/qml/{Main.qml,ChatView.qml,AuditView.qml,StatusBar.qml}`, `panel/tests/tst_chat.qml`, `tests/e2e/panel_daemon.sh`, `packaging/rpm/nisse-panel/{nisse-panel.spec,nisse-panel.desktop}`

**Interfaces:**
- Consumes: the Task 7 D-Bus API.
- Produces `DaemonClient : QObject` (thin C++ glue over QtDBus, the only C++ in the panel): `Q_INVOKABLE QString newSession()`, `Q_INVOKABLE void send(const QString &session, const QString &text)`, `Q_INVOKABLE QStringList auditTail(int n)`; property `QString backendLabel` (e.g. "max" or "ollama @ host"); signals `chunk(QString session, QString text)`, `done(QString session)`, `failed(QString session, QString message)`.

- [ ] **Step 1:** Write `panel/tests/tst_chat.qml` (QtQuickTest) with a stub `DaemonClient`: sending "hi" appends a user bubble "hi"; a `chunk` signal appends/extends an assistant bubble; `failed` shows an error bubble containing the message; the input is disabled between send and `done`.
- [ ] **Step 2:** Write `tests/e2e/panel_daemon.sh`: under `dbus-run-session` with `NISSE_FAKE_RUNNER=1` and `QT_QPA_PLATFORM=offscreen`, start the daemon, call `qdbus6 org.nisse.Daemon1 /org/nisse/Daemon1 org.nisse.Daemon1.NewSession`, send "ping", and assert the audit tail contains a `message` record; then launch `nisse-panel --self-test` which creates a session, sends "ping", waits for `done`, and exits 0.
- [ ] **Step 3:** Run both. Expected: FAIL.
- [ ] **Step 4:** Implement `DaemonClient` and the four QML files: `Main.qml` is a single window with a chat tab, an audit view reachable from a button, and a `StatusBar` showing `backendLabel`. No multiple tabs yet.
- [ ] **Step 5:** Run `ctest` in `panel/build` and `tests/e2e/panel_daemon.sh`. Expected: PASS.
- [ ] **Step 6:** Write the spec and desktop file (app menu entry, icon `distributor-logo-nisse`). Commit `panel: bare-bones chat and audit view`.

### Task 9: First-boot Claude Code fetch

**Files:**
- Create: `packaging/rpm/nisse-firstboot/{nisse-firstboot.spec,nisse-fetch-claude,nisse-fetch-claude.service}`, `tests/shell/test_fetch_claude.sh`

**Interfaces:**
- Produces: `nisse-fetch-claude` (shell). Reads `NISSE_CLAUDE_INSTALLER` (command to run; defaults to the official installer command recorded in `docs/claude-cli-notes.md`), writes one word to `${XDG_STATE_HOME:-~/.local/state}/nisse/claude-fetch.status`: `installed`, `waiting-for-network`, or `failed`. Exit 0 when installed, 75 when waiting.
- User unit `nisse-fetch-claude.service`: runs at login, `ConditionPathExists=!%h/.local/bin/claude`, `Restart=on-failure`, `RestartForceExitStatus=75`, `RestartSec=120`, `StartLimitIntervalSec=0`.

- [ ] **Step 1:** Write `tests/shell/test_fetch_claude.sh` with a fake installer script: claude already on PATH -> exits 0 without calling the installer, status `installed`; installer succeeds -> exit 0, `installed`; connectivity probe fails (set `NISSE_PROBE_URL` to an unreachable address) -> exit 75, `waiting-for-network`, installer never called; installer exits non-zero with the network up -> exit 1, `failed`.
- [ ] **Step 2:** Run it. Expected: FAIL.
- [ ] **Step 3:** Implement the script (probe `https://claude.ai` with `curl -fsI --max-time 10`, overridable) and the unit.
- [ ] **Step 4:** Run the test. Expected: PASS.
- [ ] **Step 5:** Write the spec, with a user preset enabling the unit for all users. Commit `firstboot: fetch Claude Code at first login`.

### Task 10: Integration, ISO and VM acceptance

**Files:**
- Modify: `build/kickstart/nisse-live.ks`, `tools/vm/smoke-boot.sh`
- Create: `tests/e2e/test_hw_in_vm.sh`, `docs/milestone-1-acceptance.md`

**Interfaces:**
- Consumes: every RPM from Tasks 1, 2, 5, 7, 8, 9; `smoke-boot.sh` SMBIOS flags (Task 3).

- [ ] **Step 1:** Extend the kickstart package list with `nisse-hw nisse-firstboot nisse-daemon nisse-panel`; add them to the ISO contents test (`nisse-hwroute` and `nisse-daemon` binaries present, `claude` still absent). Run the contents test. Expected: FAIL until the build includes them.
- [ ] **Step 2:** Rebuild all RPMs (`tools/rpm/build-rpm.sh` per package, then `make-repo.sh`), rebuild the ISO, run the contents test and `smoke-boot.sh`. Expected: PASS.
- [ ] **Step 3:** Write `tests/e2e/test_hw_in_vm.sh`: boot the ISO three times with spoofed SMBIOS (`Microsoft Corporation`/`Surface Go`, `Apple Inc.`/`MacBookPro15,2`, `Apple Inc.`/`MacBookPro13,1`) plus once unspoofed; in the live session run `nisse-hwroute --dry-run` (via the serial console) and assert the profile and planned kernel package for each (`surface` plans `kernel-surface`, `apple-t2` plans the t2 kernel, `apple-pre-t2` plans no kernel, plain QEMU plans nothing).
- [ ] **Step 4:** Check the installer hook: write a no-op marker script into `/usr/share/anaconda/post-scripts/` in the kickstart, install the ISO once in QEMU, and look for the marker. If it ran, make that script call `nisse-hwroute` inside the installed system (chroot) and leave the first-boot unit as the retry path. If not, ship only the first-boot unit and note this in `docs/milestone-1-acceptance.md`.
- [ ] **Step 5:** Write `docs/milestone-1-acceptance.md`: a manual checklist run once by Bert (install in QEMU with spoofed Surface DMI; confirm `/var/lib/nisse/hw-profile.json`, kernel-surface installed after network, Claude Code downloads at first login, the panel opens and answers via Claude Code on Max, and `fc-match Nunito` finds our font). Commit `integrate: milestone 1 ISO with hardware routing, daemon and panel`.

---

## Self-review notes

- **Spec coverage:** milestone 1 (ISO, panel, kernel selection) is Tasks 3, 8, 4-5; branding Tasks 1-2; first-boot fetch Task 9; audit log and backend config Task 6; two-Apple-path hardware Tasks 4-5; Claude Code never bundled Tasks 3 and 10. Everything else in the spec is listed as out of scope above.
- **Types:** `Profile`, `Plan`, `DmiInfo`, `AuditRecord`, `Backend`, `RunEvent`, the D-Bus method names and `DaemonClient` slots are defined once and reused unchanged.
- **Unverified facts the executor must check on the host:** Fedora's current stable number; the linux-surface, t2linux and Broadcom/FaceTime package sources; the T2 model list; Claude CLI flags and settings path; whether `/usr/share/anaconda/post-scripts/` runs in live installs. Each has a step that records the answer.
