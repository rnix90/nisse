#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Live proof for N-513 in the Fedora build VM: nisse-devtools installed into a clean install root that has ONLY Fedora's release repository (like the
# image; the build VM itself must keep its own cargo and rustc, which the package conflicts with), every tool's version command run inside it, and the
# real first-use Rust setup against rust-lang.org. Run after tools/rpm/build-rpm.sh nisse-devtools:
#   tools/build/vm.sh ssh 'cd ~/nisse && tools/vm/devtools_check.sh'
set -u
cd "$(dirname "$0")/../.."
R=/var/tmp/devtools-root
rpmf="$(ls -v out/rpmbuild/RPMS/noarch/nisse-devtools-[0-9]*.rpm | tail -1)"
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok   $*"; }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

sudo rm -rf "$R"
sudo mkdir -p "$R/etc/yum.repos.d" "$R/etc/pki"
sudo cp /etc/yum.repos.d/fedora.repo "$R/etc/yum.repos.d/"
sudo cp -r /etc/pki/rpm-gpg "$R/etc/pki/"
if sudo dnf --installroot="$R" --releasever=44 install -y "$rpmf" > /tmp/devtools-install.log 2>&1; then ok "nisse-devtools installs from the release repository alone"; else bad "install failed: $(tail -5 /tmp/devtools-install.log)"; exit 1; fi
echo "     installed: $(sudo rpm --root "$R" -qa | wc -l) packages, $(sudo du -sh "$R" | cut -f1)"

inroot() { sudo chroot "$R" env HOME=/root PATH=/usr/local/bin:/usr/bin:/usr/sbin:/bin "$@"; }
v() { # name command...
    local name="$1"; shift
    if out="$(inroot "$@" 2>&1 | head -1)" && [ -n "$out" ]; then ok "$name: $out"; else bad "$name: '$*' did not run"; fi
}
v git git --version
v gcc gcc --version
v g++ g++ --version
v make make --version
v cmake cmake --version
v ninja ninja --version
v pkg-config pkg-config --version
v gdb gdb --version
v clang clang --version
v clangd clangd --version
v ripgrep rg --version
v jq jq --version
v curl curl --version
v rustup-init rustup-init --version
v python3 python3 --version
v pip pip --version
v virtualenv virtualenv --version
v uv uv --version
v node node --version
v npm npm --version
v npx npx --version
v podman podman --version
v distrobox distrobox --version
v neovim nvim --version
v esptool esptool version
v dfu-util dfu-util --version
v wget wget --version
v flex flex --version
v bison bison --version
v gperf gperf --version
v ccache ccache --version
inroot picocom --help >/dev/null 2>&1 && ok "picocom runs" || bad "picocom does not run"

# first use: cargo is a shim that sets Rust up, for real
sudo cp -L --remove-destination /etc/resolv.conf "$R/etc/resolv.conf"
sudo mount --bind /proc "$R/proc" 2>/dev/null
if out="$(inroot cargo --version 2>"$R/tmp/rust-setup.err")" && echo "$out" | grep -q '^cargo '; then ok "first use: cargo set Rust up and ran: $out"; else bad "first use of cargo: '$out' $(tail -3 "$R/tmp/rust-setup.err")"; fi
inroot rustc --version | grep -q '^rustc ' && ok "rustc: $(inroot rustc --version)" || bad "rustc does not run after the setup"
inroot rust-analyzer --version | grep -q 'rust-analyzer' && ok "rust-analyzer: $(inroot rust-analyzer --version)" || bad "rust-analyzer does not run after the setup"
inroot cargo clippy --version | grep -q clippy && ok "clippy is there" || bad "no clippy"
inroot rustfmt --version | grep -q rustfmt && ok "rustfmt is there" || bad "no rustfmt"
sudo umount "$R/proc" 2>/dev/null
sudo rm -rf "$R"
echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
