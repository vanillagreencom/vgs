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
// pointer moved since the last key. The nested sandbox proves placement,
// real keys and dismissal.
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
            compare(menu.currentIndex, -1);
            menu.move(1);
            compare(menu.currentIndex, 0);
            compare(menu.items()[0].highlighted, true);
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
            // it less the padding on each side, the scroll bar's strip being
            // the right padding.
            verify(wide.implicitWidth + 2 * Theme.menu.padding > Theme.menu.maxWidth, "the wide entry passes the cap: " + wide.implicitWidth);
            compare(window.width, Theme.menu.maxWidth);
            compare(wide.width, window.width - 2 * Theme.menu.padding);
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
            compare(window.height, 90 + 2 * Theme.menu.padding);
            compare(long.scrollArea.overflowing, true);
            compare(long.scrollArea.bar.visible, true);
            // The entries leave the bar its gutter.
            compare(long.items()[0].width, long.scrollArea.width - Theme.scrollArea.gutter);
            long.close();
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
            compare(item.rightPadding, Theme.menu.item.paddingX + Theme.icon.size.sm + item.spacing);
            compare(long.items()[0].indicator.visible, false);
            compare(long.items()[0].rightPadding, Theme.menu.item.paddingX);
            long.close();
            root.chosen = -1;
            long.open();
            compare(long.currentIndex, -1, "with no checked entry nothing is highlighted");
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
            compare(long.items()[long.currentIndex].text, "Bar", "after the pause the letters start again");
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
            compare(plate.shown, false, "an open menu with nothing highlighted shows no cursor");
            compare(String(plate.color), String(Qt.color(Theme.menu.item.hover)));
            menu.move(1);
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

        // The list opens `menu.padding` left of the control and that much
        // wider on each side, so an entry's text starts where the field's
        // does; every entry leaves the right padding for the scroll bar,
        // overflowing or not.
        function test_select_list_text_lines_up_with_the_field() {
            select.openList();
            const list = selectList(select);
            tryVerify(() => list.itemAtIndex(0) !== null, 1000, "the list builds its entries");
            const entry = list.itemAtIndex(0);
            let popup = null;
            for (let i = 0; i < select.resources.length; i++)
                if (select.resources[i].anchor !== undefined) popup = select.resources[i];
            compare(popup.anchor.margins.left, -Theme.menu.padding);
            compare(popup.width, select.width + 2 * Theme.menu.padding);
            compare(list.x, Theme.menu.padding);
            compare(entry.leftPadding, select.leftPadding);
            compare(entry.width, list.width - Theme.menu.padding);
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
