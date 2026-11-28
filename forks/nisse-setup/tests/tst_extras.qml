// SPDX-FileCopyrightText: 2026 nisse
// SPDX-License-Identifier: GPL-2.0-or-later

// N-507d: the options page's logic (modules/extras/contents/ui/extras.js), run by qmltestrunner (tests/e2e/test_nisse_setup_extras_page.sh).
import QtQuick
import QtTest

import "../modules/extras/contents/ui/extras.js" as Extras

TestCase {
    name: "Extras"

    readonly property var items: [{id: "openh264"}, {id: "codecs"}, {id: "chrome"}, {id: "steam"}]

    function test_the_answer_is_in_catalog_order_whatever_order_they_were_ticked() {
        // nisse-extras reports what is installed in catalog order and the engine compares that text with the answer, so the answer must match it
        compare(Extras.answer(items, ["steam", "openh264", "chrome"]), "openh264,chrome,steam");
        compare(Extras.answer(items, []), "");
    }

    function test_an_id_the_catalog_does_not_have_is_left_out_of_the_answer() {
        compare(Extras.answer(items, ["chrome", "ghost"]), "chrome");
    }

    function test_ticking_adds_and_unticking_removes_without_changing_the_list_given() {
        const given = ["chrome"];
        compare(Extras.toggled(given, "steam", true), ["chrome", "steam"]);
        compare(Extras.toggled(given, "chrome", false), []);
        compare(Extras.toggled(given, "chrome", true), ["chrome"], "ticking what is ticked changes nothing");
        compare(given, ["chrome"]);
    }

    function test_the_same_ticks_in_another_order_are_not_a_change() {
        verify(Extras.same(["a", "b"], ["b", "a"]));
        verify(!Extras.same(["a"], ["a", "b"]));
        verify(Extras.same([], []));
    }

    function test_progress_is_summed_up_for_the_person() {
        const p = {finished: false, items: [{id: "a", state: "done", message: "Installed"}, {id: "b", state: "working", message: "Installing"},
                                            {id: "c", state: "waiting", message: ""}, {id: "d", state: "failed", message: "no network"}]};
        compare(Extras.counts(p), {done: 1, working: 1, waiting: 1, failed: 1});
        compare(Extras.failures(p).map(f => f.id), ["d"]);
    }

    function test_the_state_words_are_plain() {
        compare(Extras.stateLabel("waiting"), "Waiting");
        compare(Extras.stateLabel("working"), "Working");
        compare(Extras.stateLabel("done"), "Done");
        compare(Extras.stateLabel("failed"), "Failed");
        compare(Extras.stateLabel("whatever"), "Waiting");
    }

    function test_the_title_of_an_item_is_found_by_its_id() {
        const full = [{id: "chrome", title: "Google Chrome"}];
        compare(Extras.titleOf(full, "chrome"), "Google Chrome");
        compare(Extras.titleOf(full, "ghost"), "ghost");
    }
}
