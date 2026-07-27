pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Modals.Settings
import qs.Widgets

// Secondary navigation shared by the theming pages (Themes / Wallpaper / Colors /
// Icons / Screensaver). Persistent across all of them so they read as one group;
// the active page is highlighted. Sits in its own surface above the page content.
Item {
    id: root

    property var parentModal: null
    property string activeId: ""

    readonly property var items: [
        { id: "theme", label: I18n.tr("Themes"), icon: "format_paint" },
        { id: "wallpaper", label: I18n.tr("Wallpaper"), icon: "wallpaper" },
        { id: "colors", label: I18n.tr("Colors"), icon: "palette" },
        { id: "icons", label: I18n.tr("Icons"), icon: "interests" },
        { id: "screensaver", label: I18n.tr("Screensaver"), icon: "screenshot_monitor" }
    ]

    width: parent ? parent.width : 0
    height: bar.height + Theme.spacingL

    StyledRect {
        id: bar
        width: parent.width
        height: pillRow.height + Theme.spacingXS * 2
        radius: Theme.cornerRadius
        // Flatline: no heavy container — the tabs carry the look (was overdone).
        color: "transparent"

        Row {
            id: pillRow
            anchors.left: parent.left
            anchors.leftMargin: Theme.spacingXS
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingXS

            Repeater {
                model: root.items

                delegate: Rectangle {
                    id: pill
                    required property var modelData
                    readonly property bool isActive: modelData.id === root.activeId

                    width: pillContent.width + Theme.spacingM * 2
                    height: 34
                    radius: Theme.cornerRadius - 2
                    color: {
                        if (isActive)
                            return Theme.withAlpha(Theme.primary, 0.12);
                        if (pillMouse.containsMouse)
                            return Theme.surfaceHover;
                        return "transparent";
                    }

                    Behavior on color {
                        ColorAnimation {
                            duration: Theme.shorterDuration
                            easing.type: Theme.standardEasing
                        }
                    }

                    Row {
                        id: pillContent
                        anchors.centerIn: parent
                        spacing: Theme.spacingXS

                        VgsIcon {
                            name: pill.modelData.icon
                            size: 16
                            color: pill.isActive ? Theme.primary : Theme.surfaceVariantText
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        StyledText {
                            text: pill.modelData.label
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: pill.isActive ? Font.Medium : Font.Normal
                            color: pill.isActive ? Theme.primary : Theme.surfaceVariantText
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    MouseArea {
                        id: pillMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (!pill.isActive && root.parentModal)
                                root.parentModal.setTabIndex(SettingsRegistry.tabIndexFor(pill.modelData.id));
                        }
                    }
                }
            }
        }
    }
}
