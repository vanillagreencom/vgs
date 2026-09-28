import QtQuick
import Quickshell.Io
import qs.Commons

// The applied theme's background: the image backgrounds.json in the state
// directory names as `current`, cropped to fill the screen. The plugin is
// shown only while that image is drawn, so with no current image, or one
// that cannot be read, the host maps no surface and a wallpaper another
// program draws stays visible. The runner replaces backgrounds.json by
// rename on every change, an image replaced under its name included, and
// the image is loaded under its `stamp`, so each change decodes it again.
// WatchedFile reads it, so a change that lands during a read is read again.
Item {
    id: root

    property var shell: null
    property var screen: null
    // Read by the background host: whether this instance has an image to
    // draw, so the host maps the screen's surface.
    readonly property bool shown: drawn

    readonly property string statePath: Paths.stateDir + "/backgrounds.json"
    // The image drawn, as a file URL carrying its stamp, or "" for none.
    property string source: ""
    // Whether the image drew its source; it stays true while a new source
    // loads, since the old image stays on screen until the new one is ready.
    property bool drawn: false
    // The image URL backgrounds.json's TEXT names, or "" when it names none
    // or is not the runner's; a document the runner did not write is
    // logged, not drawn. The stamp is a query a local file URL ignores.
    function sourceOf(text) {
        let doc = null;
        try {
            doc = JSON.parse(text);
        } catch (e) {
            // Logged below with the document's other defects.
        }
        if (doc !== null && typeof doc === "object" && doc.current === null) return "";
        if (doc !== null && typeof doc === "object" && typeof doc.current === "string" && typeof doc.stamp === "string")
            return "file://" + doc.current.split("/").map(encodeURIComponent).join("/") + "?" + encodeURIComponent(doc.stamp);
        console.error("background: " + statePath + " malformed");
        return "";
    }

    WatchedFile {
        path: root.statePath
        onChanged: read()
        onLoaded: content => { root.source = root.sourceOf(content); }
        onLoadFailed: error => {
            if (error !== FileViewError.FileNotFound) console.error("background: " + path + " unreadable: " + error);
            root.source = "";
        }
    }

    Image {
        anchors.fill: parent
        source: root.source
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        retainWhileLoading: true
        // Decoded at the size that covers the screen, never the file's own,
        // and sized from the screen, since the item has no size while the
        // host maps no surface: https://doc.qt.io/qt-6/qml-qtquick-image.html#sourceSize-prop
        sourceSize.width: root.screen === null ? 0 : root.screen.width
        sourceSize.height: root.screen === null ? 0 : root.screen.height
        // Each screen holds its own decode.
        cache: false
        onStatusChanged: {
            if (status === Image.Ready) root.drawn = true;
            else if (status !== Image.Loading) root.drawn = false;
            if (status === Image.Error) console.error("background: " + root.source + " unreadable");
        }
    }
}
