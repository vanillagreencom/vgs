import QtQuick
import QtTest
import qs.Commons
import qs.Ui
import qs.Unit

// Pane owns the layout contract for an inset container: header, body and
// footer share one content edge, the scroll bar sits in the right inset
// strip, fit-to-content caps at a maximum height, and a rounded container
// clears its drawn corner through the shared inset rule.
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
        function divider(of) { return of.children[3]; }
        function footerDivider(of) { return of.children[4]; }
        function body(of) { return of.scrollArea.contentItem.children[0].children[0]; }

        function test_header_body_and_footer_share_the_content_edge() {
            compare(pane.contentInset, Theme.inset.window);
            compare(headerSlot(pane).x, pane.contentInset);
            compare(headerSlot(pane).width, pane.width - 2 * pane.contentInset);
            // The body sits on the content edge; the viewport reaches the
            // ring's room past it.
            compare(body(pane).mapToItem(pane, 0, 0).x, pane.contentInset);
            compare(body(pane).width, pane.width - 2 * pane.contentInset);
            compare(scroll(pane).x, pane.contentInset - pane.ringRoom);
            compare(footerSlot(pane).x, pane.contentInset);
            compare(footerSlot(pane).y, scroll(pane).y + scroll(pane).height - pane.ringRoom + pane.footerGap);
            compare(footerSlot(pane).width, pane.width - 2 * pane.contentInset);
        }

        function test_scroll_bar_sits_inside_the_right_inset_strip() {
            const contentRight = body(pane).mapToItem(pane, 0, 0).x + body(pane).width;
            const insetRight = pane.width - pane.contentInset;
            compare(contentRight, insetRight);
            verify(scroll(pane).bar.x + scroll(pane).x >= contentRight, "bar starts in the right inset strip");
            verify(scroll(pane).bar.x + scroll(pane).bar.width + scroll(pane).x <= pane.width, "bar stays inside the pane");
        }

        function test_fit_to_content_caps_the_body() {
            compare(fitted.implicitHeight, 120);
            compare(fitted.scrollArea.height, 120 - 2 * fitted.contentInset - headerSlot(fitted).height - fitted.headerGap + 2 * fitted.ringRoom);
            verify(fitted.scrollArea.overflowing, "the capped pane scrolls its body");
        }

        // A 4 px pad under a 20 px corner: the content's top stands 4 in,
        // dy = 20 - 4 = 16 and reach = 20 - 4 = 16, so the corner stays one
        // step inside the curve only at 20 - sqrt(16^2 - 16^2) = 20.
        function test_radius_sets_the_effective_inset_floor() {
            compare(UnitTheme.override({ radius: { md: 20 }, inset: { window: 4 } }), "ok");
            const expected = 20;
            tryCompare(pane, "contentInset", expected);
            compare(body(pane).width, pane.width - 2 * expected);
            compare(UnitTheme.override({ radius: { md: 0 }, inset: { window: 18 } }), "ok");
            tryCompare(pane, "contentInset", 18);
            compare(body(pane).width, pane.width - 36);
        }

        function test_header_and_footer_keep_one_gap_when_the_body_is_empty() {
            compare(emptyBody.bodyContentHeight, 0);
            compare(footerSlot(emptyBody).y, headerSlot(emptyBody).y + headerSlot(emptyBody).height + emptyBody.gap);
            compare(emptyBody.implicitHeight, 2 * emptyBody.contentInset + headerSlot(emptyBody).height + emptyBody.gap + footerSlot(emptyBody).height);
            compare(hiddenBody.bodyContentHeight, 0);
            compare(footerSlot(hiddenBody).y, headerSlot(hiddenBody).y + headerSlot(hiddenBody).height + hiddenBody.gap);
            compare(hiddenBody.implicitHeight, 2 * hiddenBody.contentInset + headerSlot(hiddenBody).height + hiddenBody.gap + footerSlot(hiddenBody).height);
        }

        // A plugin that owns its look hands its own padding and radius.
        function test_explicit_padding_and_radius_win() {
            emptyBody.padding = 7;
            compare(emptyBody.contentInset, 7);
            compare(headerSlot(emptyBody).x, 7);
            emptyBody.cornerRadius = 40;
            tryVerify(() => emptyBody.contentInset > 7, 1000, "a rounded explicit corner moves the content in");
            emptyBody.padding = Qt.binding(() => emptyBody.paddingOf(emptyBody.container));
            emptyBody.cornerRadius = Qt.binding(() => emptyBody.radiusOf(emptyBody.container));
        }

        // The divider under the header shows while the body is scrolled.
        function test_the_header_divider_shows_while_scrolled() {
            compare(divider(pane).visible, false);
            scroll(pane).contentY = 20;
            compare(divider(pane).visible, true);
            compare(divider(pane).width, pane.width - 2 * pane.contentInset);
            verify(divider(pane).y >= headerSlot(pane).y + headerSlot(pane).height && divider(pane).y + divider(pane).height <= body(pane).mapToItem(pane, 0, 0).y + scroll(pane).contentY, "the divider sits in the header gap");
            scroll(pane).contentY = 0;
            compare(divider(pane).visible, false);
        }

        // The divider over the footer shows while more of the body lies
        // below the view, and sits in the footer gap.
        function test_the_footer_divider_shows_while_more_lies_below() {
            verify(scroll(pane).contentHeight > scroll(pane).height, "the fixture overflows");
            scroll(pane).contentY = 0;
            compare(footerDivider(pane).visible, true);
            compare(footerDivider(pane).width, pane.width - 2 * pane.contentInset);
            verify(footerDivider(pane).y >= scroll(pane).y + scroll(pane).height - pane.ringRoom && footerDivider(pane).y + footerDivider(pane).height <= footerSlot(pane).y, "the divider sits in the footer gap");
            scroll(pane).contentY = scroll(pane).contentHeight - scroll(pane).height;
            compare(footerDivider(pane).visible, false);
            scroll(pane).contentY = 0;
        }

        // A focus ring around a row on the content's left and top edges
        // lies inside the viewport, so the scroll area's clip keeps it.
        function test_a_ring_on_the_content_edge_stays_in_the_viewport() {
            const row = body(pane).children[0];
            const ringLeft = row.mapToItem(scroll(pane), -Theme.focusRing.offset - Theme.focusRing.width, 0).x;
            const ringTop = row.mapToItem(scroll(pane), 0, -Theme.focusRing.offset - Theme.focusRing.width).y;
            verify(ringLeft >= 0, "the ring's left edge " + ringLeft + " is inside the viewport");
            verify(ringTop >= 0, "the ring's top edge " + ringTop + " is inside the viewport");
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
