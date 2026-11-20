// SPDX-License-Identifier: GPL-2.0-or-later
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Several conversations at once (N-206). The daemon owns which sessions exist, their order and their names; this view
// shows them as tabs and never invents an id. Only the selected tab shows its transcript. A background tab shows its
// title and one status dot: red "needs you" (an approval is waiting on it), amber "working", green "unread" (it
// finished while you were elsewhere). Its text is kept and appears when the tab is selected.
Item {
    id: root
    property var client

    // The daemon's list, as plain objects (id, title, created_at, started, running, pending_approvals).
    property var tabs: []
    // Sessions waiting in the library (not tabs): kept through a reboot, reopened on demand (N-208).
    property var library: []
    property string selectedKeep: "library"
    // The backends the daemon knows, as picker choices (the first is "use the default"), and the choice of the selected tab.
    property var backendChoices: []
    property string selectedBackend: ""
    property string backendNote: ""
    property string selectedId: ""
    property string renamingId: ""
    property string errorText: ""
    property var workingMap: ({})
    property var unreadMap: ({})
    // Total approvals waiting across all sessions, and sessions that finished unseen (the taskbar badges, N-207).
    property int needsYouCount: 0
    property int unreadCount: 0
    // Sessions with a turn running: by their own chunks or by the daemon's word (the tray item's busy state, N-415b).
    readonly property int workingCount: {
        var n = 0
        for (var i = 0; i < tabs.length; ++i)
            if (tabs[i].running === true || workingMap[tabs[i].id] === true)
                n += 1
        return n
    }

    property bool creating: false
    property string pendingSelect: ""

    ListModel { id: tabModel }

    function reset() {
        tabModel.clear()
        tabs = []
        library = []
        selectedKeep = "library"
        selectedBackend = ""
        backendNote = ""
        selectedId = ""
        renamingId = ""
        errorText = ""
        workingMap = ({})
        unreadMap = ({})
        needsYouCount = 0
        unreadCount = 0
        pendingSelect = ""
    }

    function defaultTitle(createdMs) {
        return Qt.formatDateTime(new Date(createdMs), "MMM d, HH:mm")
    }

    function titleOf(s) {
        return s.title ? s.title : defaultTitle(s.created_at)
    }

    function parseList() {
        var lines = client.sessions()
        var out = []
        for (var i = 0; i < lines.length; ++i) {
            try {
                out.push(JSON.parse(lines[i]))
            } catch (e) {
                // a damaged entry is skipped
            }
        }
        return out
    }

    function indexOfId(id) {
        for (var i = 0; i < tabModel.count; ++i)
            if (tabModel.get(i).sid === id)
                return i
        return -1
    }

    function chatFor(id) {
        for (var i = 0; i < chats.count; ++i) {
            var item = chats.itemAt(i)
            if (item && item.session === id)
                return item
        }
        return null
    }

    function isOpen(s) { return s.open !== false }

    function refresh() {
        if (creating)
            return
        var all = parseList()
        var list = all.filter(isOpen)
        if (list.length === 0) {
            creating = true
            var made = client.newSession()
            creating = false
            if (made !== "") {
                all = parseList()
                list = all.filter(isOpen)
            }
        }
        library = all.filter(function (s) { return !isOpen(s) })
        loadBackends()

        // Sync the model in place so the transcripts of the tabs that stay are kept.
        var keep = {}
        for (var i = 0; i < list.length; ++i)
            keep[list[i].id] = true
        for (var r = tabModel.count - 1; r >= 0; --r) {
            if (!keep[tabModel.get(r).sid]) {
                var gone = tabModel.get(r).sid
                tabModel.remove(r)
                var w = Object.assign({}, workingMap); delete w[gone]; workingMap = w
                var u = Object.assign({}, unreadMap); delete u[gone]; unreadMap = u
            }
        }
        for (var j = 0; j < list.length; ++j) {
            var s = list[j]
            var at = indexOfId(s.id)
            var row = { sid: s.id, title: s.title ? s.title : "", createdAt: s.created_at, started: s.started === true,
                        running: s.running === true, pending: s.pending_approvals | 0, restored: s.started === true,
                        keep: s.keep ? s.keep : "library", backend: s.backend ? s.backend : "" }
            if (at < 0) {
                tabModel.append(row)
            } else {
                tabModel.setProperty(at, "title", row.title)
                tabModel.setProperty(at, "running", row.running)
                tabModel.setProperty(at, "pending", row.pending)
                tabModel.setProperty(at, "keep", row.keep)
                tabModel.setProperty(at, "backend", row.backend)
            }
        }
        tabs = list
        var pend = 0
        for (var p = 0; p < list.length; ++p)
            pend += list[p].pending_approvals | 0
        needsYouCount = pend

        if (indexOfId(selectedId) < 0) {
            var next = pendingSelect !== "" && indexOfId(pendingSelect) >= 0 ? pendingSelect : ""
            if (next === "" && list.length > 0)
                next = list[list.length - 1].id
            pendingSelect = ""
            selectedId = ""
            if (next !== "")
                select(next)
        }
        countUnread()
        updateKeep()
    }

    function updateKeep() {
        var at = indexOfId(selectedId)
        selectedKeep = at >= 0 ? tabModel.get(at).keep : "library"
        selectedBackend = at >= 0 ? tabModel.get(at).backend : ""
        updateBackendNote()
    }

    function targetWords(target) {
        return target === "local-ollama" ? "this computer" : (target === "remote-ollama" ? "another computer" : "Max account")
    }

    function loadBackends() {
        var rows = []
        var lines = client.backends()
        var defaultName = ""
        for (var i = 0; i < lines.length; ++i) {
            try {
                var b = JSON.parse(lines[i])
                rows.push(b)
                if (b["default"] === true)
                    defaultName = b.name
            } catch (e) {
                // a damaged entry is skipped
            }
        }
        if (rows.length === 0) {
            backendChoices = []
            return
        }
        var choices = [{ text: "Default (" + defaultName + ")", value: "" }]
        for (var j = 0; j < rows.length; ++j)
            choices.push({ text: rows[j].name + " - " + targetWords(rows[j].target), value: rows[j].name })
        backendChoices = choices
    }

    function updateBackendNote() {
        if (selectedBackend === "") {
            backendNote = ""
            return
        }
        for (var i = 0; i < backendChoices.length; ++i) {
            if (backendChoices[i].value === selectedBackend) {
                var target = backendChoices[i].text.split(" - ")[1]
                backendNote = "This session runs on " + selectedBackend + " (" + target + ")."
                return
            }
        }
        backendNote = "This session is set to " + selectedBackend + ", which is not in the configuration. Pick another backend."
    }

    function chooseBackend(name) {
        if (selectedId === "")
            return
        errorText = client.setSessionBackend(selectedId, name)
        refresh()
    }

    function keepText(keep) {
        return keep === "always" ? "keep open" : (keep === "drop" ? "drop" : "keep in library")
    }

    function cycleKeep() {
        if (selectedId === "")
            return
        var next = selectedKeep === "library" ? "always" : (selectedKeep === "always" ? "drop" : "library")
        errorText = client.setKeepMode(selectedId, next)
        refresh()
    }

    function openFromLibrary(id) {
        errorText = client.openSession(id)
        refresh()
        select(id)
    }

    function deleteFromLibrary(id) {
        errorText = client.closeSession(id)
        refresh()
    }

    function countUnread() {
        var n = 0
        for (var k in unreadMap)
            if (unreadMap[k] && indexOfId(k) >= 0)
                n += 1
        unreadCount = n
    }

    function select(id) {
        if (indexOfId(id) < 0)
            return
        selectedId = id
        var u = Object.assign({}, unreadMap)
        u[id] = false
        unreadMap = u
        countUnread()
        updateKeep()
    }

    function newTab() {
        creating = true
        var id = client.newSession()
        creating = false
        if (id === "") {
            errorText = "The nisse daemon is not reachable. Try again in a moment."
            return
        }
        errorText = ""
        refresh()
        select(id)
    }

    function closeTab(id) {
        var at = indexOfId(id)
        if (at < 0)
            return
        if (id === selectedId) {
            var neighbour = at + 1 < tabModel.count ? tabModel.get(at + 1).sid : (at > 0 ? tabModel.get(at - 1).sid : "")
            pendingSelect = neighbour
        }
        if (renamingId === id)
            renamingId = ""
        var err = client.closeSession(id)
        errorText = err
        refresh()
    }

    function startRename(id) {
        var at = indexOfId(id)
        if (at < 0)
            return
        renamingId = id
        renameField.text = tabModel.get(at).title
        renameField.forceActiveFocus()
        renameField.selectAll()
    }

    function commitRename() {
        if (renamingId === "")
            return
        var id = renamingId
        renamingId = ""
        errorText = client.renameSession(id, renameField.text)
        refresh()
    }

    function cancelRename() {
        renamingId = ""
    }

    function statusOf(pending, running, id, working, unread) {
        if (pending > 0)
            return "needs-you"
        if (running || working[id] === true)
            return "working"
        if (unread[id] === true)
            return "unread"
        return "idle"
    }

    Component.onCompleted: refresh()

    Connections {
        target: root.client
        function onSessionsChanged() { root.refresh() }
        function onApprovalChanged() { root.refresh() }
        function onReconnected() {
            root.refresh()
            for (var i = 0; i < root.tabs.length; ++i) {
                var chat = root.chatFor(root.tabs[i].id)
                if (chat)
                    chat.catchUp(root.tabs[i].running === true)
            }
        }
        function onChunk(sid, text) {
            if (root.workingMap[sid] !== true) {
                var w = Object.assign({}, root.workingMap)
                w[sid] = true
                root.workingMap = w
            }
        }
        function onDone(sid) {
            var w = Object.assign({}, root.workingMap)
            w[sid] = false
            root.workingMap = w
            if (sid !== root.selectedId && root.indexOfId(sid) >= 0) {
                var u = Object.assign({}, root.unreadMap)
                u[sid] = true
                root.unreadMap = u
                root.countUnread()
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ---- the tab bar
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 36
            color: "#232d3d"

            RowLayout {
                anchors.fill: parent
                spacing: 2

                Flickable {
                    id: bar
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    contentWidth: tabRow.width
                    contentHeight: height
                    flickableDirection: Flickable.HorizontalFlick
                    boundsBehavior: Flickable.StopAtBounds

                    Item {
                      id: tabRow
                      width: tabModel.count * 170
                      height: bar.height
                      Repeater {
                    model: tabModel
                    delegate: Rectangle {
                        id: tab
                        required property int index
                        required property string sid
                        required property string title
                        required property real createdAt
                        required property bool running
                        required property int pending
                        objectName: "tab-" + sid
                        readonly property string status: root.statusOf(pending, running, sid, root.workingMap, root.unreadMap)
                        readonly property bool selected: sid === root.selectedId
                        x: index * 170
                        width: 168
                        height: bar.height
                        color: selected ? "#1b2330" : "transparent"
                        border.color: selected ? "#e0623f" : "transparent"
                        border.width: selected ? 1 : 0

                        MouseArea {
                            anchors.fill: parent
                            onClicked: root.select(tab.sid)
                            onDoubleClicked: root.startRename(tab.sid)
                        }

                        Rectangle {
                            id: dot
                            objectName: "dot-" + tab.sid
                            anchors.left: parent.left
                            anchors.leftMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            width: 9
                            height: 9
                            radius: 5
                            color: tab.status === "needs-you" ? "#e0623f"
                                 : tab.status === "working" ? "#d9a441"
                                 : tab.status === "unread" ? "#5fa86b" : "#46505f"
                        }

                        Label {
                            objectName: "tabLabel-" + tab.sid
                            anchors.left: dot.right
                            anchors.leftMargin: 6
                            anchors.right: closeButton.left
                            anchors.verticalCenter: parent.verticalCenter
                            elide: Text.ElideRight
                            color: "#f6f2e9"
                            font.bold: tab.selected
                            text: tab.title !== "" ? tab.title : root.defaultTitle(tab.createdAt)
                        }

                        ToolButton {
                            id: closeButton
                            objectName: "closeTab-" + tab.sid
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            width: 28
                            height: 28
                            text: "x"
                            onClicked: root.closeTab(tab.sid)
                        }
                    }
                      }
                    }
                }

                ToolButton {
                    objectName: "newTab"
                    text: "+"
                    onClicked: root.newTab()
                }
                ToolButton {
                    objectName: "libraryButton"
                    text: root.library.length > 0 ? "Library (" + root.library.length + ")" : "Library"
                    onClicked: libraryPopup.open()
                }
            }
        }

        // ---- what a reboot does to the selected tab
        RowLayout {
            Layout.fillWidth: true
            Layout.margins: 4
            visible: root.selectedId !== ""
            Button {
                objectName: "keepToggle"
                flat: true
                text: "After a reboot: " + root.keepText(root.selectedKeep)
                onClicked: root.cycleKeep()
            }
            Label {
                Layout.fillWidth: true
                elide: Text.ElideRight
                opacity: 0.6
                text: "click to change"
            }
        }

        // ---- which backend the selected tab's turns go to (N-211)
        RowLayout {
            Layout.fillWidth: true
            Layout.margins: 4
            visible: root.selectedId !== "" && root.backendChoices.length > 0
            Label { text: "Backend:" }
            ComboBox {
                id: backendPicker
                objectName: "backendPicker"
                Layout.fillWidth: true
                visible: root.backendChoices.length > 0
                textRole: "text"
                valueRole: "value"
                model: root.backendChoices
                currentIndex: {
                    for (var i = 0; i < root.backendChoices.length; ++i)
                        if (root.backendChoices[i].value === root.selectedBackend)
                            return i
                    return 0
                }
                onActivated: root.chooseBackend(root.backendChoices[currentIndex].value)
            }
        }
        Label {
            Layout.fillWidth: true
            Layout.margins: 4
            visible: root.backendNote !== ""
            wrapMode: Text.Wrap
            opacity: 0.8
            text: root.backendNote
        }

        // ---- renaming one tab
        RowLayout {
            Layout.fillWidth: true
            Layout.margins: 4
            visible: root.renamingId !== ""
            Label { text: "Name:" }
            TextField {
                id: renameField
                objectName: "renameField"
                Layout.fillWidth: true
                placeholderText: "Empty goes back to the date and time"
                onAccepted: root.commitRename()
                Keys.onEscapePressed: root.cancelRename()
            }
            Button { text: "Save"; onClicked: root.commitRename() }
            Button { text: "Cancel"; onClicked: root.cancelRename() }
        }

        Label {
            Layout.fillWidth: true
            Layout.margins: 4
            visible: root.errorText !== ""
            wrapMode: Text.Wrap
            color: "#e0623f"
            text: root.errorText
        }

        // ---- the transcripts: one chat per session, only the selected one visible
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            Repeater {
                id: chats
                model: tabModel
                delegate: ChatView {
                    required property string sid
                    required property bool restored
                    anchors.fill: parent
                    client: root.client
                    session: sid
                    visible: sid === root.selectedId
                    Component.onCompleted: {
                        if (restored)
                            replay()
                    }
                }
            }

            ColumnLayout {
                objectName: "offlineNote"
                anchors.centerIn: parent
                visible: tabModel.count === 0
                spacing: 8
                Label { text: "The nisse daemon is not reachable."; Layout.alignment: Qt.AlignHCenter }
                Button {
                    objectName: "retry"
                    text: "Try again"
                    Layout.alignment: Qt.AlignHCenter
                    onClicked: root.refresh()
                }
            }
        }
    }

    Popup {
        id: libraryPopup
        objectName: "libraryPopup"
        modal: true
        anchors.centerIn: parent
        width: Math.min(parent.width - 24, 420)
        padding: 12
        ColumnLayout {
            anchors.fill: parent
            spacing: 6
            Label { text: "Library"; font.bold: true }
            Label {
                visible: root.library.length === 0
                opacity: 0.7
                text: "Nothing here. Sessions kept in the library after a reboot show up here."
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            Repeater {
                model: root.library
                delegate: RowLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    Label {
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                        text: modelData.title ? modelData.title : root.defaultTitle(modelData.created_at)
                    }
                    Button {
                        text: "Open"
                        onClicked: { libraryPopup.close(); root.openFromLibrary(modelData.id) }
                    }
                    Button {
                        text: "Delete"
                        onClicked: root.deleteFromLibrary(modelData.id)
                    }
                }
            }
        }
    }
}
