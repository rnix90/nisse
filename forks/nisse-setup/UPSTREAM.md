# Where nisse-setup comes from

nisse-setup is a fork of KDE's **Plasma Setup**, the first-boot wizard (Bert, 2026-11-18: nisse has its own wizard that
replaces it, built as a fork so the proven user, locale, keyboard, time, hostname and Wi-Fi logic keeps working).

| | |
|---|---|
| Upstream project | Plasma Setup, https://invent.kde.org/plasma/plasma-setup (invent.kde.org/plasma/plasma-setup) |
| Imported version | 6.8.3, git tag `v6.8.3`, commit `052bd7390bbb8b71a1412e6eea80b5a7d98d37bc` |
| Tarball | `plasma-setup-6.8.3.tar.xz` from https://download.kde.org/stable/plasma/6.8.3/ |
| Tarball sha256 | `12c3562051fe099521b47f408633c649c8d96cc726f1629a81129ec12f895657` |
| Tarball signature | `plasma-setup-6.8.3.tar.xz.sig` was fetched with the Fedora source RPM; it was NOT verified here (no KDE release key checked) |
| Fedora source | `plasma-setup-6.8.3-1.fc44.src.rpm` (the tarball plus two small Fedora branding patches, see below) |
| Licences | a mix of GPL-2.0-or-later, GPL-3.0-or-later, LGPL-2.0/2.1/3.0, BSD-2-Clause, CC0-1.0 (`LICENSES/`); every upstream file keeps its own SPDX header |

## How the fork is kept

- The first commit that added `forks/nisse-setup` is the **pristine import** of that tarball: `git log -- forks/nisse-setup`
  shows it first, and every later commit is a nisse change. So our patch series is always "the commits after the import".
- Every changed file is listed with its reason in `NISSE-PATCHES.md`; `tests/repo/test_nisse_setup_fork.sh` fails if a file
  changed since the import is not listed, or the import commit is not the 169 files of the tarball.
- Decision (Bert, 2026-11-18): only **system-visible names** are renamed (package, command, service, special user, polkit
  rule, flag file, helper). KDE's internal QML module and C++ names stay, so merging a newer upstream stays easy. The full
  rename waits for the whole-Plasma fork he expects after v1 (memory `nisse-fork-upstream-ok`).

## Taking a newer upstream (for example 6.8.4 or a newer branch)

1. Get the new tarball, record its tag, commit and sha256 above.
2. `git format-patch <import-commit>..HEAD -- forks/nisse-setup` saves our series.
3. Replace the tree by the new tarball in one commit (the new pristine import; update the test's file count and hashes).
4. `git am` the series; fix conflicts (the ledger tells what each patch is for); rebuild and run the tests.

## What Fedora patches, and what nisse does instead

Fedora 44 carries two patches on top of upstream: the landing page wallpaper (`wallpapers/Default`) and the light/dark toggle's
look and feel (`org.fedoraproject.*`). nisse does not take them; it patches the same two places for its own look instead
(`wallpapers/nisse`, `org.nisse.desktop` and `org.nisse.desktop.light`), see `NISSE-PATCHES.md`.
