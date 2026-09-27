import QtQuick
import QtQuick.Templates as T
import qs.Commons

// A vertically scrolling area for content taller than it: children go in
// the flickable's content item and the content height follows them. The
// bar shows while the content overflows, drawn from the scroll tokens.
Flickable {
    id: root

    clip: true
    contentWidth: width
    contentHeight: contentItem.childrenRect.height
    boundsBehavior: Flickable.StopAtBounds

    T.ScrollBar.vertical: T.ScrollBar {
        id: bar
        parent: root
        x: root.width - width
        height: root.height
        policy: T.ScrollBar.AsNeeded
        hoverEnabled: true
        implicitWidth: Theme.scrollArea.barWidth
        contentItem: Rectangle {
            implicitWidth: Theme.scrollArea.barWidth
            radius: Theme.scrollArea.barRadius
            color: bar.pressed || bar.hovered ? Theme.scrollArea.barHover : Theme.scrollArea.bar
            visible: bar.size < 1
        }
    }
}
