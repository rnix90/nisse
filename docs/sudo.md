# sudo policy (N-306a)

nisse is meant to work without stopping for a password, and the design gives the AI a root shell in v1 (design 6.4). The
`nisse-sudo` package sets that up with two modes.

| Mode | Policy | The AI's `sudo` | A terminal's `sudo` |
|---|---|---|---|
| **full** (default) | everyone in `wheel` runs any command as any user, no password (`/etc/sudoers.d/50-nisse-sudo`) | just works | just works |
| **limited** | only `/usr/libexec/nisse/nisse-snapshot-batch` is passwordless; one answer is remembered for a few minutes for callers with no terminal | opens a KDE password popup (through the sudo shim) | asks on the terminal as usual |

Switch with `sudo nisse-sudo-mode limited` or `full` (`nisse-sudo-mode status` shows the mode). The new policy is checked with
`visudo -cf` before it replaces the old file, so a mistake cannot lock everyone out of sudo. The mode is also an
**install choice** (`docs/install-choices.md`, N-306c): the first-boot wizard (N-306d, N-306e) will ask, an answers file or a
installer script can set it (`nisse-choices set sudo-mode limited`), and `nisse-choices apply` applies it at first boot. Until
the wizard page exists every install is full.

**What full mode means, plainly.** Any process running as the installed user (the AI, but also a browser exploit or a malicious
script the person runs) gets root with no prompt. That is the design's choice (autonomous root with a rollback net), not an
accident; limited mode is for people who want a prompt.

## How limited mode asks for a password

Verified in the build VM (`tools/spike/sudo_modes_spike.sh`, Fedora 44, sudo 1.9.17):

- A drop-in later in `/etc/sudoers.d` overrides Fedora's `%wheel ALL=(ALL) ALL`, so the full and limited rules both work.
- With no terminal, sudo does **not** use `SUDO_ASKPASS` alone, nor `Path askpass` in `/etc/sudo.conf` alone: it needs `-A`.
- An AI session's `sudo` is plain `sudo`, so the daemon puts `/usr/libexec/nisse/shims` first on the `PATH` of every session it starts
  (`nisse_daemon::sudo::session_env`), and that `sudo` shim adds `-A` and `SUDO_ASKPASS=/usr/libexec/nisse/nisse-askpass` when the mode
  is limited and there is no terminal. In full mode, or with a terminal, the shim is exactly `sudo`.
- `nisse-askpass` shows a `kdialog --password` box and gives up after five minutes, so a turn is never stuck for ever on a popup
  nobody sees. A cancelled box or a wrong password fails (a wrong one is retried three times by sudo).
- `Defaults:%wheel timestamp_type=global` makes the answer count for every caller with no terminal, so a session that needs five
  commands is asked once. The cost: for those few minutes any process of that user has root without asking.
- `sudo -n` never opens a popup (`-n` wins), which is why the snapshot helper, called with `sudo -n`, is the one thing that stays
  passwordless in limited mode.

## Tests

| Test | Where | What it proves |
|---|---|---|
| `tests/shell/test_sudo_scripts.sh` | anywhere | the mode switch (including that a template visudo rejects changes nothing), the shim in each mode, the popup helper with a stub `kdialog`, the templates |
| `tests/rpm/test_nisse_sudo.sh` | build VM | contents, modes (0440 for the drop-in), config flags, requirements, `visudo` accepts the policies, rpmlint |
| `tests/e2e/test_sudo_modes.sh` | build VM (sudo) | the REAL sudo for a wheel user with no terminal: full has no password; limited needs one, keeps the snapshot helper free, asks the popup once and remembers it, fails on a wrong answer and a cancel, never pops up for `-n`; the whole sudoers stays valid in every mode |
| `services/crates/nisse-daemon/tests/sudo_env.rs` | build VM (cargo) | a turn's environment gets the shim directory first on `PATH` only when the shim is installed |
| `tests/iso/test_iso_contents.sh` | ISO rebuild | the image is in full mode with a 0440 drop-in, the shim, the helper and `kdialog` are there, first-run users join `wheel` |

## Not covered or not yet verified

- The popup on a real Plasma desktop: that `kdialog --password` returns the typed text, and that the daemon's session environment has
  the display variables, is only checked with a stub. A hand check on an installed VM is queued with GATE 3.
- That the installer's own first user is in `wheel`: the install harness's answer file says so, and Fedora's first-run setup is
  configured for it (`UserGroups=wheel`), but the graphical installer's "administrator" box is a hand check at GATE 3.
- polkit prompts (the KDE settings and Discover password dialogs) are untouched; they have their own policy.
- Terminal `claude` runs and the remote-access server do not get the shim (N-306b).
