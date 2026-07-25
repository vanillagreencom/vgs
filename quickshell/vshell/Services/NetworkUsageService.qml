pragma Singleton

pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common

// Per-process network bandwidth, sourced from `bandwhich --raw`. bandwhich needs
// raw-socket capture privileges, so it must carry file capabilities
// (cap_net_raw,cap_net_admin,cap_dac_read_search,cap_sys_ptrace) — apply them with
// `vshell net-usage setup`. The capture process only runs while a consumer holds a
// ref (i.e. the flyout is open), so nothing is captured in the background.
Singleton {
    id: root

    // Consumers call addRef()/removeRef(); capture runs only while refCount > 0.
    property int refCount: 0
    // bandwhich binary is on PATH.
    property bool available: false
    // Present but cannot capture (missing capabilities) — the flyout shows setup help.
    property bool needsSetup: false
    // Actively receiving capture data.
    property bool active: false
    // Capture just started and no output has arrived yet — the flyout shows a
    // spinner instead of an empty state during the ~1-2s bandwhich warm-up.
    property bool warmingUp: false

    // Aggregated per app: [{ name, up, down, connections }] (bytes/sec, up=tx, down=rx).
    property var apps: []
    property real totalUp: 0
    property real totalDown: 0

    // Sort state for the list view (same shape as DgopService's process sort).
    property string sortBy: "down" // "down" | "up" | "name" | "connections"
    property bool sortAscending: false

    // Lines accumulated for the snapshot currently being read; committed when the
    // frame id changes (a new snapshot begins).
    property var _pending: []
    property string _currentFrame: ""

    function addRef() {
        refCount = refCount + 1;
        if (refCount === 1) {
            // Re-probe capability on each fresh open (the user may have just run setup).
            needsSetup = false;
        }
    }

    function removeRef() {
        refCount = Math.max(0, refCount - 1);
    }

    function toggleSort(column) {
        if (column === sortBy) {
            sortAscending = !sortAscending;
        } else {
            sortBy = column;
            sortAscending = false;
        }
    }

    function _handleLine(line) {
        const m = line.match(/^process: <(\d+)> "([^"]*)" up\/down Bps: (\d+)\/(\d+) connections: (\d+)/);
        if (!m) {
            // "Refreshing:" delimiter lines are not reliably delivered as their own
            // segments, so snapshot boundaries are detected from the frame id below.
            // A "<NO TRAFFIC>" frame carries no data lines; flush the previous
            // snapshot so a quiet moment clears the list.
            if (line.indexOf("<NO TRAFFIC>") === 0) {
                _commit();
                _pending = [];
                _currentFrame = "";
            }
            return;
        }

        // Reaching a parseable data line means capture is working.
        if (needsSetup) {
            needsSetup = false;
        }
        active = true;
        // Clear the list if data stops arriving (delimiter lines that signal an idle
        // frame are not reliably delivered, so don't depend on them alone).
        idleTimer.restart();

        // Each line of a snapshot shares the same frame id; a changed id means a new
        // snapshot began, so commit the completed one first.
        const frame = m[1];
        if (frame !== _currentFrame) {
            _commit();
            _pending = [];
            _currentFrame = frame;
        }

        // Reassign rather than push(): a QML `property var` array getter can return
        // a copy, so an in-place push() mutates a throwaway and the stored array
        // stays empty. concat() + reassignment persists the accumulation.
        _pending = _pending.concat([{
            "name": m[2] && m[2].length ? m[2] : "unknown",
            "up": parseInt(m[3], 10),
            "down": parseInt(m[4], 10),
            "connections": parseInt(m[5], 10)
        }]);
    }

    // Aggregate the just-completed snapshot by app name. bandwhich emits one line
    // per process instance; several instances of the same app are merged so the
    // flyout reads as "which apps are sending/receiving".
    function _commit() {
        if (!active && _pending.length === 0) {
            return;
        }
        const byName = {};
        let tu = 0;
        let td = 0;
        for (let i = 0; i < _pending.length; i++) {
            const p = _pending[i];
            let bucket = byName[p.name];
            if (!bucket) {
                bucket = {
                    "name": p.name,
                    "up": 0,
                    "down": 0,
                    "connections": 0
                };
                byName[p.name] = bucket;
            }
            bucket.up += p.up;
            bucket.down += p.down;
            bucket.connections += p.connections;
            tu += p.up;
            td += p.down;
        }
        const list = [];
        for (const key in byName) {
            list.push(byName[key]);
        }
        apps = list;
        totalUp = tu;
        totalDown = td;

        // Keep the spinner up until real results land (the first non-empty
        // snapshot), rather than dropping it the instant bandwhich prints its
        // first "<NO TRAFFIC>" line — that early gap is what read as "broken".
        if (list.length > 0 && warmingUp) {
            warmingUp = false;
            warmupTimer.stop();
        }
    }

    Timer {
        id: idleTimer
        interval: 4000
        repeat: false
        onTriggered: {
            root.apps = [];
            root.totalUp = 0;
            root.totalDown = 0;
            root._pending = [];
            root._currentFrame = "";
        }
    }

    // Safety net so the spinner never sticks if bandwhich produces no parseable
    // output (e.g. a completely idle link) — drop out of warm-up after a grace period.
    Timer {
        id: warmupTimer
        interval: 4000
        repeat: false
        onTriggered: root.warmingUp = false
    }

    Component.onCompleted: availabilityCheck.running = true

    Process {
        id: availabilityCheck
        command: ["sh", "-c", "command -v bandwhich"]
        running: false
        onExited: exitCode => {
            root.available = exitCode === 0 && Quickshell.env("VGS_DISABLE_BANDWHICH") !== "1";
        }
    }

    Process {
        id: captureProcess

        // Stop once setup is known to be missing so a failing binary is not
        // respawned in a tight loop; addRef() clears needsSetup on the next open.
        running: root.available && root.refCount > 0 && !root.needsSetup
        command: ["bandwhich", "--raw", "--processes", "--no-resolve"]

        onRunningChanged: {
            if (running) {
                root.warmingUp = true;
                warmupTimer.restart();
            } else {
                root.apps = [];
                root.totalUp = 0;
                root.totalDown = 0;
                root.active = false;
                root.warmingUp = false;
                warmupTimer.stop();
                root._pending = [];
                root._currentFrame = "";
            }
        }

        onExited: (exitCode, exitStatus) => {
            // A non-zero exit while we still want data almost always means the
            // capability grant is missing; surface the setup path.
            if (root.refCount > 0 && exitCode !== 0 && !root.active) {
                root.needsSetup = true;
            }
        }

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: line => root._handleLine(line)
        }

        stderr: SplitParser {
            splitMarker: "\n"
            onRead: line => {
                if (line.indexOf("Insufficient permissions") !== -1 || line.indexOf("permission") !== -1) {
                    root.needsSetup = true;
                }
            }
        }
    }
}
