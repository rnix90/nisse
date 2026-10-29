# Nisse OS - design

Date: 2026-10-28. Status: draft for review. Owner: Bert (Robert Nix).

"Decided" means Bert chose it. "Call" means Claude chose it and Bert has not seen it yet.

## 1. Intent and why

Nisse is Bert's own daily-driver desktop operating system. It is a Fedora remix with KDE Plasma
where an AI agent (Claude Code) is wired through the whole system, so that setting up,
maintaining, fixing and operating the computer is mostly a conversation instead of chores.

The name comes from the nisse, the household spirit that quietly looks after the farm. The
product idea follows: the system should look after itself and its owner, mostly out of sight.

Why build it instead of installing Fedora KDE and tweaking it, in Bert's words, all of these:
- hardware just works (one image, installer picks the right kernel for Surface and Intel MacBook)
- his dev toolchain is preinstalled
- quiet self-maintenance
- opinionated defaults and our branding
- and the headline: "completely comprehensive frictionless Claude Code CLI control and
  integration through the entire OS. KDE is the harness, but this is an OS interacted with by AI
  that can be pointed at my Max account or at local LLM capabilities."

It is for Bert's own use first. It will be developed in a git repo that may become public, so it
must stay generic: nothing personal in the image or the repo.

## 2. Goals

1. One x86_64 install image that runs on four machines: RN-DESKTOP (big GPU), RN-LAPTOP, a
   Surface Go (touch), and an Intel MacBook.
2. Installer detects Surface and Intel MacBook hardware and installs the matching patched kernel
   (linux-surface; t2linux for T2-era MacBooks).
3. An AI layer through which the agent can control everything on the machine: packages and
   services, KDE settings and windows, hardware and network, files, dev environments and devices
   (including serial and flashing for ESP32 boards).
4. A desktop front end for that AI: a standalone app plus a small Plasma widget.
5. Per-category routing of AI work to different backends (Max account, local Ollama, remote
   Ollama over LAN or WARP).
6. A rollback net strong enough that the AI can act autonomously, including as root.
7. Safe automatic updates, and a way for the AI to set up its own quiet background jobs.
8. A first-boot ingestion step where Bert supplies a natural-language description of his network
   and extra software, and the AI does that setup.
9. Our branding (logo package, Nunito font) applied throughout.

## 3. Non-goals

- Not a general-purpose distro for other people at this stage (it may be shareable later).
- Not building from scratch (no Linux From Scratch style work).
- Not image-based or atomic (no bootc, ostree, Silverblue style). Classic RPM with kickstart.
- No other desktops or spins in v1 (KDE Plasma only).
- Not in v1: health watch, backups of home, daily report. (The AI can add such jobs itself later
  using the background-job facility.)
- Not bundling Claude Code in the ISO.
- No personal data, credentials or homelab details in the image or repo.

## 4. Anti-goals (what would make it a failure even if it technically works)

- The AI breaks a system and recovery fails (unbootable machine or lost data).
- The AI is slow, noisy or in the way.

Bert did not pick "constant babysitting" or "Surface/MacBook feel second-class" as failure
conditions, but both machines remain in scope.

## 5. Constraints

- Base: Fedora, latest stable release, upgraded to each new release as it ships (about every
  six months). Fedora KDE is the starting point.
- Image built with kickstart and the Anaconda installer (classic RPM remix).
  AMENDED 2026-10-29: the image is now built with kiwi, see `2026-10-29-kiwi-build-design.md`. Anaconda stays.
- Claude Code is proprietary. Decided: it is fetched from Anthropic's own installer at first boot
  and kept updated there. It is never shipped inside the ISO. (Claude's note: current Anthropic
  terms should be re-checked before this is relied on.)
- Build host: WSL2 or a VM on RN-DESKTOP, run on demand (not unattended, no nightly CI yet).
- License: GPL-2.0-or-later for original code. The bundled Nunito font is SIL OFL 1.1.
- Written style: plain ASCII in everything authored.
- Existing assets: repo at T:\Claude Code Creations\Nisse, branches `main` (stable) and `daily`,
  logo package and font in `assets/`, logo build script in `tools/logo/`.

## 6. Decisions

### 6.1 Platform and hardware
- One x86_64 image for all machines.
- Installer detects the hardware and routes kernel patches (Surface: linux-surface; Intel
  MacBook: t2linux where needed).
- Bert has several Intel MacBooks, possibly of both kinds, so v1 ships both Apple paths:
  T2-era (about 2018-2020): t2linux kernel and Secure Boot off; pre-T2 (2017 and older): stock
  Fedora kernel plus Broadcom Wi-Fi and FaceTime camera driver packages. The installer detects
  which kind it is.
- Per machine, the installer proposes a default for disk encryption and boot security
  (LUKS, TPM unlock, Secure Boot handling) and Bert confirms. Reason: T2 MacBooks usually need
  Secure Boot off, Surfaces can enroll a key.

### 6.2 Storage
- btrfs. Snapshots cover the system only. Home and large data (model stores, projects) live in
  excluded subvolumes.
- Consequence: AI mistakes inside home or data are not undone by snapshots, which is why the
  deletion guardrail in 6.4 exists.

### 6.3 AI backends and routing
- A config panel sets a main backend and separate routes per category (for example computer
  vision). Each route points at: Max account, local Ollama, or a remote Ollama reachable over
  LAN or WARP (for example the Surface using RN-DESKTOP's Ollama).
- From Bert's notes, the only viable local model so far is gpt-oss:20b, which needs a GPU, so
  the Surface Go and the MacBook will mostly use remote Ollama or Max.

### 6.4 AI authority and guardrails
- Mode: autonomous, including root, with a rollback net (snapshots, an audit log, guardrails).
- Root access: decided "root shell now, tools over time". In v1 the AI gets sudo and a shell so
  milestone 1 can move. Over time each area (packages, services, KDE, hardware, devices) gets a
  mediated tool/helper, and direct root use is narrowed as those land. Until then the two
  guardrails below are advisory (the AI is instructed to follow them and the audit log records
  its actions), not mechanically enforced. They become system-enforced as mediated tools replace
  the shell, area by area.
- Guardrails, even in autonomous mode:
  1. Deleting or overwriting user data outside snapshots needs confirmation.
  2. Sending data or spending money off the machine needs approval. Local actions and the AI's
     own model calls do not. Decided definition: it is about outbound ACTIONS, not network
     traffic. Posting, emailing, git push, uploading files, purchases, and API calls that change
     something remote need approval. Reading and downloading (packages, web pages, models) do
     not. There is no firewall or egress allowlist in v1.
- Bert chose NOT to guard: changes to boot, disk layout and encryption keys; reading or moving
  secrets. (Claude's note: this leaves an autonomous root agent able to touch credentials and the
  bootloader. Snapshots can undo boot changes but not leaked secrets. Revisit if needed.)

### 6.5 Interface
- Panel form: both a standalone QML/Qt app (taskbar entry, tabs, badges) and a small Plasma
  widget (badges, status), sharing one backend service.
- Panel contents in v1: chat and task history; an undo/rollback button; an approvals queue (where
  guardrail requests land); backend and usage status including a kill switch that pauses the AI.
- Tabs: a tabbing system for multiple sessions/agents running at once.
- Per session: a checkbox for Claude's remote-control setting, and a choice of whether that
  session reloads automatically after reboot.
- Noise: verbose inside the selected chat tab. Other tabs signal through a taskbar badge:
  red for "needs you", green for unread completion, each with a count in the middle, drawn in
  Nunito.

### 6.6 OS control
- Scope in v1 is everything: packages and services, KDE settings and windows, hardware and
  network, files and dev environments and devices. Bert: "the goal is seamless control of
  everything."
- GUI control: structured first (D-Bus, KDE config interfaces, accessibility tree, keyboard
  shortcuts), vision (screenshot and click) only as a fallback.

### 6.7 Self-maintenance
- v1: updates with a safe-apply routine (snapshot, update packages and hardware kernel, verify
  the machine boots and key services work, roll back automatically on failure).
- Plus a facility so the AI can stand up its own quiet scheduled or background jobs.

### 6.8 Personal setup
- The image contains nothing personal. A first-boot ingestion layer takes a natural-language
  "config prompt" from Bert (network architecture, extra software, homelab wiring) and the AI
  carries it out.

### 6.9 Code and tooling
- Split by layer: shell and Python for installer and kickstart glue; Rust for long-running
  services and MCP servers; QML for the panel UI.

### 6.10 Distribution and updates
- Nisse's own RPMs are served from a GitHub-hosted repo (Pages or Releases). `main` feeds the
  stable channel and `daily` feeds the daily channel.

### 6.11 Verification and rollout
- A VM fault-injection suite that deliberately breaks things (bad kernel, broken config, deleted
  packages) and checks recovery, plus checks of the guardrails and the hardware routing.
- Then staged rollout to real machines: Surface Go first, then laptop, then main desktop.

### 6.12 Milestone 1
- A thin slice of all three parts: a bootable branded ISO, a bare-bones panel, and
  hardware-based kernel selection. Less polished, but it exercises the whole path end to end.

## 7. Calls made by Claude (for Bert to check)

- Snapshot tool: snapper (via btrfs) for system snapshots before every AI action batch.
- Hardware detection: DMI vendor and product strings and PCI/USB IDs, evaluated in an Anaconda
  addon or `%pre` script, choosing a kernel flavor from our repo.
- One audit log (append-only) that the panel reads; every AI system action writes to it.
- Guardrail enforcement: polkit rules plus a privileged helper that wraps the dangerous
  operations, so the guardrails are not just prompts. (Mechanism is a builder detail.)
- The backend service is a single Rust daemon the app and widget both talk to; MCP servers are
  separate Rust binaries it supervises.
- "Remote control" in the panel means Claude Code's remote-control feature for a session.
- Kill switch pauses all AI activity and revokes in-flight root actions; it does not roll back.
- Daily vs stable: both are package channels in our GitHub-hosted RPM repo. A small
  `nisse-release` package holds which channel a machine follows (default stable), so one machine
  can follow daily while another follows stable. Builds are run by hand on RN-DESKTOP and
  published when ready; there is no nightly CI yet. Packages and repo metadata are signed with a
  Nisse GPG key held on the build host.
- Secure Boot and signing: where Secure Boot is on, the stock Fedora kernel uses Fedora's own
  chain. Our patched kernels (linux-surface) are signed with a Nisse Machine Owner Key that the
  installer enrolls on that machine. The key lives on the RN-DESKTOP build host. T2 MacBooks run
  with Secure Boot off.
- Milestone 1 panel: chat in a single tab talking to the Rust daemon, plus a read-only view of
  the audit log and the current backend. Approvals queue, rollback button, multiple tabs and the
  Plasma widget come after milestone 1.
- Safe-apply rollback trigger: a systemd health-check unit runs after the update's reboot
  (boot reached, network up, key services active, display session reached). If checks fail
  within a time limit, a watchdog performs a snapper rollback and reboots. GRUB boot counting is
  the backstop when the machine does not reach the unit at all.
- First boot with no network: not a failure. The desktop works normally, the panel shows that
  the AI layer is waiting for a connection, and the fetch retries until it succeeds. Wi-Fi
  firmware needed by the Surface and MacBooks is included in the image so this is rare.
- Claude Code's remote-control feature on headless or daemon-managed sessions is unverified. The
  per-session checkbox is built on the assumption it works; if it does not, drop or redesign the
  checkbox.

## 8. Left to the builder

- Package names, repo layout, service names and D-Bus API shapes.
- How the kickstart is structured and how the hardware-detection hook is implemented.
- Exact snapshot policy (frequency, retention) and the safe-apply health checks.
- The panel's visual design, within the noise and badge rules above.
- The VM test harness technology.

## 9. Known risks

- Autonomous root plus unguarded secrets and boot (6.4). In v1 the guardrails are advisory
  because the AI has a root shell; they become enforced only as mediated tools replace it.
- Claude Code redistribution and first-boot network dependency (5).
- Each Fedora release upgrade is a porting job for kernel patches and Plasma integrations.
- Wayland screen capture and input go through KDE portals that can show permission prompts,
  which limits the vision fallback.
