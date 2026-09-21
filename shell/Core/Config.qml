pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "PluginLogic.js" as Logic

// Shell configuration: the shipped defaults under config/ merged with the
// user's file. Both files are watched; a change re-derives `effective`
// once. A user file that does not parse keeps the last good value and logs
// the error, so a typo never blanks the desktop.
Singleton {
    id: root

    readonly property string shippedPath: Quickshell.shellDir + "/../config/shell.json"
    readonly property string userDir: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/vgs"
    readonly property string userPath: userDir + "/shell.json"

    property var shipped: ({ version: 1 })
    property var user: null
    property bool shippedLoaded: false
    readonly property var effective: Logic.effectiveConfig(shipped, user)

    function parse(label, text) {
        try {
            return { ok: true, value: JSON.parse(text) };
        } catch (e) {
            console.error("config: " + label + " does not parse: " + e.message);
            return { ok: false };
        }
    }

    FileView {
        id: shippedView
        path: root.shippedPath
        watchChanges: true
        blockLoading: true
        onLoaded: {
            const r = root.parse(path, text());
            if (r.ok) { root.shipped = r.value; root.shippedLoaded = true; }
        }
        onLoadFailed: error => console.error("config: shipped defaults unreadable at " + path + ": " + error)
        onFileChanged: reload()
    }

    FileView {
        id: userView
        path: root.userPath
        watchChanges: true
        printErrors: false
        onLoaded: {
            const r = root.parse(path, text());
            if (r.ok) root.user = r.value;
        }
        onLoadFailed: error => { if (error === FileViewError.FileNotFound) root.user = null; else console.error("config: user file unreadable at " + path + ": " + error); }
        onFileChanged: reload()
    }

    // Replace the user file whole. The watcher then re-derives `effective`.
    function writeUser(value) {
        root.user = value;
        userView.setText(JSON.stringify(value, null, 2) + "\n");
    }

    function reload() {
        shippedView.reload();
        userView.reload();
    }
}
