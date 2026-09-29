import QtQuick
import qs.Commons
import qs.Ui
import "Files.js" as Files

// One card on the wallpaper browser's rail: an image card draws its image,
// decoded at the size the carousel hands it; the download or update card,
// and an image card while its image loads or when it cannot be read, fill
// with the surface colour and name the card under an icon. A Spinner
// turns over the card while the browser sets its image or runs its
// download.
Item {
    id: root

    // The card BrowserLogic.wallpaperCards built.
    required property var modelData
    required property size decodeSize
    // Whether the browser is setting this image or running this card's
    // download.
    property bool busy: false

    readonly property bool offer: modelData.kind !== "image"

    anchors.fill: parent

    Rectangle {
        anchors.fill: parent
        visible: image.status !== Image.Ready
        color: Theme.color.surface

        Column {
            anchors.centerIn: parent
            width: parent.width - 2 * Theme.space.xxl
            spacing: Theme.space.sm

            Icon {
                anchors.horizontalCenter: parent.horizontalCenter
                name: root.modelData.kind === "download" ? "download" : root.modelData.kind === "update" ? "refresh-cw" : "image"
                size: Theme.icon.size.xl
                color: Theme.color.textMuted
            }

            Label {
                role: "h2"
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideMiddle
                text: root.modelData.label
                color: Theme.color.textMuted
            }
        }
    }

    Image {
        id: image
        anchors.fill: parent
        visible: status === Image.Ready
        source: root.offer ? "" : Files.fileUrl(root.modelData.path)
        sourceSize: root.decodeSize
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        onStatusChanged: if (status === Image.Error) console.warn("themes: wallpaper card image unreadable path=" + root.modelData.path)
    }

    Spinner {
        anchors.centerIn: parent
        visible: root.busy
    }
}
