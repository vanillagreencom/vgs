import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Modules.Plugins
import qs.Services

import "FleetLogic.js" as Logic

// The one fleet status reader in the shell. Each bar's FleetWidget is a view
// of this instance, so a poll runs the status command once however many
// screens show the pill. The actions live here too: each is one command
// against the one fleet.
PluginDaemonComponent {
    id: root

    readonly property int pollSeconds: Logic.settingNumber(pluginData.pollSeconds, Logic.DEFAULTS.pollSeconds, 10)
    readonly property bool useFixture: Logic.settingBool(pluginData.useFixture, Logic.DEFAULTS.useFixture)
    readonly property string binDir: (Quickshell.env("HOME") || "") + "/.local/bin"
    readonly property string fixturePath: decodeURIComponent(
        String(Qt.resolvedUrl("fleet-status.fixture.json")).replace(/^file:\/\//, ""))

    // Null until the first read settles, then one decoded read, replaced whole,
    // so every bar and the popout render the same answer.
    property var result: null
    // When `result` settled. The views measure ages against it, so an age moves
    // with each poll and no view needs a clock of its own.
    property real fetchedAt: 0
    // Command name to true for each fleet command found executable. Null until
    // the first probe answers.
    property var available: null
    readonly property bool busy: probeProc.running || statusProc.running

    property bool _inFlight: false
    property bool _outDone: false
    property bool _exitDone: false
    property int _exitCode: 0
    property int _exitStatus: 0

    onUseFixtureChanged: {
        if (root.watched)
            root.refresh();
    }

    // Probe the commands first, so a missing status command is reported by
    // name and an action button knows whether it can run.
    function refresh() {
        if (probeProc.running || statusProc.running)
            return;
        probeProc.running = true;
    }

    function readStatus() {
        if (!root.useFixture) {
            const problem = Logic.commandProblem(Logic.STATUS_COMMAND, root.available);
            if (problem !== "") {
                root.settle(Logic.failure(problem));
                return;
            }
        }
        root._outDone = false;
        root._exitDone = false;
        root._exitCode = 0;
        root._exitStatus = 0;
        root._inFlight = true;
        statusProc.running = true;
    }

    function settle(result) {
        root.result = result;
        root.fetchedAt = Date.now();
        if (!result.ok)
            console.warn("fleet: " + result.error);
    }

    // Stdout closing and the exit are not ordered, so the read settles once
    // both have arrived.
    function settleStatus() {
        if (!root._inFlight || !root._outDone || !root._exitDone)
            return;
        root._inFlight = false;
        root.settle(Logic.decodeStatus(root._exitCode, root._exitStatus, statusOut.text, statusErr.text));
    }

    // Answers whether the action started, so a view changes what it shows only
    // for an action that did.
    function run(action, row) {
        const problem = Logic.commandProblem(Logic.actionCommand(action), root.available);
        if (problem !== "") {
            ToastService.showWarning("Fleet action unavailable", problem);
            return false;
        }
        Quickshell.execDetached(Logic.actionArgv(action, row, Paths.vshellCli, root.binDir));
        return true;
    }

    Process {
        id: probeProc
        command: ["sh", "-c", "dir=$1; shift; for c in \"$@\"; do if [ -x \"$dir/$c\" ]; then printf '%s\\n' \"$c\"; fi; done",
            "fleet-probe", root.binDir].concat(Logic.fleetCommands())
        running: false
        stdout: StdioCollector {
            id: probeOut
            onStreamFinished: {
                root.available = Logic.availableCommands(probeOut.text);
                root.readStatus();
            }
        }
    }

    Process {
        id: statusProc
        command: Logic.statusArgv(root.useFixture, root.fixturePath, root.binDir)
        running: false
        stdout: StdioCollector {
            id: statusOut
            onStreamFinished: {
                root._outDone = true;
                root.settleStatus();
            }
        }
        stderr: StdioCollector {
            id: statusErr
        }
        onExited: (exitCode, exitStatus) => {
            root._exitCode = exitCode;
            root._exitStatus = exitStatus;
            root._exitDone = true;
            root.settleStatus();
        }
    }

    Timer {
        id: pollTimer
        interval: root.pollSeconds * 1000
        repeat: true
        // Poll only while a widget watches, so the first watching widget reads
        // at once and a shell with the widget on no bar runs nothing.
        running: root.watched
        triggeredOnStart: true
        onTriggered: root.refresh()
    }
}
