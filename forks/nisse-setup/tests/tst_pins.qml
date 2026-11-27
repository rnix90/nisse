// SPDX-FileCopyrightText: 2026 nisse
// SPDX-License-Identifier: GPL-2.0-or-later

// N-508c: the taskbar page's tick logic (modules/taskbar/contents/ui/pins.js), run by qmltestrunner (tests/e2e/test_nisse_setup_taskbar_page.sh).
import QtQuick
import QtTest

import "../modules/taskbar/contents/ui/pins.js" as Pins

TestCase {
    name: "Pins"

    function test_a_newly_ticked_app_goes_to_the_end() {
        compare(Pins.toggled(["a", "b"], "c", true), ["a", "b", "c"]);
        compare(Pins.toggled([], "c", true), ["c"]);
    }

    function test_what_was_chosen_keeps_its_place() {
        compare(Pins.toggled(["a", "b", "c"], "b", true), ["a", "b", "c"], "ticking what is ticked changes nothing");
        compare(Pins.toggled(["a", "b", "c"], "a", true), ["a", "b", "c"]);
    }

    function test_an_unticked_app_is_dropped() {
        compare(Pins.toggled(["a", "b", "c"], "b", false), ["a", "c"]);
        compare(Pins.toggled(["a"], "a", false), []);
        compare(Pins.toggled(["a", "b"], "z", false), ["a", "b"], "unticking what is not there changes nothing");
    }

    function test_the_list_given_is_never_changed() {
        const given = ["a", "b"];
        Pins.toggled(given, "c", true);
        Pins.toggled(given, "a", false);
        compare(given, ["a", "b"]);
    }

    function test_the_answer_is_the_items_joined_by_commas() {
        compare(Pins.answer(["a", "b"]), "a,b");
        compare(Pins.answer([]), "");
    }
}
