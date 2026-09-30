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

    // A fitted pane its host holds shorter than its fitted height, as a
    // popup held inside a short output does.
    Pane {
        id: held
        x: 260
        y: 240
        width: 200
        height: 140
        fitToContent: true
        maximumHeight: 400
        container: "dialog"
        header: [ Label { text: "Header"; role: "h3"; width: parent.width } ]
        Rectangle { width: parent.width; height: 300; color: "transparent" }
        footer: [ Button { text: "Apply"; variant: "secondary" } ]
    }

    // A panel over a click target: a bare header label, a short body and
    // a footer bound to the content width, fitted under a cap.
    Component {
        id: overTarget
        Item {
            width: 240
            height: 300
            property alias pane: layer
            property alias spy: clicks
            MouseArea { id: target; anchors.fill: parent }
            SignalSpy { id: clicks; target: target; signalName: "clicked" }
            Pane {
                id: layer
                anchors.fill: parent
                container: "panel"
                fitToContent: true
                maximumHeight: 300
                header: [ Label { role: "h3"; text: "Themes" } ]
                Section {
                    title: "Wallpaper"
                    Item { width: layer.contentWidth; height: 72 }
                }
                footer: [ Column { width: layer.contentWidth; Button { width: parent.width; text: "Add" } } ]
            }
        }
    }
    // A fitted pane whose body takes the room the pane leaves it.
    Component {
        id: filled
        Pane {
            id: layer
            width: 240
            container: "panel"
            fitToContent: true
            maximumHeight: 300
            header: [ Item { width: 10; height: 20 } ]
            Item { width: layer.contentWidth; height: layer.bodyRoom }
            footer: [ Item { width: 10; height: 30 } ]
        }
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

        // A bare header label sizes the header slot by its implicit width,
        // beside a footer bound to the content width, with no binding loop:
        // the runner fails a file that logs one.
        function test_a_bare_header_beside_a_footer_loops_nothing() {
            const made = overTarget.createObject(root);
            const label = headerSlot(made.pane).children[0];
            compare(headerSlot(made.pane).implicitWidth, label.implicitWidth);
            wait(50);
            made.destroy();
        }

        // The body fits, so a press on its empty part, 10 px above the
        // viewport's bottom, reaches the target under the pane.
        function test_a_press_on_a_body_that_fits_reaches_what_lies_under_it() {
            const made = overTarget.createObject(root);
            tryVerify(() => made.pane.bodyContentHeight > 72, 1000, "the body is laid out");
            verify(!made.pane.scrollArea.overflowing, "the body fits");
            const view = made.pane.scrollArea;
            mouseClick(made, 120, view.mapToItem(made, 0, view.height - made.pane.ringRoom - 10).y);
            compare(made.spy.count, 1);
            made.destroy();
        }

        // The body's room at the cap: 300 less 12 inset twice, the 20 px
        // header, the 30 px footer and a 12 px gap after the header and
        // before the footer is 300 - 24 - 20 - 30 - 24 = 202. A body that
        // takes it fills the pane to its cap and does not scroll.
        function test_a_body_sized_from_its_room_fills_the_pane_to_its_cap() {
            const made = filled.createObject(root);
            compare(made.bodyRoom, 202);
            tryCompare(made, "bodyContentHeight", 202);
            compare(made.height, 300);
            verify(!made.scrollArea.overflowing, "the filled body does not scroll");
            compare(made.scrollArea.interactive, false);
            made.destroy();
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

        // A host shorter than the fitted height keeps the footer inside
        // the box it gives: the body shrinks and scrolls, and the pane
        // still asks for its fitted height.
        function test_a_short_host_keeps_the_footer_inside() {
            verify(held.cappedHeight > held.height, "the fixture is held short");
            compare(held.implicitHeight, held.cappedHeight);
            const foot = footerSlot(held);
            verify(foot.y + foot.height <= held.height - held.contentInset + 0.5, "footer ends at " + (foot.y + foot.height) + " in a " + held.height + " box");
            verify(scroll(held).contentHeight > scroll(held).height, "the body scrolls");
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

        // An overlay draws no container: its content sits inset.overlay,
        // 32, in, and a 30 pixel corner, which would push content 4 in to
        // 30, moves nothing, since there is no corner to clear.
        function test_an_overlay_sits_its_inset_in_and_clears_no_corner() {
            const made = Qt.createQmlObject('import QtQuick\nimport qs.Ui\nPane { width: 300; height: 200; container: "overlay"; header: [ Item { width: 10; height: 10 } ] }', root, "overlay");
            compare(made.cornerRadius, 0);
            tryCompare(made, "contentInset", 32);
            compare(UnitTheme.override({ radius: { md: 30 }, inset: { overlay: 4 } }), "ok");
            tryCompare(made, "contentInset", 4);
            wait(50);
            compare(made.contentInset, 4);
            made.destroy();
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
