# SPDX-License-Identifier: GPL-2.0-or-later
"""Tests for the sentence punctuation checker (ledger N-501b): a full sentence nisse writes ends with . ! ? or a colon.

Bert's standing rule (2026-11-25): labels, buttons and menu entries are not sentences and stay bare; every sentence
people read is closed. The checker reads the strings nisse ships (panel, daemon, packaging scripts, the install choices
page, the boot mocks) and names a capitalized string of four words or more that has no closing mark, unless it is
listed as a label in tools/repo/sentence_labels.txt with its reason.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import sentence_punctuation as sp  # noqa: E402

REPO = Path(__file__).resolve().parents[3]


def strings(text, rel="panel/qml/X.qml"):
    return [s for _, s in sp.find_text(rel, text)]


def test_a_capitalized_sentence_without_a_closing_mark_is_found():
    assert strings('text: "The update did not pass its checks"') == ["The update did not pass its checks"]
    # the name is lowercase even at the start of a sentence, so "nisse ..." starts a sentence too
    assert strings('b.append(text(W / 2, 800, "nisse starts in 4 seconds", 26))') == ["nisse starts in 4 seconds"]
    assert strings('b.append(text(W / 2, 800, "nisse starts in 4 seconds.", 26))') == []


def test_the_four_closing_marks_pass():
    for end in (".", "!", "?", ":"):
        assert strings(f'text: "Nothing is waiting for you{end}"') == [], end


def test_short_strings_and_lowercase_starts_are_left_alone():
    # fewer than four words: a label or a lead-in, never judged
    assert strings('text: "Add a backend"') == []
    assert strings('text: "Pair a device"') == []
    # lowercase start: a log-style fragment, outside the sweep (Bert, 2026-11-26)
    assert strings('"could not save the settings: {e}"') == []


def test_a_lead_in_that_ends_in_a_space_is_a_piece_of_a_longer_string():
    assert strings('text: "This session runs on " + name + "."') == []


def test_comments_are_not_strings_people_read():
    assert strings('// Could not reach the daemon at all today') == []
    assert strings('# Could not reach the daemon at all today', "packaging/rpm/x/nisse-x") == []
    assert strings(' * Could not reach the daemon at all today') == []


def test_placeholders_do_not_count_as_a_closing_mark():
    assert strings('QStringLiteral("Could not stop the thing: %1")') == ["Could not stop the thing: %1"]
    assert strings('QStringLiteral("Could not stop the thing: %1.")') == []


def test_escaped_quotes_stay_inside_the_string():
    assert strings(r'text: "Go back to before \"%1\" was done"') == [r'Go back to before \"%1\" was done']


def test_a_desktop_comment_line_is_a_sentence_too():
    assert strings("Comment=Talk to the AI that looks after this computer", "packaging/rpm/p/p.desktop") == [
        "Talk to the AI that looks after this computer"]
    assert strings("Comment=Talk to the AI that looks after this computer.", "packaging/rpm/p/p.desktop") == []
    assert strings("Name=Talk to the AI that looks after this computer", "packaging/rpm/p/p.desktop") == []


def test_a_metadata_description_is_a_sentence_too():
    line = '"Description": "The nisse desktop: the Ember dark look",'
    assert strings(line, "assets/theme/lookandfeel/x/metadata.json") == ["The nisse desktop: the Ember dark look"]
    assert strings(line.replace("look\"", "look.\""), "assets/theme/lookandfeel/x/metadata.json") == []


def test_only_the_shipped_files_are_in_scope():
    assert sp.in_scope("panel/qml/Main.qml")
    assert sp.in_scope("services/crates/nisse-daemon/src/runner.rs")
    assert sp.in_scope("packaging/rpm/nisse-update/nisse-update-notice")
    assert sp.in_scope("tools/art/boot_mocks.py")
    assert sp.in_scope("forks/nisse-setup/modules/choices/contents/ui/main.qml")
    # tests, docs and upstream's own strings are not nisse's sentences
    assert not sp.in_scope("panel/tests/tst_chat.qml")
    assert not sp.in_scope("services/crates/nisse-daemon/tests/usage.rs")
    assert not sp.in_scope("tests/e2e/test_rollback.sh")
    assert not sp.in_scope("docs/boot-art.md")
    assert not sp.in_scope("forks/nisse-setup/src/auth/authhelper.cpp")
    assert not sp.in_scope("forks/nisse-setup/modules/time/metadata.json")


def test_every_label_entry_says_why_and_still_matches_a_string():
    labels = sp.load_labels(REPO)
    assert labels, "the label list is empty: the judged labels must be written down"
    seen = {(rel, s) for rel, s in sp.all_strings(REPO)}
    for (rel, s), why in labels.items():
        assert len(why.split()) >= 2, f"{rel}: {s}: a label needs a reason"
        assert (rel, s) in seen, f"stale label entry (the string is gone): {rel}: {s}"


def test_the_shipped_tree_has_no_unclosed_sentence():
    left = sp.check(REPO)
    assert left == [], "\n".join(f"{rel}:{n}: {s}" for rel, n, s in left)


def test_the_boot_mock_sentences_are_closed():
    text = (REPO / "tools/art/boot_mocks.py").read_text(encoding="utf-8")
    for want in ('"Press E to change how nisse starts."', '"Type your password to unlock."',
                 '"What would you like to do?"'):
        assert want in text, want
