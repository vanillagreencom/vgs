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
        function reloadConfig(): string { if (!root.guarded) return root.guardRefusal; Config.reload(); return "ok"; }
        function rescanPlugins(): string { return root.guarded ? Plugins.rescan() : root.guardRefusal; }
        function setPluginEnabled(id: string, enabled: bool): string { return root.guarded ? Plugins.setEnabled(id, enabled) : root.guardRefusal; }
        function summon(kind: string, id: string, payloadJson: string): string { return root.guarded ? Plugins.route("summon", kind, id, payloadJson) : root.guardRefusal; }
        function hide(kind: string, id: string): string { return root.guarded ? Plugins.route("hide", kind, id, "") : root.guardRefusal; }
        function toggle(kind: string, id: string, payloadJson: string): string { return root.guarded ? Plugins.route("toggle", kind, id, payloadJson) : root.guardRefusal; }
    }
}
