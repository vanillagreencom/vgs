import QtQuick
import QtTest
import qs.Commons
import qs.Ui
import qs.Unit

// DeviceRow: a row with a state line is the two-line height, one without
// the one-line height; the badge, the actions and the overflow button end
// the row in that order; the battery badge reads the percentage in the
// tone its thresholds name, and a level badge the caller's text and tone;
// the row takes focus and draws its ring for keyboard focus; Enter, Return
// and Space emit `clicked`; Shift+F10 and the Menu key open the overflow
// menu, the overflow button does too, and a row without entries hides the
// button and passes the keys on; under a ListCursor the cursor draws the
// highlight.
Item {
    id: root
    width: 480
    height: 400

    property int passed: 0

    Button { id: before; text: "Scan" }
    Item {
        id: list
        y: 40
        width: 420
        height: column.height
        // The keys a row passes on; QtTest presses Shift on its own first.
        Keys.onPressed: event => { if (event.key !== Qt.Key_Shift) root.passed += 1; event.accepted = true; }

        ListCursor { id: cursor }
        Column {
            id: column
            width: parent.width
            DeviceRow {
                id: headset
                width: parent.width
                cursor: cursor
                text: "Headset"
                secondary: "Connected"
                iconName: "headphones"
                battery: 0.5
                actions: [ Button { id: disconnect; text: "Disconnect"; size: "sm" } ]
                menuEntries: [
                    MenuItem { text: "Rename" },
                    MenuItem { text: "Forget" }
                ]
            }
            DeviceRow {
                id: mouse
                width: parent.width
                cursor: cursor
                text: "Mouse"
                iconName: "mouse"
                badge: "Strong"
                badgeTone: "success"
                badgeIcon: "wifi"
            }
        }
    }
    SignalSpy { id: activations; target: headset; signalName: "clicked" }

    TestCase {
        name: "devicerow"
        when: windowShown

        function trailing(row) { return row.contentItem.children[2].children; }
        function badgeOf(row) { return trailing(row)[0]; }
        function menuOf(row) { return trailing(row)[2].children.find(child => child.triggerCurrent !== undefined); }

        function init() {
            UnitTheme.reset();
            activations.clear();
            root.passed = 0;
            headset.battery = 0.5;
            headset.highlighted = false;
            headset.focus = false;
            mouse.focus = false;
            const menu = menuOf(headset);
            if (menu.opened) menu.close();
        }

        function test_rows_keep_the_list_rhythm() {
            compare(headset.height, Theme.listItem.twoLineHeight);
            compare(mouse.height, Theme.listItem.height);
        }

        function test_the_badge_actions_and_overflow_end_the_row() {
            const items = trailing(headset);
            const badge = items[0], actions = items[1], more = items[2];
            verify(badge.visible && more.visible, "the badge or the overflow button is hidden");
            verify(badge.x < actions.x && actions.x < more.x, "the trailing items are out of order");
            compare(disconnect.parent, actions);
            const end = more.mapToItem(headset, more.width, 0).x;
            compare(end, headset.width - headset.rightPadding);
            compare(more.label, "More actions");
            for (const item of [badge, actions, more])
                fuzzyCompare(item.mapToItem(headset, 0, item.height / 2).y, headset.height / 2, 1);
        }

        function test_battery_reads_its_tone_from_the_thresholds() {
            const badge = badgeOf(headset);
            compare(badge.text, "50%");
            compare(badge.tone, "neutral");
            headset.battery = Theme.deviceRow.battery.warning;
            compare(badge.tone, "warning");
            compare(badge.iconName, "battery-low");
            headset.battery = Theme.deviceRow.battery.danger;
            compare(badge.tone, "danger");
            compare(badge.iconName, "battery-warning");
            headset.battery = 1.4;
            compare(badge.text, "100%");
            compare(badge.tone, "neutral");
            headset.battery = NaN;
            verify(!badge.visible, "a battery that is not a number draws a badge");
            compare(UnitTheme.override({ deviceRow: { battery: { warning: 0.6 } } }), "ok");
            headset.battery = 0.5;
            compare(badge.tone, "warning");
        }

        function test_a_level_badge_reads_the_callers_text_and_tone() {
            const badge = badgeOf(mouse);
            verify(badge.visible, "the level badge is hidden");
            compare(badge.text, "Strong");
            compare(badge.tone, "success");
            compare(badge.iconName, "wifi");
            verify(!trailing(mouse)[2].visible, "a row without entries draws its overflow button");
        }

        function test_keyboard_focus_draws_the_ring() {
            const ring = headset.background.children[0];
            verify(!ring.visible, "the ring draws without focus");
            before.forceActiveFocus(Qt.TabFocusReason);
            keyClick(Qt.Key_Tab);
            compare(headset.activeFocus, true, "Tab passes the row by");
            tryCompare(headset, "visualFocus", true);
            compare(ring.visible, true);
            headset.focus = false;
            tryCompare(ring, "visible", false);
        }

        function test_enter_return_and_space_activate() {
            headset.forceActiveFocus(Qt.TabFocusReason);
            keyClick(Qt.Key_Return);
            compare(activations.count, 1);
            keyClick(Qt.Key_Enter);
            compare(activations.count, 2);
            keyClick(Qt.Key_Space);
            compare(activations.count, 3);
            keyClick(Qt.Key_Down);
            compare(root.passed, 1, "an arrow does not reach the list");
            compare(activations.count, 3);
        }

        // A popup window shown before may still hold the window focus;
        // the keys go to the test window.
        function focusRow(row) {
            root.Window.window.requestActivate();
            row.forceActiveFocus(Qt.TabFocusReason);
            tryCompare(row, "activeFocus", true);
        }

        function test_the_menu_keys_open_the_overflow_menu() {
            const menu = menuOf(headset);
            const keys = [[Qt.Key_F10, Qt.ShiftModifier], [Qt.Key_Menu, Qt.NoModifier]];
            for (const key of keys) {
                focusRow(headset);
                keyClick(key[0], key[1]);
                compare(menu.opened, true, "key " + key[0] + " leaves the menu closed");
                compare(menu.items().map(item => item.text), ["Rename", "Forget"]);
                menu.close();
            }
            compare(root.passed, 0);
            focusRow(mouse);
            keyClick(Qt.Key_Menu);
            compare(root.passed, 1, "a row without entries keeps the menu key");
        }

        function test_the_overflow_button_opens_the_menu() {
            const menu = menuOf(headset);
            mouseClick(trailing(headset)[2]);
            compare(menu.opened, true);
            compare(activations.count, 0, "the overflow button activates the row");
            menu.close();
        }

        function test_the_cursor_draws_the_highlight() {
            headset.highlighted = true;
            tryCompare(cursor, "target", headset);
            compare(String(headset.background.color), String(Qt.color("transparent")));
        }
    }
}
