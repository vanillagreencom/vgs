import QtQuick
import Quickshell.Widgets
import "NotificationLogic.js" as Logic

// The people a notification names, as round faces overlapping left to
// right, each laid over the one before it and ringed in the glass so it
// cuts that one out: the image the notification carries on the first
// face, initials on a tint picked from the name on the others and on the
// first when it carries none, and a "+N" chip last, whole on top, for the
// people past them. One face alone is the icon's size; several are
// smaller.
Item {
    id: faces

    required property var look
    property var names: []
    property int more: 0
    // The carried image, drawn on the first face; "" or an image that does
    // not load leaves its initials.
    property string image: ""

    readonly property int count: names.length + (more > 0 ? 1 : 0)
    readonly property bool single: count === 1
    readonly property real size: single ? look.card.icon : look.face.small
    readonly property real step: single ? size : size - look.face.overlap

    implicitWidth: count === 0 ? 0 : size + (count - 1) * step
    implicitHeight: count === 0 ? 0 : size

    Repeater {
        model: faces.count

        ClippingRectangle {
            id: face
            required property int index
            readonly property bool chip: index >= faces.names.length
            x: index * faces.step
            z: face.index
            width: faces.size
            height: faces.size
            radius: faces.look.radius.full
            color: chip ? faces.look.face.chip : faces.look.face.tint[Logic.faceTint(faces.names[face.index])]
            border.width: faces.single ? 0 : faces.look.face.ringWidth
            border.color: faces.look.face.ring

            Text {
                anchors.centerIn: parent
                visible: !photo.visible
                text: face.chip ? "+" + faces.more : Logic.initialsOf(faces.names[face.index])
                textFormat: Text.PlainText
                color: faces.look.text.foreground
                font.family: faces.look.font.family
                font.pixelSize: faces.single ? faces.look.face.initials.size : faces.look.face.initialsSmall.size
                font.weight: faces.single ? faces.look.face.initials.weight : faces.look.face.initialsSmall.weight
            }

            Image {
                id: photo
                anchors.fill: parent
                source: face.index === 0 && !face.chip ? faces.image : ""
                visible: status === Image.Ready
                sourceSize.width: faces.size * Screen.devicePixelRatio
                sourceSize.height: faces.size * Screen.devicePixelRatio
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                smooth: true
            }
        }
    }
}
