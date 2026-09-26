pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "PluginLogic.js" as Logic

// Shell configuration: the shipped defaults under config/ merged with the
// user's file. Both files are watched; a change re-derives `effective`
// once. Each file's state is one tagged value. A file that does not parse
// or fails PluginLogic.configError keeps the last good value and logs the
// error, so a typo never blanks the desktop; a user file in that state
// blocks writes until it passes again, so a manager edit never overwrites
// unread edits. Nothing is built before `ready`: the shipped file has
// loaded once and the user file has settled, so a bar never draws from the
// user file alone. One save is in flight at a time and later edits
// coalesce behind it; a file notification is read once the save lands.
Singleton {
    id: root

    readonly property string shippedPath: Quickshell.shellDir + "/../config/shell.json"
    readonly property string userDir: Paths.configDir
    readonly property string userPath: userDir + "/shell.json"

    // null until the shipped file loaded once; a later failure keeps the
    // last good value.
    property var shipped: null
    property var user: null
    property var shippedText: null
    property var userText: null
    // "pending" until the first answer, then "loaded", "unparseable",
    // "unreadable" or "malformed" (parsed, refused by configError); the user
    // file may also be "absent". A file that was loaded once keeps its last
    // good value through a later failure.
    property string shippedState: "pending"
    property string userState: "pending"
    // What holds the configuration back, or "" once it is ready: the
    // shipped file's state while it has never loaded ("pending" until its
    // first answer, then the failure that stays until the file is fixed),
    // "pending" while the user file has not settled.
    readonly property string notReady: shipped === null ? shippedState : (userState === "pending" ? "pending" : "")
    readonly property bool ready: notReady === ""
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
            const content = text();
            if (root.shippedState === "loaded" && content === root.shippedText) return;
            const r = root.judge(path, content);
            if (r.state === "loaded") {
                if (content !== root.shippedText) root.shipped = r.value;
                root.shippedText = content;
            }
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
        // A read that lands while an edit waits for its save updates only
        // what the disk is known to hold; the edit is written next and
        // wins, as the later of the two.
        onLoaded: {
            root.reloading = false;
            const content = text();
            if (content === root.persistedUser.text && root.persistedUser.state === "loaded") {
                // The disk holds what it held: a write's own notification,
                // or a file readable again.
                root.userState = "loaded";
            } else {
                const r = root.judge(path, content);
                if (r.state === "loaded") {
                    const settled = root.userText === root.persistedUser.text;
                    root.persistedUser = { value: r.value, text: content, state: "loaded" };
                    if (settled) {
                        root.user = r.value;
                        root.userText = content;
                    }
                } else {
                    root.persistedUser = { value: root.persistedUser.value, text: root.persistedUser.text, state: r.state };
                }
                root.userState = r.state;
            }
            Qt.callLater(root.flushSave);
        }
        onLoadFailed: error => {
            root.reloading = false;
            if (error === FileViewError.FileNotFound) {
                const settled = root.userText === root.persistedUser.text;
                root.persistedUser = { value: null, text: null, state: "absent" };
                if (settled) {
                    root.user = null;
                    root.userText = null;
                }
                root.userState = "absent";
            } else {
                console.error("config: user file unreadable at " + path + ": " + error);
                root.userState = "unreadable";
            }
            Qt.callLater(root.flushSave);
        }
        onFileChanged: root.reloadUser()
        onSaved: {
            root.persistedUser = { value: root.activeSave.value, text: root.activeSave.text, state: "loaded" };
            root.userState = "loaded";
            root.activeSave = null;
            Qt.callLater(root.flushSave);
        }
        onSaveFailed: error => {
            console.error("config: user file not written at " + path + ": " + error);
            root.lastSaveError = String(error);
            root.user = root.persistedUser.value;
            root.userText = root.persistedUser.text;
            root.activeSave = null;
            // FileView keeps the bytes of a failed write and skips a later
            // write of the same bytes, so the file is read again first.
            root.reloadRequested = true;
            Qt.callLater(root.flushSave);
        }
    }

    // What the disk is known to hold: the last judged content of the user
    // file, its text (null when absent) and its state. `user` and
    // `userText` run ahead of it while an edit waits for its save.
    property var persistedUser: ({ value: null, text: null, state: "pending" })
    // The save in flight as { value, text }, or null.
    property var activeSave: null
    // A read in flight, and a read wanted once the operation in flight ends.
    property bool reloading: false
    property bool reloadRequested: false
    property string lastSaveError: ""
    // Run the one operation the file view may carry: FileView completes a
    // write in flight synchronously inside a second setText, and a reload
    // during a write starts nothing, so a read and a write never overlap.
    // A wanted read goes first; then the latest edit, when it differs from
    // what the disk holds. An edit that waits behind a file the shell can
    // no longer read is dropped and logged, never written unread.
    function flushSave() {
        if (activeSave !== null || reloading) return;
        if (reloadRequested) {
            reloadRequested = false;
            reloading = true;
            userView.reload();
            return;
        }
        if (userText === persistedUser.text) return;
        if (userState !== "loaded" && userState !== "absent") {
            console.error("config: edit dropped, user file " + userState + " at " + userPath);
            user = persistedUser.value;
            userText = persistedUser.text;
            return;
        }
        activeSave = { value: user, text: userText };
        userView.setText(userText);
    }

    function reloadUser() {
        reloadRequested = true;
        flushSave();
    }

    // Replace the user file whole. Refused unless the file was read or is
    // absent, so an unparseable, malformed or unreadable file is never
    // overwritten unread. The in-memory value moves first so the screen
    // reacts at once; a failed save restores it and is reported once, by
    // refusing the next write with the error. `ok` means the save was
    // queued: a save in flight is followed by one more with the latest
    // edit. Returns `ok` or the keyed refusal.
    function writeUser(value) {
        if (userState !== "loaded" && userState !== "absent") return "refused: user-config=" + userState + " path=" + userPath;
        if (lastSaveError !== "") {
            const error = lastSaveError;
            lastSaveError = "";
            return "refused: user-config=unwritable path=" + userPath + " error=" + error;
        }
        const content = JSON.stringify(value, null, 2) + "\n";
        if (content === userText) return "ok";
        root.user = value;
        root.userText = content;
        flushSave();
        return "ok";
    }

    function reload() {
        shippedView.reload();
        reloadUser();
    }
}
