import QtQuick
import QtTest
import qs.Commons
import qs.Ui
import qs.Unit

// BarItem: every bar widget's one item. It is `bar.item.height` tall and
// never narrower; its content sits `bar.item.paddingX` in; the icon is
// `bar.item.icon` wide at full opacity; a count draws in the bar role in
// the item's tone; `active` fills it with `bar.active`; hover and press
// fill it with their own tokens; a click emits `clicked`.
Item {
    id: root
    width: 300
    height: 160

    BarItem { id: icon; iconName: "settings"; label: "Settings"; onClicked: root.clicks += 1 }
    BarItem { id: counted; iconName: "shield"; count: "12"; tone: "#ff0000"; y: 40 }
    BarItem { id: pill; text: "1"; active: true; y: 80 }
    BarItem { id: spinner; iconName: "refresh-cw"; spinning: true; y: 120 }
    BarItem { id: shortcut; iconName: "settings"; label: "Settings"; tooltip: "Open settings"; shortcut: "Super+M"; x: 80 }
    property int clicks: 0

    TestCase {
        name: "baritem"
        when: windowShown

        function init() { UnitTheme.reset(); root.clicks = 0; }

        function labels(item) {
            const out = [];
            const walk = node => { for (const child of node.children) { if (child.role !== undefined && child.visible) out.push(child); walk(child); } };
            walk(item.contentItem);
            return out;
        }
        function firstIcon(item) {
            const walk = node => { for (const child of node.children) { if (child.name !== undefined && child.paths !== undefined) return child; const found = walk(child); if (found) return found; } return null; };
            return walk(item.contentItem);
        }

        function test_geometry_follows_the_bar_item_tokens() {
            compare(icon.height, Theme.bar.item.height);
            compare(icon.width, Theme.bar.item.height, "an icon-only item is square");
            compare(counted.leftPadding, Theme.bar.item.paddingX);
            compare(counted.width, Math.ceil(counted.implicitContentWidth) + 2 * Theme.bar.item.paddingX);
            compare(firstIcon(icon).size, Theme.bar.item.icon);
            compare(firstIcon(icon).opacity, 1);
            const glyph = firstIcon(icon);
            fuzzyCompare(glyph.mapToItem(icon, 0, 0).y + glyph.height / 2, icon.height / 2, 0.5);
        }

        function test_count_draws_in_the_bar_role_and_the_tone() {
            const found = labels(counted);
            compare(found.length, 1);
            compare(found[0].role, "bar");
            compare(found[0].text, "12");
            compare(String(found[0].color), "#ff0000");
            compare(String(firstIcon(counted).color), "#ff0000");
        }

        function test_active_fills_and_states_move_the_fill() {
            compare(String(pill.background.color), String(Qt.color(Theme.bar.active)));
            compare(String(labels(pill)[0].color), String(Qt.color(Theme.bar.onActive)));
            mouseMove(icon, icon.width / 2, icon.height / 2);
            tryCompare(icon.background, "color", Qt.color(Theme.bar.item.hover));
            mousePress(icon, icon.width / 2, icon.height / 2);
            tryCompare(icon.background, "color", Qt.color(Theme.bar.item.pressed));
            mouseRelease(icon, icon.width / 2, icon.height / 2);
            compare(root.clicks, 1);
            mouseMove(root, root.width - 1, root.height - 1);
            tryCompare(icon.background, "color", Qt.color("transparent"));
        }

        function test_a_spinner_takes_the_icon_place() {
            const glyph = firstIcon(spinner);
            compare(glyph.visible, false);
            compare(spinner.width, spinner.height);
        }

        function test_shortcut_tooltip_is_anchored_to_the_item() {
            const tip = shortcut.children.find(child => child.shortcut !== undefined);
            verify(tip !== undefined, "the bar item has one tooltip");
            compare(tip.anchorItem, shortcut);
            compare(tip.text, "Open settings");
            compare(tip.shortcut, "Super+M");
        }

        function test_theme_moves_the_item() {
            compare(UnitTheme.override({ bar: { item: { height: 30, paddingX: 9, icon: 20 } } }), "ok");
            compare(icon.height, 30);
            compare(counted.leftPadding, 9);
            compare(icon.width, 30);
            compare(firstIcon(icon).size, 20);
        }
    }
}
