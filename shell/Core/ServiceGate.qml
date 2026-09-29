pragma Singleton
import QtQuick
import QtQuick.Window
import Quickshell

// When the service host may build services: once every bar the core built
// for the first applied scan has presented its first frame, so no service
// build delays the first bar (D045). Bars, their widgets and backgrounds
// build in the turn that scan ends; services build on the release, in a
// later turn, and so claim an exclusive capability after every surface
// plugin. The release happens once per shell process and is never taken
// back: a service enabled later, a rescan, a screen change or a bar
// rebuild builds services at once. With no bar built for that scan (no
// screen; the active bar disabled, unknown, refused or broken) it releases
// at once. A bar that never presents, as on a monitor the compositor
// configures no surface for, holds the services for `deadlineMs` at most;
// the release then logs a warning naming the bar hosts that did not
// present.
Singleton {
    id: root

    // Why the services were released: `first-frame`, `no-bar` or
    // `deadline`; "" while they are held. ServiceHost builds on it.
    property string release: ""
    // The bar windows that have presented a frame, until the release.
    property var presented: []
    // When the first judgement found a bar that had not presented, in ms
    // since the epoch; 0 until then.
    property real heldSince: 0
    // Twice the highest waited_ms of the 33 first-bar runs
    // docs/architecture/validation-latency.md names: 179 ms.
    readonly property int deadlineMs: 358

    // The bars the core built, as { hostKey, window }, from its build
    // records; `window` is null until the bar's window exists.
    function bars() {
        const out = [];
        for (const hostKey of Object.keys(Plugins.built))
            for (const row of Plugins.built[hostKey])
                if (row.origin === "core" && row.kind === "bar") out.push({ hostKey: hostKey, window: row.instance.Window.window });
        return out;
    }

    // The host keys of the built bars that have not presented a frame.
    function unpresented(built) {
        return built.filter(bar => bar.window === null || presented.indexOf(bar.window) === -1).map(bar => bar.hostKey);
    }

    // Decide once the bars of the first applied scan are built. It runs
    // after the turn that built them, never inside it: a binding read in
    // that turn can still hold the value from before the scan
    // (docs/architecture/runtime-qml.md).
    function judge() {
        if (release !== "") return;
        // No slot key is set before an applied scan and a ready
        // configuration, so no bar is decided yet.
        if (!Registry.scanned || Config.notReady !== "") return;
        const built = bars();
        if (built.length === 0) { open("no-bar", []); return; }
        if (unpresented(built).length === 0) { open("first-frame", []); return; }
        if (heldSince === 0) {
            heldSince = Date.now();
            deadline.start();
        }
    }

    function open(reason, hosts) {
        deadline.stop();
        const waited = heldSince === 0 ? 0 : Date.now() - heldSince;
        const line = "plugins: services released reason=" + reason + " waited_ms=" + waited;
        if (reason === "deadline") console.warn(line + " unpresented=" + hosts.join(","));
        else console.info(line);
        presented = [];
        release = reason;
    }

    Timer {
        id: deadline
        interval: root.deadlineMs
        onTriggered: root.open("deadline", root.unpresented(root.bars()))
    }

    Connections {
        target: Registry
        function onScanFinished() { Qt.callLater(root.judge); }
    }
    Connections {
        target: Config
        function onNotReadyChanged() { Qt.callLater(root.judge); }
    }
    Connections {
        target: Plugins
        function onBuiltChanged() { if (root.release === "") Qt.callLater(root.judge); }
    }

    // One watcher per bar window until the release. Frames arrive from the
    // render thread, queued to this one, after the turn that built the bar.
    Variants {
        model: root.release !== "" ? [] : root.bars().map(bar => bar.window).filter(window => window !== null)
        Connections {
            required property var modelData
            target: modelData
            function onFrameSwapped() {
                if (root.presented.indexOf(modelData) === -1) root.presented = root.presented.concat([modelData]);
                root.judge();
            }
        }
    }
}
