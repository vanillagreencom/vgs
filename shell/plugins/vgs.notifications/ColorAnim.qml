import QtQuick

// A ColorAnimation on the notifications' motion, as Anim.qml.
ColorAnimation {
    required property var curve

    easing.type: Easing.BezierSpline
    easing.bezierCurve: [curve.x1, curve.y1, curve.x2, curve.y2, 1, 1]
}
