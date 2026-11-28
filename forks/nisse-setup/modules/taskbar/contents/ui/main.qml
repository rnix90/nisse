// SPDX-FileCopyrightText: 2026 nisse
// SPDX-License-Identifier: GPL-2.0-or-later

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import org.kde.kirigami as Kirigami

import org.kde.plasmasetup.components as PlasmaSetupComponents

import org.nisse.setup.choicesutil

import "pins.js" as Pins

/**
 * The taskbar apps (N-508c, docs/taskbar-pins-spike.md): one checkbox per app installed on this computer, for each `multi` choice an
 * installed package declares (the taskbar pins). It is a page of its own, AFTER the choices page, and builds its list of apps each time
 * it opens, so an app an earlier choice installed (a different browser) is in it. A tick is recorded and applied at once, like every
 * answer; what is chosen keeps its order, a newly ticked app goes to the end. With no such choice the page is not shown.
 */
PlasmaSetupComponents.SetupModule {
    id: root

    /** The apps offered (maps with id, name, icon, pseudo), read again whenever the page opens. */
    property var apps: []

    readonly property var lists: ChoicesUtil.choices.filter(c => c.kind === "multi" && c.id === "taskbar-pins")

    available: lists.length > 0

    function refresh(): void {
        root.apps = ChoicesUtil.launchers();
    }

    function onPageActivated(): void {
        ChoicesUtil.reload();
        root.refresh();
    }

    Component.onCompleted: refresh()

    contentItem: ScrollView {
        id: scroll
        anchors.fill: parent
        clip: true

        Item {
            width: Math.min(scroll.availableWidth, Kirigami.Units.gridUnit * 36)
            height: Math.max(scroll.availableHeight, column.implicitHeight + Kirigami.Units.gridUnit * 2)
            anchors.horizontalCenter: parent.horizontalCenter

            ColumnLayout {
                id: column
                anchors.centerIn: parent
                width: parent.width - Kirigami.Units.gridUnit * 2
                spacing: Kirigami.Units.gridUnit

                Kirigami.InlineMessage {
                    Layout.fillWidth: true
                    visible: ChoicesUtil.error.length > 0
                    type: Kirigami.MessageType.Error
                    text: ChoicesUtil.error
                }

                Repeater {
                    model: root.lists

                    delegate: ColumnLayout {
                        id: choice

                        required property var modelData

                        readonly property var chosen: choice.modelData.effective
                        readonly property var shown: root.apps.filter(a => a.name.toLowerCase().indexOf(search.text.trim().toLowerCase()) >= 0)

                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing

                        Kirigami.Heading {
                            Layout.fillWidth: true
                            level: 3
                            wrapMode: Text.Wrap
                            text: choice.modelData.title
                        }

                        Label {
                            Layout.fillWidth: true
                            wrapMode: Text.Wrap
                            opacity: 0.7
                            text: choice.modelData.description
                        }

                        TextField {
                            id: search
                            Layout.fillWidth: true
                            placeholderText: i18nc("@info:placeholder", "Search apps")
                        }

                        ListView {
                            id: list
                            objectName: "appList"
                            Layout.fillWidth: true
                            Layout.preferredHeight: Kirigami.Units.gridUnit * 16
                            clip: true
                            model: choice.shown
                            ScrollBar.vertical: ScrollBar {}

                            delegate: CheckDelegate {
                                id: row

                                required property var modelData

                                width: ListView.view.width
                                text: row.modelData.name
                                icon.name: row.modelData.icon
                                checked: choice.chosen.indexOf(row.modelData.id) >= 0
                                onToggled: ChoicesUtil.setChoice(choice.modelData.id, Pins.answer(Pins.toggled(choice.chosen, row.modelData.id, checked)))
                            }
                        }

                        Label {
                            Layout.fillWidth: true
                            opacity: 0.7
                            text: i18ncp("@info", "%1 app is pinned.", "%1 apps are pinned.", choice.chosen.length)
                        }
                    }
                }
            }
        }
    }
}
