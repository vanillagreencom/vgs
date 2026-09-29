import QtQuick
import qs.Commons
import qs.Ui

// A vertically scrolling area for content taller than it: children go in
// the flickable's content item and the content height follows them. While
// the content overflows, the content is `scrollArea.gutter` narrower than
// the area and the embedded bar sits in that gutter, so no content lies
// under it; `bar` is that bar.
Flickable {
    id: root

    readonly property bool overflowing: contentHeight > height
    readonly property alias bar: scrollBar

    clip: true
    contentWidth: overflowing ? width - Theme.scrollArea.gutter : width
    contentHeight: contentItem.childrenRect.height
    boundsBehavior: Flickable.StopAtBounds

    HoverHandler { id: hover }

    ScrollBar {
        id: scrollBar
        flickable: root
        hovered: hover.hovered
    }
}
