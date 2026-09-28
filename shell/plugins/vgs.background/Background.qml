import QtQuick
import Quickshell.Io
import qs.Commons

// The applied theme's background: the image backgrounds.json in the state
// directory names as `current`, cropped to fill the screen over the host's
// background colour, which shows alone while no image is current or the
// image cannot be read. The runner replaces backgrounds.json by rename on
// every change, an image replaced under its name included, which the
// watch sees. The `background` symlink beside it names the same image for
// other applications, but a watch on a symlink follows its target and
// misses a retargeted link: runtime.md § QML. One view holds the watcher
// and another reads, since a reload rebuilds the reloading view's watcher
// and starts no second read while one is in flight: the same section.
Item {
    id: root

    property var shell: null
    property var screen: null

    readonly property string statePath: Paths.stateDir + "/backgrounds.json"
    // The absolute path of the image drawn, or "" for none.
    property string current: ""
    // The reader's read: `running` from the first, which the reader starts
    // when its path is set; `stale` when the file changed during it; `idle`.
    property string readState: "running"

    function changed() {
        if (readState !== "idle") {
            readState = "stale";
            return;
        }
        readState = "running";
        reader.reload();
    }

    // Whether a change overtook the read that just ended; if so the read
    // starts again once the handler returns and its result is dropped.
    function readAgain() {
        if (readState !== "stale") return false;
        readState = "running";
        Qt.callLater(() => reader.reload());
        return true;
    }

    // Draw PATH, decoding it again even when it is the image drawn now,
    // since every change to the state file is a change to what it names.
    function show(path) {
        current = "";
        current = path;
    }

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
        console.error("background: " + statePath + " malformed");
        return "";
    }

    FileView {
        preload: false
        path: root.statePath
        watchChanges: true
        printErrors: false
        onFileChanged: root.changed()
    }

    FileView {
        id: reader
        path: root.statePath
        printErrors: false
        onLoaded: {
            if (root.readAgain()) return;
            root.readState = "idle";
            root.show(root.currentOf(text()));
        }
        onLoadFailed: error => {
            if (root.readAgain()) return;
            root.readState = "idle";
            if (error !== FileViewError.FileNotFound) console.error("background: " + path + " unreadable: " + error);
            root.show("");
        }
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
        // Each screen holds its own decode, and a source set again reads
        // the file again.
        cache: false
        onStatusChanged: if (status === Image.Error) console.error("background: " + root.current + " unreadable")
    }
}
