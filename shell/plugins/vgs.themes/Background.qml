import QtQuick

// The applied theme's background: the image WallpaperState names, cropped
// to fill the screen. The instance is shown only while that image is
// drawn, so with no current image, or one that cannot be read, the host
// maps no surface and a wallpaper another program draws stays visible.
Item {
    id: root

    property var shell: null
    property var screen: null
    // Read by the background host: whether this instance has an image to
    // draw, so the host maps the screen's surface.
    readonly property bool shown: drawn

    // Whether the image drew its source; it stays true while a new source
    // loads, since the old image stays on screen until the new one is ready.
    property bool drawn: false

    WallpaperState { id: wallpaper }

    Image {
        anchors.fill: parent
        source: wallpaper.source
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        retainWhileLoading: true
        // Decode at device pixels, sized from the screen because the item
        // has no size while the host maps no surface.
        sourceSize.width: root.screen === null ? 0 : Math.ceil(root.screen.width * root.screen.devicePixelRatio)
        sourceSize.height: root.screen === null ? 0 : Math.ceil(root.screen.height * root.screen.devicePixelRatio)
        // Each screen holds its own decode.
        cache: false
        onStatusChanged: {
            if (status === Image.Ready) root.drawn = true;
            else if (status !== Image.Loading) root.drawn = false;
            if (status === Image.Error) console.error("background: " + wallpaper.source + " unreadable");
        }
    }
}
