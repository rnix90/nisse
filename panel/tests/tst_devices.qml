// SPDX-License-Identifier: GPL-2.0-or-later
import QtQuick
import QtTest
import "../qml"

TestCase {
    id: tc
    name: "devices"
    when: windowShown
    width: 520
    height: 900
    visible: true

    function dev(id, name, role, extra) {
        var d = { id: id, name: name, role: role, public_key_hex: "ab", created_at: 1794700000, last_seen: null, revoked_at: null }
        for (var k in extra) d[k] = extra[k]
        return d
    }

    QtObject {
        id: stub
        property var list: []
        property var started: []
        property int cancelled: 0
        property var revoked: []
        property string failWith: ""
        signal devicesChanged()
        signal reconnected()

        function devices() { return list.map(function (d) { return JSON.stringify(d) }) }
        function startPairing(name, approverOnly) {
            started.push([name, approverOnly])
            if (failWith !== "")
                return "error: " + failWith
            return JSON.stringify({ code: "12345678", expires_at: 1794700300, name: name, role: approverOnly ? "approver" : "full" })
        }
        function cancelPairing() { cancelled += 1 }
        function revokeDevice(id) {
            revoked.push(id)
            list = list.map(function (d) { if (d.id === id) d.revoked_at = 1794700100; return d })
            devicesChanged()
            return ""
        }
    }

    DevicesView {
        id: view
        anchors.fill: parent
        client: stub
        nowSecs: 1794700000
    }

    function init() {
        stub.list = []
        stub.started = []
        stub.cancelled = 0
        stub.revoked = []
        stub.failWith = ""
        view.nowSecs = 1794700000
        view.reset()
        view.refresh()
    }

    function test_no_devices_says_so() {
        verify(findChild(view, "noDevices").visible)
        compare(findChild(view, "deviceList").count, 0)
    }

    function test_paired_devices_are_listed_with_their_access_in_words() {
        stub.list = [dev("d1", "Bert's phone", "full", { last_seen: 1794699000 }), dev("d2", "Watch", "approver", {})]
        view.refresh()
        compare(findChild(view, "deviceList").count, 2)
        verify(!findChild(view, "noDevices").visible)
        verify(view.describe(stub.list[0]).indexOf("Bert's phone") >= 0)
        verify(view.describe(stub.list[0]).indexOf("full access") >= 0, view.describe(stub.list[0]))
        verify(view.describe(stub.list[1]).indexOf("approving only") >= 0)
        verify(view.describe(stub.list[1]).indexOf("never used") >= 0)
    }

    function test_a_revoked_device_says_so_and_has_no_revoke_button() {
        stub.list = [dev("d1", "Old tablet", "full", { revoked_at: 1794699500 })]
        view.refresh()
        verify(view.describe(stub.list[0]).indexOf("revoked") >= 0)
        verify(!view.canRevoke(stub.list[0]))
        verify(view.canRevoke(dev("d2", "x", "full", {})))
    }

    function test_pairing_needs_a_name() {
        view.pair("   ", false)
        compare(stub.started.length, 0)
        verify(findChild(view, "devicesError").visible)
    }

    function test_pairing_shows_the_code_in_groups_and_when_it_runs_out() {
        view.pair("Bert's phone", false)
        compare(stub.started.length, 1)
        compare(stub.started[0][0], "Bert's phone")
        compare(stub.started[0][1], false)
        verify(findChild(view, "pairingBox").visible)
        compare(findChild(view, "pairingCode").text, "1234 5678")
        verify(findChild(view, "pairingNote").text.indexOf("5 min") >= 0, findChild(view, "pairingNote").text)
    }

    function test_approving_only_is_sent_to_the_daemon() {
        view.pair("Watch", true)
        compare(stub.started[0][1], true)
    }

    function test_cancel_stops_the_pairing() {
        view.pair("Bert's phone", false)
        mouseClick(findChild(view, "cancelPairing"))
        compare(stub.cancelled, 1)
        verify(!findChild(view, "pairingBox").visible)
    }

    function test_a_refusal_from_the_daemon_is_shown() {
        stub.failWith = "the daemon said no"
        view.pair("Bert's phone", false)
        verify(findChild(view, "devicesError").text.indexOf("said no") >= 0)
        verify(!findChild(view, "pairingBox").visible)
    }

    function test_when_the_device_completes_the_pairing_the_code_goes_away_and_the_device_shows() {
        view.pair("Bert's phone", false)
        stub.list = [dev("d1", "Bert's phone", "full", {})]
        stub.devicesChanged()
        verify(!findChild(view, "pairingBox").visible)
        compare(findChild(view, "deviceList").count, 1)
        verify(findChild(view, "pairedNote").text.indexOf("Bert's phone") >= 0)
    }

    function test_a_code_that_has_run_out_is_taken_down() {
        view.pair("Bert's phone", false)
        view.nowSecs = 1794700301
        view.tick()
        verify(!findChild(view, "pairingBox").visible)
        verify(findChild(view, "devicesError").text.indexOf("expired") >= 0)
    }

    function test_revoking_asks_the_daemon_and_the_list_follows() {
        stub.list = [dev("d1", "Bert's phone", "full", {})]
        view.refresh()
        view.revoke("d1")
        compare(stub.revoked[0], "d1")
        verify(view.describe(stub.list[0]).indexOf("revoked") >= 0)
    }

    function test_the_plain_words_say_what_pairing_means() {
        var note = findChild(view, "devicesNote").text
        verify(note.indexOf("full access") >= 0, note)
        verify(note.indexOf("revoke") >= 0, note)
    }
}
