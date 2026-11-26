#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Fails if a sentence nisse writes has no closing mark (ledger N-501b, Bert's standing rule of 2026-11-25: a full sentence ends
# with a full stop, a question mark, an exclamation mark or a colon; labels, buttons and menu entries stay bare). The strings
# judged to be labels are listed with their reasons in tools/repo/sentence_labels.txt.
set -euo pipefail
cd "$(dirname "$0")/../.."
python tools/repo/sentence_punctuation.py check
python -m pytest -q -p no:cacheprovider tools/repo/tests/test_sentence_punctuation.py
