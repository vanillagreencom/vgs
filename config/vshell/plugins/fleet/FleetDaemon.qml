import QtQuick
import Quickshell
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
    readonly property string binDir: (Quickshell.env("HOME") || "") + "/.local/bin"

    // Null until the first read settles, then one decoded read, replaced whole,
    // so every bar and the popout render the same answer.
    property var result: null
    // When `result` settled. The views measure ages against it, so an age moves
    // with each poll and no view needs a clock of its own.
    property real fetchedAt: 0
    // Command name to true for each fleet command found executable. Null until
    // the first probe answers.
    property var available: null
    // True from a refresh's probe until its read settles, so a poll or a manual
    // refresh never starts a second read over one in flight. Proc's timeout
    // settles a command that hangs, so a refresh always ends.
    property bool busy: false

    // Probe the commands first, so a missing status command is reported by
    // name and an action button knows whether it can run.
    function refresh() {
        if (root.busy)
            return;
        root.busy = true;
        const probe = ["sh", "-c", "dir=$1; shift; for c in \"$@\"; do if [ -x \"$dir/$c\" ]; then printf '%s\\n' \"$c\"; fi; done",
            "fleet-probe", root.binDir].concat(Logic.fleetCommands());
        Proc.runCommand("fleet-probe", probe, (output, exitCode) => {
            const probed = Logic.decodeProbe(exitCode, output);
            if (!probed.ok) {
                root.settle(probed);
                return;
            }
            root.available = probed.available;
            const read = Logic.statusRead(root.available, root.binDir);
            if (!read.ok) {
                root.settle(read);
                return;
            }
            Proc.runCommand("fleet-status", read.argv, (out, code, err) => root.settle(Logic.decodeStatus(code, out, err)), 0);
        }, 0);
    }

    function settle(result) {
        root.result = result;
        root.fetchedAt = Date.now();
        root.busy = false;
        if (!result.ok)
            console.warn("fleet: " + result.error);
    }

    // Why an action cannot run, or "" when it can. The views show it; run is
    // the one place a click is refused.
    function actionProblem(action) {
        return Logic.commandProblem(Logic.actionCommand(action), root.available);
    }

    // Answers whether the action started, so a view changes what it shows only
    // for an action that did.
    function run(action, row) {
        const problem = root.actionProblem(action);
        if (problem !== "") {
            ToastService.showWarning("Fleet action unavailable", problem);
            return false;
        }
        Quickshell.execDetached(Logic.actionArgv(action, row, Paths.vshellCli, root.binDir));
        return true;
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
