# Nisse desktop defaults (approved 2026-11-13, ledger N-110)

Bert approved this list as proposed. N-111 ships it as system config (and skel only if a setting cannot be set
system-wide); each key is checked against the installed Plasma 6.6 when N-111 is built, and any line whose key cannot be
set as a default is brought back to Bert instead of being dropped silently.

"Verified" means read from Fedora 44's `kde-settings` package on 2026-11-13. "Stock" means Plasma's own default, which
was not re-checked here.

| # | Setting | Default | Today |
|---|---|---|---|
| 1 | Click behavior | Double-click to open, single-click to select | Same (verified: `SingleClick=false`) |
| 2 | Animations | Plasma's stock speed and effects; nothing added | Stock |
| 3 | Night Light | On, fixed times 21:00 to 06:30, 4500 K at night, 30-minute transition. Fixed times need no location lookup. | Off (stock) |
| 4 | Window rules | None shipped | None |
| 5 | Shortcuts | Plasma's stock set plus one: Meta+N opens or focuses the Nisse panel app | Stock |
| 6 | Screen lock | Stock: locks after idle and on resume | Stock |
| 7 | Session restore | New logins start empty; AI sessions return through the daemon (ledger N-208), not KDE session restore | Same (verified: `loginMode=default`) |
| 8 | File indexing | Fedora's setting kept: the home folder is not indexed, so there is no background indexing load | Same (verified: baloo excludes the home folder) |
| 9 | On-screen keyboard | Stays enabled on Wayland, for touch machines such as the Surface Go | Same (verified: `VirtualKeyboardEnabled=true`) |

Real changes from today: Night Light (3) and the Meta+N shortcut (5). Everything else is Fedora's or Plasma's value kept
on purpose.

Related decisions elsewhere: color schemes and fonts (N-104, N-101), widget style (N-106), global themes and the system
default (N-108), panel layout (N-109), default apps (N-507), quick-ask hotkey and voice input (deferred, N-D05).
