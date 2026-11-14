#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Checks the built nisse-daemon RPM. Run in the Fedora build VM after: tools/rpm/build-rpm.sh nisse-daemon
set -euo pipefail
cd "$(dirname "$0")/../.."
fail() { echo "FAIL: $*" >&2; exit 1; }

rpmf="$(ls -v out/rpmbuild/RPMS/x86_64/nisse-daemon-[0-9]*.rpm 2>/dev/null | tail -1 || true)"
[ -n "$rpmf" ] || fail "nisse-daemon RPM not found (run tools/rpm/build-rpm.sh nisse-daemon)"
member() { rpm2cpio "$rpmf" | cpio -i --to-stdout --quiet "./$1"; }

files="$(rpm -qlp "$rpmf")"
for f in /usr/bin/nisse-daemon /usr/bin/nisse-audit-hook /usr/lib/systemd/user/nisse-daemon.service \
         /usr/share/dbus-1/services/org.nisse.Daemon1.service /usr/share/nisse/claude-settings.json; do
    printf '%s\n' "$files" | grep -qxF "$f" || fail "RPM lacks $f"
done

rpm -qp --requires "$rpmf" | grep -q 'nisse-release-common' || fail "nisse-daemon must require nisse-release-common (owner of /usr/share/nisse)"
member usr/share/nisse/claude-settings.json | grep -q '/usr/bin/nisse-audit-hook' || fail "settings must register nisse-audit-hook"
settings="$(member usr/share/nisse/claude-settings.json)"
for event in PreToolUse PostToolUse; do
    grep -q "\"$event\"" <<< "$settings" || fail "settings must hook $event (a command that wedges the machine never reaches PostToolUse)"
done
python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert all(d["hooks"][e][0]["hooks"][0]["command"]=="/usr/bin/nisse-audit-hook" for e in ("PreToolUse","PostToolUse"))' <<< "$settings" || fail "both hooks must run /usr/bin/nisse-audit-hook"
# N-204: the guardrail hold is in the daemon's own settings, before any call runs, with a timeout longer than the longest
# approval wait (a hook that times out lets the call run), and only on PreToolUse.
printf '%s\n' "$files" | grep -qxF /usr/bin/nisse-guard-hook || fail "RPM lacks /usr/bin/nisse-guard-hook"
python3 - "$settings" <<'PY' || fail "daemon settings must hold the guard hook on PreToolUse only, with a timeout of at least 1200"
import json, sys
d = json.loads(sys.argv[1])
pre = [h for g in d["hooks"]["PreToolUse"] for h in g["hooks"]]
guards = [h for h in pre if h["command"] == "/usr/bin/nisse-guard-hook"]
assert len(guards) == 1 and guards[0]["timeout"] >= 1200, guards
assert all(h["command"] != "/usr/bin/nisse-guard-hook" for g in d["hooks"]["PostToolUse"] for h in g["hooks"])
PY
# N-226: audit every claude run on the machine (terminal sessions too), but never limit one.
printf '%s\n' "$files" | grep -qxF "/etc/claude-code/managed-settings.json" || fail "RPM lacks /etc/claude-code/managed-settings.json"
managed="$(member etc/claude-code/managed-settings.json)"
python3 - "$managed" <<'PY' || fail "managed settings must hold exactly the two --managed audit hooks and nothing else"
import json, sys
d = json.loads(sys.argv[1])
assert set(d) == {"hooks"}, "only hooks may be set: %s" % sorted(d)   # no allowManagedHooksOnly, no permissions
assert set(d["hooks"]) == {"PreToolUse", "PostToolUse"}, sorted(d["hooks"])
for event, groups in d["hooks"].items():
    cmds = [h["command"] for g in groups for h in g["hooks"]]
    assert cmds == ["/usr/bin/nisse-audit-hook --managed"], (event, cmds)
PY
# N-223: the guardrail never goes into the machine-wide file, so a terminal session is never held or blocked.
! grep -q 'guard' <<< "$managed" || fail "managed settings must not hold the guardrail hook (terminal sessions are never limited)"
grep -q 'allowManagedHooksOnly' <<< "$managed" && fail "managed settings must not set allowManagedHooksOnly (it would switch off the daemon's own hook)"
rpm -qp -c "$rpmf" | grep -qxF /etc/claude-code/managed-settings.json || fail "managed settings must be a config file (edits survive upgrades)"
# The daemon's own settings keep the plain hook: a daemon session is recorded by it, and the managed hook skips daemon sessions.
! grep -q -- '--managed' <<< "$settings" || fail "the daemon's own settings must not use --managed"
member usr/share/dbus-1/services/org.nisse.Daemon1.service | grep -qx 'SystemdService=nisse-daemon.service' || fail "D-Bus service must activate the user unit"
member usr/lib/systemd/user/nisse-daemon.service | grep -qx 'BusName=org.nisse.Daemon1' || fail "unit must claim org.nisse.Daemon1"
[ "$(rpm -qp --qf '%{LICENSE}' "$rpmf")" = "GPL-2.0-or-later" ] || fail "License must be GPL-2.0-or-later"

out="$(rpmlint "$rpmf" 2>&1 || true)"
echo "$out" | tail -3
errors="$(echo "$out" | grep -oE '[0-9]+ errors' | tail -1 | cut -d' ' -f1)"
[ "${errors:-0}" = "0" ] || fail "rpmlint reported $errors errors"
echo "PASS: nisse-daemon"
