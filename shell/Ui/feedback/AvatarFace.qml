import QtQuick
import QtQuick.Effects
import qs.Commons

// One round face of an AvatarGroup: `image` cut to a circle once it loads,
// or `initials` on `tint` until then and when it does not, with an
// optional ring of `ringWidth` in `ring` over its edge. The group sets
// every value; the face reads no token but the full radius of a circle.
Item {
    id: face

    property string image: ""
    property string initials: ""
    property color tint
    property color ring
    property real ringWidth: 0
    property color foreground
    property string fontFamily: ""
    property real fontSize: 0
    property int fontWeight: Font.Normal
    readonly property bool photoShown: photo.status === Image.Ready

    Rectangle {
        anchors.fill: parent
        radius: Theme.radius.full
        color: face.tint
    }

    Text {
        anchors.centerIn: parent
        visible: !face.photoShown
        text: face.initials
        textFormat: Text.PlainText
        color: face.foreground
        font.family: face.fontFamily
        font.pixelSize: face.fontSize
        font.weight: face.fontWeight
    }

    Rectangle {
        id: mask
        anchors.fill: parent
        radius: Theme.radius.full
        visible: false
        layer.enabled: true
        layer.smooth: true
    }

    // The image cut to the circle: the mask's antialiased edge becomes the
    // image's, over the tint.
    Item {
        anchors.fill: parent
        visible: face.photoShown
        layer.enabled: true
        layer.smooth: true
        layer.effect: MultiEffect {
            maskEnabled: true
            maskSource: mask
            maskThresholdMin: 0.5
            maskSpreadAtMin: 1
        }

        Image {
            id: photo
            anchors.fill: parent
            source: face.image
            sourceSize.width: face.width * Screen.devicePixelRatio
            sourceSize.height: face.height * Screen.devicePixelRatio
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            smooth: true
        }
    }

    Rectangle {
        anchors.fill: parent
        visible: face.ringWidth > 0
        radius: Theme.radius.full
        color: "transparent"
        border.width: face.ringWidth
        border.color: face.ring
    }
}
