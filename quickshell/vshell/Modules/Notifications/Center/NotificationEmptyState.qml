import QtQuick
import qs.Common
import qs.Services
import qs.Widgets

Item {
    id: root

    // An empty center is the whole symptom of a lost bus name: notifications
    // appear on screen, drawn by another daemon, and VGS shows nothing. Say so
    // here rather than leaving the user to read the journal.
    readonly property bool conflict: NotificationService.serverConflict

    width: parent.width
    height: conflict ? conflictColumn.height + Theme.spacingXL * 2 : 200
    visible: NotificationService.notifications.length === 0

    onVisibleChanged: {
        if (visible)
            NotificationService.checkServerOwnership();
    }

    Column {
        anchors.centerIn: parent
        spacing: Theme.spacingXS
        width: parent.width * 0.8
        visible: !root.conflict

        VgsIcon {
            anchors.horizontalCenter: parent.horizontalCenter
            name: "notifications_none"
            size: Theme.iconSizeLarge + 16
            color: Theme.surfaceTextAlpha
        }

        StyledText {
            anchors.horizontalCenter: parent.horizontalCenter
            text: I18n.tr("Nothing to see here")
            font.pixelSize: Theme.fontSizeLarge
            color: Theme.surfaceTextAlpha
            font.weight: Font.Medium
            horizontalAlignment: Text.AlignHCenter
        }
    }

    Column {
        id: conflictColumn
        anchors.centerIn: parent
        spacing: Theme.spacingS
        width: parent.width * 0.86
        visible: root.conflict

        VgsIcon {
            anchors.horizontalCenter: parent.horizontalCenter
            name: "notifications_off"
            size: Theme.iconSizeLarge + 16
            color: Theme.error
        }

        StyledText {
            width: parent.width
            text: I18n.tr("%1 is handling notifications, not VGS").arg(NotificationService.serverConflictDaemon || I18n.tr("Another app"))
            font.pixelSize: Theme.fontSizeLarge
            font.weight: Font.Medium
            color: Theme.surfaceText
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
        }

        StyledText {
            width: parent.width
            text: NotificationService.serverConflictFixable ? I18n.tr("It claimed org.freedesktop.Notifications first, so nothing reaches this list.") : I18n.tr("It claimed org.freedesktop.Notifications first: %1.").arg(NotificationService.serverConflictReason || I18n.tr("no supported way to stop it from here"))
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
        }

        VgsButton {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: NotificationService.serverConflictFixable
            enabled: !NotificationService.serverTakeoverBusy
            text: NotificationService.serverTakeoverBusy ? I18n.tr("Taking over…") : I18n.tr("Use VGS for Notifications")
            iconName: "swap_horiz"
            onClicked: NotificationService.takeOverNotificationServer()
        }
    }
}
