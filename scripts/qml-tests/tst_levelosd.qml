import QtQuick
import QtTest
import qs.Commons
import qs.Ui
import qs.Unit

// LevelOsd: the icon, the bar and the label sit `osd.gap` apart inside
// `osd.padding` on its card; the bar is `osd.barWidth` long and filled to
// the level, held to 0 to 1, and empty for a level that is not a number;
// the label reads the level as a percentage unless the caller names it,
// right-aligned in a column as wide as "100%", and elides past
// `osd.labelMaxWidth`; it takes no focus and no press.
Item {
    id: root
    width: 600
    height: 300

    property int presses: 0
    MouseArea { anchors.fill: parent; onPressed: root.presses += 1 }

    LevelOsd { id: osd; iconName: "volume-2"; level: 0.45 }
    LevelOsd { id: muted; y: 200; iconName: "volume-x"; level: 0; text: "Muted" }
    LevelOsd { id: named; y: 100; iconName: "sun"; level: 1; text: "Studio Display brightness at its brightest setting" }

    TestCase {
        name: "levelosd"
        when: windowShown

        function partsOf(item) { return item.children[0].children; }
        function iconOf(item) { return partsOf(item)[0]; }
        function barOf(item) { return partsOf(item)[1]; }
        function labelOf(item) { return partsOf(item)[2].children[1]; }
        function xIn(part, item) { return part.mapToItem(item, 0, 0).x; }

        function init() {
            UnitTheme.reset();
            osd.level = 0.45;
        }

        function test_the_parts_sit_in_one_padded_row() {
            const icon = iconOf(osd), bar = barOf(osd), column = partsOf(osd)[2];
            compare(icon.width, Theme.osd.icon);
            compare(xIn(icon, osd), Theme.osd.padding);
            compare(xIn(bar, osd), Theme.osd.padding + Theme.osd.icon + Theme.osd.gap);
            compare(bar.width, Theme.osd.barWidth);
            compare(xIn(column, osd), xIn(bar, osd) + bar.width + Theme.osd.gap);
            compare(osd.width, xIn(column, osd) + column.width + Theme.osd.padding);
            compare(osd.height, 2 * Theme.osd.padding + partsOf(osd)[2].height);
            for (const part of [icon, bar])
                fuzzyCompare(part.mapToItem(osd, 0, part.height / 2).y, osd.height / 2, 1);
            compare(String(osd.color), String(Qt.color(Theme.osd.background)));
            compare(String(osd.border.color), String(Qt.color(Theme.osd.border)));
            compare(osd.radius, Theme.osd.radius);
        }

        function test_the_bar_fills_to_the_held_level() {
            const bar = barOf(osd);
            compare(bar.value, 0.45);
            fuzzyCompare(bar.contentItem.children[0].width, 0.45 * bar.contentItem.width, 0.01);
            osd.level = 1.7;
            compare(bar.value, 1);
            compare(labelOf(osd).text, "100%");
            osd.level = -0.2;
            compare(bar.value, 0);
            compare(labelOf(osd).text, "0%");
            osd.level = 0.5;
            osd.level = NaN;
            compare(bar.value, 0);
            compare(labelOf(osd).text, "0%");
        }

        function test_the_label_reads_the_level_or_the_callers_text() {
            const label = labelOf(osd);
            compare(label.text, "45%");
            compare(label.horizontalAlignment, Text.AlignRight);
            const column = partsOf(osd)[2];
            const widest = column.children[0];
            compare(widest.text, "100%");
            compare(column.width, widest.implicitWidth, "the column moves with the level");
            osd.level = 0.05;
            compare(column.width, widest.implicitWidth);
            compare(labelOf(muted).text, "Muted");
            compare(iconOf(muted).name, "volume-x");
            compare(partsOf(named)[2].width, Theme.osd.labelMaxWidth);
            verify(labelOf(named).truncated, "a long label runs past its column");
        }

        function test_it_takes_no_focus_and_no_press() {
            osd.forceActiveFocus(Qt.TabFocusReason);
            verify(!osd.activeFocusOnTab, "the display is a tab stop");
            for (const part of partsOf(osd))
                verify(part.activeFocusOnTab !== true && part.focusPolicy !== Qt.TabFocus && part.focusPolicy !== Qt.StrongFocus, "a part takes focus");
            mouseClick(barOf(osd), 4, 2);
            mouseClick(osd, 2, 2);
            compare(root.presses, 2);
        }
    }
}
