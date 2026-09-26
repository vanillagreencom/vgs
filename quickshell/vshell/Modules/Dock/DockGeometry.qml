pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Services

QtObject {
    id: root

    property var screen: null
    property string edge: "bottom"
    property bool dockVisible: false
    property bool autoHide: false
    property real iconSize: 40
    property real spacing: 4
    property real borderThickness: 0
    property real offset: 0
    property real margin: 0
    property real barSpacing: 0
    property real dpr: 1

    function px(value) {
        return Math.round(value * dpr) / dpr;
    }

    readonly property real effectiveMargin: margin
    readonly property real visualOffset: offset
    readonly property real reserveOffset: offset
    readonly property real joinedEdgeMargin: barSpacing + effectiveMargin + 1 + borderThickness
    readonly property real bodyEdgeMargin: joinedEdgeMargin

    readonly property real bodyThickness: iconSize + spacing * 2 + borderThickness * 2
    readonly property real visualThickness: bodyThickness + 10
    readonly property real surfaceThickness: visualThickness + spacing + effectiveMargin
    readonly property real motionThickness: surfaceThickness + visualOffset

    readonly property real reserveZone: px(bodyThickness + reserveOffset + effectiveMargin)
    readonly property bool shouldReserveSpace: dockVisible && !autoHide && barSpacing <= 0
}
