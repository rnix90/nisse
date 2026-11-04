#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# The Nisse replacements for Fedora's placeholder art (assets/logo/system) must be exactly what tools/logo/build_system.py
# produces, and they must cover every "R" line of tests/rpm/placeholder-paths.txt. Needs Pillow; runs on the host.
set -u
cd "$(dirname "$0")/../.."
fail=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=$((fail + 1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
py="$(command -v python3 || command -v python)"
if "$py" tools/logo/build_system.py --out "$tmp/system" >"$tmp/build.log" 2>&1; then
    ok "build_system.py runs"
    if diff -r -q assets/logo/system "$tmp/system" >"$tmp/diff.txt" 2>&1; then ok "assets/logo/system is exactly what build_system.py produces"
    else bad "assets/logo/system differs from a fresh build (re-run tools/logo/build_system.py and commit): $(head -3 "$tmp/diff.txt" | tr '\n' ' ')"; fi
else
    bad "build_system.py failed: $(tail -2 "$tmp/build.log" | tr '\n' ' ')"
fi

missing=0
while read -r kind path sha spec; do
    case "$spec" in symlink:*) continue ;; esac
    [ -f "assets/logo/system$path" ] || { bad "no artwork for $path"; missing=1; }
done < <(grep '^R ' tests/rpm/placeholder-paths.txt)
[ "$missing" = 0 ] && ok "every replaced path in tests/rpm/placeholder-paths.txt has artwork"

# nothing may be left over that the manifest does not list (a stray file would ship in the RPM)
extra="$(cd assets/logo/system && find . -type f | sed 's|^\.||' | sort | while read -r f; do grep -q "^R $f " ../../../tests/rpm/placeholder-paths.txt || echo "$f"; done)"
[ -z "$extra" ] && ok "assets/logo/system holds only listed files" || bad "unlisted files in assets/logo/system: $extra"

# The About page shows system-logo-white.png (kde-settings' /etc/xdg/kcm-about-distrorc) on a light or a dark page, and
# GTK-style dialogs show fedora-logo.png: both must be readable on any background, so they are opaque cards, not a
# lockup floating on transparency (a Paper lockup on a light page would vanish).
for f in usr/share/pixmaps/system-logo-white.png usr/share/pixmaps/fedora-logo.png; do
    res="$("$py" - "assets/logo/system/$f" <<'PYEOF'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGBA")
alpha = im.getchannel("A")
opaque = alpha.histogram()[255] / (im.width * im.height)
print("ok" if opaque >= 0.70 else "transparent %.0f%% opaque" % (opaque * 100))
PYEOF
)"
    [ "$res" = ok ] && ok "$f is an opaque card (readable on light and dark pages)" || bad "$f is not readable on every background: $res"
done

if [ "$fail" -eq 0 ]; then echo "PASS: system art"; else echo "$fail failure(s)"; exit 1; fi
