#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-310: tests nisse-update-watchdog (when to undo an update, the countdown notice with its Cancel button, the hang limit, the
# fallback boot) and nisse-update-notice (the one plain notice after a rollback) against fakes for nisse-rollback, nisse-boot,
# loginctl, runuser, notify-send and sleep. The fake sleep moves a fake clock and the fake uptime, so a ten-minute limit takes
# no time. The real rollback on a real disk is tests/e2e/test_rollback.sh.
set -u
cd "$(dirname "$0")/../.."
tool="$PWD/packaging/rpm/nisse-update/nisse-update-watchdog"
notice="$PWD/packaging/rpm/nisse-update/nisse-update-notice"
failures=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; failures=$((failures + 1)); }

fresh() {
    work="$(mktemp -d)"
    mkdir -p "$work/state" "$work/run" "$work/home"
    export NISSE_STATE_DIR="$work/state"
    export NISSE_RUNTIME_DIR="$work/run"
    export NISSE_ROLLBACK="$work/nisse-rollback"
    export NISSE_BOOT_TOOL="$work/nisse-boot"
    export NISSE_LOGINCTL="$work/loginctl"
    export NISSE_RUNUSER="$work/runuser"
    export NISSE_NOTIFY="$work/notify-send"
    export NISSE_SLEEP="$work/sleep"
    export NISSE_CLOCK_FILE="$work/clock"
    export NISSE_UPTIME_FILE="$work/uptime"
    export NISSE_BOOT_ID_FILE="$work/boot_id"
    echo "aaaaaaaa-this-boot" > "$work/boot_id"
    export NISSE_CMDLINE_FILE="$work/cmdline"
    export NISSE_FSROOT=/root
    export NISSE_COUNTDOWN=5
    export NISSE_HANG_LIMIT=60
    export NISSE_POLL=5
    export XDG_STATE_HOME="$work/home"
    export STUB_DIR="$work"
    export TZ=UTC
    echo 100000 > "$work/clock"
    echo "10.00 40.00" > "$work/uptime"
    echo "BOOT_IMAGE=x root=UUID=1 ro rootflags=subvol=root" > "$work/cmdline"
    printf 'state=pending-verify\nsnapshot=41\nfingerprint=abc\n' > "$work/state/state"
    : > "$work/calls"
    printf 'armed=yes\nsnapshot=41\ntries-left=2\nboot-success=0\n' > "$work/boot-status"
    unset ROLLBACK_FAIL CLICK
    # sessions: id|type|class|state|name|uid
    cat > "$work/sessions" <<'EOF'
c1|wayland|greeter|active|plasmalogin|981
2|tty|user|active|tester|1000
4|wayland|user|active|tester|1000
EOF
    cat > "$work/nisse-rollback" <<'STUB'
#!/bin/sh
echo "rollback $*" >> "$STUB_DIR/calls"
[ -n "${ROLLBACK_FAIL:-}" ] && { echo "nisse-rollback: refused" >&2; exit 1; }
exit 0
STUB
    cat > "$work/nisse-boot" <<'STUB'
#!/bin/sh
[ "$1" = status ] && cat "$STUB_DIR/boot-status"
exit 0
STUB
    cat > "$work/loginctl" <<'STUB'
#!/bin/sh
case "$1" in
    list-sessions) cut -d'|' -f1 "$STUB_DIR/sessions" | sed 's/$/ 1000 x seat0 -/' ;;
    show-session)
        id="$2"
        line="$(grep "^$id|" "$STUB_DIR/sessions")"
        echo "$line" | awk -F'|' '{print "Type=" $2; print "Class=" $3; print "State=" $4; print "Name=" $5; print "User=" $6}'
        ;;
esac
STUB
    cat > "$work/runuser" <<'STUB'
#!/bin/sh
# runuser -u USER -- env DBUS_...=... notify-send ARGS: log it, and answer the way a person would
echo "runuser $*" >> "$STUB_DIR/calls"
echo "notify-at-clock $(cat "$STUB_DIR/clock")" >> "$STUB_DIR/calls"
[ -n "${CLICK:-}" ] && echo cancel
exit 0
STUB
    cat > "$work/sleep" <<'STUB'
#!/bin/sh
echo "sleep $1" >> "$STUB_DIR/calls"
echo $(( $(cat "$STUB_DIR/clock") + $1 )) > "$STUB_DIR/clock"
awk -v add="$1" '{printf "%.2f %.2f\n", $1 + add, $2}' "$STUB_DIR/uptime" > "$STUB_DIR/uptime.new"; mv "$STUB_DIR/uptime.new" "$STUB_DIR/uptime"
[ -f "$STUB_DIR/on_sleep" ] && sh "$STUB_DIR/on_sleep"
exit 0
STUB
    cat > "$work/notify-send" <<'STUB'
#!/bin/sh
echo "notify-send $*" >> "$STUB_DIR/calls"
STUB
    chmod +x "$work"/nisse-rollback "$work"/nisse-boot "$work"/loginctl "$work"/runuser "$work"/sleep "$work"/notify-send
}
has_call() { grep -q -- "$1" "$work/calls"; }
call_line() { grep -n -- "$1" "$work/calls" | head -1 | cut -d: -f1; }
count_calls() { grep -c -- "$1" "$work/calls"; }
run() { timeout 30 sh "$tool" "$@" 2>&1; }
# the health result of THIS boot (it carries this boot's id)
unhealthy_now() {
    printf 'result=unhealthy\nchecked-at=%s\nboot-id=aaaaaaaa-this-boot\nchecks=10-boot 20-network\nfailed=20-network\nmessage-20-network=NetworkManager does not answer\n' "$(( $(cat "$work/clock") - 3 ))" > "$work/state/health"
}

# ---- nothing to watch
fresh
printf 'state=idle\nlast=verified\n' > "$work/state/state"
out="$(run run)"; rc=$?
[ "$rc" = 0 ] && ! has_call 'rollback' && ! has_call 'runuser' && ok "idle: nothing is watched, nothing happens" || bad "idle: rc=$rc calls=$(cat "$work/calls")"
for s in failed running; do
    fresh; printf 'state=%s\n' "$s" > "$work/state/state"
    out="$(run run)"; rc=$?
    [ "$rc" = 0 ] && ! has_call 'rollback' && ok "state=$s: not an update waiting for its checks, so left alone" || bad "state=$s: acted"
done
fresh
rm -f "$work/state/state"
out="$(run run)"; rc=$?
[ "$rc" = 0 ] && ! has_call 'rollback' && ok "no state file at all: left alone" || bad "no state: acted"
fresh
echo "BOOT_IMAGE=x root=live:CDLABEL=x rd.live.image" > "$work/cmdline"
unhealthy_now
out="$(run run)"; rc=$?
[ "$rc" = 0 ] && ! has_call 'rollback' && ok "live media: never rolls back" || bad "live media: acted"

# ---- healthy: the health check verifies it while the watchdog is waiting
fresh
printf 'sleep\n' > /dev/null
cat > "$work/on_sleep" <<EOF
printf 'state=idle\nlast=verified\n' > "$work/state/state"
EOF
out="$(run run)"; rc=$?
[ "$rc" = 0 ] && ! has_call 'rollback' && ! has_call 'runuser' && ok "healthy: the update is verified while waiting, the watchdog ends quietly" || bad "healthy: rc=$rc calls=$(cat "$work/calls")"

# ---- unhealthy: the countdown notice, then the rollback
fresh
unhealthy_now
out="$(run run)"; rc=$?
[ "$rc" = 0 ] && ok "unhealthy: exit 0" || bad "unhealthy: rc=$rc $out"
has_call 'rollback run 41 --reason .*20-network.*NetworkManager does not answer.* --reboot' && ok "unhealthy: rolls back to the snapshot in the state, with the failing check and its reason, and reboots" || bad "unhealthy: rollback call: $(grep rollback "$work/calls")"
[ "$(count_calls '^rollback')" = 1 ] && ok "unhealthy: exactly one rollback" || bad "unhealthy: $(count_calls '^rollback') rollbacks"
n="$(call_line '^runuser')"; r="$(call_line '^rollback')"
[ -n "$n" ] && [ "$n" -lt "$r" ] && ok "unhealthy: the notice comes before the rollback" || bad "unhealthy: order notice=$n rollback=$r"
has_call 'runuser -u tester -- env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus' && ok "notice: sent to the user's own session bus as that user" || bad "notice: $(grep runuser "$work/calls")"
has_call '^runuser .*--expire-time=5000' && ok "notice: stays for the whole countdown (5 s in this test, 60 s in production)" || bad "notice: expire-time: $(grep runuser "$work/calls")"
has_call '^runuser .*--action=cancel=' && ok "notice: carries a Cancel button (action 'cancel')" || bad "notice: no action"
has_call '^runuser .*--wait' && ok "notice: waits for the person's answer" || bad "notice: no --wait"
has_call '^runuser .*--urgency=critical' && ok "notice: urgent, so it is not hidden by Do Not Disturb" || bad "notice: not critical"
has_call '^runuser .*in 5 seconds' && ok "notice: says when it will happen" || bad "notice: no time in the text: $(grep runuser "$work/calls")"
[ "$(count_calls '^runuser')" = 1 ] && ok "notice: only the graphical user session gets it (not the greeter, not the serial login)" || bad "notice: sent $(count_calls '^runuser') times"
grep -q 'sleep 1' "$work/calls" && [ "$(count_calls '^sleep 1')" -ge 4 ] && ok "countdown: waits out the countdown a second at a time (so a Cancel is noticed at once)" || bad "countdown: $(grep -c sleep "$work/calls") sleeps"

# ---- Cancel
fresh
unhealthy_now
export CLICK=1
out="$(run run)"; rc=$?
[ "$rc" = 0 ] && ! has_call '^rollback' && ok "cancel: the person pressed Cancel, nothing is rolled back" || bad "cancel: rc=$rc calls=$(cat "$work/calls")"
[ -e "$work/run/cancelled" ] && ok "cancel: remembered for the rest of this boot" || bad "cancel: no flag"
grep -qx 'state=pending-verify' "$work/state/state" && ok "cancel: the update stays pending, so GRUB's fallback still guards the next boots" || bad "cancel: state changed"
unset CLICK; : > "$work/calls"
out="$(run run)"; rc=$?
[ "$rc" = 0 ] && ! has_call '^runuser' && ! has_call '^rollback' && ok "cancel: a second run in the same boot does not ask again" || bad "cancel: asked again: $(cat "$work/calls")"
rm -f "$work/run/cancelled"; : > "$work/calls"
out="$(run run)"; rc=$?
has_call '^rollback' && ok "cancel: the next boot starts clean and acts again (the flag lives in /run)" || bad "cancel: next boot did not act"

# ---- nobody logged in: the countdown still runs, then it rolls back
fresh
unhealthy_now
printf 'c1|wayland|greeter|active|plasmalogin|981\n' > "$work/sessions"
out="$(run run)"; rc=$?
[ "$rc" = 0 ] && ! has_call '^runuser' && has_call '^rollback run 41' && ok "no graphical user: no notice, the countdown still runs and the rollback happens" || bad "no user: rc=$rc calls=$(cat "$work/calls")"
[ "$(count_calls '^sleep 1')" -ge 4 ] && ok "no graphical user: it waited the countdown out first" || bad "no user: no wait"

# ---- two people logged in: both are told
fresh
unhealthy_now
printf '4|wayland|user|active|tester|1000\n7|x11|user|active|guest|1001\n9|wayland|user|closing|gone|1002\n' > "$work/sessions"
out="$(run run)"
[ "$(count_calls '^runuser')" = 2 ] && has_call 'user.*guest.*1001\|runuser -u guest' && ok "two graphical sessions: both are told, a closing session is not" || bad "two sessions: $(grep runuser "$work/calls")"

# ---- a result from an earlier boot is not this boot's verdict
fresh
printf 'result=unhealthy\nchecked-at=%s\nboot-id=bbbbbbbb-an-earlier-boot\nchecks=10-boot\nfailed=10-boot\nmessage-10-boot=old news\n' "$(( $(cat "$work/clock") - 3 ))" > "$work/state/health"
out="$(run run)"; rc=$?
has_call 'rollback run 41 --reason .*did not finish' && ! grep -q 'old news' "$work/calls" && ok "a result with another boot's id is ignored (even one dated just now); the hang limit decides" || bad "another boot's result used: $(grep rollback "$work/calls")"
fresh
printf 'result=unhealthy\nchecked-at=%s\nchecks=10-boot\nfailed=10-boot\nmessage-10-boot=no id\n' "$(( $(cat "$work/clock") - 3 ))" > "$work/state/health"
out="$(run run)"
has_call 'rollback run 41 --reason .*did not finish' && ! grep -q 'no id' "$work/calls" && ok "a result with no boot id (written by an older nisse-update) cannot be told from another boot's, so it is ignored" || bad "an id-less result was used: $(grep rollback "$work/calls")"
# the real-world bug the end-to-end test found: the clock stepped during boot (a flat CMOS battery, the first network time sync),
# so the result's time was a week before "now minus uptime". The boot id does not care.
fresh
printf 'result=unhealthy\nchecked-at=%s\nboot-id=aaaaaaaa-this-boot\nchecks=10-boot 20-network\nfailed=20-network\nmessage-20-network=NetworkManager does not answer\n' "$(( $(cat "$work/clock") - 604800 ))" > "$work/state/health"
out="$(run run)"
has_call 'rollback run 41 --reason .*health check failed.*20-network' && ok "a clock that stepped forward by a week during boot does not hide this boot's unhealthy result" || bad "clock step: $(grep rollback "$work/calls")"

# ---- the hang limit
fresh
out="$(run run)"; rc=$?
[ "$rc" = 0 ] && has_call 'rollback run 41 --reason .*did not finish its health checks within 1 minute.* --reboot' && ok "hang limit: the checks never finished within the limit (60 s here, 10 minutes in production), so it rolls back" || bad "hang limit: rc=$rc calls=$(grep -E 'rollback|sleep 5' "$work/calls" | head -3)"
up="$(cut -d' ' -f1 "$work/uptime" | cut -d. -f1)"
[ "$up" -ge 60 ] && [ "$up" -lt 80 ] && ok "hang limit: it waited until the machine had been up for the limit, no longer ($up s)" || bad "hang limit: uptime when acting $up"
fresh
export NISSE_HANG_LIMIT=600 NISSE_POLL=60
out="$(run run)"
has_call 'rollback run 41 --reason .*within 10 minutes' && ok "hang limit: the production default of 10 minutes is worded as minutes" || bad "hang limit wording: $(grep rollback "$work/calls")"
export NISSE_HANG_LIMIT=60 NISSE_POLL=5

# ---- a rollback that fails leaves the update pending
fresh
unhealthy_now
export ROLLBACK_FAIL=1
out="$(run run)"; rc=$?
[ "$rc" != 0 ] && grep -qx 'state=pending-verify' "$work/state/state" && ok "rollback refused: the watchdog fails loudly and the state stays pending-verify" || bad "rollback fail: rc=$rc"
unset ROLLBACK_FAIL

# ---- the fallback boot (GRUB gave up on the update and started the snapshot)
fresh
printf 'armed=no\nfell-back=yes\nboot-success=0\n' > "$work/boot-status"
export NISSE_FSROOT=/root/.snapshots/41/snapshot
printf 'state=idle\n' > "$work/state/state"          # the snapshot's own, older state file
out="$(run run)"; rc=$?
[ "$rc" = 0 ] && has_call 'rollback run 41 --reason .*fell back.* --reboot' && ok "fallback boot: running from snapshot 41 after GRUB fell back, it settles with a real rollback to that snapshot" || bad "fallback: rc=$rc calls=$(cat "$work/calls")"
has_call '^runuser' && ok "fallback boot: the countdown notice is shown here too" || bad "fallback: no notice"
fresh
printf 'armed=no\nfell-back=yes\nboot-success=0\n' > "$work/boot-status"
export NISSE_FSROOT=/root
printf 'state=idle\n' > "$work/state/state"
out="$(run run)"
! has_call '^rollback' && ok "fell-back flag but the normal root is running: nothing to settle" || bad "fallback flag on the normal root acted"
fresh
export NISSE_FSROOT=/root/.snapshots/41/snapshot
printf 'state=idle\n' > "$work/state/state"
out="$(run run)"
! has_call '^rollback' && ok "running from a snapshot by choice (picked from the menu, GRUB not fallen back): left alone" || bad "snapshot by choice was rolled back"
export NISSE_FSROOT=/root

# ---- the notice after a rollback (shown once per person)
fresh
printf 'state=idle\nlast=rolled-back\nrolled-back-at=99000\nsnapshot=41\nreason=the network check failed\n' > "$work/state/state"
out="$(sh "$notice" 2>&1)"; rc=$?
[ "$rc" = 0 ] && has_call '^notify-send' && has_call 'notify-send .*undid\|notify-send .*undone' && ok "after-boot notice: tells the person the update was undone" || bad "after-boot notice: rc=$rc calls=$(cat "$work/calls")"
has_call 'notify-send .*the network check failed' && ok "after-boot notice: says why" || bad "after-boot notice: no reason"
has_call 'notify-send .*files' && ok "after-boot notice: says their files were not touched" || bad "after-boot notice: no word on files"
: > "$work/calls"
out="$(sh "$notice" 2>&1)"
! has_call '^notify-send' && ok "after-boot notice: shown once (the person's marker remembers it)" || bad "after-boot notice shown twice"
printf 'state=idle\nlast=rolled-back\nrolled-back-at=99500\nsnapshot=41\nreason=again\n' > "$work/state/state"
out="$(sh "$notice" 2>&1)"
has_call '^notify-send' && ok "after-boot notice: a later rollback is told again" || bad "after-boot notice: second rollback silent"
fresh
printf 'state=idle\nlast=verified\n' > "$work/state/state"
out="$(sh "$notice" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ! has_call '^notify-send' && ok "after-boot notice: silent when the last update was fine" || bad "after-boot notice: spoke without a rollback"
fresh
rm -f "$work/state/state"
out="$(sh "$notice" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ! has_call '^notify-send' && ok "after-boot notice: silent with no state file" || bad "after-boot notice: no state rc=$rc"

# ---- plain ASCII only
fresh
unhealthy_now
run run >/dev/null
if LC_ALL=C grep -q -P '[^\x00-\x7F]' "$work/calls"; then bad "a notice or reason holds a non-ASCII character"; else ok "everything the watchdog says is plain ASCII"; fi
if LC_ALL=C grep -q -P '[^\x00-\x7F]' "$tool" "$notice"; then bad "a script holds a non-ASCII character"; else ok "the scripts are plain ASCII"; fi

# ---- usage
fresh
out="$(run bogus)"; rc=$?
[ "$rc" = 2 ] && ok "an unknown command prints usage and exits 2" || bad "usage rc=$rc"

rm -rf "$work"
echo
if [ "$failures" = 0 ]; then echo "nisse-update-watchdog: all checks passed"; else echo "nisse-update-watchdog: $failures FAILED"; exit 1; fi
