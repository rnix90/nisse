# SPDX-License-Identifier: GPL-2.0-or-later
"""Progress read for docs/planning/TASK-LEDGER.md: done and open tasks per stage and a rough percentage by work.

Run:  python tools/ledger/progress.py [path]

The percentage is by weight, not by task count, because a phone decision is minutes and a gate is an ISO rebuild plus
every check. Weights are a judgement, kept here in one place: build 3, art 3, desk 1, phone 0.5, gate 6. A task in
progress counts half; dropped tasks and the DEFERRED section are left out.
"""
import re
import sys
from dataclasses import dataclass
from pathlib import Path

WEIGHT = {"build": 3.0, "art": 3.0, "desk": 1.0, "phone": 0.5, "gate": 6.0}
TASK = re.compile(r"^- \[(.)\] \*\*(N-\d+[a-z]?)\*\* `\[(\w+)\]`")


@dataclass
class Stage:
    name: str
    done: int = 0
    total: int = 0
    done_weight: float = 0.0
    total_weight: float = 0.0


def measure(text):
    stages = []
    current = None
    for line in text.splitlines():
        if line.startswith("## "):
            current = None
            if line.startswith("## STAGE"):
                current = Stage(line[3:].strip())
                stages.append(current)
            continue
        m = TASK.match(line)
        if not m or current is None:
            continue
        status, _id, tag = m.groups()
        if status == "-":
            continue
        weight = WEIGHT.get(tag, 3.0)
        current.total += 1
        current.total_weight += weight
        if status == "x":
            current.done += 1
            current.done_weight += weight
        elif status == "~":
            current.done_weight += weight / 2
    return stages


def percent(stages):
    total = sum(s.total_weight for s in stages)
    done = sum(s.done_weight for s in stages)
    return round(100 * done / total) if total else 0


def next_open(text):
    """The first task in file order that is not done, as the protocol says (stages only, not DEFERRED)."""
    in_stage = False
    for line in text.splitlines():
        if line.startswith("## "):
            in_stage = line.startswith("## STAGE")
            continue
        m = TASK.match(line)
        if in_stage and m and m.group(1) in " ~!":
            return m.group(2)
    return None


def report(text):
    stages = measure(text)
    lines = []
    for s in stages:
        pct = round(100 * s.done_weight / s.total_weight) if s.total_weight else 0
        lines.append(f"{s.name}: {s.done}/{s.total} tasks, {pct}% by work")
    done = sum(s.done for s in stages)
    total = sum(s.total for s in stages)
    lines.append(f"Overall: {done} of {total} tasks done, about {percent(stages)}% by work")
    lines.append(f"Next open: {next_open(text)}")
    return "\n".join(lines)


if __name__ == "__main__":
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2] / "docs" / "planning" / "TASK-LEDGER.md"
    print(report(path.read_text(encoding="utf-8")))
