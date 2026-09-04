import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import "../../../Common/DndFormat.js" as DndFormat

Item {
    id: root

    property var keyboardController: null
    property bool showSettings: false
    property int currentTab: 0
    property bool showDndMenu: false
    property var transientSurfaceTracker: null

    onShowDndMenuChanged: transientSurfaceTracker?.setActive(root, showDndMenu, null)
    Component.onDestruction: transientSurfaceTracker?.unregister(root)

    Connections {
        target: root.transientSurfaceTracker
        ignoreUnknownSignals: true

        function onCloseRequested() {
            root.showDndMenu = false;
        }
    }

    onCurrentTabChanged: {
        if (currentTab === 1 && !SettingsData.notificationHistoryEnabled)
            currentTab = 0;
    }

    onShowSettingsChanged: {
        if (showSettings)
            showDndMenu = false;
    }

    Connections {
        target: SettingsData
        function onNotificationHistoryEnabledChanged() {
            if (!SettingsData.notificationHistoryEnabled)
                root.currentTab = 0;
        }
    }

    width: parent.width
    height: headerColumn.implicitHeight

    VgsInlineTooltip {
        id: sharedTooltip
    }

    Column {
        id: headerColumn
        width: parent.width
        // Gaps are set explicitly per child so the DND block can sit closer to
        // the title than the tab switcher does to the DND block.
        spacing: 0

        Item {
            width: parent.width
            height: Math.max(titleRow.implicitHeight, actionsRow.implicitHeight)

            Row {
                id: titleRow
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingXS

                StyledText {
                    text: I18n.tr("Notifications")
                    font.pixelSize: Theme.fontSizeXLarge
                    color: Theme.surfaceText
                    font.weight: Font.Bold
                    anchors.verticalCenter: parent.verticalCenter
                }

                // Mutes only the notification chime; notifications keep arriving.
                // Mirrors the toggle in the audio popout (AudioOutputDetail) and
                // hides when no sound backend is available, since there is
                // nothing to mute then.
                VgsActionButton {
                    id: notifSoundButton
                    visible: AudioService.soundsAvailable
                    iconName: SettingsData.soundNewNotification ? "volume_up" : "volume_off"
                    iconColor: SettingsData.soundNewNotification ? Theme.surfaceText : Theme.error
                    buttonSize: Theme.iconSize + Theme.spacingS
                    anchors.verticalCenter: parent.verticalCenter
                    onClicked: SettingsData.set("soundNewNotification", !SettingsData.soundNewNotification)
                    onEntered: sharedTooltip.show(SettingsData.soundNewNotification ? I18n.tr("Mute notification sounds") : I18n.tr("Unmute notification sounds"), notifSoundButton, 0, 0, "bottom")
                    onExited: sharedTooltip.hide()
                }
            }

            Row {
                id: actionsRow
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingXS

                VgsActionButton {
                    id: helpButton
                    iconName: "info"
                    iconColor: (keyboardController && keyboardController.showKeyboardHints) ? Theme.primary : Theme.surfaceText
                    buttonSize: Theme.iconSize + Theme.spacingS
                    visible: keyboardController !== null
                    anchors.verticalCenter: parent.verticalCenter
                    onClicked: {
                        if (keyboardController)
                            keyboardController.showKeyboardHints = !keyboardController.showKeyboardHints;
                    }
                }

                VgsActionButton {
                    id: settingsButton
                    iconName: "settings"
                    iconColor: root.showSettings ? Theme.primary : Theme.surfaceText
                    buttonSize: Theme.iconSize + Theme.spacingS
                    anchors.verticalCenter: parent.verticalCenter
                    onClicked: root.showSettings = !root.showSettings
                }

                Rectangle {
                    id: clearAllButton
                    width: clearButtonContent.implicitWidth + Theme.spacingM * 2
                    height: Theme.iconSize + Theme.spacingS
                    radius: Theme.cornerRadius
                    visible: root.currentTab === 0 ? NotificationService.notifications.length > 0 : NotificationService.historyList.length > 0
                    color: clearArea.containsMouse ? Theme.primaryHoverLight : Theme.nestedSurface
                    border.color: Theme.outlineMedium
                    border.width: Theme.layerOutlineWidth

                    Row {
                        id: clearButtonContent
                        anchors.centerIn: parent
                        spacing: Theme.spacingXS

                        VgsIcon {
                            name: "delete_sweep"
                            size: Theme.iconSizeSmall
                            color: clearArea.containsMouse ? Theme.primary : Theme.surfaceText
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        StyledText {
                            text: I18n.tr("Clear")
                            font.pixelSize: Theme.fontSizeSmall
                            color: clearArea.containsMouse ? Theme.primary : Theme.surfaceText
                            font.weight: Font.Medium
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    MouseArea {
                        id: clearArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (root.currentTab === 0) {
                                NotificationService.clearAllNotifications();
                            } else {
                                NotificationService.clearHistory();
                            }
                        }
                    }
                }
            }
        }

        Item {
            width: 1
            height: Theme.spacingS
        }


        StyledRect {
            id: dndCard
            width: parent.width
            height: dndCardColumn.implicitHeight + Theme.spacingXS * 2
            radius: Theme.cornerRadius

            color: SessionData.doNotDisturb ? Theme.errorHover : Theme.nestedSurface
            border.width: 0

            Column {
                id: dndCardColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 0

                Item {
                    id: dndHeaderRow
                    width: parent.width
                    height: dndCardRow.implicitHeight + Theme.spacingS * 2

                    // The row body toggles DND. The switch and chevron sit above
                    // this and consume their own clicks.
                    MouseArea {
                        id: dndCardArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: SessionData.setDoNotDisturb(!SessionData.doNotDisturb)
                    }

                    Row {
                        id: dndCardRow
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: Theme.spacingM
                        anchors.rightMargin: Theme.spacingS
                        spacing: Theme.spacingM

                        VgsIcon {
                            id: dndCardIcon
                            name: SessionData.doNotDisturb ? "notifications_off" : "notifications"
                            size: Theme.iconSize - 2
                            color: SessionData.doNotDisturb ? Theme.error : Theme.surfaceText
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Column {
                            width: parent.width - dndCardIcon.width - dndCardToggle.width - dndExpandButton.width - parent.spacing * 3
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 0

                            StyledText {
                                text: I18n.tr("Do Not Disturb")
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Medium
                                color: Theme.surfaceText
                                elide: Text.ElideRight
                                width: parent.width
                            }

                            StyledText {
                                visible: SessionData.doNotDisturb
                                text: {
                                    if (SessionData.doNotDisturbUntil <= 0)
                                        return I18n.tr("On until you turn it off");
                                    return I18n.tr("On until %1").arg(DndFormat.clockTime(SessionData.doNotDisturbUntil, SettingsData.use24HourClock));
                                }
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.error
                                elide: Text.ElideRight
                                width: parent.width
                            }
                        }

                        VgsToggle {
                            id: dndCardToggle
                            hideText: true
                            anchors.verticalCenter: parent.verticalCenter
                            checked: SessionData.doNotDisturb
                            onToggled: checked => SessionData.setDoNotDisturb(checked)
                        }

                        VgsActionButton {
                            id: dndExpandButton
                            iconName: root.showDndMenu ? "expand_less" : "expand_more"
                            iconColor: root.showDndMenu ? Theme.primary : Theme.surfaceVariantText
                            buttonSize: Theme.iconSize + Theme.spacingS
                            anchors.verticalCenter: parent.verticalCenter
                            onClicked: {
                                root.showDndMenu = !root.showDndMenu;
                                if (root.showDndMenu)
                                    root.showSettings = false;
                            }
                            onEntered: sharedTooltip.show(I18n.tr("Silence for a while"), dndExpandButton, 0, 0, "bottom")
                            onExited: sharedTooltip.hide()
                        }
                    }
                }

                Rectangle {
                    x: Theme.spacingM
                    width: parent.width - Theme.spacingM * 2
                    height: Theme.layerOutlineWidth
                    color: Theme.outlineMedium
                    visible: root.showDndMenu
                }

                DndDurationMenu {
                    id: dndMenu
                    width: parent.width
                    visible: root.showDndMenu
                    // Rendered inside the DND card: no chrome of its own, and the
                    // row above already states the current status.
                    flat: true
                    showHeader: false
                    onDismissed: root.showDndMenu = false
                }
            }
        }


        Item {
            width: 1
            height: 15
        }

        VgsButtonGroup {
            id: tabGroup
            width: parent.width
            currentIndex: root.currentTab
            buttonHeight: 32
            buttonPadding: Theme.spacingM
            checkEnabled: false
            textSize: Theme.fontSizeSmall
            visible: SettingsData.notificationHistoryEnabled
            model: [I18n.tr("Current", "notification center tab") + " (" + NotificationService.notifications.length + ")", I18n.tr("History", "notification center tab") + " (" + NotificationService.historyList.length + ")"]
            onSelectionChanged: (index, selected) => {
                if (selected)
                    root.currentTab = index;
            }
        }
    }
}
