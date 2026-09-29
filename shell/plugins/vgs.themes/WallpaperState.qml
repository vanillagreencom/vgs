import QtQuick
import Quickshell.Io
import qs.Commons
import "Files.js" as Files

// The wallpapers backgrounds.json in the state directory names: `current`
// and the `screens` map, the plugin's one reading of that file. The
// background draws `sourceFor` its screen, the panel names `current`, and
// the wallpaper browser selects the path its scope shows.
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
    // Each output's own image as its absolute path, keyed as `screens`.
    property var screenPaths: ({})

    // The source the output NAME draws: its own entry in `screens`, else
    // `current`.
    function sourceFor(name) {
        return Object.prototype.hasOwnProperty.call(screens, name) ? screens[name] : source;
    }

    // The `screens` map of a document as { sources, paths }, each empty
    // for an absent key, or null for one the runner did not write.
    function screenSources(value) {
        if (value === undefined) return { sources: {}, paths: {} };
        if (value === null || typeof value !== "object" || Array.isArray(value)) return null;
        const sources = {};
        const paths = {};
        for (const name of Object.keys(value)) {
            const entry = value[name];
            if (entry === null || typeof entry !== "object" || typeof entry.path !== "string" || typeof entry.stamp !== "string") return null;
            sources[name] = Files.stampedUrl(entry.path, entry.stamp);
            paths[name] = entry.path;
        }
        return { sources: sources, paths: paths };
    }

    function clear() {
        path = "";
        source = "";
        screens = {};
        screenPaths = {};
    }

    // Set `path`, `source`, `screens` and `screenPaths` from
    // backgrounds.json's TEXT; a document the runner did not write is
    // logged and names no image.
    function take(text) {
        let doc = null;
        try {
            doc = JSON.parse(text);
        } catch (e) {
            // Logged below with the document's other defects.
        }
        const own = doc !== null && typeof doc === "object" ? screenSources(doc.screens) : null;
        const current = own !== null && typeof doc.current === "string" && typeof doc.stamp === "string";
        if (own !== null && (current || doc.current === null)) {
            path = current ? doc.current : "";
            source = current ? Files.stampedUrl(doc.current, doc.stamp) : "";
            screens = own.sources;
            screenPaths = own.paths;
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
