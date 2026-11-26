# SPDX-License-Identifier: GPL-2.0-or-later
"""Every full sentence nisse writes ends with punctuation (ledger N-501b; Bert's standing rule, 2026-11-25).

  python tools/repo/sentence_punctuation.py check   list the unclosed sentences in the shipped files; exit 1 if any
  python tools/repo/sentence_punctuation.py list    list every string the checker looked at (to judge labels)

The rule: a string of four words or more that starts with a capital (or with the name, "nisse", which is lowercase
even at the start of a sentence) must end with a full stop, a question mark, an exclamation mark or a colon.
Labels, buttons and menu entries are not sentences and stay bare: they are listed with the reason in
tools/repo/sentence_labels.txt (one per line: path | string | reason).

What is not checked: strings of fewer than four words, strings that start in lowercase (log-style error fragments
are outside the sweep, Bert 2026-11-26), a lead-in that ends in a space (a piece of a longer string), comments, tests,
docs, and the text upstream's own files carry (the Plasma Setup fork keeps KDE's strings so a newer upstream merges).
"""
import argparse
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
LABELS_FILE = "tools/repo/sentence_labels.txt"

# the shipped files whose strings people read
SCOPE_PREFIXES = (
    "panel/qml/", "panel/src/", "packaging/rpm/", "tools/art/boot_mocks.py",
    "assets/theme/lookandfeel/", "assets/art/wallpaper/package/nisse/metadata.json",
    "forks/nisse-setup/modules/choices/", "forks/nisse-setup/modules/choicesutil/",
    "forks/nisse-setup/src/auth/choiceset.cpp",
)
SCOPE_PATTERNS = (re.compile(r"^services/crates/[^/]+/src/"),)
OUT_PATTERNS = (re.compile(r"/tests?/"), re.compile(r"(^|/)CMakeLists\.txt$"), re.compile(r"\.(png|svg|ttf|license|spec|preset|service|timer|path|conf|repo|toml|md)$"))

BS = chr(92)
LITERAL = re.compile('"((?:[^"' + BS + BS + ']|' + BS + BS + '.)*)"')
DESKTOP = re.compile(r"^Comment=(.*)$")
CLOSERS = ".!?:"
COMMENT_START = ("//", "#", "*", "/*", "--")


def in_scope(rel):
    if any(p.search(rel) for p in OUT_PATTERNS):
        return False
    return rel.startswith(SCOPE_PREFIXES) or any(p.match(rel) for p in SCOPE_PATTERNS)


def is_sentence_start(s):
    return s[:1].isupper() or s.startswith("nisse ")


def judged(s):
    """True when the string is of the kind the rule applies to (before the closing mark is looked at)."""
    if len(s.split()) < 4 or not is_sentence_start(s):
        return False
    if s.endswith(" "):  # a lead-in joined to a value: the sentence ends in a later piece
        return False
    if len(re.findall("[A-Za-z]{2,}", s)) < 3 or "HTTP/" in s:  # path data, a protocol line: not words
        return False
    return True


def find_text(rel, text):
    """Return [(line number, string)] for each unclosed sentence in the text of file rel (labels not yet excused)."""
    return [(n, s) for n, s in _judged_strings(rel, text) if s.rstrip()[-1:] not in CLOSERS]


def _judged_strings(rel, text):
    for n, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith(COMMENT_START):
            continue
        if rel.endswith(".desktop"):
            m = DESKTOP.match(line)
            found = [m.group(1)] if m else []
        elif rel.endswith(".json"):
            found = re.findall('"Description": "([^"]*)"', line)
        else:
            found = [m.group(1) for m in LITERAL.finditer(line)]
        for s in found:
            if judged(s):
                yield n, s


def tracked_files(root):
    raw = subprocess.run(["git", "-C", str(root), "ls-files", "-z"], capture_output=True, check=True).stdout
    return [rel for rel in raw.decode("utf-8").split("\0") if rel and in_scope(rel)]


def _read(path):
    try:
        data = path.read_bytes()
        return None if b"\0" in data[:8192] else data.decode("utf-8")
    except (OSError, UnicodeDecodeError):
        return None


def all_strings(root):
    """Every (path, string) the rule applies to, closed or not."""
    out = []
    for rel in tracked_files(root):
        text = _read(root / rel)
        if text is not None:
            out.extend((rel, s) for _, s in _judged_strings(rel, text))
    return out


def load_labels(root):
    """{(path, string): reason} from the label list."""
    labels = {}
    path = root / LABELS_FILE
    if not path.is_file():
        return labels
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        parts = [p.strip() for p in line.split(" | ", 2)]
        if len(parts) == 3:
            labels[(parts[0], parts[1])] = parts[2]
    return labels


def check(root):
    """Return [(path, line number, string)] for each unclosed sentence that is not a listed label."""
    labels = load_labels(root)
    left = []
    for rel in tracked_files(root):
        text = _read(root / rel)
        if text is None:
            continue
        for n, s in find_text(rel, text):
            if (rel, s) not in labels:
                left.append((rel, n, s))
    return left


def main(argv=None):
    p = argparse.ArgumentParser(prog="sentence_punctuation.py", description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    p.add_argument("cmd", choices=["check", "list"])
    p.add_argument("--root", type=Path, default=REPO)
    a = p.parse_args(argv)
    if a.cmd == "list":
        for rel, s in all_strings(a.root):
            print(f"{rel}: {s}")
        return 0
    left = check(a.root)
    for rel, n, s in left:
        print(f"{rel}:{n}: {s}")
    if left:
        print(f"{len(left)} sentence(s) without a closing mark (close them, or list them as labels in {LABELS_FILE})", file=sys.stderr)
    return 1 if left else 0


if __name__ == "__main__":
    sys.exit(main())
