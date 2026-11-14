#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Fails if a tracked text file prints the product name with a capital (ledger N-115, Bert 2026-11-13: always lowercase
# "nisse" whenever possible). What stays capitalised on purpose is listed in tools/repo/lowercase_name.py.
set -euo pipefail
cd "$(dirname "$0")/../.."
python tools/repo/lowercase_name.py check
