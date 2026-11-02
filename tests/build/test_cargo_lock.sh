#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# services/Cargo.lock must match the manifests: the RPM build runs `cargo build --release --locked`, which fails when a
# dependency was added without committing the updated lock file. Needs cargo, so it runs in the build VM.
set -u
cd "$(dirname "$0")/../../services"
if ! command -v cargo >/dev/null 2>&1; then
    echo "skip: cargo not installed; run this test in the build VM"
    exit 0
fi
if cargo metadata --locked --format-version 1 >/dev/null 2>"${TMPDIR:-/tmp}/cargo-lock.err"; then
    echo "PASS: Cargo.lock matches the manifests"
else
    echo "FAIL: Cargo.lock is out of date: $(tail -2 "${TMPDIR:-/tmp}/cargo-lock.err" | tr '\n' ' ')"
    exit 1
fi
