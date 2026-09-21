//@ pragma UseQApplication
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Core
import qs.Hosts

// The v2 shell root. Draws only when started by the runner that holds the
// instance lock: the runner exports its own process id and execs qs, so a
// second qs started by hand carries a stale value and refuses. Everything
// visible lives in a host, and every host draws a plugin.
ShellRoot {
    id: root

    readonly property bool guarded: Quickshell.env("VGSH_RUNNER_PID") === String(Quickshell.processId)

    Component.onCompleted: {
        if (!guarded)
            console.error("shell: refusing to draw; start it with `vgsh run`, VGSH_RUNNER_PID=" + JSON.stringify(Quickshell.env("VGSH_RUNNER_PID")) + " pid=" + Quickshell.processId);
    }

    Variants {
        id: barHosts
        model: root.guarded ? Quickshell.screens : []
        BarHost {}
    }

    // Widget ids each bar currently hosts, keyed by screen name. The smoke
    // reads this to prove the bar and its widgets were built.
    function barWidgets() {
        const out = {};
        for (const host of barHosts.instances)
            out[host.screen.name] = host.instance === null ? [] : host.instance.widgetIds();
        return out;
    }

    IpcHandler {
        target: "shell"

        function ping(): string { return "ok"; }
        function listPlugins(): string { return Plugins.listJson(); }
        function listShellConfig(): string { return JSON.stringify(Config.effective); }
        function reloadConfig(): string { Config.reload(); return "ok"; }
        function rescanPlugins(): string { Plugins.rescan(); return "ok"; }
        function setPluginEnabled(id: string, enabled: bool): string { return Plugins.setEnabled(id, enabled); }
        function guarded(): bool { return root.guarded; }
        function barWidgets(): string { return JSON.stringify(root.barWidgets()); }
    }
}
