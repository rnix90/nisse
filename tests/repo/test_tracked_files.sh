#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Fails if a file the build needs is untracked or git-ignored (a fresh clone could not build the ISO).
set -u
cd "$(dirname "$0")/../.."
failures=0
for f in build/FEDORA_RELEASE build/build-iso.sh build/build-all.sh build/kickstart/fedora-live-kde.flat.ks \
         build/kickstart/nisse-live.ks tools/rpm/build-rpm.sh tools/rpm/make-repo.sh tools/vm/smoke-boot.sh \
         packaging/rpm/nisse-release/nisse-release.spec services/Cargo.lock; do
    if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
        echo "ok   tracked: $f"
    else
        echo "FAIL not tracked: $f"; failures=$((failures + 1))
    fi
done
ignored="$(git ls-files --others --ignored --exclude-standard -- build packaging tools tests hw services docs panel 2>/dev/null | grep -vE '(target/|__pycache__|\.pyc$|/build/|\.pytest_cache)' || true)"
if [ -n "$ignored" ]; then echo "FAIL ignored source files:"; echo "$ignored"; failures=$((failures + 1)); fi
if [ "$failures" -eq 0 ]; then echo "PASS: tracked files"; else echo "$failures failure(s)"; exit 1; fi
