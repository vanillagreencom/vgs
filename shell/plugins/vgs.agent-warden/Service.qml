import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "WardenLogic.js" as WardenLogic

// The Agent Warden service: the one reader of the warden's status file,
// $XDG_RUNTIME_DIR/agent-warden/status.json, which vsys's warden replaces
// every tick. It derives the consumer state through WardenLogic.js and
// publishes it as plugin status (manifest `status`, D037), which the
// plugin's other instances and its Settings page read. It never runs,
// starts or changes the warden.
//   vgsh ipc call vgs.agent-warden invoke status
//     the published values as one JSON line
//
// The derivation runs again when a file changes and on every tick of the
// shared minute clock, so a status the warden stopped rewriting reads as
// stale between 90 and 150 s after its time.
Item {
    id: root

    // The core assigns the plugin's scoped shell object after creation.
    property var shell: null
    // The shell this service registered with, so a new object handed over
    // registers nothing twice.
    property var registeredWith: null

    readonly property string dir: Quickshell.env("XDG_RUNTIME_DIR") + "/agent-warden"
    // The last read of status.json: WardenLogic.readStatus's answer, or
    // { kind: "absent" }, or { kind: "pending" } before the first read.
    property var status: ({ kind: "pending" })
    // Whether state.json exists, read only while status.json is absent:
    // "pending", "present" or "absent".
    property string legacy: "pending"
    // The derived state, WardenLogic.derive's answer; null while a read is
    // pending. Time.now is the dependency that re-derives it each minute;
    // the moment itself is read to the millisecond.
    readonly property var detail: {
        Time.now;
        return WardenLogic.derive(WardenLogic.fileOf(status, legacy), Date.now());
    }
    // The plugin's requirement commands the last scan did not find; its
    // change publishes again. publish() reads the source itself, since a
    // dependent binding may still hold its old value in a change handler
    // (docs/architecture/runtime-qml.md).
    readonly property var missing: shell === null ? null : shell.requirements.missing

    onShellChanged: {
        if (shell === null) return;
        if (registeredWith === null) {
            registeredWith = shell;
            shell.ipc.handle("status", () => JSON.stringify(root.shell.status.values));
        }
        publish();
    }
    onDetailChanged: publish()
    onMissingChanged: publish()

    // Publish each value that differs from the one the core holds. A
    // refusal means a value this plugin declares did not fit its own
    // declaration, which WardenLogic.published rules out.
    function publish() {
        if (shell === null || detail === null) return;
        const values = WardenLogic.published(detail, shell.requirements.missing);
        const held = shell.status.values;
        for (const key of Object.keys(values)) {
            if (JSON.stringify(held[key]) === JSON.stringify(values[key])) continue;
            const reply = shell.status.set(key, values[key]);
            if (reply !== "ok") console.error("agent-warden: publish=" + key + " " + reply);
        }
    }

    // A status that cannot be read is logged once per cause; the published
    // state already says so.
    function readStatus(next) {
        if (next.kind !== "read" && JSON.stringify(next) !== JSON.stringify(status))
            console.warn("agent-warden: status=" + next.kind + " " + (next.kind === "schema" ? "schema=" + next.schema : "cause=" + next.cause) + " path=" + dir + "/status.json");
        status = next;
    }

    // A watcher adds only a directory that exists when it is built
    // (docs/architecture/runtime-qml.md), so the warden's directory is made
    // before the watches start: a warden set up while the shell runs is
    // then seen. A directory that could not be made is logged and the
    // watches start anyway, reading both files as absent.
    Process {
        id: dirProc
        property var completion: null
        property bool settled: false
        command: ["mkdir", "-p", "--", root.dir]
        running: true
        stderr: StdioCollector { id: dirErr }
        onExited: (code, status) => { completion = { code: code, status: status }; }
        onRunningChanged: {
            if (running) return;
            if (completion === null || completion.code !== 0 || completion.status !== 0)
                console.error("agent-warden: directory failed: dir=" + root.dir + " " + JSON.stringify(completion) + "\n" + dirErr.text.trim());
            settled = true;
        }
    }

    LazyLoader {
        active: dirProc.settled
        WatchedFile {
            path: root.dir + "/status.json"
            onChanged: read()
            onLoaded: content => root.readStatus(WardenLogic.readStatus(content))
            onLoadFailed: error => root.readStatus(error === FileViewError.FileNotFound ? { kind: "absent" } : { kind: "unreadable", cause: "read=" + FileViewError.toString(error) })
        }
    }

    // An older warden writes state.json and no status.json. Its content is
    // never read, only whether it exists; a state.json that exists and
    // cannot be read still exists.
    LazyLoader {
        active: dirProc.settled && root.status.kind === "absent"
        onActiveChanged: root.legacy = "pending"
        WatchedFile {
            path: root.dir + "/state.json"
            onChanged: read()
            onLoaded: content => { root.legacy = "present"; }
            onLoadFailed: error => { root.legacy = error === FileViewError.FileNotFound ? "absent" : "present"; }
        }
    }
}
