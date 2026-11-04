#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Inspect a built Nisse live ISO (kiwi layout: /LiveOS/squashfs.img is an EROFS image holding the root filesystem;
# see docs/kiwi-spike.md). Run in the Fedora build VM:
#   tests/iso/test_iso_contents.sh out/nisse-live.iso
set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
iso="${1:?usage: test_iso_contents.sh ISO}"
[ -f "$iso" ] || fail "ISO not found: $iso"

# The volume id comes from the kiwi description, but a wrapper or a set-type-attr option could override it, so read it
# from the ISO itself.
fedora_base="$(tr -d '[:space:]' < "$(dirname "$0")/../../build/FEDORA_RELEASE")"
release="$(tr -d '[:space:]' < "$(dirname "$0")/../../build/PRODUCT_VERSION")"   # Nisse's own version, not the Fedora base
xorriso -indev "$iso" -pvd_info 2>/dev/null | grep -q "^Volume Id *: *Nisse-$release\$" \
    || fail "the ISO volume id is not Nisse-$release"
# The boot menu finds the ISO by this label: it must match the volume id, and nothing may still say the Fedora base.
cfgs="$(mktemp -d)"
xorriso -osirrox on -indev "$iso" -extract /EFI/BOOT "$cfgs/efi" >/dev/null 2>&1
xorriso -osirrox on -indev "$iso" -extract /boot/grub2 "$cfgs/grub2" >/dev/null 2>&1
grep -rqh "root=live:CDLABEL=Nisse-$release " "$cfgs" || { rm -rf "$cfgs"; fail "the boot menu does not boot from CDLABEL=Nisse-$release"; }
if grep -rqh -E "Nisse[- ]$fedora_base" "$cfgs"; then rm -rf "$cfgs"; fail "the boot menu still names the Fedora base ($fedora_base) as Nisse's version"; fi
rm -rf "$cfgs"

work="$(mktemp -d)"
cleanup() { sudo umount "$work/merged" 2>/dev/null || true; sudo umount "$work/mnt" 2>/dev/null || true; sudo rm -rf "$work"; }
trap cleanup EXIT

xorriso -osirrox on -indev "$iso" -extract /LiveOS/squashfs.img "$work/root.erofs" >/dev/null 2>&1 \
    || fail "no /LiveOS/squashfs.img in the ISO"
mkdir "$work/mnt"
sudo mount -t erofs -o loop,ro "$work/root.erofs" "$work/mnt" || fail "the root image is not a mountable EROFS filesystem"
root="$work/mnt"
listing="$(sudo find "$root" -xdev -type f 2>/dev/null)"

grep -qx 'ID=nisse' "$root/usr/lib/os-release" || fail "root filesystem os-release lacks ID=nisse"
[ -d "$root/usr/share/fonts/nunito" ] || fail "Nunito font directory missing"
for prog in nisse-hwroute nisse-daemon nisse-audit-hook nisse-panel nisse-fetch-claude; do
    # a here-string, not a pipe: under pipefail, grep -q exits early and printf dies of SIGPIPE on a long listing
    grep -qE "(^|/)usr/bin/$prog$" <<< "$listing" || fail "/usr/bin/$prog is missing from the ISO"
done
if grep -E '(^|/)claude$' <<< "$listing"; then
    fail "a file named claude is inside the ISO (Claude Code must not be bundled)"
fi

# The installer hook that routes hardware at install time (Anaconda runs everything in this directory).
[ -f "$root/usr/share/anaconda/post-scripts/90-nisse-hwroute.ks" ] \
    || fail "Anaconda post-script 90-nisse-hwroute.ks is missing"

# The live session itself: livesys creates the live user and sets up autologin; without these units the ISO boots to
# a login prompt instead of the desktop (Fedora enables them through its own preset file, which nisse-release replaced).
for u in livesys.service livesys-late.service; do
    # -L, not -e: the enable symlink's target is absolute (/usr/lib/...), so -e would resolve it on the host
    [ -L "$root/etc/systemd/system/multi-user.target.wants/$u" ] || fail "$u is not enabled in the image"
done

# Presets: every unit the Nisse presets enable must be enabled once the image applies its presets. The static image only
# has the units whose package scriptlets preset them; systemd applies the rest (preset-all) at the live system's first
# boot, so simulate that on a writable overlay of the image. Units of packages that are not installed are skipped and
# listed. 80-nisse-desktop sorts first and wins.
mkdir "$work/upper" "$work/ovwork" "$work/merged"
sudo mount -t overlay overlay -o "lowerdir=$root,upperdir=$work/upper,workdir=$work/ovwork" "$work/merged" \
    || fail "cannot mount an overlay on the image"
merged="$work/merged"
sudo systemctl --root="$merged" preset-all >/dev/null 2>&1 || fail "systemctl preset-all failed on the image"
sudo systemctl --root="$merged" --global preset-all >/dev/null 2>&1 || fail "systemctl --global preset-all failed on the image"
presets="$(dirname "$0")/../../packaging/rpm/nisse-release"
disabled_by_nisse="$(sed -n 's/^disable \([^*]*\)$/\1/p' "$presets/80-nisse-desktop.preset")"
skipped=""; checked=0
while read -r unit; do
    grep -qxF "$unit" <<< "$disabled_by_nisse" && continue
    if [ ! -e "$root/usr/lib/systemd/system/$unit" ]; then skipped="$skipped $unit"; continue; fi
    state="$(sudo systemctl --root="$merged" is-enabled "$unit" 2>/dev/null || true)"
    case "$state" in
        enabled|enabled-runtime|alias|static|indirect|generated) checked=$((checked + 1)) ;;
        *) fail "$unit is enabled by the preset but is '$state' after the image applies its presets" ;;
    esac
done < <(cat "$presets/80-nisse-desktop.preset" "$presets/85-display-manager.preset" "$presets/90-default.preset" |
         sed -n 's/^enable \([^*[:space:]]*\)$/\1/p' | sort -u)
echo "presets: $checked enabled units checked in the image; not installed, skipped:${skipped:- none}" | fold -w 150

# An SSH server is opt-in: after the presets are applied sshd must not be enabled.
ssh_state="$(sudo systemctl --root="$merged" is-enabled sshd.service 2>/dev/null || true)"
case "$ssh_state" in
    enabled|enabled-runtime) fail "sshd.service is enabled by default in the image" ;;
esac

# The same for the user preset (a desktop session's PipeWire, WirePlumber, xdg-user-dirs): --global reads the user units.
for unit in wireplumber.service pipewire-pulse.socket xdg-user-dirs.service; do
    [ -e "$root/usr/lib/systemd/user/$unit" ] || fail "user unit $unit is not installed in the image"
    state="$(sudo systemctl --root="$merged" --global is-enabled "$unit" 2>/dev/null || true)"
    [ "$state" = enabled ] || fail "user unit $unit is '$state' in the image, expected enabled"
done

# Package database checks: the release-repo-only decision (Qt 6.10) and Fedora's KDE release package is gone.
rpmq() { rpm --dbpath "$root/usr/lib/sysimage/rpm" "$@"; }
qt="$(rpmq -q --qf '%{version}' qt6-qtbase 2>/dev/null)" || fail "qt6-qtbase is not installed in the image"
case "$qt" in 6.10*) ;; *) fail "qt6-qtbase is $qt, expected 6.10.x (release repo only, no updates)";; esac
if rpmq -q fedora-release-kde >/dev/null 2>&1; then fail "fedora-release-kde is installed (Nisse must use nisse-release)"; fi
rpmq -q nisse-release >/dev/null 2>&1 || fail "nisse-release is not installed"

echo "PASS: ISO contents ($iso), Qt $qt"
