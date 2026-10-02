import QtQuick
import QtTest
import qs.Commons
import qs.Ui
import qs.Unit

// FormRow: the label column is `field.labelWidth` wide and the control
// starts `field.labelGap` after it and ends on the row's end edge; the row
// is `row.height` tall unless its control is taller; the label sits by
// capital height and the control by its box; a warning Badge leads the
// value column in its tone and moves neither the label column nor the
// control's end edge; without a label column the control takes the full
// width at its own height; the smoke's `fieldRow` hook names the row.
Item {
    id: root
    width: 480
    height: 400

    Column {
        width: 420
        FormRow { id: plain; width: parent.width; label: "Clock"; Switch { id: toggle; size: "sm" } }
        FormRow { id: filled; width: parent.width; label: "Format"; Select { id: choice; width: parent.width; model: ["HH:mm", "hh:mm ap"] } }
        FormRow { id: tall; width: parent.width; label: "Preview"; Rectangle { id: block; width: 40; height: Theme.row.height + 24; color: "transparent" } }
        FormRow { id: warned; width: parent.width; label: "Speed"; warning: "Overridden"; Slider { id: speed; width: parent.width; from: 0; to: 1; value: 0.5 } }
        FormRow { id: bare; width: parent.width; label: "Hidden"; labelColumn: false; Rectangle { id: thin; width: parent.width; height: 8; color: "transparent" } }
    }

    TestCase {
        name: "formrow"
        when: windowShown

        function labelOf(row) { return row.children[0]; }
        function badgeOf(row) { return row.children[1]; }
        function xIn(item, row) { return item.mapToItem(row, 0, 0).x; }

        function init() { UnitTheme.reset(); }

        function test_a_row_is_the_row_height_with_a_label_column() {
            for (const row of [plain, filled, warned])
                compare(row.height, Theme.row.height);
            compare(plain.valueX, Theme.field.labelWidth + Theme.field.labelGap);
            compare(xIn(toggle, plain), plain.valueX);
            compare(xIn(choice, filled), filled.valueX);
            compare(xIn(choice, filled) + choice.width, filled.width, "the control ends on the row's end edge");
            compare(labelOf(plain).width, Theme.field.labelWidth);
            compare(labelOf(plain).y, labelOf(plain).topForCapCenter(plain.height), "the label sits by capital height");
            fuzzyCompare(toggle.mapToItem(plain, 0, toggle.height / 2).y, plain.height / 2, 1);
        }

        function test_a_taller_control_grows_the_row() {
            compare(tall.height, block.height);
            compare(block.mapToItem(tall, 0, 0).y, 0);
        }

        function test_a_warning_leads_the_value_column() {
            const badge = badgeOf(warned);
            verify(badge.visible, "the warning draws no badge");
            compare(badge.text, "Overridden");
            compare(String(badge.color), String(Qt.color(Theme.badge.tone.warning.background)));
            compare(xIn(badge, warned), warned.valueX);
            fuzzyCompare(badge.y + badge.height / 2, warned.height / 2, 1);
            compare(xIn(speed, warned), warned.valueX + badge.width + Theme.stack.inline);
            compare(xIn(speed, warned) + speed.width, warned.width, "a warning moves the control's end edge");
            compare(labelOf(warned).width, Theme.field.labelWidth);
            verify(!badgeOf(plain).visible, "a row without a warning draws a badge");
            warned.warningTone = "danger";
            compare(String(badge.color), String(Qt.color(Theme.badge.tone.danger.background)));
            warned.warningTone = "warning";
        }

        function test_without_a_label_column_the_control_takes_the_row() {
            verify(!labelOf(bare).visible, "the label draws without its column");
            compare(bare.valueX, 0);
            compare(xIn(thin, bare), 0);
            compare(thin.width, bare.width);
            compare(bare.height, thin.height);
        }

        function test_a_theme_moves_the_columns() {
            compare(UnitTheme.override({ field: { labelWidth: 80, labelGap: 5 }, row: { height: 44 } }), "ok");
            compare(xIn(choice, filled), 85);
            compare(choice.width, filled.width - 85);
            compare(plain.height, 44);
        }

        function test_the_smoke_hook_names_the_row() {
            compare(plain.objectName, "fieldRow");
        }
    }
}
