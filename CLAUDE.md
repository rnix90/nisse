# Nisse - project rules

Nisse is a custom Fedora 44 based, AI-native KDE Plasma distro that Bert (Robert Nix) builds with Claude. Branches:
`main` (stable) and `daily` (integration; work here). Public mirror: github.com/rnix90/nisse.

## Working protocol - READ THIS FIRST

`docs/planning/TASK-LEDGER.md` is the source of truth for what to do next. The trigger phrase is **"next nisse task"**
(also "nisse next"). Plain "next task" belongs to the Cozy Crab project. On the trigger: take the first open task in
the ledger, give Bert that one task only (phone-sized, with a concrete proposal), develop it until he approves, then do
the work, commit, tick the box, update the NOW pointer, commit, and reply exactly **"Ready for next nisse task."**
Never batch, never work ahead. The ledger's PROTOCOL, GATES and Ledger rules sections are the full text.

The design is `docs/superpowers/specs/2026-10-28-nisse-os-design.md` (plus the kiwi amendment). The roadmap is the why
and shape; the ledger is the queue. Check the ledger structure with `python tools/ledger/check.py`.

## Standing rules

1. **Questions to Bert are asked one at a time**, through the interactive prompt. Never batched, never in prose.
2. **Plan before code.** A decision gets agreed first; a design task is not started by writing code.
3. **Ask before spending**: several agents, broad web research, paid services.
4. **Every merge to `main` gets a scrub first** (code, docs, ledger: stale claims, contradictions, orphans,
   supersessions, unowned work). Findings go in `docs/planning/MERGE-SCRUBS.md`, newest first. Record, then merge.
5. **No invented facts.** An unverified mechanism is a spike or verify step, not an assumption.
6. **Built, tested, never called is the recurring bug**: grep for a runtime caller, and let the ISO gates catch what unit
   tests miss.
7. **Fix minor review findings too**, unless Bert's decision is needed.
8. **ASCII only** in everything authored (code, docs, commit messages, SVGs, notifications). No codepoint above 127.
9. **Public repo**: no credentials, no network addresses, nothing personal or homelab-specific in the repo or image.
10. **Customizations ship as RPMs** in the Nisse repo, never as hand edits to the image. Every ISO claim is checked by
    a test. TDD: a failing test first.
11. License: GPL-2.0-or-later with an SPDX header on original files. The bundled Nunito font is SIL OFL 1.1.

## Tooling notes

- The ISO is built by kiwi-ng in a Fedora 44 build VM (QEMU) on the Windows host; helpers: `tools/build/vm.sh`,
  `tools/build/build-iso.sh`; see `docs/build-host.md`. A full build is about 33 minutes.
- The Bash tool collapses backslashes: write files containing them with Write or Edit. Never `pkill -f` over ssh.
- Brand art review page: `docs/brand-art.md`. Never delete its out directory by hand (it holds the comments).
