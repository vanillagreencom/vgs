import QtQuick
import QtQuick.Effects

// Frosted glass: a soft drop shadow, a translucent fill, a faint top-down
// sheen and a hairline inner edge. The compositor blurs what is behind it
// when a layer rule asks it to (README). Children go into the clipped body.
// Every value comes from `look`, the launcher's own table.
Item {
    id: glass

    required property var look
    default property alias content: body.data
    property color fill: look.glass.fill
    property real radius: look.card.radius
    // `wide` for the card, `tight` for a small transient surface.
    property var elevation: look.shadow.wide
    // Cache the shadow only for a surface that keeps its size; a resizing
    // card would rebuild the cache every frame.
    property bool shadowCached: true
    property real padding: 0
    readonly property real contentInset: padding

    RectangularShadow {
        anchors.fill: parent
        radius: glass.radius
        blur: glass.elevation.blur
        spread: glass.elevation.spread
        offset: Qt.vector2d(0, glass.elevation.offsetY)
        color: glass.elevation.color
        cached: glass.shadowCached
    }

    Rectangle {
        id: body
        anchors.fill: parent
        radius: glass.radius
        color: glass.fill
        clip: true

        // Light falling on the top of the glass, at a fixed height so it
        // does not redraw while the card resizes.
        Rectangle {
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: Math.min(glass.look.glass.sheenHeight, parent.height)
            radius: parent.radius
            z: -1
            gradient: Gradient {
                GradientStop { position: 0; color: glass.look.glass.sheen }
                GradientStop { position: 1; color: glass.look.glass.sheenEnd }
            }
        }
    }

    // The hairline sits above the content, so no row covers it.
    Rectangle {
        anchors.fill: parent
        radius: glass.radius
        color: "transparent"
        border.width: glass.look.glass.hairlineWidth
        border.color: glass.look.glass.hairline
    }
}
