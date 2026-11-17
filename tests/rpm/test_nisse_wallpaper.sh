#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Checks the built nisse-wallpaper RPM (N-407a). Run in the Fedora build VM after: tools/rpm/build-rpm.sh nisse-wallpaper
set -euo pipefail
cd "$(dirname "$0")/../.."
fail() { echo "FAIL: $*" >&2; exit 1; }

rpmf="$(ls -v out/rpmbuild/RPMS/noarch/nisse-wallpaper-[0-9]*.rpm 2>/dev/null | tail -1 || true)"
[ -n "$rpmf" ] || fail "nisse-wallpaper RPM not found (run tools/rpm/build-rpm.sh nisse-wallpaper)"
files="$(rpm -qlp "$rpmf")"
has() { printf '%s\n' "$files" | grep -qxF "$1" || fail "RPM lacks $1"; }
base=/usr/share/wallpapers/nisse
has "$base/metadata.json"
has "$base/contents/screenshot.png"
# one light and one dark picture for every size the generator makes
n=0
while read -r size; do
    has "$base/contents/images/$size.png"
    has "$base/contents/images_dark/$size.png"
    n=$((n + 1))
done < <(python3 - <<'PY'
import sys
sys.path.insert(0, "tools/art")
import wallpaper
for w, h in wallpaper.SIZES:
    print(f"{w}x{h}")
PY
)
[ "$n" -ge 15 ] || fail "expected at least 15 sizes, found $n"
printf '%s\n' "$files" | grep -qx '/usr/share/wallpapers' && fail "must not own /usr/share/wallpapers"
[ "$(rpm -qp --qf '%{LICENSE}' "$rpmf")" = "GPL-2.0-or-later" ] || fail "License must be GPL-2.0-or-later"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
rpm2cpio "$rpmf" | (cd "$tmp" && cpio -idm --quiet)
python3 - "$tmp$base" <<'PY'
import json, struct, sys
root = sys.argv[1]
meta = json.load(open(root + "/metadata.json"))
assert meta["KPlugin"]["Id"] == "nisse" and meta["KPlugin"]["Name"] == "nisse", meta
for folder in ("images", "images_dark"):
    for size in ("1920x1080", "3840x2160", "1080x1920"):
        data = open(f"{root}/contents/{folder}/{size}.png", "rb").read(32)
        assert data[:8] == b"\x89PNG\r\n\x1a\n", (folder, size)
        w, h = struct.unpack(">II", data[16:24])
        assert f"{w}x{h}" == size, (folder, size, w, h)
print("ok   metadata and the PNG sizes")
PY

out="$(rpmlint "$rpmf" 2>&1 || true)"
echo "$out" | tail -3
errors="$(echo "$out" | grep -oE '[0-9]+ errors' | tail -1 | cut -d' ' -f1)"
[ "${errors:-0}" = "0" ] || fail "rpmlint reported $errors errors"
echo "PASS: nisse-wallpaper"
