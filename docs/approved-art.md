# The approved art, and who owns what is still missing (N-415)

Every approved nisse asset is listed in `tests/rpm/approved-art.txt`: its path in the image, the package that ships it and the done task
that made it. Three checks keep the list honest:

| Check | Where it runs | What it proves |
|---|---|---|
| `tests/rpm/test_approved_art.sh` | the build VM, against the built RPMs | every path is in the package that should ship it; the six tray icons are the approved symbolic SVGs |
| `tests/iso/test_iso_contents.sh` (a block that reads the same list) | the build VM, against the built ISO (queued for the next rebuild) | every path, and every folder with its minimum file count, is in the image |
| `tools/brandart/tests/test_art_ownership.py` | the host, in pytest | the list's lines are well formed and name real packages and done tasks; no art request is orphaned |

## No orphans

`tools/brandart/surfaces.toml` still lists the art the brand inventory asks for ("requests"). Each one now says what became of it, and the
test fails if one does not:

| Key | Means | Checked |
|---|---|---|
| `shipped` | it is built and installed | the path is in `approved-art.txt` |
| `used_by` | shipped, but something has to start using it | that task is OPEN in the ledger |
| `owner` | it is not built yet | that task is OPEN in the ledger |
| `repo` | it lives in the repository, not in the image | a reason is written |
| `decided` | someone decided against it | that task is DONE in the ledger |

Today: GRUB logo N-502, login manager N-503, lock and logout screens N-504, Welcome Center slides N-515; the tray icons are shipped and
shown by the panel's tray item (N-415b, which nothing owned until N-414); the website mark is kept in `assets/logo/favicon` and `assets/logo/social`
because a website is not part of the image; the window decoration is Breeze's (N-106).

## What N-415 itself added

The six tray icons (`tools/art/tray_icons.py`, N-413) install through `nisse-branding` 0.2-6 as
`/usr/share/icons/hicolor/scalable/status/nisse-tray-<state>-symbolic.svg`. Everything else approved was already installed by its own
task (the logo and n mark, avatars, wallpaper, cursors, icon themes, installer look, color schemes, sounds); the manifest records where.

When a new asset is approved, add its line to `approved-art.txt` in the same task that ships it, and give any request it answers a
`shipped` path.
