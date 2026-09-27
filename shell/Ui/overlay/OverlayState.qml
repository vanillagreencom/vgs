pragma Singleton
import QtQuick

// Which overlays are open, for the tooltip policy: a tooltip does not open
// while a popover, a menu or a select list is open, so hover under an
// open overlay never raises one. Overlays register on open and leave on
// close; the count is what a tooltip reads.
QtObject {
    id: state

    property int open: 0

    function opened() { open += 1; }
    function closed() { if (open > 0) open -= 1; }
}
