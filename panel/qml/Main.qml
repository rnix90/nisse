// SPDX-License-Identifier: GPL-2.0-or-later
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ApplicationWindow {
    id: window
    width: 480
    height: 720
    visible: true
    title: "Nisse"

    property bool showAudit: false

    header: StatusBar {
        client: daemon
    }

    StackLayout {
        anchors.fill: parent
        currentIndex: window.showAudit ? 1 : 0

        ChatView {
            client: daemon
        }
        AuditView {
            client: daemon
        }
    }

    footer: ToolBar {
        RowLayout {
            anchors.fill: parent
            Button {
                text: window.showAudit ? "Chat" : "Audit log"
                onClicked: window.showAudit = !window.showAudit
            }
        }
    }
}
