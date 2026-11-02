// SPDX-License-Identifier: GPL-2.0-or-later
import QtQuick
import QtTest
import "../qml"

TestCase {
    id: tc
    name: "chat"
    when: windowShown
    width: 400
    height: 600
    visible: true

    QtObject {
        id: stub
        property string backendLabel: "max"
        property string authorityLabel: "autonomous"
        property var cancelled: []
        property var sent: []
        property string nextSession: "s1"
        signal chunk(string session, string text)
        signal done(string session)
        signal failed(string session, string message)
        function newSession() { return nextSession }
        function send(session, text) { sent.push([session, text]) }
        function auditTail(n) { return [] }
        function cancel(session) { cancelled.push(session) }
    }

    StatusBar {
        id: bar
        width: parent.width
        client: stub
    }

    ChatView {
        id: chat
        anchors.fill: parent
        client: stub
    }

    function init() {
        chat.reset()
        stub.sent = []
        stub.cancelled = []
        stub.nextSession = "s1"
        stub.authorityLabel = "autonomous"
    }

    function test_sending_appends_a_user_bubble() {
        chat.submit("hi")
        compare(chat.messages.count, 1)
        compare(chat.messages.get(0).role, "user")
        compare(chat.messages.get(0).text, "hi")
        compare(stub.sent.length, 1)
        compare(stub.sent[0][0], "s1")
        compare(stub.sent[0][1], "hi")
    }

    function test_chunks_build_one_assistant_bubble() {
        chat.submit("hi")
        stub.chunk("s1", "Hel")
        stub.chunk("s1", "lo")
        compare(chat.messages.count, 2)
        compare(chat.messages.get(1).role, "assistant")
        compare(chat.messages.get(1).text, "Hello")
    }

    function test_failure_shows_an_error_bubble() {
        chat.submit("hi")
        stub.failed("s1", "Claude Code is not installed yet")
        compare(chat.messages.count, 2)
        compare(chat.messages.get(1).role, "error")
        verify(chat.messages.get(1).text.indexOf("not installed yet") >= 0)
    }

    function test_input_is_disabled_between_send_and_done() {
        var input = findChild(chat, "input")
        verify(input.enabled)
        chat.submit("hi")
        verify(!input.enabled)
        stub.done("s1")
        verify(input.enabled)
    }

    function test_chunks_for_another_session_are_ignored() {
        chat.submit("hi")
        stub.chunk("other", "nope")
        compare(chat.messages.count, 1)
    }

    function test_empty_text_is_not_sent() {
        chat.submit("")
        compare(chat.messages.count, 0)
        compare(stub.sent.length, 0)
    }

    function test_a_second_message_after_done_starts_a_new_reply_bubble() {
        chat.submit("one")
        stub.chunk("s1", "a")
        stub.done("s1")
        chat.submit("two")
        stub.chunk("s1", "b")
        compare(chat.messages.count, 4)
        compare(chat.messages.get(3).text, "b")
    }

    function test_an_unreachable_daemon_shows_an_error_and_keeps_input_enabled() {
        stub.nextSession = ""
        chat.submit("hi")
        compare(chat.messages.count, 2)
        compare(chat.messages.get(1).role, "error")
        verify(chat.messages.get(1).text.indexOf("daemon") >= 0)
        verify(findChild(chat, "input").enabled)
        compare(stub.sent.length, 0)
    }

    function test_stop_button_is_visible_only_while_busy() {
        var stop = findChild(chat, "stop")
        verify(!stop.visible)
        chat.submit("hi")
        verify(stop.visible)
        stub.done("s1")
        verify(!stop.visible)
    }

    function test_stop_calls_cancel_for_the_current_session() {
        chat.submit("hi")
        mouseClick(findChild(chat, "stop"))
        compare(stub.cancelled.length, 1)
        compare(stub.cancelled[0], "s1")
    }

    function test_done_after_stop_unlocks_the_input_and_notes_it() {
        chat.submit("hi")
        mouseClick(findChild(chat, "stop"))
        stub.done("s1")
        verify(!chat.busy)
        verify(findChild(chat, "input").enabled)
        compare(chat.messages.count, 2)
        compare(chat.messages.get(1).role, "note")
        compare(chat.messages.get(1).text, "Stopped.")
    }

    function test_done_without_a_stop_adds_no_note() {
        chat.submit("hi")
        stub.done("s1")
        compare(chat.messages.count, 1)
    }

    function test_status_bar_shows_the_authority() {
        var label = findChild(bar, "authority")
        compare(label.text, "Authority: autonomous")
        stub.authorityLabel = "supervised"
        compare(label.text, "Authority: supervised")
    }

    function test_an_unknown_session_error_drops_the_dead_session_id() {
        chat.submit("hi")
        stub.failed("s1", "unknown session: s1")
        stub.done("s1")
        stub.nextSession = "s2"
        chat.submit("again")
        compare(stub.sent.length, 2)
        compare(stub.sent[1][0], "s2")
    }
}
