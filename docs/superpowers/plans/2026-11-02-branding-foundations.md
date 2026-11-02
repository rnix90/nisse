# Branding Foundations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove every trace of Fedora's placeholder branding (the "hot dog" from `generic-logos`) from the image and give Nisse its own product version, 0.2, so the first thing a tester sees is Nisse.

**Architecture:** `nisse-branding` becomes the system logo package (`Provides: system-logos`, `Conflicts: generic-logos`) and ships Nisse art under the file names the rest of the system already looks for; the logo build script generates that art from the existing logo sources. A new `build/PRODUCT_VERSION` feeds `nisse-release` (displayed name and version) and the kiwi volume id, while `VERSION_ID` stays the Fedora base release that dnf, COPR and `%fedora` need.

**Tech Stack:** RPM specs, Python (Pillow, fontTools, playwright) in `tools/logo/build.py`, kiwi description templates, bash tests, the Fedora build VM and host QEMU smoke boot (`docs/build-host.md`).

**Spec:** `docs/roadmap.md` (Phase 1: 1.3, 1.4, 1.9, 1.12 groundwork), Bert's decisions of 2026-11-02 recorded in the memory file (Nisse's own version number starting at 0.2, no "alpha" label, no following Fedora's number in future; branding replaces generic-logos).

## Global Constraints

- ASCII only in everything authored. No tokens, credentials or personal data in the repo or image.
- TDD: every behaviour change gets a test that is run and seen to fail first.
- `VERSION_ID` in os-release and the `nisse-release` RPM `Version` stay the Fedora base release (44): dnf's `$releasever`, the COPR plugin and the `%fedora` macro depend on them. Only user-visible names change.
- RPM changes bump the spec `Release` and add a dated changelog entry (author `Bert <266182601+rnix90@users.noreply.github.com>`).
- Rust, QML and RPM tests run in the build VM (`bash tools/build/vm.sh sync` first; `vm.sh sync` uses fresh mtimes). Python and the logo build run on the host.
- Commits end with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_012HaX4wM2HNi6CtaPcZCAUT`.
- Bert's standing rule: fix Minor review findings too, ask only for decisions that are his.
- After any rebuild of the ISO, compare the binaries and key files in the image with the freshly built RPMs (kiwi can serve a cached RPM with an unchanged name-version-release).

## Review Focus

- Nothing from `generic-logos` or `fedora-logos` may remain in the image, and nothing that depended on them may break (`anaconda`, `plymouth`, `plasma-welcome`, `kde-settings` all ask for `system-logos` or read the fixed file names).
- A package that previously owned a branding path must not conflict with `nisse-branding` at install time (file conflicts break the ISO build and `dnf` upgrades).
- The product version must appear wherever the OS names itself (os-release, `/etc/issue`, `/usr/lib/fedora-release`, the CPE name, the ISO volume id and the boot menu) and the string "Nisse 44" must appear nowhere.
- `VERSION_ID` and `$releasever` must still be 44: a dnf transaction against Fedora's repos must still resolve.
- The start button, the About page and the installer must show Nisse art in a booted image, not just in package contents.

---

### Task 1: Nisse's own product version

**Files:**
- Create: `build/PRODUCT_VERSION` (content `0.2`)
- Modify: `packaging/rpm/nisse-release/nisse-release.spec`, `tools/rpm/build-rpm.sh`, `build/render-kiwi.sh`, `build/kiwi/nisse/components/nisse-live.xml`, `docs/build-host.md`
- Test: `tests/rpm/test_nisse_release.sh`, `tests/build/test_kiwi_description.sh`, `tests/iso/test_iso_contents.sh`

**Interfaces:**
- Produces: `build/PRODUCT_VERSION` read by `build-rpm.sh` (defines `%nisse_product`) and `render-kiwi.sh` (placeholder `@PRODUCT@`, replacing `@RELEASE@` in the volid, application id and publisher fields only; `@RELEASE@` stays for anything that means the Fedora base). os-release fields: `NAME="Nisse"`, `VERSION="0.2"`, `PRETTY_NAME="Nisse 0.2"`, `VERSION_ID=44` (unchanged, with a comment in the spec saying why), `BUILD_ID=0.2`, `CPE_NAME="cpe:/o:nisse:nisse:0.2"`. `/usr/lib/fedora-release` reads `Nisse release 0.2 (Nisse)` and `/usr/lib/system-release-cpe` the new CPE. ISO volume id `Nisse-0.2`.

- [ ] **Step 1: Write the failing assertions.** `test_nisse_release.sh`: os-release has the six lines above (`VERSION_ID=$REL` still asserted), `PRETTY_NAME` does not contain `$REL`, `/usr/lib/fedora-release` equals `Nisse release 0.2 (Nisse)`, the CPE file holds `cpe:/o:nisse:nisse:0.2`, the RPM `Version` is still `$REL`. `test_kiwi_description.sh` part 2: the rendered `nisse-live.xml` has `volid="Nisse-0.2"` (read the product from `build/PRODUCT_VERSION`) and the Fedora base release still appears nowhere as a product name. `test_iso_contents.sh`: the ISO Volume Id is `Nisse-<product>`, and `grep -rn "Nisse 44"` over the ISO's `boot/grub` and `EFI` configuration finds nothing.
- [ ] **Step 2: Run them and watch them fail** (RPM test and description test in the VM, ISO test against the current ISO).
- [ ] **Step 3: Implement.** Create `build/PRODUCT_VERSION`; `build-rpm.sh` passes `--define "nisse_product $(cat build/PRODUCT_VERSION)"` for every package; the spec uses `%{nisse_product}` in os-release, `fedora-release`, the CPE and a new changelog entry (Release 6, text "Nisse's own product version 0.2; VERSION_ID stays the Fedora base"); `render-kiwi.sh` substitutes `@PRODUCT@` (escaped like the other values); the volid, application id and publisher in `nisse-live.xml` use `@PRODUCT@`; document the two numbers in `docs/build-host.md` (product version vs Fedora base).
- [ ] **Step 4: Run to verify:** RPM test and description test GREEN in the VM; also the host description test; `rpmlint` 0 errors.
- [ ] **Step 5: Commit** `feat: Nisse's own product version (0.2); VERSION_ID stays the Fedora base`.

---

### Task 2: Replace the placeholder art (generic-logos) with Nisse's

**Files:**
- Modify: `tools/logo/build.py` (new outputs), `assets/logo/` (generated files, committed like the others), `packaging/rpm/nisse-branding/nisse-branding.spec` (Version 0.2, Release 1), `build/kiwi/nisse/components/nisse-live.xml` (drop `generic-logos`, keep the ignore entries for `fedora-logos`)
- Create: `assets/logo/system/` (the replacement files), `tests/rpm/placeholder-paths.txt` (every path `generic-logos` owns, from `rpm -ql generic-logos` in the image)
- Test: `tests/rpm/test_branding.sh`, `tests/iso/test_iso_contents.sh`

**Interfaces:**
- Produces: `nisse-branding` gains `Provides: system-logos = %{version}-%{release}`, `Provides: fedora-logos`, `Conflicts: generic-logos`, `Conflicts: fedora-logos`, and ships Nisse art at each path listed in `tests/rpm/placeholder-paths.txt` at the same size as the original: `start-here` in `hicolor/scalable/apps` and `hicolor/scalable/places` (plus a symbolic variant), `/usr/share/pixmaps/fedora-logo.png` (240x310), `fedora-logo-small.png` (128x128), `fedora-logo-sprite.svg`, `system-logo-white.png`, `splash/gnome-splash.png` (420x293), the Anaconda set under `/usr/share/anaconda/pixmaps/` (`anaconda_header.png` 800x88, `progress_first.png` 416x265, `sidebar-bg.png` 406x767, `sidebar-logo.png` 128x128, `splash.png` 416x265, `topbar-bg.png` 1040x132), the `anaconda` icons (48x48 png, scalable svg, oxygen 48x48), and the bootloader pixmaps `bootloader/fedora.icns`, `fedora.vol`, `fedora-media.vol` (Nisse art or text under the old names). Colours: Ink `#1b2330` and Paper `#f6f2e9` only (the Ember accent comes with roadmap 1.1/1.2).

- [ ] **Step 1: List the placeholders.** In the VM, mount the current ISO and write every path owned by `generic-logos` (`rpm -ql`) to `tests/rpm/placeholder-paths.txt`, one per line; decide per path (in the ledger) whether Nisse replaces it or it is deliberately dropped (for example translation or Mac-only files) and list the dropped ones in the same file after a `# dropped:` line with the reason.
- [ ] **Step 2: Write the failing tests.** `tests/rpm/test_branding.sh`: the RPM provides `system-logos`, conflicts with `generic-logos` and `fedora-logos`, and ships every replaced path from `placeholder-paths.txt`; each replaced PNG has the expected dimensions (read the PNG header); each SVG parses as XML and contains no `<image` element with embedded raster data over 20 KB (a hot dog would be one). `tests/iso/test_iso_contents.sh`: `generic-logos` and `fedora-logos` are not installed; no file in the image is owned by either; `rpm -qf` of every replaced path names `nisse-branding`; `usr/share/icons/hicolor/scalable/apps/start-here.svg` differs from the generic-logos original (compare against the sha256 recorded for it in `tests/rpm/placeholder-paths.txt`).
- [ ] **Step 3: Run them and watch them fail** (the branding RPM test in the VM; the ISO test against the current ISO fails on `generic-logos` being installed).
- [ ] **Step 4: Implement.** Extend `tools/logo/build.py` to generate the replacement set from the existing icon and wordmark sources (Pillow for PNG compositing and `.icns`, the SVG sources for `start-here` and the sprite); re-run it and commit the generated files under `assets/logo/system/`; update the spec (`%files`, `Provides`, `Conflicts`, Version 0.2) and `nisse-live.xml`.
- [ ] **Step 5: Run to verify:** `python tools/logo/build.py` reproduces the committed files; the branding RPM test GREEN; `rpmlint` 0 errors; `tests/repo/test_tracked_files.sh` PASS (add the new paths to it).
- [ ] **Step 6: Commit** `feat: nisse-branding replaces generic-logos (no more placeholder art)`.

---

### Task 3: The About page and the start button show Nisse

**Files:**
- Modify (only if the investigation shows it is needed): `packaging/rpm/nisse-branding/nisse-branding.spec` or a small `kdeglobals`/Plasma default shipped by `nisse-branding`, `docs/milestone-1-acceptance.md`
- Test: `tests/iso/test_iso_contents.sh`, `tests/e2e/check_start_button.py` (new)

**Interfaces:**
- Produces: `tests/e2e/check_start_button.py SCREENSHOT.png` exits 0 when the start button region of a 1280x800 live-desktop screenshot (the first icon at the left of the bottom panel) contains no hot dog colours (brown `#a0522d` family and yellow glow) and does contain Ink or Paper pixels.

- [ ] **Step 1: Investigate what the About page loads.** Find out how `kcm_about-distro` picks its picture (read the QML shipped in the image or the plugin's resources) and what the start button's `kickoff` uses (`start-here-kde` then `start-here`). Record the finding in the ledger. If the page uses `LOGO` from os-release, `distributor-logo-nisse` must resolve (it is in the hicolor cache); if it falls back to `start-here`, Task 2 already covers it.
- [ ] **Step 2: Write the failing check.** `check_start_button.py` with a fixture screenshot of the current (hot dog) ISO saved under `tests/e2e/fixtures/start-button-placeholder.png` and one of a clean region: the script must FAIL on the placeholder fixture and PASS on a Nisse one. Add to `test_iso_contents.sh` a check that `start-here-kde` and `start-here` resolve (by file) to Nisse-owned files in every hicolor size directory that Plasma queries.
- [ ] **Step 3: Rebuild the ISO** (`build/build-all.sh`, about 35 minutes), pull it, run `tools/vm/smoke-boot.sh ... --screenshot`, and run `check_start_button.py` on the screenshot. Expected: PASS. Look at the screenshot yourself as well.
- [ ] **Step 4: If the About page still shows a placeholder** (it cannot be checked by script without input), fix what step 1 found and add the item "About this System shows the Nisse logo, name Nisse 0.2 and the repository link" to `docs/milestone-1-acceptance.md` for Bert's manual check.
- [ ] **Step 5: Whole suite and push.** Run the full suite (hw pytest, cargo, panel ctest and e2e, every RPM, shell and build test, ISO contents, boot screenshot, hardware e2e), compare the binaries in the image with the built RPMs, update `docs/roadmap.md` (Phase 1 group "1.0 branding foundations" done), and push `daily`.
- [ ] **Step 6: Commit** `feat: start button and About page show Nisse; product version 0.2 on the ISO`.

---

## Self-review notes

- **Spec coverage:** hot dog explained and removed (Task 2, proven in Task 3), own version 0.2 without "alpha" (Task 1), `VERSION_ID` kept for dnf (Global Constraints, Task 1 test).
- **Rulings the executor settles and ledgers:** which `generic-logos` paths are replaced versus dropped; how the Anaconda artwork is composed from Ink/Paper only (the Ember accent is a later roadmap item); the exact About-page mechanism found in Task 3 step 1; whether the ISO volume id may contain a dot (it does in Fedora's own older volume ids; if the build or the boot label chokes, use `Nisse-0_2`).
- **Not in this plan:** the Ember palette, Plasma theme, wallpapers (the blue Fedora wallpaper and `plasma-lookandfeel-fedora` are still Fedora's and belong to roadmap 1.2 and 1.4), the Plymouth splash and GRUB theme (1.9), the installer's wording (1.12), and the SSH install-time option (1.15).
