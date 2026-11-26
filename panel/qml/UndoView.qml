// SPDX-License-Identifier: GPL-2.0-or-later
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// System history (N-311): the changes nisse made to the system (an AI turn, an update, a package change), newest first and grouped
// by day, each with an Undo button. Going back to one means going back to how the system was BEFORE it, which undoes everything
// made after it too; the confirmation lists those and says that home and data are not covered and that the computer restarts at
// once. The list and the undo itself live in the daemon (ListUndo, Undo); this view shows them and asks.
ColumnLayout {
    id: root
    property var client
    // The clock in unix seconds; a property so tests can set it.
    property real nowSecs: Math.floor(Date.now() / 1000)
    // How many chats have a turn in progress (the daemon refuses an undo then: the restart would cut them off).
    property int chatsWorking: 0

    property var entries: []
    property var rows: []               // the entries with a header before each new day: { header } or { entry }
    property string errorText: ""
    property bool confirming: false
    property bool restarting: false
    property var selected: null

    readonly property int laterLimit: 6
    readonly property string intro: "Go back to how the system was before a change. That undoes the change and everything made after it."

    spacing: 8

    function reset() {
        entries = []
        rows = []
        errorText = ""
        confirming = false
        restarting = false
        selected = null
    }

    // ---- words
    function labelOf(e) {
        if (e.kind === "ai-turn")
            return e.title && e.title !== "" ? e.title : "Untitled Chat"
        if (e.kind === "update")
            return "System Update"
        if (e.kind === "package")
            return "Package Change"
        return "Change"
    }

    function detailOf(e) {
        if (e.kind === "ai-turn")
            return "AI Turn"
        if (e.kind === "update")
            return "Updated by nisse"
        if (e.kind === "package")
            return "Software Installed, Removed or Updated"
        return ""
    }

    function timeOf(e) {
        return Qt.formatTime(new Date(e.at), "HH:mm")
    }

    function dayOf(ms) {
        var now = new Date(nowSecs * 1000)
        var d = new Date(ms)
        var today = new Date(now.getFullYear(), now.getMonth(), now.getDate())
        var that = new Date(d.getFullYear(), d.getMonth(), d.getDate())
        var days = Math.round((today.getTime() - that.getTime()) / 86400000)
        if (days === 0)
            return "Today"
        if (days === 1)
            return "Yesterday"
        return Qt.formatDate(that, d.getFullYear() === now.getFullYear() ? "MMM d" : "MMM d, yyyy")
    }

    function buildRows(list) {
        var out = []
        var last = ""
        for (var i = 0; i < list.length; ++i) {
            var day = dayOf(list[i].at)
            if (day !== last) {
                out.push({ header: day })
                last = day
            }
            out.push({ entry: list[i] })
        }
        return out
    }

    // ---- the list
    function refresh() {
        errorText = ""
        var text = client && client.undoList ? client.undoList() : ""
        var parsed = null
        try {
            parsed = JSON.parse(text)
        } catch (e) {
            parsed = null
        }
        if (parsed === null || typeof parsed !== "object" || !Array.isArray(parsed.entries)) {
            entries = []
            rows = []
            errorText = "Could not read the list of changes from the nisse daemon."
            return
        }
        if (parsed.error) {
            entries = []
            rows = []
            errorText = parsed.error
            return
        }
        entries = parsed.entries
        rows = buildRows(entries)
    }

    function canUndo(e) {
        return !restarting && chatsWorking === 0 && e.bootable === true
    }

    // ---- the question
    function laterChanges(e) {
        var out = []
        for (var i = 0; i < entries.length; ++i) {
            if (entries[i].id === e.id)
                break
            out.push(entries[i])
        }
        return out
    }

    function laterText(e) {
        var later = laterChanges(e)
        if (later.length === 0)
            return "Nothing else has changed since."
        var text = "This also undoes " + later.length + (later.length === 1 ? " later change:" : " later changes:")
        for (var i = 0; i < later.length && i < laterLimit; ++i)
            text += "\n" + dayOf(later[i].at) + " " + timeOf(later[i]) + "  " + labelOf(later[i])
        if (later.length > laterLimit)
            text += "\nand " + (later.length - laterLimit) + " more"
        return text
    }

    function ask(e) {
        errorText = ""
        selected = e
        confirming = true
    }

    function cancel() {
        confirming = false
        selected = null
    }

    function go() {
        if (selected === null)
            return
        var error = client.undo(selected.id)
        confirming = false
        selected = null
        if (error !== "")
            errorText = error
        else
            restarting = true
    }

    Component.onCompleted: refresh()
    onVisibleChanged: if (visible && !restarting) refresh()

    Connections {
        target: root.client
        function onReconnected() { root.refresh() }
        // a turn that ended may have left a snapshot
        function onDone(session) { if (root.visible && !root.confirming && !root.restarting) root.refresh() }
    }

    Label {
        Layout.fillWidth: true
        wrapMode: Text.Wrap
        opacity: 0.8
        text: root.intro
        visible: !root.confirming
    }

    Label {
        objectName: "errorNote"
        Layout.fillWidth: true
        wrapMode: Text.Wrap
        color: "#c0392b"
        text: root.errorText
        visible: root.errorText !== ""
    }

    Label {
        objectName: "workingNote"
        Layout.fillWidth: true
        wrapMode: Text.Wrap
        text: "A chat is working. Stop it before you undo anything, because the restart would cut it off."
        visible: root.chatsWorking > 0 && !root.restarting
    }

    Label {
        objectName: "emptyNote"
        Layout.fillWidth: true
        wrapMode: Text.Wrap
        opacity: 0.8
        text: "Nothing to undo yet. nisse keeps a snapshot before each change the AI makes and each update or package change."
        visible: root.rows.length === 0 && root.errorText === "" && !root.restarting
    }

    Label {
        objectName: "restartingNote"
        Layout.fillWidth: true
        wrapMode: Text.Wrap
        font.bold: true
        text: "Going back and restarting the computer..."
        visible: root.restarting
    }

    Column {
        objectName: "rowList"
        Layout.fillWidth: true
        spacing: 4
        visible: !root.confirming && root.rows.length > 0

        Repeater {
            model: root.rows

            delegate: Column {
                width: parent ? parent.width : 0
                spacing: 2

                Label {
                    visible: modelData.header !== undefined
                    topPadding: 6
                    font.bold: true
                    opacity: 0.7
                    text: modelData.header !== undefined ? modelData.header : ""
                }

                RowLayout {
                    visible: modelData.entry !== undefined
                    width: parent.width
                    spacing: 8

                    Label {
                        objectName: modelData.entry ? "undoTime-" + modelData.entry.id : ""
                        Layout.alignment: Qt.AlignTop
                        opacity: 0.7
                        text: modelData.entry ? root.timeOf(modelData.entry) : ""
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        Label {
                            objectName: modelData.entry ? "undoLabel-" + modelData.entry.id : ""
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            text: modelData.entry ? root.labelOf(modelData.entry) : ""
                        }
                        Label {
                            objectName: modelData.entry ? "undoDetail-" + modelData.entry.id : ""
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            opacity: 0.7
                            text: modelData.entry ? root.detailOf(modelData.entry) : ""
                        }
                        Label {
                            objectName: modelData.entry ? "undoWhy-" + modelData.entry.id : ""
                            Layout.fillWidth: true
                            wrapMode: Text.Wrap
                            color: "#c0392b"
                            visible: modelData.entry !== undefined && modelData.entry.bootable !== true
                            text: modelData.entry && modelData.entry.bootable !== true
                                ? "Cannot be undone any more: " + (modelData.entry.reason ? modelData.entry.reason : "its snapshot cannot boot")
                                : ""
                        }
                    }
                    Button {
                        objectName: modelData.entry ? "undoButton-" + modelData.entry.id : ""
                        Layout.alignment: Qt.AlignTop
                        text: "Undo"
                        enabled: modelData.entry !== undefined && root.canUndo(modelData.entry)
                        onClicked: root.ask(modelData.entry)
                    }
                }
            }
        }
    }

    ColumnLayout {
        objectName: "confirmCard"
        Layout.fillWidth: true
        spacing: 10
        visible: root.confirming

        Label {
            objectName: "confirmTitle"
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            font.bold: true
            text: root.selected
                ? "Go back to before \"" + root.labelOf(root.selected) + "\" (" + root.dayOf(root.selected.at) + " " + root.timeOf(root.selected) + ")?"
                : ""
        }
        Label {
            objectName: "confirmLater"
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            text: root.selected ? root.laterText(root.selected) : ""
        }
        Label {
            objectName: "confirmHome"
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            text: "Your files in your home folder and your data are not covered by this: they stay exactly as they are."
        }
        Label {
            objectName: "confirmRestart"
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            font.bold: true
            text: "The computer restarts right away. Save your work first."
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            Button {
                objectName: "confirmCancel"
                text: "Cancel"
                onClicked: root.cancel()
            }
            Button {
                objectName: "confirmGo"
                text: "Undo and Restart"
                highlighted: true
                onClicked: root.go()
            }
        }
    }
}
