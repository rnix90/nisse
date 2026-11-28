// SPDX-License-Identifier: GPL-2.0-or-later
// A window that loads the nisse-setup development boards page (N-514a), plays a person ticking, unticking, reading terms and pressing Install
// Selected, reports what the page did and saves a picture (tests/e2e/test_nisse_setup_extras_page.sh fills in the placeholders).
import QtQuick
import QtQuick.Controls

ApplicationWindow {
    id: win
    width: 780
    height: 1300
    visible: true
    color: "#ece8df"

    // inside the grabbed item, so that the picture has the background (the window's own color is not part of a grab)
    Rectangle {
        id: bg
        anchors.fill: parent
        color: "#ece8df"

        Loader {
            id: loader
            anchors.fill: parent
            source: "file://@PAGE@"
        }
    }

    function find(item, name, out) {
        if (!item) {
            return out;
        }
        if (item.objectName === name) {
            out.push(item);
        }
        for (var i = 0; i < item.children.length; ++i) {
            find(item.children[i], name, out);
        }
        return out;
    }
    function boxes() {
        return find(loader.item, "optionBox", []);
    }
    function one(name) {
        var r = find(loader.item, name, []);
        return r.length > 0 ? r[0] : null;
    }
    function dialog() {
        for (var i = 0; i < loader.item.data.length; ++i) {
            if (loader.item.data[i].objectName === "termsDialog") {
                return loader.item.data[i];
            }
        }
        return null;
    }
    function snap(path, item) {
        item.grabToImage(function (result) {
            result.saveToFile(path);
        });
    }

    property int step: 0
    Timer {
        interval: 900
        running: true
        repeat: true
        onTriggered: {
            var p = loader.item;
            var b = win.boxes();
            switch (win.step++) {
            case 0:
                console.info("BSTATE1 available=" + p.available + " options=" + b.length + " ticked=" + p.ticked.join("|") + " pending=" + p.pending + " next=" + p.nextEnabled
                             + " first=" + b[0].text + " group=" + p.group + " choice=" + (p.choice ? p.choice.id : "none") + " installEnabled=" + win.one("installButton").enabled);
                break;
            case 1: // Raspberry Pi Pico: an open license, so ticking is enough and no dialog opens
                b[2].click();
                break;
            case 2:
                console.info("BSTATE2 ticked=" + p.ticked.join("|") + " asking=" + (p.asking ? p.asking.id : "none") + " dialogVisible=" + win.dialog().visible);
                b[0].click(); // untick ESP32
                break;
            case 3:
                console.info("BSTATE3 ticked=" + p.ticked.join("|") + " tickedHasEsp32=" + (p.ticked.indexOf("esp32") >= 0));
                p.showTerms(p.items[3], false);
                break;
            case 4:
                console.info("BSTATE4 reading=" + (p.reading ? p.reading.id : "none") + " dialogVisible=" + win.dialog().visible + " title=" + win.dialog().title);
                win.dialog().close();
                break;
            case 5: // no root helper in this test, so the answer fails and the failure path shows
                win.one("installButton").clicked();
                break;
            case 6:
                console.info("BSTATE5 installing=" + p.installing + " failed=" + p.failed + " pending=" + p.pending + " next=" + p.nextEnabled + " progressItems=" + p.progress.items.length);
                win.snap("@OUT@", bg);
                break;
            case 7:
                Qt.quit();
                break;
            }
        }
    }
}
