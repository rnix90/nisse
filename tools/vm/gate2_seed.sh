#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Run in the live image by gate2.py (N-219) with the image's daemon already on the session bus: makes a session with a
# message, two held approvals and a paired device, so the panel's pages have something to show.
set -u
probe="$HOME/g2/device_probe"
call() { busctl --user --json=short call org.nisse.Daemon1 /org/nisse/Daemon1 org.nisse.Daemon1 "$@"; }
datum() { python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0])'; }

if [ "${1:-}" = approvals ]; then
    # filed after the daemon restart: approvals do not survive one (they expire), so the screenshots need them fresh
    sid="$(cat "$HOME/g2/ui/sid")"
    call RequestApproval sssss "$sid" guardrail Bash "Bash: git push origin main (leaves this computer)" '{}' >/dev/null
    call RequestApproval sssss "$sid" guardrail Write "Write: /etc/hosts (outside the project)" '{}' >/dev/null
    echo "SEED approvals filed"
    exit 0
fi
sid="$(call NewSession | datum)"
echo "$sid" > "$HOME/g2/ui/sid"
call RenameSession ss "$sid" "Gate check" >/dev/null
call SendMessage ss "$sid" "ping from the gate" >/dev/null
sleep 2
code="$(call StartPairing ss "Bert phone" full | datum | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["code"])')"
"$probe" pair 7 "$code" >/dev/null
echo "SEED sid=$sid paired=$(call ListDevices | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["data"][0]))')"
