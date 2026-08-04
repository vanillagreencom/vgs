import QtQuick
import qs.Common
import qs.Widgets

// One line in the changelog's "Upgrade Notes" block. Notes display to every user
// whose `~/.config/vshell/.changelog-<version>` marker is older than the shipped
// `quickshell/vshell/VERSION`, so a note written here reaches users on the next
// release — see "Changelog" in docs/architecture/shell-architecture.md.
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
