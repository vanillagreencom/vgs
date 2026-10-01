import QtQuick
import QtTest
import qs.Commons
import qs.Ui
import qs.Unit

// The overlays through the stand-in popup window: a popover opens and
// closes and counts in OverlayState, a menu moves its highlight and
// triggers by key and closes on a trigger, a select chooses by index and
// reads its text role, a tooltip opens after the delay while the pointer
// rests and not under an open overlay, and a toast draws its tone. A menu
// taller than its maximum scrolls with the highlight kept in view, jumps
// to the entry whose text starts with the letters typed, opens on its
// checked entry and draws its mark. A menu and a select's list draw their
// highlight through one ListCursor, which a hover moves only once the
// pointer moved since the last key. The first entry's highlight and a
// select's chosen fill meet the list's border at the top and both sides,
// under a square and a rounded theme, and stay inside a rounder corner;
// the bar of an overflowing list draws over a strip each entry keeps clear,
// exactly while the bar shows. Under a rounded theme a list is cut to its
// window's rounded interior, so a filled row half scrolled past the top and
// the bar's thumb at the top stay inside the curve; a square list draws no
// layer.
// The nested sandbox proves placement, real keys and dismissal.
Item {
    id: root
    width: 300
    height: 200

    Item { id: host; width: 60; height: 26
        Popover { id: popover; width: 120; Item { width: 100; height: 40 } }
        Menu { id: menu
            MenuItem { text: "First"; onTriggered: root.triggered = 0 }
            MenuItem { text: "Second"; onTriggered: root.triggered = 1 }
            MenuItem { text: "Off"; enabled: false; onTriggered: root.triggered = 2 }
            MenuItem { id: wide; text: "An entry far wider than the menu's minimum width, with a shortcut"; shortcut: "Ctrl+Shift+W" }
        }
        Menu { id: mid
            MenuItem { text: "Rescan every plugin"; iconName: "refresh-cw"; shortcut: "R" }
        }
        Tooltip { id: tip; text: "hint" }
        Tooltip { id: longTip; text: "method=unknown path=/home/user/.local/share/vgs/repo is where VGS runs from, and no package manager owns it" }
        Menu { id: long
            Repeater {
                model: ["Bar", "Gallery", "Launcher", "Notifications", "Settings", "Themes", "Beta", "Clock", "Dock", "Echo", "Files", "Grid", "Help", "Inbox", "Jobs"]
                MenuItem { required property string modelData; required property int index; text: modelData; checked: index === root.chosen }
            }
        }
    }
    property int chosen: 4
    Select { id: select; y: 40; model: ["one", "two", "three"] }
    Select { id: roled; y: 80; textRole: "name"; model: [{ name: "alpha" }, { name: "beta" }] }
    property int wanted: 0
    Select { id: bound; y: 120; model: ["one", "two", "three"]; currentIndex: root.wanted }
    Select { id: longSelect; y: 160; model: ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p"] }
    Toast { id: toast; y: 120; title: "Saved"; message: "to disk"; tone: "success"; iconName: "check" }
    property int triggered: -1
    SignalSpy { id: dismissals; target: toast; signalName: "dismissed" }
    SignalSpy { id: activations; target: roled; signalName: "activated" }

    TestCase {
        name: "overlays"
        when: windowShown

        function init() { UnitTheme.reset(); popover.close(); menu.close(); select.choose(0); root.triggered = -1; dismissals.clear(); }

        function test_popover_opens_and_counts() {
            compare(popover.opened, false);
            compare(OverlayState.open, 0);
            popover.open();
            compare(popover.opened, true);
            compare(OverlayState.open, 1);
            popover.close();
            compare(popover.opened, false);
            compare(OverlayState.open, 0);
            popover.toggle();
            compare(popover.opened, true);
            popover.toggle();
            compare(popover.opened, false);
        }

        function test_popover_anchors_to_its_item() {
            let window = null;
            for (let i = 0; i < popover.resources.length; i++)
                if (popover.resources[i].anchor !== undefined) window = popover.resources[i];
            verify(window !== null, "the popover holds a popup window");
            compare(window.anchor.item, host);
            compare(window.anchor.margins.bottom, -Theme.popover.gap);
            compare(window.grabFocus, true);
            const updates = window.anchor.updates;
            popover.open();
            host.x += 10;
            verify(window.anchor.updates > updates, "a moved anchor updates the popup's anchor");
            host.visible = false;
            compare(popover.opened, false);
            host.visible = true;
            host.x = 0;
        }

        function test_menu_moves_and_triggers_by_key() {
            menu.open();
            compare(menu.opened, true);
            compare(menu.currentIndex, 0);
            menu.move(1);
            compare(menu.currentIndex, 1);
            compare(menu.items()[0].highlighted, false);
            menu.triggerCurrent();
            compare(root.triggered, 1);
            tryCompare(menu, "opened", false);
        }

        function test_menu_skips_disabled_entries_and_starts_at_the_ends() {
            menu.open();
            menu.move(-1);
            compare(menu.currentIndex, 3, "Up from none takes the last reachable entry");
            menu.move(1);
            compare(menu.currentIndex, 0, "the highlight wraps over the reachable entries");
            menu.move(-1);
            compare(menu.currentIndex, 3);
            menu.move(-1);
            compare(menu.currentIndex, 1, "the highlight skips the disabled entry going up");
            menu.currentIndex = 2;
            menu.triggerCurrent();
            compare(root.triggered, -1, "a disabled entry never triggers");
            menu.close();
        }

        // An output's room is its size less `size.window.gutter` a side;
        // with no output there is no bound, and an overlay keeps its cap.
        function test_an_output_leaves_its_room() {
            const room = OverlayState.room({ width: 480, height: 720 });
            compare(room.width, 480 - 2 * Theme.size.window.gutter);
            compare(room.height, 720 - 2 * Theme.size.window.gutter);
            compare(OverlayState.room(null).width, Infinity);
            compare(OverlayState.widthFor(null, 360), 360);
        }

        function test_menu_width_follows_its_widest_entry() {
            let window = null;
            for (let i = 0; i < menu.resources.length; i++)
                if (menu.resources[i].anchor !== undefined) window = menu.resources[i];
            verify(window !== null, "the menu holds a popup window");
            verify(wide.implicitWidth > Theme.menu.minWidth, "the wide entry passes the minimum: " + wide.implicitWidth);
            menu.open();
            // Past `menu.maxWidth` the window stops growing; the entries fill
            // it inside the border.
            verify(wide.implicitWidth + 2 * Theme.border.thin > Theme.menu.maxWidth, "the wide entry passes the cap: " + wide.implicitWidth);
            compare(window.width, Theme.menu.maxWidth);
            compare(wide.width, window.width - 2 * Theme.border.thin);
            menu.close();
            // Under the cap no entry elides, whatever fraction of a pixel
            // its text measures: the window rounds its width up.
            mid.open();
            let midWindow = null;
            for (let i = 0; i < mid.resources.length; i++)
                if (mid.resources[i].anchor !== undefined) midWindow = mid.resources[i];
            verify(mid.widest > Theme.menu.minWidth && mid.widest !== Math.floor(mid.widest), "the entry passes the minimum by a fraction: " + mid.widest);
            tryVerify(() => mid.items()[0].width >= mid.widest, 1000, "the entry takes its whole width in a window " + midWindow.width + " wide, the entry " + mid.widest);
            compare(mid.items()[0].contentItem.children[1].truncated, false);
            mid.close();
            menu.open();
            // The long text elides and the shortcut keeps its trailing column.
            const title = wide.contentItem.children[1];
            const hint = wide.contentItem.children[2];
            compare(title.truncated, true);
            compare(hint.x + hint.width, wide.contentItem.width);
            verify(title.x + title.width <= hint.x - wide.spacing, "the text stops before the shortcut column");
            menu.close();
        }

        function longWindow() {
            for (let i = 0; i < long.resources.length; i++)
                if (long.resources[i].anchor !== undefined) return long.resources[i];
            return null;
        }

        function test_a_long_menu_scrolls_inside_its_maximum() {
            compare(UnitTheme.override({ menu: { maxHeight: 90 } }), "ok");
            long.open();
            const window = longWindow();
            compare(window.height, 90 + 2 * Theme.border.thin);
            compare(long.scrollArea.overflowing, true);
            compare(long.scrollArea.bar.visible, true);
            // The entries span the list, and each keeps the bar's strip
            // clear at its end: the bar lies inside it.
            const first = long.items()[0];
            // The window's content item takes the window's size a turn
            // after it shows.
            tryCompare(long.scrollArea, "width", window.width - 2 * Theme.border.thin);
            compare(first.width, long.scrollArea.width);
            compare(first.barRoom, Theme.scrollArea.gutter);
            const bar = long.scrollArea.bar;
            verify(bar.x >= first.width - first.barRoom && bar.x + bar.width <= first.width, "the bar lies in the entry's end strip: " + bar.x);
            verify(first.contentItem.x + first.contentItem.width <= first.width - first.barRoom, "the entry's text stops before the bar");
            long.close();
            // A menu that fits keeps no strip.
            UnitTheme.reset();
            menu.open();
            tryCompare(menu.items()[0], "barRoom", 0);
            compare(menu.items()[0].rightPadding, menu.items()[0].sidePadding);
            menu.close();
        }

        function test_the_highlight_is_kept_in_view() {
            compare(UnitTheme.override({ menu: { maxHeight: 90 } }), "ok");
            root.chosen = -1;
            long.open();
            compare(long.scrollArea.contentY, 0);
            for (let i = 0; i < 10; i++) long.move(1);
            const item = long.items()[long.currentIndex];
            verify(item.y + item.height <= long.scrollArea.contentY + long.scrollArea.height, "the highlighted entry's bottom is in view");
            verify(item.y >= long.scrollArea.contentY, "the highlighted entry's top is in view");
            long.move(1);
            long.currentIndex = 0;
            compare(long.scrollArea.contentY, 0, "going back up scrolls the first entry into view");
            long.close();
            root.chosen = 4;
        }

        function test_opening_highlights_the_checked_entry_and_draws_its_mark() {
            compare(UnitTheme.override({ menu: { maxHeight: 90 } }), "ok");
            root.chosen = 12;
            long.open();
            compare(long.currentIndex, 12);
            const item = long.items()[12];
            verify(item.y + item.height <= long.scrollArea.contentY + long.scrollArea.height && item.y >= long.scrollArea.contentY, "the checked entry opens in view");
            compare(item.indicator.visible, true);
            compare(item.indicator.name, "check");
            compare(item.rightPadding, Theme.menu.item.paddingX + Theme.scrollArea.gutter + Theme.icon.size.sm + item.spacing);
            compare(item.indicator.x + item.indicator.width, item.width - item.sidePadding - item.barRoom, "the check mark ends a side padding before the bar");
            compare(long.items()[0].indicator.visible, false);
            compare(long.items()[0].rightPadding, Theme.menu.item.paddingX + Theme.scrollArea.gutter);
            long.close();
            root.chosen = -1;
            long.open();
            compare(long.currentIndex, 0, "with no checked entry the first reachable item is highlighted");
            long.close();
            root.chosen = 4;
        }

        // A highlight moved and dismissed without a choice: the next opening
        // lands the cursor on the checked entry at once, with motion on.
        function test_a_reopened_menu_lands_on_its_checked_entry() {
            compare(UnitTheme.override({ motion: { list: { travel: { duration: 2000 } } } }), "ok");
            long.open();
            const items = long.items();
            const plate = items[0].cursor;
            compare(long.currentIndex, 4);
            tryCompare(plate, "opacity", 1);
            long.move(1);
            long.move(1);
            compare(long.currentIndex, 6);
            // The cursor is on its way to the moved highlight.
            wait(200);
            verify(plate.y > items[4].y, "the cursor left the checked entry, at " + plate.y);
            long.close();
            long.open();
            compare(long.currentIndex, 4);
            compare(plate.y, items[4].y, "the cursor lands on the checked entry at once");
            long.close();
        }

        function test_a_reopened_select_list_lands_on_the_choice() {
            compare(UnitTheme.override({ motion: { list: { travel: { duration: 2000 } } } }), "ok");
            select.openList();
            const list = selectList(select);
            tryVerify(() => list.itemAtIndex(2) !== null, 1000, "the list builds its entries");
            const plate = list.contentItem.children.find(child => child.follow !== undefined);
            tryCompare(plate, "opacity", 1);
            list.currentIndex = 2;
            // The cursor is on its way to the moved highlight.
            wait(200);
            verify(plate.y > list.itemAtIndex(0).y, "the cursor left the choice, at " + plate.y);
            list.Window.window.visible = false;
            compare(select.listOpen, false);
            select.openList();
            compare(list.currentIndex, 0);
            compare(plate.y, list.itemAtIndex(0).y, "the cursor lands on the choice at once");
            select.choose(0);
        }

        function test_closed_select_keys_do_not_wrap() {
            select.forceActiveFocus();
            select.choose(0);
            select.closedNav.moveBy(-1);
            compare(select.currentIndex, 0);
            keyClick(Qt.Key_Up);
            compare(select.currentIndex, 0);
            select.choose(2);
            select.closedNav.moveBy(1);
            compare(select.currentIndex, 2);
            keyClick(Qt.Key_Down);
            compare(select.currentIndex, 2);
        }

        function test_open_select_keys_do_not_wrap() {
            select.openList();
            const list = selectList(select);
            tryVerify(() => list.itemAtIndex(2) !== null, 1000, "the list builds its entries");
            list.currentIndex = 2;
            keyClick(Qt.Key_Down);
            compare(list.currentIndex, 2);
            list.currentIndex = 0;
            keyClick(Qt.Key_Up);
            compare(list.currentIndex, 0);
            select.choose(0);
        }

        function test_typing_jumps_to_the_entry_starting_with_the_letters() {
            compare(UnitTheme.override({ menu: { typeahead: 200 } }), "ok");
            root.chosen = -1;
            long.open();
            compare(long.typeAhead("e"), true);
            compare(long.items()[long.currentIndex].text, "Echo", "the first entry that starts with e, not one that holds it");
            compare(long.typeAhead("T"), true, "no entry starts with et, so t starts a new prefix");
            compare(long.items()[long.currentIndex].text, "Themes");
            compare(long.typeAhead("h"), true);
            compare(long.items()[long.currentIndex].text, "Themes");
            compare(long.typed, "th");
            tryCompare(long, "typed", "", 2000);
            compare(long.typeAhead("b"), true);
            compare(long.items()[long.currentIndex].text, "Beta", "after the pause the letters start again from the current entry");
            compare(long.typeAhead("e"), true);
            compare(long.items()[long.currentIndex].text, "Beta", "two letters narrow the jump");
            long.close();
            root.chosen = 4;
        }

        function test_destroyed_overlay_releases_its_count() {
            const made = Qt.createQmlObject("import qs.Ui\nPopover { width: 80 }", host);
            made.open();
            compare(OverlayState.open, 1);
            made.destroy();
            wait(50);
            compare(OverlayState.open, 0);
        }

        function test_menu_click_triggers_and_closes() {
            menu.open();
            menu.items()[0].clicked();
            compare(root.triggered, 0);
            tryCompare(menu, "opened", false);
        }

        function test_menu_highlights_through_its_cursor() {
            menu.open();
            const items = menu.items();
            const plate = items[0].cursor;
            verify(plate !== null, "the menu hands its entries a cursor");
            compare(plate.shown, true, "an open menu highlights its first reachable entry");
            compare(String(plate.color), String(Qt.color(Theme.menu.item.hover)));
            verify(plate.target === items[0], "the highlighted entry holds the cursor");
            compare(String(items[0].background.color), "#00000000", "the entry draws no fill of its own");
            mouseMove(items[1], 10, 5);
            compare(menu.currentIndex, 0, "the first reading after a key moves nothing");
            mouseMove(items[1], 12, 5);
            compare(menu.currentIndex, 1, "a moved pointer highlights the entry under it");
            menu.move(-1);
            compare(menu.currentIndex, 0);
            // The pointer rests where it was: Qt delivers it hover again
            // while the cursor travels, and a resting pointer must not take
            // the highlight back from the key.
            mouseMove(items[1], 12, 5);
            compare(menu.currentIndex, 0, "a key disarms the pointer");
            mouseMove(items[2], 12, 5);
            compare(menu.currentIndex, 0, "a hover highlights no disabled entry");
            menu.close();
        }

        function selectList(owner) {
            let window = null;
            for (let i = 0; i < owner.resources.length; i++)
                if (owner.resources[i].anchor !== undefined) window = owner.resources[i];
            return window.contentItem.children.find(child => child.currentIndex !== undefined);
        }

        function test_select_list_highlights_through_its_cursor() {
            select.openList();
            const list = selectList(select);
            tryVerify(() => list.itemAtIndex(1) !== null, 1000, "the list builds its entries");
            const first = list.itemAtIndex(0);
            const second = list.itemAtIndex(1);
            // The keys go to the list's own window, which takes the focus
            // before the pointer moves: activating it delivers a hover.
            list.Window.window.requestActivate();
            list.forceActiveFocus();
            tryCompare(list.Window, "active", true);
            tryCompare(list, "activeFocus", true);
            // The window's first key after it takes the focus goes astray
            // under the offscreen platform.
            wait(50);
            keyClick(Qt.Key_Down);
            compare(list.currentIndex, 1);
            mouseMove(second, 10, 5);
            compare(list.currentIndex, 1, "the first reading after a key moves nothing");
            mouseMove(first, 12, 5);
            compare(list.currentIndex, 0, "a moved pointer highlights the entry under it");
            compare(String(first.background.color), String(Qt.color(Theme.select.selected)), "the chosen entry keeps its fill");
            keyClick(Qt.Key_Down);
            compare(list.currentIndex, 1);
            compare(String(second.background.color), "#00000000", "the highlighted entry draws no fill of its own");
            // The pointer rests where it was: Qt delivers it hover again
            // while the cursor travels, and a resting pointer must not take
            // the highlight back from the key.
            mouseMove(first, 12, 5);
            compare(list.currentIndex, 1, "a key disarms the pointer");
            select.choose(0);
        }

        // A fill's box in its window's content item.
        function boxIn(item, window) {
            const p = item.mapToItem(window.contentItem, 0, 0);
            return { x: p.x, y: p.y, width: item.width, height: item.height };
        }
        // Whether a fill `radius` round stays inside the top corners of a
        // container `width` by `height` whose corner is `containerRadius`
        // inside a `border`: every point of the fill's top corner arcs that
        // lies in a corner's square is no farther from that corner's
        // centre than its inner radius, half a pixel allowed.
        function insideCorner(box, radius, width, height, containerRadius, border) {
            const outer = Math.min(containerRadius, width / 2, height / 2);
            const inner = Math.max(0, outer - border);
            const own = Math.min(radius, box.width / 2, box.height / 2);
            for (let i = 0; i <= 32; i++) {
                const angle = Math.PI / 2 * i / 32;
                const y = box.y + own - own * Math.sin(angle);
                for (const [x, centre] of [[box.x + own - own * Math.cos(angle), outer], [box.x + box.width - own + own * Math.cos(angle), width - outer]]) {
                    const inSquare = y < outer && (x < outer || x > width - outer);
                    if (inSquare && Math.hypot(x - centre, y - outer) > inner + 0.5) return false;
                }
            }
            return true;
        }

        function test_the_first_menu_entry_meets_the_border_data() {
            return [
                { tag: "square", theme: {}, flush: true },
                { tag: "rounded", theme: { radius: { sm: 6, md: 12, lg: 16 } }, flush: true },
                { tag: "square entries in a round menu", theme: { radius: { md: 12 }, menu: { item: { radius: 0 } } }, flush: false }
            ];
        }

        // The first entry's highlight reaches the list's border at the top
        // and both sides, with no gutter, and stays inside the menu's drawn
        // corner; entries less round than the corner start lower, inside it.
        function test_the_first_menu_entry_meets_the_border(data) {
            compare(UnitTheme.override(data.theme), "ok");
            menu.open();
            let window = null;
            for (let i = 0; i < menu.resources.length; i++)
                if (menu.resources[i].anchor !== undefined) window = menu.resources[i];
            const plate = menu.items()[0].cursor;
            tryCompare(plate, "opacity", 1);
            tryVerify(() => plate.target === menu.items()[0] && plate.height === menu.items()[0].height, 2000, "the cursor holds the first entry");
            const fill = boxIn(plate, window);
            const border = Theme.border.thin;
            compare(fill.x, border, "the fill meets the left border");
            compare(fill.x + fill.width, window.width - border, "the fill meets the right border");
            if (data.flush) compare(fill.y, border, "the fill meets the top border");
            else verify(fill.y > border, "a square entry starts below a round corner: " + fill.y);
            compare(plate.radius, Theme.menu.item.radius);
            verify(insideCorner(fill, plate.radius, window.width, window.height, Theme.menu.radius, border), "the fill's corners stay inside the menu's corner: " + JSON.stringify(fill));
            menu.close();
        }

        function test_the_first_select_entry_meets_the_border_data() {
            return test_the_first_menu_entry_meets_the_border_data();
        }

        // The list opens on the control's edges, as wide as it; the chosen
        // entry's fill and the highlight on it reach the border at the top
        // and both sides, and the entry's text starts where the field's
        // does.
        function test_the_first_select_entry_meets_the_border(data) {
            compare(UnitTheme.override(data.theme), "ok");
            select.choose(0);
            select.openList();
            const list = selectList(select);
            tryVerify(() => list.itemAtIndex(0) !== null, 1000, "the list builds its entries");
            const entry = list.itemAtIndex(0);
            let popup = null;
            for (let i = 0; i < select.resources.length; i++)
                if (select.resources[i].anchor !== undefined) popup = select.resources[i];
            const border = Theme.border.thin;
            compare(popup.anchor.margins.left, 0);
            compare(popup.width, select.width);
            const fill = boxIn(entry.background, popup);
            compare(fill.x, border, "the chosen fill meets the left border");
            compare(fill.x + fill.width, popup.width - border, "the chosen fill meets the right border");
            if (data.flush) compare(fill.y, border, "the chosen fill meets the top border");
            else verify(fill.y > border, "a square entry starts below a round corner: " + fill.y);
            verify(insideCorner(fill, entry.background.radius, popup.width, popup.height, Theme.menu.radius, border), "the fill's corners stay inside the list's corner: " + JSON.stringify(fill));
            const plate = list.contentItem.children.find(child => child.follow !== undefined);
            tryVerify(() => plate.target === entry && plate.height === entry.height, 2000, "the cursor holds the chosen entry");
            const highlight = boxIn(plate, popup);
            compare(highlight.x, fill.x);
            compare(highlight.y, fill.y);
            compare(highlight.width, fill.width);
            const text = entry.contentItem.mapToItem(popup.contentItem, 0, 0);
            compare(text.x, select.contentItem.x, "the entry's text starts where the field's does");
            select.choose(select.currentIndex);
        }

        // The window of an overlay that declares it.
        function windowOf(owner) {
            for (let i = 0; i < owner.resources.length; i++)
                if (owner.resources[i].anchor !== undefined) return owner.resources[i];
            return null;
        }

        // Whether a point lies inside a rounded rectangle, half a pixel
        // allowed.
        function inRounded(x, y, box) {
            if (x < box.x - 0.5 || x > box.x + box.width + 0.5 || y < box.y - 0.5 || y > box.y + box.height + 0.5) return false;
            const cx = Math.min(Math.max(x, box.x + box.radius), box.x + box.width - box.radius);
            const cy = Math.min(Math.max(y, box.y + box.radius), box.y + box.height - box.radius);
            return Math.hypot(x - cx, y - cy) <= box.radius + 0.5;
        }

        // Points along the four corners of a rounded rectangle, each corner
        // `radii` round in the order top left, top right, bottom right,
        // bottom left.
        function cornerPoints(left, top, right, bottom, radii) {
            const out = [];
            const corners = [[left, top, 1, 1], [right, top, -1, 1], [right, bottom, -1, -1], [left, bottom, 1, -1]];
            for (let c = 0; c < 4; c++) {
                const [x, y, sx, sy] = corners[c];
                const r = radii[c];
                for (let i = 0; i <= 16; i++) {
                    const angle = Math.PI / 2 * i / 16;
                    out.push([x + sx * (r - r * Math.cos(angle)), y + sy * (r - r * Math.sin(angle))]);
                }
            }
            return out;
        }

        // Whether `item`, drawn `radius` round, shows only inside its
        // window's rounded interior: inside the border, the window's drawn
        // `menu.radius` less the border round. What shows is the item's box
        // cut by each clipping ancestor, whose cut edges draw square, and,
        // when an ancestor's layer masks it through a MultiEffect, cut to
        // that mask too; a mask inside the interior keeps it there.
        function drawsInside(item, radius, window) {
            const border = Theme.border.thin;
            const outer = Math.min(Theme.menu.radius, window.width / 2, window.height / 2);
            const inner = { x: border, y: border, width: window.width - 2 * border, height: window.height - 2 * border, radius: Math.max(0, outer - border) };
            const at = boxIn(item, window);
            let left = at.x, top = at.y, right = at.x + at.width, bottom = at.y + at.height;
            const cut = { left: false, top: false, right: false, bottom: false };
            for (let a = item.parent; a !== null && a !== window.contentItem; a = a.parent) {
                if (a.layer.enabled) {
                    const effect = a.parent.children.find(child => String(child).startsWith("QQuickMultiEffect(") && child.maskEnabled);
                    if (effect !== undefined) {
                        const mask = boxIn(effect.maskSource, window);
                        const r = Math.min(effect.maskSource.radius, mask.width / 2, mask.height / 2);
                        return cornerPoints(mask.x, mask.y, mask.x + mask.width, mask.y + mask.height, [r, r, r, r]).every(([x, y]) => inRounded(x, y, inner));
                    }
                }
                if (a.clip) {
                    const c = boxIn(a, window);
                    if (top < c.y) { top = c.y; cut.top = true; }
                    if (left < c.x) { left = c.x; cut.left = true; }
                    if (bottom > c.y + c.height) { bottom = c.y + c.height; cut.bottom = true; }
                    if (right > c.x + c.width) { right = c.x + c.width; cut.right = true; }
                }
            }
            if (right <= left || bottom <= top) return true;
            const own = Math.min(radius, at.width / 2, at.height / 2);
            const radii = [cut.top || cut.left ? 0 : own, cut.top || cut.right ? 0 : own, cut.bottom || cut.right ? 0 : own, cut.bottom || cut.left ? 0 : own];
            return cornerPoints(left, top, right, bottom, radii).every(([x, y]) => inRounded(x, y, inner));
        }

        // A long menu open under a rounded theme, nothing checked, its
        // list at its window's size.
        function openRoundedLong() {
            compare(UnitTheme.override({ radius: { sm: 6, md: 12, lg: 16 }, menu: { maxHeight: 90 } }), "ok");
            root.chosen = -1;
            long.open();
            const window = longWindow();
            // The window's content item takes the window's size a turn after
            // it shows.
            tryCompare(long.scrollArea, "width", window.width - 2 * Theme.border.thin);
            tryCompare(long.scrollArea, "height", window.height - 2 * long.listInset);
            return window;
        }

        // A highlighted entry scrolled half a row past the top stays inside
        // a rounded menu's interior.
        function test_a_rounded_menu_cuts_a_half_scrolled_highlight() {
            const window = openRoundedLong();
            const items = long.items();
            long.currentIndex = 1;
            const plate = items[1].cursor;
            tryVerify(() => plate.target === items[1] && plate.y === items[1].y && plate.opacity === 1, 2000, "the cursor holds the second entry");
            long.scrollArea.contentY = items[1].y + items[1].height / 2;
            const inside = drawsInside(plate, plate.radius, window);
            long.close();
            root.chosen = 4;
            verify(inside, "the highlight half past the top stays inside the corner");
        }

        // The bar's thumb at the top stays inside a rounded menu's interior.
        function test_a_rounded_menu_cuts_its_thumb() {
            const window = openRoundedLong();
            long.scrollArea.bar.hovered = true;
            const thumb = long.scrollArea.bar.thumb;
            compare(thumb.y, 0, "the thumb is at the top");
            const inside = drawsInside(thumb, thumb.radius, window);
            long.scrollArea.bar.hovered = false;
            long.close();
            root.chosen = 4;
            verify(inside, "the thumb at the top stays inside the corner");
        }

        // The long select open on its second entry under a rounded theme,
        // its list at its window's size.
        function openRoundedSelect() {
            compare(UnitTheme.override({ radius: { sm: 6, md: 12, lg: 16 } }), "ok");
            longSelect.choose(1);
            longSelect.openList();
            const window = windowOf(longSelect);
            const list = selectList(longSelect);
            tryVerify(() => list.itemAtIndex(1) !== null && list.height === window.height - 2 * longSelect.listInset, 1000, "the list builds its entries and takes its window's height");
            compare(list.overflowing, true);
            return [window, list];
        }

        // The chosen entry and the highlight on it, scrolled half a row
        // past the top, stay inside a rounded select list's interior.
        function test_a_rounded_select_cuts_a_half_scrolled_choice() {
            const [window, list] = openRoundedSelect();
            const entry = list.itemAtIndex(1);
            const plate = list.contentItem.children.find(child => child.follow !== undefined);
            tryVerify(() => plate.target === entry && plate.y === entry.y && plate.opacity === 1, 2000, "the cursor holds the chosen entry");
            list.contentY = entry.y + entry.height / 2;
            const fill = drawsInside(entry.background, entry.background.radius, window);
            const highlight = drawsInside(plate, plate.radius, window);
            longSelect.choose(0);
            verify(fill, "the chosen fill half past the top stays inside the corner");
            verify(highlight, "the highlight half past the top stays inside the corner");
        }

        // The bar's thumb at the top stays inside a rounded select list's
        // interior.
        function test_a_rounded_select_cuts_its_thumb() {
            const [window, list] = openRoundedSelect();
            const bar = list.children.find(child => child.thumb !== undefined);
            list.contentY = 0;
            bar.hovered = true;
            compare(bar.thumb.y, 0, "the thumb is at the top");
            const inside = drawsInside(bar.thumb, bar.thumb.radius, window);
            bar.hovered = false;
            longSelect.choose(0);
            verify(inside, "the thumb at the top stays inside the corner");
        }

        // A square list keeps its rectangular clip and draws no layer.
        function test_a_square_list_draws_no_layer() {
            menu.open();
            compare(menu.scrollArea.layer.enabled, false);
            menu.close();
            select.openList();
            compare(selectList(select).layer.enabled, false);
            select.choose(select.currentIndex);
        }

        // An entry keeps the bar's strip exactly while the bar shows: a
        // list less than half a pixel past its view shows no bar and keeps
        // no strip.
        function test_a_select_entry_keeps_the_strip_while_the_bar_shows() {
            select.openList();
            const list = selectList(select);
            tryVerify(() => list.itemAtIndex(0) !== null && list.height > 0, 1000, "the list builds its entries");
            const bar = list.children.find(child => child.thumb !== undefined);
            const margin = list.anchors.bottomMargin;
            list.anchors.bottomMargin = margin + 0.3;
            tryVerify(() => list.contentHeight - list.height > 0.2, 1000, "the content passes the view by a fraction: " + (list.contentHeight - list.height));
            compare(bar.visible, false, "no bar for a fraction of a pixel");
            compare(list.itemAtIndex(0).rightPadding, select.sidePadding - Theme.border.thin, "no strip without a bar");
            list.anchors.bottomMargin = Qt.binding(() => select.listInset);
            select.choose(select.currentIndex);
        }

        function test_select_chooses_and_reads_its_role() {
            compare(select.count, 3);
            compare(select.currentText, "one");
            select.choose(2);
            compare(select.currentIndex, 2);
            compare(select.currentText, "three");
            select.choose(7);
            compare(select.currentIndex, 2);
            compare(roled.currentText, "alpha");
            roled.choose(1);
            compare(roled.currentText, "beta");
            select.openList();
            compare(select.listOpen, true);
            compare(OverlayState.open, 1);
            select.choose(1);
            compare(select.listOpen, false);
            compare(OverlayState.open, 0);
        }

        function test_select_activation_is_a_user_choice_only() {
            roled.model = [{ name: "alpha" }, { name: "beta" }];
            roled.currentIndex = 0;
            activations.clear();
            roled.choose(1);
            compare(activations.count, 1);
            compare(activations.signalArguments[0][0], 1);
            roled.choose(1);
            compare(activations.count, 2, "the current entry is still a user choice");
            roled.choose(-1);
            roled.choose(2);
            compare(activations.count, 2, "invalid entries emit nothing");
            roled.model = [{ name: "new alpha" }, { name: "new beta" }];
            roled.currentIndex = 0;
            compare(activations.count, 2, "model and index updates do not activate");
            roled.model = [{ name: "alpha" }, { name: "beta" }];
        }

        function test_choosing_the_current_entry_keeps_the_index_binding() {
            root.wanted = 0;
            bound.choose(0);
            root.wanted = 2;
            compare(bound.currentIndex, 2);
            bound.choose(1);
            root.wanted = 0;
            compare(bound.currentIndex, 1);
        }

        function test_enter_opens_the_closed_select() {
            root.Window.window.requestActivate();
            select.forceActiveFocus();
            tryCompare(select, "activeFocus", true);
            keyClick(Qt.Key_Return);
            compare(select.listOpen, true);
            select.choose(0);
            compare(select.listOpen, false);
        }

        function test_select_keys_move_the_choice_while_closed() {
            // A popup window shown by an earlier test may still hold the
            // window focus; the keys go to the test window.
            root.Window.window.requestActivate();
            select.forceActiveFocus();
            tryCompare(select, "activeFocus", true);
            keyClick(Qt.Key_Down);
            compare(select.currentIndex, 1);
            keyClick(Qt.Key_Up);
            compare(select.currentIndex, 0);
        }

        function tipWindow(owner) {
            for (let i = 0; i < owner.resources.length; i++)
                if (owner.resources[i].anchor !== undefined) return owner.resources[i];
            return null;
        }

        // A short tip is its text's width; a long one stops at
        // `tooltip.maxWidth` and wraps inside the padding.
        function test_tooltip_wraps_past_its_maximum_width() {
            const short = tipWindow(tip);
            const long = tipWindow(longTip);
            const shortLabel = short.contentItem.children[1];
            const longLabel = long.contentItem.children[1];
            compare(short.width, Math.ceil(shortLabel.implicitWidth) + 2 * Theme.tooltip.paddingX);
            compare(long.width, Theme.tooltip.maxWidth + 2 * Theme.tooltip.paddingX);
            verify(longLabel.lineCount > 1, "the long tip wraps: " + longLabel.lineCount);
            compare(long.height, longLabel.height + 2 * Theme.tooltip.paddingY);
            compare(longLabel.x, Theme.tooltip.paddingX);
            // Under a pill theme with a small pad the text moves in until it
            // clears the round end.
            compare(UnitTheme.override({ tooltip: { radius: 4096, paddingX: 2 } }), "ok");
            tryVerify(() => shortLabel.x > 2, 1000, "the rounded tip's text moved in: " + shortLabel.x);
        }

        function test_tooltip_opens_after_the_delay_and_not_under_an_overlay() {
            compare(UnitTheme.override({ tooltip: { delay: 50 } }), "ok");
            mouseMove(host, host.width / 2, host.height / 2);
            tryCompare(tip, "opened", true, 2000);
            mouseMove(root, root.width - 1, root.height - 1);
            tryCompare(tip, "opened", false);
            popover.open();
            mouseMove(host, host.width / 2, host.height / 2);
            wait(200);
            compare(tip.opened, false);
            popover.close();
            mouseMove(root, root.width - 1, root.height - 1);
            // The other order: a shown tooltip closes when an overlay opens.
            mouseMove(host, host.width / 2, host.height / 2);
            tryCompare(tip, "opened", true, 2000);
            popover.open();
            compare(tip.opened, false);
            popover.close();
            mouseMove(root, root.width - 1, root.height - 1);
        }

        // A press closes the tooltip and it stays closed while the pointer
        // rests, so it never covers what the press opened; it opens again
        // once the pointer left the item and came back.
        function test_tooltip_stays_closed_after_a_press_until_the_pointer_leaves() {
            compare(UnitTheme.override({ tooltip: { delay: 50 } }), "ok");
            mouseMove(host, host.width / 2, host.height / 2);
            tryCompare(tip, "opened", true, 2000);
            mouseClick(host, host.width / 2, host.height / 2);
            compare(tip.opened, false);
            wait(200);
            compare(tip.opened, false);
            mouseMove(root, root.width - 1, root.height - 1);
            mouseMove(host, host.width / 2, host.height / 2);
            tryCompare(tip, "opened", true, 2000);
            mouseMove(root, root.width - 1, root.height - 1);
        }

        function test_toast_draws_its_tone_and_dismisses() {
            compare(toast.tokens.foreground, Theme.badge.tone.success.foreground);
            compare(toast.width, Theme.toast.width);
            mouseClick(toast.closeButton);
            compare(dismissals.count, 1);
        }
    }
}
