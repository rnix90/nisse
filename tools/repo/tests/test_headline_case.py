# SPDX-License-Identifier: GPL-2.0-or-later
"""Tests for the headline case checker (ledger N-501c): short strings are in headline case, like "Computer Settings".

Bert's standing rule (2026-11-26): labels, buttons, menu entries, headings and field names are names of things, up to about
five words, and get headline case; full sentences stay in sentence case with a closing mark (N-501b). The name stays
lowercase ("Earlier Versions of nisse"), and small words (of, a, the, and, to, in, on, for ...) stay lowercase unless first or
last. What is judged not to be a short string (placeholders, pieces of a longer sentence, date formats, notification titles)
is listed with its reason in tools/repo/headline_exceptions.txt.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import headline_case as hc  # noqa: E402

REPO = Path(__file__).resolve().parents[3]


def strings(text, rel="panel/qml/X.qml"):
    return [s for _, s in hc.find_text(rel, text)]


def test_headline_case_means_every_big_word_is_capitalized():
    for good in ("Computer Settings", "Earlier Versions of nisse", "Add a Backend", "Which Backend Does Which Work",
                 "Chat and Code", "Looking at Images", "Last 24 Hours", "Stop All AI", "Log In", "Limited, Ask Me",
                 "2 Approvals Waiting", "Usage: Unknown", "Software Installed, Removed or Updated", "nisse Setup"):
        assert hc.is_headline(good), good
    for bad in ("Computer settings", "Earlier versions of nisse", "Add a backend", "Chat And Code", "Log in", "Stop all AI",
                "2 approvals waiting", "Usage: unknown"):
        assert not hc.is_headline(bad), bad


def test_small_words_are_lowercase_inside_but_capital_first_and_last_and_after_a_colon():
    assert hc.is_headline("Looking at Images")
    assert not hc.is_headline("Looking At Images")
    assert hc.is_headline("What to Look For")
    assert not hc.is_headline("What to Look for")
    assert hc.is_headline("Usage: The Max Account")
    assert not hc.is_headline("Usage: the Max Account")


def test_the_name_stays_lowercase_and_acronyms_and_numbers_are_left_alone():
    assert hc.is_headline("Earlier Versions of nisse")
    assert not hc.is_headline("Earlier Versions of " + "nisse".capitalize())  # the name is never capitalized
    assert hc.is_headline("Last 7 Days")
    assert hc.is_headline("AI Turn")
    assert hc.is_headline("Wi-Fi Networks")


def test_an_unclosed_short_string_that_is_not_headline_is_found():
    assert strings('text: "Add a backend"') == ["Add a backend"]
    assert strings('text: "Add a Backend"') == []
    assert strings('QStringLiteral("%1 approvals waiting")') == ["%1 approvals waiting"]
    assert strings('QStringLiteral("%1 Approvals Waiting")') == []


def test_sentences_and_single_words_and_long_strings_are_not_short_strings():
    assert strings('text: "Chat"') == []
    assert strings('text: "Nothing is waiting for you."') == []  # closed: a sentence
    assert strings('text: "Could not stop: %1."') == []
    assert strings('text: "Step up to a fallback when a backend is away"') == []  # more than five words
    assert strings('text: "This session runs on "') == []  # a piece of a longer string


def test_lowercase_starts_and_comments_are_left_alone():
    assert strings('"unknown session: x"') == []
    assert strings('// Add a backend here') == []


def test_desktop_names_and_toml_titles_and_metadata_names_count():
    assert strings("GenericName=AI assistant", "packaging/rpm/nisse-panel/nisse-panel.desktop") == ["AI assistant"]
    assert strings("GenericName=AI Assistant", "packaging/rpm/nisse-panel/nisse-panel.desktop") == []
    assert strings("Name=nisse update notice", "packaging/rpm/nisse-update/nisse-update-notice.desktop") == ["nisse update notice"]
    assert strings('title = "All passwordless"', "packaging/rpm/nisse-sudo/choice-sudo-mode.toml") == ["All passwordless"]
    assert strings('title = "All Passwordless"', "packaging/rpm/nisse-sudo/choice-sudo-mode.toml") == []
    assert strings('        "Name": "A few choices"', "forks/nisse-setup/modules/choices/metadata.json") == ["A few choices"]


def test_the_setup_window_title_is_in_scope_but_upstreams_strings_are_not():
    assert hc.in_scope("forks/nisse-setup/src/qml/Main.qml")
    assert hc.in_scope("forks/nisse-setup/files/nisse-setup.desktop.in")
    assert hc.in_scope("packaging/rpm/nisse-sudo/choice-sudo-mode.toml")
    assert not hc.in_scope("forks/nisse-setup/modules/time/metadata.json")
    assert not hc.in_scope("panel/tests/tst_chat.qml")


def test_every_exception_says_why_and_still_matches_a_string():
    ex = hc.load_exceptions(REPO)
    assert ex, "the exception list is empty: the judged strings must be written down"
    seen = set(hc.all_candidates(REPO))
    for (rel, s), why in ex.items():
        assert len(why.split()) >= 2, f"{rel}: {s}: an exception needs a reason"
        assert (rel, s) in seen, f"stale exception (the string is gone or now fine): {rel}: {s}"


def test_the_shipped_tree_is_in_headline_case():
    left = hc.check(REPO)
    assert left == [], "\n".join(f"{rel}:{n}: {s}" for rel, n, s in left)


def test_the_setup_window_names_itself_in_headline_case():
    # main.cpp carries upstream's own strings, so it is not scanned; its two nisse lines are pinned here
    text = (REPO / "forks/nisse-setup/src/main.cpp").read_text(encoding="utf-8")
    assert 'i18n("nisse Setup")' in text
    assert 'i18n("nisse setup")' not in text
