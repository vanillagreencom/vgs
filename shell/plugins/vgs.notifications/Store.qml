import QtQuick
import Quickshell
import Quickshell.Io
import "NotificationLogic.js" as Logic

// The notifications' persistent state: Silence, the last Mark read, the
// toasts on screen and the history, in one file under the XDG state
// directory, and the image copies the stored entries own beside it. The
// file is read once when the store is built and written whole at the end of
// the event-loop turn that changed it, so a rebuilt service, whose new
// store reads the file in a later turn, finds every change. A file the
// judge refuses or the store cannot read is never overwritten: the store
// keeps working in memory, says why in `problem`, and writes again only
// after `reset`, which the user asks for by clearing the history. A failed
// write is reported the same way and tried again with the next change.
// Image copies and sweeps run one at a time through images.sh, so a sweep
// never removes a copy still being written.
Item {
    id: store

    readonly property string dir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/vgs/notifications"
    readonly property string path: dir + "/state.json"
    readonly property string imagesDir: dir + "/images"
    readonly property string script: String(Qt.resolvedUrl("images.sh")).replace(/^file:\/\//, "")

    // pending, loaded, absent, corrupt or unreadable.
    property string status: "pending"
    readonly property bool ready: status !== "pending"
    readonly property bool writable: status === "loaded" || status === "absent"
    // The keyed line naming why the file is not read or written, or "".
    property string problem: ""
    property bool dnd: false
    property real readBefore: 0
    // The toasts on screen and the history, as the file stores them: newest
    // first, image values pointing at the copies.
    property var live: []
    property var history: []

    // How many helper runs may wait; a copy past it is dropped and logged,
    // and the card falls back to the application icon.
    readonly property int queueMax: 64
    // { argv, done } helper runs waiting, the one running, and whether a
    // sweep waits already.
    property var queue: []
    property var running: null
    property bool sweepQueued: false
    // The directories exist; until then a write waits, and when they could
    // not be made every write is held and `problem` says so.
    property bool prepared: false
    property bool dirty: false
    property bool flushQueued: false

    function hasKey(key) {
        return live.some(e => e.key === key) || history.some(e => e.key === key);
    }

    function read(text) {
        const judged = Logic.parseState(text);
        if (!judged.ok) {
            refuse("corrupt", "notifications: state refused: file=" + path + " reason=" + judged.error);
            return;
        }
        dnd = judged.state.dnd;
        readBefore = judged.state.readBefore;
        live = judged.state.live;
        history = judged.state.history;
        status = "loaded";
    }

    function refuse(state, line) {
        console.error(line);
        problem = line;
        status = state;
    }

    FileView {
        id: file
        path: store.path
        watchChanges: false
        atomicWrites: true
        blockWrites: true
        printErrors: false
        onLoaded: store.read(text())
        onLoadFailed: error => {
            if (error === FileViewError.FileNotFound) store.status = "absent";
            else store.refuse("unreadable", "notifications: state unreadable: file=" + store.path + " error=" + error);
        }
        onSaved: {
            store.problem = "";
            store.status = "loaded";
        }
        onSaveFailed: error => {
            store.problem = "notifications: state not written: file=" + store.path + " error=" + error;
            console.error(store.problem);
        }
    }

    // Every change calls this; one write follows at the end of the turn,
    // once the directory exists.
    function changed() {
        dirty = true;
        if (flushQueued) return;
        flushQueued = true;
        Qt.callLater(flush);
    }

    function flush() {
        flushQueued = false;
        if (!dirty || !prepared) return;
        if (!writable) {
            console.warn("notifications: state held in memory: file=" + path + " state=" + status);
            return;
        }
        dirty = false;
        file.setText(Logic.serializeState({ dnd: dnd, readBefore: readBefore, live: live, history: history }));
        sweep();
    }

    // Start over after the user cleared a file the store could not use.
    function reset() {
        if (writable) return;
        console.warn("notifications: state reset by the user: file=" + path + " was " + status);
        problem = "";
        status = "absent";
        changed();
    }

    function setDnd(value) {
        if (dnd === value) return;
        dnd = value;
        changed();
    }

    function setReadBefore(value) {
        readBefore = value;
        changed();
    }

    // Store one toast on screen, replacing the one with its key.
    function putLive(entry) {
        const at = live.findIndex(e => e.key === entry.key);
        live = at === -1 ? [entry].concat(live) : live.slice(0, at).concat([entry], live.slice(at + 1));
        changed();
    }

    // Record a toast's clock, as NotificationLogic.clockFields gives it, on
    // its stored entry; a clock that did not move writes nothing.
    function setClock(key, fields) {
        const at = live.findIndex(e => e.key === key);
        if (at === -1) return;
        const current = live[at];
        if (current.deadline === fields.deadline && current.remaining === fields.remaining) return;
        const next = {};
        for (const role of Logic.ENTRY_ROLES) next[role] = current[role];
        live = live.slice(0, at).concat([Object.assign(next, fields)], live.slice(at + 1));
        changed();
    }

    // Take one toast off the screen; into the history unless `forget`.
    function dropLive(key, forget) {
        const entry = live.find(e => e.key === key);
        if (entry === undefined) return;
        live = live.filter(e => e.key !== key);
        if (!forget) history = Logic.pushHistory(history, [entry]).history;
        changed();
    }

    function archive(entries) {
        if (entries.length === 0) return;
        history = Logic.pushHistory(history, entries).history;
        changed();
    }

    function clearHistory() {
        reset();
        history = [];
        changed();
    }

    function dropHistory(key) {
        const next = history.filter(e => e.key !== key);
        if (next.length === history.length) return;
        history = next;
        changed();
    }

    // A copy the helper could not make leaves its entries without that
    // image, so a card drawn from the store falls back to the application
    // icon instead of pointing at nothing.
    function forgetImages(urls) {
        const strip = e => {
            let out = e;
            for (const role of Logic.IMAGE_ROLES)
                if (urls.indexOf(e[role]) !== -1) {
                    out = Object.assign({}, out);
                    out[role] = "";
                }
            return out;
        };
        live = live.map(strip);
        history = history.map(strip);
        changed();
    }

    // Copy a sender's images to where the stored entry points; `done` runs
    // once they are made or skipped, or at once when there are none.
    function copy(copies, done) {
        if (copies.length === 0) {
            if (done) done();
            return;
        }
        const argv = ["bash", script, "copy", imagesDir];
        for (const c of copies) argv.push(c.from, c.to);
        enqueue({ argv: argv, done: done || null });
    }

    // Remove every image no stored entry owns. One sweep waits at a time; it
    // reads what the entries own when it starts.
    function sweep() {
        if (sweepQueued) return;
        sweepQueued = true;
        enqueue({ argv: null, done: null });
    }

    function enqueue(job) {
        if (queue.length >= queueMax) {
            console.warn("notifications: image job dropped: queue=full limit=" + queueMax);
            if (job.done) job.done();
            return;
        }
        queue = queue.concat([job]);
        next();
    }

    function next() {
        if (running !== null || queue.length === 0) return;
        const job = queue[0];
        queue = queue.slice(1);
        if (job.argv === null) {
            sweepQueued = false;
            job.argv = ["bash", script, "sweep", imagesDir].concat(Logic.ownedImages(live.concat(history)));
        }
        running = job;
        helper.completion = null;
        helper.command = job.argv;
        helper.running = true;
    }

    Process {
        id: helper
        property var completion: null
        stdout: StdioCollector { id: helperOut }
        stderr: StdioCollector { id: helperErr }
        onExited: (code, status) => { completion = { code: code, status: status }; }
        onRunningChanged: {
            if (running) return;
            const job = store.running;
            store.running = null;
            const done = completion;
            completion = null;
            if (done === null || done.code !== 0) {
                const first = String(helperErr.text || "").split("\n").find(l => l.indexOf("notifications-images: ") === 0);
                console.error(first !== undefined ? first : "notifications-images: " + (done === null ? "start=failed" : "exit=" + done.code) + " verb=" + job.argv[2]);
            }
            const skipped = [];
            for (const line of String(helperOut.text || "").split("\n")) {
                if (line.indexOf("skipped ") !== 0) continue;
                console.info("notifications: image " + line);
                skipped.push("file://" + line.slice(8, line.lastIndexOf(" reason=")));
            }
            if (skipped.length > 0) store.forgetImages(skipped);
            if (job.argv[2] === "prepare") {
                store.prepared = done !== null && done.code === 0;
                if (store.prepared) store.flush();
                else {
                    store.problem = "notifications: state directory not made: dir=" + store.dir;
                    console.error(store.problem);
                }
            }
            if (job.done) {
                try {
                    job.done();
                } catch (e) {
                    console.error("notifications: image job callback failed: " + e.message);
                }
            }
            store.next();
        }
    }

    Component.onCompleted: {
        running = { argv: ["bash", script, "prepare", dir, imagesDir], done: null };
        helper.command = running.argv;
        helper.running = true;
    }

}
