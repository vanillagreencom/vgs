import QtQuick
import Quickshell
import Quickshell.Io
import "Tokens.js" as Tokens
import "ThemeLogic.js" as ThemeLogic

// The theme file and the last document it accepted. Theme holds the one
// instance; this file is absent from qmldir, so no plugin can name it. The
// file is read the way Config reads shell.json: an absent file is the
// expected case and publishes the defaults, so a file removed while the
// shell runs draws what a fresh start without it would. A file that is
// unreadable or that the judge refuses is logged and leaves the last
// accepted theme; nothing of a refused document is published. One view
// holds the file's watcher and another reads it, because a reload rebuilds
// the reloading view's own watcher.
Scope {
    id: source

    readonly property string path: Paths.configDir + "/theme.json"
    readonly property var defaults: ThemeLogic.defaults(Tokens.TOKENS)

    // The accepted theme: its name and its resolved values, a tree in the
    // table's shape. `revision` rises after both hold the new theme.
    property string name: defaults.name
    property var values: defaults.values
    property int revision: 0
    // The file: `pending` until its first read, then `loaded`, `absent`,
    // `refused` or `unreadable`.
    property string state: "pending"
    // The reading view's read: `running` from the first, which the view
    // starts when `path` is set; `stale` when the file changed during it;
    // `idle`.
    property string readState: "running"

    function publish(accepted) {
        name = accepted.name;
        values = accepted.values;
        revision += 1;
    }

    // FileView starts no second read of a path while one is in flight, the
    // handlers of its result included, and that read reports the file as it
    // was. A change seen during a read is read again once the handler
    // returns, and the result it overtook is dropped unpublished.
    function changed() {
        if (readState !== "idle") {
            readState = "stale";
            return;
        }
        readState = "running";
        view.reload();
    }

    function readAgain() {
        if (readState !== "stale") return false;
        readState = "running";
        Qt.callLater(() => view.reload());
        return true;
    }

    // A reload rebuilds the reloading view's watcher after its read has
    // started, and a change that lands in between raises no notification.
    // This view never reads and is never reloaded, so its watcher is built
    // once and no change lands on a discarded one.
    FileView {
        preload: false
        path: source.path
        watchChanges: true
        printErrors: false
        onFileChanged: source.changed()
    }

    // The reader. It watches nothing, so its reloads build no watcher.
    FileView {
        id: view
        path: source.path
        printErrors: false
        onLoaded: {
            if (source.readAgain()) return;
            source.readState = "idle";
            const accepted = ThemeLogic.accept(Tokens.TOKENS, text());
            if (!accepted.ok) {
                console.error(ThemeLogic.refusalLine(accepted) + " file=" + path);
                source.state = "refused";
                return;
            }
            source.publish(accepted);
            source.state = "loaded";
        }
        onLoadFailed: error => {
            if (source.readAgain()) return;
            source.readState = "idle";
            if (error === FileViewError.FileNotFound) {
                if (source.values !== source.defaults.values) source.publish(source.defaults);
                source.state = "absent";
                return;
            }
            console.error("theme: " + path + " unreadable: " + error);
            source.state = "unreadable";
        }
    }
}
