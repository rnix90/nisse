// SPDX-License-Identifier: GPL-2.0-or-later
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The approvals queue (N-205): what is waiting for a person, the detail of one, approve and deny, and a short history.
// All state lives in the daemon; this view lists it and sends the decision as the "desktop" device.
Item {
    id: root
    property var client
    // The clock in unix seconds; a property so tests can set it. Updated while the view is open.
    property real nowSecs: Math.floor(Date.now() / 1000)

    property var pendingItems: []
    property var historyItems: []
    property var historyIds: []
    property int pendingTotal: 0
    property string selectedId: ""
    property var selected: null
    property string errorText: ""

    readonly property int historyLimit: 20

    function reset() {
        selectedId = ""
        selected = null
        pendingItems = []
        historyItems = []
        historyIds = []
        pendingTotal = 0
        errorText = ""
    }

    function parseAll() {
        var lines = client ? client.approvals("") : []
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

    function refresh() {
        errorText = ""
        var all = parseAll()
        var pend = []
        var hist = []
        var found = null
        for (var i = 0; i < all.length; ++i) {
            var a = all[i]
            if (a.state === "pending")
                pend.push(a)
            else
                hist.push(a)
            if (a.id === selectedId)
                found = a
        }
        hist.sort(function (x, y) { return (y.decided_at || y.asked_at || 0) - (x.decided_at || x.asked_at || 0) })
        hist = hist.slice(0, historyLimit)
        pendingItems = pend
        historyItems = hist
        var ids = []
        for (var j = 0; j < hist.length; ++j)
            ids.push(hist[j].id)
        historyIds = ids
        pendingTotal = pend.length
        if (found === null)
            selectedId = ""
        selected = found
    }

    function select(id) {
        selectedId = id
        errorText = ""
        refresh()
    }

    // "expires in 12 min", for the time left at `now`.
    function expiresIn(now, expiresAt) {
        var left = Math.floor(expiresAt - now)
        if (left <= 0)
            return "expired"
        if (left < 60)
            return "expires in " + left + " s"
        var minutes = Math.floor(left / 60)
        if (minutes < 60)
            return "expires in " + minutes + " min"
        var h = Math.floor(minutes / 60)
        var m = minutes % 60
        return "expires in " + h + " h" + (m > 0 ? " " + m + " min" : "")
    }

    function describe(a) {
        if (!a)
            return ""
        var lines = []
        lines.push("Asked by: " + a.asked_by)
        lines.push("Tool: " + a.tool)
        if (a.session)
            lines.push("Session: " + a.session)
        var d = a.detail || {}
        if (d.category)
            lines.push("Category: " + d.category)
        if (d.reason)
            lines.push("Why: " + d.reason)
        if (d.command) {
            lines.push("Command: " + d.command)
        } else if (Object.keys(d).length > 0) {
            var text = JSON.stringify(d)
            lines.push("Details: " + (text.length > 600 ? text.substring(0, 597) + "..." : text))
        }
        if (a.state === "pending")
            lines.push("Waiting: " + expiresIn(nowSecs, a.expires_at))
        else if (a.state === "approved")
            lines.push("Approved by " + (a.decided_by || "someone"))
        else if (a.state === "denied")
            lines.push("Denied by " + (a.decided_by || "someone") + (a.reason ? ": " + a.reason : ""))
        else
            lines.push("This request expired.")
        return lines.join("\n")
    }

    function decide(approve) {
        if (!selected || selected.state !== "pending")
            return
        var err = approve ? client.approve(selected.id) : client.deny(selected.id, reasonField.text)
        reasonField.text = ""
        refresh()
        errorText = err
    }

    Component.onCompleted: refresh()

    Connections {
        target: root.client
        function onApprovalChanged() { root.refresh() }
    }

    Timer {
        interval: 15000
        running: root.visible
        repeat: true
        onTriggered: root.nowSecs = Math.floor(Date.now() / 1000)
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 8
        spacing: 8

        Label {
            text: "Waiting for you"
            font.bold: true
        }

        Label {
            objectName: "empty"
            visible: root.pendingTotal === 0
            text: "Nothing waiting for you."
            opacity: 0.7
        }

        ListView {
            objectName: "pendingList"
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(contentHeight, 160)
            clip: true
            visible: root.pendingTotal > 0
            model: root.pendingItems
            delegate: ItemDelegate {
                required property var modelData
                width: ListView.view.width
                highlighted: modelData.id === root.selectedId
                text: modelData.summary + "  (" + root.expiresIn(root.nowSecs, modelData.expires_at) + ")"
                onClicked: root.select(modelData.id)
            }
        }

        Frame {
            Layout.fillWidth: true
            visible: root.selected !== null
            ColumnLayout {
                anchors.fill: parent
                spacing: 6
                Label {
                    objectName: "detail"
                    Layout.fillWidth: true
                    visible: root.selected !== null
                    wrapMode: Text.Wrap
                    text: root.describe(root.selected)
                }
                TextField {
                    id: reasonField
                    objectName: "reason"
                    Layout.fillWidth: true
                    placeholderText: "Reason (optional, sent with a denial)"
                    visible: root.selected !== null && root.selected.state === "pending"
                }
                RowLayout {
                    Button {
                        objectName: "approve"
                        text: "Approve"
                        enabled: root.selected !== null && root.selected.state === "pending"
                        onClicked: root.decide(true)
                    }
                    Button {
                        objectName: "deny"
                        text: "Deny"
                        enabled: root.selected !== null && root.selected.state === "pending"
                        onClicked: root.decide(false)
                    }
                }
            }
        }

        Label {
            objectName: "error"
            Layout.fillWidth: true
            visible: root.errorText !== ""
            wrapMode: Text.Wrap
            color: "#e0623f"
            text: root.errorText
        }

        Label {
            text: "Recent"
            font.bold: true
            visible: root.historyItems.length > 0
        }

        ListView {
            objectName: "historyList"
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: root.historyItems
            delegate: ItemDelegate {
                required property var modelData
                width: ListView.view.width
                highlighted: modelData.id === root.selectedId
                text: modelData.state + " by " + (modelData.decided_by || "?") + ": " + modelData.summary
                onClicked: root.select(modelData.id)
            }
        }
    }
}
