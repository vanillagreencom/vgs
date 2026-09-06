pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Common
import qs.Services

Singleton {
    id: root
    readonly property var log: Log.scoped("HyprlandService")

    // VGS is Hyprland-native-Lua only. Dotfiles own static config;
    // VGS generates the color fragment consumed by that config.
    readonly property bool luaConfigActive: true
    property bool layoutXrayEnabled: false
    property bool layoutBarXrayEnabled: false

    property bool _layoutApplyPending: false

    function generateLayoutConfig() {
        layoutApplyTimer.restart();
    }
    property var outputs: ({})
    property bool outputsAvailable: false
    property bool outputsLoading: false
    property string outputsError: ""
    property string outputRecoveryToken: ""
    property string outputPreviewToken: ""

    function requestOutputs() {
        if (outputsLoading || !CompositorService.isHyprland)
            return;
        outputsLoading = true;
        outputsCommand("current", [], result => {
            outputsLoading = false;
            outputsAvailable = result.ok;
            outputsError = result.ok ? result.recoveryError || "" : result.error || I18n.tr("Could not read displays");
            outputRecoveryToken = result.recoveryToken || "";
            if (result.ok)
                outputs = result.outputs;
        });
    }

    function outputsCommand(action, args, callback) {
        Proc.runCommand(null, [Paths.vshellCli, "config", "hyprland-outputs-" + action].concat(args), (output, exitCode, errorOutput) => {
            let result;
            try {
                result = JSON.parse(output);
            } catch (error) {
                result = {ok: false, error: errorOutput || output || I18n.tr("No response from display control")};
            }
            if (exitCode !== 0)
                result.ok = false;
            if (!result.ok)
                ToastService.showError(I18n.tr("Display settings failed"), result.error || errorOutput, "", "display-config");
            callback(result);
        }, 0, 15000);
    }

    function generateOutputsConfig(outputsData, settings, callback, preview = false) {
        const payload = JSON.stringify({outputs: outputsData, settings: settings, displayNameMode: SettingsData.displayNameMode});
        outputsCommand(preview ? "preview" : "write", [payload], result => {
            if (result.ok && preview)
                outputPreviewToken = result.token;
            requestOutputs();
            if (callback)
                callback(result.ok);
        });
    }

    function finishOutputPreview(keep, callback) {
        outputsCommand(keep ? "confirm" : "revert", [outputPreviewToken], result => {
            outputPreviewToken = "";
            requestOutputs();
            callback(result.ok);
        });
    }

    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (["monitoradded", "monitorremoved", "configreloaded"].includes(event.name))
                outputRefreshTimer.restart();
        }
    }

    Timer {
        id: outputRefreshTimer
        interval: 500
        onTriggered: root.requestOutputs()
    }
    function generateCursorConfig() {}
    function setLayoutXray(enabled) { layoutXrayEnabled = !!enabled; }
    function setLayoutBarXray(enabled) { layoutBarXrayEnabled = !!enabled; }

    Component.onCompleted: generateLayoutConfig()

    Timer {
        id: layoutApplyTimer
        interval: 420
        repeat: false
        onTriggered: root.applyLayoutConfig()
    }

    function applyLayoutConfig() {
        if (layoutApply.running) {
            _layoutApplyPending = true;
            return;
        }
        layoutApply.command = [Paths.vshellCli, "config", "apply-layout", "hyprland", "--json"];
        layoutApply.running = true;
    }

    Process {
        id: layoutApply
        running: false
        command: []

        stdout: StdioCollector {
            onStreamFinished: {
                if ((text || "").trim().length === 0)
                    return;
                try {
                    const payload = JSON.parse(text);
                    if (!payload.ok)
                        log.warn("Hyprland layout apply failed:", payload.error || payload.reload?.stderr || "unknown");
                } catch (e) {
                    log.warn("Hyprland layout apply returned invalid JSON:", e);
                }
            }
        }

        onExited: exitCode => {
            if (exitCode !== 0)
                log.warn("Hyprland layout apply failed with code:", exitCode);
            if (root._layoutApplyPending) {
                root._layoutApplyPending = false;
                root.generateLayoutConfig();
            }
        }
    }

    function luaString(value) {
        return `"${String(value ?? "").replace(/\\/g, "\\\\").replace(/"/g, "\\\"")}"`;
    }

    function luaValue(value) {
        const text = String(value ?? "");
        return /^[-+]?\d+$/.test(text) ? text : luaString(text);
    }

    function windowSelector(windowAddress) {
        if (!windowAddress)
            return "";
        const text = String(windowAddress);
        if (text.startsWith("address:"))
            return text;
        return `address:${text.startsWith("0x") ? text : "0x" + text}`;
    }

    function renameWorkspace(wsId, newName) {
        const fullName = wsId + " " + newName;
        Hyprland.dispatch(`hl.dsp.workspace.rename({ workspace = ${luaValue(wsId)}, name = ${luaString(fullName)} })`);
    }

    function focusWorkspace(workspace) {
        Hyprland.dispatch(`hl.dsp.focus({ workspace = ${luaValue(workspace)} })`);
    }

    function focusWindow(windowAddress) {
        const selector = windowSelector(windowAddress);
        if (selector)
            Hyprland.dispatch(`hl.dsp.focus({ window = ${luaString(selector)} })`);
    }

    function closeWindow(windowAddress) {
        const selector = windowSelector(windowAddress);
        if (selector)
            Hyprland.dispatch(`hl.dsp.window.close(${luaString(selector)})`);
    }

    function moveToWorkspace(workspace, windowAddress, follow) {
        const selector = windowSelector(windowAddress);
        if (!selector)
            return;
        const shouldFollow = follow !== false;
        Hyprland.dispatch(`hl.dsp.window.move({ workspace = ${luaValue(workspace)}, window = ${luaString(selector)}, follow = ${shouldFollow ? "true" : "false"} })`);
    }

    function toggleSpecial(specialName) {
        Hyprland.dispatch(`hl.dsp.workspace.toggle_special(${luaString(specialName)})`);
    }

    function exit() {
        Hyprland.dispatch("hl.dsp.exit()");
    }

    // hl.dsp.dpms requires a table. A positional string is ignored and turns an explicit state request into a toggle.
    function dpmsOff() {
        Hyprland.dispatch('hl.dsp.dpms({ action = "off" })');
    }

    function dpmsOn() {
        Hyprland.dispatch('hl.dsp.dpms({ action = "on" })');
    }
}
