#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Inspect a built nisse live ISO (kiwi layout: /LiveOS/squashfs.img is an EROFS image holding the root filesystem;
# see docs/kiwi-spike.md). Run in the Fedora build VM:
#   tests/iso/test_iso_contents.sh out/nisse-live.iso
set -euo pipefail

failures=0
# NISSE_KEEP_GOING=1 lists every failure in one pass (a rebuild-and-rerun cycle is slow); the default stops at the first.
fail() { echo "FAIL: $*" >&2; if [ "${NISSE_KEEP_GOING:-}" = 1 ]; then failures=$((failures + 1)); return 0; fi; exit 1; }
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
# a query against the image's own package database (defined here, before the first block that uses it: the N-415a block once
# called it before it existed, and nothing noticed until the first rebuild that ran the test)
rpmq() { rpm --dbpath "$root/usr/lib/sysimage/rpm" "$@"; }

grep -qx 'ID=nisse' "$root/usr/lib/os-release" || fail "root filesystem os-release lacks ID=nisse"
[ -d "$root/usr/share/fonts/nunito" ] || fail "Nunito font directory missing"
[ -d "$root/usr/share/fonts/fira-code" ] || fail "Fira Code font directory missing (the nisse monospace font, ledger N-101)"
[ -d "$root/usr/share/fonts/typetogether-literata-fonts" ] || fail "Literata font directory missing (the nisse document font, ledger N-101)"
for scheme in NisseEmber NisseEmberLight; do
    [ -f "$root/usr/share/color-schemes/$scheme.colors" ] || fail "Plasma color scheme $scheme is missing (nisse-theme)"
done
for prog in nisse-hwroute nisse-daemon nisse-audit-hook nisse-guard-hook nisse-panel nisse-fetch-claude pw-dump; do
    # a here-string, not a pipe: under pipefail, grep -q exits early and printf dies of SIGPIPE on a long listing
    grep -qE "(^|/)usr/bin/$prog$" <<< "$listing" || fail "/usr/bin/$prog is missing from the ISO"
done
# GATE 2 (N-219): what the AI core installs. The daemon's hooks and settings, the machine-wide audit hook (terminal sessions,
# N-226), the protocol schema (N-220) and the pieces the panel needs (pw-dump for the microphone check, N-205).
for f in /usr/share/nisse/claude-settings.json /usr/share/nisse/daemon-protocol.schema.json /etc/claude-code/managed-settings.json          /usr/lib/systemd/user/nisse-daemon.service /usr/share/dbus-1/services/org.nisse.Daemon1.service; do
    [ -f "$root$f" ] || fail "$f is missing from the ISO (the AI core)"
done
python3 - "$root/etc/claude-code/managed-settings.json" "$root/usr/share/nisse/claude-settings.json" "$root/usr/share/nisse/daemon-protocol.schema.json" <<'PY' || fail "the AI core settings in the ISO are not what N-204, N-226 and N-220 say"
import json, sys
managed, daemon, schema = (json.load(open(p)) for p in sys.argv[1:4])
assert set(managed) == {"hooks"}, "managed settings hold only hooks"
for e in ("PreToolUse", "PostToolUse"):
    cmds = [h["command"] for g in managed["hooks"][e] for h in g["hooks"]]
    assert cmds[0] == "/usr/bin/nisse-audit-hook --managed", cmds   # N-306b added the turn snapshot hook after it on PreToolUse
assert {e: [h["command"] for g in managed["hooks"][e] for h in g["hooks"]] for e in ("UserPromptSubmit", "Stop")} == {
    "UserPromptSubmit": ["/usr/bin/nisse-turn-hook"], "Stop": ["/usr/bin/nisse-turn-hook"]}
pre = [h for g in daemon["hooks"]["PreToolUse"] for h in g["hooks"]]
assert any(h["command"] == "/usr/bin/nisse-guard-hook" and h["timeout"] >= 1200 for h in pre), "the guardrail hold is in the daemon settings"
assert {"Session", "Approval", "AuditRecord", "Event", "EventsPage", "Device", "SignedRequest"} <= set(schema["definitions"])
PY
if grep -E '(^|/)claude$' <<< "$listing"; then
    fail "a file named claude is inside the ISO (Claude Code must not be bundled)"
fi

# The installer hook that routes hardware at install time (Anaconda runs everything in this directory).
[ -f "$root/usr/share/anaconda/post-scripts/90-nisse-hwroute.ks" ] \
    || fail "Anaconda post-script 90-nisse-hwroute.ks is missing"

# The Anaconda profile for ID=nisse (N-304). Anaconda matches profiles on the os-release ID only; without this file the
# installer fell back to LVM and an EFI directory called "default", and the boot loader step failed (N-303 finding).
prof="$root/etc/anaconda/profile.d/nisse.conf"
[ -f "$prof" ] || fail "the Anaconda profile /etc/anaconda/profile.d/nisse.conf is missing (N-304)"
grep -qx 'os_id = nisse' "$prof" || fail "the nisse profile must detect os_id = nisse"
grep -qx 'default_scheme = BTRFS' "$prof" || fail "the nisse profile must select BTRFS"
grep -qx 'ID=nisse' "$root/etc/os-release" || fail "os-release ID is not nisse (the profile is matched on it)"

# The Konqi pictures of other packages are gnome pictures (N-406a). The nisse-avatars file trigger removes the Konqi and Katie
# user pictures and replaces three pictures that keep their names; it must have fired when the image was built.
av="$root/usr/share/plasma/avatars"
ls "$av" | grep -qiE 'konqi|katie' && fail "a Konqi or Katie user picture is still in the image: $(ls "$av" | grep -iE 'konqi|katie' | head -3 | tr '\n' ',')"
gnomes="$(ls "$av" | grep -c ' gnome\.png$' || true)"
[ "$gnomes" -ge 16 ] || fail "expected the 16 activity gnome pictures in $av, found $gnomes"
[ -f "$av/nisse.png" ] || fail "the plain gnome user picture nisse.png is missing"
[ -d "$av/photos" ] || fail "the photo avatars were removed"
rep="$root/usr/share/nisse/art-replacements"
# (the "Fedora loves KDE" sticker, fedora-loves-kde.svg, came from plasma-welcome-fedora, which went with the Welcome Center in N-508)
[ ! -e "$root/usr/share/icons/hicolor/scalable/apps/fedora-loves-kde.svg" ] || fail "fedora-loves-kde.svg is in the image: plasma-welcome-fedora should be gone (N-508)"
for pair in "usr/share/icons/hicolor/scalable/apps/mascot_konqi_3rdparty.svg:mascot_konqi_3rdparty.svg" \
            "usr/share/plasma/packages/org.kde.plasmasetup.finished/contents/ui/konqi-calling.png:konqi-calling.png"; do
    cmp -s "$root/${pair%%:*}" "$rep/${pair##*:}" || fail "${pair%%:*} is not the nisse replacement (the nisse-avatars trigger did not run)"
done
[ ! -e "$root/usr/share/plasma/packages/org.kde.plasmasetup.finished/contents/ui/konqi-calling.png.license" ] \
    || fail "the old konqi-calling.png licence file is still beside the new picture"

# The nisse wallpaper (N-407a): installed with a light and a dark picture for each size, and the default in both looks.
wp="$root/usr/share/wallpapers/nisse"
[ -f "$wp/metadata.json" ] || fail "the nisse wallpaper is missing ($wp)"
[ -f "$wp/contents/images/1920x1080.png" ] && [ -f "$wp/contents/images_dark/1920x1080.png" ] \
    || fail "the nisse wallpaper lacks its light or dark 1920x1080 picture"
for laf in org.nisse.desktop org.nisse.desktop.light; do
    awk '$0=="[Wallpaper]"{s=1;next} /^\[/{s=0} s&&$1=="Image=nisse"{f=1} END{exit !f}' "$root/usr/share/plasma/look-and-feel/$laf/contents/defaults" \
        || fail "$laf does not default to the nisse wallpaper (Image=nisse under [Wallpaper])"
done

# The login screen (N-503): Plasma Login Manager's distro defaults name the nisse wallpaper (its greeter already takes the colors, the font
# and the icons from /etc/xdg/kdeglobals). The display manager itself is enabled by nisse-release's preset.
lg="$root/usr/lib/plasmalogin/defaults.conf"
[ -f "$lg" ] || fail "the login screen default is missing (/usr/lib/plasmalogin/defaults.conf)"
awk '$0=="[Greeter][Wallpaper][org.kde.image][General]"{s=1;next} /^\[/{s=0} s&&$1=="Image=file:///usr/share/wallpapers/nisse"{f=1} END{exit !f}' "$lg"     || fail "the login screen does not default to the nisse wallpaper"
if rpmq -q kde-settings-plasmalogin >/dev/null 2>&1; then fail "kde-settings-plasmalogin is installed (it ships Fedora's login wallpaper at the same path)"; fi
[ -f "$root/usr/libexec/plasma-login-greeter" ] || fail "the image has no Plasma Login greeter (the login screen the nisse wallpaper is for)"
echo "ok   the login screen defaults to the nisse wallpaper"

# The lock screen and the logout screen (N-504): the lock screen's layout is plasma-desktop's, so only its wallpaper is nisse's (a system
# default); the logout screen is nisse's own copy in both looks.
lk="$root/etc/xdg/kscreenlockerrc"
[ -f "$lk" ] || fail "the lock screen default is missing (/etc/xdg/kscreenlockerrc)"
awk '$0=="[Greeter][Wallpaper][org.kde.image][General]"{s=1;next} /^\[/{s=0} s&&$1=="Image=file:///usr/share/wallpapers/nisse"{f=1} END{exit !f}' "$lk" || fail "the lock screen does not default to the nisse wallpaper"
for laf in org.nisse.desktop org.nisse.desktop.light; do
    for f in Logout.qml LogoutButton.qml timer.js; do
        [ -f "$root/usr/share/plasma/look-and-feel/$laf/contents/logout/$f" ] || fail "$laf has no contents/logout/$f (nisse's logout screen)"
    done
done
echo "ok   the lock screen defaults to the nisse wallpaper and both looks carry nisse's logout screen"

# The Plasma splash (N-505): both looks carry nisse's own (the n and the comet ring) and name it, and so does the system default; Breeze's (with
# "Plasma made by KDE" and the KDE logo) is not what either look uses.
for laf in org.nisse.desktop org.nisse.desktop.light; do
    for f in Splash.qml images/n.svg images/comet.svg; do
        [ -f "$root/usr/share/plasma/look-and-feel/$laf/contents/splash/$f" ] || fail "$laf has no contents/splash/$f (nisse's splash)"
    done
    awk '$0=="[ksplashrc][KSplash]"{s=1;next} /^\[/{s=0} s&&$1=="Theme=" want{f=1} END{exit !f}' want="$laf" "$root/usr/share/plasma/look-and-feel/$laf/contents/defaults"         || fail "$laf does not name its own splash (Theme=$laf under [ksplashrc][KSplash])"
done
grep -qx 'Theme=org.nisse.desktop' "$root/etc/xdg/ksplashrc" || fail "the system default does not name nisse's splash (/etc/xdg/ksplashrc)"
echo "ok   both looks and the system default use nisse's splash"

# The default apps (N-508, build/default-apps.txt, docs/default-apps.md): every dropped package is out of the image and its launcher
# entries with it, every added one is in, a hidden one is in but its entry says NoDisplay=true, and the mail suite is wired to nothing.
# tests/build/test_image_apps.sh proves the same from the dependency solver before the ISO is built; this is the image itself.
pkgs="$(rpm --root "$root" -qa --qf '%{NAME}\n' 2>/dev/null | sort -u)"
[ -n "$pkgs" ] || fail "could not read the package list of the image (rpm --root)"
apps_n=0
while IFS='|' read -r kind pkg app entries; do
    case "$kind" in ""|"#"*) continue ;; esac
    has=0; printf '%s\n' "$pkgs" | grep -qx -- "$pkg" && has=1
    case "$kind" in
        drop) [ "$has" = 0 ] || fail "$app ($pkg) is dropped (N-508) but is in the image"
              for e in $entries; do [ ! -e "$root/usr/share/applications/$e" ] || fail "the launcher entry $e of the dropped $app is in the image"; done;;
        add)  [ "$has" = 1 ] || fail "$app ($pkg) is an addition (N-508) but is not in the image"
              for e in $entries; do [ -f "$root/usr/share/applications/$e" ] || fail "$app is in the image without its launcher entry $e"; done;;
        hide) [ "$has" = 1 ] || fail "$app ($pkg) should stay in the image, hidden (N-508)"
              for e in $entries; do grep -qx 'NoDisplay=true' "$root/usr/share/applications/$e" || fail "the launcher entry $e is not hidden (the nisse-defaults file trigger did not run)"; done;;
    esac
    apps_n=$((apps_n + 1))
done < "$(dirname "$0")/../../build/default-apps.txt"
# the mail suite's one autostart is turned off by the system default, and nothing else of it autostarts
awk '$0=="[General]"{s=1;next} /^\[/{s=0} s&&$1=="Autostart=false"{f=1} END{exit !f}' "$root/etc/xdg/kalendaracrc" || fail "/etc/xdg/kalendaracrc does not turn Calendar Reminders off (N-508)"
pim_auto="$(ls "$root/etc/xdg/autostart" | grep -iE 'akonadi|kmail|kontact|korganizer|kalarm|kaddressbook|merkuro' || true)"
[ -z "$pim_auto" ] || fail "a mail suite program has an autostart entry: $pim_auto (N-508)"
echo "ok   the default apps: $apps_n packages checked (dropped out, added in, hidden hidden), the mail suite wired to nothing"

# The default taskbar (N-508a): the layout both looks ship pins only apps that are in the image, and no browser. The pin list is read
# from the installed layout script itself, not from the repo, so it is what a new user really gets.
pin_n=0
for look in org.nisse.desktop org.nisse.desktop.light; do
    layout="$root/usr/share/plasma/look-and-feel/$look/contents/layouts/org.kde.plasma.desktop-layout.js"
    [ -f "$layout" ] || fail "$look has no panel layout in the image (N-508a)"
    pins="$(sed -n '/writeConfig("launchers"/,/\])/p' "$layout" | grep -o '"[a-z]*:[^"]*"' | tr -d '"')"
    [ -n "$pins" ] || fail "no pinned launchers found in the $look layout (N-508a)"
    for pin in $pins; do
        case "$pin" in
            applications:*) desk="${pin#applications:}" ;;
            preferred://filemanager) desk=org.kde.dolphin.desktop ;;
            *) fail "the $look layout pins $pin: not a kind of pin the default taskbar may have (no browser, N-508a)" ;;
        esac
        f="$root/usr/share/applications/$desk"
        [ -f "$f" ] || fail "the $look layout pins $pin, but the image has no $desk (N-508a)"
        if grep -q '^Categories=.*WebBrowser' "$f"; then fail "the $look layout pins a web browser: $pin (N-508a)"; fi
        grep -qx 'NoDisplay=true' "$f" && fail "the $look layout pins $pin, whose launcher is hidden (N-508a)"
        pin_n=$((pin_n + 1))
    done
done
echo "ok   the default taskbar: $pin_n pins in the two looks, each an installed app that shows, none a browser"

# Every approved art asset (N-415): the path-by-path check of the whole manifest against the image.
art_n=0
while read -r path pkg task opts; do
    case "$path" in ""|"#"*) continue ;; esac
    case "$path" in
        */)
            min="${opts#min=}"; [ -n "$opts" ] || min=1
            # a folder that is not in the image at all counts as 0 files (find fails, and under pipefail that used to end the whole
            # test silently, so every check after this one never ran)
            have="$({ find "$root$path" -type f 2>/dev/null || true; } | wc -l)"
            [ "$have" -ge "$min" ] || fail "approved art ($task, $pkg): $path has $have files in the image, expected at least $min"
            ;;
        *)
            [ -e "$root$path" ] || fail "approved art ($task, $pkg): $path is not in the image"
            [ -f "$root$path" ] || fail "approved art ($task, $pkg): $path does not resolve to a file (a broken link?)"
            ;;
    esac
    art_n=$((art_n + 1))
done < "$(dirname "$0")/../rpm/approved-art.txt"
[ "$art_n" -ge 25 ] || fail "the approved-art manifest was read as only $art_n lines"
echo "ok   $art_n approved art paths are in the image"

# The nisse sound theme (N-414): a freedesktop sound theme that falls back to ocean, selected by the system default, with the names
# Plasma 6.6 asks for (the startkde event plays desktop-login, the volume feedback audio-volume-change, error events dialog-error...).
snd="$root/usr/share/sounds/nisse"
grep -qx 'Name=nisse' "$snd/index.theme" || fail "the nisse sound theme is missing ($snd/index.theme)"
grep -qx 'Inherits=ocean,freedesktop' "$snd/index.theme" || fail "the nisse sound theme must inherit ocean and freedesktop"
for n in desktop-login desktop-logout audio-volume-change dialog-error dialog-error-serious message-new-instant nisse-needs-you; do
    [ -f "$snd/stereo/$n.wav" ] || fail "the nisse sound theme lacks $n.wav (a missing file or a broken link)"
done
[ -f "$root/usr/share/sounds/ocean/index.theme" ] || fail "the ocean sound theme the nisse theme inherits is not installed"
awk '$0=="[Sounds]"{s=1;next} /^\[/{s=0} s&&$1=="Theme=nisse"{f=1} END{exit !f}' "$root/etc/xdg/kdeglobals" \
    || fail "/etc/xdg/kdeglobals does not select the nisse sound theme (Theme=nisse under [Sounds])"
# What plays desktop-login and desktop-logout on Plasma 6.6.4 (the image's version): the notifyrc events and the programs that emit
# them (their names are UTF-16 strings in the binaries). Plasma 6.8's plasma-startupsound.service does not exist here.
nrc="$root/usr/share/knotifications6/plasma_workspace.notifyrc"
[ -f "$nrc" ] || fail "plasma_workspace.notifyrc is missing"
grep -qx 'Sound=desktop-login' "$nrc" || fail "the startkde event no longer plays desktop-login"
grep -qx 'Sound=desktop-logout' "$nrc" || fail "the exitkde event no longer plays desktop-logout"
LC_ALL=C grep -qaP 's\x00t\x00a\x00r\x00t\x00k\x00d\x00e\x00' "$root/usr/bin/plasma_session" \
    || fail "plasma_session no longer emits the startkde event: nothing would play the login sound"
LC_ALL=C grep -qaP 'e\x00x\x00i\x00t\x00k\x00d\x00e\x00' "$root/usr/bin/ksmserver" \
    || fail "ksmserver no longer emits the exitkde event: nothing would play the logout sound"

# The panel is a docked sidebar that runs from login (N-415a): the layer-shell plugin it loads at run time is in the image, and the
# login autostart starts it closed.
case "$(rpmq -q layer-shell-qt 2>/dev/null)" in layer-shell-qt-*) ;; *) fail "layer-shell-qt is not installed (the sidebar is a layer-shell surface)" ;; esac
[ -f "$root/usr/lib64/qt6/plugins/wayland-shell-integration/liblayer-shell.so" ] || fail "the layer-shell plugin is missing: the panel would open as a normal window"
grep -qx 'Exec=nisse-panel --background' "$root/etc/xdg/autostart/nisse-panel-autostart.desktop" || fail "nothing starts the panel at login (/etc/xdg/autostart/nisse-panel-autostart.desktop)"

# The nisse cursor theme (N-408): the two logo cursors replaced, everything else inherited from Breeze, and the default in both looks.
cth="$root/usr/share/icons/nisse_cursors"
grep -qx 'Inherits=breeze_cursors' "$cth/index.theme" || fail "nisse_cursors must inherit breeze_cursors"
[ -f "$cth/cursors/x-cursor" ] && [ -f "$cth/cursors/wayland-cursor" ] || fail "nisse_cursors lacks x-cursor or wayland-cursor"
[ -d "$root/usr/share/icons/breeze_cursors/cursors" ] || fail "breeze_cursors is missing (nisse_cursors inherits it)"
for laf in org.nisse.desktop org.nisse.desktop.light; do
    grep -qx 'cursorTheme=nisse_cursors' "$root/usr/share/plasma/look-and-feel/$laf/contents/defaults" \
        || fail "$laf does not default to the nisse_cursors cursor theme"
done

# The nisse icon themes (N-409): overlays on Breeze with exactly three icons, the default in both looks and the system default;
# the installer icon (anaconda) is the logo on a disk.
for t in nisse_icons:breeze nisse_icons_dark:breeze-dark; do
    d="$root/usr/share/icons/${t%%:*}"
    grep -qx "Inherits=${t##*:}" "$d/index.theme" || fail "${t%%:*} must inherit ${t##*:}"
    for f in scalable/apps/preferences-system.svg scalable/apps/utilities-terminal.svg scalable/apps/org.fedoraproject.AnacondaInstaller.svg scalable/places/start-here-kde-plasma.svg; do
        [ -f "$d/$f" ] || fail "${t%%:*} lacks $f"
    done
    [ -d "$root/usr/share/icons/${t##*:}" ] || fail "the base icon theme ${t##*:} is missing"
done
grep -qx 'Theme=nisse_icons_dark' "$root/usr/share/plasma/look-and-feel/org.nisse.desktop/contents/defaults" || fail "the dark look does not default to nisse_icons_dark"
grep -qx 'Theme=nisse_icons' "$root/usr/share/plasma/look-and-feel/org.nisse.desktop.light/contents/defaults" || fail "the light look does not default to nisse_icons"
grep -qx 'Theme=nisse_icons_dark' "$root/etc/xdg/kdeglobals" || fail "/etc/xdg/kdeglobals does not default to nisse_icons_dark"
grep -q 'id="drive"' "$root/usr/share/icons/hicolor/scalable/apps/anaconda.svg" || fail "the anaconda icon is not the logo on a disk"

# The AI panel app's icon is the three-star sparkle (N-409a), at every size; the taskbar's two nisse entries are the Start disc and it.
grep -qx 'Icon=nisse-assistant' "$root/usr/share/applications/nisse-panel.desktop" || fail "nisse-panel.desktop does not use the nisse-assistant icon"
for f in scalable/apps/nisse-assistant.svg 48x48/apps/nisse-assistant.png 16x16/apps/nisse-assistant.png 512x512/apps/nisse-assistant.png; do
    [ -f "$root/usr/share/icons/hicolor/$f" ] || fail "the assistant icon $f is missing from hicolor"
done
launchers="$(grep -v '^ *//' "$root/usr/share/plasma/look-and-feel/org.nisse.desktop/contents/layouts/org.kde.plasma.desktop-layout.js" | grep -o 'applications:[a-zA-Z.-]*\.desktop\|preferred://[a-z]*' | tr '\n' ' ')"
case "$launchers" in "applications:nisse-panel.desktop preferred://filemanager preferred://browser applications:org.kde.konsole.desktop applications:systemsettings.desktop ") ;; *) fail "the pinned taskbar launchers changed: $launchers" ;; esac

# The live desktop's Install to Hard Drive launcher (N-410): liveinst.desktop names an icon that must resolve, or the launcher shows a
# blank page. It is the working pickaxe, shipped by nisse-branding in place of fedora-logos' icon.
inst_icon="$(sed -n 's/^Icon=//p' "$root/usr/share/applications/liveinst.desktop" | head -1)"
[ -n "$inst_icon" ] || fail "liveinst.desktop names no icon"
[ -f "$root/usr/share/icons/hicolor/scalable/apps/$inst_icon.svg" ] || fail "the icon liveinst.desktop names ($inst_icon) does not exist in hicolor: the launcher would show a blank page"
grep -q 'id="pickaxe"' "$root/usr/share/icons/hicolor/scalable/apps/$inst_icon.svg" || fail "the installer launcher icon is not the working pickaxe"

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
case "$(rpmq -qf /usr/bin/pw-dump 2>/dev/null)" in pipewire-utils-*) ;; *) fail "pw-dump is not from pipewire-utils" ;; esac
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
# The installer's look (ledger N-411): cockpit takes the Anaconda WebUI's colors and logo from the folder named after os-release ID.
for f in branding.css logo.png favicon.ico apple-touch-icon.png; do
    [ -f "$root/usr/share/cockpit/branding/nisse/$f" ] || fail "the installer branding folder lacks $f"
done
grep -qx 'ID=nisse' "$root/etc/os-release" || grep -qx 'ID=nisse' "$root/usr/lib/os-release" || fail "os-release ID is not nisse, so cockpit would not pick the nisse branding folder"
grep -qF '#e0623f' "$root/usr/share/cockpit/branding/nisse/branding.css" || fail "the installer branding has no Ember"
echo "installer look: the nisse cockpit branding folder is in the image and matches the os-release ID"

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

# Rollback block 2 (ledger N-305): the snapshot package is in the image with its dnf5 hook, scripts and presets, and
# snapper plus the actions plugin it needs are there. The live image must not carry a snapper root config: the setup unit
# makes it at first boot of an installed btrfs system only.
case "$(rpmq -q nisse-snapshots 2>/dev/null)" in nisse-snapshots-*) ;; *) fail "nisse-snapshots is not installed in the image" ;; esac
for p in snapper libdnf5-plugin-actions btrfs-progs; do rpmq -q "$p" >/dev/null 2>&1 || fail "$p is not installed (nisse-snapshots needs it)"; done
for f in /usr/libexec/nisse/nisse-snapshot-hook /usr/libexec/nisse/nisse-snapshot-setup /usr/libexec/nisse/nisse-snapshot-prune /usr/libexec/nisse/nisse-snapshot-batch         /usr/share/nisse/snapshots/root.conf /etc/dnf/libdnf5-plugins/actions.d/nisse-snapshots.actions; do
    [ -f "$root$f" ] || fail "$f missing from the image"
done
[ -x "$root/usr/libexec/nisse/nisse-snapshot-hook" ] || fail "the snapshot hook is not executable"
grep -qx 'pre_transaction:::enabled=host-only:/usr/libexec/nisse/nisse-snapshot-hook pre' "$root/etc/dnf/libdnf5-plugins/actions.d/nisse-snapshots.actions" || fail "the dnf5 pre_transaction hook line is missing"
for unit in nisse-snapshot-setup.service nisse-snapshot-prune.timer snapper-cleanup.timer; do
    state="$(sudo systemctl --root="$merged" is-enabled "$unit" 2>/dev/null || true)"
    case "$state" in enabled | enabled-runtime) ;; *) fail "$unit is '$state' after the image applies its presets, expected enabled" ;; esac
done
for unit in snapper-timeline.timer snapper-boot.timer; do
    state="$(sudo systemctl --root="$merged" is-enabled "$unit" 2>/dev/null || true)"
    case "$state" in enabled | enabled-runtime) fail "$unit is enabled (nisse takes snapshots on events only)" ;; esac
done
[ -e "$root/etc/snapper/configs/root" ] && fail "the image ships a snapper root config (it must be made at first boot on the installed btrfs root)"
echo "snapshots: nisse-snapshots, snapper and the dnf5 hook are in the image; no timed snapshots; no root config until first boot"

# Boot recovery (ledger N-307): the nisse-boot package, its two GRUB snippets, units and preset are in the image, and the
# image ships no env_block-fixing result of its own (the setup service removes env_block on every boot of an installed system).
case "$(rpmq -q nisse-boot 2>/dev/null)" in nisse-boot-*) ;; *) fail "nisse-boot is not installed in the image" ;; esac
for p in grub2-tools grub2-tools-minimal; do rpmq -q "$p" >/dev/null 2>&1 || fail "$p is not installed (nisse-boot needs it)"; done
for f in /usr/bin/nisse-boot /usr/libexec/nisse/nisse-boot-setup /etc/grub.d/09_nisse_fallback /etc/grub.d/11_nisse_snapshots          /usr/lib/systemd/system/nisse-boot-setup.service /usr/lib/systemd/system/nisse-boot-sync.path /usr/lib/systemd/user/grub-boot-success.service.d/10-nisse-armed.conf; do
    sudo test -e "$root$f" || fail "$f missing from the image"   # sudo: /etc/grub.d is mode 0700
done
sudo test -x "$root/usr/bin/nisse-boot" && sudo test -x "$root/etc/grub.d/09_nisse_fallback" && sudo test -x "$root/etc/grub.d/11_nisse_snapshots" || fail "nisse-boot or a GRUB snippet is not executable"
for unit in nisse-boot-setup.service nisse-boot-sync.path; do
    state="$(sudo systemctl --root="$merged" is-enabled "$unit" 2>/dev/null || true)"
    case "$state" in enabled | enabled-runtime) ;; *) fail "$unit is '$state' after the image applies its presets, expected enabled" ;; esac
done
[ -e "$root/boot/grub2/nisse-boot.cfg" ] && fail "the image ships a snapshot menu file (it is written on an installed btrfs system)"
echo "boot recovery: nisse-boot, the GRUB snippets and the units are in the image; no snapshot menu until an installed system makes one"

# Safe-apply (ledger N-308): the update flow is in the image with what it calls, and nothing is pending in a fresh image.
case "$(rpmq -q nisse-update 2>/dev/null)" in nisse-update-*) ;; *) fail "nisse-update is not installed in the image" ;; esac
[ -x "$root/usr/bin/nisse-apply-updates" ] || fail "nisse-apply-updates is missing or not executable"
[ -e "$root/var/lib/nisse/update/state" ] && fail "the image ships an update state file (nothing may be pending in a fresh image)"
grep -q 'NISSE_SNAPSHOT_SKIP' "$root/usr/libexec/nisse/nisse-snapshot-hook" || fail "the dnf snapshot hook does not stand aside for safe-apply"
echo "safe-apply: nisse-update is in the image, the dnf hook stands aside for it, no update is pending"

# The health check (ledger N-309): the runner, its four checks and the services list are in the image and executable, and the
# unit is enabled (it does nothing unless an update waits to be verified).
for f in /usr/bin/nisse-health-check /usr/lib/nisse/health.d/10-boot /usr/lib/nisse/health.d/20-network /usr/lib/nisse/health.d/30-services /usr/lib/nisse/health.d/40-display; do
    [ -x "$root$f" ] || fail "$f is missing or not executable"
done
[ -f "$root/usr/share/nisse/health/services.d/00-core.list" ] || fail "the core service list is missing"
state="$(sudo systemctl --root="$merged" is-enabled nisse-health-check.service 2>/dev/null || true)"
case "$state" in enabled | enabled-runtime) ;; *) fail "nisse-health-check.service is '$state' after the image applies its presets, expected enabled" ;; esac
echo "health check: the runner, the four checks and the unit are in the image and enabled"

# The watchdog rollback (ledger N-310): the rollback tool, the watchdog, the notice after a rollback and the countdown notice's
# sender are in the image, the watchdog unit is enabled, the notice starts at the KDE login, and the tools it needs are there.
for f in /usr/bin/nisse-rollback /usr/bin/nisse-update-watchdog /usr/bin/nisse-update-notice /usr/bin/notify-send /usr/sbin/btrfs /usr/bin/runuser /usr/bin/loginctl; do
    [ -x "$root$f" ] || [ -x "$root/usr/bin/$(basename "$f")" ] || fail "$f is missing or not executable"
done
[ -f "$root/etc/xdg/autostart/nisse-update-notice.desktop" ] || fail "the notice after a rollback has no autostart entry"
state="$(sudo systemctl --root="$merged" is-enabled nisse-update-watchdog.service 2>/dev/null || true)"
case "$state" in enabled | enabled-runtime) ;; *) fail "nisse-update-watchdog.service is '$state' after the image applies its presets, expected enabled" ;; esac
echo "watchdog rollback: nisse-rollback, the watchdog, the after-rollback notice, notify-send and the unit are in the image, the unit is enabled"

# Undo in the panel (ledger N-311): the list command the daemon runs, the limited-mode rule that lets it run without a password box
# (and no passwordless rollback), and the guard binary that holds nisse-rollback for the AI are in the image.
grep -q '^cmd_list() {' "$root/usr/bin/nisse-rollback" || fail "nisse-rollback in the image has no list command"
# N-312: and it carries the subvolumes nested in the root across to the restored system
grep -q '^nested_subvolumes() {' "$root/usr/bin/nisse-rollback" || fail "nisse-rollback in the image does not carry nested subvolumes across"
sudo grep -qx '%wheel ALL=(root) NOPASSWD: /usr/bin/nisse-rollback list' "$root/usr/share/nisse/sudo/sudoers-limited" || fail "the limited sudo policy in the image does not allow 'nisse-rollback list' without a password"
if sudo grep -E 'NOPASSWD:.*nisse-rollback' "$root/usr/share/nisse/sudo/sudoers-limited" | grep -vqx '%wheel ALL=(root) NOPASSWD: /usr/bin/nisse-rollback list'; then fail "the limited sudo policy makes more of nisse-rollback passwordless than 'list'"; fi
[ -x "$root/usr/bin/nisse-guard-hook" ] || fail "nisse-guard-hook is missing from the image (it holds nisse-rollback for the AI)"
echo "undo: nisse-rollback list, the limited-mode rule for it and the guard hook are in the image"

# nisse's sudo policy (ledger N-306a): the package is in the image in its default, full mode (wheel runs sudo with no
# password, the AI works with no interruptions), the sudoers drop-in is the mode sudo requires (0440), and the shim and
# the password popup helper are there for limited mode.
case "$(rpmq -q nisse-sudo 2>/dev/null)" in nisse-sudo-*) ;; *) fail "nisse-sudo is not installed in the image" ;; esac
sudo grep -qx '%wheel ALL=(ALL) NOPASSWD: ALL' "$root/etc/sudoers.d/50-nisse-sudo" || fail "the image's sudo policy is not full mode (wheel passwordless)"
[ "$(sudo stat -c %a "$root/etc/sudoers.d/50-nisse-sudo")" = 440 ] || fail "the sudoers drop-in is not mode 0440 (sudo would ignore it)"
[ "$(cat "$root/etc/nisse/sudo-mode")" = full ] || fail "the image's sudo mode file does not say full"
for f in /usr/libexec/nisse/shims/sudo /usr/libexec/nisse/nisse-askpass /usr/share/nisse/sudo/sudoers-full /usr/share/nisse/sudo/sudoers-limited; do
    [ -f "$root$f" ] || fail "$f missing from the image"
done
[ -x "$root/usr/libexec/nisse/shims/sudo" ] && [ -x "$root/usr/libexec/nisse/nisse-askpass" ] || fail "the sudo shim or the popup helper is not executable"
[ -f "$root/usr/bin/kdialog" ] || fail "kdialog is not in the image (the limited-mode password popup needs it)"
grep -q 'UserGroups=.*wheel' "$root/etc/xdg/nissesetuprc" || fail "the first-run user setup does not put the new user in wheel (the sudo policy is for wheel)"
# The install choices framework (ledger N-306c): the engine is in the image, the sudo mode is a choice it knows, and the
# apply service is enabled once the image applies its presets (and not on live media, which the unit itself skips).
case "$(rpmq -q nisse-choices 2>/dev/null)" in nisse-choices-*) ;; *) fail "nisse-choices is not installed in the image" ;; esac
[ -x "$root/usr/bin/nisse-choices" ] || fail "the nisse-choices command is missing from the image"
[ -f "$root/usr/share/nisse/choices.d/10-sudo-mode.toml" ] || fail "the sudo-mode choice manifest is missing from the image"
state="$(sudo systemctl --root="$merged" is-enabled nisse-choices-apply.service 2>/dev/null || true)"
case "$state" in enabled | enabled-runtime) ;; *) fail "nisse-choices-apply.service is '$state' after the image applies its presets, expected enabled" ;; esac
NISSE_CHOICES_MANIFESTS="$root/usr/share/nisse/choices.d" "$root/usr/bin/nisse-choices" validate >/dev/null 2>&1 || fail "the choice manifests in the image do not validate"
echo "sudo: nisse-sudo in full mode, shim and popup helper installed, first-run users join wheel; choices engine and sudo-mode manifest present"

# The first-boot wizard (ledger N-306d): nisse's fork replaces KDE's Plasma Setup, runs before the login screen once, and is
# not on the live image's own boot (the unit skips live media).
case "$(rpmq -q nisse-setup 2>/dev/null)" in nisse-setup-*) ;; *) fail "nisse-setup is not installed in the image" ;; esac
if rpmq -q plasma-setup >/dev/null 2>&1 && case "$(rpmq -q plasma-setup)" in nisse-setup*) false ;; *) true ;; esac; then fail "KDE's plasma-setup is installed beside nisse-setup (it must be replaced)"; fi
for f in /usr/libexec/nisse-setup /usr/libexec/nisse-setup-bootutil /usr/libexec/kf6/kauth/nisse-setup-auth-helper \
         /usr/lib/systemd/system/nisse-setup.service /usr/share/polkit-1/rules.d/nisse-setup-polkit.rules /usr/share/polkit-1/actions/org.nisse.setup.policy \
         /usr/lib/sysusers.d/nisse-setup-sysuser.conf /etc/xdg/nissesetuprc; do
    [ -e "$root$f" ] || fail "$f missing from the image"
done
[ -e "$root/usr/libexec/plasma-setup" ] && fail "KDE's /usr/libexec/plasma-setup is in the image"
[ -e "$root/etc/nisse-setup-done" ] && fail "the image ships /etc/nisse-setup-done (the wizard would never run on an installed system)"
grep -qx 'UserGroups=wheel' "$root/etc/xdg/nissesetuprc" || fail "the wizard's user does not join wheel (the sudo policy is for wheel)"
state="$(sudo systemctl --root="$merged" is-enabled nisse-setup.service 2>/dev/null || true)"
case "$state" in enabled | enabled-runtime) ;; *) fail "nisse-setup.service is '$state' after the image applies its presets, expected enabled" ;; esac
# The choices page of the wizard (ledger N-306e): the page, its backend module and the helper action are in the image, and the
# action is declared and allowed for the wizard's user only.
for f in /usr/share/plasma/packages/org.nisse.setup.choices/metadata.json /usr/share/plasma/packages/org.nisse.setup.choices/contents/ui/main.qml; do
    [ -f "$root$f" ] || fail "$f missing from the image"
done
[ -d "$root/usr/lib64/qt6/qml/org/nisse/setup/choicesutil" ] || fail "the choicesutil QML module is missing from the image"
grep -q 'action id="org.nisse.setup.setchoice"' "$root/usr/share/polkit-1/actions/org.nisse.setup.policy" || fail "the helper does not declare org.nisse.setup.setchoice"
grep -q '"org.nisse.setup.setchoice"' "$root/usr/share/polkit-1/rules.d/nisse-setup-polkit.rules" || fail "polkit does not allow org.nisse.setup.setchoice for the wizard's user"
echo "first boot: nisse-setup replaces plasma-setup, enabled, wheel, not finished; the choices page and its helper action are present"

# The audit log never holds secrets or over-long text (ledger N-219c): the schema in the image allows the `changed` field, and the
# hook binary in the image, run on a made-up key (built here from pieces) and 100 KB of output, writes no key and a small, flagged record.
grep -q '"changed"' "$root/usr/share/nisse/daemon-protocol.schema.json" || fail "the protocol schema in the image has no changed field (N-219c)"
redact_dir="$(mktemp -d)"
redact_key="sk-ant-api03-$(printf 'Zq3x%.0s' $(seq 1 20))"
python3 - "$redact_key" > "$redact_dir/payload.json" <<'PY'
import json, sys
print(json.dumps({"session_id": "iso", "hook_event_name": "PostToolUse", "tool_name": "Bash",
                  "tool_input": {"command": "printenv"}, "tool_response": {"stdout": "K=" + sys.argv[1] + chr(10) + "x" * 100000}}))
PY
NISSE_AUDIT_LOG="$redact_dir/audit.jsonl" "$root/usr/bin/nisse-audit-hook" < "$redact_dir/payload.json" || true
if grep -q "$redact_key" "$redact_dir/audit.jsonl" 2>/dev/null; then rm -rf "$redact_dir"; fail "the audit hook in the image wrote a secret to the audit log (N-219c)"; fi
python3 - "$redact_dir/audit.jsonl" <<'PY' || { rm -rf "$redact_dir"; fail "the audit hook in the image did not redact and flag the record (N-219c)"; }
import json, sys
lines = open(sys.argv[1]).read().splitlines()
assert len(lines) == 1 and len(lines[0]) < 20000, "one small record expected, got %d line(s) of %d bytes" % (len(lines), len(lines[0]) if lines else 0)
r = json.loads(lines[0])
assert "[redacted: api-key]" in r["detail"]["tool_response"]["stdout"], "no marker"
assert r["changed"]["redacted"][0]["kind"] == "api-key" and r["changed"]["cut"][0]["bytes"] > 90000, r["changed"]
PY
rm -rf "$redact_dir"
echo "audit: the image's hook redacts a key, cuts long output and flags the record; the schema allows the flag"

# The boot screen (ledger N-501): the nisse Plymouth theme is the default in the image AND inside the initramfs the live ISO boots
# from (Plymouth runs there first), the script plugin it needs is in the initramfs, and no kernel line of the menu puts a serial
# console on without the option that lets Plymouth draw anyway (otherwise it forces its text theme and the screen never shows).
rpmq -q nisse-plymouth >/dev/null || fail "nisse-plymouth is not installed in the image (N-501)"
[ "$(sed -n 's/^Theme=//p' "$root/etc/plymouth/plymouthd.conf")" = nisse ] || fail "the image's default Plymouth theme is not nisse: $(grep -v '^#' "$root/etc/plymouth/plymouthd.conf" | tr '\n' ' ')"
for f in nisse.plymouth nisse.script logo.png field.png bullet.png bar-00.png bar-47.png; do
    [ -f "$root/usr/share/plymouth/themes/nisse/$f" ] || fail "the Plymouth theme lacks $f (N-501)"
done
boot_dir="$(mktemp -d)"
xorriso -osirrox on -indev "$iso" -extract /boot/x86_64/loader/initrd "$boot_dir/initrd" >/dev/null 2>&1 || { rm -rf "$boot_dir"; fail "no /boot/x86_64/loader/initrd in the ISO"; }
initrd_out="$(bash "$(dirname "$0")/plymouth_initrd_check.sh" "$boot_dir/initrd" 2>&1)" || { rm -rf "$boot_dir"; fail "${initrd_out#FAIL: } (N-501)"; }
rm -rf "$boot_dir"
menu_dir="$(mktemp -d)"
xorriso -osirrox on -indev "$iso" -extract /EFI/BOOT "$menu_dir/efi" >/dev/null 2>&1 || true
xorriso -osirrox on -indev "$iso" -extract /boot/grub2 "$menu_dir/grub2" >/dev/null 2>&1 || true
kernel_lines="$(grep -rhE '^[[:space:]]*(linux|linuxefi)[[:space:]]' "$menu_dir" || true)"
rm -rf "$menu_dir"
[ -n "$kernel_lines" ] || fail "no kernel line found in the ISO's menu (N-501)"
if printf '%s\n' "$kernel_lines" | grep 'console=ttyS' | grep -qv 'plymouth.ignore-serial-consoles'; then
    fail "a menu entry puts a serial console on the kernel line without plymouth.ignore-serial-consoles: Plymouth would force its text theme (N-501)"
fi
printf '%s\n' "$kernel_lines" | grep -q 'rhgb' || fail "the menu's kernel line lacks rhgb: Plymouth would not show a splash (N-501)"
echo "boot screen: nisse is the default Plymouth theme in the image and the initramfs, with its script plugin; the kernel line lets it draw"

# The boot menu (ledger N-502): the nisse GRUB theme is in the image and on the ISO's boot area (BIOS and UEFI read it from there), the
# menu is nisse's own (plain words, nisse the default), and the fonts and pictures theme.txt names are all there.
rpmq -q nisse-grub-theme >/dev/null || fail "nisse-grub-theme is not installed in the image (N-502)"
grub_dir="$(mktemp -d)"
xorriso -osirrox on -indev "$iso" -extract /boot/grub2 "$grub_dir/grub2" >/dev/null 2>&1 || true
theme="$grub_dir/grub2/themes/nisse"
for f in theme.txt logo.png bartrack.png select_nw.png select_c.png bar_nw.png barhl_c.png unicode.pf2 nunito-regular-28.pf2 nunito-semibold-regular-28.pf2          nunito-regular-22.pf2 nunito-regular-18.pf2; do
    [ -s "$theme/$f" ] || { rm -rf "$grub_dir"; fail "the ISO lacks /boot/grub2/themes/nisse/$f (N-502)"; }
done
python3 - "$theme" <<'PY' || { rm -rf "$grub_dir"; fail "theme.txt names a picture or font that is not on the ISO (N-502)"; }
import pathlib, re, sys
d = pathlib.Path(sys.argv[1])
text = (d / "theme.txt").read_text(encoding="ascii")
for name in re.findall(r'"([\w*.-]+\.png)"', text):
    pieces = [name.replace("*", p) for p in ("nw", "n", "ne", "w", "c", "e", "sw", "s", "se")] if "*" in name else [name]
    for f in pieces:
        assert (d / f).is_file(), f
for font in re.findall(r'(?:font|item_font|selected_item_font)\s*[:=]\s*"(Nunito [A-Za-z]+ \d+)"', text):
    assert (d / (font.lower().replace(" ", "-") + ".pf2")).is_file(), font
PY
cfg="$grub_dir/grub2/grub.cfg"
[ -f "$cfg" ] || { rm -rf "$grub_dir"; fail "no /boot/grub2/grub.cfg on the ISO (N-502)"; }
for entry in 'menuentry " *nisse" ' 'submenu " *More Ways to Start"' 'menuentry " *Check This Media and Start nisse"' 'menuentry " *Start nisse in Basic Graphics Mode"'; do
    grep -qE "$entry" "$cfg" || { rm -rf "$grub_dir"; fail "the ISO's menu lacks $entry (N-502)"; }
done
grep -q '^set default="0"' "$cfg" || { rm -rf "$grub_dir"; fail "the ISO's default menu entry is not the first, nisse (N-502)"; }
grep -q 'boot/grub2/themes/nisse' "$cfg" && grep -q 'set theme=' "$cfg" || { rm -rf "$grub_dir"; fail "the ISO's menu does not load the nisse theme (N-502)"; }
if grep -qE 'menuentry "(Start nisse"|Test this media)|Troubleshooting' "$cfg"; then rm -rf "$grub_dir"; fail "the ISO's menu still has a stock Fedora-style entry (N-502)"; fi
rm -rf "$grub_dir"
echo "boot menu: the nisse GRUB theme (pictures, fonts, theme.txt) is on the ISO and in the image; the menu is nisse, More Ways to Start, in plain words"

[ "$failures" = 0 ] || { echo "FAIL: $failures assertion(s) failed (NISSE_KEEP_GOING)" >&2; exit 1; }
echo "PASS: ISO contents ($iso), Qt $qt"
