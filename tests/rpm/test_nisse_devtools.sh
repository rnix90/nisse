#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Checks the built nisse-devtools RPM (the dev toolchain that ships, ledger N-513, docs/dev-toolchain.md). Run in the Fedora build VM after:
#   tools/rpm/build-rpm.sh nisse-devtools
set -euo pipefail
cd "$(dirname "$0")/../.."

RPMS=out/rpmbuild/RPMS/noarch
fail() { echo "FAIL: $*" >&2; exit 1; }
rpm_path="$(ls -v "$RPMS"/nisse-devtools-[0-9]*.rpm 2>/dev/null | tail -1 || true)"
[ -n "$rpm_path" ] || fail "nisse-devtools RPM not found (run tools/rpm/build-rpm.sh nisse-devtools)"

# the toolchain of docs/dev-toolchain.md, package by package (names verified against the Fedora 44 release repository on 2026-11-28; node and npm
# are nodejs24-bin and nodejs24-npm-bin, the packages that own /usr/bin/node and /usr/bin/npm)
want=(git gcc gcc-c++ make cmake ninja-build pkgconf-pkg-config gdb clang clang-tools-extra
      ripgrep jq curl
      rustup
      python3 python3-pip python3-virtualenv uv
      nodejs24 nodejs24-bin nodejs24-npm nodejs24-npm-bin
      podman distrobox
      neovim
      esptool picocom dfu-util libusb1 wget flex bison gperf ccache libffi-devel)
reqs="$(rpm -qp --requires "$rpm_path")"
for p in "${want[@]}"; do
    printf '%s\n' "$reqs" | grep -qx "$p" || fail "nisse-devtools does not require $p"
done
echo "ok   it requires all ${#want[@]} packages of the toolchain list"
# Kate is the image's other editor (N-507) and is not this package's business; nothing outside the list sneaks in
extra="$(printf '%s\n' "$reqs" | grep -v -E '^(rpmlib|config)\(' | grep -v -x -E '/bin/sh|/usr/bin/sh' | grep -v -x -F -f <(printf '%s\n' "${want[@]}") || true)"
[ -z "$extra" ] || fail "nisse-devtools requires something that is not in the toolchain list: $extra"
echo "ok   and nothing else"

files="$(rpm -qlp "$rpm_path")"
for f in /usr/bin/nisse-rust-setup /usr/bin/cargo /usr/bin/rustc /usr/bin/rust-analyzer /usr/bin/rustfmt /usr/bin/rustdoc /usr/bin/rustup /etc/profile.d/nisse-rust.sh /usr/lib/udev/rules.d/60-nisse-boards.rules; do
    printf '%s\n' "$files" | grep -qxF "$f" || fail "nisse-devtools lacks $f"
done
echo "ok   the helper, the six shims, the profile snippet and the board rules are in the package"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
rpm2cpio "$rpm_path" | (cd "$scratch" && cpio -idm --quiet 2>/dev/null)
for n in cargo rustc rust-analyzer rustfmt rustdoc rustup; do
    [ -x "$scratch/usr/bin/$n" ] || fail "$n is not executable"
    cmp -s <(tail -n +2 "$scratch/usr/bin/$n") <(tail -n +2 packaging/rpm/nisse-devtools/nisse-rust-shim) || fail "$n differs from the shim source"
done
cmp -s <(tail -n +2 "$scratch/usr/bin/nisse-rust-setup") <(tail -n +2 packaging/rpm/nisse-devtools/nisse-rust-setup) || fail "nisse-rust-setup differs from its source"
echo "ok   the shims and the helper are the sources"

cmp -s "$scratch/usr/lib/udev/rules.d/60-nisse-boards.rules" packaging/rpm/nisse-devtools/60-nisse-boards.rules || fail "the board rules differ from their source"
if command -v udevadm >/dev/null 2>&1; then
    v="$(udevadm verify "$scratch/usr/lib/udev/rules.d/60-nisse-boards.rules" 2>&1)" || fail "udevadm verify refuses the board rules: $v"
    echo "ok   udevadm verify accepts the board rules"
fi

conf="$(rpm -qp --conflicts "$rpm_path")"
for c in rust cargo rust-analyzer rustfmt; do
    printf '%s\n' "$conf" | grep -qx "$c" || fail "nisse-devtools does not conflict with Fedora's $c, whose files it would overwrite"
done
echo "ok   it conflicts with Fedora's own rust, cargo, rust-analyzer and rustfmt"

# Rust itself is not shipped, and nothing personal
bad="$(printf '%s\n' "$files" | grep -E '/\.cargo|/\.rustup|/usr/lib(64)?/rustlib' || true)"
[ -z "$bad" ] || fail "the package ships Rust itself: $bad"
echo "ok   Rust is not in the package (it is fetched on first use)"
if command -v rpmlint >/dev/null; then
    out="$(rpmlint -r tests/rpm/nisse-devtools.rpmlintrc "$rpm_path" 2>&1 || true)"
    echo "$out" | tail -2
    echo "$out" | grep -q ' E: ' && fail "rpmlint reports errors: $(echo "$out" | grep ' E: ' | head -3)"
fi
echo "PASS: nisse-devtools"
