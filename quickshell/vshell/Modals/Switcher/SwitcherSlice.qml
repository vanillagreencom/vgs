pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import qs.Common

// One tile of the switcher carousel: whatever is placed inside it, clipped to a
// leaning parallelogram, washed out unless it is the selection, and outlined by
// a stroke on the same four corners.
//
// The lean IS the chrome. There is no rounding, no card, no shadow and no
// panel behind the carousel — the shape and the dim carry the whole hierarchy,
// which is what makes a row of these read as a stack of angled shots rather
// than as a grid of framed thumbnails.
//
// Children go inside the mask. `skewOffset` is an ABSOLUTE horizontal offset of
// the top edge against the bottom, not a fraction of the width, so a narrow
// slice leans hard and the wide selected preview only tilts — the same
// relationship a physical stack of prints has.
Item {
    id: slice

    property real skewOffset: 28
    property bool selected: false
    // Unselected tiles are washed toward this, so the selection is the only
    // one at full colour. Tracks the foundational background rather than a
    // surface role: it is a dimming wash on top of the scrim, not a fill.
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

    // One path carries both the dim wash and the outline, so the two can never
    // trace different corners.
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
