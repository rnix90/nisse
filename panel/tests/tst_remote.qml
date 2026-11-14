// SPDX-License-Identifier: GPL-2.0-or-later
import QtQuick
import QtTest
import "../qml"

TestCase {
    id: tc
    name: "remote"
    when: windowShown
    width: 480
    height: 200
    visible: true

    QtObject {
        id: stub
        property var state: ({ enabled: false, running: false, restarts: 0, error: null })
        property var calls: []
        property string failWith: ""
        signal remoteAccessChanged(string json)

        function remoteAccess() { return JSON.stringify(state) }
        function setRemoteAccess(on) {
            calls.push(on)
            if (failWith !== "")
                return failWith
            state = { enabled: on, running: false, restarts: 0, error: null }
            return ""
        }
        function push(s) {
            state = s
            remoteAccessChanged(JSON.stringify(s))
        }
    }

    RemoteSwitch {
        id: remote
        anchors.fill: parent
        client: stub
    }

    function init() {
        stub.state = { enabled: false, running: false, restarts: 0, error: null }
        stub.calls = []
        stub.failWith = ""
        remote.refresh()
    }

    function test_it_starts_off_and_says_so() {
        verify(!findChild(remote, "remoteSwitch").checked)
        compare(findChild(remote, "remoteStatus").text, "Remote access is off.")
    }

    function test_turning_it_on_asks_the_daemon() {
        mouseClick(findChild(remote, "remoteSwitch"))
        compare(stub.calls.length, 1)
        compare(stub.calls[0], true)
        verify(findChild(remote, "remoteSwitch").checked)
    }

    function test_turning_it_off_asks_the_daemon() {
        stub.push({ enabled: true, running: true, restarts: 0, error: null })
        verify(findChild(remote, "remoteSwitch").checked)
        mouseClick(findChild(remote, "remoteSwitch"))
        compare(stub.calls[0], false)
        verify(!findChild(remote, "remoteSwitch").checked)
    }

    function test_on_and_waiting_for_the_server_says_starting() {
        stub.push({ enabled: true, running: false, restarts: 0, error: null })
        compare(findChild(remote, "remoteStatus").text, "Remote access is on; starting.")
    }

    function test_on_and_running_says_ready() {
        stub.push({ enabled: true, running: true, restarts: 0, error: null })
        compare(findChild(remote, "remoteStatus").text, "Remote access is on. Start a session from claude.ai/code or the phone app.")
    }

    function test_a_reason_it_cannot_run_is_shown_in_words() {
        stub.push({ enabled: true, running: false, restarts: 3, error: "Claude Code is not installed yet; waiting for first-boot download" })
        var text = findChild(remote, "remoteStatus").text
        verify(text.indexOf("not installed yet") >= 0, text)
        verify(text.indexOf("Trying again") >= 0, text)
    }

    function test_a_refusal_from_the_daemon_is_shown_and_the_switch_follows_the_daemon() {
        stub.failWith = "remote access is not set up in this daemon"
        mouseClick(findChild(remote, "remoteSwitch"))
        verify(findChild(remote, "remoteError").visible)
        verify(findChild(remote, "remoteError").text.indexOf("not set up") >= 0)
        verify(!findChild(remote, "remoteSwitch").checked)
    }

    function test_the_plain_words_say_whose_sessions_these_are() {
        var note = findChild(remote, "remoteNote").text
        verify(note.indexOf("Claude's own") >= 0, note)
        verify(note.indexOf("approvals") >= 0, note)
        verify(note.indexOf("not tabs") >= 0 || note.indexOf("do not appear") >= 0, note)
    }

    function test_a_status_pushed_by_the_daemon_updates_the_switch_without_a_click() {
        stub.push({ enabled: true, running: true, restarts: 0, error: null })
        verify(findChild(remote, "remoteSwitch").checked)
        stub.push({ enabled: false, running: false, restarts: 0, error: null })
        verify(!findChild(remote, "remoteSwitch").checked)
    }
}
