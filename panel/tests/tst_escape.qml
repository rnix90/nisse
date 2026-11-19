// SPDX-License-Identifier: GPL-2.0-or-later
// N-415a: Escape closes the sidebar even while the chat field has the keyboard (found in the live session on 2026-11-19: typing
// worked but Escape did nothing, because a focused text field takes the key before a window-level Shortcut sees it).
import QtQuick
import QtQuick.Controls
import QtTest

TestCase {
    id: test
    name: "SidebarEscape"
    width: 400
    height: 200
    visible: true
    when: windowShown

    property int closed: 0

    // the same arrangement as Main.qml: the handler sits on the window's content, the chat input is a TextField inside it
    Item {
        id: content
        anchors.fill: parent
        Keys.onEscapePressed: test.closed++
        TextField {
            id: field
            objectName: "input"
            anchors.centerIn: parent
            width: 300
        }
    }

    function init() {
        closed = 0
        field.text = ""
        field.forceActiveFocus()
    }

    function test_escape_reaches_the_handler_while_the_text_field_has_focus() {
        verify(field.activeFocus)
        keyClick(Qt.Key_Escape)
        compare(closed, 1)
    }

    function test_typing_still_goes_to_the_text_field() {
        keyClick(Qt.Key_H)
        keyClick(Qt.Key_I)
        compare(field.text, "hi")
        compare(closed, 0)
    }

    function test_escape_with_text_typed_still_closes() {
        keyClick(Qt.Key_H)
        keyClick(Qt.Key_Escape)
        compare(closed, 1)
        compare(field.text, "h")
    }
}
