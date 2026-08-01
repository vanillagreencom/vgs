import QtQuick
import qs.Common
import qs.Services
import qs.Widgets

// Reading pane. Pages are swapped rather than stacked so an off-screen page
// never keeps polling or holding a remote listing alive.
Item {
    id: root

    property var parentModal: null
    property int currentIndex: 0

    // Missing engine is a whole-app state, not a per-page one: without rclone
    // there is nothing any page could usefully show.
    Item {
        anchors.fill: parent
        visible: !CloudSyncService.available

        Column {
            anchors.centerIn: parent
            width: Math.min(420, parent.width - Theme.spacingXL * 2)
            spacing: Theme.spacingM

            VgsIcon {
                anchors.horizontalCenter: parent.horizontalCenter
                name: "cloud_off"
                size: 48
                color: Theme.surfaceVariantText
            }

            StyledText {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: I18n.tr("Cloud Sync needs rclone", "Empty state title when the rclone binary is missing")
                font.pixelSize: Theme.fontSizeLarge
                font.weight: Theme.fontWeightSectionHeader
                color: Theme.surfaceText
            }

            StyledText {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                text: I18n.tr("Install the rclone package to connect cloud accounts and sync folders. Streaming folders on demand also needs fuse3.", "Empty state body when the rclone binary is missing")
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }
        }
    }

    Loader {
        id: pageLoader

        anchors.fill: parent
        visible: CloudSyncService.available
        active: CloudSyncService.available
        sourceComponent: {
            switch (root.currentIndex) {
            case 0:
                return accountsPage;
            case 1:
                return foldersPage;
            case 2:
                return activityPage;
            case 3:
                return conflictsPage;
            case 4:
                return settingsPage;
            }
            return accountsPage;
        }

        onLoaded: {
            if (item && item.hasOwnProperty("parentModal"))
                item.parentModal = root.parentModal;
        }
    }

    Component {
        id: accountsPage
        AccountsPage {}
    }

    Component {
        id: foldersPage
        FoldersPage {}
    }

    Component {
        id: activityPage
        ActivityPage {}
    }

    Component {
        id: conflictsPage
        ConflictsPage {}
    }

    Component {
        id: settingsPage
        CloudSyncSettingsPage {}
    }
}
