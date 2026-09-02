import QtQuick
import qs.Common
import qs.Widgets

// One shortcut in the cheatsheet: its key in a badge, then what the key does.
// Every row shares one key column width so the descriptions line up down the
// list rather than tracking the length of the badge beside them.
Item {
    id: row

    property real keyColumnWidth: 220
    property string keyLabel: ""
    property string description: ""

    height: 30

    StyledRect {
        id: keyBadge

        // The badge hugs its text, capped at the key column. Width reads
        // implicitWidth, so keyText must never wrap: a wrapping Text
        // recomputes implicitWidth from the width it was given, and the pair
        // oscillates.
        width: Math.min(keyText.implicitWidth + Theme.spacingS * 2, row.keyColumnWidth)
        height: 26
        radius: 4
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter

        StyledText {
            id: keyText
            anchors.fill: parent
            anchors.leftMargin: Theme.spacingS
            anchors.rightMargin: Theme.spacingS
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            color: Theme.secondary
            text: row.keyLabel
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Medium
            isMonospace: true
            elide: Text.ElideRight
            wrapMode: Text.NoWrap
        }
    }

    StyledText {
        anchors.left: parent.left
        anchors.leftMargin: row.keyColumnWidth + Theme.spacingM
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: row.description
        font.pixelSize: Theme.fontSizeMedium
        opacity: 0.9
        elide: Text.ElideRight
        wrapMode: Text.NoWrap
    }
}
