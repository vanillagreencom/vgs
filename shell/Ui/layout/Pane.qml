import QtQuick
import qs.Commons
import qs.Ui

// One inset box for a container: optional header, scrolling body and
// optional footer all start at the same content edge. The scroll bar lives
// in the right inset strip, outside the body's content width, so content
// never moves when it overflows.
Item {
    id: root

    property string container: "panel"
    property bool fitToContent: false
    property real maximumHeight: 0
    property real gap: Theme.pane.gap
    property real bodySpacing: Theme.pane.gap
    property alias header: headerSlot.data
    default property alias body: bodyColumn.data
    property alias footer: footerSlot.data
    readonly property real contentInset: Math.max(paddingOf(container), radiusOf(container))
    readonly property real contentWidth: Math.max(0, width - 2 * contentInset)
    readonly property real bodyContentHeight: bodyColumn.implicitHeight
    readonly property real headerHeight: headerSlot.children.length > 0 ? headerSlot.implicitHeight : 0
    readonly property real footerHeight: footerSlot.children.length > 0 ? footerSlot.implicitHeight : 0
    readonly property bool contentBelowHeader: bodyContentHeight > 0 || footerHeight > 0
    readonly property real headerGap: headerHeight > 0 && contentBelowHeader ? gap : 0
    readonly property real footerGap: footerHeight > 0 && bodyContentHeight > 0 ? gap : 0
    readonly property real uncappedHeight: 2 * contentInset + headerHeight + headerGap + bodyContentHeight + footerGap + footerHeight
    readonly property real cappedHeight: maximumHeight > 0 ? Math.min(uncappedHeight, maximumHeight) : uncappedHeight
    readonly property alias scrollArea: scroll

    implicitWidth: Math.max(headerSlot.implicitWidth, bodyColumn.implicitWidth, footerSlot.implicitWidth) + 2 * contentInset
    implicitHeight: fitToContent ? cappedHeight : uncappedHeight

    function paddingOf(name) {
        switch (name) {
        case "dialog": return Theme.dialog.padding;
        case "popover": return Theme.popover.padding;
        case "panel": return Theme.surface.padding;
        case "window": return Theme.inset.window;
        }
        console.error("Pane: no padding rule named " + JSON.stringify(name));
        return Theme.surface.padding;
    }

    function radiusOf(name) {
        switch (name) {
        case "dialog": return Theme.dialog.radius;
        case "popover": return Theme.popover.radius;
        case "window":
        case "panel": return Theme.surface.radius;
        }
        console.error("Pane: no radius rule named " + JSON.stringify(name));
        return Theme.surface.radius;
    }

    Item {
        id: headerSlot
        x: root.contentInset
        y: root.contentInset
        width: root.contentWidth
        height: root.headerHeight
        implicitHeight: childrenRect.height
        implicitWidth: childrenRect.width
    }

    ScrollArea {
        id: scroll
        x: root.contentInset
        y: root.contentInset + root.headerHeight + root.headerGap
        width: Math.max(0, root.width - root.contentInset)
        rightInset: root.contentInset
        height: root.fitToContent ? Math.max(0, root.cappedHeight - 2 * root.contentInset - root.headerHeight - root.headerGap - root.footerGap - root.footerHeight) : Math.max(0, root.height - y - root.contentInset - root.footerGap - root.footerHeight)

        Column {
            id: bodyColumn
            width: scroll.contentWidth
            spacing: root.bodySpacing
        }
    }

    Item {
        id: footerSlot
        x: root.contentInset
        y: scroll.y + scroll.height + root.footerGap
        width: root.contentWidth
        height: root.footerHeight
        implicitHeight: childrenRect.height
        implicitWidth: childrenRect.width
    }
}
