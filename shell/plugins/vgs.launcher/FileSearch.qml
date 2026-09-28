import QtQuick
import Quickshell
import Quickshell.Io
import "MenuModel.js" as MenuModel

// The launcher's file and folder search, backed by file-search.sh from this
// plugin's published revision. Every helper run is a child Process owned
// here, so it dies with the launcher. A request is debounced, and a result
// lands only if it answers the newest request, so fast typing never shows
// stale rows. A helper that fails reports its keyed first line as `error`,
// which the launcher shows; nothing is dropped silently.
Item {
    id: search

    required property var look
    readonly property string script: String(Qt.resolvedUrl("file-search.sh")).replace(/^file:\/\//, "")
    readonly property string home: Quickshell.env("HOME") || ""
    // [{ path, name, dir, mime, mtime }], best match first.
    property var results: []
    // "f" files, "d" folders, "" off.
    property string mode: ""
    property string query: ""
    // The helper's last refusal, or "" after a run that succeeded.
    property string error: ""
    readonly property bool busy: queryProc.running || debounce.running
    property int serial: 0

    function request(nextMode, nextQuery) {
        // Entering a mode refreshes its index; the query runs again when the
        // refresh lands.
        if (nextMode !== mode) refresh(nextMode);
        mode = nextMode;
        query = nextQuery;
        serial += 1;
        if (!query) {
            results = [];
            debounce.stop();
            return;
        }
        debounce.restart();
    }

    function clear() {
        serial += 1;
        queryProc.pending = false;
        debounce.stop();
        mode = "";
        query = "";
        results = [];
        error = "";
    }

    Timer {
        id: debounce
        interval: search.look.motion.debounce
        onTriggered: {
            // A running query is superseded: it is stopped, and the next one
            // starts once it has exited, since a Process ignores a start
            // while it is still stopping.
            if (queryProc.running) {
                queryProc.pending = true;
                queryProc.running = false;
            } else {
                search.startQuery();
            }
        }
    }

    // One refresh at a time; a mode switch during one queues the other.
    function refresh(type) {
        if (type === "") return;
        if (refreshProc.running) {
            refreshProc.queued = type;
            return;
        }
        refreshProc.queued = "";
        refreshProc.completion = null;
        refreshProc.command = ["bash", search.script, "refresh", type];
        refreshProc.running = true;
    }

    // The first line of what the helper wrote on stderr, or its status.
    function failure(text, code) {
        const first = String(text || "").split("\n").find(line => line.indexOf("file-search: ") === 0 && line.indexOf("=") > 0);
        return first !== undefined ? first : "file-search: exit=" + code;
    }

    // Each helper Process records its exit in `completion` and is handled
    // once `running` falls, after its output is read; a helper that never
    // started leaves `completion` null (docs/architecture/runtime-qml.md).
    function outcome(completion, errText) {
        if (completion === null) return "file-search: start=failed";
        if (completion.code !== 0 || completion.status !== 0) return failure(errText, completion.code);
        return "";
    }

    Process {
        id: refreshProc
        property string queued: ""
        property var completion: null
        stderr: StdioCollector { id: refreshErr }
        onExited: (code, status) => { completion = { code: code, status: status }; }
        onRunningChanged: {
            if (running) return;
            const failed = search.outcome(completion, refreshErr.text);
            completion = null;
            if (failed !== "") {
                search.error = failed;
                console.warn("launcher: " + failed);
            }
            if (queued) search.refresh(queued);
            else if (search.query) search.request(search.mode, search.query);
        }
    }

    function startQuery() {
        queryProc.pending = false;
        queryProc.completion = null;
        queryProc.requestSerial = search.serial;
        queryProc.command = ["bash", search.script, "query", search.mode, search.query];
        queryProc.running = true;
    }

    Process {
        id: queryProc
        property int requestSerial: 0
        property bool pending: false
        property var completion: null
        stdout: StdioCollector { id: queryOut }
        stderr: StdioCollector { id: queryErr }
        onExited: (code, status) => { completion = { code: code, status: status }; }
        onRunningChanged: {
            if (running) return;
            if (pending) {
                if (search.query) search.startQuery();
                return;
            }
            if (requestSerial !== search.serial) return;
            const failed = search.outcome(completion, queryErr.text);
            if (failed !== "") {
                search.error = failed;
                console.warn("launcher: " + failed);
                search.results = [];
                return;
            }
            const parsed = MenuModel.parseFileResults(queryOut.text, search.home);
            if (parsed.malformed > 0) console.error("launcher: file-search: malformed=" + parsed.malformed);
            search.error = "";
            search.results = parsed.rows;
        }
    }

    // Theme icon for a MIME type: exact, then the family's generic icon.
    function iconFor(mime) {
        if (mime === "inode/directory") return Quickshell.iconPath("folder", true) || Quickshell.iconPath("inode-directory", true);
        const exact = Quickshell.iconPath(mime.replace("/", "-"), true);
        if (exact) return exact;
        return Quickshell.iconPath(mime.split("/")[0] + "-x-generic", true) || Quickshell.iconPath("text-x-generic", true);
    }

    // The applications that open `path`, default first, handed to `done`
    // once as [{ desktopFile, name, icon, isDefault }]. A newer call
    // supersedes an older one, whose `done` never runs; a helper failure
    // hands `done` an empty list and sets `error`.
    function loadApps(path, done) {
        appsProc.serial += 1;
        appsProc.nextDone = done;
        appsProc.nextCommand = ["bash", search.script, "apps", path];
        if (appsProc.running) appsProc.running = false;
        else appsProc.start();
    }

    Process {
        id: appsProc
        property var done: null
        property var nextCommand: null
        property var nextDone: null
        property int serial: 0
        property int runSerial: 0
        property var completion: null
        function start() {
            completion = null;
            done = nextDone;
            runSerial = serial;
            command = nextCommand;
            nextCommand = null;
            running = true;
        }
        stdout: StdioCollector { id: appsOut }
        stderr: StdioCollector { id: appsErr }
        onExited: (code, status) => { completion = { code: code, status: status }; }
        onRunningChanged: {
            if (running) return;
            if (nextCommand) {
                start();
                return;
            }
            if (runSerial !== serial) return;
            const finish = done;
            done = null;
            const failed = search.outcome(completion, appsErr.text);
            if (failed !== "") {
                search.error = failed;
                console.warn("launcher: " + failed);
                if (finish) finish([]);
                return;
            }
            const apps = MenuModel.parseOpenWith(appsOut.text).map(app => {
                const entry = DesktopEntries.byId(app.id);
                return { desktopFile: app.desktopFile, name: entry ? entry.name : app.id, icon: entry && entry.icon ? Quickshell.iconPath(entry.icon, true) : "", isDefault: app.isDefault };
            });
            if (finish) finish(apps);
        }
    }
}
