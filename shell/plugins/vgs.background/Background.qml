import QtQuick
import Quickshell.Io
import qs.Commons

// The applied theme's background: the image backgrounds.json in the state
// directory names as `current`, cropped to fill the screen over the host's
// background colour, which shows alone while no image is current or the
// image cannot be read. The runner replaces backgrounds.json by rename on
// every change, which the watch sees. The `background` symlink beside it
// names the same image for other applications, but a watch on a symlink
// follows its target and misses a retargeted link: runtime.md § QML.
Item {
    id: root

    property var shell: null
    property var screen: null

    // The absolute path of the image drawn, or "" for none.
    property string current: ""

    // The `current` of backgrounds.json's TEXT, or "" when the document
    // names none or is not the runner's; a document the runner did not
    // write is logged, not drawn.
    function currentOf(text) {
        let doc = null;
        try {
            doc = JSON.parse(text);
        } catch (e) {
            // Logged below with the document's other defects.
        }
        if (doc !== null && typeof doc === "object" && (doc.current === null || typeof doc.current === "string"))
            return doc.current === null ? "" : doc.current;
        console.error("background: " + state.path + " malformed");
        return "";
    }

    FileView {
        id: state
        path: Paths.stateDir + "/backgrounds.json"
        watchChanges: true
        printErrors: false
        onLoaded: root.current = root.currentOf(text())
        onLoadFailed: error => {
            if (error !== FileViewError.FileNotFound) console.error("background: " + path + " unreadable: " + error);
            root.current = "";
        }
        onFileChanged: reload()
    }

    Image {
        anchors.fill: parent
        source: root.current === "" ? "" : "file://" + root.current.split("/").map(encodeURIComponent).join("/")
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        // Decoded at the size that covers the screen, never the file's own:
        // https://doc.qt.io/qt-6/qml-qtquick-image.html#sourceSize-prop
        sourceSize.width: width
        sourceSize.height: height
        // Each screen holds its own decode and none outlives its image.
        cache: false
        onStatusChanged: if (status === Image.Error) console.error("background: " + root.current + " unreadable")
    }
}
