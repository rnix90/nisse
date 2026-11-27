# Default apps: what ships and what does not (N-507)

Decided with Bert on 2026-11-25, one group at a time, from the launcher entries on the rebuilt ISO (67 entries, 2210 packages,
a 3.2 GB ISO). This is the list N-508 (de-bloat), N-508a, N-510 and N-511 work from. Every "in Fedora" below was checked against the
Fedora 44 repository in the build VM on that day; the two that are not in Fedora are marked.

## Rules from the decision

- **The mail suite is not wired into anything.** The whole KDE PIM suite ships, but nothing starts it, pins it, autostarts it, syncs
  an account or runs its background service until the user opens it or asks. N-508 carries the test.
- **Moonlight and Sunshine are built into the nisse repo** (neither is in Fedora). Sunshine is a network listener, so its service is
  installed but off until the user turns it on.
- **The browser is Chromium**, chosen in the first-run setup with other choices on offer (Chrome is fetched from Google, since it is
  not in Fedora). Firefox does not ship on the image.

## Ships

| Group | Apps |
|---|---|
| Files, terminal, system | Dolphin, Konsole, Spectacle, System Settings, System Monitor, Info Center, Discover, Filelight, Ark, Menu Editor |
| Text and numbers | Kate (replaces KWrite; the code editor of N-511), KCalc, Qalculate (Qt), Emoji Selector, KCharSelect |
| Office | LibreOffice Writer, Calc, Impress, Draw, Math |
| Mail and personal information | Kontact, KMail, KOrganizer, KAddressBook, Akregator, KMail Import Wizard, PIM Data Exporter, Sieve Editor, KTnef, Contact Theme Editor, Contact Print Theme Editor, KMail Header Theme Editor (all wired to nothing, see above) |
| Media and documents | VLC (replaces every other video player), Elisa, Gwenview, Okular, Xournal++ (PDF markup, drawing and export), KolourPaint, Kamoso, Skanpage, Qrca |
| Keys and security | KWallet Manager, Kleopatra, Firewall, Journald Browser, Crashed Processes Viewer |
| Disks and USB | GParted (replaces KDE Partition Manager), KDE ISO Image Writer (replaces Fedora Media Writer) |
| Remote and phone | KDE Connect (all three entries), Moonlight and Sunshine (nisse RPMs, not in Fedora) |
| Browser | Chromium (default) |
| nisse | the nisse panel |

## Drops

Dragon Player, KMahjongg, KMines, KPatience, KRDC, Krfb, NeoChat, SELinux Troubleshooter, Problem Reporting, KDebugSettings, Input
Method Selector, GnuPG Log Viewer, KMouth, Firefox, Fedora Media Writer, KDE Partition Manager, KFind, KWrite, Help Center, Welcome Center
(the nisse tour of N-515 replaces it).

## What each decision feeds

- N-508: remove the drops, add the additions that are in Fedora (VLC, Xournal++, GParted, Qalculate, Chromium, KDE ISO Image Writer, Kate).
- N-507a (new): build Moonlight and Sunshine as nisse RPMs. Spike first.
- N-507b (new): the first-run browser choice, including Chrome.
- N-508b (new): Discover must not become a second update path next to nisse-update.
- N-508a (built, below): the shipped taskbar pins name only apps that are installed, and no browser is pinned (Bert, 2026-11-15).
- N-508c (new): the installer offers the taskbar pins as a checkbox list (Bert, 2026-11-27); the live session keeps the defaults.
- N-510 covers, on a light surface with the shell dark: KMail (mail), LibreOffice Writer and Calc (word processor and
  spreadsheet), Okular and Xournal++ (PDF), Chromium (browser).
- N-511: Kate is the code editor that stays dark.

## Open points

- Kamoso and Qrca were on a drop list offered to Bert; he answered "keep a suite of everything we need" and named only the video
  player and PDF editing as changes, so they are kept. Say so if they should go.
- Dropping a package can be blocked by something that requires it (Plasma's meta packages pull some of these in). N-508 resolved
  each with the real dependency solver; the result is below.

## Built: N-508 (2026-11-26)

The decision above is data in `build/default-apps.txt` (one line per package: drop, hide or add). `build/kiwi/nisse/components/nisse-live.xml`
asks for it: an `<ignore>` for each drop and a `<package>` for each addition. `tools/build/image_packages.py` works out the whole
package set kiwi will install without building the ISO: it reads the description as kiwi does and runs the same dnf5 install as a dry run
in an empty root. `tests/build/test_image_apps.sh` (in the build VM) proves from that answer that every drop is absent, every addition
is present with its dependencies solved, and no mail suite program autostarts.

### Dropping is blocked by a dependency

kiwi turns an `<ignore>` into dnf's exclude, so a package that another package hard-requires cannot be dropped alone: the dry run fails
and names it. Two kinds of block came up:

- **A group or a plug-in needs it, and the pieces can go too.** Problem Reporting: `abrt-desktop` and `abrt-gui` require `gnome-abrt`,
  and nothing else needs them (the crash collector `abrt` itself stays, the launcher entry and the desktop applet go).
  Input Method Selector: `imsettings-plasma` requires `im-chooser`, so both are dropped (the Plasma plug-in of the input method
  settings, which nothing in the image uses).
- **Part of a program that stays.** GnuPG Log Viewer (`kwatchgnupg`) is a launcher entry of Kleopatra, which ships. The package
  `kleopatra` is a `hide` line: its program stays and the entry gets `NoDisplay=true`. A file trigger of nisse-defaults
  (`/usr/libexec/nisse-hide-launchers`, list `/usr/share/nisse/hidden-launchers.txt`) sets it whenever the entry is installed or
  updated, so it holds after Fedora updates the package. `rpm -V kleopatra` then shows that file as changed (the cost, as with the
  avatars of N-406a).

One more catch: Fedora's own vendored description names `mediawriter` as a package (`components/desktops/common.xml`), and dnf5 refuses to
install what it is told to exclude, so `build/render-kiwi.sh` takes that line out of the rendered copy (`tools/build/apply_drops.py`); the
vendored tree stays exactly as published.

### The mail suite is wired to nothing

Seen in the live session of the old image, right after login: Calendar Reminders (`kalendarac`, from `akonadi-calendar`) was running
and had started Akonadi (16 processes: the server and eight or so agents). It is the one mail suite program with an autostart entry; its
autostart file asks `kalendaracrc:General:Autostart:true`, and `nisse-defaults` 0.2-2 now ships `/etc/xdg/kalendaracrc` saying
`Autostart=false`. `tools/vm/pim_check.py` shows it in a live session: before the package kalendarac and Akonadi run; after it the
condition KDE evaluates is false and the real generated autostart unit is skipped (`result=exec-condition`), with no kalendarac and
no Akonadi process afterwards. No taskbar pin names a mail program (the pins are checked whole in N-508a). The drops also remove
three other things that started at login in the old image: the Problem Reporting applet, the SELinux Troubleshooter's alert program
and the Welcome Center.

### The Welcome Center's sticker

`plasma-welcome-fedora` requires `plasma-welcome`, so dropping the Welcome Center drops it too, and with it the "Fedora loves KDE"
sticker that nisse-avatars replaces (N-406a). The nisse sticker stays in `nisse-avatars` with nothing to replace until N-515 (the nisse
tour) either uses it or removes it.

### The default taskbar (N-508a)

The live session and a fresh install pin four things, in this order: the nisse panel, Files (`preferred://filemanager`, Dolphin),
Terminal (Konsole) and System Settings. No browser is pinned (Bert, 2026-11-15; Chromium is one click away in the launcher, and the
first-run browser choice is N-507b). `nisse-lookandfeel` 0.2-9 ships the layout script. Proof: `tests/rpm/test_lookandfeel.sh` (the exact
list, no browser), `tests/build/test_image_apps.sh` (each pin is a desktop file shipped by a package of the resolved image and is not a
`WebBrowser`), the queued block in `tests/iso/test_iso_contents.sh` (the same on the real image, read from the installed layout), and
`tools/vm/pins_check.py` (a live session: the old taskbar pins Firefox; with the package in and the panel configuration removed, the
panel built from the layout script pins exactly the four; `docs/screenshots/n508a-taskbar-before.png` and `-after.png`). The five
screenshot goldens in `tests/golden` show the taskbar and lose the browser icon, so they are re-accepted at the next rebuild (N-403a's
way). Bert asked (2026-11-27) that the installer let the user tick the pins as a checkbox list: N-508c.

### Size

From the dry run (the package sizes as dnf lists them, not the compressed ISO): 2093 packages and 7099 MiB before, 2281 packages and
7564 MiB after (+188 packages, +465 MiB: VLC, Chromium, Kate, Xournal++, GParted, Qalculate and KDE ISO Image Writer with their
libraries, less the drops). The previous ISO was 3.2 GB and the budget has no ceiling (docs/dev-toolchain.md: looked at again past a
standard 8 GB stick); the real number is recorded when the ISO is rebuilt.
