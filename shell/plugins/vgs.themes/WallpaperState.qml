import QtQuick
import Quickshell.Io
import qs.Commons
import "Files.js" as Files

// The wallpapers backgrounds.json in the state directory names: `current`
// and the `screens` map, the plugin's one reading of that file. The
// background draws `sourceFor` its screen and the panel names `current`.
// The runner replaces the file by rename on every change, an image
// replaced under its name included, and every source carries its entry's
// `stamp`, so each change decodes the image again. WatchedFile reads it,
// so a change that lands during a read is read again.
Item {
    id: root

    readonly property string statePath: Paths.stateDir + "/backgrounds.json"
    // The absolute path of the current image, or "" for none, for a state
    // file that cannot be read and for one the runner did not write.
    property string path: ""
    // The same image as a file URL carrying its stamp, or "" for none. The
    // stamp is a query a local file URL ignores.
    property string source: ""
    // Each output's own image as a file URL carrying its stamp, keyed by
    // the Hyprland output name; empty for a state file that cannot be read
    // and for one the runner did not write.
    property var screens: ({})

    // The source the output NAME draws: its own entry in `screens`, else
    // `current`.
    function sourceFor(name) {
        return Object.prototype.hasOwnProperty.call(screens, name) ? screens[name] : source;
    }

    // The image's URL with its entry's stamp as the query, so a new stamp
    // is a new source.
    function fileUrl(path, stamp) {
        return Files.fileUrl(path) + "?" + encodeURIComponent(stamp);
    }

    // The `screens` map of a document as sources, {} for an absent key, or
    // null for one the runner did not write.
    function screenSources(value) {
        if (value === undefined) return {};
        if (value === null || typeof value !== "object" || Array.isArray(value)) return null;
        const sources = {};
        for (const name of Object.keys(value)) {
            const entry = value[name];
            if (entry === null || typeof entry !== "object" || typeof entry.path !== "string" || typeof entry.stamp !== "string") return null;
            sources[name] = fileUrl(entry.path, entry.stamp);
        }
        return sources;
    }

    function clear() {
        path = "";
        source = "";
        screens = {};
    }

    // Set `path`, `source` and `screens` from backgrounds.json's TEXT; a
    // document the runner did not write is logged and names no image.
    function take(text) {
        let doc = null;
        try {
            doc = JSON.parse(text);
        } catch (e) {
            // Logged below with the document's other defects.
        }
        const sources = doc !== null && typeof doc === "object" ? screenSources(doc.screens) : null;
        const current = sources !== null && typeof doc.current === "string" && typeof doc.stamp === "string";
        if (sources !== null && (current || doc.current === null)) {
            path = current ? doc.current : "";
            source = current ? fileUrl(doc.current, doc.stamp) : "";
            screens = sources;
            return;
        }
        console.error("background: " + statePath + " malformed");
        clear();
    }

    WatchedFile {
        path: root.statePath
        onChanged: read()
        onLoaded: content => root.take(content)
        onLoadFailed: error => {
            if (error !== FileViewError.FileNotFound) console.error("background: " + path + " unreadable: " + error);
            root.clear();
        }
    }
}
