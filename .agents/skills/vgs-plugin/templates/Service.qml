import QtQuick
import Quickshell
import Quickshell.Io

// __NAME__ service: no surface. Every timer, watcher and subprocess lives
// inside this item so unloading the plugin destroys them. A Process gets
// its stdout parser before it starts; one owner per source.
Item {
    id: root

    // The core assigns the plugin's scoped shell object after creation.
    property var shell: null
    property string lastLine: ""

    Process {
        id: probe
        command: ["true"]
        // `exited` precedes `running` turning false, and a command that
        // fails to start emits no `exited`: a run that ends without one did
        // not start, and is logged instead of retried in silence.
        property bool exitedThisRun: false
        stdout: SplitParser {
            onRead: data => root.lastLine = data
        }
        onStarted: exitedThisRun = false
        onExited: (code, status) => {
            exitedThisRun = true;
            if (code !== 0)
                console.error("__ID__: probe exited " + code);
        }
        onRunningChanged: {
            if (!running && !exitedThisRun)
                console.error("__ID__: probe did not start: " + JSON.stringify(command));
        }
    }

    Timer {
        interval: 60000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: if (!probe.running) probe.running = true
    }
}
