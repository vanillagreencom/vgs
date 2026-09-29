import QtQuick

// The pointing hand over a clickable item: declared as a direct child of
// the item that takes the click, it shows `Qt.PointingHandCursor` while the
// pointer rests on that item. It is the one place the shell names the hand;
// `scripts/check-pointer-cursor.py` refuses a click area without it.
// Qt picks no cursor from a disabled item, so a disabled control shows the
// cursor of what lies under it, the arrow on a bare surface. A text input
// inside the item keeps its I-beam, since Qt asks the topmost item under the
// pointer first. The handler is passive: it takes no press and blocks no
// hover from the items under it.
HoverHandler {
    cursorShape: Qt.PointingHandCursor
}
