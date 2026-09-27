import QtQuick
import QtTest
import qs.Commons
import qs.Ui
import qs.Unit

// The overlays through the stand-in popup window: a popover opens and
// closes and counts in OverlayState, a menu moves its highlight and
// triggers by key and closes on a trigger, a select chooses by index and
// reads its text role, a tooltip opens after the delay while the pointer
// rests and not under an open overlay, and a toast draws its tone. The
// nested sandbox proves placement, real keys and dismissal.
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
    }
    Select { id: select; y: 40; model: ["one", "two", "three"] }
    Select { id: roled; y: 80; textRole: "name"; model: [{ name: "alpha" }, { name: "beta" }] }
    property int wanted: 0
    Select { id: bound; y: 120; model: ["one", "two", "three"]; currentIndex: root.wanted }
    Toast { id: toast; y: 120; title: "Saved"; message: "to disk"; tone: "success"; iconName: "check" }
    property int triggered: -1
    SignalSpy { id: dismissals; target: toast; signalName: "dismissed" }

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

        function test_menu_width_follows_its_widest_entry() {
            let window = null;
            for (let i = 0; i < menu.resources.length; i++)
                if (menu.resources[i].anchor !== undefined) window = menu.resources[i];
            verify(window !== null, "the menu holds a popup window");
            verify(wide.implicitWidth > Theme.menu.minWidth, "the wide entry passes the minimum: " + wide.implicitWidth);
            menu.open();
            // The window's width is whole pixels.
            verify(window.width + 1 >= wide.implicitWidth + 2 * Theme.menu.padding, "the window holds the widest entry: " + window.width + " for " + wide.implicitWidth);
            compare(wide.width, window.width - 2 * Theme.menu.padding);
            menu.close();
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

        function test_toast_draws_its_tone_and_dismisses() {
            compare(toast.tokens.foreground, Theme.badge.tone.success.foreground);
            compare(toast.width, Theme.toast.width);
            mouseClick(toast.closeButton);
            compare(dismissals.count, 1);
        }
    }
}
