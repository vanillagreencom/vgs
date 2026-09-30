import QtQuick
import QtQuick.Window
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
    Dialog {
        id: emptyBody
        x: 260
        y: 300
        title: "Download wallpaper?"
        message: "The file is ready."
        actions: [{ label: "Cancel", role: "cancel" }, { label: "Download", role: "accept" }]
    }
    Dialog {
        id: hiddenBody
        x: 260
        y: 420
        title: "Apply theme?"
        actions: [{ label: "Cancel", role: "cancel" }, { label: "Apply", role: "accept" }]
        Label { role: "body"; text: "Hidden"; visible: false }
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
        function pane(of) { return of.children[1]; }
        function headerColumn(of) { return pane(of).children[0].children[0]; }
        function titleLabel(of) { return headerColumn(of).children[0]; }
        function messageLabel(of) { return headerColumn(of).children[1]; }
        function footer(of) { return pane(of).children[2].children[0]; }
        function headerSlot(of) { return pane(of).children[0]; }
        function footerSlot(of) { return pane(of).children[2]; }
        function spinner(of) { return footer(of).children[0]; }
        function ring(button) { return button.background.children[button.background.children.length - 1]; }

        function test_draws_its_tokens() {
            compare(dialog.width, Theme.dialog.width);
            compare(String(card(dialog).color), String(Qt.color(Theme.dialog.background)));
            compare(String(card(dialog).border.color), String(Qt.color(Theme.dialog.border)));
            compare(card(dialog).radius, Theme.dialog.radius);
            compare(pane(dialog).contentInset, Theme.dialog.padding);
            compare(headerColumn(dialog).spacing, Theme.dialog.gap);
            compare(titleLabel(dialog).role, Theme.dialog.titleRole);
            compare(titleLabel(dialog).text, "Download wallpapers?");
            compare(messageLabel(dialog).role, Theme.dialog.bodyRole);
            compare(dialog.height, pane(dialog).implicitHeight);
            compare(pane(dialog).scrollArea.rightInset, pane(dialog).contentInset);
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

        // expected-log: Dialog: no action role named "confirm" -- the test names an unknown action role on purpose
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
            compare(pane(three).scrollArea.contentItem.children[0].children[0].children[0].visible, false);
        }

        function test_actions_keep_one_gap_under_the_header_when_the_body_is_empty() {
            for (const ofDialog of [emptyBody, hiddenBody]) {
                const p = pane(ofDialog);
                compare(p.bodyContentHeight, 0);
                compare(footerSlot(ofDialog).y, headerSlot(ofDialog).y + headerSlot(ofDialog).height + p.gap);
                compare(ofDialog.implicitHeight, 2 * p.contentInset + p.headerHeight + p.gap + p.footerHeight);
            }
        }

        function test_tall_content_scrolls_under_the_maximum_height() {
            const tall = Qt.createQmlObject("import QtQuick\nimport qs.Ui\nDialog { width: 360; availableHeight: 200; title: \"Tall\"; Rectangle { width: parent.width; height: 400; color: \"transparent\" } }", root);
            tryCompare(tall, "implicitHeight", 160);
            const p = pane(tall);
            verify(p.scrollArea.overflowing, "the body scrolls when the fitted height is capped");
            tall.destroy();
        }

        function test_the_default_maximum_height_comes_from_the_screen() {
            const window = Qt.createQmlObject("import QtQuick\nimport QtQuick.Window\nimport qs.Ui\nWindow { width: 300; height: 300; visible: true; Dialog { id: d; objectName: \"dialog\"; width: 240; title: \"Screen\"; Rectangle { width: parent.width; height: 4000; color: \"transparent\" } } }", root);
            wait(0);
            const made = window.contentItem.children[0];
            const screenHeight = made.screenHeight();
            verify(screenHeight > 0, "the test window has a screen");
            tryCompare(made, "maximumHeight", screenHeight * Theme.dialog.maxHeightShare);
            window.destroy();
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

        function test_padding_changes_reach_the_pane_inset() {
            compare(UnitTheme.override({ dialog: { padding: 31 } }), "ok");
            compare(pane(emptyBody).contentInset, 31);
            compare(headerSlot(emptyBody).x, 31);
            compare(UnitTheme.override({ inset: { dialog: 27 } }), "ok");
            compare(Theme.dialog.padding, 27);
            compare(pane(emptyBody).contentInset, 27);
            compare(headerSlot(emptyBody).x, 27);
        }
    }
}
