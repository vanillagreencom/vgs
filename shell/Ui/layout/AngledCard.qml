import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import qs.Commons

// A card that leans: the content declared inside it is clipped to a
// parallelogram whose top edge sits `skew` pixels right of its bottom edge,
// or left of it for a negative skew, and an outline follows the same edge.
// A dimmed card draws `angledCard.dim` over its content; by default a card
// is dimmed while it is not selected. A selected card draws the selected
// outline. While `hovered`, which the caller sets from its pointer area, a
// dimmed card lifts its wash to `angledCard.hoverDim`, and a card not
// selected draws the `hoverBorder` outline; a selected card keeps its
// outline. The caller sizes
// the card and places it; `corners` is the parallelogram, so a row of
// cards can overlap them edge to edge.
//
// The clip is a Shape of the parallelogram used as a MultiEffect mask over
// a layer of the content: a mask reads coverage alone, so the mask's path
// keeps ShapePath's default opaque fill and no theme colour reaches it. The
// effect's mask thresholds stay at their defaults, so the content's edge is
// the mask's own antialiased coverage, and the outline is drawn over it.
Item {
    id: root

    property real skew: Theme.angledCard.skew
    property bool selected: false
    property bool hovered: false
    property bool dimmed: !selected
    default property alias content: body.data
    // Top-left, top-right, bottom-right and bottom-left, in the card's own
    // coordinates.
    readonly property var corners: [
        Qt.point(Math.max(skew, 0), 0),
        Qt.point(width + Math.min(skew, 0), 0),
        Qt.point(width - Math.max(skew, 0), height),
        Qt.point(-Math.min(skew, 0), height)
    ]
    readonly property var outline: corners.concat([corners[0]])

    Shape {
        id: mask
        anchors.fill: parent
        visible: false
        layer.enabled: true
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            strokeColor: "transparent"
            PathPolyline { path: root.outline }
        }
    }

    Item {
        id: clipped
        anchors.fill: parent
        layer.enabled: true
        layer.smooth: true
        layer.effect: MultiEffect {
            maskEnabled: true
            maskSource: mask
        }

        Item {
            id: body
            anchors.fill: parent
        }
        Rectangle {
            id: wash
            anchors.fill: parent
            color: root.hovered ? Theme.angledCard.hoverDim : Theme.angledCard.dim
            visible: root.dimmed
            Behavior on color { ColorAnimation { duration: Theme.motion.duration.fast; easing.type: Theme.motion.easing.standard } }
        }
    }

    Shape {
        id: edge
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            fillColor: "transparent"
            strokeColor: root.selected ? Theme.angledCard.selectedBorder : root.hovered ? Theme.angledCard.hoverBorder : Theme.angledCard.border
            strokeWidth: root.selected ? Theme.angledCard.selectedBorderWidth : Theme.angledCard.borderWidth
            PathPolyline { path: root.outline }
        }
    }
}
