import QtQuick
import qs.Commons
import qs.Ui

// One Settings page header row. The list page and each plugin page use it
// so the title, leading controls and trailing controls share one height,
// `size.control.md` unless an item is taller, every item centred on it,
// and the body does not move during a push or pop. The title draws in
// `h3`, the role of every window title (design-quality.md). A leading
// icon button puts its glyph's ink, not its box, on the content edge, and
// the title starts `control.gap` after that ink; the button's box and
// focus ring reach into the window's inset (design-layout.md § Headers).
Item {
    id: root

    property string text: ""
    property string role: "h3"
    property Item menu: null
    property alias leading: leadingSlot.data
    property alias trailing: trailingSlot.data
    readonly property alias titleButton: titleControl
    readonly property alias label: titleLabel
    readonly property real titleHeight: menu === null ? titleLabel.implicitHeight : titleControl.implicitHeight
    readonly property real rowHeight: Math.max(Theme.size.control.md, titleHeight, leadingSlot.implicitHeight, trailingSlot.implicitHeight)
    // How far the leading item's box stands left of its glyph's ink, and
    // right of it: an IconButton's glyph insets, zero for any other item.
    readonly property real leadingStart: leadingSlot.children.length > 0 && leadingSlot.children[0].glyphStart !== undefined ? leadingSlot.children[0].glyphStart : 0
    readonly property real leadingEnd: leadingSlot.children.length > 0 && leadingSlot.children[0].glyphEnd !== undefined ? leadingSlot.children[0].glyphEnd : 0

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
        x: -Math.round(root.leadingStart)
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
        x: leadingSlot.width > 0 ? Math.round(leadingSlot.x + leadingSlot.width - root.leadingEnd) + Theme.control.gap : 0
        width: Math.max(0, root.width - x - (trailingSlot.width > 0 ? trailingSlot.width + Theme.control.gap : 0))
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
