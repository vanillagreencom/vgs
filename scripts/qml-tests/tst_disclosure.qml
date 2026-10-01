import QtQuick
import QtTest
import qs.Commons
import qs.Ui
import qs.Unit

// Disclosure: it starts with its content hidden and adds no height for it;
// a click on its row, or Space on the focused row, shows the content under
// the row and turns the chevron up, and a second click hides it again; a
// click on a control among its trailing items reaches that control and
// toggles nothing; a row that cannot expand draws no chevron, keeps its room, and a click
// on it shows nothing.
Item {
    id: root
    width: 400
    height: 400

    Disclosure {
        id: disclosure
        width: 300
        text: "System"
        secondary: "2 updates"
        iconName: "package"
        trailing: [
            Button { id: action; text: "Update"; size: "sm"; anchors.verticalCenter: parent.verticalCenter }
        ]
        Label { id: line; role: "code"; text: "linux 6.1 → 6.2" }
    }
    SignalSpy { id: actions; target: action; signalName: "clicked" }

    TestCase {
        name: "disclosure"
        when: windowShown

        // The row is the first child; the chevron is the last item its
        // trailing row holds.
        function row() { return disclosure.children[0]; }
        function chevron() {
            const items = row().contentItem.children[2].children;
            return items[items.length - 1];
        }

        function init() {
            UnitTheme.reset();
            disclosure.expanded = false;
            disclosure.expandable = true;
            actions.clear();
        }

        function test_starts_hidden() {
            compare(disclosure.expanded, false);
            verify(!line.visible, "the content shows before a click");
            tryCompare(disclosure, "height", row().height);
            compare(chevron().name, "chevron-down");
        }

        function test_a_click_on_the_row_toggles_the_content() {
            mouseClick(row(), 20, row().height / 2);
            compare(disclosure.expanded, true);
            verify(line.visible, "the content is hidden after a click");
            tryCompare(disclosure, "height", row().height + line.height);
            compare(chevron().name, "chevron-up");
            verify(line.mapToItem(disclosure, 0, 0).y >= row().height, "the content sits over the row");
            mouseClick(row(), 20, row().height / 2);
            compare(disclosure.expanded, false);
            tryCompare(disclosure, "height", row().height);
        }

        function test_space_toggles_the_content() {
            row().forceActiveFocus();
            keyClick(Qt.Key_Space);
            compare(disclosure.expanded, true);
        }

        function test_return_enter_and_arrows_drive_the_disclosure() {
            compare(disclosure.focusItem, row());
            row().forceActiveFocus();
            keyClick(Qt.Key_Return);
            compare(disclosure.expanded, true);
            keyClick(Qt.Key_Left);
            compare(disclosure.expanded, false);
            keyClick(Qt.Key_Right);
            compare(disclosure.expanded, true);
            disclosure.expanded = false;
            keyClick(Qt.Key_Enter);
            compare(disclosure.expanded, true);
        }

        function test_a_row_that_cannot_expand_stays_closed() {
            const trailingWidth = row().contentItem.children[2].width;
            disclosure.expandable = false;
            compare(chevron().opacity, 0, "a row that cannot expand draws its chevron");
            // The chevron keeps its room, so the trailing items stay put.
            compare(row().contentItem.children[2].width, trailingWidth);
            mouseClick(row(), 20, row().height / 2);
            compare(disclosure.expanded, false);
            verify(!line.visible, "a row that cannot expand shows its content");
        }

        function test_a_trailing_control_takes_its_own_click() {
            mouseClick(action);
            compare(actions.count, 1);
            compare(disclosure.expanded, false);
        }
    }
}
