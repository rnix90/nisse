#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Checks the built nisse-avatars RPM (N-406a). Run in the Fedora build VM after: tools/rpm/build-rpm.sh nisse-avatars
# The replace script is also run against a temporary tree, which stands in for a machine where the Konqi pictures were just
# installed by their own packages. The real trigger is checked on the ISO (tests/iso/test_iso_contents.sh).
set -euo pipefail
cd "$(dirname "$0")/../.."
fail() { echo "FAIL: $*" >&2; exit 1; }

rpmf="$(ls -v out/rpmbuild/RPMS/noarch/nisse-avatars-[0-9]*.rpm 2>/dev/null | tail -1 || true)"
[ -n "$rpmf" ] || fail "nisse-avatars RPM not found (run tools/rpm/build-rpm.sh nisse-avatars)"
files="$(rpm -qlp "$rpmf")"
has() { printf '%s\n' "$files" | grep -qxF "$1" || fail "RPM lacks $1"; }

# the 17 gnome pictures, under their own names (so they never conflict with the owner package)
n=0
while IFS=$'\t' read -r src dest; do
    case "$src" in ''|'#'*) continue ;; esac
    has "/usr/share/plasma/avatars/$dest"; n=$((n + 1))
done < assets/art/avatars/install-manifest.txt
[ "$n" = 17 ] || fail "expected 17 avatars in the manifest, found $n"
# (the replacements keep the names Plasma reads, konqi-calling.png and mascot_konqi_3rdparty.svg: only the avatar folder is checked)
if printf '%s\n' "$files" | grep '^/usr/share/plasma/avatars/' | grep -qiE 'konqi|katie'; then fail "a Konqi or Katie file is in the avatar folder"; fi

# the replacements for the files that keep their names, and the script the trigger runs
for f in fedora-loves-kde.svg mascot_konqi_3rdparty.svg konqi-calling.png; do has "/usr/share/nisse/art-replacements/$f"; done
has /usr/libexec/nisse-avatars-replace
printf '%s\n' "$files" | grep -qx '/usr/share/nisse' && fail "must not own /usr/share/nisse (nisse-release-common does)"
rpm -qp --requires "$rpmf" | grep -q 'nisse-release-common' || fail "must require nisse-release-common (owner of /usr/share/nisse)"

# the trigger: on the three folders, running the script (rpm lists them with --filetriggers)
trig="$(rpm -qp --filetriggers "$rpmf")"
grep -q 'transfiletriggerin' <<< "$trig" || fail "no file trigger"
for dir in /usr/share/plasma/avatars /usr/share/icons/hicolor/scalable/apps /usr/share/plasma/packages/org.kde.plasmasetup.finished/contents/ui; do
    grep -qF "$dir" <<< "$trig" || fail "the trigger does not watch $dir"
done
grep -q '/usr/libexec/nisse-avatars-replace' <<< "$trig" || fail "the trigger does not run the replace script"

# licences: our art is GPL-2.0-or-later, the derived sticker CC-BY-SA-4.0, with the licence text and attribution shipped
lic="$(rpm -qp --qf '%{LICENSE}' "$rpmf")"
[ "$lic" = "GPL-2.0-or-later AND CC-BY-SA-4.0" ] || fail "License is '$lic'"
printf '%s\n' "$files" | grep -qE '^/usr/share/licenses/nisse-avatars/CC-BY-SA-4.0' || fail "the CC-BY-SA-4.0 text is not shipped"
printf '%s\n' "$files" | grep -qE '^/usr/share/licenses/nisse-avatars/NOTICE' || fail "the attribution notice is not shipped"

# the replace script against a temporary tree
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
rpm2cpio "$rpmf" | (cd "$tmp" && cpio -idm --quiet)
script="$tmp/usr/libexec/nisse-avatars-replace"
[ -x "$script" ] || fail "the script is not executable"
av="$tmp/usr/share/plasma/avatars"; ic="$tmp/usr/share/icons/hicolor/scalable/apps"; ui="$tmp/usr/share/plasma/packages/org.kde.plasmasetup.finished/contents/ui"
mkdir -p "$ic" "$ui"
for f in "Artist Konqi.png" "Boss Konqi.png" "Virtual Reality Konqi.png" Konqi.png Katie.png; do printf 'konqi picture' > "$av/$f"; done
printf 'cat photo' > "$av/Cat.png"
printf 'fedora sticker' > "$ic/fedora-loves-kde.svg"; printf 'old mascot' > "$ic/mascot_konqi_3rdparty.svg"; printf 'old calling' > "$ui/konqi-calling.png"; printf 'old licence' > "$ui/konqi-calling.png.license"
printf 'other icon' > "$ic/other.svg"
listed() { for f in "$av"/*.png "$ic"/*.svg "$ui"/konqi-calling.png; do printf '%s\n' "${f#"$tmp"}"; done; }
listed | NISSE_ROOT="$tmp" "$script"
for f in "Artist Konqi.png" "Boss Konqi.png" "Virtual Reality Konqi.png" Konqi.png Katie.png; do [ ! -e "$av/$f" ] || fail "$f was not removed"; done
[ "$(cat "$av/Cat.png")" = "cat photo" ] || fail "a photo avatar was touched"
[ "$(cat "$ic/other.svg")" = "other icon" ] || fail "an unrelated icon was touched"
cmp -s "$ic/fedora-loves-kde.svg" "$tmp/usr/share/nisse/art-replacements/fedora-loves-kde.svg" || fail "the sticker was not replaced"
cmp -s "$ic/mascot_konqi_3rdparty.svg" "$tmp/usr/share/nisse/art-replacements/mascot_konqi_3rdparty.svg" || fail "the mascot picture was not replaced"
cmp -s "$ui/konqi-calling.png" "$tmp/usr/share/nisse/art-replacements/konqi-calling.png" || fail "konqi-calling.png was not replaced"
[ ! -e "$ui/konqi-calling.png.license" ] || fail "the old picture's licence file was left beside the new picture"
# running it twice changes nothing and does not fail (an update fires the trigger again)
listed | NISSE_ROOT="$tmp" "$script"
cmp -s "$ic/fedora-loves-kde.svg" "$tmp/usr/share/nisse/art-replacements/fedora-loves-kde.svg" || fail "the second run broke the sticker"

out="$(rpmlint "$rpmf" 2>&1 || true)"
echo "$out" | tail -3
errors="$(echo "$out" | grep -oE '[0-9]+ errors' | tail -1 | cut -d' ' -f1)"
[ "${errors:-0}" = "0" ] || fail "rpmlint reported $errors errors"
echo "PASS: nisse-avatars"
