#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-306b spike: which Claude Code hook events bracket one turn of a terminal session, and what do they carry?
# Run in the Fedora build VM, signed in to Claude Code (4 tiny real prompts). The probe hooks go in the machine-wide
# managed settings file for the run (the file the nisse audit hook uses) and are removed again.
set -u
managed=/etc/claude-code/managed-settings.json
work="$(mktemp -d)"
log="$work/events.log"
cleanup() { sudo rm -f "$managed"; [ -f "$work/managed.orig" ] && sudo cp "$work/managed.orig" "$managed"; rm -rf "$work"; }
trap cleanup EXIT
[ -f "$managed" ] && sudo cp "$managed" "$work/managed.orig"

cat > "$work/probe.py" <<'EOF'
# records: event, session id, tool name, stop_hook_active, whether NISSE_SESSION is set, the payload's other keys
import json, os, sys, time
d = json.load(sys.stdin)
here = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(here, "events.log"), "a") as f:
    f.write(json.dumps({
        "t": round(time.time(), 2), "event": d.get("hook_event_name"), "session": (d.get("session_id") or "")[:8],
        "tool": d.get("tool_name"), "stop_hook_active": d.get("stop_hook_active"),
        "nisse_session_env": bool(os.environ.get("NISSE_SESSION")),
        "keys": sorted(k for k in d if k not in ("hook_event_name", "session_id")),
    }) + chr(10))
EOF
hook() { printf '{"type":"command","command":"python3 %s","timeout":30}' "$work/probe.py"; }
events="PreToolUse PostToolUse UserPromptSubmit Stop SessionStart SessionEnd SubagentStop"
{
    printf '{"hooks":{'
    first=1
    for e in $events; do
        [ $first = 1 ] || printf ','
        first=0
        if [ "$e" = PreToolUse ] || [ "$e" = PostToolUse ]; then printf '"%s":[{"matcher":"*","hooks":[%s]}]' "$e" "$(hook)"
        else printf '"%s":[{"hooks":[%s]}]' "$e" "$(hook)"; fi
    done
    printf '}}'
} > "$work/managed.json"
sudo mkdir -p /etc/claude-code && sudo cp "$work/managed.json" "$managed"

cd "$work" || exit 1
show() { echo "--- $1"; cat "$log" 2>/dev/null | python3 -c 'import sys,json
for l in sys.stdin:
    d=json.loads(l); print("   %-17s tool=%-5s stop_hook_active=%-5s nisse_env=%s keys=%s" % (d["event"], d["tool"], d["stop_hook_active"], d["nisse_session_env"], ",".join(d["keys"])))'; : > "$log"; }
: > "$log"

echo "A. a turn with no tool call"
timeout 120 claude -p "Reply with the single word: ok" < /dev/null >/dev/null 2>&1; echo "   exit=$?"
show "events for A"

echo "B. a turn that changes a file (Bash)"
timeout 180 claude -p "Use the Bash tool to run exactly: echo hi > $work/made.txt   Then reply: done" --dangerously-skip-permissions < /dev/null >/dev/null 2>&1; echo "   exit=$? file=$(cat "$work/made.txt" 2>/dev/null)"
show "events for B"

echo "C. a turn that only reads (Read tool)"
echo "hello" > "$work/readme.txt"
timeout 180 claude -p "Use the Read tool on $work/readme.txt and reply with its first word." --dangerously-skip-permissions < /dev/null >/dev/null 2>&1; echo "   exit=$?"
show "events for C"

echo "D. the same with NISSE_SESSION set (a daemon session): do hooks still fire, and is the variable visible?"
NISSE_SESSION=fake-daemon-session timeout 120 claude -p "Reply with the single word: ok" < /dev/null >/dev/null 2>&1; echo "   exit=$?"
show "events for D"

echo "E. a run killed in the middle (SIGTERM during the turn): is Stop ever sent?"
( timeout -s TERM 8 claude -p "Use the Bash tool to run: sleep 60   Then reply: done" --dangerously-skip-permissions >/dev/null 2>&1 ); echo "   exit=$?"
sleep 2
show "events for E"
