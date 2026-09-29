import QtQuick

// Stands in for Quickshell.Io's FileView, whose plugin does not load outside
// the shell. It arms an initial read and watcher when a path is assigned, so
// a test can create a view and then set its path as production QML does. It
// has the two behaviours WatchedFile works around
// (docs/architecture/runtime-qml.md): a reload while the view's read or
// write is outstanding, a result handler included, starts nothing, and a
// reload of a watching view builds its watcher again. A read or a write
// that starts during a result handler's run is lost once the handler
// returns. Nothing touches a disk: the test finishes each operation.
QtObject {
    id: view

    property string path
    property bool preload: true
    property bool watchChanges: false
    property bool printErrors: true

    // What the test reads back: the operation outstanding (`read`, `write`
    // or ""), how many reads started, how many reloads were asked, how many
    // watchers were built and the last bytes a write took.
    property string live: ""
    property int reads: 0
    property int reloads: 0
    property int watchers: 0
    property string written: ""
    property string content: ""
    property string armedPath: ""

    signal loaded()
    signal loadFailed(int error)
    signal saved()
    signal saveFailed(int error)
    signal fileChanged()

    function text() { return content; }

    function start() {
        if (live !== "") return;
        live = "read";
        reads += 1;
    }

    function reload() {
        reloads += 1;
        if (preload) start();
        if (watchChanges) watchers += 1;
    }

    function setText(bytes) {
        written = bytes;
        live = "write";
    }

    // The result of the outstanding operation, reported while the view still
    // holds it; what a handler starts meanwhile is dropped with it.
    function report(emitResult) {
        emitResult();
        live = "";
    }

    function finishRead(bytes) {
        content = bytes;
        report(() => loaded());
    }

    function failRead(error) { report(() => loadFailed(error)); }

    function finishWrite() {
        content = written;
        report(() => saved());
    }

    function change() { fileChanged(); }

    function armPath() {
        if (path === "") return;
        if (path === armedPath) return;
        armedPath = path;
        if (preload) start();
        if (watchChanges) watchers += 1;
    }

    onPathChanged: armPath()

    Component.onCompleted: {
        armPath();
    }
}
