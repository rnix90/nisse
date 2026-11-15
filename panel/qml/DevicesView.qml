// SPDX-License-Identifier: GPL-2.0-or-later
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Paired devices (N-221): pair a phone with a one-time code shown here, see which devices are paired and what they may do,
// and revoke one. The daemon checks every call a device makes; this only starts a pairing and shows the list.
ColumnLayout {
    id: root
    property var client
    // The clock in unix seconds; a property so tests can set it.
    property real nowSecs: Math.floor(Date.now() / 1000)

    property var devices: []
    property var pairing: null          // { code, expires_at, name, role } while a code is waiting
    property string errorText: ""
    property string pairedText: ""

    spacing: 6

    function reset() {
        devices = []
        pairing = null
        errorText = ""
        pairedText = ""
    }

    function refresh() {
        var lines = client && client.devices ? client.devices() : []
        var out = []
        for (var i = 0; i < lines.length; ++i) {
            try {
                out.push(JSON.parse(lines[i]))
            } catch (e) {
                // a damaged entry is skipped
            }
        }
        var before = devices.length
        devices = out
        // the device that was being paired has completed it: the code is used up
        if (pairing !== null) {
            for (var j = 0; j < out.length; ++j) {
                if (out[j].name === pairing.name && out[j].created_at >= pairing.expires_at - 300 - 5) {
                    pairedText = "Paired " + out[j].name + "."
                    pairing = null
                    break
                }
            }
        }
    }

    function groupedCode(code) {
        return code.length === 8 ? code.substring(0, 4) + " " + code.substring(4) : code
    }

    function pair(name, approverOnly) {
        errorText = ""
        pairedText = ""
        var label = name.trim()
        if (label === "") {
            errorText = "Give the device a name first."
            return
        }
        var reply = client.startPairing(label, approverOnly)
        if (reply.indexOf("error:") === 0) {
            errorText = reply.substring(6).trim()
            return
        }
        try {
            pairing = JSON.parse(reply)
        } catch (e) {
            errorText = "The daemon did not answer the pairing request."
        }
    }

    function cancel() {
        client.cancelPairing()
        pairing = null
    }

    // Looked at every few seconds: takes down a code that has run out.
    function tick() {
        if (pairing !== null && nowSecs >= pairing.expires_at) {
            pairing = null
            errorText = "The pairing code expired. Start a new pairing."
        }
    }

    function canRevoke(d) {
        return !d.revoked_at
    }

    function revoke(id) {
        errorText = client.revokeDevice(id)
        refresh()
    }

    function dateWords(secs) {
        return Qt.formatDateTime(new Date(secs * 1000), "MMM d, HH:mm")
    }

    function describe(d) {
        var access = d.role === "approver" ? "approving only" : "full access"
        var seen = d.last_seen ? "last used " + dateWords(d.last_seen) : "never used"
        var state = d.revoked_at ? ", revoked " + dateWords(d.revoked_at) : ""
        return d.name + ": " + access + ", paired " + dateWords(d.created_at) + ", " + seen + state
    }

    function minutesLeft() {
        if (pairing === null)
            return ""
        var left = Math.max(0, pairing.expires_at - nowSecs)
        return left >= 60 ? Math.ceil(left / 60) + " min" : left + " s"
    }

    Component.onCompleted: refresh()

    Connections {
        target: root.client
        function onDevicesChanged() { root.refresh() }
        function onReconnected() { root.refresh() }
    }

    Timer {
        interval: 2000
        running: root.visible && root.pairing !== null
        repeat: true
        onTriggered: { root.nowSecs = Math.floor(Date.now() / 1000); root.tick() }
    }

    Label {
        objectName: "devicesNote"
        Layout.fillWidth: true
        wrapMode: Text.Wrap
        opacity: 0.8
        text: "A paired device (your phone) gets full access: it can do what this panel does, except pair or revoke devices. "
            + "Each device has its own key and the daemon checks every call it makes. If one is lost, revoke it here."
    }

    Label {
        objectName: "noDevices"
        visible: root.devices.length === 0
        opacity: 0.7
        text: "No device is paired."
    }

    Repeater {
        objectName: "deviceList"
        model: root.devices
        delegate: RowLayout {
            required property var modelData
            Layout.fillWidth: true
            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                text: root.describe(modelData)
            }
            Button {
                text: "Revoke"
                visible: root.canRevoke(modelData)
                onClicked: root.revoke(modelData.id)
            }
        }
    }

    RowLayout {
        Layout.fillWidth: true
        visible: root.pairing === null
        TextField {
            id: nameField
            objectName: "deviceName"
            Layout.fillWidth: true
            placeholderText: "Device name, for example Bert's phone"
        }
        CheckBox {
            id: approverOnly
            objectName: "approverOnly"
            text: "Approving only"
        }
        Button {
            objectName: "pairButton"
            text: "Pair a device"
            onClicked: root.pair(nameField.text, approverOnly.checked)
        }
    }

    ColumnLayout {
        objectName: "pairingBox"
        Layout.fillWidth: true
        visible: root.pairing !== null
        Label {
            objectName: "pairingCode"
            font.pixelSize: 28
            font.bold: true
            text: root.pairing ? root.groupedCode(root.pairing.code) : ""
        }
        Label {
            objectName: "pairingNote"
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            text: root.pairing ? "Enter this code on " + root.pairing.name + " within " + root.minutesLeft()
                + ". It works once; five wrong tries cancel it." : ""
        }
        Button {
            objectName: "cancelPairing"
            text: "Cancel pairing"
            onClicked: root.cancel()
        }
    }

    Label {
        objectName: "pairedNote"
        visible: root.pairedText !== ""
        text: root.pairedText
    }

    Label {
        objectName: "devicesError"
        Layout.fillWidth: true
        visible: root.errorText !== ""
        wrapMode: Text.Wrap
        color: "#e0623f"
        text: root.errorText
    }
}
