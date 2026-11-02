# Brand Art Review Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** PLAN ONLY. Bert (2026-11-02): "let's just plan for now, we'll implement later." Do not execute until he says so.

**Goal:** A locally hosted page that shows every graphic of a built Nisse image that belongs to its identity or desktop theme, each with a comment box, so Bert can assemble one large "what to draw" submission for Nisse's own artwork.

**Architecture:** A host-side Python tool extracts the brand-bearing graphics from a built ISO (read in the build VM, where the EROFS image mounts) according to a curated surface list, writes an `inventory.json` and preview images into the git-ignored `out/brandart/`, and a small standard-library web server shows them on `127.0.0.1` and stores Bert's comments in a JSON file on disk. An export button writes a Markdown brief (plus copies of the originals marked for redraw) that can be handed to an artist or fed back to Claude.

**Tech Stack:** Python 3 standard library for the server and inventory (Pillow only for thumbnails and swatches, already used by `tools/logo/build.py`), vanilla HTML/JS/CSS with no external requests, pytest for tests, playwright for the page smoke test, the Fedora build VM for reading the image (`docs/build-host.md`).

**Spec:** Bert's answers of 2026-11-02 (own graphics and branding for all parts of KDE and Fedora; review page with a comment box per graphic; scope = identity + desktop theme), `docs/roadmap.md` Phase 1 (1.1 to 1.15) and `docs/superpowers/plans/2026-11-02-branding-foundations.md` (the placeholder-art replacement this feeds).

## Global Constraints

- ASCII only in everything authored, including the generated Markdown brief (no emoji, smart quotes or arrows).
- Everything runs locally: the server binds to `127.0.0.1` only, the page loads nothing from the network (no CDN, fonts or analytics), and `out/` stays git-ignored. Extracted Fedora and KDE originals never enter git.
- Bert's comments must never be lost: every change is written to disk before the page shows it as saved, writes are atomic (temp file then rename), and the page keeps a copy in the browser too.
- No tokens, credentials or personal data in the repo, the page or the export.
- TDD: each behaviour gets a test that is seen to fail first. Python tests run on the host; image reading runs in the build VM.
- Commits end with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_012HaX4wM2HNi6CtaPcZCAUT`.
- Bert's standing rule: fix Minor review findings too; ask only for decisions that are his.

## Review Focus

- The inventory must not silently miss a surface: every group in `surfaces.toml` must match at least one real file in a real image, or be marked explicitly as a "missing graphic" request, and the tool fails when a pattern matches nothing without that mark.
- Comments survive a server restart, a browser reload, two browser tabs open at once, and a crash in the middle of a save (no truncated or half-written `comments.json`).
- A transparent or white-on-transparent graphic (symbolic icons, logos for dark backgrounds) must be reviewable: the preview needs switchable light, dark and Ink backgrounds, or it will look like an empty card.
- The export must be complete and self-explaining: every commented item carries its id, where it is seen, the source path, the owning package and license, its size, and the comment, so Bert's brief makes sense without the page.
- Large groups (hundreds of icons and cursor frames) must stay fast: lazy-load images and never block the page on the whole inventory.

---

## Surface list (what "every graphic" means, grouped by where Bert sees it)

Defined in `tools/brandart/surfaces.toml` (Task 1). Each group has a title, a one-line "where you see it", and file patterns relative to the image root; a group can also hold "missing graphic" requests for places that have no graphic yet.

1. **Logos and marks:** distributor logo at every size, start button icon (`start-here`), About this System picture, favicon, the `nisse-panel` app icon and tray icon.
2. **Boot and login:** Plymouth boot splash (all frames and watermark), GRUB menu background and logo, the Plasma Login Manager theme and background, the lock screen, the logout and shutdown screens.
3. **Installer and first run:** Anaconda sidebar, header, top bar, splash and progress art; the live "Install to Hard Drive" icon; the Plasma Welcome app's slides and images.
4. **Wallpapers:** every wallpaper in the image (light and dark variants, with sizes), plus the default-wallpaper request.
5. **Plasma look and feel:** the look-and-feel package previews and splash screens, the Plasma theme SVG sheets (panel, widgets, dialogs, tooltips, tray) rendered per sheet with their element ids listed, the window decoration (code-drawn: listed as a text-only request), the cursor theme (each cursor, rendered frames), the color schemes (rendered swatches with the key color roles).
6. **Core icons:** a curated list of about 150 icon names that make up the daily experience (folders and files, system settings categories, network, audio, battery, notifications, window controls, the default apps) rendered from the Breeze theme at 48 and 128 px, with symbolic variants.
7. **Default application icons:** the launcher icons of the apps Nisse ships by default (Dolphin, Konsole, Kate, Discover, System Settings, Firefox, the Nisse panel and any others in the image's default favorites).
8. **Sounds:** login, logout, notification and error sounds, listed as audio items with a play button (not graphics, but part of the identity and cheap to review).
9. **Requests for new art:** surfaces with no graphic today (for example a Nisse login avatar, an empty-state illustration for the panel, a lock screen scene) plus anything Bert adds on the page.

---

### Task 1: Surface list and inventory extraction

**Files:**
- Create: `tools/brandart/surfaces.toml`, `tools/brandart/inventory.py`, `tools/brandart/extract_in_vm.sh`, `tools/brandart/tests/test_inventory.py`, `tools/brandart/tests/fixtures/` (a tiny fake image root)
- Modify: `.gitignore` (`/out/brandart/`)

**Interfaces:**
- Produces: `inventory.py ROOT --out DIR` where ROOT is an unpacked image root (directory). It writes `DIR/inventory.json` and copies each matched file to `DIR/assets/<id>.<ext>`. `inventory.json` is `{"image": {"iso": str, "built": str, "sha256": str}, "groups": [{"id", "title", "seen", "items": [Item]}]}` with `Item = {"id": str, "title": str, "seen": str, "kind": "png|svg|cursor|colors|sound|missing", "source": str, "owner": str, "license": str, "width": int|null, "height": int|null, "preview": str|null, "variants": [str]}`. Ids are stable slugs (`<group>/<file-stem>-<size>`) so comments survive a re-extraction. `owner` and `license` come from `rpm -qf` and `rpm -q --qf %{LICENSE}` against the image's rpm database (passed as `--rpmdb`; empty when not available).
- `extract_in_vm.sh ISO` mounts the EROFS root in the VM, runs the tool there against the mount, and pulls `out/brandart/` back to the host.

- [ ] **Step 1: Write the failing tests** in `test_inventory.py` against the fixture root: every pattern group in `surfaces.toml` parses; a pattern that matches no file and is not marked `missing = true` fails the run with the pattern named; ids are unique and stable across two runs; PNG and SVG dimensions are read correctly; a file listed twice by two patterns appears once; the `owner`/`license` fields are filled from a fake rpm query.
- [ ] **Step 2: Run to verify they fail** (`python -m pytest tools/brandart/tests -q`): no module.
- [ ] **Step 3: Implement** `surfaces.toml` for the nine groups above (patterns for the real Fedora 44 KDE image: the Plymouth theme directory, `usr/share/wallpapers/*`, `usr/share/plasma/desktoptheme/*/widgets/*.svg`, `usr/share/icons/breeze_cursors/cursors/*`, `usr/share/color-schemes/*.colors`, the Anaconda pixmaps, the sound theme directory, the curated icon name list in `icons.txt`), `inventory.py`, and `extract_in_vm.sh`.
- [ ] **Step 4: Run to verify:** tests pass; then run `extract_in_vm.sh` on the current ISO and check the group counts against a hand count of two groups. Expected: no group empty without the `missing` mark.
- [ ] **Step 5: Commit** `feat: brand art inventory (surface list and extraction)`.

### Task 2: Previews for the awkward kinds

**Files:**
- Create: `tools/brandart/previews.py`, `tools/brandart/tests/test_previews.py`

**Interfaces:**
- Consumes: Task 1's `inventory.json` and `assets/`.
- Produces: `previews.py DIR` adds a `preview` PNG (and `variants` for extra frames) for every item that is not directly viewable: `svg` sheets render to PNG with their element ids listed in the item (`elements: [str]`); `colors` schemes render to a swatch PNG showing Window, View, Button, Selection, Tooltip and Complementary background/foreground pairs; `cursor` files render each frame to PNG (via `xcur2png` in the VM, otherwise a documented fallback); `sound` items get a duration read from the file header and no image.

- [ ] **Step 1: Write the failing tests:** a fixture `.colors` file renders a swatch of the expected size whose pixels at known positions equal the scheme's colors; a fixture SVG with three element ids lists all three; a fixture WAV reports its duration; items of kinds that cannot be previewed stay listed with `preview: null` and a `note` (never dropped).
- [ ] **Step 2: Run to verify they fail.**
- [ ] **Step 3: Implement** `previews.py` (Pillow for swatches, playwright for SVG sheets as in `tools/logo/build.py`, the VM helper for cursors).
- [ ] **Step 4: Run to verify:** tests pass; run on the real extraction and spot-check one of each kind by eye.
- [ ] **Step 5: Commit** `feat: brand art previews (svg sheets, color schemes, cursors, sounds)`.

### Task 3: Local server with a safe comment store and export

**Files:**
- Create: `tools/brandart/serve.py`, `tools/brandart/run.sh`, `tools/brandart/tests/test_serve.py`

**Interfaces:**
- Consumes: `out/brandart/inventory.json` and `assets/`.
- Produces: `serve.py [--dir out/brandart] [--port N]` binds `127.0.0.1` (random free port by default), prints the URL, and serves the page and assets. API: `GET /api/inventory`; `GET /api/state` returns `{"direction": str, "items": {id: {"verdict": "keep|redraw|drop|variant", "priority": "must|should|nice", "comment": str}}, "groups": {id: {"comment": str}}, "custom": [{"id", "title", "comment"}]}`; `PUT /api/state` replaces the state atomically (validates shape, rejects unknown verdicts, keeps the previous file as `comments.json.bak`); `POST /api/export` writes `out/brandart/submission-<YYYY-MM-DD>.md` and a `submission-<date>/` folder with copies of every item whose verdict is `redraw` or `variant`, and returns the Markdown. `run.sh` starts the server and opens the browser.
- The Markdown brief: an "Overall direction" section, then per group: group comment, then per commented item a block with `id`, title, where it is seen, source path, owning package and license, size, verdict, priority and comment, then a "Custom requests" section and a summary count table. ASCII only (non-ASCII in a comment is replaced by `?` with the count noted in the footer).

- [ ] **Step 1: Write the failing tests:** state round-trips through PUT then GET; a crash simulated between the temp write and the rename leaves the old `comments.json` intact; an invalid verdict returns 400 and changes nothing; two PUTs in quick succession both land (last one wins, no corruption); export lists every commented item with the required fields and copies exactly the `redraw` and `variant` assets; export output is pure ASCII; the server refuses a non-loopback bind.
- [ ] **Step 2: Run to verify they fail.**
- [ ] **Step 3: Implement** `serve.py` on `http.server.ThreadingHTTPServer` with a lock around state writes, and `run.sh`.
- [ ] **Step 4: Run to verify:** tests pass.
- [ ] **Step 5: Commit** `feat: brand art review server (comments and export)`.

### Task 4: The review page

**Files:**
- Create: `tools/brandart/web/index.html`, `tools/brandart/web/app.js`, `tools/brandart/web/style.css`, `tools/brandart/tests/test_page.py` (playwright)

**Interfaces:**
- Consumes: the API of Task 3.
- Produces: one page with a sidebar of groups (title, item count, commented/total progress bar), a grid of cards per group with lazy-loaded previews, a background switch (light, dark, Ink, checkerboard) that applies to every preview, per card: title, "where you see it", size, owner and license badge, verdict buttons (Keep, Redraw, Drop, New variant), priority, and a comment box; a comment box per group; an "Overall direction" box at the top; an "Add a request" button that creates a custom item; filters (uncommented, redraw only, by kind) and a search box; autosave with a visible "saved" state that turns red when a save fails; an "Export submission" button showing the written path and a preview of the Markdown; keyboard shortcuts for next and previous card and for the verdict keys.

- [ ] **Step 1: Write the failing tests** (playwright against `serve.py` on a fixture inventory): the page lists every group and item; typing a comment shows "saved" and survives a reload; two tabs show each other's saved state after a reload; changing the background switch changes the preview background; the filter "uncommented" hides commented cards; "Add a request" creates an item that appears in the export; a failed save (server stopped) shows the red state and keeps the text in the box; a group with 400 fixture items renders without loading all images at once (count of loaded `img` elements stays small until scrolled).
- [ ] **Step 2: Run to verify they fail.**
- [ ] **Step 3: Implement** the page (no framework, no build step, no network requests; test that the page makes none other than to `127.0.0.1`).
- [ ] **Step 4: Run to verify:** tests pass.
- [ ] **Step 5: Commit** `feat: brand art review page`.

### Task 5: Run it on the real image and hand it to Bert

**Files:**
- Create: `docs/brand-art.md`
- Modify: `docs/roadmap.md` (new row 1.16 marked done), `docs/build-host.md` (one paragraph)

- [ ] **Step 1:** `tools/brandart/extract_in_vm.sh /d/nisse-build-vm/out/nisse-live.iso`, then `previews.py`, then `run.sh`. Take a screenshot of the page with the playwright script and read it; check three groups by eye (a logo group, the wallpapers, the color schemes).
- [ ] **Step 2:** Write `docs/brand-art.md`: what the page is, how to start it (`bash tools/brandart/run.sh`), how to regenerate after an ISO build (the ids are stable so comments stay attached), how the exported brief is meant to be used (artist brief, or fed to Claude to draw), and where the files live (`out/brandart/`, git-ignored).
- [ ] **Step 3:** Run the whole new test set and the existing suite parts that cannot be affected (host description and guard tests); push `daily`.
- [ ] **Step 4:** Tell Bert the URL command and what to do first (set "Overall direction", then go group by group); do not review the art for him.
- [ ] **Step 5: Commit** `docs: brand art review page, roadmap 1.16 done`.

---

## Self-review notes

- **Spec coverage:** every graphic in identity + desktop theme (surface list groups 1 to 9), a comment box per graphic and per group (Task 4), assemble a submission (Task 3 export), locally hosted (Task 3, Global Constraints).
- **Rulings the executor settles and ledgers:** the exact Plymouth, Plasma login and lock-screen paths in the Fedora 44 image (Task 1 finds them; any surface with no file becomes a `missing` request), the curated core icon list (about 150 names, start from the Plasma System Tray, Dolphin and System Settings icon names), whether `xcur2png` is available in the VM or cursors stay listed without frames, and the exact verdict labels if Bert dislikes them.
- **Not in this plan:** drawing any art, replacing any graphic in the image (the branding foundations plan does the placeholder replacement), the Ember palette, and any change to the ISO.
