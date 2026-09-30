import QtQuick

// One movement of the list motion: `step` is `{ duration, easing }` as
// `motion.list` publishes it, an `Easing` enumerator. A plugin that owns its
// look hands `Easing.BezierSpline` with `curve`, the list
// `Easing.bezierCurve` reads; every other easing ignores `curve`, so the
// shell's own steps carry none.
NumberAnimation {
    required property var step

    duration: step.duration
    easing.type: step.easing
    easing.bezierCurve: step.easing === Easing.BezierSpline ? step.curve : []
}
