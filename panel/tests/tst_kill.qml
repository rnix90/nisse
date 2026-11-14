// SPDX-License-Identifier: GPL-2.0-or-later
import QtQuick
import QtTest
import "../qml"

TestCase {
    id: tc
    name: "kill"
    when: windowShown
    width: 480
    height: 160
    visible: true

    QtObject {
        id: stub
        property string killSwitchJson: JSON.stringify({ engaged: false, by: null, reason: null, since: null })
        property var engaged: []
        property int released: 0
        property string failWith: ""
        function engageKillSwitch(reason) {
            engaged.push(reason)
            if (failWith !== "")
                return failWith
            killSwitchJson = JSON.stringify({ engaged: true, by: "desktop", reason: reason === "" ? null : reason, since: 1700000000 })
            return ""
        }
        function releaseKillSwitch() {
            released += 1
            if (failWith !== "")
                return failWith
            killSwitchJson = JSON.stringify({ engaged: false, by: null, reason: null, since: null })
            return ""
        }
    }

    KillSwitchBar {
        id: bar
        width: parent.width
        client: stub
    }

    function init() {
        stub.killSwitchJson = JSON.stringify({ engaged: false, by: null, reason: null, since: null })
        stub.engaged = []
        stub.released = 0
        stub.failWith = ""
        bar.errorText = ""
    }

    function test_released_shows_only_the_stop_button() {
        verify(findChild(bar, "killButton").visible)
        verify(!findChild(bar, "killBanner").visible)
        compare(findChild(bar, "killButton").text, "Stop all AI")
    }

    function test_the_stop_button_engages_the_switch_as_the_desktop() {
        mouseClick(findChild(bar, "killButton"))
        compare(stub.engaged.length, 1)
        verify(findChild(bar, "killBanner").visible)
        verify(!findChild(bar, "killButton").visible)
    }

    function test_the_banner_says_who_stopped_it_why_and_that_nothing_was_undone() {
        stub.killSwitchJson = JSON.stringify({ engaged: true, by: "phone", reason: "it was deleting my photos", since: 1700000000 })
        var text = findChild(bar, "killText").text
        verify(text.indexOf("paused") >= 0, text)
        verify(text.indexOf("phone") >= 0, text)
        verify(text.indexOf("it was deleting my photos") >= 0, text)
        verify(text.indexOf("not undone") >= 0 || text.indexOf("nothing was undone") >= 0 || text.indexOf("Nothing was rolled back") >= 0, text)
    }

    function test_a_banner_without_a_reason_still_reads_well() {
        stub.killSwitchJson = JSON.stringify({ engaged: true, by: "desktop", reason: null, since: 1700000000 })
        var text = findChild(bar, "killText").text
        verify(text.indexOf("desktop") >= 0 && text.indexOf("null") < 0 && text.indexOf("()") < 0, text)
    }

    function test_resume_turns_the_switch_off() {
        stub.killSwitchJson = JSON.stringify({ engaged: true, by: "phone", reason: null, since: 1 })
        mouseClick(findChild(bar, "killResume"))
        compare(stub.released, 1)
        verify(!findChild(bar, "killBanner").visible)
        verify(findChild(bar, "killButton").visible)
    }

    function test_a_refusal_from_the_daemon_is_shown() {
        stub.failWith = "the daemon is not reachable"
        mouseClick(findChild(bar, "killButton"))
        verify(findChild(bar, "killError").visible)
        verify(findChild(bar, "killError").text.indexOf("not reachable") >= 0)
        verify(findChild(bar, "killButton").visible, "still not engaged")
    }

    function test_the_state_follows_the_daemon_without_a_click() {
        stub.killSwitchJson = JSON.stringify({ engaged: true, by: "phone", reason: null, since: 1 })
        verify(findChild(bar, "killBanner").visible)
        stub.killSwitchJson = JSON.stringify({ engaged: false, by: null, reason: null, since: null })
        verify(!findChild(bar, "killBanner").visible)
    }

    function test_unreadable_status_counts_as_not_engaged_but_does_not_break() {
        stub.killSwitchJson = "{ not json"
        verify(findChild(bar, "killButton").visible)
    }

    function test_the_engaged_property_is_available_to_the_rest_of_the_panel() {
        verify(!bar.engaged)
        stub.killSwitchJson = JSON.stringify({ engaged: true, by: "phone", reason: null, since: 1 })
        verify(bar.engaged)
    }
}
