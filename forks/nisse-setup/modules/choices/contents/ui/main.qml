// SPDX-FileCopyrightText: 2026 nisse
// SPDX-License-Identifier: GPL-2.0-or-later

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import org.kde.kirigami as Kirigami

import org.kde.plasmasetup.components as PlasmaSetupComponents

import org.nisse.setup.choicesutil

/**
 * The install choices (N-306e): one block per choice that an installed package declares for the first boot (nisse-choices
 * list), with its title and description. An answer is recorded and applied at once. With no choices the page is not shown.
 */
PlasmaSetupComponents.SetupModule {
    id: root

    available: ChoicesUtil.count > 0

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

                Label {
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    horizontalAlignment: Text.AlignHCenter
                    text: i18nc("@info:usagetip", "A few choices about how nisse works for you. You can change them later.")
                }

                Kirigami.InlineMessage {
                    Layout.fillWidth: true
                    visible: ChoicesUtil.error.length > 0
                    type: Kirigami.MessageType.Error
                    text: ChoicesUtil.error
                }

                Repeater {
                    model: ChoicesUtil.choices

                    delegate: ColumnLayout {
                        id: choice

                        required property var modelData

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

                        // an enum: one radio button per option, each with its own description
                        ColumnLayout {
                            visible: choice.modelData.kind === "enum"
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.smallSpacing

                            ButtonGroup {
                                id: optionGroup
                            }

                            Repeater {
                                model: choice.modelData.kind === "enum" ? choice.modelData.options : []

                                delegate: ColumnLayout {
                                    id: option

                                    required property var modelData

                                    Layout.fillWidth: true
                                    spacing: 0

                                    RadioButton {
                                        ButtonGroup.group: optionGroup
                                        text: option.modelData.title
                                        checked: choice.modelData.effective === option.modelData.value
                                        onClicked: ChoicesUtil.setChoice(choice.modelData.id, option.modelData.value)
                                    }

                                    Label {
                                        Layout.fillWidth: true
                                        Layout.leftMargin: Kirigami.Units.gridUnit * 2
                                        wrapMode: Text.Wrap
                                        opacity: 0.7
                                        text: option.modelData.description
                                    }
                                }
                            }
                        }

                        // a bool: a switch
                        Switch {
                            visible: choice.modelData.kind === "bool"
                            checked: choice.modelData.effective === true
                            text: checked ? i18nc("@option:check", "On") : i18nc("@option:check", "Off")
                            onToggled: ChoicesUtil.setChoice(choice.modelData.id, checked)
                        }

                        // a text: a field, applied when the person is done typing
                        TextField {
                            visible: choice.modelData.kind === "text"
                            Layout.fillWidth: true
                            text: choice.modelData.kind === "text" ? choice.modelData.effective : ""
                            onEditingFinished: ChoicesUtil.setChoice(choice.modelData.id, text)
                        }
                    }
                }
            }
        }
    }
}
