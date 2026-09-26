//@ pragma UseQApplication
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Core
import qs.Hosts

// The v2 shell root. Draws only when started by the runner that holds the
// instance lock: the runner exports its own process id and execs qs, so a
// second qs started by hand carries a stale value and refuses. Everything
// visible lives in a host, and every host draws a plugin. An unguarded
// instance answers read-only calls, so its refusal can be diagnosed, and
// refuses every call that would change state.
ShellRoot {
    id: root

    readonly property bool guarded: Quickshell.env("VGSH_RUNNER_PID") === String(Quickshell.processId)
    readonly property string guardRefusal: "refused: guard=unowned pid=" + Quickshell.processId

    // The reply of a state-changing call: `reply()` from the guarded
    // instance, the guard refusal from any other.
    function ifGuarded(reply) {
        return guarded ? reply() : guardRefusal;
    }

    Component.onCompleted: {
        if (!guarded)
            console.error("shell: refusing to draw; start it with `vgsh run`, VGSH_RUNNER_PID=" + JSON.stringify(Quickshell.env("VGSH_RUNNER_PID")) + " pid=" + Quickshell.processId);
    }

    Variants {
        model: root.guarded ? Quickshell.screens : []
        BarHost {}
    }

    Loader {
        active: root.guarded
        sourceComponent: ServiceHost {}
    }

    LazyLoader {
        active: root.guarded
        LockHost {}
    }

    Variants {
        model: root.guarded ? Quickshell.screens : []
        BackgroundHost {}
    }

    LazyLoader {
        active: root.guarded
        Scope {
            SummonHost { kind: "panel" }
            SummonHost { kind: "overlay" }
            SummonHost { kind: "menu" }
        }
    }

    IpcHandler {
        target: "shell"

        function ping(): string { return "ok"; }
        function guarded(): bool { return root.guarded; }
        function listPlugins(): string { return Plugins.listJson(); }
        function listShellConfig(): string { return JSON.stringify(Config.effective); }
        function built(): string { return Plugins.builtJson(); }
        function buildCount(): int { return Plugins.buildCount; }
        function lent(): string { return Capabilities.lentJson(); }
        function readInstance(hostKey: string, id: string, property: string): string { return Plugins.readInstance(hostKey, id, property); }
        function invokeInstance(hostKey: string, id: string, name: string, arg: string): string { return root.ifGuarded(() => Plugins.invokeInstance(hostKey, id, name, arg)); }
        function reloadConfig(): string { return root.ifGuarded(() => { Config.reload(); return "ok"; }); }
        function rescanPlugins(): string { return root.ifGuarded(() => Plugins.rescan()); }
        function setPluginEnabled(id: string, enabled: bool): string { return root.ifGuarded(() => Plugins.setEnabled(id, enabled)); }
        function summon(kind: string, id: string, payloadJson: string): string { return root.ifGuarded(() => Plugins.route("summon", kind, id, payloadJson, null)); }
        function hide(kind: string, id: string): string { return root.ifGuarded(() => Plugins.route("hide", kind, id, "", null)); }
        function toggle(kind: string, id: string, payloadJson: string): string { return root.ifGuarded(() => Plugins.route("toggle", kind, id, payloadJson, null)); }
    }
}
