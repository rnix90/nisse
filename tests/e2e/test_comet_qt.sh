#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-404: Qt draws the comet spinner and the splash's RotationAnimator turns it. Run in the Fedora build VM
# (qt6-qtdeclarative and qt6-qtsvg installed, no display needed): tests/e2e/test_comet_qt.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
fail() { echo "FAIL: $*" >&2; exit 1; }

runner=""
for c in qmltestrunner qmltestrunner6 /usr/lib64/qt6/bin/qmltestrunner /usr/lib/qt6/bin/qmltestrunner; do
    if command -v "$c" >/dev/null 2>&1; then runner="$c"; break; fi
done
[ -n "$runner" ] || fail "qmltestrunner not found (install qt6-qtdeclarative-devel)"
[ -f assets/art/comet/svg/nisse-comet.svg ] || fail "assets/art/comet/svg/nisse-comet.svg missing (run python tools/art/comet.py)"

out="$(QT_QPA_PLATFORM=offscreen "$runner" -input tests/qml/tst_comet.qml 2>&1)" || { echo "$out" | tail -30; fail "the comet QML tests failed"; }
echo "$out" | grep -E '^(PASS|FAIL|Totals)' | head -12
echo "$out" | grep -q '^FAIL' && fail "a comet QML test failed"
echo "$out" | grep -qE 'Totals: [1-9][0-9]* passed, 0 failed' || fail "no passing totals in the output"
echo "PASS: comet spinner in Qt"
