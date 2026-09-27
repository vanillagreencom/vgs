pragma ComponentBehavior: Bound
import QtQuick
import qs.Common
import qs.Widgets

Flow {
    id: root
    property int currentIndex: -1
    signal selected(int tabIndex)
    readonly property var items: SettingsNavigation.tabsFor(currentIndex)
    spacing: Theme.spacingXS
    visible: items.length > 1
    height: visible ? implicitHeight : 0

    Repeater {
        model: root.items
        delegate: Rectangle {
            id: tab
            required property var modelData
            readonly property bool isActive: root.currentIndex === modelData.tabIndex
            width: tabContent.width + Theme.spacingM * 2
            height: 34
            radius: Math.max(0, Theme.cornerRadius - 2)
            color: isActive ? Theme.withAlpha(Theme.primary, 0.12) : tabMouse.containsMouse ? Theme.surfaceHover : "transparent"
            border.width: activeFocus ? 2 : 0
            border.color: Theme.primary
            activeFocusOnTab: true
            Accessible.role: Accessible.PageTab
            Accessible.name: modelData.text
            Accessible.onPressAction: root.selected(modelData.tabIndex)
            Keys.onReturnPressed: root.selected(modelData.tabIndex)
            Keys.onSpacePressed: root.selected(modelData.tabIndex)

            Row {
                id: tabContent
                anchors.centerIn: parent
                spacing: Theme.spacingXS
                VgsIcon {
                    name: tab.modelData.icon
                    size: 16
                    color: tab.isActive ? Theme.primary : Theme.surfaceVariantText
                    anchors.verticalCenter: parent.verticalCenter
                }
                StyledText {
                    text: tab.modelData.text
                    font.pixelSize: Theme.settingsFontSize
                    font.weight: tab.isActive ? Font.Medium : Font.Normal
                    color: tab.isActive ? Theme.primary : Theme.surfaceVariantText
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
            MouseArea {
                id: tabMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.selected(tab.modelData.tabIndex)
            }
        }
    }
}
