import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "WardenLogic.js" as WardenLogic
import "ViewLogic.js" as ViewLogic
import "Notices.js" as Notices

// The Agent Warden service: the one reader of the warden's status file,
// $XDG_RUNTIME_DIR/agent-warden/status.json, which vsys's warden replaces
// every tick. It derives the consumer state through WardenLogic.js and
// publishes it as plugin status (manifest `status`, D037), which the
// plugin's other instances and its Settings page read. It never runs,
// starts or changes the warden.
//   vgsh ipc call vgs.agent-warden invoke status
//     the published values as one JSON line
//
// The derivation runs again when a file changes and when one timer fires
// at the moment WardenLogic.nextChange names, so a status the warden
// stopped rewriting reads as stale 90 s after its time, and a recent event
// leaves the state when its window ends, with no file change.
//
// It also owns the desktop notices about agents (Notices.js). While it
// reads a status and notify-send is on PATH, it touches the warden's
// heartbeat, $XDG_RUNTIME_DIR/agent-warden/notifier, every 60 s, and the
// warden then sends none of its own. Each derivation steps the episodes it
// remembers and sends each new one once, through one notify-send run, or
// as a toast for a move under `notify: everything`. A press on Open vsys
// opens the plugin's `vsys` TUI. The episodes live as long as the service:
// a service built again, by a shell restart or a new plugin revision,
// sends each episode still open once more.
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
    // pending. derive() alone sets it.
    property var detail: null
    // The plugin's requirement commands the last scan did not find; its
    // change publishes again. publish() reads the source itself, since a
    // dependent binding may still hold its old value in a change handler
    // (docs/architecture/runtime-qml.md).
    readonly property var missing: shell === null ? null : shell.requirements.missing
    // The `notify` setting: which notices go out, one of Notices.MODES.
    readonly property string mode: shell === null ? "" : shell.settings.notify
    // Whether this service owns the notices and touches the heartbeat.
    readonly property bool owns: missing !== null && Notices.owns(status, missing)
    // The keys of the open episodes this service remembers, Notices.step's.
    property var episodes: []
    // The new episodes the last step dropped past Notices.MAX_EPISODES,
    // logged when it changes.
    property int dropped: 0
    // The notify-send runs waiting for a press on Open vsys.
    property int waiting: 0
    // Whether the last heartbeat write failed, logged when it starts.
    property bool heartbeatFailed: false

    onShellChanged: {
        if (shell === null) return;
        if (registeredWith === null) {
            registeredWith = shell;
            shell.ipc.handle("status", () => JSON.stringify(root.shell.status.values));
        }
        derive();
    }
    onStatusChanged: derive()
    onLegacyChanged: derive()
    onMissingChanged: publish()
    // A value the manifest's schema does not offer reaches the service
    // only from a hand-edited file; the service then sends nothing.
    onModeChanged: {
        if (mode !== "" && Notices.MODES.indexOf(mode) === -1)
            console.error("agent-warden: notify=" + JSON.stringify(mode) + " unknown\nThe notify setting takes " + Notices.MODES.join(", ") + "; no notice goes out until it does.");
    }

    // Derive the state from both reads at this moment, publish it, and set
    // the timer to the next moment the answer can change with the files
    // unchanged.
    function derive() {
        const file = WardenLogic.fileOf(status, legacy);
        const now = Date.now();
        detail = WardenLogic.derive(file, now);
        const next = WardenLogic.nextChange(file, now);
        if (next === null) {
            deadline.stop();
        } else {
            // Timer.interval is a 32-bit int: a moment further ahead fires
            // at the ceiling, derives again and sets the timer again.
            deadline.interval = Math.min(next - now, 2147483647);
            deadline.restart();
        }
        publish();
        if (detail !== null) notify(file, now);
    }

    // Step the remembered episodes through FILE at NOW and send each new
    // one the `notify` setting asks for. Memory moves under every setting,
    // so an episode open while notices were off is not sent when they come
    // back on.
    function notify(file, now) {
        if (shell === null) return;
        const result = Notices.step(episodes, Notices.conditionsOf(file, detail, now));
        episodes = result.memory;
        if (result.dropped !== dropped && result.dropped > 0)
            console.error("agent-warden: notices=full dropped=" + result.dropped + " limit=" + Notices.MAX_EPISODES);
        dropped = result.dropped;
        if (Notices.MODES.indexOf(mode) === -1) return;
        const vsys = shell.requirements.missing.indexOf("vsys") === -1;
        for (const notice of Notices.notices(result.opened, mode, vsys, now)) send(notice);
    }

    // One notice: a toast, or one notify-send run that this service owns
    // until it ends. A notice that fails to go out is forgotten, so the
    // next status sends it again.
    function send(notice) {
        if (notice.channel === "toast") {
            try {
                shell.toasts.show(Notices.toast(notice));
            } catch (e) {
                console.error("agent-warden: notice=" + notice.kind + " " + e.message);
                episodes = Notices.forget(episodes, notice.keys);
            }
            return;
        }
        // A list crosses createObject's initial properties as something
        // else (runtime-qml.md), so the run takes its lists after creation.
        const run = sender.createObject(root, { kind: notice.kind, offers: Notices.offers(notice, waiting) });
        run.keys = notice.keys;
        run.command = Notices.argv(notice, waiting);
        if (run.offers) waiting += 1;
        run.running = true;
    }

    // A notify-send run ended: COMPLETION is its exit, null when it did not
    // start; STDOUT the action pressed, STDERR its complaint.
    function sent(run, completion, stdout, stderr) {
        if (run.offers) waiting -= 1;
        if (completion === null || completion.code !== 0 || completion.status !== 0) {
            console.error("agent-warden: notice=" + run.kind + " failed=" + JSON.stringify(completion) + "\n" + stderr.trim());
            episodes = Notices.forget(episodes, run.keys);
        } else if (Notices.pressed(stdout)) {
            const reply = shell.tui.run("vsys");
            if (!ViewLogic.handedOff(reply)) console.error("agent-warden: action=open " + reply);
        }
        Qt.callLater(() => run.destroy());
    }

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
    // state already says so. An absent status is a warden not set up, a
    // normal state, and logs nothing.
    function readStatus(next) {
        if ((next.kind === "unreadable" || next.kind === "schema") && JSON.stringify(next) !== JSON.stringify(status))
            console.warn("agent-warden: status=" + next.kind + " " + (next.kind === "schema" ? "schema=" + next.schema : "cause=" + next.cause) + " path=" + dir + "/status.json");
        status = next;
    }

    Component {
        id: sender
        Process {
            id: run
            property string kind: ""
            property var keys: []
            // Whether the run offers Open vsys and so waits for a press.
            property bool offers: false
            property var completion: null
            stdout: StdioCollector { id: chosen }
            stderr: StdioCollector { id: complaint }
            onExited: (code, status) => { completion = { code: code, status: status }; }
            onRunningChanged: {
                if (!running) root.sent(run, completion, chosen.text, complaint.text);
            }
        }
    }

    // The heartbeat: a write of the time, in milliseconds, which a changed
    // text makes a real write each time (runtime-qml.md, FileView.setText).
    // The warden reads only the file's age. The timer touches it at once
    // when the service starts to own the notices, and a file it stops
    // touching goes stale 120 s after its last write.
    FileView {
        id: heartbeat
        path: root.dir + "/notifier"
        preload: false
        watchChanges: false
        atomicWrites: true
        printErrors: false
        onSaved: root.heartbeatFailed = false
        onSaveFailed: error => {
            if (!root.heartbeatFailed)
                console.error("agent-warden: heartbeat=failed path=" + path + " error=" + FileViewError.toString(error));
            root.heartbeatFailed = true;
        }
    }
    Timer {
        interval: Notices.HEARTBEAT_MS
        repeat: true
        triggeredOnStart: true
        running: root.owns && dirProc.settled
        onTriggered: heartbeat.setText(String(Date.now()) + "\n")
    }

    Timer {
        id: deadline
        repeat: false
        onTriggered: root.derive()
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
