# SPDX-License-Identifier: GPL-2.0-or-later
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import progress  # noqa: E402

LEDGER = HERE.parents[2] / "docs" / "planning" / "TASK-LEDGER.md"

SAMPLE = """## STAGE 1 - First
- [x] **N-101** `[build]` **A.** done.
- [ ] **N-102** `[build]` **B.** open.
- [ ] **N-103** `[phone]` **C.** open.
## STAGE 2 - Second
- [~] **N-201** `[gate]` **G.** half way.
- [-] **N-202** `[build]` **Dropped.** not counted.
## DEFERRED
- [ ] **N-D01** `[build]` **Later.** not counted.
"""


def test_counts_and_weights_per_stage():
    stages = progress.measure(SAMPLE)
    assert [s.name for s in stages] == ["STAGE 1 - First", "STAGE 2 - Second"]
    s1, s2 = stages
    assert (s1.done, s1.total) == (1, 3)
    # build weighs 3, phone 0.5: done 3 of 6.5
    assert (s1.done_weight, s1.total_weight) == (3, 6.5)
    # in progress counts half of a gate (weight 6); dropped and deferred tasks are not counted
    assert (s2.done, s2.total) == (0, 1)
    assert (s2.done_weight, s2.total_weight) == (3, 6)


def test_overall_percent_is_by_weight_not_by_count():
    stages = progress.measure(SAMPLE)
    assert progress.percent(stages) == round(100 * 6 / 12.5)


def test_the_next_open_task_is_the_first_not_done_in_file_order():
    assert progress.next_open(SAMPLE) == "N-102"


def test_the_real_ledger_reports_a_sane_percentage():
    stages = progress.measure(LEDGER.read_text(encoding="utf-8"))
    assert stages and 0 < progress.percent(stages) < 100
    assert sum(s.total for s in stages) > 100


def test_the_report_names_the_next_task_and_the_percent():
    text = progress.report(SAMPLE)
    assert "48%" in text and "Next open: N-102" in text
