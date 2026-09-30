import QtQuick
import QtTest
import qs.Commons
import qs.Ui
import qs.Unit

// EmptyState: a box three two-line rows tall, 3 * 56 = 168, at any width;
// the icon, the line and the action centred in it, `stack.group`, 12,
// apart; the icon and the action drawn only while named; and a press on
// the action emitting `activated`. Expected values are worked by hand from
// the defaults in Tokens.js, never read from Theme.
Item {
    id: root
    width: 400
    height: 400

    EmptyState {
        id: full
        width: 300
        iconName: "search-x"
        text: "No plugin matches"
        actionText: "Clear search"
    }
    EmptyState {
        id: bare
        y: 200
        width: 300
        text: "Loading themes"
    }
    SignalSpy { id: spy; target: full; signalName: "activated" }

    TestCase {
        name: "emptyState"
        when: windowShown

        function init() {
            UnitTheme.reset();
            spy.clear();
        }

        function parts(state) { return state.children[0].children; }

        function test_the_box_is_three_two_line_rows_tall() {
            compare(full.height, 168);
            compare(bare.height, 168);
        }

        // The column is centred in the box and across it, its parts 12
        // apart, the line as wide as the box.
        function test_the_parts_are_centred_a_group_apart() {
            const column = full.children[0];
            const [icon, label, button] = parts(full);
            verify(icon.visible && label.visible && button.visible, "every named part is drawn");
            fuzzyCompare(column.y + column.height / 2, 84, 0.5);
            compare(label.y, icon.y + icon.height + 12);
            compare(button.y, label.y + label.height + 12);
            fuzzyCompare(icon.x + icon.width / 2, 150, 0.5);
            fuzzyCompare(button.x + button.width / 2, 150, 0.5);
            compare(label.width, 300);
        }

        function test_an_unnamed_icon_and_action_are_not_drawn() {
            const [icon, label, button] = parts(bare);
            verify(!icon.visible, "no icon is drawn");
            verify(label.visible, "the line is drawn");
            verify(!button.visible, "no action is drawn");
        }

        function test_a_press_on_the_action_emits_activated() {
            mouseClick(parts(full)[2]);
            compare(spy.count, 1);
        }
    }
}
