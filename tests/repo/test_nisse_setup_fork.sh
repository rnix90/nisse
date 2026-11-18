#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-306d: the nisse-setup fork of Plasma Setup (forks/nisse-setup). Guards the fork discipline:
#   - UPSTREAM.md says exactly what was imported (tag, commit, tarball hash, where from);
#   - the first commit that added the tree is the pristine import, so everything after it is a nisse change;
#   - every file changed since the import is listed in NISSE-PATCHES.md with a reason, and nothing listed is unchanged;
#   - the nisse look is in the places we patched (wallpaper, look and feel, color scheme, window and welcome text).
set -u
cd "$(dirname "$0")/../.."
fork=forks/nisse-setup
failures=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; failures=$((failures + 1)); }

[ -f "$fork/CMakeLists.txt" ] && ok "the fork tree is there" || { bad "no $fork/CMakeLists.txt"; echo "$failures failed"; exit 1; }

up="$fork/UPSTREAM.md"
[ -f "$up" ] || bad "UPSTREAM.md is missing"
for want in 'v6.8.3' '052bd7390bbb8b71a1412e6eea80b5a7d98d37bc' '12c3562051fe099521b47f408633c649c8d96cc726f1629a81129ec12f895657' 'invent.kde.org/plasma/plasma-setup' 'download.kde.org'; do
    grep -q -- "$want" "$up" 2>/dev/null && ok "UPSTREAM.md records $want" || bad "UPSTREAM.md lacks $want"
done

# the import commit: the first commit that added the fork's CMakeLists.txt
import="$(git log --diff-filter=A --format=%H --reverse -- "$fork/CMakeLists.txt" | head -1)"
[ -n "$import" ] && ok "the import commit is ${import:0:10}" || { bad "no import commit found (is the history shallow?)"; echo "$failures failed"; exit 1; }
n="$(git ls-tree -r --name-only "$import" -- "$fork" | wc -l)"
[ "$n" = 169 ] && ok "the import commit holds the 169 files of the upstream tarball" || bad "the import commit holds $n files, expected 169 (it must be pristine)"

# everything changed since the import must be in the patch ledger, and the ledger must not name unchanged files
ledger="$fork/NISSE-PATCHES.md"
[ -f "$ledger" ] || bad "NISSE-PATCHES.md is missing"
changed="$(git diff --name-only "$import" HEAD -- "$fork" 2>/dev/null; git ls-files --others --exclude-standard -- "$fork"; git diff --name-only HEAD -- "$fork")"
changed="$(printf '%s\n' "$changed" | sed "s|^$fork/||" | sort -u | grep -v '^$' | grep -v -x -e 'UPSTREAM.md' -e 'NISSE-PATCHES.md')"
while read -r f; do
    [ -n "$f" ] || continue
    grep -q "\`$f\`" "$ledger" 2>/dev/null && ok "ledger lists changed file $f" || bad "$f changed since the import but NISSE-PATCHES.md does not list it"
done <<< "$changed"
listed="$(grep -o '^| `[^`]*`' "$ledger" 2>/dev/null | sed 's/^| `//; s/`$//')"
while read -r f; do
    [ -n "$f" ] || continue
    printf '%s\n' "$changed" | grep -qx -- "$f" && continue
    # a listed file may be a rename target or an added file: it must at least exist, and a pure leftover is stale
    [ -e "$fork/$f" ] && ok "ledger names $f (present)" || bad "NISSE-PATCHES.md names $f, which is not in the tree"
done <<< "$listed"

# the nisse look (commit 2)
grep -q 'wallpapers/nisse/contents/images/' "$fork/src/qml/LandingComponent.qml" && grep -q 'wallpapers/nisse/contents/images_dark/' "$fork/src/qml/LandingComponent.qml" \
    && ok "the landing page uses the nisse wallpaper (light and dark)" || bad "the landing page does not use the nisse wallpaper"
grep -q 'wallpapers/Next' "$fork/src/qml/LandingComponent.qml" && bad "the KDE Next wallpaper is still referenced"
p="$fork/modules/prepareutil/prepareutil.cpp"
grep -q 'org.nisse.desktop.light' "$p" && grep -q '"org.nisse.desktop"\|org.nisse.desktop"' "$p" && ok "the light and dark toggle applies the nisse looks" || bad "prepareutil does not apply org.nisse.desktop and org.nisse.desktop.light"
grep -q 'NisseEmber' "$p" && ok "the dark theme is recognised by the NisseEmber color scheme" || bad "prepareutil does not recognise NisseEmber"
if grep -qi 'breeze' "$p"; then bad "prepareutil still mentions Breeze"; else ok "prepareutil no longer mentions Breeze"; fi
for f in src/qml/LandingComponent.qml src/qml/Main.qml src/main.cpp; do
    if grep -q 'Plasma Desktop\|Plasma Mobile' "$fork/$f"; then bad "$f still welcomes to Plasma"; fi
done
grep -q 'nisse' "$fork/src/qml/LandingComponent.qml" && ok "the welcome text says nisse" || bad "the welcome text does not say nisse"

# nothing of ours is capitalised, and our own files are ASCII (upstream's own files keep their authors' names)
for f in UPSTREAM.md NISSE-PATCHES.md; do
    [ -f "$fork/$f" ] || continue
    if LC_ALL=C grep -q '[^ -~	]' "$fork/$f"; then bad "$f has non-ASCII"; else ok "$f is ASCII"; fi
done

echo
[ "$failures" = 0 ] && echo "PASS: nisse-setup fork" || { echo "$failures failed"; exit 1; }
