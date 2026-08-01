import QtQuick
import qs.Common
import qs.Services
import qs.Widgets

// Cloud-side directory browser, backed by cloudsync.browse (rclone
// operations/list with dirsOnly). Listing a remote directory is a network call,
// so this shows its own loading and error states rather than looking frozen.
Item {
    id: root

    property string remote: ""
    property string currentPath: ""
    property bool loading: false
    property string error: ""
    property var entries: []

    readonly property string selectedPath: currentPath

    implicitHeight: 300

    onRemoteChanged: {
        currentPath = "";
        refresh();
    }

    Component.onCompleted: refresh()

    function refresh() {
        if (!remote || remote.length === 0)
            return;
        root.loading = true;
        root.error = "";
        const requestedPath = root.currentPath;
        CloudSyncService.browse(root.remote, requestedPath, response => {
            // A slower earlier request must not overwrite a newer listing.
            if (requestedPath !== root.currentPath)
                return;
            root.loading = false;
            if (response.error) {
                root.error = response.error;
                root.entries = [];
                return;
            }
            root.entries = (response.result && response.result.entries) || [];
        });
    }

    function enter(path) {
        root.currentPath = path;
        refresh();
    }

    function goUp() {
        if (currentPath.length === 0)
            return;
        const parts = currentPath.split("/");
        parts.pop();
        enter(parts.join("/"));
    }

    Column {
        anchors.fill: parent
        spacing: Theme.spacingS

        Item {
            width: parent.width
            height: 28

            Row {
                id: remoteNav
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingXS

                VgsActionButton {
                    iconName: "arrow_upward"
                    buttonSize: 28
                    tooltipText: I18n.tr("Up one level", "Tooltip for the parent-directory button")
                    enabled: root.currentPath.length > 0
                    onClicked: root.goUp()
                }

                VgsActionButton {
                    iconName: "refresh"
                    buttonSize: 28
                    tooltipText: I18n.tr("Refresh", "Tooltip for reloading a remote directory listing")
                    onClicked: root.refresh()
                }
            }

            StyledRect {
                anchors.left: remoteNav.right
                anchors.right: parent.right
                anchors.leftMargin: Theme.spacingXS
                anchors.verticalCenter: parent.verticalCenter
                height: 28
                radius: Theme.controlRadius
                color: Theme.elevatedRowColor

                StyledText {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.spacingS
                    anchors.rightMargin: Theme.spacingS
                    verticalAlignment: Text.AlignVCenter
                    text: root.remote + ":" + root.currentPath
                    elide: Text.ElideMiddle
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                }
            }
        }

        StyledRect {
            width: parent.width
            height: Math.max(0, root.height - 28 - Theme.spacingS)
            radius: Theme.controlRadius
            color: Theme.surfaceContainer
            border.width: 1
            border.color: Theme.borderColor
            clip: true

            VgsListView {
                id: list

                anchors.fill: parent
                anchors.margins: Theme.spacingXXS
                clip: true
                visible: !root.loading && root.error.length === 0
                boundsBehavior: Flickable.StopAtBounds
                model: root.entries

                delegate: Rectangle {
                    required property var modelData

                    width: ListView.view.width
                    height: 32
                    radius: Theme.controlRadius
                    color: entryArea.containsMouse ? Theme.surfaceHover : "transparent"

                    Row {
                        anchors.fill: parent
                        anchors.leftMargin: Theme.spacingS
                        anchors.rightMargin: Theme.spacingS
                        spacing: Theme.spacingS

                        VgsIcon {
                            name: "folder"
                            size: Theme.iconSizeSmall
                            color: Theme.surfaceVariantText
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        StyledText {
                            text: parent.parent.modelData.name
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceText
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    MouseArea {
                        id: entryArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.enter(parent.modelData.path)
                    }
                }
            }

            VgsSpinner {
                anchors.centerIn: parent
                visible: root.loading
                size: 28
            }

            StyledText {
                anchors.centerIn: parent
                anchors.margins: Theme.spacingM
                width: parent.width - Theme.spacingXL
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                visible: root.error.length > 0
                text: root.error
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.error
            }

            StyledText {
                anchors.centerIn: parent
                visible: !root.loading && root.error.length === 0 && root.entries.length === 0
                text: I18n.tr("No folders here", "Empty state inside the cloud folder picker")
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }
        }
    }
}
