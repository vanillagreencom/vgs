pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import qs.Common

// Clip caller content to a leaning parallelogram with a matching wash and outline.
// skewOffset is an absolute top-edge offset, so narrow slices lean more than a wide preview.
Item {
    id: slice

    property real skewOffset: 28
    property bool selected: false
    // Wash unselected tiles toward the desktop background so only the selected preview keeps full color.
    property color dimColor: "black"
    property real dimOpacity: 0.42
    property color borderColor: "transparent"
    property real borderWidth: 1

    default property alias tileContent: masked.data

    signal clicked

    readonly property real _skew: Math.abs(skewOffset)
    readonly property real topLeftX: skewOffset >= 0 ? _skew : 0
    readonly property real topRightX: skewOffset >= 0 ? width : width - _skew
    readonly property real bottomRightX: skewOffset >= 0 ? width - _skew : width
    readonly property real bottomLeftX: skewOffset >= 0 ? 0 : _skew

    Item {
        id: maskShape
        anchors.fill: parent
        visible: false
        layer.enabled: true

        Shape {
            anchors.fill: parent
            antialiasing: true
            preferredRendererType: Shape.CurveRenderer

            ShapePath {
                fillColor: "white"
                strokeColor: "transparent"
                startX: slice.topLeftX
                startY: 0

                PathLine {
                    x: slice.topRightX
                    y: 0
                }

                PathLine {
                    x: slice.bottomRightX
                    y: slice.height
                }

                PathLine {
                    x: slice.bottomLeftX
                    y: slice.height
                }

                PathLine {
                    x: slice.topLeftX
                    y: 0
                }
            }
        }
    }

    Item {
        id: masked
        anchors.fill: parent
        layer.enabled: true
        layer.smooth: true
        layer.effect: MultiEffect {
            maskEnabled: true
            maskSource: maskShape
            maskThresholdMin: 0.3
            maskSpreadAtMin: 0.3
        }
    }


    Shape {
        anchors.fill: parent
        antialiasing: true
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            fillColor: slice.selected ? "transparent" : Theme.withAlpha(slice.dimColor, slice.dimOpacity)
            strokeColor: slice.borderColor
            strokeWidth: slice.borderWidth
            startX: slice.topLeftX
            startY: 0

            PathLine {
                x: slice.topRightX
                y: 0
            }

            PathLine {
                x: slice.bottomRightX
                y: slice.height
            }

            PathLine {
                x: slice.bottomLeftX
                y: slice.height
            }

            PathLine {
                x: slice.topLeftX
                y: 0
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: slice.clicked()
    }
}
