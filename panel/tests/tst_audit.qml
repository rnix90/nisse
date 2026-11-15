// SPDX-License-Identifier: GPL-2.0-or-later
import QtQuick
import QtTest
import "../qml"

TestCase {
    id: tc
    name: "audit"
    when: windowShown
    width: 520
    height: 900
    visible: true

    function rec(i, extra) {
        var r = { ts: "2026-11-14T10:00:" + (i < 10 ? "0" + i : i) + "Z", session: "s1", actor: "user", kind: "message", detail: { text: "hello " + i } }
        for (var k in extra) r[k] = extra[k]
        return r
    }

    QtObject {
        id: stub
        property var queries: []
        property var exports: []
        property var reply: ({ records: [], total: 0, scanned: 0, offset: 0, limit: 100 })
        property string failWith: ""
        property string exportReply: "/home/u/Documents/nisse-audit-2026-11-14.jsonl"
        function searchAudit(json) {
            queries.push(JSON.parse(json))
            if (failWith !== "")
                return ""
            return JSON.stringify(reply)
        }
        function exportAudit(json) {
            exports.push(JSON.parse(json))
            return exportReply
        }
        function sessions() {
            return [
                JSON.stringify({ id: "s1", title: "Taxes", created_at: 1700000000000, started: true, running: false, pending_approvals: 0, keep: "library", open: true, backend: null }),
                JSON.stringify({ id: "s2", title: null, created_at: 1700000060000, started: true, running: false, pending_approvals: 0, keep: "library", open: true, backend: null })
            ]
        }
    }

    AuditView {
        id: view
        anchors.fill: parent
        client: stub
        nowSecs: 1794700000
    }

    function init() {
        stub.queries = []
        stub.exports = []
        stub.failWith = ""
        stub.reply = { records: [rec(1), rec(2)], total: 2, scanned: 2, offset: 0, limit: 100 }
        view.clearFilters()
        stub.queries = []
        view.search()
    }

    function last() { return stub.queries[stub.queries.length - 1] }

    function test_it_opens_on_the_newest_records_with_no_filters() {
        compare(stub.queries.length, 1)
        compare(Object.keys(last()).filter(function (k) { return k !== "limit" && k !== "offset" }).length, 0)
        compare(findChild(view, "resultList").count, 2)
        compare(findChild(view, "countNote").text, "Showing 1-2 of 2")
    }

    function test_the_text_filter_is_sent_trimmed() {
        findChild(view, "searchText").text = "  git push  "
        view.search()
        compare(last().text, "git push")
    }

    function test_the_source_filter_offers_daemon_and_terminal() {
        view.sourceFilter = "terminal"
        view.search()
        compare(last().source, "terminal")
        view.sourceFilter = "daemon"
        view.search()
        compare(last().source, "daemon")
        view.sourceFilter = ""
        view.search()
        compare(last().source, undefined)
    }

    function test_the_tool_and_kind_filters() {
        findChild(view, "toolText").text = "Bash"
        view.kindFilter = "approval-requested"
        view.search()
        compare(last().tool, "Bash")
        compare(last().kind, "approval-requested")
    }

    function test_the_session_filter_uses_the_session_id_and_lists_names() {
        var names = view.sessionChoices.map(function (c) { return c.text })
        compare(names[0], "All sessions")
        compare(names[1], "Taxes")
        verify(names[2].length > 0 && names[2] !== "null")
        view.sessionFilter = "s2"
        view.search()
        compare(last().session, "s2")
    }

    function test_the_time_range_becomes_a_since_time() {
        view.rangeSeconds = 3600
        view.search()
        compare(last().since, new Date((1794700000 - 3600) * 1000).toISOString())
        view.rangeSeconds = 0
        view.search()
        compare(last().since, undefined)
    }

    function test_paging_asks_for_the_next_and_the_previous_page() {
        stub.reply = { records: [rec(1)], total: 250, scanned: 250, offset: 0, limit: 100 }
        view.search()
        verify(!findChild(view, "newerButton").enabled)
        verify(findChild(view, "olderButton").enabled)
        mouseClick(findChild(view, "olderButton"))
        compare(last().offset, 100)
        stub.reply = { records: [rec(1)], total: 250, scanned: 250, offset: 100, limit: 100 }
        view.search(100)
        compare(findChild(view, "countNote").text, "Showing 101-101 of 250")
        verify(findChild(view, "newerButton").enabled)
        mouseClick(findChild(view, "newerButton"))
        compare(last().offset, 0)
    }

    function test_the_last_page_has_no_older_button() {
        var fifty = []
        for (var i = 0; i < 50; ++i) fifty.push(rec(i))
        stub.reply = { records: fifty, total: 150, scanned: 150, offset: 100, limit: 100 }
        view.search(100)
        compare(findChild(view, "countNote").text, "Showing 101-150 of 150")
        verify(!findChild(view, "olderButton").enabled)
    }

    function test_no_matches_says_so() {
        stub.reply = { records: [], total: 0, scanned: 40, offset: 0, limit: 100 }
        view.search()
        verify(findChild(view, "emptyNote").visible)
        compare(findChild(view, "emptyNote").text, "No matching records.")
        compare(findChild(view, "countNote").text, "0 matches")
    }

    function test_a_search_that_fails_says_so_and_keeps_the_last_results() {
        stub.failWith = "x"
        view.search()
        verify(findChild(view, "auditError").visible)
        compare(findChild(view, "resultList").count, 2)
    }

    function test_each_kind_of_record_gets_a_readable_summary() {
        compare(view.summarize(rec(1)), "hello 1")
        compare(view.summarize(rec(1, { kind: "tool", actor: "claude", detail: { hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: { command: "git push" } } })), "Bash: git push")
        compare(view.summarize(rec(1, { kind: "tool", detail: { tool_name: "Edit", tool_input: { file_path: "/tmp/x" } } })), "Edit: /tmp/x")
        compare(view.summarize(rec(1, { kind: "approval-requested", detail: { summary: "Bash: rm -r old (delete)" } })), "Bash: rm -r old (delete)")
        compare(view.summarize(rec(1, { kind: "kill-switch", detail: { engaged: true, reason: "stop" } })), "engaged (stop)")
        compare(view.summarize(rec(1, { kind: "kill-switch", detail: { engaged: false } })), "released")
        verify(view.summarize(rec(1, { kind: "something-new", detail: { a: 1 } })).indexOf("something-new") >= 0)
        compare(view.summarize(rec(1, { kind: "tool", detail: { raw: "garbled" } })).length > 0, true)
    }

    function test_a_long_summary_is_cut() {
        var lots = ""
        for (var i = 0; i < 400; ++i) lots += "x"
        verify(view.summarize(rec(1, { detail: { text: lots } })).length <= 200)
    }

    function test_the_source_of_a_record_is_shown_in_words() {
        compare(view.sourceWords(rec(1)), "daemon")
        compare(view.sourceWords(rec(1, { source: "terminal" })), "terminal")
    }

    function test_selecting_a_record_shows_its_full_detail() {
        view.toggle(0)
        verify(view.expanded === 0)
        verify(view.detailText(stub.reply.records[0]).indexOf("hello 1") >= 0)
        view.toggle(0)
        verify(view.expanded === -1)
    }

    function test_export_sends_the_same_filters_without_a_page_and_shows_where_it_went() {
        findChild(view, "searchText").text = "needle"
        view.sourceFilter = "terminal"
        view.search()
        mouseClick(findChild(view, "exportButton"))
        compare(stub.exports.length, 1)
        compare(stub.exports[0].text, "needle")
        compare(stub.exports[0].source, "terminal")
        compare(stub.exports[0].limit, undefined)
        compare(stub.exports[0].offset, undefined)
        verify(findChild(view, "exportNote").text.indexOf("/home/u/Documents/nisse-audit-2026-11-14.jsonl") >= 0)
    }

    function test_an_export_that_fails_says_why() {
        stub.exportReply = "error: no space left"
        mouseClick(findChild(view, "exportButton"))
        verify(findChild(view, "exportNote").text.indexOf("no space left") >= 0)
        stub.exportReply = "/home/u/Documents/nisse-audit-2026-11-14.jsonl"
    }

    function test_clear_forgets_every_filter_and_searches_again() {
        findChild(view, "searchText").text = "x"
        view.sourceFilter = "terminal"
        view.kindFilter = "tool"
        stub.queries = []
        mouseClick(findChild(view, "clearButton"))
        compare(findChild(view, "searchText").text, "")
        compare(view.sourceFilter, "")
        compare(view.kindFilter, "")
        compare(stub.queries.length, 1)
    }
}
