// SPDX-License-Identifier: GPL-2.0-or-later
import QtQuick
import QtTest
import "../qml"

// N-311: the undo list in Settings ("System History"): what each row says, what is disabled and why, the confirmation, and the one
// call the confirmation makes. The list and the undo itself live in the daemon; the stub stands in for it.
TestCase {
    id: tc
    name: "undo"
    when: windowShown
    width: 420
    height: 720
    visible: true

    QtObject {
        id: stub
        property var entries: []        // what the daemon's ListUndo would return, newest first
        property string listError: ""
        property string rawAnswer: ""   // when set, undoList() answers with exactly this text
        property var undone: []
        property string undoFail: ""
        property int lists: 0
        signal reconnected()
        signal done(string session)

        function undoList() {
            lists += 1
            if (rawAnswer !== "")
                return rawAnswer
            return JSON.stringify({ entries: listError === "" ? entries : [], error: listError })
        }
        function undo(id) {
            undone.push(id)
            return undoFail
        }
    }

    UndoView {
        id: view
        width: 420
        client: stub
        nowSecs: new Date(2026, 10, 21, 15, 0, 0).getTime() / 1000
    }

    function ms(y, mo, d, h, mi) { return new Date(y, mo, d, h, mi, 0).getTime() }

    function make(id, kind, at, extra) {
        var e = { id: id, kind: kind, at: at, session: null, title: null, post: id + 1, bootable: true, reason: null }
        for (var k in extra) e[k] = extra[k]
        return e
    }

    // today 14:32 (an AI turn in "Downloads cleanup"), today 11:05 (an untitled chat), yesterday 21:40 (an update), Nov 18 (a package change)
    function sample() {
        return [
            make(50, "ai-turn", ms(2026, 10, 21, 14, 32), { session: "s1", title: "Downloads cleanup" }),
            make(46, "ai-turn", ms(2026, 10, 21, 11, 5), { session: "s2" }),
            make(43, "update", ms(2026, 10, 20, 21, 40)),
            make(30, "package", ms(2026, 10, 18, 7, 0))
        ]
    }

    function init() {
        stub.entries = []
        stub.listError = ""
        stub.rawAnswer = ""
        stub.undone = []
        stub.undoFail = ""
        stub.lists = 0
        view.chatsWorking = 0
        view.reset()
    }

    function test_nothing_to_undo_shows_the_empty_note() {
        view.refresh()
        verify(findChild(view, "emptyNote").visible)
        compare(view.rows.length, 0)
        verify(!findChild(view, "errorNote").visible)
    }

    function test_rows_are_grouped_by_day_newest_first() {
        stub.entries = sample()
        view.refresh()
        var r = view.rows
        compare(r.length, 4 + 3)
        compare(r[0].header, "Today")
        compare(r[1].entry.id, 50)
        compare(r[2].entry.id, 46)
        compare(r[3].header, "Yesterday")
        compare(r[4].entry.id, 43)
        compare(r[5].header, Qt.formatDate(new Date(2026, 10, 18), "MMM d"))
        compare(r[6].entry.id, 30)
        verify(!findChild(view, "emptyNote").visible)
    }

    function test_each_row_says_the_time_and_who_or_what() {
        stub.entries = sample()
        view.refresh()
        var e = stub.entries
        compare(view.labelOf(e[0]), "Downloads cleanup")
        compare(view.detailOf(e[0]), "AI Turn")
        compare(view.labelOf(e[1]), "Untitled Chat")
        compare(view.detailOf(e[1]), "AI Turn")
        compare(view.labelOf(e[2]), "System Update")
        compare(view.labelOf(e[3]), "Package Change")
        compare(view.timeOf(e[0]), Qt.formatTime(new Date(e[0].at), "HH:mm"))
        compare(findChild(view, "undoTime-50").text, view.timeOf(e[0]))
        compare(findChild(view, "undoLabel-50").text, "Downloads cleanup")
        compare(findChild(view, "undoDetail-50").text, "AI Turn")
    }

    function test_a_failing_list_shows_the_reason_and_no_rows() {
        stub.listError = "snapper could not list the snapshots"
        view.refresh()
        compare(view.rows.length, 0)
        verify(findChild(view, "errorNote").visible)
        verify(findChild(view, "errorNote").text.indexOf("snapper could not list the snapshots") >= 0)
        verify(!findChild(view, "emptyNote").visible)
    }

    function test_an_unreadable_answer_is_an_error_not_an_empty_list() {
        stub.rawAnswer = "this is not json"
        view.refresh()
        verify(findChild(view, "errorNote").visible)
        compare(view.rows.length, 0)
        stub.rawAnswer = ""
        view.refresh()
        verify(!findChild(view, "errorNote").visible)
    }

    function test_every_row_has_an_undo_button_that_is_enabled() {
        stub.entries = sample()
        view.refresh()
        for (var i = 0; i < stub.entries.length; ++i) {
            var b = findChild(view, "undoButton-" + stub.entries[i].id)
            verify(b !== null, "button " + stub.entries[i].id)
            verify(b.enabled)
        }
    }

    function test_a_change_that_cannot_boot_is_disabled_and_says_why() {
        stub.entries = [make(43, "update", ms(2026, 10, 20, 21, 40), { bootable: false, reason: "its kernel is no longer in /boot" })]
        view.refresh()
        verify(!findChild(view, "undoButton-43").enabled)
        var why = findChild(view, "undoWhy-43")
        verify(why.visible)
        verify(why.text.indexOf("its kernel is no longer in /boot") >= 0)
    }

    function test_while_a_chat_is_working_nothing_can_be_undone_and_the_note_says_so() {
        stub.entries = sample()
        view.refresh()
        view.chatsWorking = 1
        verify(findChild(view, "workingNote").visible)
        verify(findChild(view, "workingNote").text.indexOf("working") >= 0)
        verify(!findChild(view, "undoButton-50").enabled)
        view.chatsWorking = 0
        verify(!findChild(view, "workingNote").visible)
        verify(findChild(view, "undoButton-50").enabled)
    }

    function test_clicking_undo_opens_the_confirmation_and_calls_nothing() {
        stub.entries = sample()
        view.refresh()
        mouseClick(findChild(view, "undoButton-46"))
        verify(view.confirming)
        verify(findChild(view, "confirmCard").visible)
        verify(!findChild(view, "rowList").visible, "the list steps aside for the question")
        compare(stub.undone.length, 0)
    }

    function test_the_confirmation_names_the_change_and_lists_what_came_after() {
        stub.entries = sample()
        view.refresh()
        view.ask(stub.entries[2])            // the update of yesterday: the two AI turns of today came after it
        var title = findChild(view, "confirmTitle").text
        verify(title.indexOf("System Update") >= 0, title)
        var later = findChild(view, "confirmLater").text
        verify(later.indexOf("Downloads cleanup") >= 0, later)
        verify(later.indexOf("Untitled Chat") >= 0, later)
        verify(later.indexOf("System Update") < 0, "the change itself is not listed as 'after'")
        verify(later.indexOf("Package Change") < 0, "an older change is not listed as 'after'")
    }

    function test_the_confirmation_says_what_is_and_is_not_covered_and_that_it_restarts() {
        stub.entries = sample()
        view.refresh()
        view.ask(stub.entries[3])
        var all = findChild(view, "confirmLater").text + " " + findChild(view, "confirmHome").text + " " + findChild(view, "confirmRestart").text
        verify(findChild(view, "confirmHome").text.indexOf("home") >= 0)
        verify(findChild(view, "confirmHome").text.indexOf("data") >= 0)
        verify(findChild(view, "confirmHome").text.indexOf("not covered") >= 0)
        verify(findChild(view, "confirmRestart").text.indexOf("restarts") >= 0)
        verify(findChild(view, "confirmRestart").text.indexOf("Save your work") >= 0)
        verify(findChild(view, "confirmGo").text === "Undo and Restart")
        verify(findChild(view, "confirmCancel").text === "Cancel")
    }

    function test_the_newest_change_says_nothing_came_after_it() {
        stub.entries = sample()
        view.refresh()
        view.ask(stub.entries[0])
        verify(findChild(view, "confirmLater").text.indexOf("Nothing else has changed since") >= 0)
    }

    function test_a_long_list_of_later_changes_is_cut_and_counted() {
        var many = []
        for (var i = 0; i < 9; ++i)
            many.push(make(100 - i, "package", ms(2026, 10, 21, 10 + i % 4, i)))
        many.push(make(20, "update", ms(2026, 10, 15, 8, 0)))       // the oldest: all nine are after it
        stub.entries = many
        view.refresh()
        view.ask(many[9])
        var later = findChild(view, "confirmLater").text
        verify(later.indexOf("and 3 more") >= 0, later)
        compare(later.split("Package Change").length - 1, 6)
    }

    function test_cancel_goes_back_to_the_list_and_calls_nothing() {
        stub.entries = sample()
        view.refresh()
        view.ask(stub.entries[1])
        mouseClick(findChild(view, "confirmCancel"))
        verify(!view.confirming)
        verify(findChild(view, "rowList").visible)
        compare(stub.undone.length, 0)
    }

    function test_confirming_calls_undo_once_with_the_before_snapshot_and_shows_the_restart() {
        stub.entries = sample()
        view.refresh()
        view.ask(stub.entries[1])
        mouseClick(findChild(view, "confirmGo"))
        compare(stub.undone.length, 1)
        compare(stub.undone[0], 46)
        verify(view.restarting)
        verify(findChild(view, "restartingNote").visible)
        verify(!findChild(view, "undoButton-50").enabled, "nothing more can be clicked while it restarts")
        verify(!view.confirming)
    }

    function test_a_refused_undo_shows_the_daemons_words_and_goes_back_to_the_list() {
        stub.entries = sample()
        stub.undoFail = "a chat is still working: stop it first, because the restart would cut it off"
        view.refresh()
        view.ask(stub.entries[1])
        mouseClick(findChild(view, "confirmGo"))
        verify(!view.restarting)
        verify(!view.confirming)
        verify(findChild(view, "errorNote").visible)
        verify(findChild(view, "errorNote").text.indexOf("still working") >= 0)
    }

    function test_the_list_is_read_again_when_the_daemon_comes_back() {
        view.refresh()
        var before = stub.lists
        stub.entries = sample()
        stub.reconnected()
        verify(stub.lists > before)
        compare(view.rows.length, 7)
    }

    function test_the_list_is_read_again_when_a_turn_ends_if_the_page_is_showing() {
        view.refresh()
        var before = stub.lists
        stub.entries = sample()
        stub.done("s1")
        verify(stub.lists > before)
        compare(view.rows.length, 7)
    }

    function test_every_word_is_plain_ascii() {
        stub.entries = sample()
        view.refresh()
        view.ask(stub.entries[2])
        var texts = [findChild(view, "confirmTitle").text, findChild(view, "confirmLater").text, findChild(view, "confirmHome").text,
                     findChild(view, "confirmRestart").text, findChild(view, "confirmGo").text, findChild(view, "confirmCancel").text,
                     findChild(view, "emptyNote").text, findChild(view, "workingNote").text, view.intro]
        for (var i = 0; i < texts.length; ++i) {
            for (var j = 0; j < texts[i].length; ++j)
                verify(texts[i].charCodeAt(j) < 128, "non-ASCII character in: " + texts[i])
        }
    }
}
