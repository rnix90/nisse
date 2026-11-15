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

    // ---- events (N-220): the daemon numbers what happens in a session, so a transcript can be rebuilt and a gap closed

    function applyEvent(ev) {
        if (ev.type === "user_message") {
            model.append({ role: "user", text: ev.text })
            replyIndex = -1
        } else if (ev.type === "chunk") {
            if (replyIndex < 0) {
                model.append({ role: "assistant", text: ev.text })
                replyIndex = model.count - 1
            } else {
                model.setProperty(replyIndex, "text", model.get(replyIndex).text + ev.text)
            }
        } else if (ev.type === "error") {
            model.append({ role: "error", text: ev.message })
            replyIndex = -1
        } else if (ev.type === "done") {
            replyIndex = -1
        }
    }

    function readPage(after) {
        try {
            var page = JSON.parse(client.eventsSince(session, after))
            return page && page.events ? page : null
        } catch (e) {
            return null
        }
    }

    // A session that was already there when the panel started: show what the daemon kept of it.
    function replay() {
        if (session === "" || !client || !client.eventsSince)
            return
        var page = readPage(0)
        if (page === null) {
            model.append({ role: "note", text: "Earlier messages could not be loaded." })
            return
        }
        if (page.events.length === 0) {
            model.append({ role: "note", text: "Earlier messages are not available." })
            return
        }
        if (page.gap)
            model.append({ role: "note", text: "Older messages are no longer kept." })
        for (var i = 0; i < page.events.length; ++i)
            applyEvent(page.events[i])
        replyIndex = -1
        client.markSeen(session, page.last_seq)
    }

    // The daemon was away and is back: add what happened meanwhile (each event once), and stop waiting for a reply that was
    // cut off by a restart (`running` is what the daemon says about the session now).
    function catchUp(running) {
        if (session === "" || !client || !client.eventsSince)
            return
        var page = readPage(client.lastSeq(session))
        if (page !== null) {
            for (var i = 0; i < page.events.length; ++i)
                applyEvent(page.events[i])
            client.markSeen(session, page.last_seq)
        }
        if (busy && !running) {
            busy = false
            replyIndex = -1
            stopRequested = false
            model.append({ role: "note", text: "The daemon restarted while this was running, so the reply was cut off." })
        }
    }

    function submit(text) {
        if (text === "" || busy)
            return
        if (session === "") {
            session = client.newSession()
            if (session === "") {
                model.append({ role: "user", text: text })
                model.append({ role: "error", text: "The nisse daemon is not reachable. Try again in a moment." })
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

        function onUserMessage(sid, text) {
            if (sid !== root.session)
                return
            model.append({ role: "user", text: text })
            root.replyIndex = -1
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
                placeholderText: "Ask nisse..."
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
