#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-306e: nisse's own C++ tests in the fork (forks/nisse-setup/tests): the root helper's logic and the listing parser. Run in the
# Fedora build VM (the KDE build dependencies are there). The helper's logic is also run against the REAL nisse-choices, which
# this script builds from services first.
set -u
cd "$(dirname "$0")/../.."
root="$PWD"
echo "building the real engine (cargo)"
(cd services && cargo build -p nisse-choices >/dev/null 2>&1) || { echo "FAIL: cannot build nisse-choices"; exit 1; }
engine="$root/services/target/debug/nisse-choices"
[ -x "$engine" ] || { echo "FAIL: no $engine"; exit 1; }
build="$(mktemp -d)"
trap 'rm -rf "$build"' EXIT
cmake -S forks/nisse-setup -B "$build" -DBUILD_TESTING=ON -DCMAKE_BUILD_TYPE=Debug >"$build/configure.log" 2>&1 || { echo "FAIL: configure"; tail -5 "$build/configure.log"; exit 1; }
cmake --build "$build" --target choiceset_test choiceslisting_test -j"$(nproc)" >"$build/build.log" 2>&1 || { echo "FAIL: build"; grep -E "error" "$build/build.log" | head; exit 1; }
out="$(cd "$build" && NISSE_CHOICES_REAL="$engine" ctest -R '_test$' -V 2>&1)"
echo "$out" | grep -E "^ *[0-9]+: (PASS|FAIL|SKIP)" | sed 's/^ *[0-9]*: //' | head -30
if echo "$out" | grep -q 'SKIP.*withTheRealEngine'; then echo "FAIL: the real-engine test was skipped"; exit 1; fi
echo "$out" | grep -q 'PASS   : ChoiceSetTest::withTheRealEngine' || { echo "FAIL: the real-engine test did not run"; exit 1; }
echo "$out" | grep -E "tests passed|tests failed" | tail -1
echo "$out" | grep -q '100% tests passed' && echo "PASS: the fork's C++ tests" || { echo "FAIL: some tests failed"; exit 1; }
