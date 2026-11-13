# SPDX-License-Identifier: GPL-2.0-or-later
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import check  # noqa: E402

LEDGER = HERE.parents[2] / "docs" / "planning" / "TASK-LEDGER.md"

GOOD = """## STAGE 1
- [ ] **N-101** `[phone]` **A.** x. *Source:* s. *Done when:* y. *Depends:* none.
- [ ] **N-102** `[gate]` **G.** x. *Certifies:* N-101. *Done when:* y. *Depends:* N-101.
## DEFERRED
- [ ] **N-D01** `[build]` **Later.** x. **Unblocks when:** N-101 is done.
"""


def test_the_real_ledger_is_sound():
    assert check.check_text(LEDGER.read_text(encoding="utf-8")) == []


def test_a_good_ledger_passes():
    assert check.check_text(GOOD) == []


def test_a_duplicate_id_is_refused():
    bad = GOOD + "- [ ] **N-101** `[phone]` **Again.** *Done when:* y. *Depends:* none.\n"
    assert any("duplicate" in p for p in check.check_text(bad))


def test_a_deferred_task_without_unblocks_when_is_refused():
    bad = GOOD.replace("**Unblocks when:** N-101 is done.", "later.")
    assert any("Unblocks when" in p for p in check.check_text(bad))


def test_a_gate_without_certifies_is_refused():
    bad = GOOD.replace("*Certifies:* N-101. ", "")
    assert any("Certifies" in p for p in check.check_text(bad))


def test_a_task_without_done_when_is_refused():
    bad = GOOD.replace("*Done when:* y. ", "", 1)
    assert any("Done when" in p for p in check.check_text(bad))


def test_a_reference_to_a_missing_task_is_refused():
    bad = GOOD.replace("*Depends:* none.", "*Depends:* N-999.")
    assert any("N-999" in p for p in check.check_text(bad))


def test_an_unknown_tag_is_refused():
    bad = GOOD.replace("[phone]", "[maybe]")
    assert any("unknown tag" in p for p in check.check_text(bad))


def test_non_ascii_is_refused():
    bad = GOOD + "caf" + chr(233) + "\n"
    assert any("non-ASCII" in p for p in check.check_text(bad))
