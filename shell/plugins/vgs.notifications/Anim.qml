import QtQuick

// A NumberAnimation on the notifications' motion: `curve` is one curve of
// look.motion.curve and `duration` one of look.motion.duration, so the
// theme's motion scale reaches every animation and 0 stills it.
NumberAnimation {
    required property var curve

    easing.type: Easing.BezierSpline
    easing.bezierCurve: [curve.x1, curve.y1, curve.x2, curve.y2, 1, 1]
}
