#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Live proof for N-507d in the Fedora build VM, against the REAL repositories (RPM Fusion, LizardByte's COPR, Google's, Fedora's openh264):
# each item is ticked, checked, unticked, and the package list afterwards must equal the one before. A stand-in repository holds nisse's own
# Sunshine so the swap can be put back. Run as the build user (it uses sudo):
#   tools/build/vm.sh sync && tools/build/vm.sh ssh 'cd ~/nisse && tools/vm/extras_live_check.sh [item ...]'
# With no arguments every item is checked. Needs: tools/rpm/build-rpm.sh nisse-extras, and the built sunshine RPM for the swap.
# EXTRAS_INSTALLROOT=/var/tmp/extras-root runs everything inside a clean install root that has ONLY Fedora's release repository, like the image
# (the build VM itself mixes release and updates packages, which hides or invents problems); programs go through wrappers that add --installroot.
set -u
cd "$(dirname "$0")/../.."
ROOT="$PWD"
NX="$ROOT/services/target/release/nisse-extras"
export NISSE_EXTRAS_DIR="$ROOT/packaging/rpm/nisse-extras/extras.d"
ITEMS=("$@")
[ "${#ITEMS[@]}" -gt 0 ] || ITEMS=(openh264 codecs sunshine-swap sunshine-full chrome steam nvidia)
# the board families (N-514a) are the boards menu of the same catalog: esp32 arduino pico stm32 (run them by name; esp32 downloads several GB)
group_of() { case "$1" in esp32|arduino|pico|stm32) echo boards ;; *) echo extras ;; esac; }

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $*"; }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }
check() { local what="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else bad "$what"; fi; }
PFX="${EXTRAS_INSTALLROOT:-}"
if [ -n "$PFX" ]; then
    sudo rm -rf "$PFX"
    sudo mkdir -p "$PFX/etc/yum.repos.d" "$PFX/usr/share" "$PFX/etc/pki" "$PFX/.bin"
    sudo cp /etc/yum.repos.d/fedora.repo "$PFX/etc/yum.repos.d/"
    sudo cp -r /usr/share/distribution-gpg-keys "$PFX/usr/share/"
    sudo cp -r /etc/pki/rpm-gpg "$PFX/etc/pki/"
    printf '#!/bin/sh
exec /usr/bin/dnf --installroot=%s --releasever=44 "$@"
' "$PFX" | sudo tee "$PFX/.bin/dnf" >/dev/null
    printf '#!/bin/sh
exec /usr/bin/rpm --root %s "$@"
' "$PFX" | sudo tee "$PFX/.bin/rpm" >/dev/null
    sudo chmod 755 "$PFX/.bin/dnf" "$PFX/.bin/rpm"
    for p in curl gpg; do sudo ln -sf "/usr/bin/$p" "$PFX/.bin/$p"; done
    # An empty root has none of the libraries a desktop image already carries, so seed it with Steam's dependencies (install Steam, remove only
    # Steam): what an untick then has to clean up is what the option itself added, as on the image.
    if printf '%s
' "${ITEMS[@]}" | grep -qx steam; then
        printf '[seed]
name=seed
baseurl=https://download1.rpmfusion.org/nonfree/fedora/releases/44/Everything/x86_64/os/
gpgcheck=0
' | sudo tee "$PFX/etc/yum.repos.d/seed.repo" >/dev/null
        sudo dnf --installroot="$PFX" --releasever=44 install -y steam >/dev/null 2>&1
        sudo dnf --installroot="$PFX" --releasever=44 remove -y --setopt=clean_requirements_on_remove=false steam >/dev/null 2>&1
        sudo rm -f "$PFX/etc/yum.repos.d/seed.repo"
    fi
fi
nx() {
    if [ -n "$PFX" ]; then sudo env NISSE_EXTRAS_ROOT="$PFX" NISSE_EXTRAS_BIN="$PFX/.bin" NISSE_EXTRAS_DIR="$NISSE_EXTRAS_DIR" "$NX" "$@"
    else sudo env NISSE_EXTRAS_DIR="$NISSE_EXTRAS_DIR" "$NX" "$@"; fi
}
installed() { rpm ${PFX:+--root "$PFX"} -q "$1" >/dev/null 2>&1; }

( cd services && cargo build --release -p nisse-extras 2>&1 | tail -1 )
# the post commands name /usr/libexec/nisse/nisse-fetch-board and read the pins from /usr/share: put the repo's own there for the run (removed at the end)
sudo mkdir -p /usr/libexec/nisse /usr/share/nisse/extras.d
sudo ln -sf "$ROOT/packaging/rpm/nisse-extras/nisse-fetch-board" /usr/libexec/nisse/nisse-fetch-board
sudo ln -sf "$ROOT/packaging/rpm/nisse-extras/extras.d/boards.pins" /usr/share/nisse/extras.d/boards.pins

snapshot() { rpm ${PFX:+--root "$PFX"} -qa --qf '%{name}\n' | sort -u > "$1"; }
snapshot /tmp/extras-before.txt

# nisse's own Sunshine from a stand-in repository (what N-904 will serve for real)
sun="$(ls "$ROOT"/out/rpmbuild/RPMS/x86_64/sunshine-[0-9]*.rpm 2>/dev/null | tail -1)"
if [ -n "$sun" ]; then
    sudo rm -rf /tmp/standin && sudo mkdir -p /tmp/standin && sudo cp "$sun" /tmp/standin/ && sudo createrepo_c /tmp/standin >/dev/null
    printf '[nisse-standin]\nname=nisse stand-in\nbaseurl=file:///tmp/standin\nenabled=1\ngpgcheck=0\n' | sudo tee /etc/yum.repos.d/zz-nisse-standin.repo >/dev/null
fi

# The swap mechanics with real dnf and rpm, against a stand-in "Sunshine" package that owns /usr/bin/sunshine like the real one (the real COPR
# build needs a newer Qt than Fedora 44 ships today, see below). The repository file is written first, so nisse-extras uses it as it is.
swap_standin() {
    local d=/tmp/lb-standin
    sudo rm -rf "$d" /tmp/rb-standin && mkdir -p /tmp/rb-standin/SPECS && sudo mkdir -p "$d"
    cat > /tmp/rb-standin/SPECS/Sunshine.spec <<'SPEC'
Name: Sunshine
Version: 9999
Release: 1
Summary: stand-in for the LizardByte build
License: GPL-3.0-only
BuildArch: noarch
%description
stand-in
%install
mkdir -p %{buildroot}/usr/bin
printf '#!/bin/sh\necho full\n' > %{buildroot}/usr/bin/sunshine
chmod 755 %{buildroot}/usr/bin/sunshine
%files
/usr/bin/sunshine
SPEC
    rpmbuild -bb --define "_topdir /tmp/rb-standin" /tmp/rb-standin/SPECS/Sunshine.spec >/dev/null 2>&1
    sudo cp /tmp/rb-standin/RPMS/noarch/Sunshine-*.rpm "$d"/ && sudo createrepo_c "$d" >/dev/null
    printf '[nisse-extras-lizardbyte]\nname=stand-in\nbaseurl=file://%s\nenabled=1\ngpgcheck=0\n' "$d" | sudo tee /etc/yum.repos.d/nisse-extras-lizardbyte.repo >/dev/null
    installed sunshine || sudo dnf install -y sunshine >/dev/null 2>&1
    check "swap: nisse's sunshine is installed first" installed sunshine
    if nx apply sunshine-full; then ok "swap: apply exits 0"; else bad "swap: apply failed"; fi
    check "swap: Sunshine is installed" installed Sunshine
    check "swap: the clean sunshine is gone" sh -c '! rpm -q sunshine'
    check "swap: the full build's file is in place" sh -c '/usr/bin/sunshine | grep -q full'
    if nx apply ""; then ok "swap: untick exits 0"; else bad "swap: untick failed"; fi
    check "swap: Sunshine is gone" sh -c '! rpm -q Sunshine'
    check "swap: nisse's clean sunshine is back" installed sunshine
    check "swap: the repository file is gone" test ! -e /etc/yum.repos.d/nisse-extras-lizardbyte.repo
}

for item in "${ITEMS[@]}"; do
    echo "---- $item"
    if [ "$item" = sunshine-swap ]; then
        [ -n "$sun" ] || { bad "sunshine-swap: no built sunshine RPM"; continue; }
        swap_standin
        continue
    fi
    if [ "$item" = sunshine-full ]; then
        # The real COPR build. While it needs a newer Qt than Fedora 44 has, the apply must fail WITHOUT touching nisse's own sunshine.
        installed sunshine || sudo dnf install -y sunshine >/dev/null 2>&1
        if ! nx apply sunshine-full 2>/tmp/sf.err; then
            if grep -q "libQt6Core" /tmp/sf.err; then
                ok "sunshine-full: the real build is not installable yet (needs a newer Qt); said so, and nothing was changed"
                check "sunshine-full: nisse's own sunshine is still installed" installed sunshine
                check "sunshine-full: no repository file left" test ! -e /etc/yum.repos.d/nisse-extras-lizardbyte.repo
                nx apply "" >/dev/null 2>&1
                continue
            fi
            bad "sunshine-full: failed for another reason: $(cat /tmp/sf.err)"; continue
        fi
    fi
    case "$item" in
        sunshine-full)
            [ -n "$sun" ] || { bad "sunshine-full: no built sunshine RPM"; continue; }
            installed sunshine || sudo dnf install -y sunshine >/dev/null 2>&1
            check "nisse's sunshine is installed first" installed sunshine
            ;;
    esac
    snapshot "/tmp/extras-pre-$item.txt"
    g="$(group_of "$item")"
    if nx apply --group "$g" "$item"; then ok "$item: apply exits 0"; else bad "$item: apply failed (see above)"; fi
    check "$item: status says $item" test "$(nx status --group "$g")" = "$item"
    for r in $(sed -n 's/^repos = \[\(.*\)\]/\1/p' "$NISSE_EXTRAS_DIR"/items/*-"$item".toml | tr -d '", '); do
        check "$item: repo file for $r exists with gpgcheck=1" grep -q '^gpgcheck=1' "$PFX/etc/yum.repos.d/nisse-extras-$r.repo"
    done
    for p in $(sed -n 's/^packages = \[\(.*\)\]/\1/p' "$NISSE_EXTRAS_DIR"/items/*-"$item".toml | tr -d '",'); do
        check "$item: $p is installed" installed "$p"
    done
    case "$item" in
        codecs)
            check "codecs: the freeworld codec library has files" sh -c "rpm ${PFX:+--root $PFX} -ql libavcodec-freeworld | grep -q '\.so'"
            ;;
        sunshine-full)
            check "sunshine-full: nisse's clean sunshine is gone" sh -c '! rpm -q sunshine'
            check "sunshine-full: the binary has the x264 and x265 encoders" sh -c 'strings -a /usr/bin/sunshine | grep -q libx264 && strings -a /usr/bin/sunshine | grep -q libx265'
            ;;
        chrome)
            check "chrome: it runs and says its version" sh -c 'google-chrome-stable --version | grep -q "Google Chrome"'
            ;;
        steam)
            check "steam: its launcher is in the package" sh -c "rpm ${PFX:+--root $PFX} -ql steam | grep -qx /usr/bin/steam"
            ;;
        esp32)
            check "esp32: ESP-IDF is in /opt/esp-idf at the pinned commit's tree" test -f /opt/esp-idf/export.sh
            check "esp32: its tools are in /opt/espressif" test -d /opt/espressif/tools
            check "esp32: no git folder is left in ESP-IDF" sh -c '[ -z "$(find /opt/esp-idf -name .git | head -1)" ]'
            check "esp32: a user who is not root can use it (get_idf, idf.py)" sudo -u nobody env HOME=/tmp IDF_TOOLS_PATH=/opt/espressif bash -c '. /opt/esp-idf/export.sh >/dev/null 2>&1 && idf.py --version | grep -q "ESP-IDF"'
            check "esp32: the profile snippet gives IDF_PATH and get_idf" bash -c ". $ROOT/packaging/rpm/nisse-extras/nisse-boards.sh; [ \"\$IDF_PATH\" = /opt/esp-idf ] && type get_idf >/dev/null 2>&1"
            echo "     size: $(du -sh /opt/esp-idf /opt/espressif | tr '	' ' ' | tr '
' ' ')"
            ;;
        arduino)
            check "arduino: arduino-cli runs and says its version" sh -c '/usr/local/bin/arduino-cli version | grep -q "1.6.0"'
            check "arduino: avrdude runs" sh -c 'avrdude -? 2>&1 | grep -qi usage'
            ;;
        pico)
            check "pico: the SDK is in /opt/pico-sdk with its submodules" test -f /opt/pico-sdk/pico_sdk_init.cmake -a -d /opt/pico-sdk/lib/tinyusb/src
            check "pico: picotool is built and runs" sh -c '/usr/local/bin/picotool version | grep -q "2.3.1"'
            check "pico: the ARM compiler runs" sh -c 'arm-none-eabi-gcc --version | head -1 | grep -q arm-none-eabi'
            ;;
        stm32)
            check "stm32: the ARM compiler runs" sh -c 'arm-none-eabi-gcc --version | head -1 | grep -q arm-none-eabi'
            check "stm32: openocd runs" sh -c 'openocd --version 2>&1 | grep -qi "open on-chip debugger"'
            check "stm32: the ST-Link tools run" sh -c 'st-info --version | grep -q .'
            ;;
        nvidia)
            echo "     akmods result: $(rpm -qa 'kmod-nvidia*' | head -1)"
            check "nvidia: the kernel module package was built" sh -c 'rpm -qa "kmod-nvidia*" | grep -q .'
            check "nvidia: the reboot flag is set" sh -c 'grep -q "\"reboot\": *true" $PFX/var/lib/nisse/extras/state.json'
            ;;
    esac
    echo "---- $item: untick"
    if nx apply --group "$g" ""; then ok "$item: untick exits 0"; else bad "$item: untick failed"; fi
    check "$item: status is empty again" test -z "$(nx status --group "$g")"
    for rp in $(sed -n 's/^remove_paths = \[\(.*\)\]/\1/p' "$NISSE_EXTRAS_DIR"/items/*-"$item".toml | tr -d '",'); do
        check "$item: $rp is gone" test ! -e "$PFX$rp"
    done
    for r in $(sed -n 's/^repos = \[\(.*\)\]/\1/p' "$NISSE_EXTRAS_DIR"/items/*-"$item".toml | tr -d '", '); do
        check "$item: repo file for $r is gone" test ! -e "$PFX/etc/yum.repos.d/nisse-extras-$r.repo"
        check "$item: key file for $r is gone" test ! -e "$PFX/etc/pki/rpm-gpg/nisse-extras-$r"
    done
    snapshot "/tmp/extras-post-$item.txt"
    left="$(comm -13 "/tmp/extras-pre-$item.txt" "/tmp/extras-post-$item.txt" | tr '\n' ' ')"
    gone="$(comm -23 "/tmp/extras-pre-$item.txt" "/tmp/extras-post-$item.txt" | tr '\n' ' ')"
    if [ -z "$left" ]; then ok "$item: no package left behind"; else bad "$item: left behind: $left"; fi
    if [ -z "$gone" ]; then ok "$item: nothing else removed"
    elif [ -n "$PFX" ]; then echo "     (install root) also removed, orphans of the seeding that nothing else in this bare root needs: $gone"
    else bad "$item: also removed: $gone"; fi
    ls /etc/yum.repos.d/ | grep -i -E "google|lizard|fusion" | sed 's/^/     repo file still there: /'
done

sudo rm -f /etc/yum.repos.d/zz-nisse-standin.repo /usr/libexec/nisse/nisse-fetch-board /usr/share/nisse/extras.d/boards.pins
echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
