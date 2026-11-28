#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-507e: the background retry of the proprietary options (packaging/rpm/nisse-extras/nisse-extras-retry and its service), with stand-ins for
# nisse-choices, loginctl, runuser and notify-send. Runs anywhere with bash. The boot service must not wait for an install; the retry service
# must come after the network and never before the login screen.
set -u
cd "$(dirname "$0")/../.."
failures=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; failures=$((failures + 1)); }

script=packaging/rpm/nisse-extras/nisse-extras-retry
unit=packaging/rpm/nisse-extras/nisse-extras-retry.service
boot_unit=packaging/rpm/nisse-choices/nisse-choices-apply.service
[ -f "$script" ] || { echo "FAIL: $script is missing"; exit 1; }

s="$(mktemp -d)"
trap 'rm -rf "$s"' EXIT
bin="$s/bin"; mkdir -p "$bin"
stub() { printf '#!/bin/sh\n%s\n' "$2" > "$bin/$1"; chmod 755 "$bin/$1"; }
# nisse-choices prints what the test says; the other three record what they were asked
stub nisse-choices 'cat "$S/choices-out"; exit "$(cat "$S/choices-code" 2>/dev/null || echo 0)"'
stub loginctl 'case "$1" in
  list-sessions) cat "$S/sessions" ;;
  show-session) f="$S/session-$2"; case "$*" in *Type*) sed -n "s/^/Type=/p" "$f.type" ;; esac; case "$*" in *Active*) sed -n "s/^/Active=/p" "$f.active" ;; esac ;;
esac'
stub runuser 'echo "runuser $*" >> "$S/calls"; while [ $# -gt 0 ]; do [ "$1" = "--" ] && { shift; break; }; shift; done; exec "$@"'
stub notify-send 'echo "notify-send $*" >> "$S/calls"'
export S="$s"

run() { # choices-output [exit-code]
    printf '%s\n' "$1" > "$s/choices-out"; echo "${2:-0}" > "$s/choices-code"; : > "$s/calls"
    NISSE_RETRY_BIN="$bin" "$script" > "$s/stdout" 2>&1
    echo $? > "$s/rc"
}
session() { # id uid user type active
    printf '%s %s %s seat0 -\n' "$1" "$2" "$3" >> "$s/sessions"; echo "$4" > "$s/session-$1.type"; echo "$5" > "$s/session-$1.active"
}
notices() { grep -c '^notify-send' "$s/calls"; }

# one active graphical session, one on a text console, one that is not active
: > "$s/sessions"
session 2 1000 alice wayland yes
session 3 1001 bob tty yes
session 4 1002 carol x11 no

run "ok   extras: already in place"
[ "$(notices)" = 0 ] && [ "$(cat "$s/rc")" = 0 ] && ok "nothing pending: no notice and a clean exit" || bad "met: $(cat "$s/calls")"

run "ok   extras: applied"
[ "$(notices)" = 1 ] && grep -q 'notify-send.*Optional Software Installed' "$s/calls" && grep -q 'runuser -u alice' "$s/calls" && ok "applied: one notice, to the active graphical session only, through that user" || bad "applied: $(cat "$s/calls")"
grep -q 'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus' "$s/calls" && ok "the notice goes to that user's session bus" || bad "no session bus address: $(cat "$s/calls")"
grep -q 'installed' "$s/calls" && grep -qE '(\.|!)( |$)' "$s/calls" && ok "the text is a sentence with punctuation" || bad "text: $(cat "$s/calls")"

run "FAIL extras: exit status 1: nisse-extras: chrome: dnf failed (1): Failed to download metadata" 1
[ "$(notices)" = 1 ] && grep -q 'Optional Software Not Installed' "$s/calls" && grep -q 'Failed to download metadata' "$s/calls" && grep -q 'try again at the next start' "$s/calls" && ok "a failure is told with its reason and that it will be tried again" || bad "failure: $(cat "$s/calls")"
[ "$(cat "$s/rc")" = 0 ] && ok "a failed install does not fail the service (the next start tries again)" || bad "rc $(cat "$s/rc")"

run "FAIL extras: exit status 1: nisse-extras: chrome: no network connection: it will be tried again at the next start" 1
[ "$(notices)" = 0 ] && grep -q 'no network' "$s/stdout" && ok "no network: silent for the person, said in the journal" || bad "offline: $(cat "$s/calls") / $(cat "$s/stdout")"

long="$(printf 'x%.0s' $(seq 1 400))"
run "FAIL extras: exit status 1: bad \"quote\" \$(touch $s/pwned) $long" 1
[ ! -e "$s/pwned" ] && ok "a reason is never run as a command" || bad "command injection through the reason"
len="$(grep '^notify-send' "$s/calls" | wc -c)"
[ "$len" -lt 600 ] && ok "a long reason is cut short" || bad "notice is $len characters"

: > "$s/sessions"
run "ok   extras: applied"
[ "$(notices)" = 0 ] && grep -q 'installed' "$s/stdout" && ok "nobody logged in: no notice, the journal says it" || bad "no session: $(cat "$s/calls")"

run "" 2
[ "$(cat "$s/rc")" = 0 ] && grep -qi 'engine' "$s/stdout" && ok "an engine that fails or says nothing is logged and does not fail the service" || bad "engine failure: rc $(cat "$s/rc") $(cat "$s/stdout")"

# the service units
[ -f "$unit" ] || bad "no $unit"
grep -q '^After=.*network-online.target' "$unit" && grep -q '^Wants=network-online.target' "$unit" && ok "the retry service waits for the network" || bad "the retry service does not wait for the network"
if grep -q 'display-manager' "$unit"; then bad "the retry service is ordered around the display manager: the login screen must not wait for it"; else ok "the retry service is not ordered before the login screen"; fi
grep -q '^ConditionKernelCommandLine=!rd.live.image' "$unit" && ok "it does not run on live media" || bad "it would run on live media"
grep -q 'ExecStart=/usr/libexec/nisse/nisse-extras-retry' "$unit" && ok "it runs the retry script" || bad "ExecStart"
grep -q 'ExecStart=/usr/bin/nisse-choices apply --boot' "$boot_unit" && ok "the boot service applies with --boot, so opt-out choices wait" || bad "the boot service does not pass --boot"
grep -q '^boot = false' packaging/rpm/nisse-extras/choice-extras.toml && ok "the extras choice opts out of the boot-time apply" || bad "the extras manifest does not say boot = false"

[ "$failures" -eq 0 ] && { echo "PASS: the extras retry"; exit 0; } || { echo "$failures failure(s)"; exit 1; }
