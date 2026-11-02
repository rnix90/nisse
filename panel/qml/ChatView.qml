// SPDX-License-Identifier: GPL-2.0-or-later
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: root

    // The object that talks to the daemon (DaemonClient in the app, a stub in tests).
    property var client
    property string session: ""
    property bool busy: false
    property int replyIndex: -1
    // True from a click on Stop until the daemon's done signal arrives.
    property bool stopRequested: false
    // Set when the daemon reported an unknown session: the id is dropped when that turn's Done arrives.
    property bool forgetSessionOnDone: false
    property alias messages: model

    ListModel { id: model }

    function reset() {
        model.clear()
        session = ""
        busy = false
        replyIndex = -1
        stopRequested = false
        forgetSessionOnDone = false
    }

    function submit(text) {
        if (text === "" || busy)
            return
        if (session === "") {
            session = client.newSession()
            if (session === "") {
                model.append({ role: "user", text: text })
                model.append({ role: "error", text: "The Nisse daemon is not reachable. Try again in a moment." })
                return
            }
        }
        model.append({ role: "user", text: text })
        replyIndex = -1
        stopRequested = false
        busy = true
        client.send(session, text)
    }

    Connections {
        target: root.client

        function onChunk(sid, text) {
            if (sid !== root.session)
                return
            if (root.replyIndex < 0) {
                model.append({ role: "assistant", text: text })
                root.replyIndex = model.count - 1
            } else {
                model.setProperty(root.replyIndex, "text", model.get(root.replyIndex).text + text)
            }
        }

        function onFailed(sid, message) {
            if (sid !== root.session)
                return
            model.append({ role: "error", text: message })
            root.replyIndex = -1
            // The daemon no longer knows this session (restarted with a lost or unreadable state file): forget it once
            // its Done has arrived, so the next message starts a new one instead of failing the same way again.
            if (message.indexOf("unknown session") === 0)
                root.forgetSessionOnDone = true
        }

        function onDone(sid) {
            if (sid !== root.session)
                return
            root.busy = false
            root.replyIndex = -1
            if (root.forgetSessionOnDone) {
                root.session = ""
                root.forgetSessionOnDone = false
            }
            if (root.stopRequested) {
                model.append({ role: "note", text: "Stopped." })
                root.stopRequested = false
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 8
        spacing: 8

        ListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: 6
            model: model
            onCountChanged: positionViewAtEnd()

            delegate: Rectangle {
                id: bubble
                required property string role
                required property string text
                width: list.width
                implicitHeight: label.implicitHeight + 16
                radius: 8
                color: role === "user" ? "#2b3a52" : (role === "error" ? "#5c2a2a" : (role === "note" ? "#2a2f3a" : "#1f2937"))

                Label {
                    id: label
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.margins: 8
                    anchors.verticalCenter: parent.verticalCenter
                    text: bubble.text
                    wrapMode: Text.Wrap
                    color: "#f6f2e9"
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            TextField {
                id: field
                objectName: "input"
                Layout.fillWidth: true
                enabled: !root.busy
                placeholderText: "Ask Nisse..."
                onAccepted: {
                    root.submit(text)
                    text = ""
                }
            }

            Button {
                objectName: "stop"
                text: "Stop"
                visible: root.busy
                onClicked: {
                    root.stopRequested = true
                    root.client.cancel(root.session)
                }
            }
        }
    }
}
