import QtQuick

// The applied theme's background: the image WallpaperState names for this
// screen, cropped to fill it. A screen whose own image cannot be read draws
// `current` in its place. The instance is shown only while an image is
// drawn, so with no image, or one that cannot be read, the host maps no
// surface and a wallpaper another program draws stays visible.
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
    // The source WallpaperState names for this screen, its own or `current`.
    readonly property string wanted: wallpaper.sourceFor(root.screen === null ? "" : root.screen.name)
    // The last `wanted` source that failed to decode. While `wanted` names
    // it the screen draws `current`, the same URL when the entry names the
    // current image, so a failed URL is not loaded again and a later
    // `current` is drawn; a changed entry is tried again.
    property string unreadable: ""

    WallpaperState { id: wallpaper }

    Image {
        anchors.fill: parent
        source: root.wanted === root.unreadable ? wallpaper.source : root.wanted
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
            if (status !== Image.Error) return;
            console.error("background: " + source + " unreadable");
            if (root.wanted !== root.unreadable) root.unreadable = root.wanted;
        }
    }
}
