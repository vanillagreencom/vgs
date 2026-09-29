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
    }
}
