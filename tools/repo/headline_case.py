# SPDX-License-Identifier: GPL-2.0-or-later
"""Short strings are in headline case (ledger N-501c; Bert's standing rule, 2026-11-26), like "Computer Settings".

  python tools/repo/headline_case.py check   list the short strings that are not in headline case; exit 1 if any
  python tools/repo/headline_case.py list    list every short string the checker looked at

A short string is a name of a thing: a label, button, menu entry, heading, tab or field name, of two to five words, that
starts with a capital (or with the name, "nisse", or with a number) and has no closing mark. Headline case: every word starts with
a capital, except the small words (of, a, the, and, to, in, on, for ...) inside the string, and the name "nisse", which is always
lowercase. After a colon the next word is capitalized. Words with digits, placeholders and acronyms are left alone.

Full sentences are the other rule (tools/repo/sentence_punctuation.py). What is judged not to be a short string is listed with
the reason in tools/repo/headline_exceptions.txt (path | string | reason): a placeholder, a piece of a longer sentence, a date
format, a notification title (Bert: titles and the Plymouth messages stay as they are). A stale line fails the test.
Upstream's own strings in the Plasma Setup fork are not scanned; the setup window's own name is pinned by a test.
"""
import argparse
import re
import sys
from pathlib import Path

import sentence_punctuation as sp

REPO = sp.REPO
EXCEPTIONS_FILE = "tools/repo/headline_exceptions.txt"
SMALL = {"a", "an", "the", "and", "or", "nor", "but", "of", "to", "in", "on", "for", "at", "by", "as", "with", "from", "up", "vs", "off", "per"}
NAME = "nisse"
EXTRA_SCOPE = (
    "packaging/rpm/nisse-sudo/choice-sudo-mode.toml",
    "forks/nisse-setup/src/qml/Main.qml",
    "forks/nisse-setup/files/nisse-setup.desktop.in",
)
BS = chr(92)
LITERAL = sp.LITERAL
NAME_LINE = re.compile(r"^(?:Name|GenericName)=(.*)$")
TITLE_LINE = re.compile(r'^\s*title = "([^"]*)"')
JSON_NAME = re.compile('"Name": "([^"]*)"')
SKIP_CHARS = re.compile("[=/{}$<>_@" + BS + BS + "]")


def in_scope(rel):
    return rel in EXTRA_SCOPE or sp.in_scope(rel)


def _words(s):
    return s.split()


def is_headline(s):
    words = _words(s)
    after_colon = True
    for i, raw in enumerate(words):
        core = re.sub(r"^[^A-Za-z0-9%]+|[^A-Za-z0-9%]+$", "", raw)
        if not core or any(ch.isdigit() for ch in core) or core.startswith("%"):
            after_colon = raw.endswith(":")
            continue
        last = i == len(words) - 1
        if core == NAME:
            pass
        elif core.lower() == NAME:  # the name is never capitalized
            return False
        elif core.isupper() and len(core) > 1:  # an acronym: AI, HH
            pass
        elif core.lower() in SMALL and not after_colon and i != 0 and not last:
            if core != core.lower():
                return False
        elif not core[0].isupper():
            return False
        after_colon = raw.endswith(":")
    return True


def judged(s):
    """True when the string is a short string of the kind the rule applies to."""
    w = _words(s)
    if not 2 <= len(w) <= 5:
        return False
    if not (s[:1].isupper() or s.startswith(NAME + " ") or re.match(r"^(\d|%\d)", s)):
        return False
    if s.endswith(" ") or s.rstrip()[-1:] in sp.CLOSERS or SKIP_CHARS.search(s):
        return False
    if len(re.findall("[A-Za-z]{2,}", s)) < 2:
        return False
    return True


def _candidates(rel, text):
    for n, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith(sp.COMMENT_START):
            continue
        if rel.endswith((".desktop", ".desktop.in")):
            m = NAME_LINE.match(line)
            found = [m.group(1)] if m else []
        elif rel.endswith(".toml"):
            m = TITLE_LINE.match(line)
            found = [m.group(1)] if m else []
        elif rel.endswith(".json"):
            found = JSON_NAME.findall(line)
        else:
            found = [m.group(1) for m in LITERAL.finditer(line)]
        for s in found:
            if judged(s):
                yield n, s


def find_text(rel, text):
    """Return [(line number, string)] for each short string in file rel that is not in headline case."""
    return [(n, s) for n, s in _candidates(rel, text) if not is_headline(s)]


def _files(root):
    import subprocess
    raw = subprocess.run(["git", "-C", str(root), "ls-files", "-z"], capture_output=True, check=True).stdout
    return [rel for rel in raw.decode("utf-8").split("\0") if rel and in_scope(rel)]


def all_candidates(root):
    """Every (path, string) the rule applies to and that is not in headline case (the ones that would need fixing or an exception)."""
    out = []
    for rel in _files(root):
        text = sp._read(root / rel)
        if text is not None:
            out.extend((rel, s) for _, s in find_text(rel, text))
    return out


def load_exceptions(root):
    ex = {}
    path = root / EXCEPTIONS_FILE
    if not path.is_file():
        return ex
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        parts = [p.strip() for p in line.split(" | ", 2)]
        if len(parts) == 3:
            ex[(parts[0], parts[1])] = parts[2]
    return ex


def check(root):
    """Return [(path, line number, string)] for each short string not in headline case and not excepted."""
    ex = load_exceptions(root)
    left = []
    for rel in _files(root):
        text = sp._read(root / rel)
        if text is None:
            continue
        for n, s in find_text(rel, text):
            if (rel, s) not in ex:
                left.append((rel, n, s))
    return left


def main(argv=None):
    p = argparse.ArgumentParser(prog="headline_case.py", description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    p.add_argument("cmd", choices=["check", "list"])
    p.add_argument("--root", type=Path, default=REPO)
    a = p.parse_args(argv)
    if a.cmd == "list":
        for rel in _files(a.root):
            text = sp._read(a.root / rel)
            for n, s in (_candidates(rel, text) if text is not None else []):
                print(f"{rel}:{n}: {s}")
        return 0
    left = check(a.root)
    for rel, n, s in left:
        print(f"{rel}:{n}: {s}")
    if left:
        print(f"{len(left)} short string(s) not in headline case (fix them, or list them in {EXCEPTIONS_FILE})", file=sys.stderr)
    return 1 if left else 0


if __name__ == "__main__":
    sys.exit(main())
