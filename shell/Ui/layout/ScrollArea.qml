import QtQuick
import QtQuick.Window
import QtQuick.Templates as T
import qs.Commons
import qs.Ui
import "../foundation/KeyNavLogic.js" as KeyNavLogic

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
// scrolls by the wheel, the keys, its bar and a touch drag, never by a
// mouse drag: it takes no mouse button, so a mouse press and drag reaches
// the item under the pointer, which selects text where text is selectable.
// It takes the wheel and a touch only while its content overflows, so a
// touch on an area that fits reaches what lies under it, such as a scrim
// that closes a full-screen view.
Flickable {
    id: root

    property real rightInset: Theme.scrollArea.gutter
    property bool barOverContent: false
    property bool keyboardScroll: false
    readonly property real measuredContentHeight: measureContentHeight()
    readonly property bool overflowing: scrollBar.needed
    readonly property alias bar: scrollBar
    readonly property Item focusProxy: keyboardFocus

    clip: true
    activeFocusOnTab: false
    contentWidth: width - (barOverContent ? 0 : rightInset)
    contentHeight: measuredContentHeight
    boundsBehavior: Flickable.StopAtBounds
    interactive: overflowing
    acceptedButtons: Qt.NoButton

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
    function reveal(item) {
        if (item === null || item === undefined) return;
        const at = item.mapToItem(contentItem, 0, 0);
        contentY = KeyNavLogic.revealY(at.y, item.height, contentY, height, Theme.focusRing.offset + Theme.focusRing.width);
    }
    function scrollBy(delta) {
        contentY = Math.max(0, Math.min(contentHeight - height, contentY + delta));
    }
    Component.onCompleted: checkInset()
    onRightInsetChanged: checkInset()
    onBarOverContentChanged: checkInset()

    function handleScrollKey(event) {
        const action = KeyNavLogic.intent(event.key, event.modifiers, "vertical", false);
        if (action === "prev") root.scrollBy(-Theme.row.height);
        else if (action === "next") root.scrollBy(Theme.row.height);
        else if (action === "pagePrev") root.scrollBy(-root.height);
        else if (action === "pageNext") root.scrollBy(root.height);
        else if (action === "first") root.contentY = 0;
        else if (action === "last") root.contentY = Math.max(0, root.contentHeight - root.height);
        else return false;
        return true;
    }

    Connections {
        target: root === null ? null : root.Window.window
        function onActiveFocusItemChanged() {
            if (root === null || root.Window.window === null) return;
            const item = root.Window.window.activeFocusItem;
            if (item !== null && item !== root && root.contentItem !== null && KeyNavLogic.contains(root.contentItem, item)) {
                root.reveal(item);
                return;
            }
        }
    }

    HoverHandler { id: hover }

    T.Control {
        id: keyboardFocus
        parent: root
        anchors.fill: parent
        z: -1
        visible: root.keyboardScroll
        enabled: root.keyboardScroll
        focusPolicy: root.keyboardScroll ? Qt.StrongFocus : Qt.NoFocus
        activeFocusOnTab: root.keyboardScroll
        Keys.onPressed: event => { event.accepted = root.handleScrollKey(event); }
    }

    ScrollBar {
        id: scrollBar
        flickable: root
        hovered: hover.hovered
    }

    FocusRing {
        parent: root
        target: keyboardFocus
        visible: root.keyboardScroll && keyboardFocus.visualFocus
    }
}
