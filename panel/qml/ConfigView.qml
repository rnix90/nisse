// SPDX-License-Identifier: GPL-2.0-or-later
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The settings (N-216): how much the AI may do without asking, how long an approval waits, the backends and which kind
// of work goes to which, and the switches that live in the daemon (usage, remote access, kill switch). The daemon owns
// the file; this edits a copy and sends it back, and the daemon refuses anything it would not accept itself.
Item {
    id: root
    property var client

    readonly property var categories: ["chat", "vision", "background"]

    property var draft: ({ authority: "autonomous", approval_expiry_secs: 900, fallback: true, main: "", backends: [], routes: ({}) })
    property var targets: ({})
    property string original: ""
    property string source: "file"
    property string loadError: ""
    property string path: ""
    property string errorText: ""
    property string savedText: ""

    readonly property string authority: draft.authority
    readonly property int expirySecs: draft.approval_expiry_secs
    readonly property bool fallbackOn: draft.fallback === true
    readonly property string mainBackend: draft.main
    readonly property bool dirty: JSON.stringify(draft) !== original

    // ---- loading and saving

    function load() {
        var reply = {}
        try {
            reply = JSON.parse(client.config())
        } catch (e) {
            reply = {}
        }
        if (!reply.config) {
            errorText = "The settings could not be read from the daemon."
            return
        }
        var cfg = JSON.parse(JSON.stringify(reply.config))
        targets = cfg.targets ? cfg.targets : ({})
        delete cfg.targets
        if (!cfg.routes)
            cfg.routes = ({})
        draft = cfg
        original = JSON.stringify(draft)
        source = reply.source ? reply.source : "file"
        loadError = reply.error ? reply.error : ""
        path = reply.path ? reply.path : ""
        errorText = ""
        savedText = ""
    }

    function revert() {
        load()
    }

    function payload() {
        var p = JSON.parse(JSON.stringify(draft))
        var routes = {}
        for (var cat in p.routes)
            if (p.routes[cat] !== "")
                routes[cat] = p.routes[cat]
        p.routes = routes
        return p
    }

    function save() {
        errorText = ""
        savedText = ""
        var err = client.saveConfig(JSON.stringify(payload()))
        if (err !== "") {
            errorText = err
            return
        }
        load()
        savedText = "Saved. It takes effect on the next message."
    }

    // ---- editing a copy

    function copy() {
        return JSON.parse(JSON.stringify(draft))
    }

    function setAuthority(a) { var d = copy(); d.authority = a; draft = d }
    function setExpiry(secs) { var d = copy(); d.approval_expiry_secs = secs; draft = d }
    function setFallback(on) { var d = copy(); d.fallback = on; draft = d }
    function setMain(name) { var d = copy(); d.main = name; draft = d }

    function setRoute(category, name) {
        var d = copy()
        if (name === "")
            delete d.routes[category]
        else
            d.routes[category] = name
        draft = d
    }

    function routeOf(category) {
        return draft.routes && draft.routes[category] ? draft.routes[category] : ""
    }

    function backendNames() {
        var out = []
        for (var i = 0; i < draft.backends.length; ++i)
            out.push(draft.backends[i].name)
        return out
    }

    function backendField(i, key) {
        var v = draft.backends[i] ? draft.backends[i][key] : null
        return v === null || v === undefined ? "" : v
    }

    function setBackendField(i, key, value) {
        var d = copy()
        d.backends[i][key] = value === "" ? null : value
        draft = d
    }

    function addBackend() {
        var d = copy()
        var taken = backendNames()
        var name = "new-ollama"
        for (var n = 2; taken.indexOf(name) >= 0; ++n)
            name = "new-ollama-" + n
        d.backends.push({ name: name, kind: "ollama", base_url: "http://localhost:11434", model: null, fallback: null })
        draft = d
        errorText = ""
    }

    function renameBackend(i, newName) {
        var name = newName.trim()
        var old = draft.backends[i].name
        if (name === old)
            return
        if (name === "") {
            errorText = "A backend needs a name."
            return
        }
        if (backendNames().indexOf(name) >= 0) {
            errorText = "There is already a backend called " + name + "."
            return
        }
        var d = copy()
        d.backends[i].name = name
        if (d.main === old)
            d.main = name
        for (var cat in d.routes)
            if (d.routes[cat] === old)
                d.routes[cat] = name
        for (var j = 0; j < d.backends.length; ++j)
            if (d.backends[j].fallback === old)
                d.backends[j].fallback = name
        draft = d
        errorText = ""
    }

    function removeBackend(i) {
        if (draft.backends.length <= 1) {
            errorText = "At least one backend is needed."
            return
        }
        var name = draft.backends[i].name
        if (name === draft.main) {
            errorText = name + " is the main backend. Pick another main backend first."
            return
        }
        var d = copy()
        d.backends.splice(i, 1)
        for (var cat in d.routes)
            if (d.routes[cat] === name)
                delete d.routes[cat]
        for (var j = 0; j < d.backends.length; ++j)
            if (d.backends[j].fallback === name)
                d.backends[j].fallback = null
        draft = d
        errorText = ""
    }

    function targetWords(name) {
        var t = targets[name]
        return t === "local-ollama" ? "this computer" : (t === "remote-ollama" ? "another computer" : (t === "max-account" ? "Max account" : ""))
    }

    Component.onCompleted: load()

    Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight + 24
        clip: true

        ColumnLayout {
            id: column
            x: 12
            y: 12
            width: parent.width - 24
            spacing: 10

            Label {
                objectName: "sourceNote"
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                visible: root.source !== "file"
                color: "#e0623f"
                text: root.source === "broken"
                    ? "The settings file cannot be used: " + root.loadError + ". nisse is using safe defaults (supervised). Saving here replaces the file; the old one is kept next to it as .bak."
                    : "There is no settings file yet, so these are the defaults. Saving creates it."
            }
            Label {
                objectName: "pathNote"
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                opacity: 0.6
                visible: root.path !== ""
                text: "File: " + root.path + " (you can edit it by hand; comments are not kept when it is saved here)"
            }

            // ---- authority and timeouts
            Label { text: "How much the AI may do"; font.bold: true }
            ComboBox {
                id: authorityPicker
                objectName: "authorityPicker"
                Layout.fillWidth: true
                model: ["autonomous", "supervised"]
                currentIndex: root.authority === "supervised" ? 1 : 0
                displayText: currentIndex === 0 ? "Autonomous: acts without asking (risky actions still ask)" : "Supervised: asks about every permission prompt"
                onActivated: root.setAuthority(model[currentIndex])
            }
            RowLayout {
                Layout.fillWidth: true
                Label { text: "An approval waits" }
                SpinBox {
                    id: expiryBox
                    objectName: "expiryBox"
                    from: 1
                    to: 86400
                    stepSize: 30
                    editable: true
                    value: root.expirySecs
                    onValueModified: root.setExpiry(value)
                }
                Label { text: "seconds for an answer, then counts as denied" ; Layout.fillWidth: true; wrapMode: Text.Wrap }
            }

            // ---- backends
            Label { text: "Backends"; font.bold: true }
            Repeater {
                model: root.draft.backends.length
                delegate: Frame {
                    id: frame
                    required property int index
                    Layout.fillWidth: true
                    ColumnLayout {
                        anchors.fill: parent
                        spacing: 4
                        RowLayout {
                            TextField {
                                objectName: "name-" + frame.index
                                Layout.fillWidth: true
                                text: root.backendField(frame.index, "name")
                                onEditingFinished: root.renameBackend(frame.index, text)
                            }
                            ComboBox {
                                objectName: "kind-" + frame.index
                                model: ["max", "ollama"]
                                currentIndex: root.backendField(frame.index, "kind") === "ollama" ? 1 : 0
                                onActivated: root.setBackendField(frame.index, "kind", model[currentIndex])
                            }
                            Button {
                                objectName: "remove-" + frame.index
                                text: "Remove"
                                onClicked: root.removeBackend(frame.index)
                            }
                        }
                        Label {
                            opacity: 0.7
                            text: root.targetWords(root.backendField(frame.index, "name"))
                            visible: text !== ""
                        }
                        TextField {
                            objectName: "url-" + frame.index
                            Layout.fillWidth: true
                            visible: root.backendField(frame.index, "kind") === "ollama"
                            placeholderText: "Address, for example http://localhost:11434"
                            text: root.backendField(frame.index, "base_url")
                            onEditingFinished: root.setBackendField(frame.index, "base_url", text)
                        }
                        TextField {
                            objectName: "model-" + frame.index
                            Layout.fillWidth: true
                            visible: root.backendField(frame.index, "kind") === "ollama"
                            placeholderText: "Model, for example gpt-oss:20b"
                            text: root.backendField(frame.index, "model")
                            onEditingFinished: root.setBackendField(frame.index, "model", text)
                        }
                        RowLayout {
                            Label { text: "If away, use" }
                            ComboBox {
                                objectName: "fallback-" + frame.index
                                Layout.fillWidth: true
                                model: ["nothing (fail)"].concat(root.backendNames().filter(function (n) { return n !== root.backendField(frame.index, "name") }))
                                currentIndex: {
                                    var f = root.backendField(frame.index, "fallback")
                                    var at = model.indexOf(f)
                                    return f === "" || at < 0 ? 0 : at
                                }
                                onActivated: root.setBackendField(frame.index, "fallback", currentIndex === 0 ? "" : model[currentIndex])
                            }
                        }
                    }
                }
            }
            Button {
                objectName: "addBackend"
                text: "Add a backend"
                onClicked: root.addBackend()
            }
            Switch {
                objectName: "fallbackSwitch"
                text: "Step up to a fallback when a backend is away"
                checked: root.fallbackOn
                onToggled: root.setFallback(checked)
            }

            // ---- routes
            Label { text: "Which backend does which work"; font.bold: true }
            RowLayout {
                Layout.fillWidth: true
                Label { text: "Main (everything without its own choice)"; Layout.fillWidth: true; wrapMode: Text.Wrap }
                ComboBox {
                    objectName: "mainPicker"
                    model: root.backendNames()
                    currentIndex: Math.max(0, model.indexOf(root.mainBackend))
                    onActivated: root.setMain(model[currentIndex])
                }
            }
            Repeater {
                model: root.categories
                delegate: RowLayout {
                    id: routeRow
                    required property string modelData
                    Layout.fillWidth: true
                    Label {
                        Layout.fillWidth: true
                        text: modelData === "chat" ? "Chat and code" : (modelData === "vision" ? "Looking at images" : "Background jobs")
                    }
                    ComboBox {
                        objectName: "route-" + routeRow.modelData
                        model: ["main"].concat(root.backendNames())
                        currentIndex: Math.max(0, model.indexOf(root.routeOf(routeRow.modelData) === "" ? "main" : root.routeOf(routeRow.modelData)))
                        onActivated: root.setRoute(routeRow.modelData, currentIndex === 0 ? "" : model[currentIndex])
                    }
                }
            }

            // ---- save
            RowLayout {
                Button {
                    objectName: "saveButton"
                    text: "Save"
                    highlighted: true
                    enabled: root.dirty
                    onClicked: root.save()
                }
                Button {
                    objectName: "revertButton"
                    text: "Revert"
                    enabled: root.dirty
                    onClicked: root.revert()
                }
            }
            Label {
                objectName: "configError"
                Layout.fillWidth: true
                visible: root.errorText !== ""
                wrapMode: Text.Wrap
                color: "#e0623f"
                text: root.errorText
            }
            Label {
                objectName: "savedNote"
                Layout.fillWidth: true
                visible: root.savedText !== ""
                text: root.savedText
            }

            // ---- what lives in the daemon
            Label { text: "Usage"; font.bold: true }
            StatusBar {
                Layout.fillWidth: true
                client: root.client
            }
            Label { text: "Remote access"; font.bold: true }
            RemoteSwitch {
                Layout.fillWidth: true
                client: root.client
            }
            Label { text: "Kill switch"; font.bold: true }
            KillSwitchBar {
                Layout.fillWidth: true
                client: root.client
            }

            Label { text: "Terminal sessions"; font.bold: true }
            Label {
                objectName: "terminalNote"
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                opacity: 0.8
                text: "Claude Code sessions you start yourself in a terminal on this computer are recorded in the local audit log "
                    + "(marked as terminal) but never limited or held. To stop recording them, delete "
                    + "/etc/claude-code/managed-settings.json (it holds only nisse's two audit hooks)."
            }
        }
    }
}
