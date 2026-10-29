# Milestone 1 acceptance

Milestone 1 is the thin slice from the design: a bootable branded ISO, a bare-bones panel, and hardware-based
kernel selection. Most of it is checked by scripts. A few things need a person, once.

## What the scripts already prove

| Check | How to run | What it proves |
|---|---|---|
| RPM tests | `tests/rpm/test_*.sh` in the build VM | each package has the files, units, presets and licenses it should |
| Hardware detection and routing | `cd hw && python -m pytest` | Surface, T2, pre-T2 and generic machines get the right profile and commands; offline runs retry |
| Services | `cd services && cargo test --workspace` | audit log, config, runner and D-Bus API |
| Panel | `ctest --test-dir panel/build`, `tests/e2e/panel_daemon.sh` | chat behaviour, and panel plus daemon on a real bus |
| First-boot fetch | `tests/shell/test_fetch_claude.sh` | Claude Code is fetched, never bundled, and retried offline |
| ISO contents | `tests/iso/test_iso_contents.sh out/nisse-live.iso` | os-release says Nisse, Nunito is there, our programs are in, no `claude` file |
| Boot | `tools/vm/smoke-boot.sh ISO --screenshot ...` | the ISO boots to Plasma with "Welcome to Nisse!" |
| Hardware in VMs | `tests/e2e/test_hw_in_vm.sh ISO` | spoofed Surface, T2, pre-T2 and plain QEMU print the expected profile and commands |

## Checklist for Bert (about 30 minutes, needs internet)

1. **Install with a spoofed Surface.** Open a VM that reports Surface hardware and boot the ISO in it:

       tools/vm/run-vm.sh /d/nisse-test.qcow2 --iso /d/nisse-build-vm/out/nisse-live.iso \
           --vendor "Microsoft Corporation" --product "Surface Go" --family Surface

   Run "Install to Hard Drive", finish, shut down, then boot the installed system with the same command
   without `--iso`.
   - [ ] `cat /var/lib/nisse/hw-profile.json` shows `"profile": "surface"` and a status of `done` or `pending`.
   - [ ] `cat /var/log/nisse-hwroute-install.log` exists (it proves the installer ran our post-script; the
         Anaconda hook is confirmed from its source, this is the end-to-end proof).
   - [ ] After network is up, `rpm -q kernel-surface` finds the package and `uname -r` after a reboot contains `surface`.
   If the log file is missing, the first-boot service `nisse-hwroute.service` is the fallback: check
   `systemctl status nisse-hwroute`.
2. **First login.**
   - [ ] `cat ~/.local/state/nisse/claude-fetch.status` goes from `waiting-for-network` (if offline) to `installed`.
   - [ ] `claude --version` works. Run `claude` once to sign in to the Max account.
3. **Panel.**
   - [ ] Open "Nisse" from the application menu. The status bar says `Backend: max`.
   - [ ] Send "hello". A reply appears and the input unlocks again.
   - [ ] Open the audit log view. It lists your message, and tool use if the agent ran any tool.
         (This is the first real test of the audit hook in `/usr/share/nisse/claude-settings.json`.)
   - [ ] With no network, send a message: the panel shows an error, not a hang.
4. **Look and feel.**
   - [ ] `fc-match Nunito` names the Nunito font.
   - [ ] `cat /etc/os-release` shows `NAME="Nisse"`, `ID=nisse`, `LOGO=distributor-logo-nisse`.

## Known gaps (planned for later plans)

- Secure Boot signing and MOK enrollment for the Surface kernel, so Secure Boot must be off for now.
- The FaceTime HD camera driver on pre-T2 MacBooks (no verified package source yet).
- The Nisse repositories are placeholders (disabled) until the GitHub-hosted channels exist.
- Rollback and safe update (snapper), approvals queue, multiple tabs, Plasma widget, mediated root tools.
- Fedora retired its kickstart repository; Nisse vendors the last kickstart (f43) and patches it in
  `build/build-iso.sh`. Fedora's maintained path is now kiwi. See the ledger note in the commit history.
