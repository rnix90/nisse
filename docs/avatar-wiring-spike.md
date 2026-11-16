# Replacing other packages' pictures: the mechanism (spike for N-406a, 2026-11-16)

Question: the Konqi pictures we replace (N-406) belong to other packages (plasma-workspace, plasma-welcome-fedora,
plasma-setup). Customizations ship as RPMs (project rule 10), and an image build must not depend on luck. How does a nisse
package replace another package's files?

Short answer: **a file trigger in nisse's own package** (`%transfiletriggerin`). rpm refuses two packages owning one file with
different content, and the files we replace have fixed names that Plasma reads, so a plain "ship the same path" does not work.
The trigger fires whenever files under the watched folders are installed, whichever package brings them and whichever order
they arrive in, and replaces them.

## Evidence (build VM, `~/spike406`; scripts `tools/spike/avatar_conflict_spike.sh` and `tools/spike/avatar_trigger_spike.sh`)

1. **Same path, other content = a conflict.** The real `plasma-workspace-6.8.3-1.fc44` was recorded in a throwaway rpm database
   (`rpm --root ... --justdb`). A package shipping `/usr/share/plasma/avatars/Konqi.png` with other content was then installed:
   `file /usr/share/plasma/avatars/Konqi.png from install of nisse-avatars-conflict-1-1.noarch conflicts with file from package
   plasma-workspace-6.8.3-1.fc44.x86_64`. Only `--replacefiles` gets past it, which a build must not rely on.
2. **The trigger works in every order** (a stand-in package owning `Konqi.png`, `Katie.png`, a photo and `fedora-loves-kde.svg`
   plus a spike package with the trigger, installed directly on the VM):
   - original first, then ours: Konqi and Katie removed, the photo stays, the sticker replaced.
   - the original UPDATED later (its files come back): the trigger fires again, same result.
   - ours first, then the original arrives: same result.
   - both in ONE transaction (what dnf does when kiwi builds the image): same result.
3. **What it costs:** `rpm -V` of the original package then reports the replaced sticker as changed (`S.5`) and the removed
   Konqi and Katie files as missing. That is the honest state of the machine, and nothing in the repo or the image tests verifies
   those packages' own files.
4. **Nothing refers to the Konqi picture names.** No binary or text file in the image (libraries, libexec, bin, plasma, kpackage,
   etc) mentions `Konqi.png`, `Katie.png` or `Artist Konqi`; the user picture chooser lists the folder. (A VM screenshot of the
   chooser is the check that it is right, N-406a.)

## What was rejected

- **Rebuild plasma-workspace, plasma-welcome-fedora and plasma-setup with other files:** nisse would carry three big forks and
  must rebuild each on every Fedora update.
- **A kiwi overlay copying the files at image build:** breaks rule 10 (not an RPM) and the first update of the owner package
  brings Konqi back.
- **`--replacefiles` or a post-install script that overwrites the files once:** the same reverting on update.
- **Dropping the owner packages:** plasma-workspace is the desktop.

## The design that follows

New package `nisse-avatars`:
- the 17 gnome pictures installed under their own new names in `/usr/share/plasma/avatars` (no conflict, nothing to replace),
- the replacements for the files that keep their names (`fedora-loves-kde.svg`, `mascot_konqi_3rdparty.svg`,
  `konqi-calling.png`) stored under `/usr/share/nisse/art-replacements/`,
- `/usr/libexec/nisse-avatars-replace`: reads installed paths on stdin; removes the Konqi and Katie pictures from the avatar
  folder, and copies a stored replacement over a listed file of the same name (and removes the `.license` file that sat beside
  the old `konqi-calling.png`, because it described the old picture),
- a `%transfiletriggerin` on the three folders that calls the script. The script takes a root prefix from the environment, so a
  test runs it against a temporary tree.

## Licence of the sticker (open, carried)

The original `fedora-loves-kde.svg` comes from `plasma-welcome-fedora` 6.3.4-3, whose package licence is
`(GPL-2.0-only OR GPL-3.0-only) AND CC-BY-SA-4.0` (the package ships the licence texts but no per-file licence record for this
picture; the upstream REUSE data could not be fetched from here). Which of the two covers the sticker is therefore NOT verified.
The derived sticker (the heart and the KDE logo are unchanged shapes; the left logo is nisse's) is shipped under CC-BY-SA-4.0
with attribution, the cautious choice, until upstream confirms. The pair picture and the avatars are nisse's own art
(GPL-2.0-or-later like the rest of the repository).

## Reproduce

    bash tools/build/vm.sh sync
    bash tools/build/vm.sh ssh 'mkdir -p ~/spike406 && cd ~/spike406 && dnf download plasma-workspace plasma-welcome-fedora plasma-setup'
    bash tools/build/vm.sh ssh 'bash ~/nisse/tools/spike/avatar_conflict_spike.sh'
    bash tools/build/vm.sh ssh 'bash ~/nisse/tools/spike/avatar_trigger_spike.sh'      # installs and removes stand-in packages on the VM

## Result on the real image (N-406a, 2026-11-16)

The mechanism was built as `nisse-avatars` (packaging/rpm/nisse-avatars) and the ISO was rebuilt. `tests/iso/test_iso_contents.sh`
passes on it: no Konqi or Katie user picture is left, the 16 `... gnome.png` pictures and `nisse.png` are there, the photo
avatars are untouched, the sticker and both phone pictures are the nisse replacements, and the old `konqi-calling.png.license`
is gone. So the file trigger fires during the kiwi image build (one dnf transaction), as the spike showed.

`docs/screenshots/n-406a-avatar-folder-in-live-image.png`: Dolphin in the live session showing `/usr/share/plasma/avatars`:
the photos folder and the gnome pictures, no Konqi.

Not automated: the user picture chooser inside System Settings. Its avatar button cannot be reached by keyboard, and the VM
harness has no working mouse (a try with a USB tablet through the QEMU monitor moved the pointer unpredictably and was dropped
rather than shipped unverified). The chooser is listed as a hand check at GATE 3.
