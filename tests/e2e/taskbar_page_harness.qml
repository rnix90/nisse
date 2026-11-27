// SPDX-License-Identifier: GPL-2.0-or-later
// A window that loads one page of the nisse-setup wizard, reports what it shows and saves a picture of it
// (tests/e2e/test_nisse_setup_taskbar_page.sh fills in the two placeholders).
import QtQuick
import QtQuick.Window
import QtQuick.Controls

Window {
    id: win
    width: 760
    height: 720
    visible: true
    color: "#ece8df"

    // inside the content, so that the picture has it (the window's own color is not part of a grab)
    Rectangle {
        anchors.fill: parent
        color: "#ece8df"
    }

    Loader {
        id: loader
        anchors.fill: parent
        source: "file://@PAGE@"
    }

    function find(item, name) {
        if (!item) {
            return null;
        }
        if (item.objectName === name) {
            return item;
        }
        for (var i = 0; i < item.children.length; ++i) {
            var r = find(item.children[i], name);
            if (r) {
                return r;
            }
        }
        return null;
    }
    function rows() {
        var l = find(loader.item, "appList");
        return l ? l.count : -1;
    }
    function ticked() {
        var l = find(loader.item, "appList");
        if (!l) {
            return "none";
        }
        var names = [];
        for (var i = 0; i < l.contentItem.children.length; ++i) {
            var c = l.contentItem.children[i];
            if (c.checked === true) {
                names.push(c.text);
            }
        }
        return names.length + ":" + names.join("|");
    }

    Timer {
        interval: 2000
        running: true
        onTriggered: {
            console.info("STATE available=" + loader.item.available + " shown=" + (loader.item.shown !== undefined ? loader.item.shown.length : "n/a")
                        + " rows=" + win.rows() + " ticked=" + win.ticked());
        }
    }
    // the page opens again (as when the person comes back to it): the list is built again from what is installed now
    Timer {
        interval: 5000
        running: true
        onTriggered: {
            if (loader.item.onPageActivated) {
                loader.item.onPageActivated();
            }
        }
    }
    Timer {
        interval: 6500
        running: true
        onTriggered: {
            console.info("STATE_AFTER rows=" + win.rows() + " ticked=" + win.ticked());
            win.contentItem.grabToImage(function (result) {
                result.saveToFile("@OUT@");
                Qt.quit();
            });
        }
    }
}
