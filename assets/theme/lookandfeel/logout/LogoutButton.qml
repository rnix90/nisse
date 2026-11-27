/*
    SPDX-FileCopyrightText: 2016 Marco Martin <mart@kde.org>
    SPDX-FileCopyrightText: 2016 David Edmundson <davidedmundson@kde.org>
    SPDX-FileCopyrightText: 2024 Noah Davis <noahadvs@gmail.com>
    SPDX-FileCopyrightText: 2026 the nisse authors

    SPDX-License-Identifier: GPL-2.0-or-later

    nisse's round logout button (ledger N-504), after Breeze's LogoutButton and ActionButton: a circle with an icon and a label under it.
    The one that has the keyboard focus (the default) is the Ember circle with an Ink icon; the others are a quiet circle with a thin ring.
    The colors come from the look's color scheme (the Selection colors for the default), so the light look gets brick and Paper.
*/

import QtQuick
import QtQuick.Layouts

import org.kde.plasma.components as PlasmaComponents3
import org.kde.kirigami as Kirigami

import "timer.js" as AutoTriggerTimer

PlasmaComponents3.AbstractButton {
    id: root

    Layout.alignment: Qt.AlignTop

    readonly property int circleSize: Kirigami.Units.gridUnit * 6
    readonly property bool isDefault: root.activeFocus

    font.pointSize: Kirigami.Theme.defaultFont.pointSize + 2
    font.bold: root.isDefault
    font.underline: false

    icon.width: Kirigami.Units.iconSizes.large
    icon.height: Kirigami.Units.iconSizes.large

    hoverEnabled: true
    opacity: root.activeFocus || root.hovered ? 1 : 0.85
    Behavior on opacity {
        PropertyAnimation {
            duration: Kirigami.Units.longDuration
            easing.type: Easing.InOutQuad
        }
    }

    padding: Kirigami.Units.smallSpacing
    horizontalPadding: Kirigami.Units.largeSpacing
    spacing: Kirigami.Units.largeSpacing

    Kirigami.MnemonicData.enabled: root.enabled && root.visible
    Kirigami.MnemonicData.controlType: Kirigami.MnemonicData.SecondaryControl
    Kirigami.MnemonicData.label: root.text

    Shortcut {
        // an explicit & in the text means the button manages its own shortcut
        enabled: !(RegExp(/\&[^\&]/).test(root.text))
        sequence: root.Kirigami.MnemonicData.sequence
        onActivated: root.animateClick()
    }

    Keys.onPressed: {
        AutoTriggerTimer.cancelAutoTrigger();
    }

    // the circle and the icon are drawn in the content, so they are centered over the label; the button itself has no background
    background: Item {}

    contentItem: Column {
        spacing: root.spacing

        Item {
            anchors.horizontalCenter: parent.horizontalCenter
            width: root.circleSize
            height: root.circleSize

            Rectangle {
                anchors.fill: parent
                radius: width / 2
                color: root.isDefault ? Kirigami.Theme.highlightColor : Kirigami.Theme.alternateBackgroundColor
                border.width: root.isDefault ? 0 : 2
                border.color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.45)
                Behavior on color {
                    ColorAnimation {
                        duration: Kirigami.Units.shortDuration
                    }
                }
            }

            Kirigami.Icon {
                anchors.centerIn: parent
                width: root.icon.width
                height: root.icon.height
                source: root.icon.name
                isMask: true
                color: root.isDefault ? Kirigami.Theme.highlightedTextColor : Kirigami.Theme.textColor
            }
        }

        PlasmaComponents3.Label {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(implicitWidth, root.circleSize * 2)      // wider than the circle ("Shut Down Now"), wrapped only when very long
            text: root.Kirigami.MnemonicData.richTextLabel
            font: root.font
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignTop
            textFormat: Text.StyledText
            wrapMode: Text.WordWrap
        }
    }

    Keys.onEnterPressed: clicked()
    Keys.onReturnPressed: clicked()
}
