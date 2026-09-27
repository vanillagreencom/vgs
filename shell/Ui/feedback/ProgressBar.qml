import QtQuick
import QtQuick.Templates as T
import qs.Commons

// A progress bar. The template owns `from`, `to`, `value`, `position` and
// `indeterminate`; this file draws the track and the filled part. An
// indeterminate bar slides a share of the track back and forth on
// `progress.duration`, and stands still when that duration is zero.
T.ProgressBar {
    id: root

    implicitWidth: Theme.size.panel.sm / 2
    implicitHeight: Theme.progress.height

    background: Rectangle {
        radius: Theme.progress.radius
        color: Theme.progress.track
    }

    contentItem: Item {
        clip: true
        Rectangle {
            id: fill
            readonly property int span: parent.width * Theme.progress.indeterminateShare
            width: root.indeterminate ? span : root.visualPosition * parent.width
            height: parent.height
            radius: Theme.progress.radius
            color: Theme.progress.fill
            SequentialAnimation on x {
                running: root.indeterminate && Theme.progress.duration > 0
                loops: Animation.Infinite
                onStopped: fill.x = 0
                NumberAnimation { from: 0; to: fill.parent.width - fill.span; duration: Theme.progress.duration; easing.type: Theme.motion.easing.standard }
                NumberAnimation { from: fill.parent.width - fill.span; to: 0; duration: Theme.progress.duration; easing.type: Theme.motion.easing.standard }
            }
        }
    }
}
