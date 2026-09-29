import QtQuick
import qs.Commons
import qs.Ui

// One Settings page header row. The list page and each plugin page use it
// so the title, leading controls and trailing controls share one height
// rule and the body does not move during a push or pop.
Item {
    id: root

    property string text: ""
    property string role: "h2"
    property Item menu: null
    property alias leading: leadingSlot.data
    property alias trailing: trailingSlot.data
    readonly property alias titleButton: titleControl
    readonly property alias label: titleLabel
    readonly property real titleHeight: Math.max(titleLabel.implicitHeight + Theme.titleButton.underlineGap + Theme.titleButton.underline, Theme.icon.size.sm)
    readonly property real rowHeight: Math.max(titleHeight, leadingSlot.implicitHeight, trailingSlot.implicitHeight)

    implicitHeight: rowHeight
    height: rowHeight

    function largestImplicit(items, axis) {
        let found = 0;
        for (const item of items) found = Math.max(found, item[axis]);
        return found;
    }

    function anchorMenu() {
        if (menu !== null && menu.parent !== titleControl) menu.parent = titleControl;
    }

    Component.onCompleted: anchorMenu()
    onMenuChanged: anchorMenu()

    Item {
        id: leadingSlot
        width: implicitWidth
        height: root.height
        implicitWidth: root.largestImplicit(children, "implicitWidth")
        implicitHeight: root.largestImplicit(children, "implicitHeight")
    }

    Label {
        id: titleLabel
        role: root.role
        text: root.text
        visible: root.menu === null
        x: leadingSlot.width > 0 ? leadingSlot.width + Theme.space.sm : 0
        width: Math.max(0, root.width - x - (trailingSlot.width > 0 ? trailingSlot.width + Theme.space.sm : 0))
        elide: Text.ElideRight
        anchors.verticalCenter: parent.verticalCenter
    }

    TitleButton {
        id: titleControl
        role: root.menu === null ? "item" : root.role
        text: root.text
        menu: root.menu
        visible: root.menu !== null
        x: titleLabel.x
        width: Math.min(implicitWidth, titleLabel.width)
        anchors.verticalCenter: parent.verticalCenter
    }

    Item {
        id: trailingSlot
        x: root.width - width
        width: implicitWidth
        height: root.height
        implicitWidth: root.largestImplicit(children, "implicitWidth")
        implicitHeight: root.largestImplicit(children, "implicitHeight")
    }
}
