import QtQuick
import QtQuick.Effects

// Frosted glass: a soft drop shadow, a translucent fill, a faint top-down
// sheen and a hairline inner edge, rounded to a pill. Every layer takes the
// surface's whole geometry and `radius`, so all of them round to the same
// corner: `clip` cuts only to the bounding box, and a layer of another size
// rounds to another corner that shows past the pill's curve. `follow` lays it
// under a card, taking the card's geometry, opacity, scale and transform
// origin; `orb`, from 0 to 1, adds the shade and the specular spot that
// make a small round surface read as a glass bead, as a toast is while it
// is still a dot. The compositor blurs what is behind it when a layer rule
// asks it to (README). Every value comes from `look`, the notifications'
// own table.
Item {
    id: glass

    required property var look
    property Item follow: null
    property real radius: look.radius.full
    property real orb: 0

    Binding on x { when: glass.follow !== null; value: glass.follow ? glass.follow.x : 0 }
    Binding on y { when: glass.follow !== null; value: glass.follow ? glass.follow.y : 0 }
    Binding on width { when: glass.follow !== null; value: glass.follow ? glass.follow.width : 0 }
    Binding on height { when: glass.follow !== null; value: glass.follow ? glass.follow.height : 0 }
    Binding on opacity { when: glass.follow !== null; value: glass.follow ? glass.follow.opacity : 1 }
    Binding on scale { when: glass.follow !== null; value: glass.follow ? glass.follow.scale : 1 }
    Binding on transformOrigin { when: glass.follow !== null; value: glass.follow ? glass.follow.transformOrigin : Item.Center }

    // The corner a pill-shaped radius rounds to, which the shadow needs as a
    // real radius.
    readonly property real corner: Math.min(radius, width / 2, height / 2)

    RectangularShadow {
        anchors.fill: parent
        radius: glass.corner
        blur: glass.look.shadow.blur
        spread: glass.look.shadow.spread
        offset: Qt.vector2d(0, glass.look.shadow.offsetY)
        color: glass.look.shadow.color
        // The card morphs, so its shadow is not cached.
        cached: false
    }

    Rectangle {
        id: body
        anchors.fill: parent
        radius: glass.radius
        color: glass.look.glass.fill
        clip: true

        // The bead: a shade toward the bottom, a spot at the top left.
        Item {
            anchors.fill: parent
            visible: glass.orb > 0
            opacity: glass.orb
            readonly property real d: Math.min(width, height)

            Rectangle {
                anchors.fill: parent
                radius: glass.radius
                gradient: Gradient {
                    GradientStop { position: glass.look.glass.orbShadeStop; color: glass.look.glass.orbClear }
                    GradientStop { position: 1; color: glass.look.glass.orbShade }
                }
            }
            Rectangle {
                x: parent.width / 2 - parent.d * glass.look.glass.orbSpotX
                y: parent.height / 2 - parent.d * glass.look.glass.orbSpotY
                width: parent.d * glass.look.glass.orbSpotWidth
                height: parent.d * glass.look.glass.orbSpotHeight
                radius: glass.look.radius.full
                rotation: glass.look.glass.orbSpotAngle
                gradient: Gradient {
                    GradientStop { position: 0; color: glass.look.glass.orbSpot }
                    GradientStop { position: 1; color: glass.look.glass.orbSpotEnd }
                }
            }
        }

        // Light falling on the top of the glass, fading out `sheenHeight`
        // down, under the fill.
        Rectangle {
            anchors.fill: parent
            radius: glass.radius
            z: -1
            gradient: Gradient {
                GradientStop { position: 0; color: glass.look.glass.sheen }
                GradientStop { position: Math.min(1, glass.look.glass.sheenHeight / glass.height); color: glass.look.glass.sheenEnd }
            }
        }
    }

    Rectangle {
        anchors.fill: parent
        radius: glass.radius
        color: "transparent"
        border.width: glass.look.glass.hairlineWidth
        border.color: glass.look.glass.hairline
    }
}
