/*
    SPDX-FileCopyrightText: 2014 Marco Martin <mart@kde.org>
    SPDX-FileCopyrightText: 2026 the nisse authors

    SPDX-License-Identifier: GPL-2.0-or-later

    nisse's Plasma splash (ledger N-505), after Breeze's: the same start stages and fades, but the picture is the approved mock
    (assets/art/boot/splash-*.png): the nisse n with its tipped hat, still, inside the comet ring, which turns. Nothing else: no text and no KDE logo.
    The colors come from the active color scheme, so one file serves both looks: the window background (Ink, or Paper in the light look), the text
    color for the n (Paper, or Ink) and the highlight color for the comet (Ember, or brick). The two pictures are single-color shapes, tinted here.
*/

import QtQuick
import org.kde.kirigami as Kirigami

Rectangle {
    id: root
    Kirigami.Theme.inherit: false
    Kirigami.Theme.colorSet: Kirigami.Theme.Window
    color: Kirigami.Theme.backgroundColor

    property int stage

    onStageChanged: {
        if (stage == 2) {
            introAnimation.running = true;
        } else if (stage == 5) {
            introAnimation.target = comet;
            introAnimation.from = 1;
            introAnimation.to = 0;
            introAnimation.running = true;
        }
    }

    Item {
        id: content
        anchors.fill: parent
        opacity: 0

        // the n with its hat: 260 px of a 1080 px screen in the mock, 14 grid units here
        Kirigami.Icon {
            id: logo
            readonly property real size: Kirigami.Units.gridUnit * 14
            anchors.centerIn: parent
            width: size
            height: size
            source: Qt.resolvedUrl("images/n.svg")
            isMask: true
            color: Kirigami.Theme.textColor
        }

        // the comet ring around it, turning clockwise; its fixed duration is on purpose (as in Breeze): it must not follow the animation speed
        Kirigami.Icon {
            id: comet
            readonly property real size: Kirigami.Units.gridUnit * 24
            anchors.centerIn: parent
            width: size
            height: size
            source: Qt.resolvedUrl("images/comet.svg")
            isMask: true
            color: Kirigami.Theme.highlightColor
            RotationAnimator on rotation {
                from: 0
                to: 360
                duration: 2000
                loops: Animation.Infinite
                // not at all when the user has switched animations off
                running: Kirigami.Units.longDuration > 1
            }
        }
    }

    OpacityAnimator {
        id: introAnimation
        running: false
        target: content
        from: 0
        to: 1
        duration: Kirigami.Units.veryLongDuration * 2
        easing.type: Easing.InOutQuad
    }
}
