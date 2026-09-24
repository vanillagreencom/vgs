pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "PluginLogic.js" as Logic

// Shell configuration: the shipped defaults under config/ merged with the
// user's file. Both files are watched; a change re-derives `effective`
// once. A user file that does not parse keeps the last good value, logs
// the error and blocks writes until it parses again, so a typo never
// blanks the desktop and a manager edit never overwrites unread edits.
// Nothing is built before `ready`: a bar built from the user file alone
// would draw without the shipped layout and fill in a moment later.
Singleton {
    id: root

    readonly property string shippedPath: Quickshell.shellDir + "/../config/shell.json"
    readonly property string userDir: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/vgs"
    readonly property string userPath: userDir + "/shell.json"

    property var shipped: ({ version: 1 })
    property var user: null
    property bool shippedLoaded: false
    // True once the user file was read, found absent, or refused as
    // unparseable; each is a settled first answer.
    property bool userSettled: false
    property bool userParseFailed: false
    readonly property bool ready: shippedLoaded && userSettled
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
            root.userParseFailed = !r.ok;
            if (r.ok) root.user = r.value;
            root.userSettled = true;
        }
        onLoadFailed: error => {
            if (error === FileViewError.FileNotFound) { root.user = null; root.userParseFailed = false; root.userSettled = true; }
            else console.error("config: user file unreadable at " + path + ": " + error);
        }
        onFileChanged: reload()
        onSaveFailed: error => {
            console.error("config: user file not written at " + path + ": " + error);
            root.lastSaveError = String(error);
            root.user = root.userBeforeWrite;
        }
        onSaved: root.lastSaveError = ""
    }

    property var userBeforeWrite: null
    property string lastSaveError: ""

    // Replace the user file whole. The in-memory value moves first so the
    // screen reacts at once; a failed save restores it and is reported on
    // the next write. Returns `ok` or the keyed refusal.
    function writeUser(value) {
        if (lastSaveError !== "") return "refused: user-config=unwritable path=" + userPath + " error=" + lastSaveError;
        userBeforeWrite = root.user;
        root.user = value;
        userView.setText(JSON.stringify(value, null, 2) + "\n");
        return "ok";
    }

    function reload() {
        shippedView.reload();
        userView.reload();
    }
}
