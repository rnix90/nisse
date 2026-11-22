#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# GATE 3 (N-313): prepare the two INSTALLED machines of docs/gate3-hand-checks.md from the disk the install-to-disk test made.
#   history  two real package changes (the probe package 1.0, then 2.0), so Settings, System history has rows to undo
#   broken   an update that installs fine and fails its own health check after the restart, applied and waiting: the first boot of
#            this machine runs the real watchdog (180 s of health check, then the 60 s countdown notice)
# Each result is a copy of the disk's overlay and firmware variables in $OUT (a LOCAL folder), booted by hand with
# tools/vm/run-vm.sh. The installed disk itself is never written. Needs out/install/run (the install-to-disk run) and the probe
# repositories (out/install/undo-e2e/probe-repos.tgz, made by tests/e2e/test_undo.sh).
#   bash tools/vm/handcheck_prepare.sh OUTDIR          (ONLY=broken or ONLY=history prepares just one)
set -u
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../.."
out="${1:?usage: handcheck_prepare.sh OUTDIR (a local folder)}"
case "$out" in //* | [T-Zt-z]:*) echo "FAIL: $out looks like a network drive"; exit 2 ;; esac
mkdir -p "$out"
disk=out/install/run/target.qcow2
vars=out/install/run/install/OVMF_VARS.fd
repos=out/install/undo-e2e
[ -f "$disk" ] && [ -f "$vars" ] && [ -s "$repos/probe-repos.tgz" ] || { echo "FAIL: missing the installed disk or the probe repositories"; exit 2; }
port=24730; httpport=24731
V() { python tools/vm/vmserver.py call "$port" "$@"; }
login() { bash tools/vm/vmlogin.sh "$port" >/dev/null; }
python -m http.server "$httpport" --bind 127.0.0.1 --directory "$repos" > "$out/http.log" 2>&1 &
httppid=$!
trap 'kill "$httppid" 2>/dev/null' EXIT

prepare() { # name, then the guest commands to run as root after the probe repositories are in place
    local name="$1"; shift
    local work="$out/work-$name"
    rm -rf "$work"
    python tools/vm/vmserver.py serve --disk "$disk" --vars "$vars" --work "$(cygpath -m "$work")" --port "$port" > "$out/server-$name.log" 2>&1 &
    sleep 8
    V expect "login:" 420 >/dev/null || { echo "FAIL: $name did not reach a login"; return 1; }
    login
    V run "curl -fsS -o /tmp/probe-repos.tgz http://10.0.2.2:$httpport/probe-repos.tgz && S mkdir -p /var/lib/e2e && S tar -C /var/lib/e2e -xzf /tmp/probe-repos.tgz && echo \"RES: repos\"" 300 | grep -q "RES: repos" || { echo "FAIL: $name: no probe repositories"; return 1; }
    V run "$*" 900 >/dev/null
    V run 'S sync; S systemctl poweroff' 60 >/dev/null 2>&1
    sleep 25
    V quit >/dev/null 2>&1
    sleep 3
    cp "$work/overlay.qcow2" "$out/$name.qcow2" && cp "$work/OVMF_VARS.fd" "$out/$name-vars.fd" && echo "ok   $name: $out/$name.qcow2"
}

[ "${ONLY:-history}" = history ] && prepare history 'S dnf install -y --disablerepo=updates /var/lib/e2e/probe-1.0.rpm >/dev/null 2>&1; sleep 5; S dnf install -y --disablerepo=updates /var/lib/e2e/repo-good/nisse-e2e-probe-2.0-1.noarch.rpm >/dev/null 2>&1; sleep 5'
# the broken update upgrades the probe package, so 1.0 has to be installed first (an upgrade of nothing is a no-op)
[ "${ONLY:-broken}" = broken ] && prepare broken 'S dnf install -y --disablerepo=updates /var/lib/e2e/probe-1.0.rpm >/dev/null 2>&1; sleep 5; S nisse-apply-updates run --dnf-arg --repofrompath=e2e,file:///var/lib/e2e/repo-broken --dnf-arg --repo=e2e --dnf-arg --no-gpgchecks >/dev/null 2>&1'
echo "done"
