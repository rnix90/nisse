// SPDX-License-Identifier: GPL-2.0-or-later
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The per-machine remote access switch (N-209). On, the daemon runs `claude remote-control` so claude.ai and the phone
// app can start sessions on this computer. The daemon owns the state; this view shows it and sends the switch.
ColumnLayout {
    id: root
    property var client
    property bool enabled: false
    property bool running: false
    property int restarts: 0
    property string reason: ""
    property string errorText: ""

    spacing: 4

    function refresh() {
        var s = {}
        try {
            s = JSON.parse(client.remoteAccess())
        } catch (e) {
            s = {}
        }
        apply(s)
    }

    function apply(s) {
        enabled = s.enabled === true
        running = s.running === true
        restarts = s.restarts | 0
        reason = s.error ? s.error : ""
        sw.checked = enabled
    }

    function toggle(on) {
        errorText = client.setRemoteAccess(on)
        refresh()
    }

    function statusText() {
        if (!enabled)
            return "Remote access is off."
        if (running)
            return "Remote access is on. Start a session from claude.ai/code or the phone app."
        if (reason !== "")
            return "Remote access is on, but the server is not running: " + reason + ". Trying again."
        return "Remote access is on; starting."
    }

    Component.onCompleted: refresh()

    Connections {
        target: root.client
        function onRemoteAccessChanged(json) {
            try {
                root.apply(JSON.parse(json))
            } catch (e) {
                root.refresh()
            }
        }
    }

    RowLayout {
        Layout.fillWidth: true
        Switch {
            id: sw
            objectName: "remoteSwitch"
            text: "Remote access"
            onClicked: root.toggle(checked)
        }
        Label {
            objectName: "remoteStatus"
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            text: root.statusText()
        }
    }

    Label {
        objectName: "remoteError"
        Layout.fillWidth: true
        visible: root.errorText !== ""
        wrapMode: Text.Wrap
        color: "#e0623f"
        text: root.errorText
    }

    Label {
        objectName: "remoteNote"
        Layout.fillWidth: true
        wrapMode: Text.Wrap
        opacity: 0.7
        text: "Sessions started from the phone or claude.ai are Claude's own: they do not appear as tabs here, and "
            + "their approvals are not in the approvals list. In supervised mode they ask on the phone. Whether the guardrail "
            + "covers them has not been confirmed yet."
    }
}
