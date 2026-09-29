import QtQuick
import qs.Commons
import qs.Ui

// The heading of one section of a panel: an eyebrow title and an optional
// description under it, with the theme's space below. `Section` owns the
// space above. It spans its parent, as a heading does, unless given a
// width; a surface that insets its rows sets `leftPadding` and
// `rightPadding` to match.
Column {
    id: root

    property string text: ""
    property string description: ""
    // The width the eyebrow and the description share: the column's own,
    // less its padding, since a positioner does not narrow its children.
    readonly property real bodyWidth: width - leftPadding - rightPadding

    width: parent ? parent.width : implicitWidth

    topPadding: 0
    bottomPadding: Theme.sectionHeader.paddingBottom
    spacing: Theme.sectionHeader.gap

    Label {
        role: "eyebrow"
        text: root.text
        width: root.bodyWidth
        elide: Text.ElideRight
    }
    Label {
        role: "hint"
        text: root.description
        visible: root.description !== ""
        width: root.bodyWidth
        wrapMode: Text.Wrap
    }
}
