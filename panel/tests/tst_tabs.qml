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
        property var keepSet: []
        property var backendSet: []
        property var backendList: [
            { name: "max", kind: "max", target: "max-account", model: null, base_url: null, "default": true },
            { name: "here", kind: "ollama", target: "local-ollama", model: "gpt-oss:20b", base_url: "http://127.0.0.1:11434", "default": false },
            { name: "desk", kind: "ollama", target: "remote-ollama", model: "qwen3-vl:8b", base_url: "http://192.0.2.10:11434", "default": false }
        ]
        property var opened: []
        property bool offline: false
        signal chunk(string session, string text)
        signal done(string session)
        signal failed(string session, string message)
        signal approvalChanged(string id, string state)
        signal sessionsChanged()
        signal userMessage(string session, string text)

        // events (N-220): what the daemon kept per session, and what this panel has seen
        property var eventsFor: ({})
        property var gapFor: ({})
        property var seen: ({})
        property var markCalls: []
        function ev(seq, type, extra) {
            var e = { seq: seq, session: "x", at_ms: 1700000000000 + seq, type: type }
            for (var k in extra) e[k] = extra[k]
            return e
        }
        function eventsSince(session, after) {
            var all = eventsFor[session] || []
            var rest = all.filter(function (e) { return e.seq > after })
            return JSON.stringify({ session: session, events: rest, after: after, last_seq: all.length ? all[all.length - 1].seq : 0, gap: gapFor[session] === true })
        }
        function lastSeq(session) { return seen[session] || 0 }
        function markSeen(session, seq) {
            markCalls.push([session, seq])
            var s = JSON.parse(JSON.stringify(seen))
            s[session] = Math.max(s[session] || 0, seq)
            seen = s
        }
        signal reconnected()

        function sessions() {
            var out = []
            for (var i = 0; i < list.length; ++i)
                out.push(JSON.stringify(list[i]))
            return out
        }
        function add(started, title) {
            counter += 1
            var s = { id: "s" + counter, title: title === undefined ? null : title, created_at: 1700000000000 + counter * 60000,
                      started: started === true, running: false, pending_approvals: 0, keep: "library", open: true, backend: null }
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
        function backends() {
            return backendList.map(function (b) { return JSON.stringify(b) })
        }
        function setSessionBackend(id, name) {
            backendSet.push([id, name])
            list = list.map(function (s) { if (s.id === id) s.backend = name === "" ? null : name; return s })
            sessionsChanged()
            return ""
        }
        function setKeepMode(id, mode) {
            keepSet.push([id, mode])
            list = list.map(function (s) { if (s.id === id) s.keep = mode; return s })
            sessionsChanged()
            return ""
        }
        function openSession(id) {
            opened.push(id)
            list = list.map(function (s) { if (s.id === id) s.open = true; return s })
            sessionsChanged()
            return ""
        }
        function addToLibrary(title) {
            var id = add(true, title)
            list = list.map(function (s) { if (s.id === id) s.open = false; return s })
            return id
        }
        function setPending(id, n) {
            list = list.map(function (s) { if (s.id === id) s.pending_approvals = n; return s })
        }
        function reset() { list = []; counter = 0; sent = []; closed = []; renamed = []; keepSet = []; backendSet = []; opened = []; offline = false; eventsFor = ({}); gapFor = ({}); seen = ({}); markCalls = [] }
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

    function test_a_tab_restored_from_the_daemon_shows_what_it_kept_of_the_conversation() {
        stub.eventsFor = { s1: [
            stub.ev(1, "user_message", { text: "hello" }), stub.ev(2, "chunk", { text: "Hi " }), stub.ev(3, "chunk", { text: "there" }),
            stub.ev(4, "done", {}), stub.ev(5, "user_message", { text: "bye" }), stub.ev(6, "error", { message: "boom" }), stub.ev(7, "done", {}) ] }
        stub.add(true)
        tabs.refresh()
        var chat = tabs.chatFor("s1")
        compare(chat.messages.count, 4)
        compare(chat.messages.get(0).role, "user")
        compare(chat.messages.get(0).text, "hello")
        compare(chat.messages.get(1).role, "assistant")
        compare(chat.messages.get(1).text, "Hi there", "chunks of one reply are one bubble")
        compare(chat.messages.get(2).text, "bye")
        compare(chat.messages.get(3).role, "error")
        compare(stub.markCalls[0][1], 7)
        mouseClick(findChild(tabs, "newTab"))
        compare(tabs.chatFor(tabs.selectedId).messages.count, 0, "a new tab has nothing to replay")
    }

    function test_a_restored_tab_with_nothing_kept_says_so() {
        stub.add(true)
        tabs.refresh()
        var chat = tabs.chatFor("s1")
        compare(chat.messages.count, 1)
        compare(chat.messages.get(0).role, "note")
        compare(chat.messages.get(0).text, "Earlier messages are not available.")
    }

    function test_a_restored_tab_whose_older_events_are_gone_says_so_before_what_is_left() {
        stub.eventsFor = { s1: [stub.ev(9, "chunk", { text: "the end of a reply" }), stub.ev(10, "done", {}) ] }
        stub.gapFor = { s1: true }
        stub.add(true)
        tabs.refresh()
        var chat = tabs.chatFor("s1")
        compare(chat.messages.get(0).text, "Older messages are no longer kept.")
        compare(chat.messages.get(1).text, "the end of a reply")
    }

    function test_after_the_daemon_is_back_each_missed_event_is_added_once_and_a_second_look_adds_nothing() {
        stub.add(true)
        stub.eventsFor = { s1: [stub.ev(1, "user_message", { text: "hello" }), stub.ev(2, "chunk", { text: "Hi" }), stub.ev(3, "done", {}) ] }
        tabs.refresh()
        var chat = tabs.chatFor("s1")
        compare(chat.messages.count, 2)
        // while the daemon was away, two more things happened
        stub.eventsFor = { s1: [stub.ev(1, "user_message", { text: "hello" }), stub.ev(2, "chunk", { text: "Hi" }), stub.ev(3, "done", {}),
            stub.ev(4, "user_message", { text: "from the phone" }), stub.ev(5, "chunk", { text: "answer" }), stub.ev(6, "done", {}) ] }
        stub.reconnected()
        compare(chat.messages.count, 4)
        compare(chat.messages.get(2).text, "from the phone")
        compare(chat.messages.get(3).text, "answer")
        stub.reconnected()
        compare(chat.messages.count, 4, "nothing is added twice")
    }

    function test_a_reply_cut_off_by_a_restart_does_not_leave_the_tab_waiting_for_ever() {
        stub.add(false)
        tabs.refresh()
        var chat = tabs.chatFor("s1")
        chat.submit("go")
        verify(chat.busy)
        stub.reconnected() // the daemon says the session is not running any more
        verify(!chat.busy)
        compare(chat.messages.get(chat.messages.count - 1).role, "note")
        verify(chat.messages.get(chat.messages.count - 1).text.indexOf("cut off") >= 0)
    }

    function test_a_reply_that_is_still_running_after_the_reconnect_keeps_waiting() {
        stub.add(false)
        tabs.refresh()
        var chat = tabs.chatFor("s1")
        chat.submit("go")
        stub.list = stub.list.map(function (s) { s.running = true; return s })
        stub.reconnected()
        verify(chat.busy)
    }

    function test_a_message_another_client_sent_shows_up_in_its_own_tab_only() {
        stub.add(false); stub.add(false)
        tabs.refresh()
        stub.userMessage("s1", "typed on the phone")
        compare(tabs.chatFor("s1").messages.count, 1)
        compare(tabs.chatFor("s1").messages.get(0).role, "user")
        compare(tabs.chatFor("s2").messages.count, 0)
    }

    function test_a_session_the_daemon_says_is_running_shows_working() {
        stub.add(true)
        stub.list = stub.list.map(function (s) { s.running = true; return s })
        tabs.refresh()
        compare(findChild(tabs, "tab-s1").status, "working")
    }

    // ---- what happens after a reboot, and the library (N-208)

    function test_a_new_tab_says_it_is_kept_in_the_library_after_a_reboot() {
        stub.add(false)
        tabs.refresh()
        compare(findChild(tabs, "keepToggle").text, "After a reboot: keep in library")
    }

    function test_clicking_the_toggle_cycles_library_always_drop_and_tells_the_daemon() {
        stub.add(false)
        tabs.refresh()
        var toggle = findChild(tabs, "keepToggle")
        mouseClick(toggle)
        compare(stub.keepSet[0][1], "always")
        compare(toggle.text, "After a reboot: keep open")
        mouseClick(toggle)
        compare(stub.keepSet[1][1], "drop")
        compare(toggle.text, "After a reboot: drop")
        mouseClick(toggle)
        compare(stub.keepSet[2][1], "library")
        compare(toggle.text, "After a reboot: keep in library")
        compare(stub.keepSet[2][0], "s1")
    }

    function test_the_toggle_follows_the_selected_tab() {
        stub.add(false); stub.add(false)
        stub.setKeepMode("s1", "drop")
        stub.keepSet = []
        tabs.refresh()
        tabs.select("s1")
        compare(findChild(tabs, "keepToggle").text, "After a reboot: drop")
        tabs.select("s2")
        compare(findChild(tabs, "keepToggle").text, "After a reboot: keep in library")
    }

    function test_library_sessions_are_not_tabs_but_are_listed_in_the_library() {
        stub.add(true)
        stub.addToLibrary("Old taxes")
        tabs.refresh()
        compare(ids().join(","), "s1")
        compare(tabs.library.length, 1)
        compare(tabs.library[0].id, "s2")
        compare(findChild(tabs, "libraryButton").text, "Library (1)")
    }

    function test_an_empty_library_says_so_on_its_button() {
        stub.add(false)
        tabs.refresh()
        compare(findChild(tabs, "libraryButton").text, "Library")
    }

    function test_reopening_from_the_library_makes_it_a_selected_tab() {
        stub.add(true)
        var lib = stub.addToLibrary("Old taxes")
        tabs.refresh()
        tabs.openFromLibrary(lib)
        compare(stub.opened[0], lib)
        compare(ids().join(","), "s1," + lib)
        compare(tabs.selectedId, lib)
        compare(tabs.library.length, 0)
        compare(findChild(tabs, "tabLabel-" + lib).text, "Old taxes")
    }

    function test_deleting_from_the_library_removes_the_session_in_the_daemon() {
        stub.add(true)
        var lib = stub.addToLibrary("Old taxes")
        tabs.refresh()
        tabs.deleteFromLibrary(lib)
        compare(stub.closed[0], lib)
        compare(tabs.library.length, 0)
        compare(ids().join(","), "s1")
    }

    function test_with_only_library_sessions_left_a_fresh_tab_is_made() {
        stub.addToLibrary("Old taxes")
        tabs.refresh()
        compare(ids().length, 1)
        compare(tabs.library.length, 1)
    }

    function test_a_session_moved_to_the_library_by_another_client_leaves_the_tabs() {
        stub.add(true); stub.add(true)
        tabs.refresh()
        stub.list = stub.list.map(function (s) { if (s.id === "s2") s.open = false; return s })
        stub.sessionsChanged()
        compare(ids().join(","), "s1")
        compare(tabs.library.length, 1)
    }

    // ---- the backend of a session (N-211)

    function test_the_picker_offers_the_default_and_every_configured_backend() {
        stub.add(false)
        tabs.refresh()
        var texts = tabs.backendChoices.map(function (c) { return c.text })
        compare(texts.length, 4)
        compare(texts[0], "Default (max)")
        verify(texts[1].indexOf("max") >= 0 && texts[1].indexOf("Max account") >= 0, texts[1])
        verify(texts[2].indexOf("here") >= 0 && texts[2].indexOf("this computer") >= 0, texts[2])
        verify(texts[3].indexOf("desk") >= 0 && texts[3].indexOf("another computer") >= 0, texts[3])
        compare(findChild(tabs, "backendPicker").count, 4)
    }

    function test_choosing_a_backend_tells_the_daemon_for_the_selected_tab() {
        stub.add(false); stub.add(false)
        tabs.refresh()
        tabs.select("s1")
        tabs.chooseBackend("here")
        compare(stub.backendSet.length, 1)
        compare(stub.backendSet[0][0], "s1")
        compare(stub.backendSet[0][1], "here")
        compare(tabs.selectedBackend, "here")
    }

    function test_choosing_the_default_sends_an_empty_name() {
        stub.add(false)
        stub.setSessionBackend("s1", "here")
        stub.backendSet = []
        tabs.refresh()
        compare(tabs.selectedBackend, "here")
        tabs.chooseBackend("")
        compare(stub.backendSet[0][1], "")
        compare(tabs.selectedBackend, "")
    }

    function test_the_picker_follows_the_selected_tab() {
        stub.add(false); stub.add(false)
        stub.setSessionBackend("s2", "desk")
        stub.backendSet = []
        tabs.refresh()
        tabs.select("s1")
        compare(tabs.selectedBackend, "")
        tabs.select("s2")
        compare(tabs.selectedBackend, "desk")
        compare(findChild(tabs, "backendPicker").currentIndex, 3)
    }

    function test_a_tab_on_a_local_backend_says_so_in_its_label_row() {
        stub.add(false)
        stub.setSessionBackend("s1", "here")
        tabs.refresh()
        compare(tabs.backendNote, "This session runs on here (this computer).")
        tabs.chooseBackend("")
        compare(tabs.backendNote, "")
    }

    function test_a_session_pointed_at_a_backend_that_is_gone_is_shown_as_missing() {
        stub.add(false)
        stub.setSessionBackend("s1", "ghost")
        tabs.refresh()
        verify(tabs.backendNote.indexOf("ghost") >= 0 && tabs.backendNote.indexOf("not in the configuration") >= 0, tabs.backendNote)
    }

    function test_with_the_daemon_unreachable_there_is_no_picker_to_show() {
        stub.backendList = []
        stub.add(false)
        tabs.refresh()
        compare(tabs.backendChoices.length, 0)
        verify(!findChild(tabs, "backendPicker").visible)
    }
}
