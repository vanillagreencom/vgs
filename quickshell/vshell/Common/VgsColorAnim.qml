import QtQuick
import qs.Common

ColorAnimation {
    duration: Theme.expressiveDurations.normal
    easing.type: Easing.BezierSpline
    easing.bezierCurve: Theme.expressiveCurves.standard
}
