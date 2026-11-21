#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-309: tests the four health checks (boot, network, services, display) and the runner nisse-health-check against fake
# systemctl, loginctl, nmcli and /sys/class/net. No systemd, no root. The real machine is tests/e2e/test_health_check.sh.
set -u
cd "$(dirname "$0")/../.."
dir="$PWD/packaging/rpm/nisse-update"
runner="$dir/nisse-health-check"
failures=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; failures=$((failures + 1)); }

fresh() {
    work="$(mktemp -d)"
    mkdir -p "$work/sysnet" "$work/services.d" "$work/state"
    export STUB_DIR="$work"
    export NISSE_SYSTEMCTL="$work/systemctl"
    export NISSE_LOGINCTL="$work/loginctl"
    export NISSE_NMCLI="$work/nmcli"
    export NISSE_SYS_NET="$work/sysnet"
    export NISSE_SERVICES_DIR="$work/services.d"
    export NISSE_STATE_DIR="$work/state"
    export NISSE_HEALTH_INTERVAL=0.2
    export NISSE_NOW=1700000000
    # a healthy graphical machine
    echo graphical.target > "$work/default"
    printf '%s\n' graphical.target multi-user.target plasmalogin.service display-manager.service NetworkManager.service \
        dbus-broker.service systemd-logind.service polkit.service systemd-journald.service > "$work/active"
    echo 0 > "$work/restarts"
    echo "c1  981 plasmalogin seat0 1482 greeter       tty1  no -" > "$work/sessions"
    echo connected > "$work/nmstate"
    printf 'enp0s2:ethernet:connected\nlo:loopback:connected (externally)\n' > "$work/nmdevices"
    mkdir -p "$work/sysnet/enp0s2/device" "$work/sysnet/lo"
    printf 'dbus-broker.service\nsystemd-logind.service\n# a comment\n\npolkit.service\nsystemd-journald.service\nNetworkManager.service\n' > "$work/services.d/00-core.list"
    cat > "$work/systemctl" <<'STUB'
#!/bin/sh
case "$1" in
    get-default) cat "$STUB_DIR/default" ;;
    is-active)
        if grep -qx "$2" "$STUB_DIR/active"; then echo active; exit 0; else echo inactive; exit 3; fi ;;
    show) cat "$STUB_DIR/restarts" ;;
esac
STUB
    cat > "$work/loginctl" <<'STUB'
#!/bin/sh
cat "$STUB_DIR/sessions"
STUB
    cat > "$work/nmcli" <<'STUB'
#!/bin/sh
[ -n "${NM_FAIL:-}" ] && { echo "Error: NetworkManager is not running." >&2; exit 8; }
case "$*" in
    *"STATE general"*) cat "$STUB_DIR/nmstate" ;;
    *"DEVICE,TYPE,STATE device"*) cat "$STUB_DIR/nmdevices" ;;
esac
STUB
    chmod +x "$work/systemctl" "$work/loginctl" "$work/nmcli"
    unset NM_FAIL
}
# a check, run with no arguments; prints its first line
chk() { sh "$dir/health.d/$1" 2>&1; }
inactive() { grep -vx "$1" "$work/active" > "$work/active.t"; mv "$work/active.t" "$work/active"; }

# ---- 10-boot
fresh
out="$(chk 10-boot)"; rc=$?
[ "$rc" = 0 ] && ok "boot: a booted graphical target passes" || bad "boot healthy: rc=$rc $out"
fresh; inactive graphical.target
out="$(chk 10-boot)"; rc=$?
[ "$rc" != 0 ] && case "$out" in *graphical.target*) ok "boot: the default target not active fails and names it" ;; *) bad "boot: reason: $out" ;; esac || bad "boot: inactive target passed"
fresh; echo emergency.target >> "$work/active"
out="$(chk 10-boot)"; rc=$?
[ "$rc" != 0 ] && case "$out" in *emergency*) ok "boot: emergency.target active fails" ;; *) bad "boot emergency reason: $out" ;; esac || bad "boot: emergency mode passed"
fresh; echo rescue.target >> "$work/active"
chk 10-boot >/dev/null; rc=$?
[ "$rc" != 0 ] && ok "boot: rescue.target active fails" || bad "boot: rescue mode passed"
fresh; echo multi-user.target > "$work/default"; inactive graphical.target
out="$(chk 10-boot)"; rc=$?
[ "$rc" = 0 ] && ok "boot: a machine whose default target is multi-user passes without a graphical target" || bad "boot multi-user default: rc=$rc $out"

# ---- 20-network (Bert's decision: the stack works; offline is fine)
fresh
out="$(chk 20-network)"; rc=$?
[ "$rc" = 0 ] && ok "network: NetworkManager up with its device passes" || bad "network healthy: rc=$rc $out"
fresh; echo disconnected > "$work/nmstate"; printf 'enp0s2:ethernet:unavailable\nlo:loopback:connected (externally)\n' > "$work/nmdevices"
out="$(chk 20-network)"; rc=$?
[ "$rc" = 0 ] && ok "network: offline (disconnected, no cable) still passes: the stack works" || bad "network offline: rc=$rc $out"
fresh; inactive NetworkManager.service
out="$(chk 20-network)"; rc=$?
[ "$rc" != 0 ] && case "$out" in *NetworkManager*) ok "network: NetworkManager not active fails and names it" ;; *) bad "network: reason $out" ;; esac || bad "network: a stopped NetworkManager passed"
fresh; export NM_FAIL=1
out="$(chk 20-network)"; rc=$?
[ "$rc" != 0 ] && ok "network: NetworkManager active but not answering fails" || bad "network: unresponsive NetworkManager passed"
fresh; printf 'lo:loopback:connected (externally)\n' > "$work/nmdevices"
out="$(chk 20-network)"; rc=$?
[ "$rc" != 0 ] && case "$out" in *enp0s2*) ok "network: the kernel has a physical interface NetworkManager does not list: fails and names it" ;; *) bad "network: reason $out" ;; esac || bad "network: a missing interface passed"
fresh; rm -rf "$work/sysnet/enp0s2"; printf 'lo:loopback:connected (externally)\n' > "$work/nmdevices"
out="$(chk 20-network)"; rc=$?
[ "$rc" = 0 ] && ok "network: a machine with no physical interface at all passes" || bad "network: no physical interface: rc=$rc $out"
fresh; mkdir -p "$work/sysnet/virbr0"; ln -s x "$work/sysnet/virbr0/bridge" 2>/dev/null
out="$(chk 20-network)"; rc=$?
[ "$rc" = 0 ] && ok "network: virtual interfaces (no device link) are not required to be listed" || bad "network: virtual interface: rc=$rc $out"

# ---- 30-services
fresh
out="$(chk 30-services)"; rc=$?
[ "$rc" = 0 ] && ok "services: every listed unit active passes" || bad "services healthy: rc=$rc $out"
fresh; inactive polkit.service
out="$(chk 30-services)"; rc=$?
[ "$rc" != 0 ] && case "$out" in *polkit.service*) ok "services: an inactive listed unit fails and names it" ;; *) bad "services: reason $out" ;; esac || bad "services: a stopped polkit passed"
fresh; inactive polkit.service; inactive systemd-logind.service
out="$(chk 30-services)"
case "$out" in *polkit.service*systemd-logind.service* | *systemd-logind.service*polkit.service*) ok "services: every inactive unit is named, not only the first" ;; *) bad "services: reason lists: $out" ;; esac
fresh; printf 'extra.service\n' > "$work/services.d/50-extra.list"
out="$(chk 30-services)"; rc=$?
[ "$rc" != 0 ] && case "$out" in *extra.service*) ok "services: a unit another package lists is checked too" ;; *) bad "services: extra reason $out" ;; esac || bad "services: an extra inactive unit passed"
fresh; echo extra.service >> "$work/active"; printf 'extra.service\n' > "$work/services.d/50-extra.list"
chk 30-services >/dev/null; rc=$?
[ "$rc" = 0 ] && ok "services: ...and passes when it is active" || bad "services: extra active unit failed"
fresh; rm -f "$work/services.d"/*
out="$(chk 30-services)"; rc=$?
[ "$rc" = 0 ] && ok "services: no list at all is nothing to check, not a failure" || bad "services: no lists: rc=$rc"

# ---- 40-display
fresh
out="$(chk 40-display)"; rc=$?
[ "$rc" = 0 ] && ok "display: the login manager running with a greeter session passes" || bad "display healthy: rc=$rc $out"
fresh; echo "2 1000 tester seat0 2100 user tty2 no -" > "$work/sessions"
chk 40-display >/dev/null; rc=$?
[ "$rc" = 0 ] && ok "display: a logged-in user session on the seat passes too" || bad "display: user session"
fresh; inactive display-manager.service; inactive plasmalogin.service
out="$(chk 40-display)"; rc=$?
[ "$rc" != 0 ] && case "$out" in *"login manager"*) ok "display: the login manager not running fails" ;; *) bad "display: reason $out" ;; esac || bad "display: no login manager passed"
fresh; echo 5 > "$work/restarts"
out="$(chk 40-display)"; rc=$?
[ "$rc" != 0 ] && case "$out" in *restart*) ok "display: a login manager that keeps restarting fails" ;; *) bad "display: restart reason $out" ;; esac || bad "display: a restart loop passed"
fresh; echo 2 > "$work/restarts"
chk 40-display >/dev/null; rc=$?
[ "$rc" = 0 ] && ok "display: up to 2 restarts is tolerated" || bad "display: 2 restarts failed"
fresh; : > "$work/sessions"
out="$(chk 40-display)"; rc=$?
[ "$rc" != 0 ] && case "$out" in *session*) ok "display: no greeter or user session on a seat fails" ;; *) bad "display: session reason $out" ;; esac || bad "display: no session passed"
fresh; echo "3 1000 tester - 2100 user ttyS0 no -" > "$work/sessions"
chk 40-display >/dev/null; rc=$?
[ "$rc" != 0 ] && ok "display: a console login without a seat is not a display session" || bad "display: serial session counted as a display"
fresh; echo multi-user.target > "$work/default"; : > "$work/sessions"; inactive display-manager.service
out="$(chk 40-display)"; rc=$?
[ "$rc" = 0 ] && ok "display: a machine that boots to multi-user has no display to check" || bad "display multi-user: rc=$rc $out"

# ---- the runner: a stand-in health directory so the retry logic is tested on its own
runner_fresh() {
    fresh
    mkdir -p "$work/health.d"
    export NISSE_HEALTH_DIR="$work/health.d"
    export NISSE_BOOT_ID_FILE="$work/boot_id"
    echo "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0" > "$work/boot_id"
    export NISSE_APPLY_UPDATES="$work/apply"
    cat > "$work/apply" <<'STUB'
#!/bin/sh
echo "apply $*" >> "$STUB_DIR/calls"
exit 0
STUB
    chmod +x "$work/apply"
    : > "$work/calls"
    printf 'state=pending-verify\nsnapshot=41\n' > "$work/state/state"
}
mkcheck() { # name exit-code [message]
    { echo '#!/bin/sh'; [ -n "${3:-}" ] && echo "echo '$3'"; echo "exit $2"; } > "$work/health.d/$1"
    chmod +x "$work/health.d/$1"
}
rrun() { sh "$runner" "$@" 2>&1; }

runner_fresh; mkcheck 10-a 0; mkcheck 20-b 0
out="$(rrun run --deadline 3)"; rc=$?
[ "$rc" = 0 ] && ok "runner: all checks pass: exit 0" || bad "runner healthy: rc=$rc $out"
grep -q 'apply verified' "$work/calls" && ok "runner: healthy means nisse-apply-updates verified" || bad "runner: verified not called: $(cat "$work/calls")"
grep -qx 'result=healthy' "$work/state/health" && grep -q '^checks=10-a 20-b$' "$work/state/health" && ok "runner: writes health with result=healthy and the checks that ran" || bad "runner: health file: $(cat "$work/state/health")"
grep -qx 'checked-at=1700000000' "$work/state/health" && ok "runner: records when" || bad "runner: no checked-at"
grep -qx 'boot-id=0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0' "$work/state/health" && ok "runner: records WHICH boot it checked (the boot id), so the watchdog never has to compare clocks: a clock that steps during boot (a flat CMOS battery, the first network time sync) made the time comparison wrong in the end-to-end test" || bad "runner: no boot-id: $(cat "$work/state/health")"

runner_fresh; mkcheck 10-a 0; mkcheck 20-b 1 "the thing is broken"
out="$(rrun run --deadline 2)"; rc=$?
[ "$rc" != 0 ] && ok "runner: a failing check at the deadline: exit non-zero" || bad "runner unhealthy: exit 0"
! grep -q 'apply verified' "$work/calls" && ok "runner: unhealthy never calls verified" || bad "runner: verified called despite a failure"
grep -qx 'result=unhealthy' "$work/state/health" && grep -qx 'failed=20-b' "$work/state/health" && ok "runner: health says unhealthy and which check" || bad "runner: unhealthy health file: $(cat "$work/state/health")"
grep -qx 'boot-id=0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0' "$work/state/health" && ok "runner: an unhealthy result records the boot id too" || bad "runner: unhealthy result has no boot-id"
grep -qx 'message-20-b=the thing is broken' "$work/state/health" && ok "runner: and the reason the check printed" || bad "runner: reason missing: $(cat "$work/state/health")"
grep -qx 'state=pending-verify' "$work/state/state" && ok "runner: the update stays pending (rolling back is N-310's job)" || bad "runner changed the update state"

runner_fresh; mkcheck 10-a 1 "first"; mkcheck 20-b 1 "second"
rrun run --deadline 1 >/dev/null
grep -qx 'failed=10-a 20-b' "$work/state/health" && ok "runner: every failing check is listed, not only the first" || bad "runner: failed list: $(grep failed= "$work/state/health")"

# a slow start: the check fails twice, then passes, within the deadline
runner_fresh
cat > "$work/health.d/10-slow" <<'STUB'
#!/bin/sh
n=$(cat "$STUB_DIR/n" 2>/dev/null || echo 0); n=$((n + 1)); echo $n > "$STUB_DIR/n"
[ "$n" -ge 3 ] && exit 0
echo "not yet ($n)"; exit 1
STUB
chmod +x "$work/health.d/10-slow"
out="$(rrun run --deadline 10)"; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$work/n")" = 3 ] && ok "runner: retries a failing check until it passes (a slow start is not a failure)" || bad "runner retry: rc=$rc n=$(cat "$work/n" 2>/dev/null)"
grep -q 'apply verified' "$work/calls" && ok "runner: ...and verifies after the retry" || bad "runner: not verified after a retry"
# a check that passed once is not run again while others retry
runner_fresh
cat > "$work/health.d/10-once" <<'STUB'
#!/bin/sh
echo x >> "$STUB_DIR/once-runs"; exit 0
STUB
cat > "$work/health.d/20-late" <<'STUB'
#!/bin/sh
n=$(cat "$STUB_DIR/n2" 2>/dev/null || echo 0); n=$((n + 1)); echo $n > "$STUB_DIR/n2"
[ "$n" -ge 3 ] && exit 0; exit 1
STUB
chmod +x "$work/health.d/10-once" "$work/health.d/20-late"
rrun run --deadline 10 >/dev/null
[ "$(wc -l < "$work/once-runs")" = 1 ] && ok "runner: a check that has passed is not run again" || bad "runner: re-ran a passed check: $(wc -l < "$work/once-runs")"

# a hanging check cannot hang the runner
runner_fresh
printf '#!/bin/sh\nsleep 30\n' > "$work/health.d/10-hang"; chmod +x "$work/health.d/10-hang"
start="$(date +%s)"
NISSE_CHECK_TIMEOUT=1 rrun run --deadline 3 >/dev/null; rc=$?
end="$(date +%s)"
[ "$rc" != 0 ] && [ $((end - start)) -lt 15 ] && ok "runner: a check that hangs is stopped (it counts as failed) and the runner ends by the deadline" || bad "runner: hang took $((end - start)) s, rc=$rc"
grep -q 'message-10-hang=.*timed out' "$work/state/health" && ok "runner: the reason says it timed out" || bad "runner: hang reason: $(grep message "$work/state/health")"

# no checks at all, not pending, --force
runner_fresh; rm -f "$work/health.d"/*
out="$(rrun run --deadline 2)"; rc=$?
[ "$rc" != 0 ] && ok "runner: no checks installed is a problem, not a pass" || bad "runner: no checks passed"
runner_fresh; mkcheck 10-a 0; printf 'state=idle\n' > "$work/state/state"
out="$(rrun run --deadline 2)"; rc=$?
[ "$rc" = 0 ] && ! grep -q 'apply' "$work/calls" && [ ! -e "$work/state/health" ] && ok "runner: nothing pending verification: exit 0, runs nothing, touches nothing" || bad "runner not pending: rc=$rc"
runner_fresh; mkcheck 10-a 0; rm -f "$work/state/state"
rrun run --deadline 2 >/dev/null; rc=$?
[ "$rc" = 0 ] && ! grep -q 'apply' "$work/calls" && ok "runner: no state file at all is nothing pending" || bad "runner no state: rc=$rc"
runner_fresh; mkcheck 10-a 0; printf 'state=idle\n' > "$work/state/state"
rrun run --deadline 2 --force >/dev/null; rc=$?
[ "$rc" = 0 ] && grep -qx 'result=healthy' "$work/state/health" && ! grep -q 'apply' "$work/calls" && ok "runner --force: runs the checks when nothing is pending, records the result, does not call verified" || bad "runner --force: rc=$rc calls=$(cat "$work/calls")"
runner_fresh; mkcheck 10-a 0
out="$(rrun run --deadline x)"; rc=$?
[ "$rc" != 0 ] && ok "runner: a bad --deadline is refused" || bad "runner: --deadline x accepted"
out="$(rrun frobnicate)"; rc=$?
[ "$rc" != 0 ] && ok "runner: an unknown command is an error" || bad "runner: unknown command accepted"
runner_fresh; mkcheck 10-a 0; sh "$runner" run --deadline 2 >/dev/null 2>&1
out="$(rrun status)"
case "$out" in *"result=healthy"*) ok "status: prints the last health result" ;; *) bad "status: $out" ;; esac
runner_fresh
out="$(rrun status)"
case "$out" in *"result=none"*) ok "status: result=none before any run" ;; *) bad "status before a run: $out" ;; esac
# a check that is not executable is skipped (a README or a backup file does not break the runner)
runner_fresh; mkcheck 10-a 0; echo "notes" > "$work/health.d/README"
out="$(rrun run --deadline 2)"; rc=$?
[ "$rc" = 0 ] && ok "runner: files that are not executable checks are ignored" || bad "runner: a README broke the run: rc=$rc"

echo
[ "$failures" = 0 ] && echo "PASS: nisse-health" || { echo "$failures failed"; exit 1; }
