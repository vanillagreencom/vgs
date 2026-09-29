import QtQuick
import qs.Commons
import qs.Ui

// A vertically scrolling area for content taller than it: children go in
// the flickable's content item and the content height follows them. While
// the content overflows, the content is `scrollArea.gutter` narrower than
// the area and the embedded bar sits in that gutter, so no content lies
// under it; `bar` is that bar. The overflow is judged once the content has
// settled, a turn of the event loop after it moves: text that wraps grows
// when the gutter narrows it, so a binding would feed its own input.
// Narrower content is never shorter, so the judgement cannot flip back.
Flickable {
    id: root

    property bool overflowing: false
    readonly property alias bar: scrollBar

    function judgeOverflow() { overflowing = contentHeight > height; }
    onContentHeightChanged: Qt.callLater(judgeOverflow)
    onHeightChanged: Qt.callLater(judgeOverflow)

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
