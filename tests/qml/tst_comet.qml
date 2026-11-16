// SPDX-License-Identifier: GPL-2.0-or-later
// N-404: the comet busy spinner, drawn by Qt the way Plasma's splash draws busywidget.svgz: a plain Image, turned by
// a RotationAnimator (see docs/busy-widget-notes.md). Run by tests/e2e/test_comet_qt.sh in the build VM.
import QtQuick
import QtTest

TestCase {
    id: tc
    name: "comet"
    width: 240
    height: 240
    visible: true
    when: windowShown

    readonly property url art: Qt.resolvedUrl("../../assets/art/comet/svg/nisse-comet.svg")

    Item {
        id: stage
        x: 20
        y: 20
        width: 200
        height: 200
        Rectangle { anchors.fill: parent; color: "black" }
        Image {
            id: spinner
            anchors.centerIn: parent
            source: tc.art
            sourceSize.width: 72     // two grid units at 2x, Plasma's own size for this image
            sourceSize.height: 72
        }
    }

    Item {
        id: liveStage
        x: 20
        y: 20
        width: 200
        height: 200
        visible: false
        Rectangle { anchors.fill: parent; color: "black" }
        Image {
            id: live
            anchors.centerIn: parent
            source: tc.art
            sourceSize.width: 72
            sourceSize.height: 72
            // the same animator the splash uses: 0 to 360 degrees in 2000 ms, looping
            RotationAnimator on rotation {
                id: anim
                from: 0
                to: 360
                duration: 2000
                loops: Animation.Infinite
                running: false
            }
        }
    }

    // Plasma's splash names the file busywidget.svgz (gzipped SVG): the shipped file must load too
    Image {
        id: zipped
        visible: false
        source: Qt.resolvedUrl("../../assets/art/comet/busywidget.svgz")
        sourceSize.width: 72
        sourceSize.height: 72
    }

    // how many pixels of a grabbed image are drawn, and where their centre of mass is (relative to the image centre)
    function measure(img) {
        var n = 0, sx = 0, sy = 0
        for (var y = 0; y < img.height; ++y) {
            for (var x = 0; x < img.width; ++x) {
                if (img.red(x, y) > 128) {   // Paper on black: the comet is the only bright thing
                    n++
                    sx += x
                    sy += y
                }
            }
        }
        return { count: n, cx: n ? sx / n - img.width / 2 : 0, cy: n ? sy / n - img.height / 2 : 0 }
    }

    function angleOf(m) {   // clockwise from twelve o'clock, in degrees
        return (Math.atan2(m.cx, -m.cy) * 180 / Math.PI + 360) % 360
    }

    function test_the_svg_loads_in_qt() {
        tryCompare(spinner, "status", Image.Ready)
        verify(spinner.paintedWidth > 0, "nothing painted")
    }

    function test_the_svgz_loads_in_qt() {
        tryCompare(zipped, "status", Image.Ready)
        verify(zipped.paintedWidth > 0, "the svgz painted nothing")
    }

    function test_it_draws_a_comet_not_a_blank_or_a_filled_square() {
        tryCompare(spinner, "status", Image.Ready)
        var m = measure(grabImage(stage))
        verify(m.count > 300, "too little drawn: " + m.count)
        verify(m.count < 2500, "too much drawn: " + m.count)
    }

    function test_it_turns_clockwise_and_keeps_its_shape() {
        tryCompare(spinner, "status", Image.Ready)
        spinner.rotation = 0
        var a0 = grabImage(stage)
        var m0 = measure(a0)
        spinner.rotation = 90
        var a90 = grabImage(stage)
        var m90 = measure(a90)
        verify(!a0.equals(a90), "turning by 90 degrees changed nothing")
        verify(Math.abs(m90.count - m0.count) < 0.1 * m0.count, "the area changed when it turned: " + m0.count + " -> " + m90.count)
        var turned = (angleOf(m90) - angleOf(m0) + 360) % 360
        verify(Math.abs(turned - 90) < 12, "the centre of mass moved " + turned + " degrees, not about 90 clockwise")
        spinner.rotation = 360
        // a full turn comes back to the start (not compared pixel for pixel: anti-aliasing differs in the last bit)
        var m360 = measure(grabImage(stage))
        verify(Math.abs(m360.count - m0.count) < 0.02 * m0.count, "a full turn changed the area: " + m0.count + " -> " + m360.count)
        var back = Math.abs(angleOf(m360) - angleOf(m0))
        verify(Math.min(back, 360 - back) < 2, "a full turn did not come back to the start angle: " + back)
        spinner.rotation = 0
    }

    function test_the_splash_animator_turns_it() {
        tryCompare(live, "status", Image.Ready)
        liveStage.visible = true
        stage.visible = false
        var before = grabImage(liveStage)
        anim.running = true
        wait(700)
        var during = grabImage(liveStage)
        verify(!before.equals(during), "the RotationAnimator did not turn the image")
        anim.running = false
    }
}
