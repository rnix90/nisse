#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-305: tests the three nisse-snapshots scripts (hook, setup, prune) against a fake snapper. No btrfs, no root.
# The real snapper on a real btrfs is tests/e2e/test_snapshots_btrfs.sh (build VM).
set -u
cd "$(dirname "$0")/../.."
dir="$PWD/packaging/rpm/nisse-snapshots"
hook="$dir/nisse-snapshot-hook"
setup="$dir/nisse-snapshot-setup"
prune="$dir/nisse-snapshot-prune"
batch="$dir/nisse-snapshot-batch"
failures=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; failures=$((failures + 1)); }

# A fresh sandbox: a fake snapper that records every call and answers from files, a config dir and a state dir.
fresh() {
    work="$(mktemp -d)"
    mkdir -p "$work/state" "$work/confdir"
    export NISSE_SNAPPER="$work/snapper"
    export NISSE_STATE_DIR="$work/state"
    export NISSE_SNAPPER_CONFDIR="$work/confdir"
    export NISSE_ROOT_FSTYPE=btrfs
    export NISSE_FREE_PERCENT=60
    export NISSE_SNAPSHOT_TEMPLATE="$work/root.conf"
    export TZ=UTC
    printf 'TIMELINE_CREATE=no\nNUMBER_LIMIT=40\n' > "$work/root.conf"
    echo 41 > "$work/next"
    cat > "$work/snapper" <<'STUB'
#!/bin/sh
# fake snapper: record the call, then answer. STUB_FAIL=<verb> makes that verb exit 1.
echo "$@" >> "$STUB_DIR/calls"
while [ "${1#-}" != "$1" ]; do
    case "$1" in -c | --separator) shift ;; esac
    shift
done
verb="$1"; shift
[ "${STUB_FAIL:-}" = "$verb" ] && exit 1
case "$verb" in
    create)
        n=$(cat "$STUB_DIR/next"); echo $((n + 1)) > "$STUB_DIR/next"
        [ -n "${STUB_BAD_NUMBER:-}" ] && { echo "oops"; exit 0; }
        echo "$n" ;;
    list) cat "$STUB_DIR/list" ;;
    create-config) touch "$NISSE_SNAPPER_CONFDIR/root" ;;
esac
exit 0
STUB
    chmod +x "$work/snapper"
    export STUB_DIR="$work"
    unset STUB_FAIL STUB_BAD_NUMBER
    : > "$work/calls"
}
has_call() { grep -q -- "$1" "$work/calls"; }

# ---- hook: stands aside while safe-apply (N-308) takes its own pair around the same dnf transaction
fresh; touch "$work/confdir/root"
export NISSE_SNAPSHOT_SKIP=1; out="$(sh "$hook" pre 2>&1)"; rc=$?
[ "$rc" = 0 ] && ! has_call 'create' && ok "hook pre: NISSE_SNAPSHOT_SKIP=1 takes no snapshot (safe-apply has its own pair)" || bad "hook pre with skip: rc=$rc calls=$(cat "$work/calls")"
echo 7 > "$work/state/pre-number"
sh "$hook" post >/dev/null 2>&1; unset NISSE_SNAPSHOT_SKIP
! has_call 'create' && ok "hook post: NISSE_SNAPSHOT_SKIP=1 takes no snapshot either" || bad "hook post with skip took a snapshot"

# ---- hook
fresh; touch "$work/confdir/root"
out="$(sh "$hook" pre 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "hook pre: exit 0" || bad "hook pre: exit $rc"
has_call 'create -t pre -p -c number -d' && ok "hook pre: takes a pre snapshot with the number cleanup algorithm" || bad "hook pre: no pre snapshot call: $(cat "$work/calls")"
has_call '--no-dbus -c root' && ok "hook pre: talks to snapper directly (no daemon cache)" || bad "hook pre: not --no-dbus -c root"
[ "$(cat "$work/state/pre-number" 2>/dev/null)" = 41 ] && ok "hook pre: remembers the snapshot number" || bad "hook pre: state file is '$(cat "$work/state/pre-number" 2>/dev/null)'"
case "$out" in *"log.INFO=nisse-snapshots: pre snapshot 41"*) ok "hook pre: logs the id for dnf";; *) bad "hook pre: no log line: $out";; esac
if LC_ALL=C grep -q '[^ -~]' "$work/calls"; then bad "hook pre: non-ASCII in a snapper argument"; else ok "hook pre: ASCII arguments"; fi

sh "$hook" post > "$work/out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "hook post: exit 0" || bad "hook post: exit $rc"
has_call 'create -t post --pre-number 41 -p -c number -d' && ok "hook post: pairs with pre snapshot 41" || bad "hook post: no paired post call: $(cat "$work/calls")"
[ ! -e "$work/state/pre-number" ] && ok "hook post: clears the state" || bad "hook post: state file left behind"
grep -q 'post snapshot 42' "$work/out" && ok "hook post: logs the id" || bad "hook post: no log line"

fresh; touch "$work/confdir/root"
sh "$hook" post >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ! has_call create && ok "hook post without a pre: does nothing, exit 0" || bad "hook post without a pre: rc=$rc calls=$(cat "$work/calls")"

fresh; touch "$work/confdir/root"; NISSE_ROOT_FSTYPE=ext4 sh "$hook" pre >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ ! -s "$work/calls" ] && ok "hook on a non-btrfs root: skipped, exit 0" || bad "hook on ext4: rc=$rc calls=$(cat "$work/calls")"

fresh
sh "$hook" pre >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ ! -s "$work/calls" ] && ok "hook without a root config: skipped, exit 0" || bad "hook without config: rc=$rc calls=$(cat "$work/calls")"

fresh; touch "$work/confdir/root"; NISSE_FREE_PERCENT=5 sh "$hook" pre > "$work/out" 2>&1; rc=$?
[ "$rc" = 0 ] && ! has_call create && grep -q 'log.WARNING=nisse-snapshots: .*5% free' "$work/out" \
    && ok "hook with under 10% free: skips the snapshot and says why" || bad "hook low space: rc=$rc out=$(cat "$work/out")"

fresh; touch "$work/confdir/root"; STUB_FAIL=create sh "$hook" pre > "$work/out" 2>&1; rc=$?
[ "$rc" = 0 ] && [ ! -e "$work/state/pre-number" ] && grep -q 'log.WARNING' "$work/out" \
    && ok "hook when snapper fails: warns, exit 0 (never blocks the transaction)" || bad "hook snapper fails: rc=$rc out=$(cat "$work/out")"

fresh; touch "$work/confdir/root"; STUB_BAD_NUMBER=1 sh "$hook" pre > "$work/out" 2>&1; rc=$?
[ "$rc" = 0 ] && [ ! -e "$work/state/pre-number" ] && ok "hook with a non-numeric answer: ignored" || bad "hook bad number: rc=$rc state=$(cat "$work/state/pre-number" 2>/dev/null)"

fresh; touch "$work/confdir/root"; sh "$hook" sideways >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "hook: unknown mode is a usage error (2)" || bad "hook: unknown mode exit $rc, wanted 2"

# ---- setup
fresh
sh "$setup" > "$work/out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "setup: exit 0 on btrfs without a config" || bad "setup: exit $rc: $(cat "$work/out")"
has_call 'create-config /' && ok "setup: creates the root config for /" || bad "setup: no create-config call"
has_call 'set-config TIMELINE_CREATE=no NUMBER_LIMIT=40' && ok "setup: applies every line of the template in one set-config" || bad "setup: set-config missing: $(cat "$work/calls")"

fresh; NISSE_SNAPSHOT_SUBVOLUME=/srv/test sh "$setup" >/dev/null 2>&1
has_call 'create-config /srv/test' && ok "setup: the subvolume can be overridden for tests" || bad "setup: NISSE_SNAPSHOT_SUBVOLUME ignored"

fresh; touch "$work/confdir/root"; sh "$setup" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ ! -s "$work/calls" ] && ok "setup: leaves an existing root config alone" || bad "setup: touched an existing config (rc=$rc)"

fresh; NISSE_ROOT_FSTYPE=xfs sh "$setup" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ ! -s "$work/calls" ] && ok "setup: skips a non-btrfs root" || bad "setup: acted on xfs (rc=$rc)"

fresh; STUB_FAIL=create-config sh "$setup" >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ok "setup: create-config failure is exit 1" || bad "setup: create-config failure exit $rc"

fresh; STUB_FAIL=set-config sh "$setup" >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && has_call 'delete-config' && ok "setup: a half-applied config is deleted so the next boot retries" || bad "setup: set-config failure rc=$rc calls=$(cat "$work/calls")"

# ---- prune: 14 days
now=1795000000   # fixed clock
iso() { date -u -d "@$1" '+%Y-%m-%d %H:%M:%S'; }
day=86400
fresh; touch "$work/confdir/root"
export NISSE_NOW=$now
cat > "$work/list" <<EOF
number,type,pre-number,date,cleanup,default,active
0,single,,,,no,no
1,pre,,$(iso $((now - 20 * day))),number,no,no
2,post,1,$(iso $((now - 20 * day + 5))),number,no,no
3,pre,,$(iso $((now - 10 * day))),number,no,no
4,post,3,$(iso $((now - 10 * day + 5))),number,no,no
5,pre,,$(iso $((now - 30 * day))),number,no,no
6,single,,$(iso $((now - 40 * day))),,no,no
7,pre,,$(iso $((now - 25 * day))),number,no,yes
8,post,7,$(iso $((now - 25 * day + 5))),number,no,yes
9,pre,,$(iso $((now - 25 * day))),number,yes,no
10,post,9,$(iso $((now - 25 * day + 5))),number,yes,no
11,pre,,$(iso $((now - 15 * day))),number,no,no
12,post,11,$(iso $((now - 13 * day))),number,no,no
EOF
sh "$prune" > "$work/out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "prune: exit 0" || bad "prune: exit $rc: $(cat "$work/out")"
del="$(grep ' delete ' "$work/calls" | sed 's/.* delete //' | tr ' ' '\n' | sort -n | tr '\n' ' ')"
[ "$del" = "1 2 5 " ] && ok "prune: deletes the old pair (1,2) and the old orphan pre (5)" || bad "prune: deleted '$del', wanted '1 2 5 '"
case " $del" in *" 3 "*|*" 4 "*) bad "prune: deleted the 10-day-old pair";; *) ok "prune: keeps a 10-day-old pair";; esac
case " $del" in *" 6 "*) bad "prune: deleted a snapshot nisse did not make (no number cleanup tag)";; *) ok "prune: never touches snapshots without the number cleanup tag";; esac
case " $del" in *" 7 "*|*" 8 "*) bad "prune: deleted the active snapshot";; *) ok "prune: never deletes the active snapshot";; esac
case " $del" in *" 9 "*|*" 10 "*) bad "prune: deleted the default snapshot";; *) ok "prune: never deletes the default snapshot";; esac
case " $del" in *" 11 "*|*" 12 "*) bad "prune: broke a pair whose post is only 13 days old";; *) ok "prune: a pair is judged by its post, so a 15/13-day pair stays";; esac

fresh; touch "$work/confdir/root"; export NISSE_NOW=$now
printf 'number,type,pre-number,date,cleanup,default,active\n0,single,,,,no,no\n3,pre,,%s,number,no,no\n4,post,3,%s,number,no,no\n' "$(iso $((now - 2 * day)))" "$(iso $((now - 2 * day)))" > "$work/list"
sh "$prune" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ! has_call ' delete ' && ok "prune: nothing old, nothing deleted" || bad "prune: deleted fresh snapshots (rc=$rc)"

fresh; export NISSE_NOW=$now
sh "$prune" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ ! -s "$work/calls" ] && ok "prune: no root config, nothing to do" || bad "prune: no config rc=$rc"

fresh; touch "$work/confdir/root"; export NISSE_NOW=$now; STUB_FAIL=list sh "$prune" >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ok "prune: snapper list failure is exit 1" || bad "prune: list failure exit $rc"

fresh; touch "$work/confdir/root"; export NISSE_NOW=$now NISSE_SNAPSHOT_MAX_AGE_DAYS=5
printf 'number,type,pre-number,date,cleanup,default,active\n3,pre,,%s,number,no,no\n4,post,3,%s,number,no,no\n' "$(iso $((now - 6 * day)))" "$(iso $((now - 6 * day)))" > "$work/list"
sh "$prune" >/dev/null 2>&1
has_call ' delete 3 4' || has_call ' delete 4 3' && ok "prune: the age limit is NISSE_SNAPSHOT_MAX_AGE_DAYS" || bad "prune: age override ignored: $(cat "$work/calls")"
unset NISSE_SNAPSHOT_MAX_AGE_DAYS NISSE_NOW

# ---- batch: the snapshot pair around one AI turn (the daemon runs it through sudo, so its arguments are checked strictly)
sess=0d9b6f0e-1c2a-4f10-9d3e-5b7c8a9d0e11
fresh; touch "$work/confdir/root"
out="$(sh "$batch" pre "$sess" 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$out" = "pre=41" ] && ok "batch pre: exit 0 and prints pre=41" || bad "batch pre: rc=$rc out=$out"
has_call "create -t pre -p -c number -d AI turn: before -u nisse=ai-batch,session=$sess" && ok "batch pre: a number-tagged pre snapshot with the session in its userdata" || bad "batch pre: call was $(cat "$work/calls")"
has_call '--no-dbus -c root' && ok "batch pre: talks to snapper directly" || bad "batch pre: not --no-dbus"

fresh; touch "$work/confdir/root"; NISSE_ROOT_FSTYPE=ext4 sh "$batch" pre "$sess" > "$work/out" 2>&1; rc=$?
[ "$rc" = 10 ] && grep -q '^skip=' "$work/out" && [ ! -s "$work/calls" ] && ok "batch pre on a non-btrfs root: quiet skip (exit 10)" || bad "batch pre ext4: rc=$rc out=$(cat "$work/out")"
fresh; sh "$batch" pre "$sess" > "$work/out" 2>&1; rc=$?
[ "$rc" = 10 ] && grep -q '^skip=' "$work/out" && [ ! -s "$work/calls" ] && ok "batch pre without a root config: quiet skip (exit 10)" || bad "batch pre no config: rc=$rc"
fresh; touch "$work/confdir/root"; NISSE_FREE_PERCENT=5 sh "$batch" pre "$sess" > "$work/out" 2>&1; rc=$?
[ "$rc" = 11 ] && grep -q '^skip=.*5% free' "$work/out" && [ ! -s "$work/calls" ] && ok "batch pre with under 10% free: loud skip (exit 11) with the reason" || bad "batch pre low space: rc=$rc out=$(cat "$work/out")"
fresh; touch "$work/confdir/root"; STUB_FAIL=create sh "$batch" pre "$sess" > "$work/out" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q '^error=' "$work/out" && ok "batch pre when snapper fails: exit 1 with error=" || bad "batch pre snapper fails: rc=$rc"
fresh; touch "$work/confdir/root"; STUB_BAD_NUMBER=1 sh "$batch" pre "$sess" > "$work/out" 2>&1; rc=$?
[ "$rc" = 1 ] && ok "batch pre with a non-numeric answer: exit 1" || bad "batch pre bad number: rc=$rc"
for badsess in 'a;b' 'a b' '$(id)' '../x' '' "$(printf 'x%.0s' $(seq 1 70))"; do
    fresh; touch "$work/confdir/root"; sh "$batch" pre "$badsess" >/dev/null 2>&1; rc=$?
    [ "$rc" = 2 ] && [ ! -s "$work/calls" ] && ok "batch pre rejects the session id '$(printf %.12s "$badsess")' (exit 2, snapper not called)" || bad "batch pre accepted a bad session id '$badsess' (rc=$rc)"
done

fresh; touch "$work/confdir/root"; echo 42 > "$work/next"
out="$(sh "$batch" post 41 "$sess" 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$out" = "post=42" ] && ok "batch post: exit 0 and prints post=42" || bad "batch post: rc=$rc out=$out"
has_call "create -t post --pre-number 41 -p -c number -d AI turn: after -u nisse=ai-batch,session=$sess" && ok "batch post: pairs with the pre snapshot and keeps the userdata" || bad "batch post: call was $(cat "$work/calls")"
fresh; touch "$work/confdir/root"; STUB_FAIL=create sh "$batch" post 41 "$sess" > "$work/out" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q '^error=' "$work/out" && ok "batch post when snapper fails: exit 1 with error=" || bad "batch post snapper fails: rc=$rc"
for badnum in 'x' '4 1' '41;id' '' '1234567890123'; do
    fresh; touch "$work/confdir/root"; sh "$batch" post "$badnum" "$sess" >/dev/null 2>&1; rc=$?
    [ "$rc" = 2 ] && [ ! -s "$work/calls" ] && ok "batch post rejects the pre number '$badnum'" || bad "batch post accepted a bad pre number '$badnum' (rc=$rc)"
done

fresh; touch "$work/confdir/root"
printf 'number;type;pre-number;userdata
0;single;;
41;pre;;nisse=ai-batch, session=%s
42;post;41;nisse=ai-batch, session=%s
' "$sess" "$sess" > "$work/list"
sh "$batch" drop 41 42 >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && has_call ' delete 41 42' && ok "batch drop: deletes our paired snapshots" || bad "batch drop: rc=$rc calls=$(cat "$work/calls")"
fresh; touch "$work/confdir/root"
printf 'number;type;pre-number;userdata
0;single;;
41;pre;;
42;post;41;
' > "$work/list"
sh "$batch" drop 41 42 >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ! has_call ' delete ' && ok "batch drop refuses snapshots that are not nisse AI batches" || bad "batch drop deleted a foreign pair (rc=$rc)"
fresh; touch "$work/confdir/root"
printf 'number;type;pre-number;userdata
0;single;;
41;pre;;nisse=ai-batch
42;post;40;nisse=ai-batch
' > "$work/list"
sh "$batch" drop 41 42 >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ! has_call ' delete ' && ok "batch drop refuses a post that is not paired with that pre" || bad "batch drop deleted an unpaired post (rc=$rc)"
# a read-only turn only ever has its pre snapshot: drop PRE alone removes it, if it is ours and nothing is paired with it
fresh; touch "$work/confdir/root"
printf 'number;type;pre-number;userdata
0;single;;
41;pre;;nisse=ai-batch, session=%s
' "$sess" > "$work/list"
sh "$batch" drop 41 >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && has_call ' delete 41' && ! has_call ' delete 41 ' && ok "batch drop PRE: deletes a lone pre snapshot of ours" || bad "batch drop PRE: rc=$rc calls=$(cat "$work/calls")"
fresh; touch "$work/confdir/root"
printf 'number;type;pre-number;userdata
0;single;;
41;pre;;nisse=ai-batch
42;post;41;nisse=ai-batch
' > "$work/list"
sh "$batch" drop 41 >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ! has_call ' delete ' && ok "batch drop PRE: refuses a pre that already has a post" || bad "batch drop PRE deleted a paired pre (rc=$rc)"
fresh; touch "$work/confdir/root"
printf 'number;type;pre-number;userdata
0;single;;
41;pre;;
' > "$work/list"
sh "$batch" drop 41 >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ! has_call ' delete ' && ok "batch drop PRE: refuses a pre that is not an AI batch" || bad "batch drop PRE deleted a foreign pre (rc=$rc)"
fresh; touch "$work/confdir/root"; sh "$batch" drop >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "batch drop with no number is a usage error (exit 2)" || bad "batch drop with no number: rc=$rc"
fresh; touch "$work/confdir/root"; sh "$batch" drop 41 x >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "batch drop rejects a bad second number (exit 2)" || bad "batch drop with a bad post number: rc=$rc"
fresh; touch "$work/confdir/root"; sh "$batch" sideways >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "batch: unknown mode is a usage error (2)" || bad "batch: unknown mode rc=$rc"

# ---- every script is ASCII, executable text with an SPDX header
for f in "$hook" "$setup" "$prune" "$batch"; do
    if LC_ALL=C grep -q '[^ -~	]' "$f"; then bad "$(basename "$f") has non-ASCII"; else ok "$(basename "$f") is ASCII"; fi
    head -3 "$f" | grep -q 'SPDX-License-Identifier: GPL-2.0-or-later' && ok "$(basename "$f") has the SPDX header" || bad "$(basename "$f") lacks the SPDX header"
    sh -n "$f" 2>/dev/null && ok "$(basename "$f") parses" || bad "$(basename "$f") has a syntax error"
done

echo
[ "$failures" = 0 ] && echo "PASS: snapshot scripts" || { echo "$failures failed"; exit 1; }
