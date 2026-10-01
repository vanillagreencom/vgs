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
    height: 320

    Button { id: primary; text: "Publish" }
    Button { id: secondary; text: "Browse"; variant: "secondary"; y: 40 }
    ToggleButton { id: toggle; text: "Pin"; y: 80 }
    Button { id: off; text: "Off"; enabled: false; y: 120 }
    IconButton { id: iconOnly; iconName: "x"; label: "Close"; y: 160 }
    IconButton { id: focusIcon; iconName: "scan-eye"; label: "Focused"; y: 200 }
    IconButton { id: pressedIcon; iconName: "mouse-pointer-click"; label: "Pressed"; y: 230; down: true }
    IconButton { id: checkedIcon; iconName: "check"; label: "Checked"; y: 260; checkable: true; checked: true }
    IconButton { id: disabledIcon; iconName: "ban"; label: "Disabled"; y: 290; enabled: false }
    Button { id: small; text: "Small"; iconName: "check"; size: "sm"; y: 320 }
    Button { id: large; text: "Large"; iconName: "check"; size: "lg"; y: 350 }
    IconButton { id: smallIcon; iconName: "chevron-left"; label: "Back"; size: "sm"; y: 400 }
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
            keyClick(Qt.Key_Return);
            compare(clicks.count, 2);
            primary.focusPreview = true;
            primary.focus = false;
            compare(ring.visible, true);
            primary.focusPreview = false;
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

        // Each size draws its own height, padding, gap and icon, Radix
        // Themes' button sizes 1, 2 and 3 on the 4 px unit.
        function test_each_size_draws_its_rhythm_data() {
            return [
                { tag: "sm", height: 24, pad: 8, gap: 4, icon: 14 },
                { tag: "md", height: 32, pad: 12, gap: 8, icon: 16 },
                { tag: "lg", height: 40, pad: 16, gap: 12, icon: 16 }
            ];
        }
        function test_each_size_draws_its_rhythm(data) {
            const button = data.tag === "sm" ? small : data.tag === "lg" ? large : Qt.createQmlObject("import qs.Ui\nButton { text: \"Medium\"; iconName: \"check\" }", root);
            tryCompare(button, "height", data.height);
            compare(button.leftPadding, data.pad);
            compare(button.rightPadding, data.pad);
            const row = button.contentItem;
            compare(row.children[0].size, data.icon);
            tryVerify(() => row.children[1].x - (row.children[0].x + row.children[0].width) === data.gap, 1000, "gap " + (row.children[1].x - row.children[0].width));
            if (data.tag === "md") button.destroy();
        }

        function test_checked_button_shows_hover_and_press() {
            mouseClick(toggle);
            compare(toggle.checked, true);
            mouseMove(toggle, toggle.width / 2, toggle.height / 2);
            tryCompare(toggle.background, "color", Qt.color(Theme.button.checked.hover));
            mousePress(toggle, toggle.width / 2, toggle.height / 2);
            tryCompare(toggle.background, "color", Qt.color(Theme.button.checked.pressed));
            mouseRelease(toggle, toggle.width / 2, toggle.height / 2);
            compare(toggle.checked, false);
            mouseMove(root, 0, root.height - 1);
        }

        // The ring follows the button's own corner under a rounded theme,
        // and the side padding grows until the label clears the round end.
        function test_rounded_button_clears_its_corner_and_rings_it() {
            compare(UnitTheme.override({ button: { radius: 4096 } }), "ok");
            const want = Inset.controlPadding(Theme.button.size.sm.paddingX, 4096, small.height, small.implicitContentHeight, Theme.space.xs);
            verify(want > Theme.button.size.sm.paddingX, "the sm pill's label needs more than its pad: " + want);
            tryCompare(small, "leftPadding", want);
            const ring = small.background.children[small.background.children.length - 1];
            compare(ring.radius, 4096 + Theme.focusRing.offset);
        }

        // An icon button's glyph insets reach the ink: chevron-left's ink
        // starts 9 of 24 units in, less half the stroke.
        function test_icon_button_reads_its_glyph_insets() {
            compare(smallIcon.contentItem.size, Theme.icon.size.sm);
            compare(smallIcon.leftPadding, Math.floor((Theme.size.control.sm - Theme.icon.size.sm) / 2));
            fuzzyCompare(smallIcon.glyphStart, smallIcon.leftPadding + 9 * Theme.icon.size.sm / 24 - Theme.icon.stroke / 2, 0.01);
            fuzzyCompare(smallIcon.glyphEnd, smallIcon.rightPadding + smallIcon.contentItem.size - (15 * Theme.icon.size.sm / 24 + Theme.icon.stroke / 2), 0.01);
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
            mouseMove(root, root.width - 1, root.height - 1);
            focusIcon.forceActiveFocus(Qt.TabFocusReason);
            tryCompare(focusIcon, "visualFocus", true);
            tryCompare(focusIcon.contentItem, "opacity", 1);
            focusIcon.focus = false;
            tryCompare(focusIcon.contentItem, "opacity", Theme.iconButton.restOpacity);
            tryCompare(pressedIcon.contentItem, "opacity", 1);
            pressedIcon.down = false;
            tryCompare(pressedIcon.contentItem, "opacity", Theme.iconButton.restOpacity);
            tryCompare(checkedIcon.contentItem, "opacity", 1);
            checkedIcon.checked = false;
            tryCompare(checkedIcon.contentItem, "opacity", Theme.iconButton.restOpacity);
            mouseMove(iconOnly, iconOnly.width / 2, iconOnly.height / 2);
            tryCompare(iconOnly.contentItem, "opacity", 1);
            mouseMove(root, 0, root.height - 1);
            tryCompare(iconOnly.contentItem, "opacity", Theme.iconButton.restOpacity);
            mouseMove(root, root.width - 1, 1);
            tryCompare(disabledIcon, "hovered", false);
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
