// SPDX-FileCopyrightText: 2026 nisse
// SPDX-License-Identifier: GPL-2.0-or-later

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import org.kde.kirigami as Kirigami

import org.kde.plasmasetup.components as PlasmaSetupComponents

import org.nisse.setup.choicesutil

import "extras.js" as Extras

/**
 * Proprietary and third-party options (N-507d, docs/proprietary-options.md): one checkbox per option in the catalog that nisse-extras lists,
 * each with where it comes from, its license and a Read Terms button. Ticking one that carries a license (Chrome, Steam, the NVIDIA driver)
 * opens an Accept dialog with the terms first. Nothing is installed by ticking: the Install Selected button applies the answer, in the
 * background (the window stays alive), with a list of what is being done. The page sits AFTER the choices page and BEFORE the taskbar page,
 * so the taskbar page lists what was just installed. With no options (the package is absent) it is not shown.
 */
PlasmaSetupComponents.SetupModule {
    id: root

    readonly property var choice: ChoicesUtil.choices.find(c => c.id === "extras")
    readonly property var items: ChoicesUtil.extras

    /** The ids ticked now, and the ticks as they were when the person last pressed Install Selected (or as the machine has them at first). */
    property var ticked: []
    property var attempted: []
    property var progress: ({finished: false, reboot: false, items: []})
    property bool installing: false
    /** One of the items, while its Accept dialog is open. */
    property var asking: null
    /** One of the items, while its Read Terms dialog is open. */
    property var reading: null
    property bool failed: false

    readonly property bool pending: !Extras.same(root.ticked, root.attempted)

    available: root.choice !== undefined && root.items.length > 0
    // a change has to be installed (or undone) before moving on; after an attempt, even a failed one, the person may go on (it is tried again at the next start)
    nextEnabled: !root.installing && !root.pending

    function refresh(): void {
        const have = root.items.filter(i => i.installed).map(i => i.id);
        root.ticked = have;
        root.attempted = have;
        root.progress = ({finished: false, reboot: false, items: []});
        root.failed = false;
    }

    function onPageActivated(): void {
        ChoicesUtil.reload();
        ChoicesUtil.reloadExtras();
        root.refresh();
    }

    function showTerms(item: var, ask: bool): void {
        root.asking = ask ? item : null;
        root.reading = ask ? null : item;
        termsDialog.open();
    }

    function install(): void {
        root.failed = false;
        root.installing = true;
        root.attempted = root.ticked.slice();
        root.progress = ({finished: false, reboot: false, items: root.progress.items});
        ChoicesUtil.applyChoice(root.choice.id, Extras.answer(root.items, root.ticked));
        poll.start();
    }

    Connections {
        target: ChoicesUtil

        function onChoiceApplied(id: string, ok: bool): void {
            if (id !== root.choice.id) {
                return;
            }
            poll.stop();
            root.progress = ChoicesUtil.extrasProgress();
            root.installing = false;
            root.failed = !ok;
        }
    }

    Timer {
        id: poll
        interval: 1000
        repeat: true
        onTriggered: root.progress = ChoicesUtil.extrasProgress()
    }

    Component.onCompleted: root.refresh()

    contentItem: ScrollView {
        id: scroll
        anchors.fill: parent
        clip: true

        Item {
            width: Math.min(scroll.availableWidth, Kirigami.Units.gridUnit * 38)
            height: Math.max(scroll.availableHeight, column.implicitHeight + Kirigami.Units.gridUnit * 2)
            anchors.horizontalCenter: parent.horizontalCenter

            ColumnLayout {
                id: column
                anchors.centerIn: parent
                width: parent.width - Kirigami.Units.gridUnit * 2
                spacing: Kirigami.Units.largeSpacing

                Kirigami.Heading {
                    Layout.fillWidth: true
                    level: 2
                    wrapMode: Text.Wrap
                    text: root.choice ? root.choice.title : ""
                }

                Label {
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    opacity: 0.7
                    text: root.choice ? root.choice.description : ""
                }

                Repeater {
                    id: options
                    objectName: "optionList"
                    model: root.items

                    delegate: Frame {
                        id: card

                        required property var modelData

                        Layout.fillWidth: true
                        enabled: !root.installing

                        contentItem: ColumnLayout {
                            spacing: Kirigami.Units.smallSpacing

                            CheckBox {
                                id: box
                                objectName: "optionBox"
                                Layout.fillWidth: true
                                text: card.modelData.title
                                font.bold: true
                                checked: root.ticked.indexOf(card.modelData.id) >= 0
                                onToggled: {
                                    if (box.checked && card.modelData.accept) {
                                        // not ticked until the terms are accepted: the new array makes the binding on `checked` give it back
                                        root.ticked = root.ticked.slice();
                                        root.showTerms(card.modelData, true);
                                    } else {
                                        root.ticked = Extras.toggled(root.ticked, card.modelData.id, box.checked);
                                    }
                                }
                            }

                            Label {
                                Layout.fillWidth: true
                                Layout.leftMargin: Kirigami.Units.gridUnit * 2
                                wrapMode: Text.Wrap
                                text: card.modelData.summary
                            }

                            Label {
                                Layout.fillWidth: true
                                Layout.leftMargin: Kirigami.Units.gridUnit * 2
                                wrapMode: Text.Wrap
                                opacity: 0.7
                                text: i18nc("@info", "From: %1. License: %2.", card.modelData.source, card.modelData.license)
                            }

                            Kirigami.InlineMessage {
                                Layout.fillWidth: true
                                Layout.leftMargin: Kirigami.Units.gridUnit * 2
                                visible: card.modelData.warning.length > 0
                                type: Kirigami.MessageType.Warning
                                text: card.modelData.warning
                            }

                            Button {
                                Layout.leftMargin: Kirigami.Units.gridUnit * 2
                                flat: true
                                text: i18nc("@action:button", "Read Terms")
                                onClicked: root.showTerms(card.modelData, false)
                            }
                        }
                    }
                }

                Kirigami.InlineMessage {
                    Layout.fillWidth: true
                    visible: root.failed
                    type: Kirigami.MessageType.Error
                    text: i18nc("@info", "Not everything could be installed. Setup can go on, and it will try the rest again at the next start when there is a network.")
                }

                Kirigami.InlineMessage {
                    Layout.fillWidth: true
                    visible: root.progress.finished && !root.failed && root.progress.items.length > 0
                    type: Kirigami.MessageType.Positive
                    text: root.progress.reboot ? i18nc("@info", "Done. A restart is needed before the NVIDIA driver is used.") : i18nc("@info", "Done.")
                }

                ColumnLayout {
                    id: progressList
                    objectName: "progressList"
                    Layout.fillWidth: true
                    visible: root.progress.items.length > 0
                    spacing: Kirigami.Units.smallSpacing

                    Repeater {
                        model: root.progress.items

                        delegate: RowLayout {
                            id: step

                            required property var modelData

                            Layout.fillWidth: true

                            Label {
                                text: Extras.stateLabel(step.modelData.state)
                                font.bold: step.modelData.state === "working"
                                color: step.modelData.state === "failed" ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.textColor
                                Layout.preferredWidth: Kirigami.Units.gridUnit * 6
                            }

                            Label {
                                Layout.fillWidth: true
                                wrapMode: Text.Wrap
                                text: Extras.titleOf(root.items, step.modelData.id) + (step.modelData.message.length > 0 ? ": " + step.modelData.message : "")
                            }
                        }
                    }
                }

                Button {
                    id: installButton
                    objectName: "installButton"
                    Layout.alignment: Qt.AlignHCenter
                    highlighted: true
                    enabled: root.pending && !root.installing
                    text: root.installing ? i18nc("@action:button", "Installing...") : i18nc("@action:button", "Install Selected")
                    onClicked: root.install()
                }

                Label {
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    horizontalAlignment: Text.AlignHCenter
                    opacity: 0.7
                    visible: root.pending && !root.installing
                    text: i18nc("@info", "Press Install Selected to apply your choices before going on. Installing needs an internet connection.")
                }
            }
        }
    }

    Dialog {
        id: termsDialog
        objectName: "termsDialog"
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: Math.min(parent.width - Kirigami.Units.gridUnit * 2, Kirigami.Units.gridUnit * 34)
        height: Math.min(parent.height - Kirigami.Units.gridUnit * 2, Kirigami.Units.gridUnit * 28)
        modal: true
        title: (root.asking ?? root.reading)?.title ?? ""

        // the one that asks has an extra Accept button below
        footer: DialogButtonBox {
            Button {
                visible: root.asking !== null
                text: i18nc("@action:button", "Accept")
                highlighted: true
                DialogButtonBox.buttonRole: DialogButtonBox.AcceptRole
            }
            Button {
                text: root.asking !== null ? i18nc("@action:button", "Cancel") : i18nc("@action:button", "Close")
                DialogButtonBox.buttonRole: DialogButtonBox.RejectRole
            }
        }

        contentItem: ScrollView {
            clip: true

            Label {
                width: termsDialog.width - Kirigami.Units.gridUnit * 3
                wrapMode: Text.Wrap
                text: (root.asking ?? root.reading)?.terms ?? ""
            }
        }

        onAccepted: {
            if (root.asking !== null) {
                root.ticked = Extras.toggled(root.ticked, root.asking.id, true);
            }
            root.asking = null;
            root.reading = null;
        }
        onRejected: {
            root.asking = null;
            root.reading = null;
        }
        onClosed: {
            root.asking = null;
            root.reading = null;
        }
    }
}
