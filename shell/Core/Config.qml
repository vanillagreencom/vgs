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
// would draw without the shipped layout and fill in a moment later. Each
// file's state is one tagged value; every file settles, so an unreadable
// file leaves the shell drawing from what it has, never blank.
Singleton {
    id: root

    readonly property string shippedPath: Quickshell.shellDir + "/../config/shell.json"
    readonly property string userDir: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/vgs"
    readonly property string userPath: userDir + "/shell.json"

    property var shipped: ({ version: 1 })
    property var user: null
    // "pending" until the first answer, then "loaded", "unparseable" or
    // "unreadable"; the user file may also be "absent". A file that was
    // loaded once keeps its last good value through a later failure.
    property string shippedState: "pending"
    property string userState: "pending"
    readonly property bool ready: shippedState !== "pending" && userState !== "pending"
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
            if (r.ok) root.shipped = r.value;
            root.shippedState = r.ok ? "loaded" : "unparseable";
        }
        onLoadFailed: error => {
            console.error("config: shipped defaults unreadable at " + path + ": " + error);
            root.shippedState = "unreadable";
        }
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
            root.userState = r.ok ? "loaded" : "unparseable";
        }
        onLoadFailed: error => {
            if (error === FileViewError.FileNotFound) {
                root.user = null;
                root.userState = "absent";
                return;
            }
            console.error("config: user file unreadable at " + path + ": " + error);
            root.userState = "unreadable";
        }
        onFileChanged: reload()
        onSaveFailed: error => {
            console.error("config: user file not written at " + path + ": " + error);
            root.lastSaveError = String(error);
            root.user = root.userBeforeWrite;
        }
    }

    property var userBeforeWrite: null
    property string lastSaveError: ""

    // Replace the user file whole. Refused unless the file was read or is
    // absent, so an unparseable or unreadable file is never overwritten
    // unread. The in-memory value moves first so the screen reacts at once;
    // a failed save restores it and is reported once, by refusing the next
    // write with the error. `ok` means the save was queued. Returns `ok` or
    // the keyed refusal.
    function writeUser(value) {
        if (userState !== "loaded" && userState !== "absent") return "refused: user-config=" + userState + " path=" + userPath;
        if (lastSaveError !== "") {
            const error = lastSaveError;
            lastSaveError = "";
            return "refused: user-config=unwritable path=" + userPath + " error=" + error;
        }
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
