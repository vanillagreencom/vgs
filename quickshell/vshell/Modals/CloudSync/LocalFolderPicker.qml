import Qt.labs.folderlistmodel
import QtCore
import QtQuick
import qs.Common
import qs.Widgets

// Directory-only browser for selecting a local sync root.
Item {
    id: root

    readonly property string homeDir: StandardPaths.writableLocation(StandardPaths.HomeLocation)
    property string currentPath: homeDir
    property bool showHidden: false

    readonly property string selectedPath: currentPath

    signal pathChosen(string path)

    implicitHeight: 300

    function encodeFolderUrl(path) {
        if (!path)
            return "";
        return "file://" + path.split("/").map(encodeURIComponent).join("/");
    }

    function decodeFolderUrl(url) {
        const raw = String(url);
        if (raw.indexOf("file://") !== 0)
            return raw;
        return decodeURIComponent(raw.substring(7));
    }

    function goUp() {
        if (currentPath === "/" || currentPath.length === 0)
            return;
        const parts = currentPath.split("/");
        parts.pop();
        currentPath = parts.join("/") || "/";
    }

    Column {
        anchors.fill: parent
        spacing: Theme.spacingS

        Item {
            width: parent.width
            height: 28

            Row {
                id: localNav
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingXS

                VgsActionButton {
                    iconName: "arrow_upward"
                    buttonSize: 28
                    tooltipText: I18n.tr("Up one level", "Tooltip for the parent-directory button")
                    enabled: root.currentPath !== "/"
                    onClicked: root.goUp()
                }

                VgsActionButton {
                    iconName: "home"
                    buttonSize: 28
                    tooltipText: I18n.tr("Home folder", "Tooltip for the home-directory button")
                    onClicked: root.currentPath = root.homeDir
                }
            }

            StyledRect {
                anchors.left: localNav.right
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
                    text: root.currentPath
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
                boundsBehavior: Flickable.StopAtBounds

                model: FolderListModel {
                    id: folders

                    showDirsFirst: true
                    showDotAndDotDot: false
                    showHidden: root.showHidden
                    showFiles: false
                    showDirs: true
                    caseSensitive: false
                    sortField: FolderListModel.Name
                    folder: root.encodeFolderUrl(root.currentPath)
                }

                delegate: Rectangle {
                    required property int index
                    required property string fileName
                    required property url fileUrl

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
                            text: parent.parent.fileName
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
                        onClicked: root.currentPath = root.decodeFolderUrl(parent.fileUrl)
                    }
                }
            }

            StyledText {
                anchors.centerIn: parent
                visible: folders.count === 0
                text: I18n.tr("No folders here", "Empty state inside the local folder picker")
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }
        }
    }
}
