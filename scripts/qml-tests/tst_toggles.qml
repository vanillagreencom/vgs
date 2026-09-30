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
    height: 240

    Switch { id: sw; text: "Notifications" }
    Switch { id: bare; y: 30 }
    Switch { id: small; size: "sm"; y: 60 }
    Switch { id: mirrored; y: 90; LayoutMirroring.enabled: true }
    Checkbox { id: box; text: "Verified"; y: 120 }
    Column {
        y: 160
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
            mouseMove(root, root.width - 1, root.height - 1);
            tryCompare(sw.indicator, "color", Qt.color(Theme.toggle.on));
            tryCompare(knob(), "x", sw.indicator.width - knob().width - Theme.toggle.inset);
            compare(String(knob().color), String(Qt.color(Theme.toggle.knobOn)));
        }

        function test_toggle_widths_count_the_gap_once() {
            compare(bare.width, Theme.toggle.size.md.width);
            compare(sw.width, sw.contentItem.implicitWidth);
            compare(box.width, box.contentItem.implicitWidth);
            compare(one.width, one.contentItem.implicitWidth);
        }

        function test_switch_sizes_set_track_and_knob_travel() {
            compare(sw.indicator.width, Theme.toggle.size.md.width);
            compare(sw.indicator.height, Theme.toggle.size.md.height);
            compare(small.indicator.width, Theme.toggle.size.sm.width);
            compare(small.indicator.height, Theme.toggle.size.sm.height);
            compare(small.indicator.children[0].width, Theme.toggle.size.sm.height - 2 * Theme.toggle.inset);
            small.checked = true;
            tryCompare(small.indicator.children[0], "x", small.indicator.width - small.indicator.children[0].width - Theme.toggle.inset);
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

        // Hover and press differ from rest on each indicator.
        function test_indicators_draw_hover_and_press() {
            sw.checked = false;
            mouseMove(sw.indicator, 4, sw.indicator.height / 2);
            tryCompare(sw.indicator, "color", Qt.color(Theme.toggle.offHover));
            const rest = knob().width;
            mousePress(sw.indicator, 4, sw.indicator.height / 2);
            tryVerify(() => knob().width > rest, 1000, "a press widens the knob");
            mouseRelease(sw.indicator, 4, sw.indicator.height / 2);
            sw.checked = false;
            mouseMove(box.indicator, 4, 4);
            tryCompare(box.indicator.border, "color", Qt.color(Theme.checkbox.hoverBorder));
            mousePress(box.indicator, 4, 4);
            tryCompare(box.indicator, "color", Qt.color(Theme.checkbox.pressed));
            mouseRelease(box.indicator, 4, 4);
            box.checked = false;
            mouseMove(two.indicator, 4, 4);
            tryCompare(two.indicator.border, "color", Qt.color(Theme.radio.hoverBorder));
            mouseMove(root, root.width - 1, root.height - 1);
            tryCompare(box.indicator.border, "color", Qt.color(Theme.checkbox.borderColor));
        }

        // Each indicator centres on its label's capital centre on a whole
        // pixel, and a compact control keeps a `size.control.sm` input area.
        function test_indicators_centre_on_the_label_and_keep_an_input_area() {
            for (const control of [sw, box, one]) {
                const label = control.contentItem;
                const centre = control.indicator.y + control.indicator.height / 2;
                compare(control.indicator.y, Math.round(control.indicator.y), control.text + " indicator y");
                verify(Math.abs(centre - (label.lineTop + label.capCentre)) <= 0.5, control.text + ": indicator centre " + centre + ", capital centre " + (label.lineTop + label.capCentre));
                compare(label.role, "item");
            }
            compare(small.height, Theme.size.control.sm);
            verify(small.indicator.height < small.height, "the compact track is smaller than its input area");
            const was = small.checked;
            mouseClick(small, small.indicator.width / 2, small.height - 1);
            compare(small.checked, !was, "a click beside the compact track toggles it");
            small.checked = was;
            mouseMove(root, root.width - 1, root.height - 1);
        }

        function test_theme_change_moves_the_indicators() {
            compare(UnitTheme.override({ toggle: { size: { md: { width: 50 }, sm: { width: 32, height: 18 } }, on: "#00ff00" }, checkbox: { size: 24 }, radio: { size: 24, dot: 10 } }), "ok");
            compare(sw.indicator.width, 50);
            compare(small.indicator.width, 32);
            compare(small.indicator.height, 18);
            sw.checked = true;
            mouseMove(root, root.width - 1, root.height - 1);
            tryCompare(sw.indicator, "color", Qt.color("#00ff00"));
            compare(box.indicator.width, 24);
            compare(one.indicator.width, 24);
            compare(one.indicator.children[0].width, 10);
        }
    }
}
