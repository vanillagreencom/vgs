import QtQuick
import QtTest
import qs.Commons
import qs.Core
import qs.Ui
import qs.Unit

// ShortcutField: a click, Enter, Return or Space asks the capture to begin;
// while it holds the field, held modifiers show as caps, the first other
// key commits the combo the judge names unless it is the key in effect,
// Escape, Tab and a focus loss end it, a held key's repeat does nothing, an
// unnamed key and a bare text key keep it with a notice, a refused
// pass-through and a timeout say so, the caps clear a rounded corner as a
// text field does; the keyboard button types a
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
        property bool failed: false
        property var ended: ({ item: null, reason: "" })
        readonly property int timeoutMs: 10000
        function begin(item) { calls = calls.concat(["begin"]); holder = item; return "ok"; }
        function end(item, reason) { if (item !== holder) return; calls = calls.concat(["end " + reason]); ended = { item: item, reason: reason }; holder = null; }
        function keyFor(key, modifiers) { return PluginLogic.capturedKey(key, modifiers); }
    }

    property var events: []
    // Escapes the fields leave to their surface, as a page's back step reads them.
    property int escapes: 0

    Column {
        width: parent.width
        spacing: Theme.space.md
        Keys.onEscapePressed: root.escapes += 1
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
            capture.failed = false;
            capture.ended = { item: null, reason: "" };
            root.events = [];
            root.escapes = 0;
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
            box(field).forceActiveFocus(Qt.TabFocusReason);
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
            keyClick(Qt.Key_End);
            keyClick("X");
            keyClick(Qt.Key_Escape);
            compare(field.typing, true, "the first Escape restores the key in effect");
            compare(descendant(field, item => item.escapeReverts === true).text, field.key);
            keyClick(Qt.Key_Escape);
            compare(field.typing, false, "the next Escape goes back to the box");
            verify(box(field).activeFocus);
            compare(JSON.stringify(root.events), '["typed SUPER+K"]');
        }

        function test_a_focus_preview_draws_the_ring() {
            const ring = descendant(box(field), item => item.ringColor !== undefined);
            compare(ring.visible, false);
            field.focusPreview = true;
            compare(ring.visible, true);
            field.focusPreview = false;
        }

        function test_escape_on_the_idle_box_goes_on_up() {
            box(field).forceActiveFocus(Qt.TabFocusReason);
            keyClick(Qt.Key_Escape);
            compare(root.escapes, 1);
        }

        function test_typing_ends_a_capture() {
            arm();
            press(field, "Type the keys");
            compare(field.capturing, false);
            compare(JSON.stringify(capture.calls), '["begin","end focus"]');
            compare(field.typing, true);
        }

        function test_clear_unbinds() {
            press(field, "Unbind");
            compare(JSON.stringify(root.events), '["cleared"]');
        }

        function test_the_key_in_effect_changes_nothing() {
            arm();
            keyClick(Qt.Key_M, Qt.MetaModifier);
            compare(JSON.stringify(capture.calls), '["begin","end commit"]');
            compare(JSON.stringify(root.events), "[]");
        }

        function test_a_bare_text_key_keeps_capturing() {
            for (const row of [{ key: Qt.Key_T, modifiers: Qt.NoModifier }, { key: Qt.Key_T, modifiers: Qt.ShiftModifier }, { key: Qt.Key_Space, modifiers: Qt.NoModifier }, { key: Qt.Key_Backspace, modifiers: Qt.NoModifier }]) {
                capture.holder = null;
                field.notice = "";
                arm();
                keyClick(row.key, row.modifiers);
                compare(field.capturing, true);
                verify(field.notice.indexOf("Hold Super, Ctrl or Alt") === 0, field.notice);
                compare(JSON.stringify(root.events), "[]");
            }
        }

        function test_tab_and_shift_tab_end_the_capture_and_move_on() {
            const b = box(field);
            const next = b.nextItemInFocusChain(true);
            const previous = b.nextItemInFocusChain(false);
            arm();
            keyClick(Qt.Key_Tab);
            compare(JSON.stringify(capture.calls), '["begin","end tab"]');
            verify(next.activeFocus, "Tab moves to the next item in the focus chain");
            capture.calls = [];
            arm();
            keyClick(Qt.Key_Backtab, Qt.ShiftModifier);
            compare(JSON.stringify(capture.calls), '["begin","end tab"]');
            verify(previous.activeFocus, "Shift+Tab moves to the item before");
            compare(JSON.stringify(root.events), "[]");
        }

        function test_a_combo_with_tab_is_captured() {
            arm();
            keyClick(Qt.Key_Tab, Qt.AltModifier);
            compare(JSON.stringify(root.events), '["committed ALT+TAB"]');
        }

        function test_a_held_key_repeat_does_nothing() {
            arm();
            const repeat = { key: Qt.Key_Return, modifiers: Qt.NoModifier, isAutoRepeat: true, accepted: false };
            field.pressed(repeat);
            compare(repeat.accepted, true);
            compare(field.capturing, true);
            compare(field.notice, "");
            compare(JSON.stringify(root.events), "[]");
        }

        function test_a_refused_pass_through_is_named() {
            arm();
            capture.failed = true;
            verify(field.hint.indexOf("Hyprland's own shortcuts still run") === 0, field.hint);
            const shown = descendant(field, item => item.text === field.hint && item.visible);
            verify(shown !== null);
            compare(Qt.colorEqual(shown.color, Theme.color.danger), true);
            keyClick(Qt.Key_Escape);
            compare(field.hint, "");
        }

        function test_a_timeout_is_named() {
            arm();
            capture.ended = { item: field, reason: "timeout" };
            capture.holder = null;
            compare(field.notice, "Listening stopped after 10 s. Press Return or click the field to listen again.");
            arm();
            compare(field.notice, "");
            capture.ended = { item: readOnly, reason: "timeout" };
            capture.holder = null;
            compare(field.notice, "");
        }

        // Under a pill theme with a small pad, the first cap starts where a
        // text field's text would: past the pad, by Theme.controlPadding.
        function test_the_caps_clear_a_rounded_corner() {
            compare(UnitTheme.override({ radius: { sm: 4096 }, textField: { paddingX: 4 } }), "ok");
            const b = box(field);
            tryVerify(() => b.leftPadding > 4, 1000, "padding " + b.leftPadding);
            compare(b.leftPadding, field.sidePadding);
            compare(b.rightPadding, field.sidePadding);
            const cap = descendant(b, item => item.text === "Super" && item.radius !== undefined);
            compare(cap.mapToItem(b, 0, 0).x, b.leftPadding);
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
