#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""N-508: take the dropped apps out of Fedora's own package lists in the RENDERED kiwi description.

dnf5 refuses `install X --exclude=X` (it says the argument matches only excluded packages) and kiwi runs exactly that when a package is
both listed and <ignore>d. Fedora's vendored description lists a few apps by name (components/desktops/common.xml names mediawriter), so
when nisse drops one (a "drop" line of build/default-apps.txt) the line is removed from the rendered copy; the vendored tree under
build/kiwi/fedora stays as published, and build/render-kiwi.sh calls this after copying. Files under nisse/ are never touched.

    python3 tools/build/apply_drops.py DESCRIPTION_DIR [POLICY_FILE]
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def dropped(policy):
    out = []
    for line in Path(policy).read_text(encoding="ascii").splitlines():
        if line.strip() and not line.startswith("#"):
            kind, package, *_ = line.split("|")
            if kind == "drop":
                out.append(package)
    return out


def apply(description, policy=ROOT / "build" / "default-apps.txt"):
    """Remove each dropped package's <package> line from the vendored XML files; returns [(relative file, package)]."""
    description = Path(description)
    names = dropped(policy)
    removed = []
    for path in sorted(description.rglob("*.xml")):
        rel = path.relative_to(description).as_posix()
        if rel.startswith("nisse/"):
            continue
        text = path.read_text(encoding="utf-8")
        for name in names:
            pattern = re.compile(r"^[ \t]*<package name=\"" + re.escape(name) + r"\"\s*/>[ \t]*\n", re.M)
            text, n = pattern.subn("", text)
            removed += [(rel, name)] * n
        path.write_text(text, encoding="utf-8", newline="")
    return removed


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if not argv or len(argv) > 2:
        print(__doc__)
        return 2
    for rel, name in apply(*argv):
        print(f"apply_drops: {name} taken out of {rel}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
