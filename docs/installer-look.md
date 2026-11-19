# The installer's look (N-411)

## What the installer really is

The installer on the live image is **not** the old GTK Anaconda. It is the Anaconda WebUI: a Cockpit page (`anaconda-webui`
in `cockpit-ws`) that `liveinst` starts in a browser window. Checked on the live ISO: `webui-desktop`, `cockpit-ws`,
`cockpit-bridge` and `anaconda --liveinst --graphical` are running, and none of the GTK images the ledger listed
(`sidebar-bg`, `topbar-bg`, `splash`, `progress_first`, `anaconda_header`) appears on screen.

Cockpit takes the page's colors and logo from `/usr/share/cockpit/branding/<os-release ID>/` (then each `ID_LIKE`, then
`default`). nisse's `ID` is `nisse`, there was no such folder, so Cockpit fell back to Fedora's (`ID_LIKE=fedora`): a Fedora-blue
header and Fedora's logo. Fedora's `branding.css` does three things: it names a three-color brand palette, it sets the
logo (`logo.png`, a link to `system-logo-white.png`), and the installer's own CSS paints the header from those colors.

## What nisse ships

`tools/art/installer_look.py` builds `/usr/share/cockpit/branding/nisse/` from `assets/palette/ember.json` (called by
`tools/logo/build_system.py`, shipped by `nisse-branding` 0.2-5):

| File | What it is |
|---|---|
| `branding.css` | the Ember palette for both looks (below), a header rule and a logo rule that out-rank the installer's own |
| `logo.png` | the 128 px app tile (Ink rounded square with the nisse logo) |
| `favicon.ico` | 16, 32, 48 and 64 px of the tile |
| `apple-touch-icon.png` | 180 px |

- **Dark look** (the live image's default): Ink page, surface and surface-2 for panels and inputs, Paper text. **Ember fills
  carry Ink text**, because Paper on Ember is only 3.1:1 (palette rule): the header band is Ember with an Ink title, the Next
  button is Ember with an Ink label. Links are the accent text color.
- **Light look**: the warm page and Paper, the darker accent (a brick red, 5.4:1 with Paper) for the header and buttons with
  Paper text; hover and pressed shades are `color-mix` of palette colors.
- Every color in the CSS is a palette color (tested); the header text is readable on **both ends** of the header's gradient in
  both looks (tested: a lighter gradient end failed 4.5:1 and was dropped).
- Brand and page tokens are set on `:root`. Set on `.anaconda` (where Fedora's file sets its three) they reached the header
  and the buttons but **not the page and sidebar backgrounds**; found by trying it in the live installer.
- The installer turns a logo into a white glyph with a CSS filter (`invert(1) grayscale(1)`, blended with `screen`), which
  turned the finished tile into a white square; the logo rule sets `filter: none` and `mix-blend-mode: normal`.
- The header rule starts with `:root`, so its specificity (0,4,0) beats the installer's (0,3,0) whatever the load order.

## The rest of the ledger list

| Id | Verdict | State |
|---|---|---|
| `installer/sidebar-logo` | redraw: nisse logo | `sidebar-logo.png` is the nisse logo (since the branding foundations); GTK Anaconda only, not shown by the WebUI |
| `installer/anaconda-apps`, `-2` | redraw: disk image | the nisse logo on a disk (N-409, `tools/art/icons.py`); the small tile in the WebUI header is now the app tile |
| `installer/fedora` | redraw: nisse logo | `fedora.icns` is the nisse tile at 512 px (Mac boot icon) |
| `boot/splash.png`, `boot/syslinux-splash.png` | redraw | the nisse lockup on Ink at the original sizes; **nothing shows them** (the ISO boots with GRUB, not syslinux), the boot art itself is N-412 |
| `installer/anaconda-header`, `progress-first`, `sidebar-bg`, `splash`, `topbar-bg` | keep | stay as they are in `nisse-branding` (nisse logo on plain Ink) |
| `installer/gnome-splash` | drop | no longer shipped (`placeholder-paths.txt` has it as a `D` line); `generic-logos` is obsoleted, so Fedora's file is gone from the image too |

Bert gated the set on 2026-11-19 from `docs/screenshots/n-411-installer-art-set.png` (the installer in both looks, true colors).

## Testing notes (for the next art task)

- **The test VM's screen is tinted.** KWin's Night Light runs in the live session (the guest clock starts at night, see
  `livevm.py`), so white renders as `#ffdebc`. For true colors hold a Night Light inhibition: a process that calls
  `org.kde.KWin.NightLight.inhibit` over the session bus and stays alive (`Gio.DBusConnection` in a main loop); the
  inhibition ends when the process does. With it, white is `#ffffff` and Ink is `#1b2330`.
- The light look in the live session: `plasma-apply-colorscheme NisseEmberLight`, then start the installer (the WebUI follows
  `prefers-color-scheme` when it loads).
- `vm.sh sync` now deletes files from the VM's copy that were deleted here (a stale `gnome-splash.png` in the VM's copy of
  `assets/logo/system` failed the RPM build's unpackaged-file check).

## Tests

| Test | Where | What it proves |
|---|---|---|
| `tools/art/tests/test_installer_look.py` (30) | anywhere | palette colors only, both looks' token values, the contrast pairs, both gradient ends, the header rule's specificity, the logo rule, the logo/favicon/touch-icon sizes, deterministic output, folder name = os-release ID |
| `tools/logo/tests/test_system_logos.py` | anywhere | the committed `assets/logo/system` tree (now with the branding folder) regenerates byte for byte |
| `tests/rpm/test_branding.sh` | build VM | the four files are in the RPM, the CSS has the Ember and no Fedora blue, the logo is 128x128, gnome-splash is not shipped |
| `tests/iso/test_iso_contents.sh` | ISO rebuild (queued) | the folder is in the image and `ID=nisse` matches it |
