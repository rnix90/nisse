// SPDX-License-Identifier: GPL-2.0-or-later
import QtQuick
import QtTest
import "../qml"

TestCase {
    id: tc
    name: "connection"
    when: windowShown
    width: 480
    height: 160
    visible: true

    QtObject {
        id: stub
        property string connectionState: "connected"
        property string connectionText: ""
        property string setupText: ""
    }

    ConnectionBanner {
        id: banner
        width: parent.width
        client: stub
    }

    function init() {
        stub.connectionState = "connected"
        stub.connectionText = ""
        stub.setupText = ""
    }

    function test_nothing_shows_when_all_is_well() {
        verify(!findChild(banner, "connectionBanner").visible)
        verify(!findChild(banner, "setupBanner").visible)
    }

    function test_waiting_for_the_daemon_at_the_start_says_so() {
        stub.connectionState = "waiting"
        stub.connectionText = "Waiting for connection to the nisse daemon."
        verify(findChild(banner, "connectionBanner").visible)
        compare(findChild(banner, "connectionText").text, "Waiting for connection to the nisse daemon.")
    }

    function test_a_daemon_that_went_away_says_it_is_restarting() {
        stub.connectionState = "restarting"
        stub.connectionText = "The nisse daemon is restarting. This usually takes a few seconds."
        verify(findChild(banner, "connectionBanner").visible)
        verify(findChild(banner, "connectionText").text.indexOf("restarting") >= 0)
    }

    function test_the_banner_goes_when_the_daemon_is_back() {
        stub.connectionState = "restarting"
        stub.connectionText = "x"
        verify(findChild(banner, "connectionBanner").visible)
        stub.connectionState = "connected"
        stub.connectionText = ""
        verify(!findChild(banner, "connectionBanner").visible)
    }

    function test_a_missing_claude_code_shows_its_own_line_while_the_daemon_is_fine() {
        stub.setupText = "Claude Code is not installed yet: waiting for a network connection. nisse tries again every 2 minutes."
        verify(findChild(banner, "setupBanner").visible)
        verify(!findChild(banner, "connectionBanner").visible)
        verify(findChild(banner, "setupText").text.indexOf("waiting for a network connection") >= 0)
        stub.setupText = ""
        verify(!findChild(banner, "setupBanner").visible)
    }

    function test_both_can_show_at_once() {
        stub.connectionState = "restarting"
        stub.connectionText = "restarting"
        stub.setupText = "network"
        verify(findChild(banner, "connectionBanner").visible)
        verify(findChild(banner, "setupBanner").visible)
    }

    function test_a_client_without_these_properties_shows_nothing_and_does_not_break() {
        banner.client = null
        verify(!findChild(banner, "connectionBanner").visible)
        verify(!findChild(banner, "setupBanner").visible)
        banner.client = stub
    }
}
