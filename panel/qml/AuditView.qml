// SPDX-License-Identifier: GPL-2.0-or-later
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The audit log (N-217): everything the AI said and did on this computer, searchable. The daemon does the searching (any
// other client can ask it the same way); this shows the newest records first, 100 at a time, and exports what matches.
Item {
    id: root
    property var client
    // The clock in unix seconds; a property so tests can set it.
    property real nowSecs: Math.floor(Date.now() / 1000)

    // the filters
    property string sourceFilter: ""      // "", "daemon" or "terminal"
    property string kindFilter: ""
    property string sessionFilter: ""
    property real rangeSeconds: 0         // 0 means any time

    property var records: []
    property int total: 0
    property int offset: 0
    property int pageLimit: 100
    property int expanded: -1
    property string errorText: ""
    property string exportText: ""
    property var sessionChoices: [{ text: "All Sessions", value: "" }]

    readonly property var kinds: ["", "message", "tool", "approval-requested", "approval-approved", "approval-denied",
        "approval-expired", "cancel", "kill-switch", "remote-access", "session-closed", "session-backend", "backend-fallback", "config-changed"]

    function loadSessions() {
        var choices = [{ text: "All Sessions", value: "" }]
        var lines = client && client.sessions ? client.sessions() : []
        for (var i = 0; i < lines.length; ++i) {
            try {
                var s = JSON.parse(lines[i])
                choices.push({ text: s.title ? s.title : Qt.formatDateTime(new Date(s.created_at), "MMM d, HH:mm"), value: s.id })
            } catch (e) {
                // a damaged entry is skipped
            }
        }
        sessionChoices = choices
    }

    // what the filters say, without a page
    function queryObject() {
        var q = {}
        var text = searchText.text.trim()
        if (text !== "")
            q.text = text
        var tool = toolText.text.trim()
        if (tool !== "")
            q.tool = tool
        if (kindFilter !== "")
            q.kind = kindFilter
        if (sourceFilter !== "")
            q.source = sourceFilter
        if (sessionFilter !== "")
            q.session = sessionFilter
        if (rangeSeconds > 0)
            q.since = new Date((nowSecs - rangeSeconds) * 1000).toISOString()
        return q
    }

    function search(at) {
        var page = at === undefined ? 0 : at
        var q = queryObject()
        q.limit = pageLimit
        q.offset = page
        var text = client.searchAudit(JSON.stringify(q))
        var reply = null
        try {
            reply = JSON.parse(text)
        } catch (e) {
            reply = null
        }
        if (!reply || !reply.records) {
            errorText = "The audit log could not be searched. Is the daemon running?"
            return
        }
        errorText = ""
        records = reply.records
        total = reply.total
        offset = reply.offset
        pageLimit = reply.limit ? reply.limit : 100
        expanded = -1
    }

    function clearFilters() {
        searchText.text = ""
        toolText.text = ""
        sourceFilter = ""
        kindFilter = ""
        sessionFilter = ""
        rangeSeconds = 0
        exportText = ""
    }

    function exportMatches() {
        var reply = client.exportAudit(JSON.stringify(queryObject()))
        exportText = reply.indexOf("error:") === 0 ? "The export failed: " + reply.substring(6).trim() : "Exported to " + reply
    }

    function sourceWords(r) {
        return r.source ? r.source : "daemon"
    }

    function clip(text, n) {
        return text.length > n ? text.substring(0, n - 3) + "..." : text
    }

    function summarize(r) {
        var d = r.detail || {}
        var s = ""
        if (r.kind === "message") {
            s = d.text ? d.text : ""
        } else if (r.kind === "tool") {
            var input = d.tool_input || {}
            var what = input.command || input.file_path || input.path || input.pattern || input.url || ""
            s = d.tool_name ? d.tool_name + (what !== "" ? ": " + what : "") : (d.raw ? d.raw : "tool record")
        } else if (r.kind.indexOf("approval-") === 0) {
            s = d.summary ? d.summary : (d.tool ? d.tool : "")
        } else if (r.kind === "kill-switch") {
            s = (d.engaged ? "engaged" : "released") + (d.reason ? " (" + d.reason + ")" : "")
        } else {
            s = r.kind + " " + JSON.stringify(d)
        }
        return clip(s.replace(/\s+/g, " ").trim(), 200)
    }

    // A record the log changed before saving it (secrets replaced, long text cut) says so, in words, and is never shown as
    // complete (N-219c). Records written before that, and records with nothing changed, have no note.
    function changeNote(r) {
        var ch = r.changed
        if (!ch)
            return ""
        var parts = []
        var red = ch.redacted || []
        if (red.length > 0) {
            var n = 0
            var seen = {}
            var fields = 0
            for (var i = 0; i < red.length; i++) {
                n += red[i].count
                if (!seen[red[i].field]) {
                    seen[red[i].field] = true
                    fields++
                }
            }
            parts.push(n + (n === 1 ? " secret" : " secrets") + " replaced in " + fields + (fields === 1 ? " field" : " fields"))
        }
        var cut = ch.cut || []
        if (cut.length > 0) {
            var bytes = 0
            for (var j = 0; j < cut.length; j++)
                bytes += cut[j].bytes
            parts.push(bytes + (bytes === 1 ? " byte" : " bytes") + " cut from " + cut.length + (cut.length === 1 ? " field" : " fields"))
        }
        if (parts.length === 0)
            return ""
        return "Changed before it was saved: " + parts.join(", ") + ". This is not the full record."
    }

    function detailText(r) {
        return JSON.stringify(r, null, 1)
    }

    function toggle(i) {
        expanded = expanded === i ? -1 : i
    }

    Component.onCompleted: {
        loadSessions()
        search()
    }

    Connections {
        target: root.client
        function onReconnected() { root.loadSessions(); root.search(root.offset) }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 8
        spacing: 6

        TextField {
            id: searchText
            objectName: "searchText"
            Layout.fillWidth: true
            placeholderText: "Search what was said or run"
            onAccepted: root.search()
        }
        RowLayout {
            Layout.fillWidth: true
            ComboBox {
                objectName: "sourceBox"
                Layout.fillWidth: true
                model: ["Any Source", "Daemon Sessions", "Terminal Sessions"]
                currentIndex: root.sourceFilter === "terminal" ? 2 : (root.sourceFilter === "daemon" ? 1 : 0)
                onActivated: { root.sourceFilter = currentIndex === 2 ? "terminal" : (currentIndex === 1 ? "daemon" : ""); root.search() }
            }
            ComboBox {
                objectName: "rangeBox"
                Layout.fillWidth: true
                model: ["Any Time", "Last Hour", "Last 24 Hours", "Last 7 Days"]
                onActivated: { root.rangeSeconds = [0, 3600, 86400, 604800][currentIndex]; root.search() }
            }
        }
        RowLayout {
            Layout.fillWidth: true
            ComboBox {
                objectName: "sessionBox"
                Layout.fillWidth: true
                textRole: "text"
                valueRole: "value"
                model: root.sessionChoices
                onActivated: { root.sessionFilter = root.sessionChoices[currentIndex].value; root.search() }
            }
            ComboBox {
                objectName: "kindBox"
                Layout.fillWidth: true
                model: root.kinds.map(function (k) { return k === "" ? "Any Kind" : k })
                currentIndex: Math.max(0, root.kinds.indexOf(root.kindFilter))
                onActivated: { root.kindFilter = root.kinds[currentIndex]; root.search() }
            }
            TextField {
                id: toolText
                objectName: "toolText"
                Layout.preferredWidth: 110
                placeholderText: "Tool"
                onAccepted: root.search()
            }
        }
        RowLayout {
            Layout.fillWidth: true
            Button { objectName: "searchButton"; text: "Search"; highlighted: true; onClicked: root.search() }
            Button { objectName: "clearButton"; text: "Clear"; onClicked: { root.clearFilters(); root.search() } }
            Item { Layout.fillWidth: true }
            Button { objectName: "exportButton"; text: "Export"; onClicked: root.exportMatches() }
        }

        Label {
            objectName: "auditError"
            Layout.fillWidth: true
            visible: root.errorText !== ""
            wrapMode: Text.Wrap
            color: "#e0623f"
            text: root.errorText
        }
        Label {
            objectName: "exportNote"
            Layout.fillWidth: true
            visible: root.exportText !== ""
            wrapMode: Text.Wrap
            text: root.exportText
        }
        Label {
            objectName: "emptyNote"
            Layout.fillWidth: true
            visible: root.total === 0
            opacity: 0.7
            text: "No matching records."
        }

        ListView {
            objectName: "resultList"
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: 2
            model: root.records
            delegate: Rectangle {
                id: row
                required property var modelData
                required property int index
                width: ListView.view.width
                implicitHeight: col.implicitHeight + 8
                color: root.expanded === index ? "#2b3a52" : "#1f2937"
                radius: 4
                ColumnLayout {
                    id: col
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: 4
                    Label {
                        Layout.fillWidth: true
                        color: "#f6f2e9"
                        opacity: 0.7
                        font.pixelSize: 11
                        text: Qt.formatDateTime(new Date(row.modelData.ts), "MMM d HH:mm:ss") + "  " + row.modelData.actor + "  " + row.modelData.kind + "  (" + root.sourceWords(row.modelData) + ")"
                    }
                    Label {
                        Layout.fillWidth: true
                        color: "#f6f2e9"
                        wrapMode: Text.Wrap
                        maximumLineCount: root.expanded === row.index ? 1000 : 2
                        elide: Text.ElideRight
                        text: root.expanded === row.index ? root.detailText(row.modelData) : root.summarize(row.modelData)
                    }
                    Label {
                        objectName: "changeNote"
                        Layout.fillWidth: true
                        visible: text !== ""
                        color: "#d9a441"
                        font.pixelSize: 11
                        wrapMode: Text.Wrap
                        text: root.changeNote(row.modelData)
                    }
                }
                TapHandler { onTapped: root.toggle(row.index) }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Button {
                objectName: "newerButton"
                text: "Newer"
                enabled: root.offset > 0
                onClicked: root.search(Math.max(0, root.offset - root.pageLimit))
            }
            Label {
                objectName: "countNote"
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                text: root.total === 0 ? "0 matches"
                    : "Showing " + (root.offset + 1) + "-" + (root.offset + root.records.length) + " of " + root.total
            }
            Button {
                objectName: "olderButton"
                text: "Older"
                enabled: root.offset + root.records.length < root.total
                onClicked: root.search(root.offset + root.pageLimit)
            }
        }
    }
}
