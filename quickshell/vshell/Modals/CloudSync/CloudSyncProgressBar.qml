import QtQuick
import qs.Common
import qs.Widgets

// Shared progress bar for transfers and storage quotas.
StyledRect {
    id: root

    // fraction < 0 means "unknown" (rclone is still scanning); the track is
    // drawn on its own rather than faking a zero-length fill.
    property real fraction: 0
    property color fillColor: Theme.primary
    property bool animate: true

    width: parent ? parent.width : 0
    height: 4
    radius: height / 2
    color: Theme.surfaceVariantAlpha

    StyledRect {
        width: parent.width * Math.max(0, Math.min(1, root.fraction))
        height: parent.height
        radius: parent.radius
        color: root.fillColor
        visible: root.fraction >= 0

        Behavior on width {
            enabled: root.animate
            NumberAnimation {
                duration: Theme.shortDuration
                easing.type: Easing.OutCubic
            }
        }
    }
}
