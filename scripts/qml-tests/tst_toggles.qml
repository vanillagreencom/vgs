import QtQuick
import QtTest
import qs.Commons
import qs.Ui
import qs.Unit

// Switch, Checkbox and Radio: a click and Space toggle `checked`, the
// indicator follows it, radios under one parent are exclusive, and a theme
// change moves the indicator's colours and geometry.
Item {
    id: root
    width: 300
    height: 200

    Switch { id: sw; text: "Notifications" }
    Switch { id: bare; y: 20 }
    Switch { id: mirrored; y: 40; LayoutMirroring.enabled: true }
    Checkbox { id: box; text: "Verified"; y: 40 }
    Column {
        y: 80
        Radio { id: one; text: "One"; checked: true }
        Radio { id: two; text: "Two" }
    }

    TestCase {
        name: "toggles"
        when: windowShown

        function init() { UnitTheme.reset(); sw.checked = false; box.checked = false; one.checked = true; }

        function knob() { return sw.indicator.children[0]; }

        function test_switch_click_slides_the_knob() {
            tryCompare(sw.indicator, "color", Qt.color(Theme.toggle.off));
            tryCompare(knob(), "x", Theme.toggle.inset);
            mouseClick(sw.indicator);
            compare(sw.checked, true);
            tryCompare(sw.indicator, "color", Qt.color(Theme.toggle.on));
            tryCompare(knob(), "x", sw.indicator.width - knob().width - Theme.toggle.inset);
            compare(String(knob().color), String(Qt.color(Theme.toggle.knobOn)));
        }

        function test_toggle_widths_count_the_gap_once() {
            compare(bare.width, Theme.toggle.width);
            compare(sw.width, sw.contentItem.implicitWidth);
            compare(box.width, box.contentItem.implicitWidth);
            compare(one.width, one.contentItem.implicitWidth);
        }

        function test_knob_follows_the_drag_and_the_mirror() {
            const inset = Theme.toggle.inset;
            compare(mirrored.indicator.children[0].x, mirrored.indicator.width - mirrored.indicator.children[0].width - inset);
            mousePress(sw.indicator, inset + 2, sw.indicator.height / 2);
            mouseMove(sw.indicator, sw.indicator.width - inset - 2, sw.indicator.height / 2);
            verify(sw.position > 0.5, "a drag moves the position: " + sw.position);
            compare(knob().x, inset + sw.visualPosition * (sw.indicator.width - knob().width - 2 * inset));
            mouseRelease(sw.indicator, sw.indicator.width - inset - 2, sw.indicator.height / 2);
            compare(sw.checked, true);
        }

        function test_switch_space_toggles() {
            sw.forceActiveFocus();
            keyClick(Qt.Key_Space);
            compare(sw.checked, true);
            keyClick(Qt.Key_Space);
            compare(sw.checked, false);
        }

        function test_checkbox_draws_the_mark_when_checked() {
            const mark = box.indicator.children[0];
            compare(mark.visible, false);
            mouseClick(box.indicator);
            compare(box.checked, true);
            compare(mark.visible, true);
            tryCompare(box.indicator, "color", Qt.color(Theme.checkbox.checked));
            box.forceActiveFocus();
            keyClick(Qt.Key_Space);
            compare(box.checked, false);
        }

        function test_radios_are_exclusive() {
            compare(one.checked, true);
            mouseClick(two.indicator);
            compare(two.checked, true);
            compare(one.checked, false);
            compare(two.indicator.children[0].visible, true);
            compare(one.indicator.children[0].visible, false);
        }

        function test_theme_change_moves_the_indicators() {
            compare(UnitTheme.override({ toggle: { width: 50, on: "#00ff00" }, checkbox: { size: 24 }, radio: { size: 24, dot: 10 } }), "ok");
            compare(sw.indicator.width, 50);
            sw.checked = true;
            tryCompare(sw.indicator, "color", Qt.color("#00ff00"));
            compare(box.indicator.width, 24);
            compare(one.indicator.width, 24);
            compare(one.indicator.children[0].width, 10);
        }
    }
}
