import QtQuick
import QtTest
import qs.Commons
import qs.Ui
import qs.Unit

// Pane owns the layout contract for an inset container: header, body and
// footer share one content edge, the scroll bar sits in the right inset
// strip, fit-to-content caps at a maximum height, and a rounded container's
// effective inset grows to clear its radius.
Item {
    id: root
    width: 500
    height: 500

    Pane {
        id: pane
        width: 240
        height: 200
        container: "window"
        header: [ Label { text: "Header"; role: "h2"; width: parent.width } ]
        Repeater { model: 12; ListItem { required property int index; width: parent.width; text: "Row " + index } }
        footer: [ Button { text: "Apply"; variant: "secondary" } ]
    }

    Pane {
        id: fitted
        y: 240
        width: 240
        fitToContent: true
        maximumHeight: 120
        container: "dialog"
        header: [ Label { text: "Tall"; role: "h3"; width: parent.width } ]
        Rectangle { width: parent.width; height: 220; color: "transparent" }
    }

    Pane {
        id: emptyBody
        x: 260
        width: 200
        fitToContent: true
        container: "dialog"
        header: [ Label { text: "Header"; role: "h3"; width: parent.width } ]
        footer: [ Button { text: "Apply"; variant: "secondary" } ]
    }

    Pane {
        id: hiddenBody
        x: 260
        y: 120
        width: 200
        fitToContent: true
        container: "dialog"
        header: [ Label { text: "Header"; role: "h3"; width: parent.width } ]
        Rectangle { width: parent.width; height: 80; color: "transparent"; visible: false }
        footer: [ Button { text: "Apply"; variant: "secondary" } ]
    }

    TestCase {
        name: "pane"
        when: windowShown

        function init() { UnitTheme.reset(); }
        function headerSlot(of) { return of.children[0]; }
        function scroll(of) { return of.scrollArea; }
        function footerSlot(of) { return of.children[2]; }

        function test_header_body_and_footer_share_the_content_edge() {
            compare(pane.contentInset, Theme.inset.window);
            compare(headerSlot(pane).x, pane.contentInset);
            compare(headerSlot(pane).width, pane.width - 2 * pane.contentInset);
            compare(scroll(pane).x, pane.contentInset);
            compare(scroll(pane).contentWidth, pane.width - 2 * pane.contentInset);
            compare(footerSlot(pane).x, pane.contentInset);
            compare(footerSlot(pane).y, scroll(pane).y + scroll(pane).height + pane.footerGap);
            compare(footerSlot(pane).width, pane.width - 2 * pane.contentInset);
        }

        function test_scroll_bar_sits_inside_the_right_inset_strip() {
            const contentRight = scroll(pane).x + scroll(pane).contentWidth;
            const insetRight = pane.width - pane.contentInset;
            compare(contentRight, insetRight);
            verify(scroll(pane).bar.x + scroll(pane).x >= contentRight, "bar starts in the right inset strip");
            verify(scroll(pane).bar.x + scroll(pane).bar.width + scroll(pane).x <= pane.width, "bar stays inside the pane");
        }

        function test_fit_to_content_caps_the_body() {
            compare(fitted.implicitHeight, 120);
            compare(fitted.scrollArea.height, 120 - 2 * fitted.contentInset - headerSlot(fitted).height - fitted.headerGap);
            verify(fitted.scrollArea.overflowing, "the capped pane scrolls its body");
        }

        function test_radius_sets_the_effective_inset_floor() {
            compare(UnitTheme.override({ radius: { md: 20 }, inset: { panel: 12 } }), "ok");
            compare(pane.contentInset, 20);
            compare(scroll(pane).contentWidth, pane.width - 40);
        }

        function test_header_and_footer_keep_one_gap_when_the_body_is_empty() {
            compare(emptyBody.bodyContentHeight, 0);
            compare(footerSlot(emptyBody).y, headerSlot(emptyBody).y + headerSlot(emptyBody).height + emptyBody.gap);
            compare(emptyBody.implicitHeight, 2 * emptyBody.contentInset + headerSlot(emptyBody).height + emptyBody.gap + footerSlot(emptyBody).height);
            compare(hiddenBody.bodyContentHeight, 0);
            compare(footerSlot(hiddenBody).y, headerSlot(hiddenBody).y + headerSlot(hiddenBody).height + hiddenBody.gap);
            compare(hiddenBody.implicitHeight, 2 * hiddenBody.contentInset + headerSlot(hiddenBody).height + hiddenBody.gap + footerSlot(hiddenBody).height);
        }

        function test_dialog_padding_token_sets_the_dialog_container_inset() {
            compare(UnitTheme.override({ dialog: { padding: 31 } }), "ok");
            compare(emptyBody.contentInset, 31);
            compare(headerSlot(emptyBody).x, 31);
            compare(UnitTheme.override({ inset: { dialog: 27 } }), "ok");
            compare(Theme.dialog.padding, 27);
            compare(emptyBody.contentInset, 27);
            compare(headerSlot(emptyBody).x, 27);
        }
    }
}
