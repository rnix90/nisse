// SPDX-License-Identifier: GPL-2.0-or-later
import QtQuick
import QtQuick.Controls

Rectangle {
    id: root
    property var client
    implicitHeight: 32
    color: "#1b2330"

    Label {
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        anchors.leftMargin: 10
        color: "#f6f2e9"
        text: "Backend: " + (root.client ? root.client.backendLabel : "unknown")
    }
}
