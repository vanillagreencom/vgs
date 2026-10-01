import QtQuick
import Quickshell
import Quickshell.Io
import "BluetoothAgentModel.js" as Model

// Owns the `bluetoothAgent` capability (D085): BlueZ's default pairing
// agent, as one `bluetoothctl --agent KeyboardDisplay` child that runs
// while a holder keeps a lease. BluetoothAgentModel.js makes every
// decision; this scope runs its effects on the child and the one timer, and
// hands it the child's output, its end and the timer as events. The child
// is resolved on the shell's PATH.
Scope {
    id: root

    // Replaced whole on every event, so each getter below that reads it is
    // bindable.
    property var model: Model.initial()

    function apply(step) {
        model = step.model;
        for (const effect of step.effects) run(effect);
        return step;
    }

    function run(effect) {
        switch (effect.kind) {
        case "start":
            agent.completion = null;
            agent.stdinEnabled = true;
            agent.running = true;
            return;
        // The model writes only after the child printed, so it has started
        // (runtime-qml.md).
        case "write":
            agent.write(effect.line + "\n");
            return;
        case "close-stdin":
            agent.stdinEnabled = false;
            return;
        case "stop":
            agent.signal(9);
            return;
        case "timer":
            if (effect.ms === 0) {
                wait.stop();
            } else {
                wait.interval = effect.ms;
                wait.restart();
            }
            return;
        case "resolve":
            Qt.callLater(() => root.apply(Model.resolve(root.model, effect.lease)));
            return;
        case "log":
            console.warn(effect.line);
            return;
        }
        throw new Error("bluetoothAgent: effect kind " + JSON.stringify(effect.kind) + " is unknown");
    }

    // `ready`: the agent is BlueZ's default; `requests`: the open prompts and
    // shown codes as { id, kind, code, service, entered }, a frozen copy per
    // read. Both are bindable.
    function provider(ctx) {
        return {
            begin: reason => root.begin(ctx, reason),
            get ready() { return Model.ready(root.model); },
            get requests() { return Object.freeze(root.model.requests.map(r => Object.freeze(Object.assign({}, r)))); },
            answer: (id, value) => root.apply(Model.answer(root.model, id, value)).answer
        };
    }

    // begin: a lease on the agent for REASON, released by `release()` or
    // with the calling instance. Its `state` reads `pending`, `ready`,
    // `refused` or `released`, and `refusal` the refusal of a refused lease;
    // both are bindable.
    function begin(ctx, reason) {
        const id = apply(Model.begin(model, reason)).lease;
        const release = ctx.onDispose(() => root.apply(Model.release(root.model, id)));
        return Object.freeze({
            release: () => release(),
            get state() { return Model.leaseOf(root.model, id).state; },
            get refusal() { return Model.leaseOf(root.model, id).refusal; }
        });
    }

    function record() {
        return Model.record(model);
    }

    Timer {
        id: wait
        onTriggered: root.apply(Model.timeout(root.model))
    }

    // A child that fails to start emits only runningChanged, so the end is
    // read there: no exit recorded is a failed start (runtime-qml.md).
    Process {
        id: agent
        property var completion: null
        command: ["bluetoothctl", "--agent", "KeyboardDisplay"]
        // readline counts the colour codes inside an agent prompt as visible
        // (src/shared/shell.c:1624-1629 marks only the outer ones), so a
        // service prompt passes 80 columns: under TERM dumb or unset it is
        // never drawn, and under an xterm TERM it wraps. A wide fixed screen
        // draws every prompt whole (bluetooth-agent.md § The child).
        environment: ({ COLUMNS: "1000", TERM: "dumb" })
        stdout: SplitParser {
            splitMarker: ""
            onRead: data => root.apply(Model.output(root.model, data))
        }
        stderr: StdioCollector { id: agentErrors }
        onExited: code => { completion = code; }
        onRunningChanged: {
            if (running) return;
            const code = completion;
            completion = null;
            const first = agentErrors.text.split("\n").find(line => line.trim() !== "");
            root.apply(Model.exited(root.model, code, first === undefined ? "" : first.trim()));
        }
    }
}
