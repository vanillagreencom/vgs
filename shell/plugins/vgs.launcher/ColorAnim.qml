import QtQuick
import "Motion.js" as Motion

// A ColorAnimation on the launcher's motion, as Anim.qml.
ColorAnimation {
    required property var curve

    easing.type: Easing.BezierSpline
    easing.bezierCurve: Motion.bezier(curve)
}
