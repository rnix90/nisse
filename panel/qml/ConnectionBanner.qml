// SPDX-License-Identifier: GPL-2.0-or-later
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// What is missing (N-218): the daemon (not there yet, or restarting) and Claude Code itself (the first-boot download is
// waiting for the network). Plain sentences, never a frozen window.
ColumnLayout {
    id: root
    property var client

    readonly property bool daemonAway: client !== null && client !== undefined
        && client.connectionState !== undefined && client.connectionState !== "connected"
    readonly property string setupWords: client && client.setupText ? client.setupText : ""

    spacing: 0

    Rectangle {
        objectName: "connectionBanner"
        Layout.fillWidth: true
        visible: root.daemonAway
        implicitHeight: connectionLabel.implicitHeight + 12
        color: "#8c6a1b"
        Label {
            id: connectionLabel
            objectName: "connectionText"
            anchors.fill: parent
            anchors.margins: 6
            wrapMode: Text.Wrap
            color: "#f6f2e9"
            text: root.client && root.client.connectionText ? root.client.connectionText : ""
        }
    }

    Rectangle {
        objectName: "setupBanner"
        Layout.fillWidth: true
        visible: root.setupWords !== ""
        implicitHeight: setupLabel.implicitHeight + 12
        color: "#2f4f6f"
        Label {
            id: setupLabel
            objectName: "setupText"
            anchors.fill: parent
            anchors.margins: 6
            wrapMode: Text.Wrap
            color: "#f6f2e9"
            text: root.setupWords
        }
    }
}
