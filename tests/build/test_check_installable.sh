#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Unit test of tools/rpm/check-installable.sh with a fake dnf: it must pass a clean resolution and fail the 2026-11-19 failure
# (nisse-panel built against Qt 6.11 while the release repository has Qt 6.10).
set -euo pipefail
cd "$(dirname "$0")/../.."
fail() { echo "FAIL: $*" >&2; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/repo/repodata"; : > "$tmp/repo/repodata/repomd.xml"
export NISSE_REPO_DIR="$tmp/repo"

cat > "$tmp/dnf-ok" <<'EOF'
#!/usr/bin/env bash
echo "Transaction Summary:"; echo " Installing: 120 packages"; echo "Operation aborted by the user."; exit 1
EOF
cat > "$tmp/dnf-qt" <<'EOF'
#!/usr/bin/env bash
echo "Problem 1: cannot install the best candidate for the job"
echo "  - nothing provides libQt6Core.so.6(Qt_6.11)(64bit) needed by nisse-panel-0.1-17.fc44.x86_64 from nisse"
exit 1
EOF
cat > "$tmp/dnf-odd" <<'EOF'
#!/usr/bin/env bash
echo "something unexpected"; exit 1
EOF
chmod +x "$tmp"/dnf-*

NISSE_DNF="$tmp/dnf-ok" bash tools/rpm/check-installable.sh > "$tmp/out" 2>&1 || fail "a clean resolution was refused: $(cat "$tmp/out")"
grep -q '^ok ' "$tmp/out" || fail "no ok line"
echo "ok   a clean resolution passes"

if NISSE_DNF="$tmp/dnf-qt" bash tools/rpm/check-installable.sh > "$tmp/out" 2>&1; then fail "the Qt 6.11 failure passed"; fi
grep -q 'nothing provides' "$tmp/out" || fail "the failure does not show the missing provides"
grep -q 'build VM is ahead' "$tmp/out" || fail "the failure does not say what to do"
echo "ok   the Qt 6.11 drift is caught with the cause named"

if NISSE_DNF="$tmp/dnf-odd" bash tools/rpm/check-installable.sh > "$tmp/out" 2>&1; then fail "unexpected dnf output passed"; fi
echo "ok   unexpected dnf output fails instead of passing silently"

rm -rf "$tmp/repo"
if NISSE_DNF="$tmp/dnf-ok" bash tools/rpm/check-installable.sh > "$tmp/out" 2>&1; then fail "a missing repo passed"; fi
echo "ok   a missing local repo fails"
echo "PASS: check-installable"
