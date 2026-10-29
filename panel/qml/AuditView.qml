// SPDX-License-Identifier: GPL-2.0-or-later
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: root
    property var client
    property var entries: []

    function refresh() {
        var lines = client.auditTail(100)
        var out = []
        for (var i = 0; i < lines.length; ++i) {
            try {
                out.push(JSON.parse(lines[i]))
            } catch (e) {
                // a damaged line is skipped, as in the daemon
            }
        }
        entries = out
    }

    Component.onCompleted: refresh()

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 8
        spacing: 8

        Button {
            text: "Refresh"
            onClicked: root.refresh()
        }

        ListView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: root.entries
            delegate: Label {
                required property var modelData
                width: ListView.view.width
                elide: Text.ElideRight
                text: modelData.ts + "  " + modelData.actor + "  " + modelData.kind
            }
        }
    }
}
