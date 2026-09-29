import QtQuick
import QtTest
import qs.Commons
import qs.Ui
import qs.Unit

// Button: the variant's fill and text, the hover and pressed fills, a
// click by pointer and by keyboard, the checked fill, the disabled opacity,
// the focus ring for keyboard focus, an unknown variant, and a theme
// change that moves the fill and keeps the text readable.
Item {
    id: root
    width: 300
    height: 260

    Button { id: primary; text: "Publish" }
    Button { id: secondary; text: "Browse"; variant: "secondary"; y: 40 }
    ToggleButton { id: toggle; text: "Pin"; y: 80 }
    Button { id: off; text: "Off"; enabled: false; y: 120 }
    IconButton { id: iconOnly; iconName: "x"; label: "Close"; y: 160 }
    IconButton { id: checkedIcon; iconName: "check"; label: "Checked"; y: 200; checkable: true; checked: true }
    IconButton { id: disabledIcon; iconName: "ban"; label: "Disabled"; y: 230; enabled: false }
    SignalSpy { id: clicks; target: primary; signalName: "clicked" }

    TestCase {
        name: "button"
        when: windowShown

        function init() { UnitTheme.reset(); clicks.clear(); primary.focus = false; }

        function test_variant_draws_its_tokens() {
            tryCompare(primary.background, "color", Qt.color(Theme.button.variant.primary.background));
            compare(String(primary.foreground), String(Qt.color(Theme.button.variant.primary.foreground)));
            tryCompare(secondary.background, "color", Qt.color(Theme.button.variant.secondary.background));
            compare(primary.height, Theme.size.control.md);
            compare(primary.background.radius, Theme.button.radius);
        }

        function test_hover_and_press_move_the_fill() {
            mouseMove(primary, primary.width / 2, primary.height / 2);
            tryCompare(primary, "hovered", true);
            tryCompare(primary.background, "color", Qt.color(Theme.button.variant.primary.hover));
            mousePress(primary, primary.width / 2, primary.height / 2);
            tryCompare(primary.background, "color", Qt.color(Theme.button.variant.primary.pressed));
            mouseRelease(primary, primary.width / 2, primary.height / 2);
            compare(clicks.count, 1);
            mouseMove(root, 0, root.height - 1);
            tryCompare(primary, "hovered", false);
        }

        function test_keyboard_activates_and_shows_the_ring() {
            primary.forceActiveFocus(Qt.TabFocusReason);
            tryCompare(primary, "visualFocus", true);
            const ring = primary.background.children[primary.background.children.length - 1];
            compare(ring.visible, true);
            keyClick(Qt.Key_Space);
            compare(clicks.count, 1);
            primary.focus = false;
            tryCompare(ring, "visible", false);
        }

        function test_checkable_draws_the_checked_fill() {
            compare(toggle.checked, false);
            mouseClick(toggle);
            compare(toggle.checked, true);
            tryCompare(toggle.background, "color", Qt.color(Theme.button.checked.background));
            mouseClick(toggle);
            compare(toggle.checked, false);
        }

        function test_disabled_fades() {
            fuzzyCompare(off.opacity, Theme.opacity.disabled, 0.001);
            compare(primary.opacity, 1);
        }

        // expected-log: Button: no variant named "loud" -- the test names an unknown variant on purpose
        function test_unknown_variant_is_logged_and_drawn_primary() {
            const button = Qt.createQmlObject("import qs.Ui\nButton { variant: \"loud\"; text: \"x\" }", root);
            compare(String(button.fill), String(Qt.color(Theme.button.variant.primary.background)));
            button.destroy();
        }

        // expected-log: IconButton: label is required, icon="x" -- the test builds an icon button with no label on purpose
        function test_icon_button_is_square_and_named() {
            compare(iconOnly.width, iconOnly.height);
            fuzzyCompare(iconOnly.contentItem.y, (iconOnly.height - iconOnly.contentItem.height) / 2, 1);
            compare(iconOnly.Accessible.name, "Close");
            const unnamed = Qt.createQmlObject("import qs.Ui\nIconButton { iconName: \"x\" }", root);
            unnamed.destroy();
        }

        function test_icon_button_opacity_states() {
            fuzzyCompare(iconOnly.contentItem.opacity, Theme.iconButton.restOpacity, 0.001);
            mouseMove(iconOnly, iconOnly.width / 2, iconOnly.height / 2);
            tryCompare(iconOnly.contentItem, "opacity", 1);
            mousePress(iconOnly, iconOnly.width / 2, iconOnly.height / 2);
            tryCompare(iconOnly.contentItem, "opacity", 1);
            mouseRelease(iconOnly, iconOnly.width / 2, iconOnly.height / 2);
            mouseMove(root, 0, root.height - 1);
            checkedIcon.forceActiveFocus(Qt.TabFocusReason);
            tryCompare(checkedIcon.contentItem, "opacity", 1);
            compare(disabledIcon.opacity, Theme.opacity.disabled);
            fuzzyCompare(disabledIcon.contentItem.opacity, 1, 0.001);
            compare(UnitTheme.override({ iconButton: { restOpacity: 0.25 } }), "ok");
            iconOnly.focus = false;
            mouseMove(root, 0, root.height - 1);
            tryCompare(iconOnly.contentItem, "opacity", 0.25);
        }

        function test_theme_change_keeps_the_text_readable() {
            compare(UnitTheme.override({ button: { variant: { primary: { background: "#ffffff" } } } }), "ok");
            tryCompare(primary.background, "color", Qt.color("#ffffff"));
            compare(String(primary.foreground), "#000000");
            compare(UnitTheme.override({ button: { variant: { primary: { background: "#000000" } } } }), "ok");
            compare(String(primary.foreground), "#ffffff");
        }
    }
}
