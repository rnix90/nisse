#!/bin/bash
# N-219c: a REAL claude turn that prints a fake key leaves a redacted audit record. The real claude CLI, the real nisse-audit-hook
# binary as its PreToolUse and PostToolUse hook, and a key made up at run time (so no token-shaped text sits in this public file).
# Run in the build VM, signed in (claude auth login), after `cargo build -p nisse-audit` in services/:
#   bash tools/build/vm.sh ssh bash -s < tools/claude-probe/live_redact.sh
# One short prompt, one tool call.
set -u
R=/tmp/live219c
rm -rf "$R"; mkdir -p "$R/work"
HOOK=/home/builder/nisse/services/target/debug/nisse-audit-hook
[ -x "$HOOK" ] || { echo "FAIL: build the hook first: cargo build -p nisse-audit"; exit 2; }
KEY="sk-ant-api03-$(python3 -c 'import random,string; r=random.Random(7); print("".join(r.choice(string.ascii_letters+string.digits) for _ in range(90)))')"
# a wrapper that notes every call (the event name and the payload size) before handing the payload to the real hook
printf '#!/bin/sh
cat > %s/payload.$$
echo "$(date +%%s) $(wc -c < %s/payload.$$) $(head -c 300 %s/payload.$$ | grep -o "hook_event_name[^,]*" | head -1)" >> %s/calls.log
%s < %s/payload.$$
' "$R" "$R" "$R" "$R" "$HOOK" "$R" > "$R/hook.sh"
chmod +x "$R/hook.sh"
printf '{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"%s"}]}],"PostToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"%s"}]}]}}' "$R/hook.sh" "$R/hook.sh" > "$R/settings.json"
cd "$R/work"
NISSE_AUDIT_LOG="$R/audit.jsonl" timeout 240 claude -p "Use the Bash tool to run exactly this command, then reply only: done
echo MY_SECRET_NOTE_KEY=$KEY; python3 -c \"print('x' * 20000)\"" \
    --settings "$R/settings.json" --dangerously-skip-permissions > "$R/reply.txt" 2>&1
echo "reply: $(head -c 120 "$R/reply.txt" | tr '\n' ' ')"
echo "hook calls:"; cat "$R/calls.log" 2>/dev/null
echo "records: $(wc -l < "$R/audit.jsonl" 2>/dev/null || echo 0)"
if grep -q "$KEY" "$R/audit.jsonl" 2>/dev/null; then echo "FAIL: the key is in the audit log"; exit 1; fi
python3 - "$R/audit.jsonl" <<'PY'
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
bash = [r for r in recs if (r.get("detail") or {}).get("tool_name") == "Bash"]
print("bash records:", len(bash))
ok = False
for r in bash:
    ch = r.get("changed") or {}
    print(" ", r["detail"].get("hook_event_name"), "changed:", json.dumps(ch)[:300])
    text = json.dumps(r["detail"])
    if "[redacted: " in text and ch.get("redacted"):
        ok = True
    if len(json.dumps(r)) > 20000:
        print("FAIL: a record is larger than 20 KB"); sys.exit(1)
print("PASS: a real turn that printed a fake key left a redacted, flagged record" if ok else "FAIL: no redacted record found")
sys.exit(0 if ok else 1)
PY
