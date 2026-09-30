import QtQuick
import "Motion.js" as Motion

// A NumberAnimation on the launcher's motion: `curve` is one curve of
// look.motion.curve and `duration` one of look.motion.duration, so the
// theme's motion scale reaches every animation and 0 stills it.
NumberAnimation {
    required property var curve

    easing.type: Easing.BezierSpline
    easing.bezierCurve: Motion.bezier(curve)
}
