pragma Singleton
import QtQuick
import QtQuick.Window
import qs.Commons

// Which overlays are open, for the tooltip policy: a tooltip does not open
// while a popover, a menu or a select list is open, so hover under an
// open overlay never raises one. Overlays register on open and leave on
// close; the count is what a tooltip reads.
QtObject {
    id: state

    property int open: 0

    function opened() { open += 1; }
    function closed() { if (open > 0) open -= 1; }

    // The output `item` draws on, or null while it has none yet.
    function outputOf(item) {
        const window = item === null || item === undefined ? null : item.Window.window;
        return window === null || window === undefined || window.screen === null || window.screen === undefined ? null : window.screen;
    }

    // The widest an overlay anchored to `item` may draw: `cap`, and never
    // wider than its output less `size.window.gutter` a side.
    function widthFor(item, cap) {
        const output = outputOf(item);
        return output === null ? cap : Math.max(1, Math.min(cap, output.width - 2 * Theme.size.window.gutter));
    }
}
