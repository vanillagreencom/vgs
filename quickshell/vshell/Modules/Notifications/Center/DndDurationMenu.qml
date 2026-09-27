import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import "../../../Common/DndFormat.js" as DndFormat

Rectangle {
    id: root

    LayoutMirroring.enabled: I18n.isRtl
    LayoutMirroring.childrenInherit: true

    signal dismissed

    // The notification center renders its own labeled DND row above this menu,
    // so it hides the built-in header. The bar popout still needs it.
    property bool showHeader: true

    // Embedded menus share the parent card's chrome and outer padding.
    property bool flat: false

    readonly property bool currentlyActive: SessionData.doNotDisturb
    readonly property real currentRemainingMs: SessionData.doNotDisturbUntil > 0 ? Math.max(0, SessionData.doNotDisturbUntil - nowMs) : 0
    property real nowMs: Date.now()

    Timer {
        interval: 1000
        repeat: true
        running: root.visible && root.currentlyActive && SessionData.doNotDisturbUntil > 0
        onTriggered: root.nowMs = Date.now()
    }

    function formatRemaining(ms) {
        if (ms <= 0)
            return I18n.tr("Off");
        const parts = DndFormat.remainingParts(ms);
        if (parts.totalMinutes < 60)
            return I18n.tr("%1 min left").arg(parts.totalMinutes);
        if (parts.minutes === 0)
            return I18n.tr("%1 h left").arg(parts.hours);
        return I18n.tr("%1 h %2 m left").arg(parts.hours).arg(parts.minutes);
    }

    function formatUntilTimestamp(ts) {
        return DndFormat.clockTime(ts, SettingsData.use24HourClock);
    }

    readonly property var presetOptions: [
        {
            "label": I18n.tr("For 15 minutes"),
            "minutes": 15
        },
        {
            "label": I18n.tr("For 30 minutes"),
            "minutes": 30
        },
        {
            "label": I18n.tr("For 1 hour"),
            "minutes": 60
        },
        {
            "label": I18n.tr("For 3 hours"),
            "minutes": 180
        },
        {
            "label": I18n.tr("For 8 hours"),
            "minutes": 480
        },
        {
            "label": I18n.tr("Until tomorrow, 8:00 AM"),
            "minutesFn": true
        },
        {
            "label": I18n.tr("Until I turn it off"),
            "minutes": 0
        }
    ]

    function selectPreset(option) {
        let minutes = option.minutes;
        if (option.minutesFn) {
            minutes = DndFormat.minutesUntilTomorrowMorning(Date.now());
        }
        SessionData.setDoNotDisturb(true, minutes);
        root.dismissed();
    }

    function turnOff() {
        SessionData.setDoNotDisturb(false);
        root.dismissed();
    }

    // Flat inset is spacingXS so the preset labels (themselves inset spacingS
    // inside their hover row) line up with the card's spacingM content edge.
    readonly property real _pad: flat ? Theme.spacingXS : Theme.spacingM

    implicitWidth: Math.max(flat ? 0 : 220, menuColumn.implicitWidth + _pad * 2)
    implicitHeight: menuColumn.implicitHeight + _pad * 2
    color: flat ? "transparent" : Theme.popupSurfaceColor(Theme.surfaceContainer, false)
    radius: flat ? 0 : Theme.cornerRadius
    border.color: BlurService.borderColor
    border.width: flat ? 0 : BlurService.borderWidth

    Column {
        id: menuColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: root._pad
        spacing: Theme.spacingXS

        Row {
            width: parent.width
            spacing: Theme.spacingS
            visible: root.showHeader

            VgsIcon {
                name: SessionData.doNotDisturb ? "notifications_off" : "notifications_paused"
                size: Theme.iconSize - 2
                color: SessionData.doNotDisturb ? Theme.primary : Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter
            }

            Column {
                width: parent.width - Theme.iconSize - parent.spacing
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
                    visible: root.currentlyActive
                    text: {
                        if (SessionData.doNotDisturbUntil > 0) {
                            return root.formatRemaining(root.currentRemainingMs) + " · " + I18n.tr("until %1").arg(root.formatUntilTimestamp(SessionData.doNotDisturbUntil));
                        }
                        return I18n.tr("On indefinitely");
                    }
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    elide: Text.ElideRight
                    width: parent.width
                }
            }
        }

        Rectangle {
            width: parent.width
            height: 1
            color: Theme.outlineStrong
            visible: root.showHeader
        }

        Repeater {
            model: root.presetOptions

            Rectangle {
                id: optionRect
                required property var modelData
                width: menuColumn.width
                height: 32
                radius: Theme.cornerRadius
                color: optionArea.containsMouse ? BlurService.hoverColor(Theme.widgetBaseHoverColor) : Theme.withAlpha(BlurService.hoverColor(Theme.widgetBaseHoverColor), 0)

                StyledText {
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.spacingS
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.spacingS
                    anchors.verticalCenter: parent.verticalCenter
                    text: optionRect.modelData.label
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    elide: Text.ElideRight
                }

                MouseArea {
                    id: optionArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.selectPreset(optionRect.modelData)
                }
            }
        }

        Rectangle {
            visible: root.currentlyActive
            width: parent.width
            height: 1
            color: Theme.outlineStrong
        }

        Rectangle {
            visible: root.currentlyActive
            width: menuColumn.width
            height: 32
            radius: Theme.cornerRadius
            color: offArea.containsMouse ? Theme.errorPressed : Theme.withAlpha(Theme.errorPressed, 0)

            Row {
                anchors.left: parent.left
                anchors.leftMargin: Theme.spacingS
                anchors.right: parent.right
                anchors.rightMargin: Theme.spacingS
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingS

                VgsIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "notifications_active"
                    size: Theme.iconSizeSmall
                    color: offArea.containsMouse ? Theme.error : Theme.surfaceText
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: I18n.tr("Turn off now")
                    font.pixelSize: Theme.fontSizeSmall
                    color: offArea.containsMouse ? Theme.error : Theme.surfaceText
                    font.weight: Font.Medium
                }
            }

            MouseArea {
                id: offArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.turnOff()
            }
        }
    }
}
