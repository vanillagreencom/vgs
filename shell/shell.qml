//@ pragma UseQApplication
//@ pragma AppId org.vgs.shell
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Core
import qs.Hosts

// The v2 shell root. Draws only when started by the runner that holds the
// instance lock: the runner's child exports its own process id and execs
// qs in the same process, so a second qs started by hand carries a stale
// value and refuses. Everything visible lives in a host, and every host
// draws a plugin. An unguarded
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
            SummonHost { kind: "window" }
        }
    }

    LazyLoader {
        active: root.guarded
        ToastHost {}
    }

    LazyLoader {
        active: root.guarded
        NoticeHost {}
    }

    LazyLoader {
        active: root.guarded
        LayerHost {}
    }

    // Every scan ends with a follow of the applied theme package, which
    // writes the theme and application files: the guarded instance alone
    // asks for it. An unguarded one names no Registry here, so a read-only
    // call is all that starts its scan.
    Connections {
        target: root.guarded ? Registry : null
        function onScanFinished() { Capabilities.themes.follow(); }
    }

    // The Hyprland layer's one writer, in the runner's shell alone.
    LazyLoader {
        id: hyprland
        active: root.guarded
        HyprlandLayer {}
    }

    IpcHandler {
        target: "shell"

        function ping(): string { return "ok"; }
        function guarded(): bool { return root.guarded; }
        function locked(): bool { return Capabilities.sessionLock.lockRequested; }
        function listPlugins(): string { return Registry.listJson(); }
        function listShellConfig(): string { return JSON.stringify(Config.effective); }
        function built(): string { return Plugins.builtJson(); }
        function lent(): string { return Capabilities.lentJson(); }
        function reloadConfig(): string { return root.ifGuarded(() => { Config.reload(); return "ok"; }); }
        function rescanPlugins(): string { return root.ifGuarded(() => Registry.rescan()); }
        // `vgsh plugin add` landed plugin `id`: the same scan, then the
        // requirement notice for it (requirement-notice.md).
        function pluginInstalled(id: string): string { return root.ifGuarded(() => Notices.installed(id)); }
        function setPluginEnabled(id: string, enabled: bool): string { return root.ifGuarded(() => Plugins.setEnabled(id, enabled)); }
        function setPluginPlaced(id: string, placed: bool): string { return root.ifGuarded(() => Plugins.setPlaced(id, placed)); }
        function summon(kind: string, id: string, payloadJson: string): string { return root.ifGuarded(() => Plugins.route("summon", kind, id, payloadJson, null)); }
        function hide(kind: string, id: string): string { return root.ifGuarded(() => Plugins.route("hide", kind, id, "", null)); }
        function toggle(kind: string, id: string, payloadJson: string): string { return root.ifGuarded(() => Plugins.route("toggle", kind, id, payloadJson, null)); }
        function listTuis(): string { return JSON.stringify(Capabilities.tuis.entries); }
        function openTui(key: string): string { return root.ifGuarded(() => Capabilities.tuis.open(key)); }
        function renderHyprland(): string { return root.ifGuarded(() => hyprland.item === null ? "refused: hyprland=pending" : hyprland.item.render()); }
    }
}
