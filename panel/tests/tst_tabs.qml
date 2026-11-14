// SPDX-License-Identifier: GPL-2.0-or-later
import QtQuick
import QtTest
import "../qml"

TestCase {
    id: tc
    name: "tabs"
    when: windowShown
    width: 480
    height: 640
    visible: true

    // A daemon with a session list, as D-Bus shows it: the panel never invents ids, order or names.
    QtObject {
        id: stub
        property string backendLabel: "max"
        property string authorityLabel: "autonomous"
        property var list: []
        property int counter: 0
        property var sent: []
        property var closed: []
        property var renamed: []
        property bool offline: false
        signal chunk(string session, string text)
        signal done(string session)
        signal failed(string session, string message)
        signal approvalChanged(string id, string state)
        signal sessionsChanged()

        function sessions() {
            var out = []
            for (var i = 0; i < list.length; ++i)
                out.push(JSON.stringify(list[i]))
            return out
        }
        function add(started, title) {
            counter += 1
            var s = { id: "s" + counter, title: title === undefined ? null : title, created_at: 1700000000000 + counter * 60000,
                      started: started === true, running: false, pending_approvals: 0 }
            list = list.concat([s])
            return s.id
        }
        function newSession() {
            if (offline)
                return ""
            var id = add(false)
            sessionsChanged()
            return id
        }
        function send(session, text) { sent.push([session, text]) }
        function cancel(session) {}
        function auditTail(n) { return [] }
        function closeSession(id) {
            closed.push(id)
            list = list.filter(function (s) { return s.id !== id })
            sessionsChanged()
            return ""
        }
        function renameSession(id, title) {
            renamed.push([id, title])
            list = list.map(function (s) { if (s.id === id) s.title = title === "" ? null : title; return s })
            sessionsChanged()
            return ""
        }
        function setPending(id, n) {
            list = list.map(function (s) { if (s.id === id) s.pending_approvals = n; return s })
        }
        function reset() { list = []; counter = 0; sent = []; closed = []; renamed = []; offline = false }
    }

    SessionTabs {
        id: tabs
        anchors.fill: parent
        client: stub
    }

    function init() {
        stub.reset()
        tabs.reset()
    }

    function ids() {
        var out = []
        for (var i = 0; i < tabs.tabs.length; ++i) out.push(tabs.tabs[i].id)
        return out
    }

    function test_the_daemon_with_no_sessions_gets_one_and_it_is_selected() {
        tabs.refresh()
        compare(ids().length, 1)
        compare(tabs.selectedId, ids()[0])
        compare(stub.list.length, 1)
    }

    function test_existing_sessions_become_tabs_in_the_daemons_order_and_the_newest_is_selected() {
        stub.add(true); stub.add(true); stub.add(false)
        tabs.refresh()
        compare(ids().join(","), "s1,s2,s3")
        compare(tabs.selectedId, "s3")
    }

    function test_plus_makes_a_session_in_the_daemon_and_selects_it() {
        tabs.refresh()
        mouseClick(findChild(tabs, "newTab"))
        compare(ids().length, 2)
        compare(tabs.selectedId, ids()[1])
        compare(stub.list.length, 2)
    }

    function test_an_unreachable_daemon_says_so_and_a_retry_brings_the_first_tab() {
        stub.offline = true
        tabs.refresh()
        compare(ids().length, 0)
        verify(findChild(tabs, "offlineNote").visible)
        stub.offline = false
        mouseClick(findChild(tabs, "retry"))
        compare(ids().length, 1)
        verify(!findChild(tabs, "offlineNote").visible)
    }

    function test_the_tab_without_a_name_reads_as_its_date_and_time() {
        stub.add(false)
        tabs.refresh()
        compare(findChild(tabs, "tabLabel-s1").text, tabs.defaultTitle(stub.list[0].created_at))
        verify(tabs.defaultTitle(stub.list[0].created_at).length > 0)
    }

    function test_a_named_tab_shows_its_name() {
        stub.add(false, "Taxes")
        tabs.refresh()
        compare(findChild(tabs, "tabLabel-s1").text, "Taxes")
    }

    function test_double_click_renames_through_the_daemon() {
        stub.add(false)
        tabs.refresh()
        tabs.startRename("s1")
        var field = findChild(tabs, "renameField")
        verify(field.visible)
        field.text = "Taxes"
        tabs.commitRename()
        compare(stub.renamed.length, 1)
        compare(stub.renamed[0][0], "s1")
        compare(stub.renamed[0][1], "Taxes")
        compare(findChild(tabs, "tabLabel-s1").text, "Taxes")
    }

    function test_an_empty_name_goes_back_to_the_date_and_time() {
        stub.add(false, "Taxes")
        tabs.refresh()
        tabs.startRename("s1")
        findChild(tabs, "renameField").text = ""
        tabs.commitRename()
        compare(stub.renamed[0][1], "")
        compare(findChild(tabs, "tabLabel-s1").text, tabs.defaultTitle(stub.list[0].created_at))
    }

    function test_cancelling_a_rename_changes_nothing() {
        stub.add(false, "Taxes")
        tabs.refresh()
        tabs.startRename("s1")
        findChild(tabs, "renameField").text = "Other"
        tabs.cancelRename()
        compare(stub.renamed.length, 0)
        compare(findChild(tabs, "tabLabel-s1").text, "Taxes")
    }

    function test_closing_a_tab_closes_it_in_the_daemon_and_selects_a_neighbour() {
        stub.add(true); stub.add(true); stub.add(true)
        tabs.refresh()
        tabs.select("s2")
        mouseClick(findChild(tabs, "closeTab-s2"))
        compare(stub.closed.length, 1)
        compare(stub.closed[0], "s2")
        compare(ids().join(","), "s1,s3")
        verify(tabs.selectedId === "s1" || tabs.selectedId === "s3")
    }

    function test_closing_the_last_tab_leaves_one_fresh_session() {
        stub.add(true)
        tabs.refresh()
        mouseClick(findChild(tabs, "closeTab-s1"))
        compare(ids().length, 1)
        verify(ids()[0] !== "s1")
    }

    function test_each_tab_keeps_its_own_conversation() {
        stub.add(false); stub.add(false)
        tabs.refresh()
        tabs.select("s1")
        tabs.chatFor("s1").submit("question one")
        stub.chunk("s1", "answer one")
        stub.done("s1")
        tabs.select("s2")
        compare(tabs.chatFor("s2").messages.count, 0)
        tabs.chatFor("s2").submit("question two")
        stub.chunk("s2", "answer two")
        stub.done("s2")
        tabs.select("s1")
        compare(tabs.chatFor("s1").messages.count, 2)
        compare(tabs.chatFor("s1").messages.get(1).text, "answer one")
        compare(tabs.chatFor("s2").messages.get(1).text, "answer two")
    }

    function test_three_live_sessions_only_the_selected_one_shows_a_transcript() {
        stub.add(false); stub.add(false); stub.add(false)
        tabs.refresh()
        tabs.select("s1")
        for (var i = 1; i <= 3; ++i)
            tabs.chatFor("s" + i).submit("go " + i)
        stub.chunk("s1", "alpha text")
        stub.chunk("s2", "bravo text")
        stub.chunk("s3", "charlie text")
        verify(tabs.chatFor("s1").visible)
        verify(!tabs.chatFor("s2").visible)
        verify(!tabs.chatFor("s3").visible)
        // what a background tab shows is its title and a status, never transcript text
        for (var k = 2; k <= 3; ++k) {
            var label = findChild(tabs, "tabLabel-s" + k).text
            verify(label.indexOf("text") < 0, label)
            compare(findChild(tabs, "tab-s" + k).status, "working")
        }
        compare(findChild(tabs, "tab-s1").status, "working") // working too, but its transcript is on screen
        // yet the text is kept and appears when the tab is selected
        tabs.select("s3")
        verify(tabs.chatFor("s3").visible)
        compare(tabs.chatFor("s3").messages.get(1).text, "charlie text")
    }

    function test_a_background_tab_that_finishes_is_marked_unread_until_selected() {
        stub.add(false); stub.add(false)
        tabs.refresh()
        tabs.select("s1")
        tabs.chatFor("s2").submit("go")
        stub.chunk("s2", "x")
        stub.done("s2")
        compare(findChild(tabs, "tab-s2").status, "unread")
        tabs.select("s2")
        compare(findChild(tabs, "tab-s2").status, "idle")
    }

    function test_finishing_in_the_selected_tab_is_not_unread() {
        stub.add(false)
        tabs.refresh()
        tabs.chatFor("s1").submit("go")
        stub.chunk("s1", "x")
        stub.done("s1")
        compare(findChild(tabs, "tab-s1").status, "idle")
    }

    function test_an_approval_waiting_on_a_background_tab_marks_it_needs_you() {
        stub.add(false); stub.add(false)
        tabs.refresh()
        tabs.select("s1")
        stub.setPending("s2", 1)
        stub.approvalChanged("a1", "pending")
        compare(findChild(tabs, "tab-s2").status, "needs-you")
        compare(tabs.needsYouCount, 1)
        stub.setPending("s2", 0)
        stub.approvalChanged("a1", "approved")
        compare(findChild(tabs, "tab-s2").status, "idle")
        compare(tabs.needsYouCount, 0)
    }

    function test_a_session_made_by_another_client_appears_as_a_tab() {
        stub.add(false)
        tabs.refresh()
        var other = stub.add(false, "From the phone")
        stub.sessionsChanged()
        compare(ids().length, 2)
        compare(findChild(tabs, "tabLabel-" + other).text, "From the phone")
        compare(tabs.selectedId, "s1", "someone else's tab does not steal the selection")
    }

    function test_a_session_closed_by_another_client_disappears() {
        stub.add(false); stub.add(false)
        tabs.refresh()
        tabs.select("s2")
        stub.list = stub.list.filter(function (s) { return s.id !== "s2" })
        stub.sessionsChanged()
        compare(ids().join(","), "s1")
        compare(tabs.selectedId, "s1")
    }

    function test_a_tab_restored_from_the_daemon_says_earlier_messages_are_not_shown() {
        stub.add(true)
        tabs.refresh()
        var restored = tabs.chatFor("s1")
        compare(restored.messages.count, 1)
        compare(restored.messages.get(0).role, "note")
        verify(restored.messages.get(0).text.indexOf("Earlier messages") >= 0)
        mouseClick(findChild(tabs, "newTab"))
        compare(tabs.chatFor(tabs.selectedId).messages.count, 0)
    }

    function test_a_session_the_daemon_says_is_running_shows_working() {
        stub.add(true)
        stub.list = stub.list.map(function (s) { s.running = true; return s })
        tabs.refresh()
        compare(findChild(tabs, "tab-s1").status, "working")
    }
}
