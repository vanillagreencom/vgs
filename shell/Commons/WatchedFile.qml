import QtQuick
import Quickshell
import Quickshell.Io

// One file read again whenever it changes, and written through the same
// view. Two Quickshell FileView behaviours drop a change otherwise
// (docs/architecture/runtime-qml.md): a reload rebuilds the reloading
// view's own watcher after its read has started, so a change landing in
// between raises no notification; and a reload while a read is in flight
// starts nothing, so the read reports the file as it was. One view holds
// the watcher and is never read or reloaded; the other reads and writes and
// watches nothing. A change or a read() during a read marks that read
// stale: its result is dropped unreported and the file is read again once
// the handler returns, so `loaded` and `loadFailed` report only a read no
// change overtook. The first read starts when the view is built. The view
// reports a result while it still holds that operation, and a reload or a
// write asked from an owner's handler then starts nothing or is lost, so
// every read and write reaches the view once the handler returns.
//
// A read asked during a write starts nothing either, so the owner sequences
// the two: read() and write() are refused while a write is in flight, and a
// change seen then is reported through `changed` for the owner to read once
// the write lands.
Scope {
    id: file

    required property string path
    // The one operation on the file: `reading` from the first, which the
    // reading view starts when `path` is set; `stale` when a change or a
    // read() landed during the read; `writing`; `idle`.
    property string operation: "reading"
    readonly property bool busy: operation !== "idle"
    readonly property bool inRead: operation === "reading" || operation === "stale"

    signal loaded(string content)
    signal loadFailed(var error)
    signal saved()
    signal saveFailed(var error)
    // The file changed while no read was in flight.
    signal changed()

    // Read the file now, or again once the read in flight ends.
    function read() {
        switch (operation) {
        case "idle":
            readLater();
            return;
        case "reading":
        case "stale":
            operation = "stale";
            return;
        case "writing":
            console.error("watched-file: refused: read operation=writing path=" + path);
            return;
        }
        console.error("watched-file: unknown operation=" + operation + " path=" + path);
    }

    // Replace the file with `content`. FileView skips a write of the bytes it
    // last read or wrote, and a skipped write reports nothing, so the owner
    // writes only bytes that differ from those.
    function write(content) {
        if (operation !== "idle") {
            console.error("watched-file: refused: write operation=" + operation + " path=" + path);
            return;
        }
        operation = "writing";
        Qt.callLater(() => view.setText(content));
    }

    function readLater() {
        operation = "reading";
        Qt.callLater(reloadView);
    }

    function reloadView() {
        view.reload();
    }

    // The read's result, or false when it was stale and a read follows.
    function settle() {
        if (operation === "stale") {
            readLater();
            return false;
        }
        if (operation !== "reading") console.error("watched-file: read finished outside a read operation=" + operation + " path=" + path);
        operation = "idle";
        return true;
    }

    function wrote() {
        if (operation !== "writing") console.error("watched-file: write finished outside a write operation=" + operation + " path=" + path);
        operation = "idle";
    }

    FileView {
        preload: false
        path: file.path
        watchChanges: true
        printErrors: false
        onFileChanged: file.inRead ? file.read() : file.changed()
    }

    FileView {
        id: view
        path: file.path
        printErrors: false
        onLoaded: if (file.settle()) file.loaded(text())
        onLoadFailed: error => { if (file.settle()) file.loadFailed(error); }
        onSaved: {
            file.wrote();
            file.saved();
        }
        onSaveFailed: error => {
            file.wrote();
            file.saveFailed(error);
        }
    }
}
