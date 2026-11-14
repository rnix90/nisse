// SPDX-License-Identifier: GPL-2.0-or-later
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The kill switch (N-215): one red button that stops all AI activity, and a banner while it is on. The state lives in the
// daemon (any paired device can use it); this only shows it and sends the click as the desktop.
ColumnLayout {
    id: root
    property var client
    property string errorText: ""

    readonly property var status: parseStatus(client ? client.killSwitchJson : "")
    readonly property bool engaged: status.engaged === true

    spacing: 0

    function parseStatus(text) {
        if (!text)
            return {}
        try {
            var v = JSON.parse(text)
            return (v && typeof v === "object") ? v : {}
        } catch (e) {
            return {}
        }
    }

    function bannerText(s) {
        var by = s.by ? s.by : "someone"
        var why = s.reason ? " (" + s.reason + ")" : ""
        return "AI activity is paused: stopped by " + by + why + ". Nothing was rolled back. Resume when you are ready."
    }

    function stop() {
        errorText = client.engageKillSwitch("")
    }

    function resume() {
        errorText = client.releaseKillSwitch()
    }

    RowLayout {
        Layout.fillWidth: true
        Layout.margins: 4
        visible: !root.engaged
        Item { Layout.fillWidth: true }
        Button {
            objectName: "killButton"
            text: "Stop all AI"
            visible: !root.engaged
            palette.button: "#e0623f"
            palette.buttonText: "#f6f2e9"
            onClicked: root.stop()
        }
    }

    Rectangle {
        objectName: "killBanner"
        Layout.fillWidth: true
        visible: root.engaged
        implicitHeight: bannerRow.implicitHeight + 16
        color: "#8c2f1b"

        RowLayout {
            id: bannerRow
            anchors.fill: parent
            anchors.margins: 8
            Label {
                objectName: "killText"
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                color: "#f6f2e9"
                text: root.bannerText(root.status)
            }
            Button {
                objectName: "killResume"
                text: "Resume"
                onClicked: root.resume()
            }
        }
    }

    Label {
        objectName: "killError"
        Layout.fillWidth: true
        Layout.margins: 4
        visible: root.errorText !== ""
        wrapMode: Text.Wrap
        color: "#e0623f"
        text: root.errorText
    }
}
