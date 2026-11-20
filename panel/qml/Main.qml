// SPDX-License-Identifier: GPL-2.0-or-later
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ApplicationWindow {
    id: window
    width: sidebarDocked ? 420 : 480
    height: 720
    visible: false // main.cpp shows it: docked on the screen edge as the sidebar (N-415a), or as a normal window where that is not possible
    title: "nisse"

    // 0 chat, 1 approvals, 2 audit log, 3 settings
    property int page: startPage

    Connections {
        target: daemon
        function onShowApprovalsRequested() {
            window.page = 1
            if (sidebarDocked) {
                sidebar.show()
            } else {
                window.show()
                window.raise()
                window.requestActivate()
            }
        }
    }

    // what the tray item shows besides the daemon's own state (N-415b)
    Binding { target: trayCounts; property: "working"; value: tabs.workingCount }
    Binding { target: trayCounts; property: "unread"; value: tabs.unreadCount }

    // the sidebar takes the keyboard when it is opened on purpose (tray, shortcut, a notice); the pointer at the edge does not
    // Asked for at once it is ignored while the surface is still sliding in from off screen (live check 2026-11-19: the window never
    // became active, so Escape and typing did nothing), so it waits for the slide to end, then focuses the chat input.
    Timer {
        id: focusLater
        interval: 320
        onTriggered: {
            window.requestActivate()
            var input = window.findInput(window.contentItem)
            if (input && window.page === 0)
                input.forceActiveFocus()
            else
                window.contentItem.forceActiveFocus()
        }
    }
    function findInput(item) {
        if (!item)
            return null
        if (item.objectName === "input")
            return item
        for (var i = 0; i < item.children.length; ++i) {
            var found = findInput(item.children[i])
            if (found)
                return found
        }
        return null
    }
    onActiveChanged: console.info("nisse panel window active=" + active)
    Connections {
        target: sidebar
        function onActivateRequested() {
            focusLater.restart()
        }
    }

    // Escape closes the sidebar; it stays open until closed otherwise (Bert, 2026-11-19). The window shortcut covers "nothing has the
    // keyboard"; the Keys handlers on the header, the pages and the footer cover a focused item (live check 2026-11-19: with the chat
    // field focused the window shortcut alone never fired; tests/tst_escape.qml)
    function closeSidebar() {
        console.info("nisse sidebar: Escape handled, docked=" + sidebarDocked)
        if (sidebarDocked)
            sidebar.escapePressed()
    }
    Shortcut {
        sequence: "Escape"
        enabled: sidebarDocked
        onActivated: window.closeSidebar()
    }

    header: ColumnLayout {
        spacing: 0
        Keys.onEscapePressed: window.closeSidebar()
        ConnectionBanner {
            Layout.fillWidth: true
            client: daemon
        }
        StatusBar {
            Layout.fillWidth: true
            client: daemon
        }
        KillSwitchBar {
            Layout.fillWidth: true
            client: daemon
        }
    }

    StackLayout {
        anchors.fill: parent
        currentIndex: window.page
        Keys.onEscapePressed: window.closeSidebar()

        SessionTabs {
            id: tabs
            client: daemon
        }
        ApprovalsView {
            client: daemon
        }
        AuditView {
            client: daemon
        }
        ConfigView {
            client: daemon
        }
    }

    footer: ToolBar {
        Keys.onEscapePressed: window.closeSidebar()
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
                objectName: "settingsTab"
                text: "Settings"
                checked: window.page === 3
                onClicked: window.page = 3
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
