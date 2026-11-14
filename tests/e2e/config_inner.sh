#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Run by panel_daemon.sh inside a private session bus (N-216): the settings panel's client edits and saves the config
# through the real daemon, and the daemon uses what was saved. $1 = daemon, $2 = panel, $3 = scratch folder.
set -euo pipefail
daemon="$1" panel="$2" work="$3"
fail() { echo "FAIL: $*" >&2; exit 1; }

export NISSE_CONFIG="$work/settings-n216.toml" NISSE_STATE="$work/sessions-n216.json"
"$daemon" &
daemon_pid=$!
trap 'kill $daemon_pid 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do
    busctl --user introspect org.nisse.Daemon1 /org/nisse/Daemon1 >/dev/null 2>&1 && break
    sleep 0.2
done

"$panel" --self-test-config >"$work/panel-config.out" 2>&1 || fail "panel client failed: $(cat "$work/panel-config.out")"
out="$(cat "$work/panel-config.out")"
echo "$out"
grep -qx 'source: default' <<<"$out" || fail "there was no file yet, so the source should be default"
grep -qx 'authority before: autonomous' <<<"$out" || fail "the default authority was not autonomous"
grep -qx 'save error: ' <<<"$out" || fail "the daemon refused a good config"
grep -qx 'authority after: supervised' <<<"$out" || fail "the daemon did not use the saved authority"
grep -q '^bad save: .*ghost' <<<"$out" || fail "a bad config was not refused with the reason"
grep -qx 'main after bad save: max' <<<"$out" || fail "a refused save changed the config"
grep -q 'authority = "supervised"' "$NISSE_CONFIG" || fail "the file was not written as expected"
grep -q 'approval_expiry_secs = 120' "$NISSE_CONFIG" || fail "the approval wait was not saved"
grep -q '"kind":"config-changed"' "$NISSE_AUDIT_LOG" || fail "the change was not audited"
echo "config e2e ok"
