#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Inspect a built nisse live ISO (kiwi layout: /LiveOS/squashfs.img is an EROFS image holding the root filesystem;
# see docs/kiwi-spike.md). Run in the Fedora build VM:
#   tests/iso/test_iso_contents.sh out/nisse-live.iso
set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
iso="${1:?usage: test_iso_contents.sh ISO}"
[ -f "$iso" ] || fail "ISO not found: $iso"

# The volume id comes from the kiwi description, but a wrapper or a set-type-attr option could override it, so read it
# from the ISO itself.
fedora_base="$(tr -d '[:space:]' < "$(dirname "$0")/../../build/FEDORA_RELEASE")"
release="$(tr -d '[:space:]' < "$(dirname "$0")/../../build/PRODUCT_VERSION")"   # nisse's own version, not the Fedora base
xorriso -indev "$iso" -pvd_info 2>/dev/null | grep -q "^Volume Id *: *nisse-$release\$" \
    || fail "the ISO volume id is not nisse-$release"
# The boot menu finds the ISO by this label: it must match the volume id, and nothing may still say the Fedora base.
cfgs="$(mktemp -d)"
xorriso -osirrox on -indev "$iso" -extract /EFI/BOOT "$cfgs/efi" >/dev/null 2>&1
xorriso -osirrox on -indev "$iso" -extract /boot/grub2 "$cfgs/grub2" >/dev/null 2>&1
grep -rqh "root=live:CDLABEL=nisse-$release " "$cfgs" || { rm -rf "$cfgs"; fail "the boot menu does not boot from CDLABEL=nisse-$release"; }
if grep -rqh -E "nisse[- ]$fedora_base" "$cfgs"; then rm -rf "$cfgs"; fail "the boot menu still names the Fedora base ($fedora_base) as nisse's version"; fi
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
[ -d "$root/usr/share/fonts/fira-code" ] || fail "Fira Code font directory missing (the nisse monospace font, ledger N-101)"
[ -d "$root/usr/share/fonts/typetogether-literata-fonts" ] || fail "Literata font directory missing (the nisse document font, ledger N-101)"
for scheme in NisseEmber NisseEmberLight; do
    [ -f "$root/usr/share/color-schemes/$scheme.colors" ] || fail "Plasma color scheme $scheme is missing (nisse-theme)"
done
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

# Presets: every unit the nisse presets enable must be enabled once the image applies its presets. The static image only
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
if rpmq -q fedora-release-kde >/dev/null 2>&1; then fail "fedora-release-kde is installed (nisse must use nisse-release)"; fi
rpmq -q nisse-release >/dev/null 2>&1 || fail "nisse-release is not installed"

# Fedora's placeholder art (generic-logos: the hot dog on the start button, About page and installer) must be gone, and
# every path it owned must be either replaced by nisse-branding or deliberately dropped (tests/rpm/placeholder-paths.txt).
for pkg in generic-logos fedora-logos; do
    if rpmq -q "$pkg" >/dev/null 2>&1; then fail "$pkg is installed: Fedora's placeholder art is in the image"; fi
done
manifest="$(dirname "$0")/../rpm/placeholder-paths.txt"
replaced=0
while read -r kind path sha spec; do
    owner="$(rpmq -qf "$path" 2>/dev/null)" || fail "the replacement for $path is missing from the image"
    case "$owner" in nisse-branding-*) ;; *) fail "$path is owned by $owner, not nisse-branding" ;; esac
    if [ "$sha" != symlink ]; then
        [ -f "$root$path" ] || fail "$path is not a file in the image"
        now="$(sudo sha256sum "$root$path" | cut -c1-16)"
        [ "$now" != "$sha" ] || fail "$path is still Fedora's placeholder (sha256 $sha)"
    fi
    replaced=$((replaced + 1))
done < <(grep '^R ' "$manifest")
while read -r kind path sha reason; do
    [ ! -e "$root$path" ] || fail "$path (dropped placeholder: $reason) is still in the image"
done < <(grep '^D ' "$manifest")
# The About page's picture is whatever kde-settings' kcm-about-distrorc names, and the start button's icon is `start-here`
# (Fedora's look-and-feel setup script): both must resolve to nisse-branding files, whatever the Fedora packages do next.
about_logo="$(sed -n 's/^LogoPath=//p' "$root/etc/xdg/kcm-about-distrorc" 2>/dev/null | head -1)"
[ -n "$about_logo" ] || fail "no LogoPath in /etc/xdg/kcm-about-distrorc (how does the About page pick its logo?)"
case "$(rpmq -qf "$about_logo" 2>/dev/null)" in nisse-branding-*) ;; *) fail "the About page logo $about_logo is not a nisse-branding file" ;; esac
case "$(rpmq -qf /usr/share/icons/hicolor/scalable/apps/start-here.svg 2>/dev/null)" in nisse-branding-*) ;; *) fail "the start button icon start-here.svg is not a nisse-branding file" ;; esac
echo "placeholder art: $replaced paths replaced by nisse-branding, $(grep -c '^D ' "$manifest") dropped, generic-logos absent"

# The nisse global themes (ledger N-108). Fedora's look-and-feel package stays installed because plasma-workspace
# requires it at an exact version, so the test is about the DEFAULT: nisse's file is the first one the session reads,
# and it names a nisse look, whatever Fedora's kde-settings profile still says further down the search path.
for id in org.nisse.desktop org.nisse.desktop.light; do
    [ -f "$root/usr/share/plasma/look-and-feel/$id/metadata.json" ] || fail "look-and-feel $id missing from the image"
done
case "$(rpmq -qf /etc/xdg/kdeglobals 2>/dev/null)" in nisse-lookandfeel-*) ;; *) fail "/etc/xdg/kdeglobals is not owned by nisse-lookandfeel" ;; esac
grep -qx 'LookAndFeelPackage=org.nisse.desktop' "$root/etc/xdg/kdeglobals" || fail "the system default look-and-feel is not org.nisse.desktop"
grep -qx 'ColorScheme=NisseEmber' "$root/etc/xdg/kdeglobals" || fail "the system default color scheme is not NisseEmber"
grep -qE '^ *XDG_CONFIG_DIRS=/etc/xdg:/usr/share/kde-settings' "$root/etc/xdg/plasma-workspace/env/env.sh" \
    || fail "Fedora's session env no longer searches /etc/xdg before its own profile: nisse's system default would lose"
echo "look and feel: org.nisse.desktop is the system default, Fedora's profile is searched after it"

# The default panel layout (ledger N-109): both looks carry the script, and the nisse panel app it pins really exists.
for id in org.nisse.desktop org.nisse.desktop.light; do
    f="$root/usr/share/plasma/look-and-feel/$id/contents/layouts/org.kde.plasma.desktop-layout.js"
    [ -f "$f" ] || fail "$id has no default panel layout script"
    grep -q 'applications:nisse-panel.desktop' "$f" || fail "the $id layout does not pin the nisse panel app"
done
case "$(rpmq -qf /usr/share/applications/nisse-panel.desktop 2>/dev/null)" in nisse-panel-*) ;; *) fail "nisse-panel.desktop is not owned by nisse-panel" ;; esac
echo "panel layout: both looks pin the nisse panel app first"

# The approved desktop defaults (docs/defaults.md, ledger N-111). Night Light and Meta+N are ours; the rest are Fedora's
# or Plasma's values kept on purpose, so assert that Fedora's kde-settings still ships them.
prof="$root/usr/share/kde-settings/kde-profile/default/xdg"
case "$(rpmq -qf /etc/xdg/kwinrc 2>/dev/null)" in nisse-defaults-*) ;; *) fail "/etc/xdg/kwinrc is not owned by nisse-defaults" ;; esac
grep -qx 'Active=true' "$root/etc/xdg/kwinrc" || fail "Night Light is not on by default"
grep -qx 'NightTemperature=4500' "$root/etc/xdg/kwinrc" || fail "the Night Light night temperature is not 4500"
grep -qx 'SingleClick=false' "$prof/kdeglobals" || fail "Fedora no longer sets double-click (approved default 1)"
grep -qx 'loginMode=default' "$prof/ksmserverrc" || fail "Fedora no longer starts sessions empty (approved default 7)"
grep -q 'exclude folders.*=\$HOME' "$prof/baloofilerc" || fail "Fedora no longer excludes the home folder from indexing (approved default 8)"
grep -qx 'VirtualKeyboardEnabled=true' "$prof/kwinrc" || fail "Fedora no longer enables the on-screen keyboard (approved default 9)"
grep -qx 'X-KDE-Shortcuts=Meta+N' "$root/usr/share/kglobalaccel/nisse-panel.desktop" || fail "Meta+N is not the nisse panel's default shortcut"
echo "defaults: Night Light on at 4500 K, Meta+N for the panel, Fedora's kept values still in place"

# The terminal (ledger N-112): the nisse scheme and profile are in the image, and the default profile names them.
for f in /usr/share/konsole/NisseEmber.colorscheme /usr/share/konsole/Nisse.profile; do
    [ -f "$root$f" ] || fail "$f missing from the image"
done
grep -qx 'DefaultProfile=Nisse.profile' "$root/usr/share/kde-settings/kde-profile/default/xdg/konsolerc" || fail "the default Konsole profile is not Nisse.profile"
case "$(rpmq -qf /etc/xdg/konsolerc 2>/dev/null)" in konsole-part-*) ;; *) fail "/etc/xdg/konsolerc is no longer owned by konsole-part (Fedora changed where it keeps Konsole's defaults)" ;; esac
echo "terminal: the nisse scheme and profile are the Konsole default"

echo "PASS: ISO contents ($iso), Qt $qt"
