#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Checks the built nisse-sounds RPM (N-414). Run in the Fedora build VM after: tools/rpm/build-rpm.sh nisse-sounds
set -euo pipefail
cd "$(dirname "$0")/../.."
fail() { echo "FAIL: $*" >&2; exit 1; }

rpmf="$(ls -v out/rpmbuild/RPMS/noarch/nisse-sounds-[0-9]*.rpm 2>/dev/null | tail -1 || true)"
[ -n "$rpmf" ] || fail "nisse-sounds RPM not found (run tools/rpm/build-rpm.sh nisse-sounds)"
files="$(rpm -qlp "$rpmf")"
has() { printf '%s\n' "$files" | grep -qxF "$1" || fail "RPM lacks $1"; }
base=/usr/share/sounds/nisse

has "$base/index.theme"
# every name in the manifest is a file in the theme: the first is real, the rest are links to it
real=0 links=0
while read -r file first rest; do
    case "$file" in ""|"#"*) continue ;; esac
    has "$base/stereo/$first.wav"
    real=$((real + 1))
    for name in $rest; do
        has "$base/stereo/$name.wav"
        links=$((links + 1))
    done
done < assets/audio/theme/names.txt
[ "$real" -eq 6 ] || fail "expected 6 sounds, the manifest lists $real"
[ "$links" -ge 5 ] || fail "expected at least 5 extra names, the manifest lists $links"
printf '%s\n' "$files" | grep -qx '/usr/share/sounds' && fail "must not own /usr/share/sounds"
[ "$(rpm -qp --qf '%{LICENSE}' "$rpmf")" = "GPL-2.0-or-later" ] || fail "License must be GPL-2.0-or-later"
echo "ok   $real sounds and $links extra names in the theme"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
rpm2cpio "$rpmf" | (cd "$tmp" && cpio -idm --quiet)
t="$tmp$base"
grep -qx 'Name=nisse' "$t/index.theme" || fail "index.theme does not name the theme"
grep -qx 'Inherits=ocean,freedesktop' "$t/index.theme" || fail "the theme must fall back to ocean for events it does not voice"
# the names Plasma asks for resolve to a real, playable WAV (through the link where there is one)
for n in desktop-login desktop-logout audio-volume-change dialog-error dialog-error-serious dialog-error-critical \
         message-new-instant nisse-needs-you dialog-question message-attention; do
    f="$t/stereo/$n.wav"
    [ -f "$f" ] || fail "$n.wav does not resolve to a file (a broken link?)"
    [ "$(head -c 4 "$f")" = "RIFF" ] && [ "$(head -c 12 "$f" | tail -c 4)" = "WAVE" ] || fail "$n.wav is not a WAV"
    [ "$(stat -Lc %s "$f")" -gt 40000 ] || fail "$n.wav is too small to be a sound"
done
[ -L "$t/stereo/dialog-error-serious.wav" ] || fail "dialog-error-serious should be a link, not a second copy"
[ "$(readlink "$t/stereo/dialog-error-serious.wav")" = "dialog-error.wav" ] || fail "dialog-error-serious must point at dialog-error.wav"
echo "ok   every name Plasma asks for resolves to a WAV"

# the files are the approved ones, byte for byte
cmp "$t/stereo/desktop-login.wav" assets/audio/theme/login.wav || fail "the login sound differs from the approved one"
cmp "$t/stereo/audio-volume-change.wav" assets/audio/theme/volume.wav || fail "the volume tick differs from the approved one"
echo "ok   the files are the approved sounds"

out="$(rpmlint "$rpmf" 2>&1 || true)"
echo "$out" | tail -3
errors="$(echo "$out" | grep -oE '[0-9]+ errors' | tail -1 | cut -d' ' -f1)"
[ "${errors:-0}" = "0" ] || fail "rpmlint reported $errors errors"
echo "PASS: nisse-sounds"
