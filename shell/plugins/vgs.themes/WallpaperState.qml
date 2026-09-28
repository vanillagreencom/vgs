import QtQuick
import Quickshell.Io
import qs.Commons

// The wallpaper backgrounds.json in the state directory names as
// `current`, the plugin's one reading of that file: the background draws
// it and the panel names it. The runner replaces the file by rename on
// every change, an image replaced under its name included, and `source`
// carries the file's `stamp`, so each change decodes the image again.
// WatchedFile reads it, so a change that lands during a read is read again.
Item {
    id: root

    readonly property string statePath: Paths.stateDir + "/backgrounds.json"
    // The absolute path of the current image, or "" for none, for a state
    // file that cannot be read and for one the runner did not write.
    property string path: ""
    // The same image as a file URL carrying its stamp, or "" for none. The
    // stamp is a query a local file URL ignores.
    property string source: ""

    // Set `path` and `source` from backgrounds.json's TEXT; a document the
    // runner did not write is logged and names no image.
    function take(text) {
        let doc = null;
        try {
            doc = JSON.parse(text);
        } catch (e) {
            // Logged below with the document's other defects.
        }
        if (doc !== null && typeof doc === "object" && typeof doc.current === "string" && typeof doc.stamp === "string") {
            path = doc.current;
            source = "file://" + doc.current.split("/").map(encodeURIComponent).join("/") + "?" + encodeURIComponent(doc.stamp);
            return;
        }
        if (doc === null || typeof doc !== "object" || doc.current !== null) console.error("background: " + statePath + " malformed");
        path = "";
        source = "";
    }

    WatchedFile {
        path: root.statePath
        onChanged: read()
        onLoaded: content => root.take(content)
        onLoadFailed: error => {
            if (error !== FileViewError.FileNotFound) console.error("background: " + path + " unreadable: " + error);
            root.path = "";
            root.source = "";
        }
    }
}
