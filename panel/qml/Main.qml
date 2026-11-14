// SPDX-License-Identifier: GPL-2.0-or-later
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ApplicationWindow {
    id: window
    width: 480
    height: 720
    visible: true
    title: "nisse"

    // 0 chat, 1 approvals, 2 audit log
    property int page: 0

    Connections {
        target: daemon
        function onShowApprovalsRequested() {
            window.page = 1
            window.show()
            window.raise()
            window.requestActivate()
        }
    }

    header: StatusBar {
        client: daemon
    }

    StackLayout {
        anchors.fill: parent
        currentIndex: window.page

        ChatView {
            client: daemon
        }
        ApprovalsView {
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
                objectName: "chatTab"
                text: "Chat"
                checked: window.page === 0
                onClicked: window.page = 0
            }
            Button {
                objectName: "approvalsTab"
                text: daemon.pendingCount > 0 ? "Approvals (" + daemon.pendingCount + ")" : "Approvals"
                checked: window.page === 1
                onClicked: window.page = 1
            }
            Button {
                objectName: "auditTab"
                text: "Audit log"
                checked: window.page === 2
                onClicked: window.page = 2
            }
        }
    }
}
