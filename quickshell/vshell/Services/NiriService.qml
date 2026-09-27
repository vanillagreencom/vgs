pragma Singleton
pragma ComponentBehavior: Bound

import QtCore
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services

Singleton {
    id: root

    readonly property var log: Log.scoped("NiriService")
    readonly property string socketPath: Quickshell.env("NIRI_SOCKET")
    readonly property bool available: CompositorService.isNiri && socketPath !== ""

    property var workspaces: ({})
    property var allWorkspaces: []
    property int focusedWorkspaceIndex: -1
    property var focusedWorkspaceId: null
    property var currentOutputWorkspaces: []
    property string currentOutput: ""
    property var outputs: ({})
    property var windows: []
    // Track snapshot receipt separately from windows: an empty list can mean either no windows or no reply.
    // Invalidate the snapshot on every connection transition.
    property bool windowsSnapshotReceived: false
    // A connected event socket does not prove that Niri is responding.
    readonly property bool eventStreamUp: eventStreamSocket.linkUp
    property var displayScales: ({})
    property bool inOverview: false
    property var casts: []
    readonly property bool hasCasts: casts.length > 0
    readonly property bool hasActiveCast: casts.some(cast => cast.is_active)
    property int currentKeyboardLayoutIndex: 0
    property var keyboardLayoutNames: []
    property string configValidationOutput: ""
    property bool layoutXrayEnabled: true
    property bool layoutBarXrayEnabled: true
    property bool matugenSuppression: false
    property bool _monitorsPoweredOff: false
    property int _outputApplySerial: 0

    signal windowUrgentChanged
    signal configReloaded

    Component.onCompleted: {
        if (available)
            fetchOutputs();
    }

    Connections {
        target: CompositorService
        function onIsNiriChanged() {
            if (CompositorService.isNiri)
                root.fetchOutputs();
        }
    }

    VgsSocket {
        id: eventStreamSocket
        path: root.socketPath
        connected: root.available
        onConnectionStateChanged: {
            // Either direction invalidates it: a drop leaves `windows` describing
            // a session VGS is no longer being told about, and a fresh link has
            // not delivered its own list yet — niri sends that in response to the
            // EventStream request below, not on connect.
            root.windowsSnapshotReceived = false;
            if (linkUp) {
                send("\"EventStream\"");
                root.fetchOutputs();
            }
        }
        parser: SplitParser {
            onRead: line => {
                try {
                    root.handleNiriEvent(JSON.parse(line));
                } catch (error) {
                    root.log.warn("Failed to parse Niri event:", error);
                }
            }
        }
    }

    VgsSocket {
        id: requestSocket
        path: root.socketPath
        connected: root.available
    }

    function validate() {
        Proc.runCommand("niri-validate-config", [Paths.vshellCli, "config", "niri-validate"],
            (output, exitCode, errorOutput) => {
                let detail = errorOutput.trim();
                try {
                    const result = JSON.parse(output);
                    detail = result.error || detail;
                } catch (_) {}
                configValidationOutput = exitCode === 0 ? "" : detail;
                if (exitCode !== 0 && configValidationOutput)
                    ToastService.showError(I18n.tr("niri: failed to load config"),
                        configValidationOutput, "", "niri-config");
            }, 0, 10000);
    }

    function setWorkspaces(next) {
        workspaces = next;
        allWorkspaces = Object.values(next).sort((a, b) => a.idx - b.idx);
    }

    function fetchOutputs() {
        if (!available)
            return false;
        Proc.runCommand("niri-fetch-outputs", [Paths.vshellCli, "config", "niri-outputs-current"], (output, exitCode, errorOutput) => {
            if (exitCode !== 0) {
                log.warn("Failed to fetch Niri outputs:", errorOutput || output);
                return;
            }
            try {
                const result = JSON.parse(output);
                outputs = result.outputs || {};
                updateDisplayScales();
                windows = sortWindowsByLayout(windows);
            } catch (error) {
                log.warn("Failed to parse Niri outputs:", error);
            }
        }, 0, 3000);
        return true;
    }

    function updateDisplayScales() {
        const next = {};
        for (const name in outputs) {
            const scale = outputs[name]?.logical?.scale;
            if (scale !== undefined && scale > 0)
                next[name] = scale;
        }
        displayScales = next;
    }

    function sortWindowsByLayout(windowList) {
        const enriched = Array.from(windowList || []).map(window => {
            const workspace = workspaces[window.workspace_id];
            const logical = outputs[workspace?.output]?.logical || {};
            const position = window.layout?.pos_in_scrolling_layout || [];
            return {
                window: window,
                outputX: logical.x ?? 999999,
                outputY: logical.y ?? 999999,
                workspaceIndex: workspace?.idx ?? 999999,
                column: position[0] ?? 999999,
                row: position[1] ?? 999999
            };
        });
        enriched.sort((a, b) =>
            a.outputX - b.outputX || a.outputY - b.outputY ||
            a.workspaceIndex - b.workspaceIndex ||
            a.column - b.column || a.row - b.row ||
            a.window.id - b.window.id);
        return enriched.map(item => item.window);
    }

    function handleNiriEvent(event) {
        const type = Object.keys(event)[0];
        const data = event[type];
        switch (type) {
        case "WorkspacesChanged":
            handleWorkspacesChanged(data);
            break;
        case "WorkspaceActivated":
            handleWorkspaceActivated(data);
            break;
        case "WorkspaceActiveWindowChanged":
            handleWorkspaceActiveWindowChanged(data);
            break;
        case "WindowFocusChanged":
            handleWindowFocusChanged(data);
            break;
        case "WindowsChanged":
            // The event that carries the whole list, which niri sends once when
            // the event stream opens and again whenever it changes wholesale.
            // Receiving it is what makes `windows` an answer rather than a
            // default, so it is the one place the snapshot is marked received.
            windows = sortWindowsByLayout(data.windows || []);
            windowsSnapshotReceived = true;
            break;
        case "WindowClosed":
            windows = windows.filter(window => window.id !== data.id);
            break;
        case "WindowOpenedOrChanged":
            handleWindowOpenedOrChanged(data);
            break;
        case "WindowLayoutsChanged":
            handleWindowLayoutsChanged(data);
            break;
        case "OutputsChanged":
            outputs = data.outputs || {};
            updateDisplayScales();
            windows = sortWindowsByLayout(windows);
            break;
        case "OverviewOpenedOrClosed":
            inOverview = data.is_open;
            break;
        case "KeyboardLayoutsChanged":
            keyboardLayoutNames = data.keyboard_layouts?.names || [];
            currentKeyboardLayoutIndex = data.keyboard_layouts?.current_idx || 0;
            break;
        case "KeyboardLayoutSwitched":
            currentKeyboardLayoutIndex = data.idx || 0;
            break;
        case "WorkspaceUrgencyChanged":
            updateWorkspace(data.id, { is_urgent: data.urgent });
            windowUrgentChanged();
            break;
        case "WindowUrgencyChanged":
            updateWindow(data.id, { is_urgent: data.urgent });
            windowUrgentChanged();
            break;
        case "CastsChanged":
            casts = data.casts || [];
            break;
        case "CastStartedOrChanged":
            updateCast(data.cast);
            break;
        case "CastStopped":
            casts = casts.filter(cast => cast.stream_id !== data.stream_id);
            break;
        case "ConfigLoaded":
            if (data.failed)
                validate();
            else {
                configValidationOutput = "";
                ToastService.dismissCategory("niri-config");
                fetchOutputs();
                configReloaded();
            }
            break;
        }
    }

    function handleWorkspacesChanged(data) {
        const next = {};
        for (const workspace of data.workspaces || []) {
            const previous = workspaces[workspace.id];
            next[workspace.id] = Object.assign({}, workspace);
            if (previous?.active_window_id !== undefined)
                next[workspace.id].active_window_id = previous.active_window_id;
        }
        setWorkspaces(next);
        focusedWorkspaceIndex = allWorkspaces.findIndex(workspace => workspace.is_focused);
        const focused = allWorkspaces[focusedWorkspaceIndex];
        focusedWorkspaceId = focused?.id ?? null;
        currentOutput = focused?.output || "";
        updateCurrentOutputWorkspaces();
    }

    function handleWorkspaceActivated(data) {
        const activated = workspaces[data.id];
        if (!activated)
            return;
        const next = {};
        for (const id in workspaces) {
            const workspace = workspaces[id];
            const changes = {};
            if (workspace.output === activated.output)
                changes.is_active = workspace.id === data.id;
            if (data.focused)
                changes.is_focused = workspace.id === data.id;
            next[id] = Object.assign({}, workspace, changes);
        }
        setWorkspaces(next);
        if (data.focused) {
            focusedWorkspaceId = data.id;
            focusedWorkspaceIndex = allWorkspaces.findIndex(workspace => workspace.id === data.id);
            currentOutput = activated.output || "";
        }
        updateCurrentOutputWorkspaces();
    }

    // Maintain at most one is_focused window because consumers use a first-match lookup.
    // Return the marked window, or null. Whole-window snapshots inherit this invariant from Niri.
    function markFocusedWindow(id) {
        let focused = null;
        windows = windows.map(window => {
            const next = Object.assign({}, window, { is_focused: window.id === id });
            if (next.is_focused)
                focused = next;
            return next;
        });
        return focused;
    }

    function handleWorkspaceActiveWindowChanged(data) {
        updateWorkspace(data.workspace_id, { active_window_id: data.active_window_id });
        // A workspace active window holds seat focus only when its workspace is focused.
        if (data.workspace_id === focusedWorkspaceId)
            markFocusedWindow(data.active_window_id);
    }

    function handleWindowFocusChanged(data) {
        const focusedWindow = markFocusedWindow(data.id);
        if (focusedWindow)
            updateWorkspace(focusedWindow.workspace_id, { active_window_id: focusedWindow.id });
    }

    function handleWindowOpenedOrChanged(data) {
        if (!data.window)
            return;
        const next = windows.filter(window => window.id !== data.window.id);
        next.push(data.window);
        windows = sortWindowsByLayout(next);
        // niri sends the whole window, marker included, so one arriving focused
        // would sit beside the window that still carries the marker until
        // WindowFocusChanged lands. Re-establish the invariant here rather than
        // depending on which of the two events arrives first.
        if (data.window.is_focused)
            markFocusedWindow(data.window.id);
    }

    function handleWindowLayoutsChanged(data) {
        if (!data.changes)
            return;
        const changes = {};
        for (const entry of data.changes)
            changes[entry[0]] = entry[1];
        windows = sortWindowsByLayout(windows.map(window =>
            changes[window.id] === undefined
                ? window
                : Object.assign({}, window, { layout: changes[window.id] })));
    }

    function updateWorkspace(id, changes) {
        if (!workspaces[id])
            return;
        const next = Object.assign({}, workspaces);
        next[id] = Object.assign({}, workspaces[id], changes);
        setWorkspaces(next);
    }

    function updateWindow(id, changes) {
        windows = windows.map(window =>
            window.id === id ? Object.assign({}, window, changes) : window);
    }

    function updateCast(cast) {
        if (!cast)
            return;
        const next = casts.filter(item => item.stream_id !== cast.stream_id);
        next.push(cast);
        casts = next;
    }

    function updateCurrentOutputWorkspaces() {
        currentOutputWorkspaces = currentOutput
            ? allWorkspaces.filter(workspace => workspace.output === currentOutput)
            : allWorkspaces.slice();
    }

    function send(request) {
        if (!available || !requestSocket.linkUp)
            return false;
        requestSocket.send(request);
        return true;
    }

    function doScreenTransition() {
        return send({ Action: { DoScreenTransition: { delay_ms: 0 } } });
    }

    function toggleOverview() {
        return send({ Action: { ToggleOverview: {} } });
    }

    function focusMonitor(output) {
        return send({ Action: { FocusMonitor: { output: output } } });
    }

    function renameWorkspace(name) {
        if (!name || !name.trim())
            return send({ Action: { UnsetWorkspaceName: { workspace: null } } });
        return send({ Action: { SetWorkspaceName: { name: name, workspace: null } } });
    }

    function moveColumnRight(output) {
        if (output && output !== currentOutput)
            focusMonitor(output);
        return send({ Action: { FocusColumnRight: {} } });
    }

    function moveColumnLeft(output) {
        if (output && output !== currentOutput)
            focusMonitor(output);
        return send({ Action: { FocusColumnLeft: {} } });
    }

    function moveWorkspaceDown() {
        return send({ Action: { FocusWorkspaceDown: {} } });
    }

    function moveWorkspaceUp() {
        return send({ Action: { FocusWorkspaceUp: {} } });
    }

    function getCurrentOutputWorkspaces() {
        return currentOutputWorkspaces.slice();
    }

    function getCurrentWorkspaceNumber() {
        const workspace = allWorkspaces[focusedWorkspaceIndex];
        return workspace?.idx ?? 1;
    }

    function switchToWorkspace(id) {
        return send({ Action: { FocusWorkspace: { reference: { Id: id } } } });
    }

    function moveWorkspaceToIndex(id, index) {
        return send({ Action: { MoveWorkspaceToIndex: { index: index, reference: { Id: id } } } });
    }

    function focusWindow(id) {
        return send({ Action: { FocusWindow: { id: id } } });
    }

    function getCurrentKeyboardLayoutName() {
        return keyboardLayoutNames[currentKeyboardLayoutIndex] || "";
    }

    function cycleKeyboardLayout() {
        return send({ Action: { SwitchLayout: { layout: "Next" } } });
    }

    function powerOffMonitors() {
        const sent = send({ Action: { PowerOffMonitors: {} } });
        if (sent)
            _monitorsPoweredOff = true;
        return sent;
    }

    function powerOnMonitors() {
        const sent = send({ Action: { PowerOnMonitors: {} } });
        if (sent)
            _monitorsPoweredOff = false;
        return sent;
    }

    function anyDisplayOff() {
        return _monitorsPoweredOff;
    }

    function debugDisplayStates() {
        return "niriOutputs=[" + Object.keys(outputs).map(name =>
            name + ":" + (_monitorsPoweredOff ? "off" : "on")).join(",") + "]";
    }

    function quit() {
        return send({ Action: { Quit: { skip_confirmation: true } } });
    }

    function screenshot() {
        Quickshell.execDetached([Paths.vshellCli, "capture", "screenshot", "region", "save-copy"]);
        return true;
    }

    function screenshotScreen() {
        Quickshell.execDetached([Paths.vshellCli, "capture", "screenshot", "fullscreen", "save-copy"]);
        return true;
    }

    function screenshotWindow() {
        Quickshell.execDetached([Paths.vshellCli, "capture", "screenshot", "window", "save-copy"]);
        return true;
    }

    function suppressNextToast() {
        matugenSuppression = true;
        suppressionReset.restart();
    }

    Timer {
        id: suppressionReset
        interval: 5000
        onTriggered: root.matugenSuppression = false
    }

    function sortToplevels(toplevels) {
        if (!toplevels || windows.length === 0)
            return Array.from(toplevels || []);
        const match = _matchToplevels(toplevels, windows);
        return match.enriched.concat(Array.from(toplevels)
            .filter(toplevel => !match.used.has(toplevel)));
    }

    function _matchToplevels(toplevels, niriWindows) {
        const candidatesByAppId = new Map();
        for (const toplevel of Array.from(toplevels || [])) {
            const candidates = candidatesByAppId.get(toplevel.appId) || [];
            candidates.push(toplevel);
            candidatesByAppId.set(toplevel.appId, candidates);
        }
        const used = new Set();
        const result = [];
        for (const window of niriWindows) {
            let best = null;
            let score = -1;
            const candidates = candidatesByAppId.get(window.app_id) || [];
            for (const toplevel of candidates) {
                if (used.has(toplevel))
                    continue;
                const nextScore = toplevel.title === window.title ? 3
                    : (toplevel.title?.includes(window.title || "") || window.title?.includes(toplevel.title || "")) ? 2 : 1;
                if (nextScore > score) {
                    best = toplevel;
                    score = nextScore;
                }
            }
            if (!best)
                continue;
            used.add(best);
            const enrichedToplevel = Object.assign({}, best, {
                activated: !!window.is_focused,
                niriWindowId: window.id,
                niriWorkspaceId: window.workspace_id,
                activate: () => root.focusWindow(window.id),
                close: () => best.close ? best.close() : false
            });
            result.push(enrichedToplevel);
        }
        return {
            enriched: result,
            used: used
        };
    }

    function _matchAndEnrichToplevels(toplevels, niriWindows) {
        return _matchToplevels(toplevels, niriWindows).enriched;
    }

    function filterCurrentWorkspace(toplevels, screenName) {
        const active = allWorkspaces.find(workspace =>
            workspace.output === screenName && workspace.is_active);
        if (!active)
            return Array.from(toplevels || []);
        if (toplevels.length > 0 && toplevels[0].niriWorkspaceId !== undefined)
            return toplevels.filter(toplevel => toplevel.niriWorkspaceId === active.id);
        return _matchAndEnrichToplevels(toplevels,
            windows.filter(window => window.workspace_id === active.id));
    }

    function filterCurrentDisplay(toplevels, screenName) {
        if (!screenName)
            return Array.from(toplevels || []);
        const workspaceIds = new Set(allWorkspaces
            .filter(workspace => workspace.output === screenName)
            .map(workspace => workspace.id));
        if (toplevels.length > 0 && toplevels[0].niriWorkspaceId !== undefined)
            return toplevels.filter(toplevel => workspaceIds.has(toplevel.niriWorkspaceId));
        return _matchAndEnrichToplevels(toplevels,
            windows.filter(window => workspaceIds.has(window.workspace_id)));
    }

    function setLayoutXray(enabled) {
        layoutXrayEnabled = enabled;
        generateNiriLayoutConfig();
    }

    function setLayoutBarXray(enabled) {
        layoutBarXrayEnabled = enabled;
        generateNiriLayoutConfig();
    }

    function generateNiriLayoutConfig() {
        if (!available)
            return false;
        Proc.runCommand("niri-layout-config",
            [Paths.vshellCli, "config", "apply-layout", "niri", "--json"],
            (output, exitCode, errorOutput) => {
                if (exitCode === 0)
                    return;
                const detail = (errorOutput || output || "helper exited with code " + exitCode).trim();
                log.warn("Failed to apply Niri layout:", detail);
                ToastService.showError(I18n.tr("Could not apply Niri layout"), detail, "", "niri-config");
            }, 0, 5000);
        return true;
    }

    function generateNiriCursorConfig() {
        if (!available)
            return false;
        Proc.runCommand("niri-cursor-config",
            [Paths.vshellCli, "config", "apply-cursor", "niri"],
            (output, exitCode, errorOutput) => {
                if (exitCode === 0)
                    return;
                const detail = (errorOutput || output || "helper exited with code " + exitCode).trim();
                log.warn("Failed to apply Niri cursor:", detail);
                ToastService.showError(I18n.tr("Could not apply Niri cursor"), detail, "", "niri-config");
            }, 0, 5000);
        return true;
    }

    function applyOutputConfig(liveName, config, callback) {
        const commandId = "niri-output-config-" + (++_outputApplySerial);
        Proc.runCommand(commandId,
            [Paths.vshellCli, "config", "niri-output-apply", liveName, JSON.stringify(config)],
            (output, exitCode, errorOutput) => {
                fetchOutputs();
                const detail = (errorOutput || output || "").trim();
                if (exitCode !== 0) {
                    log.warn("Failed to apply Niri output", liveName + ":", detail);
                    ToastService.showError(I18n.tr("Could not apply display settings"), detail, "", "display-config");
                }
                if (callback)
                    callback(exitCode === 0, detail);
            }, 0, 10000);
    }

    function outputsPayload(outputsData, niriSettings) {
        return {
            outputs: outputsData || outputs,
            settings: niriSettings || SettingsData.niriOutputSettings || {},
            displayNameMode: SettingsData.displayNameMode || ""
        };
    }

    function generateOutputsConfig(outputsData, settingsOrCallback, maybeCallback) {
        const settings = typeof settingsOrCallback === "function" ? null : settingsOrCallback;
        const callback = typeof settingsOrCallback === "function" ? settingsOrCallback : maybeCallback;
        const payload = JSON.stringify(outputsPayload(outputsData, settings));
        Proc.runCommand("niri-write-outputs",
            [Paths.vshellCli, "config", "niri-outputs-write", payload],
            (output, exitCode, errorOutput) => {
                if (exitCode !== 0) {
                    const detail = (errorOutput || output || "helper exited with code " + exitCode).trim();
                    log.warn("Failed to write Niri outputs:", detail);
                    ToastService.showError(I18n.tr("Could not write Niri outputs"), detail, "", "display-config");
                }
                if (callback)
                    callback(exitCode === 0, output.trim());
            }, 0, 10000);
    }
}
