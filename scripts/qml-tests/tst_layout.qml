import QtQuick
import QtTest
import qs.Commons
import qs.Ui
import qs.Unit

// ScrollArea, Tabs, ListItem, SectionHeader, Surface and Divider: the
// scroll area's content height follows its children and its bar shows on
// overflow, a click opens a tab, a list item highlights and clicks, a
// section header draws its eyebrow inside its padding, a surface draws its
// level and logs an unknown one, and a divider is one hairline thick.
Item {
    id: root
    width: 400
    height: 620

    ScrollArea { id: scroll; width: 100; height: 50; Column { Repeater { model: 10; Rectangle { width: 80; height: 20; color: "transparent" } } } }
    Tabs { id: tabs; model: ["Installed", "Available"]; y: 60 }
    ListItem { id: row; text: "Plugin updates"; secondary: "1 update available"; iconName: "package"; width: 300; y: 100 }
    ListItem { id: bare; text: "Plugin updates"; secondary: "1 update available"; iconName: "package"; y: 300 }
    SectionHeader { id: header; text: "Listed since"; description: "Sep 24"; width: 300; y: 150 }
    SectionHeader { id: inset; text: "Plugins"; description: "Every plugin the shell found"; leftPadding: Theme.row.paddingX; rightPadding: Theme.row.paddingX; width: 300; y: 330 }
    Column {
        id: sectionColumn
        width: 300
        y: 380
        spacing: Theme.stack.group
        Rectangle { id: beforeSection; width: parent.width; height: Theme.row.height; color: "transparent" }
        Section {
            id: section
            title: "Status"
            description: "Values from the plugin"
            headerInset: Theme.row.paddingX
            width: parent.width
            Field { label: "One"; inline: true; width: parent.width; Label { role: "item"; text: "Ready" } }
            Field { label: "Two"; inline: true; width: parent.width; Label { role: "item"; text: "Set" } }
        }
    }
    Column {
        id: firstSectionColumn
        width: 300
        y: 540
        spacing: Theme.stack.group
        Section { id: firstSection; title: "First"; width: parent.width; Field { label: "One"; inline: true; width: parent.width; Label { role: "item"; text: "Ready" } } }
    }
    Surface { id: surface; level: "raised"; width: 100; height: 40; y: 220 }
    Divider { id: divider; width: 100; y: 270 }
    SignalSpy { id: clicks; target: row; signalName: "clicked" }

    TestCase {
        name: "layout"
        when: windowShown

        function init() { UnitTheme.reset(); tabs.currentIndex = 0; row.highlighted = false; clicks.clear(); }

        function test_scroll_area_follows_its_content() {
            compare(scroll.contentHeight, 200);
            verify(scroll.contentHeight > scroll.height, "the content overflows");
            compare(scroll.bar.parent, scroll);
            compare(scroll.bar.visible, true);
            compare(scroll.bar.width, Theme.scrollArea.barWidth);
        }

        function test_tabs_open_on_click() {
            compare(tabs.count, 2);
            compare(tabs.currentIndex, 0);
            mouseClick(tabs.itemAt(1));
            compare(tabs.currentIndex, 1);
            compare(tabs.itemAt(1).checked, true);
            compare(tabs.itemAt(0).checked, false);
            compare(tabs.itemAt(1).background.children[0].visible, true);
            compare(tabs.itemAt(0).background.children[0].visible, false);
            compare(tabs.height, Theme.tabs.height);
        }

        function test_list_item_highlights_and_clicks() {
            compare(String(row.background.color), "#00000000");
            row.highlighted = true;
            tryCompare(row.background, "color", Qt.color(Theme.listItem.selected));
            mouseClick(row);
            compare(clicks.count, 1);
            verify(row.height >= Theme.listItem.height);
            // A row without a width prefers the width of its text.
            verify(bare.implicitWidth > 100, "a populated row without a width is " + bare.implicitWidth + " wide");
        }

        // The title and secondary lines draw with whole-pixel line boxes,
        // so the pair sits on the icon's centre, which is the row's.
        function test_list_item_centres_its_lines_on_its_icon() {
            const icon = row.contentItem.children[0];
            const column = row.contentItem.children[1];
            const title = column.children[0];
            const secondary = column.children[1];
            compare(title.role, "item");
            compare(secondary.role, "itemHint");
            compare(title.lineHeight, title.lineBox);
            compare(secondary.lineHeight, secondary.lineBox);
            const top = title.mapToItem(row, 0, 0).y;
            const bottom = secondary.mapToItem(row, 0, secondary.height).y;
            const iconMid = icon.mapToItem(row, 0, icon.height / 2).y;
            verify(Math.abs((top + bottom) / 2 - iconMid) <= 1, "lines centre " + (top + bottom) / 2 + ", icon centre " + iconMid);
            verify(Math.abs(iconMid - row.height / 2) <= 1, "icon centre " + iconMid + ", row centre " + row.height / 2);
            compare(row.height, Theme.listItem.twoLineHeight, "a row with a secondary line takes the two-line height");
            const single = Qt.createQmlObject("import qs.Ui\nListItem { text: \"One line\"; width: 200 }", root);
            compare(single.height, Theme.listItem.height, "a row without one takes the one-line height");
            single.destroy();
        }

        function test_section_header_and_divider() {
            const eyebrow = header.children[0];
            compare(eyebrow.role, "eyebrow");
            compare(eyebrow.text, "Listed since");
            compare(header.topPadding, 0);
            // A padded header keeps its lines inside the padding.
            for (const line of inset.children) {
                compare(line.x, inset.leftPadding);
                compare(line.width, inset.width - inset.leftPadding - inset.rightPadding);
            }
            compare(divider.height, Theme.divider.thickness);
            compare(String(divider.color), String(Qt.color(Theme.divider.color)));
        }

        function test_section_spacing_and_inset() {
            const headerItem = section.children[0];
            const rows = section.children[1];
            compare(section.topPadding, Theme.stack.section - sectionColumn.spacing);
            fuzzyCompare(headerItem.mapToItem(sectionColumn, 0, 0).y - beforeSection.height, Theme.stack.section, 1);
            compare(firstSection.topPadding, 0);
            compare(rows.spacing, Theme.stack.row);
            compare(headerItem.leftPadding, Theme.row.paddingX);
            compare(headerItem.children[0].x, Theme.row.paddingX);
        }

        // expected-log: Surface: no level named "floating" -- the test names an unknown level on purpose
        function test_surface_draws_its_level() {
            compare(String(surface.color), String(Qt.color(Theme.surface.level.raised.background)));
            compare(surface.radius, Theme.surface.radius);
            const odd = Qt.createQmlObject("import qs.Ui\nSurface { level: \"floating\" }", root);
            compare(String(odd.color), String(Qt.color(Theme.surface.level.base.background)));
            odd.destroy();
        }

        function test_theme_change_moves_the_layout() {
            compare(UnitTheme.override({ tabs: { height: 44 }, row: { height: 50 }, stack: { row: 9, section: 30 }, divider: { thickness: 3 }, surface: { radius: 9 } }), "ok");
            compare(tabs.height, 44);
            verify(row.height >= 50);
            compare(section.topPadding, 30 - sectionColumn.spacing);
            compare(section.children[1].spacing, 9);
            compare(divider.height, 3);
            compare(surface.radius, 9);
        }
    }
}
