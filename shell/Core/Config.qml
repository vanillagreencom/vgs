pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "PluginLogic.js" as Logic

// Shell configuration: the shipped defaults under config/ merged with the
// user's file. Both files are watched; a change re-derives `effective`
// once. Each file's state is one tagged value. A file that does not parse
// or fails PluginLogic.configError keeps the last good value, logs the
// error and blocks writes until it passes again, so a typo never blanks
// the desktop and a manager edit never overwrites unread edits. Nothing is
// built before `ready`: the shipped file has loaded once and the user file
// has settled, so a bar never draws from the user file alone.
Singleton {
    id: root

    readonly property string shippedPath: Quickshell.shellDir + "/../config/shell.json"
    readonly property string userDir: Paths.configDir
    readonly property string userPath: userDir + "/shell.json"

    // null until the shipped file loaded once; a later failure keeps the
    // last good value.
    property var shipped: null
    property var user: null
    // "pending" until the first answer, then "loaded", "unparseable",
    // "unreadable" or "malformed" (parsed, refused by configError); the user
    // file may also be "absent". A file that was loaded once keeps its last
    // good value through a later failure.
    property string shippedState: "pending"
    property string userState: "pending"
    readonly property bool ready: shipped !== null && userState !== "pending"
    readonly property var effective: shipped === null ? ({}) : Logic.effectiveConfig(shipped, user)

    // Judge one file's text: { state, value } with `value` only when loaded.
    function judge(label, text) {
        let value;
        try {
            value = JSON.parse(text);
        } catch (e) {
            console.error("config: " + label + " does not parse: " + e.message);
            return { state: "unparseable" };
        }
        const bad = Logic.configError(value);
        if (bad !== "") {
            console.error("config: " + label + " malformed: " + bad);
            return { state: "malformed" };
        }
        return { state: "loaded", value: value };
    }

    FileView {
        id: shippedView
        path: root.shippedPath
        watchChanges: true
        onLoaded: {
            const r = root.judge(path, text());
            if (r.state === "loaded") root.shipped = r.value;
            root.shippedState = r.state;
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
            const r = root.judge(path, text());
            if (r.state === "loaded") root.user = r.value;
            root.userState = r.state;
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
    // absent, so an unparseable, malformed or unreadable file is never
    // overwritten unread. The in-memory value moves first so the screen
    // reacts at once; a failed save restores it and is reported once, by
    // refusing the next write with the error. `ok` means the save was
    // queued. Returns `ok` or the keyed refusal.
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
