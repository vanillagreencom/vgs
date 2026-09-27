import QtQuick
import qs.Commons
import qs.Ui

// The heading of one section of a panel: an eyebrow title and an optional
// description under it, with the theme's space above and below.
Column {
    id: root

    property string text: ""
    property string description: ""

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
