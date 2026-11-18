#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-306b: the REAL claude CLI, the REAL machine-wide hook mechanism (managed settings), the real nisse-turn-hook, the real
# nisse-snapshot-batch through sudo and the real snapper on a throwaway loop btrfs. Run in the Fedora build VM, signed in to
# Claude Code (3 tiny prompts), after: (cd services && cargo build -p nisse-daemon --bin nisse-turn-hook)
# The managed settings file is backed up and put back, so the VM is left as it was.
set -u
cd "$(dirname "$0")/../.."
root="$PWD"
hook="$root/services/target/debug/nisse-turn-hook"
batch="$root/packaging/rpm/nisse-snapshots/nisse-snapshot-batch"
failures=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; failures=$((failures + 1)); }
[ -x "$hook" ] || { echo "FAIL: build the hook first: (cd services && cargo build -p nisse-daemon --bin nisse-turn-hook)"; exit 1; }
command -v claude >/dev/null || { echo "FAIL: claude is not installed in this VM"; exit 1; }

cfg=nisseterm
managed=/etc/claude-code/managed-settings.json
work="$(mktemp -d)"
img="$(mktemp -u /tmp/nisse-term-XXXXXX.img)"
mnt="$(mktemp -d /tmp/nisse-term-mnt-XXXXXX)"
[ -f "$managed" ] && sudo cp "$managed" "$work/managed.orig"
cleanup() {
    sudo rm -f "$managed"
    [ -f "$work/managed.orig" ] && sudo cp "$work/managed.orig" "$managed"
    sudo snapper --no-dbus -c "$cfg" delete-config >/dev/null 2>&1
    sudo rm -f "/etc/snapper/configs/$cfg"
    sudo umount "$mnt" 2>/dev/null
    rm -rf "$img" "$mnt" "$work"
}
trap cleanup EXIT
chmod 755 "$work"

truncate -s 1G "$img" && sudo mkfs.btrfs -q -f "$img" && sudo mount -o loop "$img" "$mnt" || { echo "FAIL: cannot make the loop btrfs"; exit 1; }
sudo chown "$(id -u)" "$mnt"
sudo env NISSE_SNAPSHOT_CONFIG="$cfg" NISSE_SNAPSHOT_SUBVOLUME="$mnt" NISSE_ROOT_FSTYPE=btrfs \
    NISSE_SNAPSHOT_TEMPLATE="$root/packaging/rpm/nisse-snapshots/root.conf" sh "$root/packaging/rpm/nisse-snapshots/nisse-snapshot-setup" >/dev/null \
    || { echo "FAIL: snapshot setup"; exit 1; }

# the helper the hook calls: the real one, as root, pointed at the loop config
cat > "$work/batch" <<EOF
#!/bin/sh
exec sudo -n env NISSE_SNAPSHOT_CONFIG=$cfg NISSE_ROOT_FSTYPE=btrfs NISSE_FREE_PERCENT=90 "$batch" "\$@"
EOF
chmod 755 "$work/batch"

# the machine-wide managed settings, as the nisse-daemon package ships them but with the hook's environment set
hookcmd="env NISSE_SNAPSHOT_BATCH=$work/batch NISSE_SNAPSHOT_SUDO=0 NISSE_AUDIT_LOG=$work/audit.jsonl XDG_RUNTIME_DIR=$work/run $hook"
python3 - "$hookcmd" "$root/packaging/rpm/nisse-daemon/managed-settings.json" > "$work/managed.json" <<'PY'
import json, sys
cmd, path = sys.argv[1], sys.argv[2]
d = json.load(open(path))
for groups in d["hooks"].values():
    for g in groups:
        for h in g["hooks"]:
            if h["command"] == "/usr/bin/nisse-turn-hook":
                h["command"] = cmd
            else:
                h["command"] = "true"   # the audit hook is not under test here
print(json.dumps(d))
PY
sudo mkdir -p /etc/claude-code && sudo cp "$work/managed.json" "$managed"

snaps() { sudo snapper --no-dbus -c "$cfg" --csvout --separator ';' list --columns number,type,pre-number,userdata | tail -n +2; }
count() { snaps | grep -c ';\(pre\|post\);'; }
audit_snap() { python3 -c 'import json,sys
for l in open(sys.argv[1]):
    d = json.loads(l)
    if d["kind"] == "snapshot": print(d["session"], d["source"], d["detail"]["phase"], d["detail"].get("pre", ""), d["detail"].get("snapshot", ""))' "$work/audit.jsonl" 2>/dev/null; }
cd "$work" || exit 1

echo "1. a chat turn (no tool): the pair must be removed again"
before="$(count)"
timeout 150 claude -p "Reply with the single word: ok" < /dev/null >/dev/null 2>&1
[ "$(count)" = "$before" ] && ok "a turn with no tool leaves no snapshot behind" || bad "snapshots before $before, after $(count)"
audit_snap | grep -q ' terminal pre ' && audit_snap | grep -q ' terminal dropped ' && ok "the audit log shows pre then dropped, source terminal" || bad "audit: $(audit_snap | tr '\n' '|')"

echo "2. a turn that changes a file: a real pair that brackets the change"
before="$(count)"
timeout 180 claude -p "Use the Bash tool to run exactly: echo hi > $mnt/changed.txt   Then reply: done" --dangerously-skip-permissions < /dev/null >/dev/null 2>&1
[ "$(cat "$mnt/changed.txt" 2>/dev/null)" = hi ] && ok "the turn changed the file" || bad "the file was not written (the real CLI did not run the command)"
[ "$(count)" = "$((before + 2))" ] && ok "one pair was added" || bad "snapshots before $before, after $(count)"
line="$(audit_snap | grep ' terminal post ' | tail -1)"
read -r sid src phase pre post <<< "$line"
[ -n "${pre:-}" ] && [ -n "${post:-}" ] && ok "the audit log has the post record with both ids ($pre, $post)" || bad "no post record: $(audit_snap | tr '\n' '|')"
snaps | grep -q "^$pre;pre;;.*session=$sid" && snaps | grep -q "^$post;post;$pre;.*session=$sid" && ok "snapper holds that pair, tagged with the Claude session id" || bad "snapper rows: $(snaps | tr '\n' '|')"
if [ -n "${pre:-}" ] && ! sudo test -e "$mnt/.snapshots/$pre/snapshot/changed.txt" && sudo test -e "$mnt/.snapshots/$post/snapshot/changed.txt"; then ok "the pre snapshot has no changed.txt, the post snapshot has it"; else bad "the pair does not bracket the change"; fi

echo "3. a session the daemon started (NISSE_SESSION set) is left to the daemon"
before="$(count)"; lines="$(wc -l < "$work/audit.jsonl")"
NISSE_SESSION=fake-daemon-session timeout 150 claude -p "Use the Bash tool to run exactly: echo again > $mnt/again.txt   Then reply: done" --dangerously-skip-permissions < /dev/null >/dev/null 2>&1
[ "$(cat "$mnt/again.txt" 2>/dev/null)" = again ] && ok "that turn ran too" || bad "the daemon-flagged turn did not run"
[ "$(count)" = "$before" ] && [ "$(wc -l < "$work/audit.jsonl")" = "$lines" ] && ok "no snapshot and no audit record from the terminal hook" || bad "the hook acted on a daemon session"

echo
[ "$failures" = 0 ] && echo "PASS: a real claude turn gets its snapshot pair" || { echo "$failures failed"; exit 1; }
