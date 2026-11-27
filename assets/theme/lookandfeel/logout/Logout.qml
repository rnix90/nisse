/*
    SPDX-FileCopyrightText: 2014 Aleix Pol Gonzalez <aleixpol@blue-systems.com>
    SPDX-FileCopyrightText: 2026 the nisse authors

    SPDX-License-Identifier: GPL-2.0-or-later

    nisse's logout screen (ledger N-504), a restyled copy of Breeze's (plasma-workspace, lookandfeel/org.kde.breeze/contents/logout):
    the same host contract (the signals and the context properties sdtype, maysd, canLogout, spdMethods, softwareUpdatePending, the
    reboot notes), so every Breeze behavior stays. What nisse changes is the look, to the approved mock (assets/art/boot/logout-*.png):
    a veil in the look's own background color (Ink in the dark look, Paper in the light one), the question "What would you like to do?"
    over the round buttons, the default button in Ember, the countdown line under the buttons, and Cancel as a plain Ember word.
    The words are plain English that end with punctuation (Bert's rule): they do not go through Plasma's translation catalog.
*/

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2

import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami

import "timer.js" as AutoTriggerTimer

import org.kde.plasma.private.sessions

Item {
    id: root
    Kirigami.Theme.inherit: false
    Kirigami.Theme.colorSet: Kirigami.Theme.Window
    height: screenGeometry.height
    width: screenGeometry.width

    signal logoutRequested()
    signal haltRequested()
    signal haltUpdateRequested()
    signal suspendRequested(int spdMethod)
    signal rebootRequested()
    signal rebootRequested2(int opt)
    signal rebootUpdateRequested()
    signal cancelRequested()
    signal lockScreenRequested()
    signal cancelSoftwareUpdateRequested()

    function sleepRequested() {
        root.suspendRequested(2);
    }

    function hibernateRequested() {
        root.suspendRequested(4);
    }

    property real timeout: 30
    property real remainingTime: root.timeout

    property var currentAction: {
        switch (sdtype) {
        case ShutdownType.ShutdownTypeReboot:
            return () => softwareUpdatePending ? rebootUpdateRequested() : rebootRequested();
        case ShutdownType.ShutdownTypeHalt:
            return () => softwareUpdatePending ? haltUpdateRequested() : haltRequested();
        default:
            return () => logoutRequested();
        }
    }

    readonly property bool showAllOptions: sdtype === ShutdownType.ShutdownTypeDefault

    // "in 1 second." or "in 30 seconds."
    function inSeconds(n) {
        return "in " + n + (n === 1 ? " second." : " seconds.");
    }

    // For showing an "other users are logged in" hint
    SessionsModel {
        id: otherSessionsModel

        // In case the default values ever change
        includeUnusedSessions: false
        includeOwnSession: false
    }

    QQC2.Action {
        onTriggered: root.cancelRequested()
        shortcut: "Escape"
    }

    onRemainingTimeChanged: {
        if (remainingTime <= 0) {
            (currentAction)();
        }
    }

    Timer {
        id: countDownTimer
        running: !showAllOptions
        repeat: true
        interval: 1000
        onTriggered: remainingTime--
        Component.onCompleted: {
            AutoTriggerTimer.addCancelAutoTriggerCallback(function() {
                countDownTimer.running = false;
            });
        }
    }

    // the veil: the look's own background color, so the dark look gets Ink and the light look Paper (the approved mock: 82%)
    Rectangle {
        id: backgroundRect
        anchors.fill: parent
        color: Kirigami.Theme.backgroundColor
        opacity: 0.82
    }
    MouseArea {
        anchors.fill: parent
        onClicked: root.cancelRequested()
    }

    ColumnLayout {
        id: column

        anchors.centerIn: parent
        spacing: Kirigami.Units.largeSpacing
        width: Math.max(implicitWidth, Kirigami.Units.gridUnit * 16)

        PlasmaComponents.Label {
            Layout.alignment: Qt.AlignHCenter
            Layout.bottomMargin: Kirigami.Units.gridUnit * 2
            font.pointSize: Kirigami.Theme.defaultFont.pointSize + 10
            font.bold: true
            text: "What would you like to do?"
            textFormat: Text.PlainText
            visible: root.showAllOptions
        }

        GridLayout {
            id: logoutButtonsRow

            readonly property int spacing: Kirigami.Units.largeSpacing * 2
            rowSpacing: spacing
            columnSpacing: spacing

            Layout.alignment: Qt.AlignHCenter

            readonly property int buttonCount: visibleChildren.length
            readonly property int singleRowWidth: (children[0].implicitWidth * buttonCount) + (spacing * (buttonCount - 1))
            columns: singleRowWidth < root.width ? buttonCount : Math.ceil(buttonCount / 2)

            LogoutButton {
                id: suspendButton
                icon.name: "system-suspend"
                text: root.showAllOptions ? "Slee&p" : "Slee&p Now"
                onClicked: root.sleepRequested()
                KeyNavigation.left: cancelButton
                KeyNavigation.right: hibernateButton.visible ? hibernateButton : (rebootButton.visible ? rebootButton : (shutdownButton.visible ? shutdownButton : logoutButton))
                visible: spdMethods.SuspendState && root.showAllOptions
            }
            LogoutButton {
                id: hibernateButton
                icon.name: "system-suspend-hibernate"
                text: root.showAllOptions ? "&Hibernate" : "&Hibernate Now"
                onClicked: root.hibernateRequested()
                KeyNavigation.left: suspendButton.visible ? suspendButton : cancelButton
                KeyNavigation.right: rebootButton.visible ? rebootButton : (shutdownButton.visible ? shutdownButton : (logoutButton.visible ? logoutButton : cancelButton))
                visible: spdMethods.HibernateState && root.showAllOptions
            }
            LogoutButton {
                id: rebootButton
                icon.name: softwareUpdatePending ? "system-reboot-update" : "system-reboot"
                text: {
                    if (softwareUpdatePending) {
                        return "Install Updates and Restart";
                    }
                    return root.showAllOptions ? "&Restart" : "&Restart Now";
                }
                onClicked: {
                    if (softwareUpdatePending) {
                        root.rebootUpdateRequested();
                    } else {
                        root.rebootRequested();
                    }
                }
                KeyNavigation.left: hibernateButton.visible ? hibernateButton : (suspendButton.visible ? suspendButton : cancelButton)
                KeyNavigation.right: rebootWithoutUpdatesButton.visible ? rebootWithoutUpdatesButton : (shutdownButton.visible ? shutdownButton : (logoutButton.visible ? logoutButton : cancelButton))
                focus: sdtype === ShutdownType.ShutdownTypeReboot
                visible: maysd && (sdtype === ShutdownType.ShutdownTypeReboot || root.showAllOptions)
            }
            LogoutButton {
                id: rebootWithoutUpdatesButton
                icon.name: "system-reboot"
                text: root.showAllOptions ? "&Restart" : "&Restart Now"
                onClicked: {
                    root.rebootRequested();
                }
                KeyNavigation.left: rebootButton
                KeyNavigation.right: shutdownButton.visible ? shutdownButton : (logoutButton.visible ? logoutButton : cancelButton)
                visible: maysd && softwareUpdatePending && (sdtype === ShutdownType.ShutdownTypeReboot || root.showAllOptions)
            }
            LogoutButton {
                id: shutdownButton
                icon.name: softwareUpdatePending ? "system-shutdown-update" : "system-shutdown"
                text: {
                    if (softwareUpdatePending) {
                        return "Install Updates and Shut Down";
                    }
                    return root.showAllOptions ? "&Shut Down" : "&Shut Down Now";
                }
                onClicked: {
                    if (softwareUpdatePending) {
                        root.haltUpdateRequested();
                    } else {
                        root.haltRequested();
                    }
                }
                KeyNavigation.left: rebootWithoutUpdatesButton.visible ? rebootWithoutUpdatesButton : (rebootButton.visible ? rebootButton : (hibernateButton.visible ? hibernateButton : (suspendButton.visible ? suspendButton : cancelButton)))
                KeyNavigation.right: shutdownWithoutUpdatesButton.visible ? shutdownWithoutUpdatesButton : (logoutButton.visible ? logoutButton : cancelButton)
                focus: sdtype === ShutdownType.ShutdownTypeHalt || root.showAllOptions
                visible: maysd && (sdtype === ShutdownType.ShutdownTypeHalt || root.showAllOptions)
            }
            LogoutButton {
                id: shutdownWithoutUpdatesButton
                icon.name: "system-shutdown"
                text: root.showAllOptions ? "&Shut Down" : "&Shut Down Now"
                onClicked: {
                    root.haltRequested();
                }
                KeyNavigation.left: shutdownButton
                KeyNavigation.right: logoutButton.visible ? logoutButton : cancelButton
                focus: sdtype === ShutdownType.ShutdownTypeHalt || root.showAllOptions
                visible: maysd && softwareUpdatePending && (sdtype === ShutdownType.ShutdownTypeHalt || root.showAllOptions)
            }
            LogoutButton {
                id: logoutButton
                icon.name: "system-log-out"
                text: root.showAllOptions ? "&Log Out" : "&Log Out Now"
                onClicked: root.logoutRequested()
                KeyNavigation.left: shutdownWithoutUpdatesButton.visible ? shutdownWithoutUpdatesButton : (shutdownButton.visible ? shutdownButton : (rebootWithoutUpdatesButton.visible ? rebootWithoutUpdatesButton : (rebootButton.visible ? rebootButton : (hibernateButton.visible ? hibernateButton : (suspendButton.visible ? suspendButton : cancelButton)))))
                KeyNavigation.right: cancelButton
                focus: sdtype === ShutdownType.ShutdownTypeNone
                visible: canLogout && (sdtype === ShutdownType.ShutdownTypeNone || root.showAllOptions)
            }
        }

        // the countdown line, under the buttons (opacity, as visible would re-layout)
        PlasmaComponents.Label {
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: Kirigami.Units.gridUnit
            font.pointSize: Kirigami.Theme.defaultFont.pointSize + 2
            opacity: countDownTimer.running ? 0.75 : 0
            Behavior on opacity {
                OpacityAnimator {
                    duration: Kirigami.Units.longDuration
                    easing.type: Easing.InOutQuad
                }
            }
            text: {
                switch (sdtype) {
                    case ShutdownType.ShutdownTypeReboot:
                        return (softwareUpdatePending ? "Installing software updates and restarting " : "Restarting ") + root.inSeconds(root.remainingTime);
                    case ShutdownType.ShutdownTypeNone:
                        return "Logging out " + root.inSeconds(root.remainingTime);
                    case ShutdownType.ShutdownTypeHalt:
                    default:
                        return (softwareUpdatePending ? "Installing software updates and shutting down " : "Shutting down ") + root.inSeconds(root.remainingTime);
                }
            }
            textFormat: Text.PlainText
        }

        PlasmaComponents.Label {
            Layout.maximumWidth: Math.max(Kirigami.Units.gridUnit * 16, logoutButtonsRow.implicitWidth)
            Layout.alignment: Qt.AlignHCenter
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            font.italic: true
            text: otherSessionsModel.count === 1
                ? "One other user is currently logged in. If the computer is shut down or restarted, that user may lose work."
                : otherSessionsModel.count + " other users are currently logged in. If the computer is shut down or restarted, those users may lose work."
            textFormat: Text.PlainText
            visible: otherSessionsModel.count > 0 && (sdtype !== ShutdownType.ShutdownTypeNone || root.showAllOptions)
        }

        PlasmaComponents.Label {
            Layout.maximumWidth: Math.max(Kirigami.Units.gridUnit * 16, logoutButtonsRow.implicitWidth)
            Layout.alignment: Qt.AlignHCenter
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            font.italic: true
            text: "When restarted, the computer will enter the firmware setup screen."
            textFormat: Text.PlainText
            visible: rebootToFirmwareSetup
        }

        PlasmaComponents.Label {
            Layout.maximumWidth: Math.max(Kirigami.Units.gridUnit * 16, logoutButtonsRow.implicitWidth)
            Layout.alignment: Qt.AlignHCenter
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            font.italic: true
            text: "When restarted, the computer will enter the boot loader menu."
            textFormat: Text.PlainText
            visible: rebootToBootLoaderMenu
        }

        PlasmaComponents.Label {
            Layout.maximumWidth: Math.max(Kirigami.Units.gridUnit * 16, logoutButtonsRow.implicitWidth)
            Layout.alignment: Qt.AlignHCenter
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            font.italic: true
            text: "When restarted, the computer will switch to " + rebootToBootLoaderEntry + "."
            textFormat: Text.PlainText
            visible: rebootToBootLoaderEntry != ""
        }

        // Cancel: a plain Ember word under everything
        PlasmaComponents.AbstractButton {
            id: cancelButton
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: Kirigami.Units.gridUnit
            padding: Kirigami.Units.largeSpacing
            hoverEnabled: true
            text: "&Cancel"
            font.pointSize: Kirigami.Theme.defaultFont.pointSize + 2
            font.bold: true
            font.underline: cancelButton.activeFocus
            onClicked: root.cancelRequested()
            Keys.onPressed: AutoTriggerTimer.cancelAutoTrigger()
            Keys.onEnterPressed: clicked()
            Keys.onReturnPressed: clicked()
            Kirigami.MnemonicData.enabled: cancelButton.enabled && cancelButton.visible
            Kirigami.MnemonicData.controlType: Kirigami.MnemonicData.SecondaryControl
            Kirigami.MnemonicData.label: cancelButton.text
            KeyNavigation.left: logoutButton.visible ? logoutButton : (shutdownWithoutUpdatesButton.visible ? shutdownWithoutUpdatesButton : (shutdownButton.visible ? shutdownButton : (rebootWithoutUpdatesButton.visible ? rebootWithoutUpdatesButton : (rebootButton.visible ? rebootButton : (hibernateButton.visible ? hibernateButton : suspendButton)))))
            KeyNavigation.right: suspendButton.visible ? suspendButton : (hibernateButton.visible ? hibernateButton : rebootButton)
            Shortcut {
                enabled: !(RegExp(/\&[^\&]/).test(cancelButton.text))
                sequence: cancelButton.Kirigami.MnemonicData.sequence
                onActivated: cancelButton.animateClick()
            }
            contentItem: PlasmaComponents.Label {
                text: cancelButton.Kirigami.MnemonicData.richTextLabel
                font: cancelButton.font
                color: Kirigami.Theme.highlightColor
                textFormat: Text.StyledText
                horizontalAlignment: Text.AlignHCenter
            }
        }
    }
}
