# GATE 3 hand checks (N-313)

Everything here needs a real mouse, a real keyboard or an ear, so no harness can do it: synthetic clicks never land in these
virtual machines. The automated parts of the gate (ISO contents, screenshot regression, install-to-disk, the six real-machine tests,
the panel and daemon tests) are reported in the ledger entry of N-313.

Three machines are used, all on the rebuilt ISO (from Git Bash in the repo; each opens a window; `--audio` plays the sounds through
the host's speakers):

- **LIVE** boots the ISO itself: a fresh desktop, nothing installed. Used for the sidebar, the tray, the sound theme and the badge.

      tools/vm/run-vm.sh D:/nisse-build-vm/handcheck/live.qcow2 --iso D:/nisse-build-vm/out/nisse-live.iso --audio

- **HISTORY** is a copy of the disk the install-to-disk test made, with two real package changes in its history. Used for System
  history and Undo (steps 15 to 19).

      tools/vm/run-vm.sh D:/nisse-build-vm/handcheck/history.qcow2 --audio

- **BROKEN** is the same disk with an update applied that fails its own health check after the restart. Used for the watchdog's
  countdown notice (steps 20 to 23). Boot it, then log in within about three minutes (see that section).

      tools/vm/run-vm.sh D:/nisse-build-vm/handcheck/broken.qcow2 --audio

On the two installed machines log in as the user the harness made (the name and password are in `out/install/run/harness-login.txt`;
a throwaway virtual machine). The disks are copies: closing a window and starting again from the same file continues where it
left off, so keep a pristine copy of `history.qcow2` and `broken.qcow2` if you want to repeat a step from the start.

A mouse that is captured by a VM window is released with Ctrl+Alt+G.

To raise the approval notice for steps 12 and 13, open Konsole in the LIVE machine and paste this one line:

    busctl --user call org.nisse.Daemon1 /org/nisse/Daemon1 org.nisse.Daemon1 RequestApproval sssss "" "demo" "Bash" "Bash: git push origin main (outbound)" "{}"

## LIVE: the sidebar (N-415a)

| # | Do | Expect |
|---|---|---|
| 1 | Press Meta+N | the nisse sidebar slides in from the right edge |
| 2 | Type a few words | they appear in the chat input |
| 3 | Press Escape | the sidebar slides out |
| 4 | Click the pinned nisse icon in the taskbar (the sparkle) | the sidebar slides in; click again, it slides out |
| 5 | Open it, click into the chat field and type | the letters land in the chat |
| 6 | Push the pointer against the right edge of the screen | the sidebar shows (and it does not take the keyboard) |

## LIVE: the tray item (N-415b)

| # | Do | Expect |
|---|---|---|
| 7 | Click the nisse icon in the system tray | the sidebar slides in; click again, it slides out |
| 8 | Slide it in with the tray icon, then type | the letters reach the chat (the click's activation token) |
| 9 | Right-click the tray icon | a menu with **Open nisse**, **Pause AI** (and **Approvals (N)** while something waits) |
| 10 | Choose **Pause AI** | the tray icon changes to the paused look; the menu now says **Resume AI** |
| 11 | Choose **Resume AI** | the icon is back to idle |

## LIVE: notices, badge and sound (N-414)

| # | Do | Expect |
|---|---|---|
| 12 | Raise an approval notice with the command above, then click it | the sidebar opens on the Approvals page |
| 13 | Look at the pinned nisse icon while an approval waits | a small number badge |
| 14 | Listen: log in, log out, a needs-you notice, an error, a volume key | six sounds in the plucked-wood voice, two semitones down; tell me which you like and which you do not |

## INSTALLED: System history and Undo (N-311)

| # | Do | Expect |
|---|---|---|
| 15 | Open the panel, then Settings, then scroll to **System history** | rows for the package changes made in the preparation, newest first, grouped by day |
| 16 | Click **Undo** on the older row | the confirmation: what is undone, that home and data are not covered, that the computer restarts right away |
| 17 | Click **Cancel** | back to the list, nothing changed |
| 18 | Click **Undo** again and then **Undo and restart** | the machine restarts and comes back with the package gone |
| 19 | `sudo nisse-sudo-mode limited`, open System history, press Undo and restart | the list opened without a password box; the Undo opens the password popup |

## INSTALLED: the watchdog's countdown notice (N-310)

The machine is prepared with an update that fails its own health check. After it starts, log in **within about three minutes**:
the health check gives up after 180 seconds and the countdown starts.

| # | Do | Expect |
|---|---|---|
| 20 | Log in and wait | a critical notice: the update failed its checks, undone in 60 seconds, with a **Keep the update** button |
| 21 | Click **Keep the update** | the notice goes away and nothing is undone this boot |
| 22 | Restart the machine, log in, and this time do not click | after 60 seconds the machine undoes the update and restarts |
| 23 | Log in again | one notice, once: nisse undid the last update, why, and that your files were not changed |

Report each number as ok, wrong or unclear, with a word about what you saw. A wrong one is reopened as a lettered task and the gate
stays open until it passes.
