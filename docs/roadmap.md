# Nisse roadmap

Status: draft, 2026-11-02. Written from the approved design (`docs/superpowers/specs/2026-10-28-nisse-os-design.md`), the
kiwi amendment, the review decisions recorded in memory, and Bert's answers of 2026-11-02. Items marked (guess) are my
proposal, not something Bert said. Items marked (decision) wait for Bert and are asked one at a time.

**The task queue now lives in `docs/planning/TASK-LEDGER.md` (2026-11-12).** This file keeps the why and the shape; the
ledger holds the ordered, checkable tasks, and its rule 13 maps these phases to its stages. Do not work from the tables
below without checking the ledger.

## Where we are

Milestone 1 (thin slice) and the kiwi build switch are done and on `daily`: a branded ISO built with kiwi boots to
Plasma ("Welcome to Nisse!"), hardware routing works for Surface, T2, pre-T2 and generic machines in spoofed VMs, and a
Rust daemon plus QML panel talk to the Claude CLI with an audit log. Everything is tested in VMs; nothing has run on real
hardware.

## Milestone 2 target (Bert, 2026-11-02)

A **complete AI layer** and the **full Nisse look and feel**, both proven in a VM. Real-hardware installs come after.
Design direction: a distinct Nisse identity, not stock KDE. Palette (decided 2026-11-02): **Ember**, a dark Ink desktop
with Paper text and a warm red-orange accent (the nisse's red cap; exact hex to be tuned for contrast). Dark shell, but
document-like apps (email, word processing, PDF, web pages) keep a light background; see 1.14.

## Ground rules for every item

- One plan per workstream, written before code; TDD; every ISO claim is checked by a test (contents, boot, screenshot).
- Customizations ship as RPMs in the Nisse repo, never as hand-edits to the image, so an installed system gets them too.
- ASCII only in everything authored. No credentials or personal data in the repo or image.
- Questions to Bert are asked one at a time.

## Phase 0: foundations (small, unblocks everything)

| Id | Item | Notes |
|---|---|---|
| 0.1 | Fix pass for the daemon and panel | CLI timeout (~10 min) with a Stop button and daemon Cancel; persist daemon sessions; per-session message queue; skip the Claude fetch on live boots; hwroute one-line error, bounded retry and a failed status |
| 0.2 | os-release and ownership | `DEFAULT_HOSTNAME=nisse`; HOME_URL, BUG_REPORT_URL, SUPPORT_URL pointing at the GitHub repo; nisse-release owns `/usr/share/nisse` |
| 0.3 | Adopt Fedora's full preset set | Decided: generally adopt (tuned, thermald, systemd-oomd, flatpak-add-fedora-repos, audit-rules, ...); true preference/tradeoff items come to Bert as questions; test the image still boots |
| 0.4 | Deferred minors from the kiwi review | file modes, `ls \| head` under pipefail, sed escaping, test greps, check-host key package |
| 0.5 | Authority switch | Config switch for the AI's authority, default autonomous (decided); wired into the daemon and shown in the panel |

**Phase 0 status: DONE 2026-11-02** (plan `docs/superpowers/plans/2026-11-02-phase-0-foundations.md`, 11 tasks). Proven on a
rebuilt ISO: contents test (63 preset-enabled units verified after a simulated first-boot preset-all), live desktop
screenshot, 4-case hardware e2e, and the whole test suite. Final review fixes (same day): the 10-minute whole-turn timeout became a check-in watchdog (30 s check-ins; no sign of life for 10 minutes
flags the CLI as hung, stops it and everything it started, restarts the turn once); sshd is off by default. Notes: supervised authority maps to the CLI's default permission
mode and its behaviour in `-p` mode is not yet verified against the real CLI (see `docs/claude-cli-notes.md`); the Fedora
preset set is adopted except `plasma-setup.service`; Flatpak remotes are Fedora's plus Flathub.

## Phase 1: the Nisse look and feel (all packaged; tested by VM screenshots)

| Id | Item | Notes |
|---|---|---|
| 1.1 | Palette and style direction | Decided: Ember (dark Ink base, Paper text, red-orange accent). Light variant for the whole desktop is optional and later |
| 1.2 | Plasma color scheme, theme, window decorations | Based on the chosen palette; light and dark variants if wanted |
| 1.3 | Icon theme, cursor theme | (guess) start from a base set and override the Nisse icons; custom cursor only if it adds value |
| 1.4 | Wallpapers and lock/login backgrounds | Nisse artwork from the logo assets; at least one wallpaper per variant |
| 1.5 | Fonts | Nunito as UI font (already shipped); choose a monospace and a document font (decision) |
| 1.6 | Panel, launcher and default layout | (guess) one panel layout shipped via the Plasma look-and-feel package and `/etc/skel`; Nisse panel entry pinned |
| 1.7 | Shortcuts and window behaviour | Defaults for shortcuts, animations, night light, window rules |
| 1.8 | Login screen (Plasma Login Manager) | Branded theme and logo |
| 1.9 | Boot experience | Plymouth splash and GRUB theme with the nisse mark |
| 1.10 | Terminal and editor defaults | Konsole profile in the Nisse palette; the terminal-under-cap logo is reserved for a terminal app (later) |
| 1.11 | Default apps and de-bloat | Decide what ships and what does not (decision) |
| 1.12 | First-boot welcome and installer branding | Replace plasma-welcome-fedora content; Anaconda branding; sound and notification theme (guess) |
| 1.14 | Light surfaces for document apps | Decided: dark shell, light document apps, set per app (not a light-content-everywhere scheme). Cover the mail client, word processor, PDF viewer and browser; check each with a screenshot of a real document; terminals and code editors stay dark |
| 1.13 | Look-and-feel regression test | Screenshot checks of the live desktop, login, splash and panel in the VM |
| 1.15 | SSH as an install-time option | Decided (Bert, 2026-11-02): sshd is an OPTION AT INSTALL, off by default until then. Anaconda has no checkbox for it, so it needs our own installer step or the first-boot welcome flow (1.12); the image ships `disable sshd.service` today |
| 1.0 | Branding foundations (DONE 2026-11-05) | Replace Fedora's placeholder art (generic-logos, the hot dog on the start button, About page and installer) with Nisse's; Nisse's own product version starting at 0.2, no alpha label, no tracking of Fedora's number (VERSION_ID stays the Fedora base). Plan `docs/superpowers/plans/2026-11-02-branding-foundations.md` |
| 1.16 | Own artwork for KDE and Fedora surfaces, with a local review page | Decided (Bert, 2026-11-02): create Nisse's own graphics for the identity and the desktop theme (scope: identity + theme layer, about 150-400 items). First a locally hosted review page showing every graphic with a comment box, exporting one big submission brief of what to draw. DONE 2026-11-05: review page built (`docs/brand-art.md`), first submission received (`docs/brand-art-submission-2026-11-05.md`); drawing the art is Phase 1. |

## Phase 2: the AI layer, core

| Id | Item | Notes |
|---|---|---|
| 2.1 | Approvals queue | Pending actions, approve/deny, hard guardrails (data deletion outside snapshots; sending data or spending money off the machine) |
| 2.2 | Tabs for concurrent sessions | Per-session state, badges (red = needs you, green = unread completion, count in Nunito) |
| 2.3 | Backend routing | Config panel for Max account vs local LLM (Ollama), per session; usage status; kill switch |
| 2.4 | Rollback and safe-apply | btrfs snapshots with snapper: snapshot, update, verify boot and services, auto-rollback; undo button in the panel |
| 2.5 | Remote-control checkbox | Per-session choice of Claude remote control |
| 2.6 | Audit view | Searchable history of messages and tool use |

## Phase 3: the AI layer, system control

| Id | Item | Notes |
|---|---|---|
| 3.1 | Mediated root tools | Root becomes a set of audited helpers (polkit) over time; shell root stays until each tool exists |
| 3.2 | OS-control tools | Packages and services, KDE settings and windows, hardware and network, files and dev environments, ESP32 serial and flashing; structured control first (D-Bus, AT-SPI, shortcuts), vision as fallback |
| 3.3 | Plasma widget | Small widget sharing the daemon with the panel: badges and status |
| 3.4 | Self-maintenance jobs | Framework for the AI to stand up its own quiet jobs; updates with safe-apply first |
| 3.5 | Config-prompt ingestion | First-boot layer: the user supplies a natural-language setup prompt (network, software, homelab wiring) and the AI performs it; credentials never in the prompt |

## Phase 4: proving it in VMs

| Id | Item | Notes |
|---|---|---|
| 4.1 | VM fault-injection suite | Failed update, rollback, hung CLI, no network, wrong hardware; asserts the system recovers |
| 4.2 | Install-to-disk test in a VM | Anaconda install, first boot, hwroute post-script, panel, snapshots |
| 4.3 | Milestone 2 acceptance checklist | Scripted proof plus a short manual checklist for Bert |

## Later (not in Milestone 2)

- Real-hardware installs: Surface Go first (Secure Boot off for now), then MacBooks (T2 and pre-T2).
- facetimehd RPM for pre-T2 MacBooks (low priority, no testing).
- Signing, MOK enrollment, and the GitHub update channels (main stable, daily daily) with gpgcheck on the Nisse repos.
- RPMs built in a mock against the ISO's Qt (removes the VM Qt pin); move the ISO to the updates repository.
- A terminal app using the terminal-under-cap logo; further hardware profiles.
- First public ISO (no "alpha" label, per the 2026-11-02 naming decision).

## Suggested order

0.1 to 0.5 first (also gives the panel the missing basics), then 1.1 (needs Bert's eyes) in parallel with 2.1 to 2.3,
then the rest of Phase 1, 2.4 to 2.6, Phase 3, and Phase 4 to close. Phases 1 and 2 are independent and can alternate.

## Decisions waiting on Bert

1. ~~Palette direction (1.1)~~: decided, Ember.
2. Monospace and document fonts (1.5).
3. Default apps to keep or drop (1.11); it decides which apps 1.14 must cover.
4. Any preset item that is a real tradeoff (0.3), asked when met.
