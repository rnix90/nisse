// SPDX-License-Identifier: GPL-2.0-or-later
// A window that loads the nisse-setup options page (N-507d), plays a person ticking, reading terms, accepting, cancelling and pressing Install
// Selected, reports what the page did and saves pictures (tests/e2e/test_nisse_setup_extras_page.sh fills in the placeholders).
import QtQuick
import QtQuick.Controls

ApplicationWindow {
    id: win
    width: 780
    height: 1500
    visible: true
    color: "#ece8df"

    // the attached Overlay property can only be read from inside an item
    Item {
        id: probe
        function overlay() {
            return Overlay.overlay;
        }
    }

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
        // the dialog is a child of the module, not of an item
        for (var i = 0; i < loader.item.data.length; ++i) {
            if (loader.item.data[i].objectName === "termsDialog") {
                return loader.item.data[i];
            }
        }
        return null;
    }
    // a grab needs an item made in QML: the page (loader) for the page, the overlay for the dialog that is open over it
    function snap(path, item) {
        var started = item.grabToImage(function (result) {
            console.info("GRAB " + path + " saved=" + result.saveToFile(path) + " size=" + result.image.width + "x" + result.image.height);
        });
        console.info("GRAB started=" + started + " item=" + item + " size=" + item.width + "x" + item.height);
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
                console.info("STATE1 available=" + p.available + " options=" + b.length + " ticked=" + p.ticked.length + " next=" + p.nextEnabled
                             + " pending=" + p.pending + " title=" + b[0].text);
                break;
            case 1: // an option with an open license: ticking is enough
                b[0].click();
                break;
            case 2:
                console.info("STATE2 ticked=" + p.ticked.join("|") + " pending=" + p.pending + " next=" + p.nextEnabled + " installEnabled=" + win.one("installButton").enabled);
                break;
            case 3: // one that carries a license: the terms come first and it is not ticked yet
                b[3].click();
                break;
            case 4:
                console.info("STATE3 asking=" + (p.asking ? p.asking.id : "none") + " tickedHasChrome=" + (p.ticked.indexOf("chrome") >= 0)
                             + " dialogVisible=" + win.dialog().visible + " title=" + win.dialog().title + " boxChecked=" + b[3].checked);
                win.snap("@TERMS@", win.dialog().contentItem);
                break;
            case 5:
                win.dialog().accept();
                break;
            case 6:
                console.info("STATE4 tickedHasChrome=" + (p.ticked.indexOf("chrome") >= 0) + " boxChecked=" + b[3].checked + " dialogVisible=" + win.dialog().visible);
                b[5].click(); // the NVIDIA driver: ask, then say no
                break;
            case 7:
                console.info("STATE5 asking=" + (p.asking ? p.asking.id : "none") + " warning=" + p.items[5].warning.length);
                win.dialog().reject();
                break;
            case 8:
                console.info("STATE6 tickedHasNvidia=" + (p.ticked.indexOf("nvidia") >= 0) + " boxChecked=" + b[5].checked + " dialogVisible=" + win.dialog().visible
                             + " ticked=" + p.ticked.join("|"));
                b[1].click(); // read the terms of one with an open license: Read Terms, then close
                p.showTerms(p.items[1], false);
                break;
            case 9:
                console.info("STATE7 reading=" + (p.reading ? p.reading.id : "none") + " dialogVisible=" + win.dialog().visible + " tickedHasCodecs=" + (p.ticked.indexOf("codecs") >= 0));
                win.dialog().close();
                break;
            case 10: // Install Selected: there is no root helper in this test, so the answer fails, which shows the failure path
                console.info("STATE8 installing-before=" + p.installing);
                win.one("installButton").clicked();
                break;
            case 11:
                console.info("STATE9 installing=" + p.installing + " failed=" + p.failed + " pending=" + p.pending + " next=" + p.nextEnabled
                             + " progressItems=" + p.progress.items.length + " finished=" + p.progress.finished);
                win.snap("@OUT@", bg);
                break;
            case 12:
                Qt.quit();
                break;
            }
        }
    }
}
