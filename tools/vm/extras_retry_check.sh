#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Live proof for N-507e in the Fedora build VM: the real nisse-choices engine, the real nisse-extras and the real retry script against the real
# RPM Fusion repository. The boot-time apply leaves the extras choice alone; the retry applies it, says nothing when it is already in place,
# and the choice is cleaned up at the end. Run after tools/rpm/build-rpm.sh nisse-extras and `cargo build --release -p nisse-choices -p nisse-extras`:
#   tools/build/vm.sh ssh 'cd ~/nisse && tools/vm/extras_retry_check.sh'
set -u
cd "$(dirname "$0")/../.."
ROOT="$PWD"
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok   $*"; }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }
check() { local what="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else bad "$what"; fi; }

w="$(mktemp -d)"
trap 'sudo rm -rf "$w"' EXIT
mkdir -p "$w/manifests" "$w/state" "$w/bin"
# the manifest as shipped, with the command pointing at a wrapper that knows where the catalog is (the engine runs commands with a bare environment)
sed "s|/usr/bin/nisse-extras|$w/nx|" packaging/rpm/nisse-extras/choice-extras.toml > "$w/manifests/80-extras.toml"
printf '#!/bin/sh\nNISSE_EXTRAS_DIR=%s exec %s "$@"\n' "$ROOT/packaging/rpm/nisse-extras/extras.d" "$ROOT/services/target/release/nisse-extras" > "$w/nx"
chmod 755 "$w/nx"
# the engine for the retry script, with the temporary manifests and state
printf '#!/bin/sh\nNISSE_CHOICES_MANIFESTS=%s NISSE_CHOICES_DIR=%s exec %s "$@"\n' "$w/manifests" "$w/state" "$ROOT/services/target/release/nisse-choices" > "$w/bin/nisse-choices"
printf '#!/bin/sh\necho "notify-send $*" >> %s/notices\n' "$w" > "$w/bin/notify-send"
for p in loginctl runuser; do ln -s "/usr/bin/$p" "$w/bin/$p"; done
chmod 755 "$w/bin/nisse-choices" "$w/bin/notify-send"
nc() { sudo "$w/bin/nisse-choices" "$@"; }
installed() { rpm -q "$1" >/dev/null 2>&1; }

nc validate "$w/manifests" >/dev/null && ok "the shipped extras manifest passes the engine (boot = false is a known key)" || bad "the engine rejects the manifest"
sudo rm -rf /var/lib/nisse/extras
nc set extras codecs >/dev/null
nc apply --boot > "$w/boot.out" 2>&1
if grep -q extras "$w/boot.out"; then bad "the boot-time apply touched extras: $(cat "$w/boot.out")"; else ok "the boot-time apply leaves the extras choice alone"; fi
check "nothing was installed at boot" sh -c '! rpm -q libavcodec-freeworld'

sudo env NISSE_RETRY_BIN="$w/bin" "$ROOT/packaging/rpm/nisse-extras/nisse-extras-retry" > "$w/retry1.out" 2>&1
check "the retry installed the codecs" installed libavcodec-freeworld
grep -q 'are installed' "$w/retry1.out" && ok "the retry says so in the journal" || bad "retry output: $(cat "$w/retry1.out")"

sudo env NISSE_RETRY_BIN="$w/bin" "$ROOT/packaging/rpm/nisse-extras/nisse-extras-retry" > "$w/retry2.out" 2>&1
[ ! -s "$w/retry2.out" ] && ok "run again with nothing pending it says nothing" || bad "second run said: $(cat "$w/retry2.out")"

nc set extras "" >/dev/null
nc apply --id extras >/dev/null 2>&1
check "cleaned up: the codecs are gone again" sh -c '! rpm -q libavcodec-freeworld'
check "cleaned up: the repository file is gone" test ! -e /etc/yum.repos.d/nisse-extras-rpmfusion-free.repo
sudo rm -rf /var/lib/nisse/extras
echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
