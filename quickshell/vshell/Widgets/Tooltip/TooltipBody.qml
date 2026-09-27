import QtQuick
import qs.Common
import qs.Services
import qs.Widgets

// Shared tooltip body for layer-surface and in-window hosts.
// Hosts provide size limits and declare whether a blurred backdrop is available for glass styling.
VgsSurfaceChrome {
    id: root

    property string text: ""
    // Cap the body width including padding.
    property real maxWidth: 300
    property real minWidth: 0

    implicitWidth: Math.min(maxWidth, Math.max(minWidth, label.implicitWidth + Theme.spacingM * 2))
    implicitHeight: label.implicitHeight + Theme.spacingS * 2

    radius: Theme.controlRadius
    // Pass backdrop availability explicitly; the default alpha assumes blur and would leave an unblurred host translucent.
    surfaceColor: Theme.popupSurfaceColor(Theme.surfaceContainerHigh, root.blurAvailable)
    borderColor: BlurService.borderColor
    borderWidth: BlurService.borderWidth

    StyledText {
        id: label

        anchors.centerIn: parent
        text: root.text
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceText
        wrapMode: Text.NoWrap
        maximumLineCount: 1
        elide: Text.ElideRight
        width: Math.min(implicitWidth, root.maxWidth - Theme.spacingM * 2)
    }
}
