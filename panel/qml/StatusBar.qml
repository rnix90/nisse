// SPDX-License-Identifier: GPL-2.0-or-later
import QtQuick
import QtQuick.Controls

// The top bar: the backend, how much of the account's limits is used (N-214), and the authority.
Rectangle {
    id: root
    property var client
    // The clock in unix seconds; a property so tests can set it.
    property real nowSecs: Math.floor(Date.now() / 1000)

    implicitHeight: 32
    color: "#1b2330"

    // ---- usage, from the daemon's JSON (docs/panel-notes.md)
    readonly property var usageData: parseUsage(client ? client.usageJson : "")
    readonly property string usageSummary: summary(usageData)
    readonly property string usageLevel: levelOf(usageData)
    readonly property string usageDetail: detail(usageData, nowSecs)

    function parseUsage(text) {
        if (!text)
            return null
        try {
            var v = JSON.parse(text)
            return (v && typeof v === "object" && !Array.isArray(v) && v.max) ? v : null
        } catch (e) {
            return null
        }
    }

    function percent(w) {
        return Math.round(w.utilization * 100)
    }

    function windowText(label, w) {
        if (!w)
            return ""
        return label + " " + (w.expired ? "-" : percent(w) + "%")
    }

    function summary(u) {
        if (!u)
            return "Usage: Unknown"
        var parts = []
        var five = windowText("5h", u.max.five_hour)
        var seven = windowText("7d", u.max.seven_day)
        if (five !== "")
            parts.push(five)
        if (seven !== "")
            parts.push(seven)
        return parts.length > 0 ? "Usage: " + parts.join(" | ") : "Usage: Unknown"
    }

    function levelOf(u) {
        if (!u)
            return "ok"
        var worst = 0
        var ws = [u.max.five_hour, u.max.seven_day]
        for (var i = 0; i < ws.length; ++i)
            if (ws[i] && !ws[i].expired)
                worst = Math.max(worst, ws[i].utilization)
        return worst >= 0.95 ? "high" : (worst >= 0.8 ? "warn" : "ok")
    }

    function inWords(seconds) {
        if (seconds >= 86400) {
            var days = Math.floor(seconds / 86400)
            return days + (days === 1 ? " day" : " days")
        }
        if (seconds >= 3600) {
            var h = Math.floor(seconds / 3600)
            var m = Math.floor((seconds % 3600) / 60)
            return h + " h" + (m > 0 ? " " + m + " min" : "")
        }
        if (seconds >= 60)
            return Math.floor(seconds / 60) + " min"
        return "under a minute"
    }

    function tokensText(n) {
        if (n >= 1000000)
            return (Math.round(n / 100000) / 10) + "M"
        if (n >= 1000)
            return (Math.round(n / 100) / 10) + "k"
        return "" + n
    }

    function windowDetail(label, w, now) {
        if (!w)
            return ""
        if (w.expired)
            return label + ": its window has reset since this was read"
        var when = ""
        if (w.resets_at)
            when = ", resets in " + inWords(Math.max(0, w.resets_at - now))
        else if (w.resets_text)
            when = ", resets " + w.resets_text
        return label + ": " + percent(w) + "% used" + when
    }

    function detail(u, now) {
        if (!u)
            return "Usage of the Max account is not known yet. It is read from Claude Code at the start of each turn."
        var lines = ["Usage of the Max Account"]
        var five = windowDetail("5-Hour Window", u.max.five_hour, now)
        var seven = windowDetail("7-Day Window", u.max.seven_day, now)
        if (five !== "")
            lines.push(five)
        if (seven !== "")
            lines.push(seven)
        if (u.max.observed_at && now - u.max.observed_at > 1800)
            lines.push("(as of " + inWords(now - u.max.observed_at) + " ago)")
        var today = u.tokens && u.tokens.today ? u.tokens.today : {}
        var names = Object.keys(today)
        if (names.length > 0) {
            var parts = []
            for (var i = 0; i < names.length; ++i) {
                var t = today[names[i]]
                parts.push(names[i] + ": " + tokensText(t.input + t.output + t.cache_read + t.cache_creation))
            }
            lines.push("Tokens today (cached ones included) - " + parts.join(", "))
        }
        return lines.join("\n")
    }

    // Asks the daemon to read the limits now (Claude Code's own /usage report: no model call, no cost).
    function askForUsage() {
        if (client && client.refreshUsage)
            client.refreshUsage()
    }

    Component.onCompleted: askForUsage()

    Timer {
        interval: 600000
        running: root.visible
        repeat: true
        onTriggered: root.askForUsage()
    }

    Timer {
        interval: 30000
        running: root.visible
        repeat: true
        onTriggered: root.nowSecs = Math.floor(Date.now() / 1000)
    }

    Label {
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        anchors.leftMargin: 10
        color: "#f6f2e9"
        text: "Backend: " + (root.client ? root.client.backendLabel : "unknown")
    }

    Label {
        id: usageLabel
        objectName: "usage"
        anchors.verticalCenter: parent.verticalCenter
        anchors.horizontalCenter: parent.horizontalCenter
        readonly property string level: root.usageLevel
        color: level === "high" ? "#e0623f" : (level === "warn" ? "#d9a441" : "#f6f2e9")
        text: root.usageSummary

        HoverHandler { id: hover }
        TapHandler { onTapped: root.askForUsage() }
        ToolTip.visible: hover.hovered
        ToolTip.delay: 400
        ToolTip.text: root.usageDetail
    }

    Label {
        objectName: "authority"
        anchors.verticalCenter: parent.verticalCenter
        anchors.right: parent.right
        anchors.rightMargin: 10
        color: "#f6f2e9"
        text: "Authority: " + (root.client ? root.client.authorityLabel : "unknown")
    }
}
