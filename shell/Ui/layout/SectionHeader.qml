import QtQuick
import qs.Commons
import qs.Ui

// The heading of one section of a panel: an eyebrow title and an optional
// description under it, with the theme's space above and below. It spans
// its parent, as a heading does, unless given a width.
Column {
    id: root

    property string text: ""
    property string description: ""

    width: parent ? parent.width : implicitWidth

    topPadding: Theme.sectionHeader.paddingTop
    bottomPadding: Theme.sectionHeader.paddingBottom
    spacing: Theme.space.xxs

    Label {
        role: "eyebrow"
        text: root.text
        width: parent.width
        elide: Text.ElideRight
    }
    Label {
        role: "hint"
        text: root.description
        visible: root.description !== ""
        width: parent.width
        wrapMode: Text.Wrap
    }
}
