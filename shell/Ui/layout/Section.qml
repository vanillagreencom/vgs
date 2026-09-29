import QtQuick
import qs.Commons
import qs.Ui

// A titled block of rows. The space above the heading is `stack.section`
// no matter which Column owns it: the section subtracts the parent's
// spacing, and the first item takes no top padding. Rows inside the section
// are spaced by `stack.row`. The header inset matches row padding by
// default, so headings align with row content.
Column {
    id: root

    property string title: ""
    property string description: ""
    property real headerInset: Theme.row.paddingX
    default property alias rows: content.data

    readonly property real parentSpacing: parent && parent.spacing !== undefined ? parent.spacing : 0

    width: parent ? parent.width : implicitWidth
    topPadding: Positioner.isFirstItem ? 0 : Math.max(0, Theme.stack.section - parentSpacing)
    spacing: 0

    SectionHeader {
        text: root.title
        description: root.description
        leftPadding: root.headerInset
        rightPadding: root.headerInset
        width: root.width
    }

    Column {
        id: content
        width: root.width
        spacing: Theme.stack.row
    }
}
