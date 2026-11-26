// SPDX-License-Identifier: GPL-2.0-or-later
import QtQuick
import QtTest
import "../qml"

TestCase {
    id: tc
    name: "usage"
    when: windowShown
    width: 520
    height: 120
    visible: true

    QtObject {
        id: stub
        property string backendLabel: "max"
        property string authorityLabel: "autonomous"
        property string usageJson: ""
        property int refreshes: 0
        function refreshUsage() { refreshes += 1 }
    }

    StatusBar {
        id: bar
        width: parent.width
        client: stub
        nowSecs: 1000000
    }

    function windows(five, seven, fiveReset, sevenReset, extra) {
        var u = {
            max: {
                observed_at: 999000,
                five_hour: five === null ? null : { utilization: five, resets_at: fiveReset, resets_text: null, status: "allowed", expired: false },
                seven_day: seven === null ? null : { utilization: seven, resets_at: sevenReset, resets_text: null, status: "allowed", expired: false },
                others: [], overage_status: "rejected", is_using_overage: false
            },
            tokens: { today: {}, week: {} }
        }
        if (extra)
            for (var k in extra) u[k] = extra[k]
        return JSON.stringify(u)
    }

    function init() {
        stub.usageJson = ""
        stub.refreshes = 0
        bar.nowSecs = 1000000
    }

    function test_nothing_known_says_unknown() {
        compare(findChild(bar, "usage").text, "Usage: Unknown")
    }

    function test_the_two_windows_show_as_percentages() {
        stub.usageJson = windows(0.25, 0.54, 1003600, 1500000)
        compare(findChild(bar, "usage").text, "Usage: 5h 25% | 7d 54%")
    }

    function test_a_window_that_has_reset_shows_a_dash_instead_of_a_stale_number() {
        var u = JSON.parse(windows(0.9, 0.5, 999999, 1500000))
        u.max.five_hour.expired = true
        stub.usageJson = JSON.stringify(u)
        compare(findChild(bar, "usage").text, "Usage: 5h - | 7d 50%")
    }

    function test_only_one_window_known() {
        stub.usageJson = windows(0.1, null, 1003600, null)
        compare(findChild(bar, "usage").text, "Usage: 5h 10%")
    }

    function test_the_level_follows_the_fullest_current_window() {
        stub.usageJson = windows(0.3, 0.5, 1003600, 1500000)
        compare(findChild(bar, "usage").level, "ok")
        stub.usageJson = windows(0.3, 0.82, 1003600, 1500000)
        compare(findChild(bar, "usage").level, "warn")
        stub.usageJson = windows(0.96, 0.5, 1003600, 1500000)
        compare(findChild(bar, "usage").level, "high")
        stub.usageJson = ""
        compare(findChild(bar, "usage").level, "ok")
    }

    function test_the_detail_says_when_each_window_resets_in_words() {
        stub.usageJson = windows(0.25, 0.54, 1000000 + 2 * 3600 + 60, 1000000 + 3 * 86400)
        var detail = bar.usageDetail
        verify(detail.indexOf("5-Hour Window: 25% used, resets in 2 h 1 min") >= 0, detail)
        verify(detail.indexOf("7-Day Window: 54% used, resets in 3 days") >= 0, detail)
    }

    function test_the_detail_uses_the_printed_reset_when_only_text_is_known() {
        var u = JSON.parse(windows(0.25, 0.54, null, null))
        u.max.five_hour.resets_text = "Nov 15, 12:29am (UTC)"
        stub.usageJson = JSON.stringify(u)
        verify(bar.usageDetail.indexOf("resets Nov 15, 12:29am (UTC)") >= 0, bar.usageDetail)
    }

    function test_the_detail_says_how_old_the_numbers_are_when_they_are_old() {
        var u = JSON.parse(windows(0.25, 0.54, 1003600, 1500000))
        u.max.observed_at = 1000000 - 3 * 3600
        stub.usageJson = JSON.stringify(u)
        verify(bar.usageDetail.indexOf("as of 3 h ago") >= 0, bar.usageDetail)
        u.max.observed_at = 999900
        stub.usageJson = JSON.stringify(u)
        verify(bar.usageDetail.indexOf("as of") < 0, "fresh numbers say nothing about their age")
    }

    function test_the_detail_lists_tokens_per_backend_for_today() {
        stub.usageJson = windows(0.25, 0.54, 1003600, 1500000, {
            tokens: { today: {
                max: { turns: 3, input: 20, output: 400, cache_read: 40000, cache_creation: 1200, cost_usd: 0.3 },
                here: { turns: 2, input: 9000, output: 3300, cache_read: 0, cache_creation: 0, cost_usd: 0 } }, week: {} }
        })
        var detail = bar.usageDetail
        verify(detail.indexOf("Tokens today") >= 0, detail)
        verify(detail.indexOf("here: 12.3k") >= 0, detail)
        verify(detail.indexOf("max: 41.6k") >= 0, detail)
    }

    function test_token_counts_are_written_short() {
        compare(bar.tokensText(0), "0")
        compare(bar.tokensText(999), "999")
        compare(bar.tokensText(1500), "1.5k")
        compare(bar.tokensText(12345), "12.3k")
        compare(bar.tokensText(2500000), "2.5M")
    }

    function test_times_are_written_in_words() {
        compare(bar.inWords(30), "under a minute")
        compare(bar.inWords(90), "1 min")
        compare(bar.inWords(2 * 3600 + 60), "2 h 1 min")
        compare(bar.inWords(3 * 86400 + 5 * 3600), "3 days")
        compare(bar.inWords(86400), "1 day")
    }

    function test_damaged_data_reads_as_unknown_not_an_error() {
        stub.usageJson = "{ not json"
        compare(findChild(bar, "usage").text, "Usage: Unknown")
        stub.usageJson = "[]"
        compare(findChild(bar, "usage").text, "Usage: Unknown")
    }

    function test_the_bar_asks_the_daemon_for_a_fresh_reading_when_it_starts_and_on_request() {
        bar.askForUsage()
        compare(stub.refreshes, 1)
    }
}
