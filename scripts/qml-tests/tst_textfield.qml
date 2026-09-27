import QtQuick
import QtTest
import qs.Commons
import qs.Ui
import qs.Unit

// TextField and Field: typing reaches `text`, the placeholder shows only
// while empty, the outline follows hover, focus and error, a leading icon
// moves the text in, action buttons sit at the end, a validator refuses,
// and Field lays out label, hint and error around a control.
Item {
    id: root
    width: 400
    height: 300

    TextField { id: plain; placeholderText: "Search plugins"; width: 200 }
    TextField { id: iconed; leadingIcon: "search"; width: 200; y: 40; actions: [ IconButton { id: clear; iconName: "x"; label: "Clear"; size: "sm"; onClicked: iconed.clear() } ] }
    TextField { id: numeric; width: 200; y: 80; validator: IntValidator { bottom: 0; top: 99 } }
    Field { id: field; label: "Name"; hint: "Shown in the bar"; width: 200; y: 120; TextField { id: inner; width: parent.width } }

    TestCase {
        name: "textfield"
        when: windowShown

        function init() { UnitTheme.reset(); plain.clear(); iconed.clear(); numeric.clear(); field.error = ""; field.inline = Qt.binding(() => Theme.field.inline); plain.focus = false; }

        function placeholder() { return plain.background.children[1]; }

        function test_typing_reaches_text() {
            plain.forceActiveFocus();
            keyClick("a");
            keyClick("b");
            compare(plain.text, "ab");
            compare(placeholder().visible, false);
            plain.clear();
            compare(placeholder().visible, true);
            compare(placeholder().text, "Search plugins");
        }

        function test_outline_follows_focus_and_error() {
            const ring = plain.background.children[plain.background.children.length - 1];
            compare(String(plain.outline), String(Qt.color(Theme.textField.borderColor)));
            compare(ring.visible, false);
            plain.forceActiveFocus();
            compare(String(plain.outline), String(Qt.color(Theme.textField.focus)));
            compare(ring.visible, true);
            plain.error = true;
            compare(String(plain.outline), String(Qt.color(Theme.textField.error)));
            plain.error = false;
            plain.focus = false;
            compare(ring.visible, false);
            mouseMove(plain, plain.width / 2, plain.height / 2);
            tryCompare(plain, "hovered", true);
            compare(String(plain.outline), String(Qt.color(Theme.textField.hover)));
            mouseMove(root, root.width - 1, root.height - 1);
        }

        function test_leading_icon_and_actions() {
            verify(iconed.leftPadding > plain.leftPadding, "a leading icon moves the text in");
            compare(iconed.actions.length, 1);
            verify(iconed.rightPadding > plain.rightPadding, "an action reserves space at the end");
            iconed.text = "abc";
            mouseClick(clear);
            compare(iconed.text, "");
        }

        function test_validator_refuses() {
            numeric.forceActiveFocus();
            keyClick("x");
            compare(numeric.text, "");
            keyClick("4");
            keyClick("2");
            compare(numeric.text, "42");
            compare(numeric.acceptableInput, true);
        }

        function test_field_lays_out_label_hint_and_error() {
            const labels = field.children.filter(child => child.role !== undefined);
            const hint = labels[labels.length - 1];
            compare(hint.text, "Shown in the bar");
            compare(String(hint.color), String(Qt.color(Theme.text.hint.color)));
            field.error = "Taken";
            compare(hint.text, "Taken");
            compare(String(hint.color), String(Qt.color(Theme.color.danger)));
            compare(inner.width, field.width);
            field.inline = true;
            compare(inner.width, field.width - Theme.field.labelWidth - Theme.field.gap);
        }

        function test_theme_change_moves_the_field() {
            compare(UnitTheme.override({ textField: { height: 44, background: "#00ff00" }, field: { inline: true, labelWidth: 80 } }), "ok");
            compare(plain.height, 44);
            compare(String(plain.background.color), "#00ff00");
            compare(field.inline, true);
            compare(inner.width, field.width - 80 - Theme.field.gap);
        }
    }
}
