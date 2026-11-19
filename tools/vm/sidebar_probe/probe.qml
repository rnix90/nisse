// SPDX-License-Identifier: GPL-2.0-or-later
// The N-415a spike scene: a dark sidebar with a text field (typing test) and a status line. The driver sends the commands
// through files in /tmp so it can step the scenario: it writes the command name into /tmp/sidebar.cmd and this reads it.
import QtQuick
import QtQuick.Controls
import QtQuick.Window

QtObject {
  property Window edgeStrip: Window {
    id: strip
    width: 2
    height: 600
    visible: false
    color: "#02000000"
    flags: Qt.FramelessWindowHint
    Component.onCompleted: { probe.strip(strip, 2); strip.visible = true }
    HoverHandler { onHoveredChanged: probe.log("edge strip hover=" + hovered) }
    TapHandler { onTapped: probe.log("edge strip tapped") }
  }

  property Window sidebar: Window {
    id: win
    width: 420
    height: 600
    visible: false
    color: "#1b2330"
    title: "nisse sidebar probe"

    property string lastCmd: ""

    Component.onCompleted: {
        probe.dock(win, 420, "right")
        win.visible = true
        probe.log("shown; title=" + win.title)
    }
    onActiveChanged: probe.log("window active=" + active)
    onVisibleChanged: probe.log("visible=" + visible)

    Column {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 12
        Label { text: "nisse sidebar probe"; color: "#f6f2e9"; font.pixelSize: 22 }
        Label { id: status; text: "typing test: click here and type"; color: "#e8743b"; font.pixelSize: 16 }
        TextField {
            id: field
            width: parent.width
            placeholderText: "type here"
            onTextChanged: probe.log("typed=" + text)
            onActiveFocusChanged: probe.log("field focus=" + activeFocus)
        }
        Rectangle { width: parent.width; height: 6; color: "#e8743b" }
    }

    // read a command from /tmp/sidebar.cmd twice a second
    Timer {
        interval: 400; running: true; repeat: true
        onTriggered: {
            var xhr = new XMLHttpRequest()
            xhr.open("GET", "file:///tmp/sidebar.cmd", false)
            try { xhr.send() } catch (e) { return }
            var cmd = (xhr.responseText || "").trim()
            if (cmd === "" || cmd === win.lastCmd) return
            win.lastCmd = cmd
            probe.log("cmd=" + cmd)
            if (cmd === "hide") probe.slide(win, 0, -420, 450)
            else if (cmd === "show") probe.slide(win, -420, 0, 450)
            else if (cmd === "reserve") probe.reserve(win, 420)
            else if (cmd === "unreserve") probe.reserve(win, 0)
            else if (cmd === "focus") { win.requestActivate(); field.forceActiveFocus() }
        }
    }
}
}
