#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-306a: tests the three nisse-sudo scripts (the mode switch, the sudo shim and the password popup helper) with stubs.
# No root and no real sudo needed. The real sudo is tests/e2e/test_sudo_modes.sh (build VM).
set -u
cd "$(dirname "$0")/../.."
dir="$PWD/packaging/rpm/nisse-sudo"
modetool="$dir/nisse-sudo-mode"
shim="$dir/nisse-sudo-shim"
askpass="$dir/nisse-askpass"
failures=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; failures=$((failures + 1)); }

fresh() {
    work="$(mktemp -d)"
    mkdir -p "$work/templates" "$work/sudoers.d" "$work/etc"
    cp "$dir/sudoers-full" "$dir/sudoers-limited" "$work/templates/"
    export NISSE_SUDO_TEMPLATES="$work/templates"
    export NISSE_SUDOERS_DROPIN="$work/sudoers.d/50-nisse-sudo"
    export NISSE_SUDO_MODE_FILE="$work/etc/sudo-mode"
    export NISSE_VISUDO="$work/visudo"
    # a stand-in visudo: -cf FILE succeeds unless the file says BROKEN
    printf '#!/bin/sh\nfor last; do :; done\nif grep -q BROKEN "$last"; then echo "parse error" >&2; exit 1; fi\necho "$last: parsed OK"\n' > "$work/visudo"
    chmod +x "$work/visudo"
    unset NISSE_REAL_SUDO NISSE_SUDO_SHIM_TTY SUDO_ASKPASS NISSE_KDIALOG NISSE_ASKPASS_TIMEOUT
}

# ---- templates
for t in full limited; do
    f="$dir/sudoers-$t"
    [ -f "$f" ] && ok "sudoers-$t exists" || bad "sudoers-$t is missing"
done
grep -qx '%wheel ALL=(ALL) NOPASSWD: ALL' "$dir/sudoers-full" && ok "full: wheel runs anything without a password" || bad "full: wrong rule"
grep -qx '%wheel ALL=(root) NOPASSWD: /usr/libexec/nisse/nisse-snapshot-batch' "$dir/sudoers-limited" && ok "limited: only the snapshot helper is passwordless" || bad "limited: wrong helper rule"
grep -qx '%wheel ALL=(root) NOPASSWD: /usr/bin/nisse-rollback list' "$dir/sudoers-limited" && ok "limited: listing the snapshots (nisse-rollback list, read-only, exactly that argument) is passwordless, so the panel's undo list opens without a password box" || bad "limited: no passwordless rollback list"
if grep -E 'NOPASSWD:.*nisse-rollback' "$dir/sudoers-limited" | grep -vqx '%wheel ALL=(root) NOPASSWD: /usr/bin/nisse-rollback list'; then bad "limited: nisse-rollback is passwordless for more than 'list' (the rollback itself must ask for the password)"; else ok "limited: the rollback itself is not passwordless (the person types the password in the popup)"; fi
grep -qx 'Defaults:%wheel timestamp_type=global' "$dir/sudoers-limited" && ok "limited: one answer is remembered for callers with no terminal" || bad "limited: no global timestamp"
if grep -q 'NOPASSWD: ALL' "$dir/sudoers-limited"; then bad "limited must not allow everything"; else ok "limited does not allow everything"; fi

# ---- the mode switch
fresh
out="$(sh "$modetool" status 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$out" = full ] && ok "status with no mode file: full (the default)" || bad "status default: rc=$rc out=$out"

fresh
sh "$modetool" limited >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && cmp -s "$dir/sudoers-limited" "$NISSE_SUDOERS_DROPIN" && ok "limited: the drop-in is the limited template" || bad "limited: drop-in wrong (rc=$rc)"
[ "$(cat "$NISSE_SUDO_MODE_FILE")" = limited ] && [ "$(sh "$modetool" status)" = limited ] && ok "limited: the mode file and status say limited" || bad "limited: mode file wrong"
mode="$(stat -c %a "$NISSE_SUDOERS_DROPIN")"; case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) [ "$mode" = 444 ] && mode=440 ;; esac   # Windows has no 0440
[ "$mode" = 440 ] && ok "the drop-in is mode 0440 (sudo refuses anything looser)" || bad "drop-in mode is $(stat -c %a "$NISSE_SUDOERS_DROPIN")"
ls "$work/sudoers.d" | grep -qx '50-nisse-sudo' && [ "$(ls "$work/sudoers.d" | wc -l)" = 1 ] && ok "no temporary file is left in sudoers.d" || bad "sudoers.d holds: $(ls -A "$work/sudoers.d" | tr '\n' ' ')"

sh "$modetool" full >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && cmp -s "$dir/sudoers-full" "$NISSE_SUDOERS_DROPIN" && [ "$(cat "$NISSE_SUDO_MODE_FILE")" = full ] && ok "full: switches back" || bad "full: did not switch back (rc=$rc)"
sh "$modetool" full >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok "setting the same mode again is fine" || bad "same mode twice: rc=$rc"

# a template that visudo rejects must never reach sudoers.d (a broken file locks everyone out of sudo)
fresh
sh "$modetool" full >/dev/null 2>&1
before="$(cat "$NISSE_SUDOERS_DROPIN")"
echo 'BROKEN rule' >> "$NISSE_SUDO_TEMPLATES/sudoers-limited"
sh "$modetool" limited > "$work/out" 2>&1; rc=$?
[ "$rc" = 1 ] && [ "$(cat "$NISSE_SUDOERS_DROPIN")" = "$before" ] && [ "$(cat "$NISSE_SUDO_MODE_FILE")" = full ] \
    && ok "a template visudo rejects: exit 1, drop-in and mode unchanged" || bad "broken template: rc=$rc drop-in changed or mode changed"
[ "$(ls -A "$work/sudoers.d" | wc -l)" = 1 ] && ok "a rejected template leaves no temporary file behind" || bad "leftovers: $(ls -A "$work/sudoers.d" | tr '\n' ' ')"

fresh; rm "$NISSE_SUDO_TEMPLATES/sudoers-limited"
sh "$modetool" limited >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ok "a missing template: exit 1" || bad "missing template: rc=$rc"
fresh; sh "$modetool" sideways >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "an unknown mode is a usage error (2)" || bad "unknown mode: rc=$rc"
fresh; sh "$modetool" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok "no argument prints the status (exit 0)" || bad "no argument: rc=$rc"
fresh; echo 'wat' > "$NISSE_SUDO_MODE_FILE"; out="$(sh "$modetool" status 2>&1)"; rc=$?
[ "$out" = unknown ] && ok "a garbled mode file reads as unknown" || bad "garbled mode file: $out"

# ---- the sudo shim
stub_sudo() { printf '#!/bin/sh\necho "$@" > "%s/sudo.args"\necho "askpass=${SUDO_ASKPASS:-}" >> "%s/sudo.args"\n' "$work" "$work" > "$work/sudo"; chmod +x "$work/sudo"; export NISSE_REAL_SUDO="$work/sudo"; }
fresh; stub_sudo; echo full > "$NISSE_SUDO_MODE_FILE"
sh "$shim" -u root id >/dev/null 2>&1
[ "$(head -1 "$work/sudo.args")" = "-u root id" ] && ok "shim, full mode: sudo is called exactly as asked" || bad "shim full: $(cat "$work/sudo.args")"
fresh; stub_sudo
sh "$shim" true >/dev/null 2>&1
[ "$(head -1 "$work/sudo.args")" = "true" ] && ok "shim, no mode file (full): unchanged" || bad "shim no mode: $(cat "$work/sudo.args")"
fresh; stub_sudo; echo limited > "$NISSE_SUDO_MODE_FILE"
NISSE_SUDO_SHIM_TTY=no sh "$shim" dnf install tree >/dev/null 2>&1
[ "$(head -1 "$work/sudo.args")" = "-A dnf install tree" ] && ok "shim, limited, no terminal: adds -A so the password popup is used" || bad "shim limited no tty: $(cat "$work/sudo.args")"
grep -qx 'askpass=/usr/libexec/nisse/nisse-askpass' "$work/sudo.args" && ok "shim, limited: names the popup helper when SUDO_ASKPASS is not set" || bad "shim: askpass not named: $(cat "$work/sudo.args")"
fresh; stub_sudo; echo limited > "$NISSE_SUDO_MODE_FILE"
SUDO_ASKPASS=/custom/askpass NISSE_SUDO_SHIM_TTY=no sh "$shim" true >/dev/null 2>&1
grep -qx 'askpass=/custom/askpass' "$work/sudo.args" && ok "shim: a SUDO_ASKPASS already set is kept" || bad "shim overrode SUDO_ASKPASS"
fresh; stub_sudo; echo limited > "$NISSE_SUDO_MODE_FILE"
NISSE_SUDO_SHIM_TTY=yes sh "$shim" true >/dev/null 2>&1
[ "$(head -1 "$work/sudo.args")" = "true" ] && ok "shim, limited, with a terminal: unchanged (sudo asks on the terminal)" || bad "shim limited tty: $(cat "$work/sudo.args")"
fresh; stub_sudo; echo limited > "$NISSE_SUDO_MODE_FILE"
NISSE_SUDO_SHIM_TTY=no sh "$shim" -n true >/dev/null 2>&1
[ "$(head -1 "$work/sudo.args")" = "-A -n true" ] && ok "shim passes -n through untouched (-n still wins in sudo)" || bad "shim with -n: $(cat "$work/sudo.args")"
fresh; printf '#!/bin/sh\nexit 7\n' > "$work/sudo"; chmod +x "$work/sudo"; export NISSE_REAL_SUDO="$work/sudo"
sh "$shim" true >/dev/null 2>&1; rc=$?
[ "$rc" = 7 ] && ok "shim: sudo's exit status is passed through" || bad "shim exit status $rc, wanted 7"

# ---- the password popup helper
stub_kdialog() { printf '#!/bin/sh\necho "$@" > "%s/kdialog.args"\n%s\n' "$work" "$1" > "$work/kdialog"; chmod +x "$work/kdialog"; export NISSE_KDIALOG="$work/kdialog"; }
fresh; stub_kdialog 'echo s3cret'
out="$(sh "$askpass" '[sudo] password for bert: ' 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$out" = s3cret ] && ok "askpass: prints the typed password and exits 0" || bad "askpass: rc=$rc out=$out"
grep -q -- '--password' "$work/kdialog.args" && grep -q -- '--title' "$work/kdialog.args" && ok "askpass: uses a kdialog password box with a title" || bad "askpass args: $(cat "$work/kdialog.args")"
grep -q 'password for bert' "$work/kdialog.args" && ok "askpass: shows sudo's own prompt text" || bad "askpass: prompt not shown"
fresh; stub_kdialog 'exit 1'
sh "$askpass" 'p' >/dev/null 2>&1; rc=$?
[ "$rc" != 0 ] && ok "askpass: a cancelled popup is a failure (sudo treats it as no password)" || bad "askpass: cancel returned 0"
fresh; stub_kdialog 'sleep 30'
start=$(date +%s); NISSE_ASKPASS_TIMEOUT=1 sh "$askpass" 'p' >/dev/null 2>&1; rc=$?; took=$(( $(date +%s) - start ))
[ "$rc" != 0 ] && [ "$took" -lt 10 ] && ok "askpass: an unanswered popup gives up after the timeout (so a turn is never stuck for ever)" || bad "askpass timeout: rc=$rc took=${took}s"
fresh; NISSE_KDIALOG="$work/no-such-kdialog" sh "$askpass" 'p' > "$work/out" 2>&1; rc=$?
[ "$rc" != 0 ] && grep -q 'kdialog' "$work/out" && ok "askpass: without kdialog it fails and says why" || bad "askpass without kdialog: rc=$rc out=$(cat "$work/out")"

# ---- every script is ASCII, with an SPDX header, and parses
for f in "$modetool" "$shim" "$askpass" "$dir/sudoers-full" "$dir/sudoers-limited"; do
    [ -f "$f" ] || { bad "$(basename "$f") is missing"; continue; }
    if LC_ALL=C grep -q '[^ -~	]' "$f"; then bad "$(basename "$f") has non-ASCII"; else ok "$(basename "$f") is ASCII"; fi
    head -3 "$f" | grep -q 'SPDX-License-Identifier: GPL-2.0-or-later' && ok "$(basename "$f") has the SPDX header" || bad "$(basename "$f") lacks the SPDX header"
done
for f in "$modetool" "$shim" "$askpass"; do
    [ -f "$f" ] && { sh -n "$f" 2>/dev/null && ok "$(basename "$f") parses" || bad "$(basename "$f") has a syntax error"; }
done

echo
[ "$failures" = 0 ] && echo "PASS: sudo scripts" || { echo "$failures failed"; exit 1; }
