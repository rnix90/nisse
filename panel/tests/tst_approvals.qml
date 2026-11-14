// SPDX-License-Identifier: GPL-2.0-or-later
import QtQuick
import QtTest
import "../qml"

TestCase {
    id: tc
    name: "approvals"
    when: windowShown
    width: 420
    height: 640
    visible: true

    QtObject {
        id: stub
        property int pendingCount: 0
        property var items: []          // approval objects, oldest first
        property var approved: []
        property var denied: []
        property string failWith: ""    // when set, approve and deny return this error text
        signal approvalChanged(string id, string state)

        function approvals(state) {
            var out = []
            for (var i = 0; i < items.length; ++i)
                if (state === "" || items[i].state === state)
                    out.push(JSON.stringify(items[i]))
            return out
        }
        function approve(id) {
            if (failWith !== "")
                return failWith
            approved.push(id)
            setState(id, "approved")
            return ""
        }
        function deny(id, reason) {
            if (failWith !== "")
                return failWith
            denied.push([id, reason])
            setState(id, "denied")
            return ""
        }
        function setState(id, state) {
            var copy = []
            for (var i = 0; i < items.length; ++i) {
                var a = JSON.parse(JSON.stringify(items[i]))
                if (a.id === id) { a.state = state; a.decided_by = "desktop" }
                copy.push(a)
            }
            items = copy
            approvalChanged(id, state)
        }
    }

    ApprovalsView {
        id: view
        anchors.fill: parent
        client: stub
        nowSecs: 1000
    }

    function make(id, state, extra) {
        var a = {
            id: id, session: "s1", asked_by: "guardrail", tool: "Bash", summary: "Bash: git push origin main (outbound)",
            detail: { category: "outbound", reason: "pushes commits to a remote", command: "git push origin main" },
            asked_at: 900, expires_at: 1900, state: state, decided_by: null, decided_at: null, reason: null
        }
        for (var k in extra) a[k] = extra[k]
        return a
    }

    function init() {
        stub.items = []
        stub.approved = []
        stub.denied = []
        stub.failWith = ""
        view.nowSecs = 1000
        view.reset()
    }

    function test_nothing_waiting_shows_the_empty_note() {
        view.refresh()
        verify(findChild(view, "empty").visible)
        compare(findChild(view, "pendingList").count, 0)
    }

    function test_pending_items_are_listed_with_their_summary() {
        stub.items = [make("a1", "pending"), make("a2", "pending", { summary: "Bash: rm -r old (delete)" })]
        view.refresh()
        compare(findChild(view, "pendingList").count, 2)
        verify(!findChild(view, "empty").visible)
        compare(view.pendingTotal, 2)
    }

    function test_selecting_an_item_shows_who_asked_and_why() {
        stub.items = [make("a1", "pending")]
        view.refresh()
        view.select("a1")
        var detail = findChild(view, "detail")
        verify(detail.visible)
        verify(detail.text.indexOf("guardrail") >= 0)
        verify(detail.text.indexOf("outbound") >= 0)
        verify(detail.text.indexOf("pushes commits to a remote") >= 0)
        verify(detail.text.indexOf("git push origin main") >= 0)
        verify(detail.text.indexOf("s1") >= 0)
    }

    function test_approve_sends_the_id_and_moves_the_item_to_the_history() {
        stub.items = [make("a1", "pending")]
        view.refresh()
        view.select("a1")
        mouseClick(findChild(view, "approve"))
        compare(stub.approved.length, 1)
        compare(stub.approved[0], "a1")
        compare(findChild(view, "pendingList").count, 0)
        compare(findChild(view, "historyList").count, 1)
    }

    function test_deny_sends_the_id_and_the_typed_reason() {
        stub.items = [make("a1", "pending")]
        view.refresh()
        view.select("a1")
        findChild(view, "reason").text = "not today"
        mouseClick(findChild(view, "deny"))
        compare(stub.denied.length, 1)
        compare(stub.denied[0][0], "a1")
        compare(stub.denied[0][1], "not today")
        compare(findChild(view, "historyList").count, 1)
    }

    function test_deny_without_a_reason_sends_an_empty_reason() {
        stub.items = [make("a1", "pending")]
        view.refresh()
        view.select("a1")
        mouseClick(findChild(view, "deny"))
        compare(stub.denied[0][1], "")
    }

    function test_the_buttons_only_work_on_a_pending_item() {
        stub.items = [make("a1", "expired", { decided_by: "daemon" })]
        view.refresh()
        view.select("a1")
        verify(!findChild(view, "approve").enabled)
        verify(!findChild(view, "deny").enabled)
        verify(findChild(view, "detail").text.indexOf("expired") >= 0)
    }

    function test_a_decided_item_shows_who_decided_and_the_reason() {
        stub.items = [make("a1", "denied", { decided_by: "phone", reason: "that is my photos" })]
        view.refresh()
        view.select("a1")
        var text = findChild(view, "detail").text
        verify(text.indexOf("phone") >= 0)
        verify(text.indexOf("that is my photos") >= 0)
    }

    function test_a_change_signal_refreshes_the_lists() {
        view.refresh()
        compare(findChild(view, "pendingList").count, 0)
        stub.items = [make("a1", "pending")]
        stub.approvalChanged("a1", "pending")
        compare(findChild(view, "pendingList").count, 1)
    }

    function test_an_error_from_the_daemon_is_shown_and_the_list_refreshes() {
        stub.items = [make("a1", "pending")]
        view.refresh()
        view.select("a1")
        stub.failWith = "already approved by phone"
        mouseClick(findChild(view, "approve"))
        var err = findChild(view, "error")
        verify(err.visible)
        verify(err.text.indexOf("already approved by phone") >= 0)
        stub.failWith = ""
        view.refresh()
        verify(!findChild(view, "error").visible)
    }

    function test_the_countdown_reads_in_plain_words() {
        compare(view.expiresIn(1000, 1000), "expired")
        compare(view.expiresIn(1000, 1030), "expires in 30 s")
        compare(view.expiresIn(1000, 1000 + 12 * 60), "expires in 12 min")
        compare(view.expiresIn(1000, 1000 + 90 * 60), "expires in 1 h 30 min")
    }

    function test_the_history_is_newest_first_and_capped() {
        var many = []
        for (var i = 0; i < 40; ++i)
            many.push(make("d" + i, "approved", { decided_by: "desktop", decided_at: 100 + i }))
        stub.items = many
        view.refresh()
        compare(findChild(view, "historyList").count, 20)
        compare(view.historyIds[0], "d39")
    }

    function test_a_selection_that_disappears_clears_the_detail() {
        stub.items = [make("a1", "pending")]
        view.refresh()
        view.select("a1")
        stub.items = []
        view.refresh()
        verify(!findChild(view, "detail").visible)
    }
}
