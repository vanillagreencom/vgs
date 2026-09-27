import QtQuick
import QtTest
import qs.Commons
import qs.Ui
import qs.Unit

// SegmentedControl: a click chooses a segment, the arrow keys move the
// choice, `activated` fires for a change the user made and not for the
// same segment again, and the chosen segment draws the selected fill.
Item {
    id: root
    width: 300
    height: 100

    SegmentedControl { id: control; model: ["Day", "Week", "Month"] }
    SignalSpy { id: activations; target: control; signalName: "activated" }

    TestCase {
        name: "segmented"
        when: windowShown

        function init() { UnitTheme.reset(); control.currentIndex = 0; activations.clear(); }

        function segment(index) { return control.children[0].children[index]; }

        function test_click_chooses() {
            compare(control.model.length, 3);
            mouseClick(segment(1));
            compare(control.currentIndex, 1);
            compare(activations.count, 1);
            compare(activations.signalArguments[0][0], 1);
            mouseClick(segment(1));
            compare(activations.count, 1);
            tryCompare(segment(1).background, "color", Qt.color(Theme.segmented.selected));
            compare(String(segment(0).background.color), "#00000000");
        }

        function test_keys_move_the_choice() {
            const ring = control.children[control.children.length - 1];
            compare(ring.visible, false);
            control.forceActiveFocus(Qt.TabFocusReason);
            compare(ring.visible, true);
            keyClick(Qt.Key_Right);
            compare(control.currentIndex, 1);
            keyClick(Qt.Key_Right);
            keyClick(Qt.Key_Right);
            compare(control.currentIndex, 2);
            keyClick(Qt.Key_Left);
            compare(control.currentIndex, 1);
            compare(activations.count, 3);
            control.focus = false;
            compare(ring.visible, false);
        }

        function test_theme_change_moves_the_segments() {
            compare(UnitTheme.override({ segmented: { height: 40, selected: "#00ff00" } }), "ok");
            compare(control.height, 40);
            tryCompare(segment(0).background, "color", Qt.color("#00ff00"));
        }
    }
}
