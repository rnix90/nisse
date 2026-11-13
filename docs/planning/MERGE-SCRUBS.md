# Merge scrubs

Every merge to `main` is preceded by a scrub (CLAUDE.md rule 4). Newest first. Findings are fixed in place when small
and become ledger tasks when larger. Record, then merge.

## 2026-11-12: daily (15 commits ahead) into main, ledger task N-002

Scope: the docs, the ledger, the brand art tooling and the host-side tests. Not re-run here: the ISO build and boot
tests (last run 2026-11-04 on the rebuilt ISO, sha 5cbcdf60; nothing on the ISO has changed since, only docs and
`tools/brandart`). Scrub done by the agent alone; no review subagent.

Checks run: `tests/build/test_cargo_lock.sh`, `tests/repo/test_tracked_files.sh`, `tests/build/test_system_art.sh`,
`hw` pytest (55), `tools/brandart` and `tools/ledger` pytest (71), ledger structure check, ASCII audit.

Findings and corrections made in place:

- **Real bug, fixed (test first):** `tools/brandart/serve.py` answered an oversized request body with a 413 and hung up
  without reading it, so about 4 requests in 100 on Windows reached the client as a connection reset instead of a 413
  (measured: 6 of 150; a browser would show a network error). The server now reads and discards the body, up to
  32 MB, before answering. Regression test `test_an_oversized_body_gets_its_413_every_time` (failed before the fix
  with WinError 10053); the same measurement is now 0 of 150. Found because the full suite failed once where the
  single test passed three times.
- **Stale:** `README.md` still said "Day zero. No build system, base, or package set chosen yet." Rewritten.
- **Supersession:** `docs/milestone-1-decisions.md` still listed the fuller Fedora preset and the Claude hook JSON as
  open. Both were resolved earlier (2026-11-02 and 2026-10-29). Marked RESOLVED; the hook verification, which lived only
  in the agent's memory, is now recorded in `docs/claude-cli-notes.md`.
- **Roadmap:** item 1.0 (branding foundations) was not marked done; "Public alpha ISO" contradicted the 2026-11-02
  decision that there is no alpha label. Fixed (now "First public ISO").
- **Unowned work:** none new. The open items the old docs carried (supervised `-p` behaviour, remote control on
  daemon sessions, the managed-settings path, Bert's manual Milestone 1 checklist) are now owned by N-201, N-202 and
  N-003.
- **Known and accepted:** `test_system_art` and `test_tracked_files` fail inside the build VM (no Pillow, not a git
  checkout) and pass on the host; they are host-side tests.
