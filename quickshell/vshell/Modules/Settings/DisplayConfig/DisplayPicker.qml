import QtQuick
import qs.Common
import qs.Widgets
import "DisplaySettingsLogic.js" as DisplaySettingsLogic

Column {
    id: root
    property string selectedOutput: ""
    readonly property var names: Object.keys(DisplayConfigState.allOutputs).filter(name => SettingsData.displayShowDisconnected || DisplayConfigState.allOutputs[name].connected)
    signal selected(string name)
    spacing: Theme.spacingL

    Flow {
        width: parent.width
        spacing: Theme.spacingM
        Repeater {
            model: root.names
            delegate: FocusScope {
                id: tile
                required property string modelData
                readonly property var output: DisplayConfigState.allOutputs[modelData]
                readonly property bool chosen: root.selectedOutput === modelData
                readonly property var dimensions: DisplayConfigState.getPhysicalSize(output)
                readonly property real aspect: {
                    if (output?.physicalWidth > 0 && output?.physicalHeight > 0) {
                        const ratio = output.physicalWidth / output.physicalHeight;
                        return DisplayConfigState.isRotated(output.logical?.transform) ? 1 / ratio : ratio;
                    }
                    return dimensions.w / dimensions.h;
                }
                readonly property string wallpaper: SessionData.getMonitorWallpaper(modelData)
                width: (parent.width - Theme.spacingM * (Math.min(root.names.length, 3) - 1)) / Math.min(root.names.length, 3)
                height: Theme.spacingXL * 7
                activeFocusOnTab: true
                Accessible.role: Accessible.Button
                Accessible.name: DisplaySettingsLogic.displayName(output, modelData) + " " + modelData
                Accessible.onPressAction: root.selected(modelData)
                Keys.onSpacePressed: root.selected(modelData)
                Keys.onReturnPressed: root.selected(modelData)

                Rectangle {
                    anchors.fill: parent
                    radius: Theme.cornerRadius
                    color: hover.containsMouse ? Theme.primaryHover : "transparent"
                    border.width: tile.activeFocus ? 2 : 0
                    border.color: Theme.primary
                }
                Rectangle {
                    id: screen
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: monitorStand.top
                    width: Math.min(tile.width - Theme.spacingL * 2, Theme.spacingXL * 4.5 * tile.aspect)
                    height: width / tile.aspect
                    radius: Theme.cornerRadius / 4
                    color: Theme.surfaceContainerHighest
                    border.width: 3
                    border.color: tile.chosen ? Theme.primary : Theme.outline
                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: 4
                        radius: parent.radius / 2
                        color: tile.wallpaper.startsWith("#") ? tile.wallpaper : Theme.surfaceContainer
                        clip: true
                        Image {
                            anchors.fill: parent
                            source: tile.wallpaper && !tile.wallpaper.startsWith("#") ? Paths.toFileUrl(tile.wallpaper) : ""
                            sourceSize.width: 480
                            sourceSize.height: 480
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            smooth: true
                        }
                    }
                }
                Rectangle {
                    id: monitorStand
                    y: Theme.spacingXL * 5
                    anchors.horizontalCenter: screen.horizontalCenter
                    width: Theme.spacingL
                    height: Theme.spacingS
                    color: Theme.outline
                }
                Column {
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: Theme.spacingM
                    width: parent.width
                    StyledText {
                        width: parent.width
                        text: DisplaySettingsLogic.displayName(tile.output, tile.modelData)
                        horizontalAlignment: Text.AlignHCenter
                        elide: Text.ElideRight
                        font.pixelSize: Theme.settingsFontSize
                        color: tile.chosen ? Theme.primary : Theme.surfaceText
                    }
                    StyledText {
                        width: parent.width
                        text: tile.output?.connected ? tile.modelData : I18n.tr("Disconnected")
                        horizontalAlignment: Text.AlignHCenter
                        font.pixelSize: Theme.settingsFontSize
                        color: Theme.surfaceVariantText
                    }
                }
                MouseArea {
                    id: hover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.selected(tile.modelData)
                }
            }
        }
    }
}
