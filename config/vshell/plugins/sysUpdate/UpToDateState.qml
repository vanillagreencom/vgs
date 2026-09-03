import QtQuick
import qs.Common
import qs.Widgets

// What the updates sheet shows when there is nothing to install: one centered
// mark in place of the four upgrade buttons, each of which would otherwise open
// a terminal and find no work.
//
// `toolsAvailable` decides only the caption, so the sheet never names a source
// this machine cannot check.
Item {
    id: emptyState

    property bool toolsAvailable: false

    height: allClearCol.implicitHeight + Theme.spacingL * 2

    Column {
        id: allClearCol
        anchors.centerIn: parent
        width: parent.width
        spacing: Theme.spacingS

        Item {
            width: 64
            height: 64
            anchors.horizontalCenter: parent.horizontalCenter

            // A short settle on open, so the mark reads as the answer to a
            // finished check rather than a static badge.
            scale: 0.9
            opacity: 0
            Component.onCompleted: {
                scale = 1;
                opacity = 1;
            }

            Behavior on scale {
                NumberAnimation { duration: Theme.mediumDuration; easing.type: Easing.OutBack }
            }

            Behavior on opacity {
                NumberAnimation { duration: Theme.mediumDuration; easing.type: Theme.standardEasing }
            }

            Rectangle {
                anchors.fill: parent
                radius: width / 2
                color: Theme.withAlpha(Theme.success, 0.12)
            }

            VgsIcon {
                anchors.centerIn: parent
                name: "check_circle"
                size: 34
                color: Theme.success
            }
        }

        StyledText {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: "Everything up to date"
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Medium
            color: Theme.surfaceText
        }

        StyledText {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: emptyState.toolsAvailable ? "Repo, AUR and dev tools" : "Repo and AUR"
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
        }
    }
}
