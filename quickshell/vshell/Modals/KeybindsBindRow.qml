import QtQuick
import qs.Common
import qs.Widgets

// Shortcut row with a shared key-column width so action descriptions align.
Item {
    id: row

    property real keyColumnWidth: 220
    property string keyLabel: ""
    property string description: ""

    height: 30

    StyledRect {
        id: keyBadge

        // Keep keyText unwrapped: wrapping makes implicitWidth depend on the width this badge derives from it.
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
