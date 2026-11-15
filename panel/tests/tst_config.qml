// SPDX-License-Identifier: GPL-2.0-or-later
import QtQuick
import QtTest
import "../qml"

TestCase {
    id: tc
    name: "config"
    when: windowShown
    width: 520
    height: 1800
    visible: true

    function baseConfig() {
        return {
            authority: "autonomous", approval_expiry_secs: 900, fallback: true, main: "max",
            backends: [
                { name: "max", kind: "max", base_url: null, model: null, fallback: null },
                { name: "here", kind: "ollama", base_url: "http://127.0.0.1:11434", model: "gpt-oss:20b", fallback: "max" }
            ],
            routes: { vision: "here" },
            targets: { max: "max-account", here: "local-ollama" }
        }
    }

    QtObject {
        id: stub
        property string killSwitchJson: JSON.stringify({ engaged: false })
        property string usageJson: ""
        property var reply: ({ config: tc.baseConfig(), source: "file", error: null, path: "/home/u/.config/nisse/backends.toml" })
        property var saved: []
        property string failWith: ""
        function config() { return JSON.stringify(reply) }
        function saveConfig(json) {
            saved.push(JSON.parse(json))
            if (failWith !== "")
                return failWith
            reply = { config: JSON.parse(json), source: "file", error: null, path: reply.path }
            return ""
        }
        function remoteAccess() { return JSON.stringify({ enabled: false, running: false, restarts: 0, error: null }) }
        function setRemoteAccess(on) { return "" }
        signal remoteAccessChanged(string json)
        signal configChanged()
        signal devicesChanged()
        function devices() { return [] }
        signal reconnected()
        function engageKillSwitch(r) { return "" }
        function releaseKillSwitch() { return "" }
        function refreshUsage() {}
    }

    ConfigView {
        id: view
        anchors.fill: parent
        client: stub
    }

    function init() {
        stub.reply = { config: baseConfig(), source: "file", error: null, path: "/home/u/.config/nisse/backends.toml" }
        stub.saved = []
        stub.failWith = ""
        view.load()
    }

    function test_it_shows_what_the_daemon_is_using() {
        compare(view.authority, "autonomous")
        compare(view.expirySecs, 900)
        verify(view.fallbackOn)
        compare(view.mainBackend, "max")
        compare(view.backendNames().join(","), "max,here")
        compare(view.routeOf("vision"), "here")
        compare(view.routeOf("chat"), "")
        verify(!view.dirty)
    }

    function test_editing_marks_it_changed_and_saving_sends_what_was_edited() {
        view.setAuthority("supervised")
        view.setExpiry(120)
        view.setFallback(false)
        view.setRoute("background", "here")
        verify(view.dirty)
        mouseClick(findChild(view, "saveButton"))
        compare(stub.saved.length, 1)
        var s = stub.saved[0]
        compare(s.authority, "supervised")
        compare(s.approval_expiry_secs, 120)
        compare(s.fallback, false)
        compare(s.routes.background, "here")
        compare(s.routes.vision, "here")
        compare(s.main, "max")
        compare(s.backends.length, 2)
        verify(!view.dirty)
        compare(findChild(view, "savedNote").text, "Saved. It takes effect on the next message.")
    }

    function test_a_refusal_from_the_daemon_is_shown_and_the_edits_are_kept() {
        stub.failWith = "main backend \"x\" is not defined"
        view.setAuthority("supervised")
        mouseClick(findChild(view, "saveButton"))
        verify(findChild(view, "configError").visible)
        verify(findChild(view, "configError").text.indexOf("not defined") >= 0)
        verify(view.dirty)
        compare(view.authority, "supervised")
    }

    function test_the_save_button_is_off_until_something_changes() {
        verify(!findChild(view, "saveButton").enabled)
        view.setFallback(false)
        verify(findChild(view, "saveButton").enabled)
    }

    function test_revert_goes_back_to_what_the_daemon_has() {
        view.setAuthority("supervised")
        mouseClick(findChild(view, "revertButton"))
        compare(view.authority, "autonomous")
        verify(!view.dirty)
    }

    function test_adding_a_backend_gives_it_a_free_name_and_a_local_ollama_start() {
        view.addBackend()
        compare(view.backendNames().length, 3)
        var name = view.backendNames()[2]
        verify(name.length > 0 && name !== "max" && name !== "here")
        view.addBackend()
        var names = view.backendNames()
        compare(names[2] === names[3], false, "names stay unique")
        compare(view.backendField(2, "kind"), "ollama")
        compare(view.backendField(2, "base_url"), "http://localhost:11434")
        verify(view.dirty)
    }

    function test_editing_a_backend_field() {
        view.setBackendField(1, "model", "qwen3-vl:8b")
        view.setBackendField(1, "base_url", "http://192.0.2.10:11434")
        mouseClick(findChild(view, "saveButton"))
        compare(stub.saved[0].backends[1].model, "qwen3-vl:8b")
        compare(stub.saved[0].backends[1].base_url, "http://192.0.2.10:11434")
    }

    function test_renaming_a_backend_follows_every_reference_to_it() {
        view.renameBackend(1, "desk")
        compare(view.backendNames().join(","), "max,desk")
        compare(view.routeOf("vision"), "desk")
        view.setMain("desk")
        view.renameBackend(0, "cloud")
        compare(view.backendField(1, "fallback"), "cloud", "the fallback pointed at max, which is now cloud")
        compare(view.mainBackend, "desk")
    }

    function test_a_name_that_is_taken_or_empty_is_not_accepted() {
        view.renameBackend(1, "max")
        compare(view.backendNames().join(","), "max,here")
        verify(findChild(view, "configError").visible)
        view.renameBackend(1, "   ")
        compare(view.backendNames().join(","), "max,here")
    }

    function test_removing_a_backend_clears_what_pointed_at_it() {
        view.removeBackend(1)
        compare(view.backendNames().join(","), "max")
        compare(view.routeOf("vision"), "", "its route is gone")
        view.addBackend()
        view.setBackendField(1, "fallback", "max")
        view.setBackendField(0, "fallback", view.backendNames()[1])
        view.removeBackend(1)
        compare(view.backendField(0, "fallback"), "", "a fallback that pointed at it is cleared")
    }

    function test_the_main_backend_cannot_be_removed() {
        view.removeBackend(0)
        compare(view.backendNames().length, 2)
        verify(findChild(view, "configError").text.indexOf("main") >= 0)
    }

    function test_the_last_backend_cannot_be_removed() {
        view.removeBackend(1)
        view.removeBackend(0)
        compare(view.backendNames().length, 1)
    }

    function test_changing_the_main_backend() {
        view.setMain("here")
        compare(view.mainBackend, "here")
        mouseClick(findChild(view, "saveButton"))
        compare(stub.saved[0].main, "here")
    }

    function test_a_route_set_to_nothing_is_left_out_of_what_is_saved() {
        view.setRoute("vision", "")
        mouseClick(findChild(view, "saveButton"))
        compare(Object.keys(stub.saved[0].routes).length, 0)
    }

    function test_a_missing_settings_file_says_these_are_the_defaults() {
        stub.reply = { config: baseConfig(), source: "default", error: null, path: "/p" }
        view.load()
        verify(findChild(view, "sourceNote").visible)
        verify(findChild(view, "sourceNote").text.indexOf("defaults") >= 0)
    }

    function test_a_broken_file_says_why_and_that_saving_replaces_it() {
        stub.reply = { config: baseConfig(), source: "broken", error: "main backend \"ghost\" is not defined", path: "/p" }
        view.load()
        var text = findChild(view, "sourceNote").text
        verify(findChild(view, "sourceNote").visible)
        verify(text.indexOf("ghost") >= 0, text)
        verify(text.indexOf(".bak") >= 0, text)
    }

    function test_a_good_file_shows_no_source_note() {
        verify(!findChild(view, "sourceNote").visible)
    }

    function test_the_plain_words_about_terminal_sessions_say_how_to_stop_the_recording() {
        var text = findChild(view, "terminalNote").text
        verify(text.indexOf("terminal") >= 0, text)
        verify(text.indexOf("audit log") >= 0, text)
        verify(text.indexOf("/etc/claude-code/managed-settings.json") >= 0, text)
    }

    function test_the_other_switches_are_here_too() {
        verify(findChild(view, "remoteSwitch") !== null)
        verify(findChild(view, "killButton") !== null)
        verify(findChild(view, "usage") !== null || findChild(view, "usageLine") !== null)
    }

    function test_the_file_location_is_shown() {
        verify(findChild(view, "pathNote").text.indexOf("/home/u/.config/nisse/backends.toml") >= 0)
    }
}
