import QtQuick
import qs.Common
import qs.Widgets

// Render an upgrade note within the changelog. Notes show to every user whose .changelog-<version> marker (ChangelogService) predates the shipped VERSION.
Row {
    id: root

    property alias text: noteText.text

    spacing: Theme.spacingS

    VgsIcon {
        name: "arrow_right"
        size: Theme.iconSizeSmall - 2
        color: Theme.surfaceVariantText
        anchors.top: parent.top
        anchors.topMargin: 2
    }

    StyledText {
        id: noteText
        width: root.width - Theme.iconSizeSmall - Theme.spacingS
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceText
        wrapMode: Text.WordWrap
    }
}
