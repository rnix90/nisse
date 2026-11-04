#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Proves tests/e2e/check_start_button.py can tell the Fedora hot dog, an empty panel and the Nisse mark apart, using the
# real hot dog crop in tests/e2e/fixtures and a synthetic Nisse tile. Needs Pillow; runs on the host.
set -u
cd "$(dirname "$0")/../.."
py="$(command -v python3 || command -v python)"
fail=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=$((fail + 1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
"$py" - "$tmp" <<'PYEOF'
import sys
from PIL import Image

out = sys.argv[1]
PANEL = (31, 36, 60)   # the live session's panel colour
REGION = (12, 750)


def screen():
    img = Image.new("RGB", (1280, 800), (60, 90, 160))
    img.paste(Image.new("RGB", (1280, 54), PANEL), (0, 746))
    return img


hot = screen()
hot.paste(Image.open("tests/e2e/fixtures/start-button-placeholder.png").convert("RGB"), REGION)
hot.save(f"{out}/hotdog.png")

empty = screen()
empty.save(f"{out}/empty.png")

nisse = screen()
tile = Image.open("assets/logo/png/nisse-app-tile-256.png").convert("RGBA").resize((36, 36), Image.LANCZOS)
nisse.paste(tile, (REGION[0] + 6, REGION[1] + 4), tile)
nisse.save(f"{out}/nisse.png")
PYEOF

"$py" tests/e2e/check_start_button.py "$tmp/hotdog.png" >"$tmp/o1" 2>&1; rc=$?
[ "$rc" -eq 1 ] && grep -q "hot dog" "$tmp/o1" && ok "the Fedora hot dog is rejected" || bad "the hot dog was not rejected (exit $rc): $(cat "$tmp/o1")"
"$py" tests/e2e/check_start_button.py "$tmp/empty.png" >"$tmp/o2" 2>&1; rc=$?
[ "$rc" -eq 1 ] && grep -q "no Nisse mark" "$tmp/o2" && ok "an empty start button is rejected" || bad "an empty start button was not rejected (exit $rc): $(cat "$tmp/o2")"
"$py" tests/e2e/check_start_button.py "$tmp/nisse.png" >"$tmp/o3" 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "the Nisse mark passes" || bad "the Nisse mark was rejected (exit $rc): $(cat "$tmp/o3")"
echo "hot dog: $(head -1 "$tmp/o1"); nisse: $(head -1 "$tmp/o3")"

if [ "$fail" -eq 0 ]; then echo "PASS: start button check"; else echo "$fail failure(s)"; exit 1; fi
