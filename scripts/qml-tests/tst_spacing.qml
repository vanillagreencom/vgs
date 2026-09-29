import QtQuick
import QtTest
import qs.Commons
import qs.Ui
import qs.Unit

// The spacing rhythm, read from drawn components: Button, TextField,
// Select and SegmentedControl stand `size.control.md` tall with their text
// `control.paddingX` from the edge; ListItem and MenuItem start their
// content `row.paddingX` in; Field starts at `field.paddingX`, zero by
// default so a container owns its edge. Controls share `control.gap`, and
// ListItem owns its larger icon gap. A theme that moves the shared token
// moves every component that follows it.
Item {
    id: root
    width: 400
    height: 600

    Button { id: button; text: "Publish"; iconName: "check" }
    TextField { id: input; width: 200; y: 40 }
    TextField { id: iconed; leadingIcon: "search"; width: 200; y: 80 }
    Select { id: select; width: 200; y: 120; model: ["one", "two"] }
    SegmentedControl { id: segmented; y: 160; model: ["Day", "Week"] }
    ListItem { id: item; text: "Plugin updates"; iconName: "package"; width: 300; y: 200 }
    MenuItem { id: entry; text: "Open"; iconName: "folder"; width: 200; y: 240 }
    Field { id: field; label: "Name"; width: 300; y: 280; TextField { width: parent.width } }
    Badge { id: badge; text: "new"; iconName: "check"; y: 340 }
    Toast { id: toast; title: "Saved"; iconName: "check"; y: 370 }
    Checkbox { id: check; text: "Pin"; y: 470 }
    Text {
        id: clearingProbeText
        text: "A message long enough to wrap after the inset grows and makes the line narrower."
        width: clearingProbe.width - 2 * clearingProbe.inset
        wrapMode: Text.WordWrap
    }
    ClearingInset {
        id: clearingProbe
        pad: 4
        radius: 4096
        width: 120
        height: clearingProbeText.implicitHeight + 8
        step: 4
        top: 4
    }

    TestCase {
        name: "spacing"
        when: windowShown

        function init() { UnitTheme.reset(); }

        // The gap between the first two children of a row: an icon and
        // the text after it.
        function gapOf(row) { return row.children[1].x - (row.children[0].x + row.children[0].width); }

        function segment(index) { return segmented.children[0].children[index]; }

        // A positioner lays its children out on the next polish, so a
        // position is waited for rather than read at once.
        function same(read, want, what) { tryVerify(() => read() === want, 1000, what + ": got " + read() + ", want " + want); }
        function close(read, want, what) { tryVerify(() => Math.abs(read() - want) <= 0.01, 1000, what + ": got " + read() + ", want " + want); }

        function checkRhythm() {
            const height = Theme.size.control.md;
            const pad = Theme.control.paddingX;
            same(() => button.height, height, "button height");
            same(() => input.height, height, "text field height");
            same(() => select.height, height, "select height");
            same(() => segmented.height, height, "segmented height");
            same(() => button.leftPadding, pad, "button padding");
            same(() => button.contentItem.x, pad, "button text x");
            same(() => input.leftPadding, pad, "text field padding");
            same(() => select.contentItem.x, pad, "select text x");
            same(() => segment(0).contentItem.x, pad, "segment text x");
            same(() => segment(0).width - segment(0).contentItem.x - segment(0).contentItem.width, pad, "segment right padding");

            const row = Theme.row.paddingX;
            same(() => item.contentItem.x, row, "list item content x");
            same(() => entry.contentItem.x, row, "menu item content x");
            const fieldPad = Theme.field.paddingX;
            same(() => field.children[0].x, fieldPad, "field label x");
            same(() => field.children[1].x, fieldPad, "field control row x");
            same(() => field.children[1].width, field.width - 2 * fieldPad, "field control row width");

            const gap = Theme.control.gap;
            same(() => gapOf(button.contentItem), gap, "button icon gap");
            same(() => iconed.leftPadding, pad + Theme.icon.size.sm + gap, "text field icon gap");
            same(() => gapOf(item.contentItem), Theme.listItem.iconGap, "list item icon gap");
            same(() => gapOf(entry.contentItem), gap, "menu item icon gap");
            same(() => gapOf(badge.children[0]), gap, "badge icon gap");
            same(() => gapOf(toast.children[0]), gap, "toast icon gap");
            same(() => check.contentItem.leftPadding - check.indicator.width, gap, "checkbox gap");
        }

        function test_components_share_the_rhythm() {
            compare(Theme.control.paddingX, 9);
            compare(Theme.control.gap, 7);
            compare(Theme.row.paddingX, 12);
            compare(Theme.field.paddingX, 0);
            compare(Theme.listItem.iconGap, 12);
            checkRhythm();
            same(() => toast.children[0].x, Theme.toast.padding, "toast default inset");
            same(() => toast.children[0].width, toast.width - 2 * Theme.toast.padding, "toast default width");
        }

        function test_one_token_moves_every_component() {
            compare(UnitTheme.override({ size: { control: { md: 34 } }, control: { paddingX: 13, gap: 3 }, row: { paddingX: 20 }, field: { paddingX: 5 }, listItem: { iconGap: 16 } }), "ok");
            compare(Theme.control.paddingX, 13);
            compare(Theme.row.paddingX, 20);
            compare(Theme.field.paddingX, 5);
            compare(Theme.listItem.iconGap, 16);
            checkRhythm();
        }

        // The least whole inset from the pad whose content corner, `top`
        // down, keeps `step` inside a corner circle of radius `corner`.
        function leastClearing(pad, corner, top, step) {
            for (let x = pad; x < corner + step; x++)
                if (corner - Math.hypot(Math.max(0, corner - x), Math.max(0, corner - top)) >= step) return x;
            return Math.ceil(corner + step);
        }

        function test_toast_text_clears_a_rounded_corner() {
            compare(UnitTheme.override({ radius: { md: 32 } }), "ok");
            const pad = Theme.toast.padding;
            tryVerify(() => toast.children[0].x > pad, 1000, "toast rounded inset grew");
            const inset = leastClearing(pad, Math.min(Theme.toast.radius, toast.width / 2, toast.height / 2), toast.children[0].y, Theme.space.xs);
            verify(inset > pad && inset < Math.min(Theme.toast.radius, toast.height / 2), "the toast's row clears inside the curve, not past the whole corner: " + inset);
            close(() => toast.children[0].x, inset, "toast rounded inset");
            close(() => toast.width - (toast.children[0].x + toast.children[0].width), inset, "toast rounded right inset");
        }

        function test_clearing_inset_settles_after_wrapped_height_grows() {
            clearingProbe.reset();
            tryVerify(() => clearingProbe.inset > clearingProbe.pad, 1000, "clearing inset grew");
            close(() => clearingProbe.inset, Math.ceil(Inset.clearing(clearingProbe.pad, clearingProbe.radius, clearingProbe.width, clearingProbe.height, clearingProbe.step, clearingProbe.top)), "clearing inset fixed point");
        }
    }
}
