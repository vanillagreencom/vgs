import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Settings.Widgets

Item {
    id: root

    VgsFlickable {
        anchors.fill: parent
        clip: true
        contentHeight: mainColumn.height + Theme.spacingXL
        contentWidth: width

        Column {
            id: mainColumn

            topPadding: Theme.spacingXL
            bottomPadding: Theme.spacingXL
            width: Math.min(550, parent.width - Theme.spacingL * 2)
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.spacingXL

            SettingsCard {
                width: parent.width
                iconName: "view_module"
                title: I18n.tr("General")
                settingKey: "workspaceSettings"
                tags: ["workspace", "workspaces"]

                SettingsToggleRow {
                    settingKey: "showWorkspaceIndex"
                    tags: ["workspace", "index", "numbers", "labels"]
                    text: I18n.tr("Workspace Index Numbers")
                    checked: SettingsData.showWorkspaceIndex
                    onToggled: checked => SettingsData.set("showWorkspaceIndex", checked)
                }

                SettingsToggleRow {
                    settingKey: "showWorkspaceName"
                    tags: ["workspace", "name", "labels"]
                    text: I18n.tr("Workspace Names")
                    description: I18n.tr("Vertical bars show the first letter.")
                    checked: SettingsData.showWorkspaceName
                    onToggled: checked => SettingsData.set("showWorkspaceName", checked)
                }

                SettingsToggleRow {
                    settingKey: "showWorkspacePadding"
                    tags: ["workspace", "padding", "minimum"]
                    text: I18n.tr("Workspace Padding")
                    description: I18n.tr("Keep at least 3 workspaces visible.")
                    checked: SettingsData.showWorkspacePadding
                    onToggled: checked => SettingsData.set("showWorkspacePadding", checked)
                }

                SettingsToggleRow {
                    settingKey: "showWorkspaceApps"
                    tags: ["workspace", "apps", "icons", "applications", "show"]
                    text: I18n.tr("Workspace Apps")
                    checked: SettingsData.showWorkspaceApps
                    visible: CompositorService.isNiri || CompositorService.isHyprland || CompositorService.isMango
                    onToggled: checked => SettingsData.set("showWorkspaceApps", checked)
                }

                Item {
                    width: parent.width
                    height: maxAppsColumn.height
                    visible: SettingsData.showWorkspaceApps
                    opacity: visible ? 1 : 0

                    Column {
                        id: maxAppsColumn
                        x: Theme.spacingM
                        width: 120
                        spacing: Theme.spacingS

                        StyledText {
                            text: I18n.tr("Max App Icons")
                            font.pixelSize: Theme.settingsFontSize
                            color: Theme.surfaceText
                            font.weight: Font.Medium
                            horizontalAlignment: Text.AlignLeft
                        }

                        VgsTextField {
                            width: 100
                            height: 28
                            placeholderText: "3"
                            text: SettingsData.maxWorkspaceIcons
                            maximumLength: 2
                            font.pixelSize: Theme.settingsFontSize
                            topPadding: Theme.spacingXS
                            bottomPadding: Theme.spacingXS
                            onEditingFinished: SettingsData.set("maxWorkspaceIcons", parseInt(text, 10))
                        }
                    }

                    Behavior on opacity {
                        NumberAnimation {
                            duration: Theme.mediumDuration
                            easing.type: Theme.emphasizedEasing
                        }
                    }
                }

                SettingsSliderRow {
                    visible: SettingsData.showWorkspaceApps
                    text: I18n.tr("Icon Size")
                    value: SettingsData.workspaceAppIconSizeOffset
                    minimum: 0
                    maximum: 10
                    unit: "px"
                    defaultValue: 0
                    onSliderValueChanged: newValue => SettingsData.set("workspaceAppIconSizeOffset", newValue)
                }

                SettingsToggleRow {
                    settingKey: "groupWorkspaceApps"
                    tags: ["workspace", "apps", "icons", "group", "grouped", "collapse"]
                    text: I18n.tr("Group Workspace Apps")
                    description: I18n.tr("Show one icon per app.")
                    checked: SettingsData.groupWorkspaceApps
                    visible: SettingsData.showWorkspaceApps
                    onToggled: checked => SettingsData.set("groupWorkspaceApps", checked)
                }

                SettingsToggleRow {
                    settingKey: "groupActiveWorkspaceApps"
                    tags: ["workspace", "apps", "icons", "group", "grouped", "active", "focused"]
                    text: I18n.tr("Group Active Workspace")
                    description: I18n.tr("Also group icons on the active workspace.")
                    checked: SettingsData.groupActiveWorkspaceApps
                    visible: SettingsData.showWorkspaceApps && SettingsData.groupWorkspaceApps
                    onToggled: checked => SettingsData.set("groupActiveWorkspaceApps", checked)
                }

                SettingsToggleRow {
                    settingKey: "workspaceActiveAppHighlightEnabled"
                    tags: ["workspace", "apps", "icons", "highlight", "active", "focused"]
                    text: I18n.tr("Highlight Active Workspace App")
                    description: I18n.tr("Highlight the focused app.")
                    checked: SettingsData.workspaceActiveAppHighlightEnabled
                    visible: SettingsData.showWorkspaceApps
                    onToggled: checked => SettingsData.set("workspaceActiveAppHighlightEnabled", checked)
                }

                SettingsToggleRow {
                    settingKey: "workspaceFollowFocus"
                    tags: ["workspace", "focus", "follow", "monitor"]
                    text: I18n.tr("Follow Monitor Focus")
                    checked: SettingsData.workspaceFollowFocus
                    visible: CompositorService.isNiri || CompositorService.isHyprland || CompositorService.isMango || CompositorService.isSway || CompositorService.isScroll || CompositorService.isMiracle
                    onToggled: checked => SettingsData.set("workspaceFollowFocus", checked)
                }

                SettingsToggleRow {
                    settingKey: "showOccupiedWorkspacesOnly"
                    tags: ["workspace", "occupied", "active", "windows", "show"]
                    text: I18n.tr("Occupied Workspaces Only")
                    checked: SettingsData.showOccupiedWorkspacesOnly
                    visible: CompositorService.isNiri || CompositorService.isHyprland || CompositorService.isMango
                    onToggled: checked => SettingsData.set("showOccupiedWorkspacesOnly", checked)
                }

                SettingsToggleRow {
                    settingKey: "reverseScrolling"
                    tags: ["workspace", "scroll", "scrolling", "reverse", "direction"]
                    text: I18n.tr("Reverse Scrolling Direction")
                    description: I18n.tr("Reverse the scroll direction.")
                    checked: SettingsData.reverseScrolling
                    visible: CompositorService.isNiri || CompositorService.isHyprland || CompositorService.isMango
                    onToggled: checked => SettingsData.set("reverseScrolling", checked)
                }

                SettingsToggleRow {
                    settingKey: "workspaceDragReorder"
                    tags: ["workspace", "drag", "reorder", "sort", "move"]
                    text: I18n.tr("Drag to Reorder")
                    checked: SettingsData.workspaceDragReorder
                    visible: CompositorService.isNiri
                    onToggled: checked => SettingsData.set("workspaceDragReorder", checked)
                }

                SettingsToggleRow {
                    settingKey: "dwlShowAllTags"
                    tags: ["dwl", "tags", "workspace", "show"]
                    text: I18n.tr("All Tags")
                    description: I18n.tr("Show all 9 tags instead of only occupied tags")
                    checked: SettingsData.dwlShowAllTags
                    visible: CompositorService.isMango
                    onToggled: checked => SettingsData.set("dwlShowAllTags", checked)
                }
            }

            WorkspaceAppearanceCard {
                width: parent.width
            }

            SettingsCard {
                width: parent.width
                iconName: "label"
                title: I18n.tr("Named Workspace Icons")
                collapsible: true
                expanded: false
                settingKey: "workspaceIcons"
                visible: SettingsData.hasNamedWorkspaces()

                StyledText {
                    width: parent.width
                    text: I18n.tr("Configure icons for named workspaces. Icons take priority over numbers when both are enabled.")
                    font.pixelSize: Theme.settingsFontSize
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                }

                Repeater {
                    model: SettingsData.getNamedWorkspaces()

                    Rectangle {
                        width: parent.width
                        height: workspaceIconRow.implicitHeight + Theme.spacingM
                        radius: Theme.cornerRadius
                        color: Theme.withAlpha(Theme.surfaceContainer, 0.5)
                        border.width: 0

                        Row {
                            id: workspaceIconRow

                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: Theme.spacingM
                            anchors.rightMargin: Theme.spacingM
                            spacing: Theme.spacingM

                            StyledText {
                                text: "\"" + modelData + "\""
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Medium
                                color: Theme.surfaceText
                                anchors.verticalCenter: parent.verticalCenter
                                width: 150
                                elide: Text.ElideRight
                            }

                            VgsIconPicker {
                                id: iconPicker
                                anchors.verticalCenter: parent.verticalCenter

                                Component.onCompleted: {
                                    var iconData = SettingsData.getWorkspaceNameIcon(modelData);
                                    if (iconData) {
                                        setIcon(iconData.value, iconData.type);
                                    }
                                }

                                onIconSelected: (iconName, iconType) => {
                                    SettingsData.setWorkspaceNameIcon(modelData, {
                                        "type": iconType,
                                        "value": iconName
                                    });
                                    setIcon(iconName, iconType);
                                }

                                Connections {
                                    target: SettingsData
                                    function onWorkspaceIconsUpdated() {
                                        var iconData = SettingsData.getWorkspaceNameIcon(modelData);
                                        if (iconData) {
                                            iconPicker.setIcon(iconData.value, iconData.type);
                                        } else {
                                            iconPicker.setIcon("", "icon");
                                        }
                                    }
                                }
                            }

                            Rectangle {
                                width: 28
                                height: 28
                                radius: Theme.cornerRadius
                                color: clearMouseArea.containsMouse ? Theme.errorHover : Theme.surfaceContainer
                                border.width: 0
                                anchors.verticalCenter: parent.verticalCenter

                                VgsIcon {
                                    name: "close"
                                    size: 16
                                    color: clearMouseArea.containsMouse ? Theme.error : Theme.outline
                                    anchors.centerIn: parent
                                }

                                MouseArea {
                                    id: clearMouseArea

                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: SettingsData.removeWorkspaceNameIcon(modelData)
                                }
                            }

                            Item {
                                width: parent.width - 150 - 240 - 28 - Theme.spacingM * 4
                                height: 1
                            }
                        }
                    }
                }
            }
        }
    }
}
