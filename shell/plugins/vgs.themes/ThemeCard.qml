import QtQuick
import qs.Commons
import qs.Ui
import "Files.js" as Files

// One theme's card on the browser's rail: its image, decoded at the size
// the carousel hands it, else a palette card that fills with the theme's
// background, names it in its foreground and ends in a band of its other
// palette colours. The palette card also shows while the image loads and
// when it cannot be read. A Spinner turns over the card while the browser
// installs or applies its theme.
Item {
    id: root

    // The card BrowserLogic.cards built for this theme, with the view's
    // `generation`, the stamp its image loads under.
    required property var modelData
    required property size decodeSize
    // Whether the browser is installing, applying or downloading for this
    // theme.
    property bool busy: false

    readonly property var colors: modelData.palette
    // The palette colours drawn in the band, in the palette group's order.
    readonly property var bandKeys: colors === null ? [] : Object.keys(colors).filter(key => key !== "background")

    anchors.fill: parent

    Rectangle {
        anchors.fill: parent
        visible: image.status !== Image.Ready
        color: root.colors === null ? Theme.color.surface : Theme.toColor(root.colors.background)

        Label {
            role: "h2"
            anchors.centerIn: parent
            width: parent.width - 2 * Theme.space.xxl
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            text: root.modelData.label
            color: root.colors === null ? Theme.color.textMuted : Theme.toColor(root.colors.foreground)
        }

        Row {
            id: band
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: Theme.space.xxl

            Repeater {
                model: root.bandKeys
                Rectangle {
                    required property string modelData
                    width: band.width / root.bandKeys.length
                    height: band.height
                    color: Theme.toColor(root.colors[modelData])
                }
            }
        }
    }

    Image {
        id: image
        anchors.fill: parent
        visible: status === Image.Ready
        source: root.modelData.image === null ? "" : Files.stampedUrl(root.modelData.image, root.modelData.generation)
        sourceSize: root.decodeSize
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        onStatusChanged: if (status === Image.Error) console.warn("themes: card image unreadable path=" + root.modelData.image)
    }

    Spinner {
        anchors.centerIn: parent
        visible: root.busy
    }
}
