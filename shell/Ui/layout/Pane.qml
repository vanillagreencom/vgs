import QtQuick
import qs.Commons
import qs.Ui

// One inset box for a container: optional header, scrolling body and
// optional footer all start at the same content edge. The scroll bar lives
// in the right inset strip, outside the body's content width, so content
// never moves when it overflows. The footer stays outside the scrolling
// body, so its actions stay in view while the body scrolls. While the body
// is scrolled, a divider spans the inset box under the header, and while
// more of it lies below the view, one spans it over the footer. `padding`
// and `cornerRadius` default to the container class's tokens; a plugin that
// owns its look (appearance.md) hands its own. The viewport reaches the
// focus ring's room past the content's left, top and bottom edges, so a
// ring drawn around a row on an edge is never clipped.
Item {
    id: root

    property string container: "panel"
    property real padding: paddingOf(container)
    property real cornerRadius: radiusOf(container)
    property bool fitToContent: false
    property real maximumHeight: 0
    property real gap: Theme.stack.group
    property real bodySpacing: Theme.stack.group
    // The width of a divider under the header while the body is scrolled,
    // and its colour.
    property real dividerWidth: Theme.divider.thickness
    property color dividerColor: Theme.divider.color
    property alias header: headerSlot.data
    default property alias body: bodyColumn.data
    property alias footer: footerSlot.data
    // The room a focus ring takes outside its row.
    readonly property real ringRoom: Theme.focusRing.width + Theme.focusRing.offset
    readonly property real contentInset: clearingInset.inset
    readonly property real contentWidth: Math.max(0, width - 2 * contentInset)
    readonly property real bodyContentHeight: bodyColumn.implicitHeight
    readonly property real headerHeight: headerSlot.children.length > 0 ? headerSlot.implicitHeight : 0
    readonly property real footerHeight: footerSlot.children.length > 0 ? footerSlot.implicitHeight : 0
    readonly property bool contentBelowHeader: bodyContentHeight > 0 || footerHeight > 0
    readonly property real headerGap: headerHeight > 0 && contentBelowHeader ? gap : 0
    readonly property real footerGap: footerHeight > 0 && bodyContentHeight > 0 ? gap : 0
    readonly property real uncappedHeight: 2 * contentInset + headerHeight + headerGap + bodyContentHeight + footerGap + footerHeight
    readonly property real cappedHeight: maximumHeight > 0 ? Math.min(uncappedHeight, maximumHeight) : uncappedHeight
    // The height the box lays out in: a fitted pane's capped height, or
    // less when its host gives it less, such as a popup held inside a
    // short output; the body then scrolls and the footer stays inside.
    readonly property real boxHeight: fitToContent ? (height > 0 ? Math.min(cappedHeight, height) : cappedHeight) : height
    readonly property alias scrollArea: scroll

    implicitWidth: Math.max(headerSlot.implicitWidth, bodyColumn.implicitWidth, footerSlot.implicitWidth) + 2 * contentInset
    implicitHeight: fitToContent ? cappedHeight : uncappedHeight

    ClearingInset {
        id: clearingInset
        pad: root.padding
        radius: root.cornerRadius
        width: root.width
        height: root.boxHeight
        top: root.padding
    }

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

    // The viewport starts `ringRoom` left of and above the content edge and
    // ends that far below it; the body sits `ringRoom` into the content, so
    // the visible edges are the inset box's.
    ScrollArea {
        id: scroll
        x: root.contentInset - root.ringRoom
        y: root.contentInset + root.headerHeight + root.headerGap - root.ringRoom
        width: Math.max(0, root.width - root.contentInset + root.ringRoom)
        // A container inset narrower than the bar's gutter still leaves the
        // gutter, so the bar never covers the content.
        rightInset: Math.max(root.contentInset, Theme.scrollArea.gutter)
        height: root.ringRoom * 2 + Math.max(0, root.boxHeight - 2 * root.contentInset - root.headerHeight - root.headerGap - root.footerGap - root.footerHeight)

        Item {
            width: scroll.contentWidth
            implicitHeight: bodyColumn.implicitHeight + 2 * root.ringRoom
            height: implicitHeight

            Column {
                id: bodyColumn
                x: root.ringRoom
                y: root.ringRoom
                width: parent.width - root.ringRoom
                spacing: root.bodySpacing
            }
        }
    }

    Item {
        id: footerSlot
        x: root.contentInset
        y: scroll.y + scroll.height - root.ringRoom + root.footerGap
        width: root.contentWidth
        height: root.footerHeight
        implicitHeight: childrenRect.height
        implicitWidth: childrenRect.width
    }

    Rectangle {
        id: headerDivider
        x: root.contentInset
        y: root.contentInset + root.headerHeight + Math.round((root.headerGap - height) / 2)
        width: root.contentWidth
        height: root.dividerWidth
        color: root.dividerColor
        visible: root.headerHeight > 0 && scroll.contentY > 0
    }

    Rectangle {
        id: footerDivider
        x: root.contentInset
        y: footerSlot.y - root.footerGap + Math.round((root.footerGap - height) / 2)
        width: root.contentWidth
        height: root.dividerWidth
        color: root.dividerColor
        visible: root.footerHeight > 0 && scroll.contentY + scroll.height < scroll.contentHeight - 1
    }
}
