import QtQuick
import QtTest
import qs.Commons
import qs.Ui
import qs.Unit

// Dialog: the card, the title and the message drawn from the `dialog`
// tokens; the accept action focused first without a ring; Enter and Return
// pressing the focused action or the accept action, Escape rejecting; Tab
// and Backtab cycling the enabled actions with the ring and never leaving
// the dialog; a press answering with the action's role; the default
// variant per role and an unknown role read as cancel; `busy` and a
// disabled action answering nothing and fading; content under the message;
// and a theme change reaching the card and the roles.
Item {
    id: root
    width: 500
    height: 600

    Button { id: outside; text: "Outside" }
    Dialog {
        id: dialog
        y: 40
        title: "Download wallpapers?"
        message: "Nord ships 12 wallpapers, 42 MB."
        actions: [{ label: "Not now", role: "cancel" }, { label: "Download", role: "accept" }]
        Label { id: extra; role: "code"; text: "vgs-themes/nord.tar.gz" }
    }
    Dialog {
        id: three
        y: 300
        title: "Remove acme.weather?"
        actions: [{ label: "Keep", role: "cancel" }, { label: "Later", role: "cancel", enabled: false }, { label: "Remove", role: "accept", variant: "danger" }]
    }
    Dialog {
        id: blocked
        y: 420
        title: "Install gum?"
        actions: [{ label: "Not now", role: "cancel" }, { label: "Install", role: "accept", enabled: false }]
    }
    SignalSpy { id: accepts; target: dialog; signalName: "accepted" }
    SignalSpy { id: rejects; target: dialog; signalName: "rejected" }
    SignalSpy { id: threeAccepts; target: three; signalName: "accepted" }
    SignalSpy { id: threeRejects; target: three; signalName: "rejected" }
    SignalSpy { id: blockedAccepts; target: blocked; signalName: "accepted" }

    TestCase {
        name: "dialog"
        when: windowShown

        function init() {
            UnitTheme.reset();
            dialog.busy = false;
            for (const spy of [accepts, rejects, threeAccepts, threeRejects, blockedAccepts]) spy.clear();
            outside.forceActiveFocus();
        }

        function card(of) { return of.children[0]; }
        function column(of) { return of.children[1]; }
        function titleLabel(of) { return column(of).children[0]; }
        function messageLabel(of) { return column(of).children[1]; }
        function spinner(of) { return column(of).children[3].children[0]; }
        function ring(button) { return button.background.children[button.background.children.length - 1]; }

        function test_draws_its_tokens() {
            compare(dialog.width, Theme.dialog.width);
            compare(String(card(dialog).color), String(Qt.color(Theme.dialog.background)));
            compare(String(card(dialog).border.color), String(Qt.color(Theme.dialog.border)));
            compare(card(dialog).radius, Theme.dialog.radius);
            compare(column(dialog).x, Theme.dialog.padding);
            compare(column(dialog).spacing, Theme.dialog.gap);
            compare(titleLabel(dialog).role, Theme.dialog.titleRole);
            compare(titleLabel(dialog).text, "Download wallpapers?");
            compare(messageLabel(dialog).role, Theme.dialog.bodyRole);
            compare(dialog.height, column(dialog).implicitHeight + 2 * Theme.dialog.padding);
        }

        function test_accept_action_takes_the_focus_without_a_ring() {
            const [notNow, download] = dialog.buttons();
            dialog.forceActiveFocus();
            compare(download.activeFocus, true);
            // A click focuses its action; the next time the dialog takes
            // the focus, the accept action holds it again.
            mouseClick(notNow);
            compare(notNow.activeFocus, true);
            outside.forceActiveFocus();
            dialog.forceActiveFocus();
            compare(download.activeFocus, true);
            compare(notNow.activeFocus, false);
            compare(download.visualFocus, false);
            compare(ring(download).visible, false);
        }

        function test_enter_and_return_accept_and_escape_rejects() {
            dialog.forceActiveFocus();
            keyClick(Qt.Key_Return);
            compare(accepts.count, 1);
            keyClick(Qt.Key_Enter);
            compare(accepts.count, 2);
            keyClick(Qt.Key_Escape);
            compare(rejects.count, 1);
            compare(accepts.count, 2);
        }

        function test_enter_presses_the_focused_action() {
            dialog.forceActiveFocus();
            keyClick(Qt.Key_Tab);
            compare(dialog.buttons()[0].activeFocus, true);
            keyClick(Qt.Key_Return);
            compare(rejects.count, 1);
            compare(accepts.count, 0);
        }

        function test_tab_cycles_the_actions_with_the_ring_and_stays_inside() {
            dialog.forceActiveFocus();
            const [notNow, download] = dialog.buttons();
            keyClick(Qt.Key_Tab);
            compare(notNow.activeFocus, true);
            compare(notNow.visualFocus, true);
            compare(ring(notNow).visible, true);
            keyClick(Qt.Key_Tab);
            compare(download.activeFocus, true);
            compare(ring(download).visible, true);
            keyClick(Qt.Key_Backtab);
            compare(notNow.activeFocus, true);
            keyClick(Qt.Key_Backtab);
            compare(download.activeFocus, true);
            for (let i = 0; i < 5; i++) {
                keyClick(Qt.Key_Tab);
                compare(outside.activeFocus, false, "Tab " + i + " left the dialog");
            }
        }

        function test_tab_skips_a_disabled_action() {
            three.forceActiveFocus();
            const [keep, later, remove] = three.buttons();
            compare(remove.activeFocus, true);
            keyClick(Qt.Key_Tab);
            compare(keep.activeFocus, true);
            keyClick(Qt.Key_Tab);
            compare(remove.activeFocus, true);
            compare(later.enabled, false);
        }

        function test_a_press_answers_with_the_action_role() {
            const [notNow, download] = dialog.buttons();
            mouseClick(download);
            compare(accepts.count, 1);
            mouseClick(notNow);
            compare(rejects.count, 1);
        }

        function test_variants_follow_the_role_or_the_action() {
            const [notNow, download] = dialog.buttons();
            compare(download.variant, "primary");
            compare(notNow.variant, "tertiary");
            tryCompare(notNow.background, "color", Qt.color(Theme.button.variant.tertiary.background));
            const remove = three.buttons()[2];
            compare(remove.variant, "danger");
            tryCompare(remove.background, "color", Qt.color(Theme.button.variant.danger.background));
        }

        function test_unknown_role_is_read_as_cancel() {
            const odd = Qt.createQmlObject("import qs.Ui\nDialog { actions: [{ label: \"Go\", role: \"confirm\" }] }", root);
            const spy = Qt.createQmlObject("import QtTest\nSignalSpy { signalName: \"rejected\" }", root);
            spy.target = odd;
            compare(odd.acceptIndex, -1);
            odd.trigger(0);
            compare(spy.count, 1);
            spy.destroy();
            odd.destroy();
        }

        function test_busy_disables_the_actions_and_answers_nothing() {
            dialog.forceActiveFocus();
            dialog.busy = true;
            for (const button of dialog.buttons()) {
                compare(button.enabled, false);
                fuzzyCompare(button.opacity, Theme.opacity.disabled, 0.001);
            }
            compare(spinner(dialog).visible, true);
            keyClick(Qt.Key_Return);
            keyClick(Qt.Key_Escape);
            keyClick(Qt.Key_Tab);
            compare(outside.activeFocus, false);
            dialog.trigger(dialog.acceptIndex);
            compare(accepts.count, 0);
            compare(rejects.count, 0);
            dialog.busy = false;
            compare(spinner(dialog).visible, false);
            for (const button of dialog.buttons()) compare(button.opacity, 1);
            keyClick(Qt.Key_Return);
            compare(accepts.count, 1);
        }

        function test_a_disabled_accept_action_answers_nothing() {
            blocked.forceActiveFocus();
            const install = blocked.buttons()[1];
            fuzzyCompare(install.opacity, Theme.opacity.disabled, 0.001);
            keyClick(Qt.Key_Return);
            keyClick(Qt.Key_Enter);
            blocked.trigger(blocked.acceptIndex);
            compare(blockedAccepts.count, 0);
            // The dialog itself holds the focus, and Tab still stays inside.
            keyClick(Qt.Key_Tab);
            compare(blocked.buttons()[0].activeFocus, true);
            keyClick(Qt.Key_Tab);
            compare(blocked.buttons()[0].activeFocus, true);
        }

        function test_content_sits_between_the_message_and_the_actions() {
            compare(extra.visible, true);
            const top = extra.mapToItem(dialog, 0, 0).y;
            const message = messageLabel(dialog);
            verify(top >= message.y + message.height, "the content starts under the message");
            const actions = dialog.buttons()[0].mapToItem(dialog, 0, 0).y;
            verify(top + extra.height <= actions, "the content ends above the actions");
            compare(column(three).children[2].visible, false);
        }

        function test_theme_change_reaches_the_card_and_the_roles() {
            const before = String(card(dialog).color);
            compare(UnitTheme.override({ palette: { background: "#ffffff", foreground: "#000000" }, dialog: { titleRole: "h2", bodyRole: "hint" } }), "ok");
            verify(String(card(dialog).color) !== before, "the palette moves the card");
            compare(String(card(dialog).color), String(Qt.color(Theme.dialog.background)));
            compare(titleLabel(dialog).role, "h2");
            compare(titleLabel(dialog).font.pixelSize, Theme.text.h2.size);
            compare(messageLabel(dialog).role, "hint");
        }
    }
}
