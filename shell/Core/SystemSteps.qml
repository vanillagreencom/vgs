import QtQuick
import Quickshell
import Quickshell.Io
import "PluginLogic.js" as Logic

// Owns the `system` capability (D081): the states of the core's system
// steps and the one `bin/vgsh-system status --json` that reads them. It
// probes while a plugin holds the capability, once when the first holder
// arrives and again after every `core/system` run the manager opened ends;
// a request while a probe runs starts one more after it, never two at a
// time. PluginLogic.systemReport judges each report, and a run that gives
// none reads every step unknown. `revision` rises when a report changes a
// step's state or reason, so a plugin binds to it.
Scope {
    id: root

    // Whether any plugin holds `system`; Capabilities binds it.
    property bool active: false
    // Every step of PluginLogic.SYSTEM_STEPS as { state, reason }, replaced
    // whole when a report changes it.
    property var steps: Logic.systemUnknown("unprobed")
    property int revision: 0
    property int probes: 0
    property bool again: false

    // The core's bin/ beside the shell directory: the shell's PATH need not
    // hold the core's commands.
    readonly property string coreBin: Quickshell.shellDir + "/../bin"

    onActiveChanged: if (active) probe()

    // `state`: the calling plugin's declared steps, each { state, reason },
    // one frozen copy per read; `revision`: the count of changed reports.
    // Both are bindable.
    function provider(ctx) {
        return {
            get state() {
                const out = Logic.systemStateOf(root.steps, ctx.manifest.systemSteps);
                for (const step of Object.keys(out)) Object.freeze(out[step]);
                return Object.freeze(out);
            },
            get revision() { return root.revision; }
        };
    }

    function probe() {
        if (prober.running) {
            again = true;
            return;
        }
        prober.completion = null;
        prober.running = true;
    }

    // The probe state and the steps, for the lending record.
    function record() {
        return { probing: prober.running, probes: probes, revision: revision, steps: steps };
    }

    // A command that fails to start emits only runningChanged, so the end
    // is read there: no exit recorded is a failed start (runtime-qml.md).
    Process {
        id: prober
        property var completion: null
        command: [root.coreBin + "/vgsh-system", "status", "--json"]
        stdout: StdioCollector { id: probeOutput }
        stderr: StdioCollector { id: probeErrors }
        onExited: (code, status) => { prober.completion = { code: code, status: status }; }
        onRunningChanged: {
            if (running) return;
            const report = Logic.systemReport(prober.completion, probeOutput.text, probeErrors.text);
            if (report.line !== "") console.error(report.line);
            root.probes += 1;
            if (!Logic.systemStepsEqual(root.steps, report.steps)) {
                root.steps = report.steps;
                root.revision += 1;
            }
            if (root.again) {
                root.again = false;
                root.probe();
            }
        }
    }
}
