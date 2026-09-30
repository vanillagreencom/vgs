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
    height: 650

    TextField { id: plain; placeholderText: "Search plugins"; width: 200 }
    TextField { id: iconed; leadingIcon: "search"; width: 200; y: 40; actions: [ IconButton { id: clear; iconName: "x"; label: "Clear"; size: "sm"; onClicked: iconed.clear() } ] }
    TextField { id: numeric; width: 200; y: 80; validator: IntValidator { bottom: 0; top: 99 } }
    Field { id: field; label: "Name"; hint: "Shown in the bar"; width: 200; y: 120; TextField { id: inner; width: parent.width } }
    Column {
        id: inlineGrid
        y: 220
        width: 360
        spacing: Theme.stack.row
        Field { id: switchField; label: "Switch"; inline: true; width: parent.width; Switch { id: inlineSwitch; size: "sm"; checked: true } }
        Field { id: labelField; label: "Text"; inline: true; width: parent.width; Label { id: inlineLabel; role: "item"; text: "Value"; width: parent.width } }
        Field { id: badgeField; label: "Badge"; inline: true; width: parent.width; Badge { id: inlineBadge; text: "Ready"; tone: "success" } }
        Field { id: textFieldRow; label: "Text field"; inline: true; width: parent.width; TextField { id: inlineText; width: parent.width; text: "abc" } }
        Field { id: longLabel; label: "Single-workspace token state"; inline: true; width: parent.width; Label { role: "item"; text: "Present" } }
        Field { id: buttonField; label: "Button"; inline: true; width: parent.width; Button { id: inlineButton; text: "Open"; size: "sm"; variant: "secondary" } }
        Field { id: selectField; label: "Select"; hint: "Shown below the value."; inline: true; width: parent.width; Select { id: inlineSelect; width: parent.width; model: ["Default", "Ocean"] } }
    }

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

        function test_text_and_placeholder_are_vertically_centred() {
            const mark = placeholder();
            compare(mark.role, "item");
            const placeholderCentre = mark.mapToItem(plain, 0, mark.height / 2).y;
            verify(Math.abs(placeholderCentre - plain.height / 2) <= 1, "placeholder centre " + placeholderCentre + ", field centre " + plain.height / 2);
            plain.text = "abc";
            wait(0);
            const cursorCentre = plain.cursorRectangle.y + plain.cursorRectangle.height / 2;
            verify(Math.abs(cursorCentre - plain.height / 2) <= 1, "text centre " + cursorCentre + ", field centre " + plain.height / 2);
            const iconCentre = iconed.background.children[0].mapToItem(iconed, 0, iconed.background.children[0].height / 2).y;
            verify(Math.abs(iconCentre - iconed.height / 2) <= 1, "leading icon centre " + iconCentre + ", field centre " + iconed.height / 2);
        }

        function test_outline_follows_focus_and_error() {
            const ring = plain.background.children[plain.background.children.length - 1];
            compare(String(plain.outline), String(Qt.color(Theme.textField.borderColor)));
            compare(ring.visible, false);
            plain.forceActiveFocus();
            compare(String(plain.outline), String(Qt.color(Theme.textField.focus)));
            compare(ring.visible, true);
            compare(String(ring.border.color), String(Qt.color(Theme.focusRing.color)));
            plain.error = true;
            compare(String(plain.outline), String(Qt.color(Theme.textField.error)));
            // A focused field in error keeps the error cue on its ring.
            compare(String(ring.border.color), String(Qt.color(Theme.textField.error)));
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
            compare(iconed.background.children[0].size, Theme.icon.size.md);
            compare(iconed.leftPadding, Theme.textField.paddingX + Theme.icon.size.md + Theme.textField.gap);
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
            const hint = field.children[2].children[0];
            compare(hint.text, "Shown in the bar");
            compare(String(hint.color), String(Qt.color(Theme.text.hint.color)));
            field.error = "Taken";
            compare(hint.text, "Taken");
            compare(String(hint.color), String(Qt.color(Theme.color.danger)));
            const pad = Theme.field.paddingX;
            tryVerify(() => inner.mapToItem(field, 0, 0).x === pad);
            compare(inner.width, field.width - 2 * pad);
            field.inline = true;
            const inset = pad + Theme.field.labelWidth + Theme.field.labelGap;
            tryVerify(() => inner.mapToItem(field, 0, 0).x === inset);
            compare(inner.width, field.width - inset - pad);
            tryVerify(() => hint.mapToItem(field, 0, 0).x === inset);
            compare(hint.width, field.width - inset - pad);
        }

        // A label too long for its column wraps to a second line, whole,
        // and the value column starts where `valueX` says.
        function test_a_long_inline_label_wraps_and_the_value_column_is_published() {
            const label = longLabel.children[1].children[0];
            compare(label.lineCount, 2);
            compare(label.truncated, false);
            compare(longLabel.valueX, Theme.field.labelWidth + Theme.field.labelGap);
            verify(longLabel.children[1].height >= label.implicitHeight, "the row holds both lines");
        }

        function test_inline_fields_share_row_height_and_value_column() {
            const rows = [switchField, labelField, badgeField, textFieldRow, buttonField, selectField];
            for (const row of rows)
                compare(row.children[1].height, Theme.row.height);
            const pairs = [[switchField, inlineSwitch], [labelField, inlineLabel], [badgeField, inlineBadge], [textFieldRow, inlineText], [buttonField, inlineButton], [selectField, inlineSelect]];
            for (const pair of pairs)
                fuzzyCompare(pair[1].mapToItem(pair[0], 0, pair[1].height / 2).y, Theme.row.height / 2, 1);
            const hint = selectField.children[2].children[0];
            compare(hint.x, Theme.field.labelWidth + Theme.field.labelGap);
        }

        function test_theme_change_moves_the_field() {
            compare(UnitTheme.override({ textField: { height: 44, background: "#00ff00" }, field: { inline: true, labelWidth: 80, labelGap: 5, paddingX: 3 } }), "ok");
            compare(plain.height, 44);
            compare(String(plain.background.color), "#00ff00");
            compare(field.inline, true);
            tryVerify(() => inner.mapToItem(field, 0, 0).x === 3 + 80 + 5);
            compare(inner.width, field.width - 3 - 80 - 5 - 3);
            compare(switchField.children[1].height, Theme.row.height);
        }
    }
}
