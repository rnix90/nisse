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
- N-508a: the shipped taskbar pins name only apps that are installed, and no browser is pinned (Bert, 2026-11-15).
- N-510 covers, on a light surface with the shell dark: KMail (mail), LibreOffice Writer and Calc (word processor and
  spreadsheet), Okular and Xournal++ (PDF), Chromium (browser).
- N-511: Kate is the code editor that stays dark.

## Open points

- Kamoso and Qrca were on a drop list offered to Bert; he answered "keep a suite of everything we need" and named only the video
  player and PDF editing as changes, so they are kept. Say so if they should go.
- Dropping a package can be blocked by something that requires it (Plasma's meta packages pull some of these in). N-508 resolves
  each with the real dependency solver; a blocked drop is hidden from the launcher instead and listed in the task's note.
