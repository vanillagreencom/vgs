import QtQuick
import QtTest
import qs.Commons
import qs.Ui
import qs.Unit

// The spacing rhythm, read from drawn components: Button, TextField,
// Select and SegmentedControl stand `size.control.md` tall with their text
// `control.paddingX` from the edge; ListItem, MenuItem and Field start
// their content `row.paddingX` in; every icon-and-text pair stands
// `control.gap` apart. A theme that moves the shared token moves every
// component that follows it.
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
            same(() => field.children[0].x, row, "field label x");
            same(() => field.children[1].x, row, "field control row x");
            same(() => field.children[1].width, field.width - 2 * row, "field control row width");

            const gap = Theme.control.gap;
            same(() => gapOf(button.contentItem), gap, "button icon gap");
            same(() => iconed.leftPadding, pad + Theme.icon.size.sm + gap, "text field icon gap");
            same(() => gapOf(item.contentItem), gap, "list item icon gap");
            same(() => gapOf(entry.contentItem), gap, "menu item icon gap");
            same(() => gapOf(badge.children[0]), gap, "badge icon gap");
            same(() => gapOf(toast.children[0]), gap, "toast icon gap");
            same(() => check.contentItem.leftPadding - check.indicator.width, gap, "checkbox gap");
        }

        function test_components_share_the_rhythm() {
            compare(Theme.control.paddingX, 9);
            compare(Theme.control.gap, 7);
            compare(Theme.row.paddingX, 12);
            checkRhythm();
        }

        function test_one_token_moves_every_component() {
            compare(UnitTheme.override({ size: { control: { md: 34 } }, control: { paddingX: 13, gap: 3 }, row: { paddingX: 20 } }), "ok");
            compare(Theme.control.paddingX, 13);
            compare(Theme.row.paddingX, 20);
            checkRhythm();
        }
    }
}
