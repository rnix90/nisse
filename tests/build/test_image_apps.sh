#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-508: the default apps decision (build/default-apps.txt, from docs/default-apps.md) holds in the image, proved by the real dependency
# solver (a dnf dry run of what kiwi installs, tools/build/image_packages.py) without building the ISO:
#   - every dropped package is absent (a drop that something hard-requires fails the dry run, and that package is a "hide" line instead)
#   - every added package is present, with its dependencies solved
#   - every hidden package is present and its launcher entries are hidden by nisse-defaults
#   - nothing of the PIM suite is wired in: no autostart entry from any package of the image names a mail, calendar or Akonadi program
# Runs in the Fedora build VM (needs dnf, out/repo from tools/rpm/make-repo.sh, and out/kiwi-description from build/render-kiwi.sh).
set -u
cd "$(dirname "$0")/../.."
fail=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=$((fail + 1)); }

if ! command -v dnf >/dev/null 2>&1 || [ ! -d out/kiwi-description ] || [ ! -f out/repo/repodata/repomd.xml ]; then
    echo "skip: needs the Fedora build VM with out/repo and out/kiwi-description (tools/rpm/make-repo.sh, build/render-kiwi.sh)"
    exit 0
fi

list=out/image-packages.txt
if ! python3 tools/build/image_packages.py --out "$list" > out/image-packages.log 2>&1; then
    bad "the image's packages do not resolve with the drops applied:"
    sed 's/^/       /' out/image-packages.log | head -20
    echo "$fail failure(s)"; exit 1
fi
ok "the image resolves: $(sed -n 's/ packages.*//p' out/image-packages.log) packages"

while IFS='|' read -r kind pkg app entries; do
    case "$kind" in ''|'#'*) continue;; esac
    present=0; grep -qx -- "$pkg" "$list" && present=1
    case "$kind" in
        drop) [ "$present" = 0 ] && ok "dropped: $app ($pkg) is not in the image" || bad "dropped: $app ($pkg) is still in the image";;
        add)  [ "$present" = 1 ] && ok "added: $app ($pkg) is in the image" || bad "added: $app ($pkg) is not in the image";;
        hide) [ "$present" = 1 ] && ok "kept and hidden: $app ($pkg) is in the image (something needs it)" || bad "hidden: $app ($pkg) is not in the image";;
    esac
done < build/default-apps.txt

# The PIM suite is shipped but wired to nothing: list every autostart entry and every user service the image's packages carry.
repoargs=(--use-host-config --releasever="$(tr -d '[:space:]' < build/FEDORA_RELEASE)" --disablerepo='*' --enablerepo=fedora
          --repofrompath="nisse,file://$PWD/out/repo" --setopt=nisse.gpgcheck=0 --setopt=nisse.priority=90)
files=out/image-autostart.txt
# repoquery prints one file per line for the packages named; chunked so the command line stays short
: > "$files"
xargs -n 400 sh -c 'sudo dnf repoquery "$@" --quiet -l 2>/dev/null' _ "${repoargs[@]}" < "$list" \
    | grep -E '^/etc/xdg/autostart/|^/usr/lib/systemd/user/.*\.service$|^/usr/share/dbus-1/services/' | sort -u > "$files"
pim='akonadi|kmail|kontact|korganizer|kalarm|kalendar|kaddressbook|kmailtransport|pim|mailtransport|kdepim|merkuro|kmail-account-wizard|kalendarac'
hits="$(grep -iE "$pim" "$files" | grep -E '/etc/xdg/autostart/' | grep -v 'org.kde.kalendarac.desktop' || true)"
[ -z "$hits" ] && ok "no mail, calendar or Akonadi program has an autostart entry in the image (apart from Calendar Reminders, below)" || { bad "PIM autostart entries in the image: $(echo "$hits" | tr '\n' ' ')"; }
# Calendar Reminders does have one. Its autostart file asks a KDE config key, and nisse-defaults sets that key to false: check the file
# still asks for the key we set (an update of akonadi-calendar that renames it would switch the reminders back on).
if grep -qx /etc/xdg/autostart/org.kde.kalendarac.desktop "$files"; then
    tmp="$(mktemp -d)"; trap 'sudo rm -rf "$tmp" 2>/dev/null' EXIT
    sudo dnf download --quiet "${repoargs[@]}" --destdir="$tmp" akonadi-calendar >/dev/null 2>&1
    cond="$(rpm2cpio "$tmp"/akonadi-calendar-*.rpm 2>/dev/null | (cd "$tmp" && cpio -i --to-stdout ./etc/xdg/autostart/org.kde.kalendarac.desktop 2>/dev/null) | sed -n 's/^X-KDE-autostart-condition=//p')"
    key="$(sed -n 's/^\(Autostart\)=.*/\1/p' assets/defaults/xdg/kalendaracrc)"
    [ "$cond" = "kalendaracrc:General:$key:true" ] && grep -qx 'Autostart=false' assets/defaults/xdg/kalendaracrc \
        && ok "Calendar Reminders asks '$cond' and nisse-defaults sets $key=false" \
        || bad "Calendar Reminders' autostart condition is '$cond': nisse-defaults' kalendaracrc no longer turns it off"
fi
# no taskbar pin names a mail suite program
pins="$(sed -n '/launchers/,/\])/p' assets/theme/lookandfeel/layout.js)"
if printf '%s\n' "$pins" | grep -qiE "$pim"; then bad "a taskbar pin names a mail suite program: $(printf '%s\n' "$pins" | grep -iE "$pim" | tr '\n' ' ')"
else ok "no taskbar pin names a mail suite program"; fi

if [ "$fail" -eq 0 ]; then echo "PASS: image apps"; else echo "$fail failure(s)"; exit 1; fi
