#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Fails if a short string nisse writes (a label, button, menu entry, heading or field name of two to five words) is not in headline
# case, like "Computer Settings" (ledger N-501c, Bert's standing rule of 2026-11-26). Sentences are the other rule (N-501b). The
# strings judged not to be short strings are listed with their reasons in tools/repo/headline_exceptions.txt.
set -euo pipefail
cd "$(dirname "$0")/../.."
python tools/repo/headline_case.py check
python -m pytest -q -p no:cacheprovider tools/repo/tests/test_headline_case.py
