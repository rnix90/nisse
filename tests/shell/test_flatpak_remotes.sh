#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Tests packaging/rpm/nisse-firstboot/nisse-flatpak-remotes with a stub flatpak. No network needed.
set -u
cd "$(dirname "$0")/../.."
script="$PWD/packaging/rpm/nisse-firstboot/nisse-flatpak-remotes"
failures=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; failures=$((failures + 1)); }

# Each case gets its own state directory, a reachable probe and a stub flatpak that records its arguments.
fresh() {
    work="$(mktemp -d)"
    mkdir -p "$work/state"
    printf '[Flatpak Repo]\nTitle=Flathub\n' > "$work/reachable"   # what the real .flatpakrepo looks like
    export NISSE_PROBE_URL="file://$work/reachable"
    export NISSE_STATE_DIR="$work/state"
    export NISSE_FLATPAK="$work/flatpak"
    printf '#!/bin/sh\necho "$@" >> "%s/calls"\nexit "${STUB_RC:-0}"\n' "$work" > "$work/flatpak"
    chmod +x "$work/flatpak"
    unset STUB_RC
}

fresh
sh "$script" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok "online: exit 0" || bad "online: exit $rc, wanted 0"
grep -qx 'remote-add --system --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo' "$work/calls" 2>/dev/null \
    && ok "online: adds the flathub remote system-wide" || bad "online: flatpak was not called with the flathub remote-add"
[ -e "$work/state/flatpak-remotes.done" ] && ok "online: writes the done marker" || bad "online: no done marker"

fresh
export NISSE_PROBE_URL="http://127.0.0.1:9/unreachable"
sh "$script" >/dev/null 2>&1; rc=$?
[ "$rc" = 75 ] && ok "offline: exit 75 (retry later)" || bad "offline: exit $rc, wanted 75"
[ ! -e "$work/calls" ] && ok "offline: flatpak not called" || bad "offline: flatpak ran without a network"
[ ! -e "$work/state/flatpak-remotes.done" ] && ok "offline: no done marker" || bad "offline: done marker written"

# A captive portal answers every request with a page of its own: that is not the internet yet.
fresh
printf '<html><body>Log in to the wifi</body></html>\n' > "$work/reachable"
sh "$script" >/dev/null 2>&1; rc=$?
[ "$rc" = 75 ] && ok "captive portal: exit 75 (retry later)" || bad "captive portal: exit $rc, wanted 75"
[ ! -e "$work/calls" ] && ok "captive portal: flatpak not called" || bad "captive portal: flatpak ran"

fresh
STUB_RC=1 sh "$script" >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ok "flatpak fails: exit 1" || bad "flatpak fails: exit $rc, wanted 1"
[ ! -e "$work/state/flatpak-remotes.done" ] && ok "flatpak fails: no done marker" || bad "flatpak fails: done marker written"

fresh
export NISSE_FLATPAK="$work/no-such-flatpak"
sh "$script" >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ok "flatpak missing: exit 1" || bad "flatpak missing: exit $rc, wanted 1"

if [ "$failures" -eq 0 ]; then echo "PASS: flatpak remotes"; else echo "$failures failure(s)"; exit 1; fi
