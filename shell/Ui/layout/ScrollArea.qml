import QtQuick
import qs.Commons
import qs.Ui

// A vertically scrolling area for content taller than it: children go in
// the flickable's content item and the content height follows them. The
// content is always `rightInset` narrower than the area, and the embedded
// bar, `bar`, sits inside that inset while the content overflows, so no
// content lies under it and the content's width never depends on its own
// height: wrapping text would otherwise move the layout a turn after it
// settled, or feed a binding its own input. With `barOverContent` the
// content spans the area and the bar draws over its right strip: for rows
// whose fills reach the area's edge and whose own end padding keeps that
// strip clear while the content overflows, as a menu's entries do. The area
// takes a press, a drag and the wheel only while its content overflows, so
// a press on an area that fits reaches what lies under it, such as a scrim
// that closes a full-screen view.
Flickable {
    id: root

    property real rightInset: Theme.scrollArea.gutter
    property bool barOverContent: false
    readonly property real measuredContentHeight: measureContentHeight()
    readonly property bool overflowing: scrollBar.needed
    readonly property alias bar: scrollBar

    clip: true
    contentWidth: width - (barOverContent ? 0 : rightInset)
    contentHeight: measuredContentHeight
    boundsBehavior: Flickable.StopAtBounds
    interactive: overflowing

    function measureContentHeight() {
        let bottom = 0;
        for (const child of contentItem.children) {
            if (!child.visible && root.visible) continue;
            const childHeight = child.height > 0 ? child.height : child.implicitHeight;
            bottom = Math.max(bottom, child.y + childHeight);
        }
        return bottom;
    }

    function checkInset() {
        if (!barOverContent && Theme.scrollArea.gutter > rightInset)
            console.error("ScrollArea: gutter=" + Theme.scrollArea.gutter + " exceeds rightInset=" + rightInset);
    }
    Component.onCompleted: checkInset()
    onRightInsetChanged: checkInset()
    onBarOverContentChanged: checkInset()

    HoverHandler { id: hover }

    ScrollBar {
        id: scrollBar
        flickable: root
        hovered: hover.hovered
    }
}
