import QtQuick
import QtTest
import qs.Commons
import qs.Core
import qs.Ui
import qs.Unit

// ShortcutField: a click, Enter, Return or Space asks the capture to begin;
// while it holds the field, held modifiers show as caps, the first other
// key commits the combo the judge names, Escape and a focus loss end it,
// and an unnamed key keeps it with a notice; the keyboard button types a
// combo instead, the clear button unbinds, a read-only field asks nothing,
// and the field is one Tab stop. The capture here records what the field
// asks and names keys with the core's own judge.
Item {
    id: root
    width: 480
    height: 300

    QtObject {
        id: capture
        property Item holder: null
        property var calls: []
        function begin(item) { calls = calls.concat(["begin"]); holder = item; return "ok"; }
        function end(item, reason) { if (item !== holder) return; calls = calls.concat(["end " + reason]); holder = null; }
        function keyFor(key, modifiers) { return PluginLogic.capturedKey(key, modifiers); }
    }

    property var events: []

    Column {
        width: parent.width
        spacing: Theme.space.md
        Button { id: before; text: "Before"; focusPolicy: Qt.StrongFocus }
        ShortcutField {
            id: field
            width: parent.width
            key: "SUPER+M"
            capture: capture
            onCommitted: key => root.events = root.events.concat(["committed " + key])
            onTyped: text => root.events = root.events.concat(["typed " + text])
            onCleared: root.events = root.events.concat(["cleared"])
        }
        ShortcutField { id: readOnly; width: parent.width; key: "SUPER+N"; capture: capture; editable: false }
        Button { id: after; text: "After"; focusPolicy: Qt.StrongFocus }
    }

    TestCase {
        name: "shortcutfield"
        when: windowShown

        function init() {
            UnitTheme.reset();
            capture.holder = null;
            capture.calls = [];
            root.events = [];
            field.notice = "";
            field.conflict = "";
            field.capture = capture;
            field.stopTyping();
            before.forceActiveFocus(Qt.TabFocusReason);
        }

        function descendant(f, matches) {
            const stack = [f];
            while (stack.length > 0) {
                const item = stack.pop();
                if (item !== f && matches(item)) return item;
                for (let i = 0; i < item.children.length; i++) stack.push(item.children[i]);
            }
            return null;
        }
        function box(f) { return descendant(f, item => String(item).indexOf("QQuickAbstractButton") === 0); }
        function buttonLabelled(f, label) { return descendant(f, item => item.label === label && item.visible); }
        // The tool row places a button it shows again at its next polish.
        function press(f, label) {
            const button = buttonLabelled(f, label);
            waitForItemPolished(button.parent);
            mouseClick(button);
        }
        function arm() {
            field.forceActiveFocus(Qt.TabFocusReason);
            keyClick(Qt.Key_Return);
            compare(field.capturing, true);
        }

        function test_tab_reaches_the_box_once() {
            keyClick(Qt.Key_Tab);
            verify(box(field).activeFocus);
            keyClick(Qt.Key_Tab);
            verify(!box(field).activeFocus);
        }

        function test_a_read_only_field_takes_no_focus_and_asks_nothing() {
            compare(box(readOnly).focusPolicy, Qt.NoFocus);
            mouseClick(box(readOnly));
            compare(JSON.stringify(capture.calls), "[]");
            compare(buttonLabelled(readOnly, "Unbind"), null);
        }

        function test_idle_caps_show_the_key() {
            compare(JSON.stringify(field.caps), '["SUPER","M"]');
        }

        function test_return_space_enter_and_click_begin() {
            for (const start of [() => keyClick(Qt.Key_Return), () => keyClick(Qt.Key_Space), () => keyClick(Qt.Key_Enter), () => mouseClick(box(field))]) {
                capture.holder = null;
                capture.calls = [];
                field.forceActiveFocus(Qt.TabFocusReason);
                start();
                compare(JSON.stringify(capture.calls), '["begin"]');
                compare(field.capturing, true);
            }
        }

        function test_a_combo_commits_the_judged_key() {
            for (const row of [
                { key: Qt.Key_Space, modifiers: Qt.MetaModifier, want: "SUPER+SPACE" },
                { key: Qt.Key_T, modifiers: Qt.ControlModifier | Qt.AltModifier, want: "CTRL+ALT+T" },
                { key: Qt.Key_F5, modifiers: Qt.NoModifier, want: "F5" }
            ]) {
                root.events = [];
                capture.calls = [];
                arm();
                keyClick(row.key, row.modifiers);
                compare(JSON.stringify(root.events), JSON.stringify(["committed " + row.want]));
                compare(JSON.stringify(capture.calls), '["begin","end commit"]');
                compare(field.capturing, false);
            }
        }

        function test_held_modifiers_show_as_caps() {
            arm();
            keyPress(Qt.Key_Meta);
            keyPress(Qt.Key_Control, Qt.MetaModifier);
            compare(JSON.stringify(field.caps), '["SUPER","CTRL"]');
            // QtTest releases every modifier its mask names, so each
            // release names none.
            keyRelease(Qt.Key_Control);
            compare(JSON.stringify(field.caps), '["SUPER"]');
            keyRelease(Qt.Key_Meta);
            compare(JSON.stringify(field.caps), "[]");
            compare(JSON.stringify(root.events), "[]");
        }

        function test_escape_cancels() {
            arm();
            keyClick(Qt.Key_Escape);
            compare(JSON.stringify(capture.calls), '["begin","end cancel"]');
            compare(JSON.stringify(root.events), "[]");
            compare(JSON.stringify(field.caps), '["SUPER","M"]');
        }

        function test_a_focus_loss_cancels() {
            arm();
            after.forceActiveFocus(Qt.TabFocusReason);
            compare(JSON.stringify(capture.calls), '["begin","end focus"]');
            compare(JSON.stringify(root.events), "[]");
        }

        function test_an_unnamed_key_keeps_capturing() {
            arm();
            keyClick(Qt.Key_Exclam, Qt.ShiftModifier);
            compare(field.capturing, true);
            verify(field.notice !== "");
            compare(JSON.stringify(root.events), "[]");
        }

        function test_a_capture_owned_elsewhere_ends_the_field() {
            arm();
            capture.holder = before;
            compare(field.capturing, false);
            keyClick(Qt.Key_K, Qt.MetaModifier);
            compare(JSON.stringify(root.events), "[]");
        }

        function test_no_capture_asks_nothing() {
            field.capture = null;
            field.forceActiveFocus(Qt.TabFocusReason);
            keyClick(Qt.Key_Return);
            compare(field.capturing, false);
            compare(JSON.stringify(capture.calls), "[]");
        }

        function test_typing_sends_the_text_and_escape_goes_back() {
            press(field, "Type the keys");
            compare(field.typing, true);
            for (const c of "SUPER+K") keyClick(c);
            keyClick(Qt.Key_Return);
            compare(field.typing, false);
            compare(JSON.stringify(root.events), '["typed SUPER+K"]');
            verify(box(field).activeFocus);
            press(field, "Type the keys");
            keyClick("X");
            keyClick(Qt.Key_Escape);
            compare(field.typing, false);
            compare(JSON.stringify(root.events), '["typed SUPER+K"]');
        }

        function test_typing_ends_a_capture() {
            arm();
            press(field, "Type the keys");
            compare(field.capturing, false);
            compare(capture.calls.length, 2);
            compare(field.typing, true);
        }

        function test_clear_unbinds() {
            press(field, "Unbind");
            compare(JSON.stringify(root.events), '["cleared"]');
        }

        function test_a_conflict_is_a_hint_that_blocks_nothing() {
            field.conflict = "Also bound to Launcher (toggle).";
            const hint = descendant(field, item => item.text === field.conflict && item.visible);
            verify(hint !== null);
            compare(Qt.colorEqual(hint.color, Theme.color.warning), true);
            arm();
            keyClick(Qt.Key_Space, Qt.MetaModifier);
            compare(JSON.stringify(root.events), '["committed SUPER+SPACE"]');
        }
    }
}
