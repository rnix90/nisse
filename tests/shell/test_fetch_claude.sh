#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Tests packaging/rpm/nisse-firstboot/nisse-fetch-claude with a fake installer. No network needed.
set -u
cd "$(dirname "$0")/../.."
script="$PWD/packaging/rpm/nisse-firstboot/nisse-fetch-claude"
unit="$PWD/packaging/rpm/nisse-firstboot/nisse-fetch-claude.service"
failures=0

check() { # name expected-exit expected-status
    local name="$1" want_rc="$2" want_status="$3" got_rc got_status
    got_rc="$rc"
    got_status="$(cat "$HOME/.local/state/nisse/claude-fetch.status" 2>/dev/null || echo none)"
    if [ "$got_rc" = "$want_rc" ] && [ "$got_status" = "$want_status" ]; then
        echo "ok   $name (exit $got_rc, status $got_status)"
    else
        echo "FAIL $name: wanted exit $want_rc / status $want_status, got exit $got_rc / status $got_status"
        failures=$((failures + 1))
    fi
}

# Each case gets its own empty HOME and a PATH without the real claude.
fresh() {
    work="$(mktemp -d)"
    export HOME="$work/home"
    mkdir -p "$HOME/.local/bin" "$work/bin"
    export PATH="$work/bin:/usr/bin:/bin"
    : > "$work/reachable"
    export NISSE_PROBE_URL="file://$work/reachable"
    export NISSE_CLAUDE_INSTALLER="touch $work/installer-ran; printf '#!/bin/sh\n' > $HOME/.local/bin/claude; chmod +x $HOME/.local/bin/claude"
}

fresh
printf '#!/bin/sh\n' > "$work/bin/claude"; chmod +x "$work/bin/claude"
sh "$script" >/dev/null 2>&1; rc=$?
check "claude already on PATH" 0 installed
[ ! -e "$work/installer-ran" ] && echo "ok   installer not called when claude exists" || { echo "FAIL installer ran although claude exists"; failures=$((failures + 1)); }

fresh
sh "$script" >/dev/null 2>&1; rc=$?
check "installer succeeds" 0 installed
[ -x "$HOME/.local/bin/claude" ] && echo "ok   claude was installed" || { echo "FAIL claude missing after install"; failures=$((failures + 1)); }

fresh
export NISSE_PROBE_URL="http://127.0.0.1:9/unreachable"
sh "$script" >/dev/null 2>&1; rc=$?
check "no network" 75 waiting-for-network
[ ! -e "$work/installer-ran" ] && echo "ok   installer not called without network" || { echo "FAIL installer ran without network"; failures=$((failures + 1)); }

fresh
export NISSE_CLAUDE_INSTALLER="exit 7"
sh "$script" >/dev/null 2>&1; rc=$?
check "installer fails with network up" 1 failed

fresh
export NISSE_CLAUDE_INSTALLER="true"
sh "$script" >/dev/null 2>&1; rc=$?
check "installer exits 0 but installs nothing" 1 failed

for line in "ConditionPathExists=!%h/.local/bin/claude" "Type=oneshot" "ExecStart=/usr/bin/nisse-fetch-claude" \
            "Restart=on-failure" "RestartForceExitStatus=75" "RestartSec=120" \
            "WantedBy=default.target"; do
    if grep -qxF "$line" "$unit" 2>/dev/null; then echo "ok   unit has $line"; else echo "FAIL unit lacks $line"; failures=$((failures + 1)); fi
done

# StartLimitIntervalSec is a [Unit] key; systemd ignores it in [Service]
if awk '/^\[Unit\]/{f=1;next} /^\[/{f=0} f' "$unit" | grep -qxF "StartLimitIntervalSec=0"; then
    echo "ok   unit has StartLimitIntervalSec=0 in [Unit]"
else
    echo "FAIL StartLimitIntervalSec=0 must be in the [Unit] section"; failures=$((failures + 1))
fi

if [ "$failures" -eq 0 ]; then echo "PASS: fetch-claude"; else echo "$failures failure(s)"; exit 1; fi
