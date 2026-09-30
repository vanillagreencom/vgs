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

    // The room an output leaves a surface: its width and height less
    // `size.window.gutter` a side, or no bound without an output. Every
    // overlay, summoned popup and window that sizes itself to its output
    // reads it here.
    function room(output) {
        if (output === null || output === undefined) return { width: Infinity, height: Infinity };
        const gutter = 2 * Theme.size.window.gutter;
        return { width: Math.max(1, output.width - gutter), height: Math.max(1, output.height - gutter) };
    }

    // The widest an overlay anchored to `item` may draw: `cap`, and never
    // wider than its output's room.
    function widthFor(item, cap) {
        return Math.min(cap, room(outputOf(item)).width);
    }
}
