#!/usr/bin/env node

// Execute extracted compositor focus bindings, handlers, and startup logic for paste targeting.
// Focus must come from the selected compositor and seed state before the first change event.
// Detection readiness and Niri snapshot readiness are separate.
// This models reported compositor state; it does not verify a live Niri server's event contract.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
// Use the shared comment-aware and string-aware brace reader to prevent truncated extraction.
const { extractBlock } = require("./lib/qml-block.js");

const QML = path.join(__dirname, "..", "quickshell", "vshell", "Services", "CompositorService.qml");
const source = fs.readFileSync(QML, "utf8");
// Read Niri snapshot-flag maintenance from its service so readiness cannot be granted by fixture assumption.
const NIRI_QML = path.join(__dirname, "..", "quickshell", "vshell", "Services", "NiriService.qml");
const niriSource = fs.readFileSync(NIRI_QML, "utf8");

// Include continuation lines in binding extraction. A declaration line alone can omit both branches.
function bindingExpression(name, kind = "string") {
    const opener = new RegExp(`^([ \\t]*)(?:readonly[ \\t]+)?property[ \\t]+${kind}[ \\t]+${name}[ \\t]*:(.*)$`, "m");
    const match = source.match(opener);
    assert.ok(match, `could not find the ${name} binding`);
    const indent = match[1].length;
    const parts = [match[2]];
    for (const line of source.slice(match.index + match[0].length).split("\n").slice(1)) {
        if (!line.trim()) break;
        if (line.length - line.trimStart().length <= indent) break;
        parts.push(line);
    }
    return parts.join("\n").trim();
}

const FOCUS_SOURCE = bindingExpression("focusSource");
const FOCUS_READY = bindingExpression("focusReady", "bool");
const FOCUSED = bindingExpression("focusedAppId");
const LAST_FOCUSED = bindingExpression("lastFocusedAppId");
const bodies = {
    remember: extractBlock(source, "function rememberNiriFocus()"),
    seed: extractBlock(source, "function seedRememberedFocus()"),
    completed: extractBlock(source, "Component.onCompleted:"),
    applyCompositor: extractBlock(source, "function _applyCompositor(name)"),
    activeToplevelChanged: extractBlock(source, "function onActiveToplevelChanged()"),
    windowsChanged: extractBlock(source, "function onWindowsChanged()", source.indexOf("target: NiriService")),
    niriEvent: extractBlock(niriSource, "function handleNiriEvent(event)"),
    niriLinkChanged: extractBlock(niriSource, "onConnectionStateChanged:"),
    markFocusedWindow: extractBlock(niriSource, "function markFocusedWindow(id)"),
    workspaceActiveWindowChanged: extractBlock(niriSource, "function handleWorkspaceActiveWindowChanged(data)"),
    windowFocusChanged: extractBlock(niriSource, "function handleWindowFocusChanged(data)"),
    windowOpenedOrChanged: extractBlock(niriSource, "function handleWindowOpenedOrChanged(data)"),
};

// Assert expected content so a truncated binding cannot pass without exercising its branch.
test("every extracted binding and handler carries the content the model relies on", () => {
    for (const [label, text, needles] of [
        ["focusSource", FOCUS_SOURCE, ["compositorDetected", "pending", "niri", "hyprland", "unknown"]],
        ["focusReady", FOCUS_READY, ["focusSource", "NiriService.", "pending"]],
        ["handleNiriEvent", bodies.niriEvent, ["WindowsChanged", "windowsSnapshotReceived"]],
        ["onConnectionStateChanged", bodies.niriLinkChanged, ["windowsSnapshotReceived", "linkUp"]],
        ["markFocusedWindow", bodies.markFocusedWindow, ["is_focused", "window.id === id"]],
        // Use identification needles independent of the fix so behavior controls reach their assertions.
        ["handleWorkspaceActiveWindowChanged", bodies.workspaceActiveWindowChanged, ["active_window_id"]],
        ["handleWindowFocusChanged", bodies.windowFocusChanged, ["updateWorkspace"]],
        ["handleWindowOpenedOrChanged", bodies.windowOpenedOrChanged, ["sortWindowsByLayout"]],
        ["focusedAppId", FOCUSED, ["focusSource", "focusReady", "is_focused", "activeToplevel"]],
        ["lastFocusedAppId", LAST_FOCUSED, ["focusSource", "focusReady", "NiriService.windows", "ToplevelManager.toplevels"]],
        ["rememberNiriFocus", bodies.remember, ["is_focused", "_lastFocusedNiriWindowId"]],
        ["seedRememberedFocus", bodies.seed, ["activeToplevel", "_lastFocusedToplevel", "rememberNiriFocus"]],
        ["Component.onCompleted", bodies.completed, ["seedRememberedFocus"]],
        ["_applyCompositor", bodies.applyCompositor, ["isNiri", "seedRememberedFocus"]],
        ["onActiveToplevelChanged", bodies.activeToplevelChanged, ["_lastFocusedToplevel"]],
        ["onWindowsChanged", bodies.windowsChanged, ["rememberNiriFocus"]],
    ]) {
        for (const needle of needles)
            assert.ok(text.includes(needle), `the extracted ${label} must contain ${needle}`);
    }
});

// with models QML's unqualified component lookup without rewriting the extracted function bodies.
function call(body, root, parameters = [], args = []) {
    return new Function("root", ...parameters, `with (root) {\n${body}\n}`)(root, ...args);
}

// Layer child-object and root scopes so socket handlers write component state instead of a fixture shadow.
function callInScope(body, root, scope) {
    return new Function("root", "scope", `with (scope) { with (root) {\n${body}\n} }`)(root, scope);
}

const foot = { id: 7, app_id: "foot", is_focused: true };
const kitty = { id: 9, app_id: "kitty", is_focused: false };
const unfocused = (window) => Object.assign({}, window, { is_focused: false });

function shell(overrides = {}) {
    const root = Object.assign({
        isHyprland: false,
        isNiri: false,
        compositor: "unknown",
        compositorDetected: false,
        _lastFocusedToplevel: null,
        _lastFocusedNiriWindowId: null,
        NiriService: { windows: [] },
        ToplevelManager: { activeToplevel: null, toplevels: { values: [] } },
        log: { warn() {}, info() {} },
        calls: [],
    }, overrides);

    root.refreshToplevels = () => root.calls.push("refreshToplevels");
    root.randrDataReady = () => root.calls.push("randrDataReady");
    // Keep compositor detection asynchronous in the model; synchronous resolution would conceal startup gaps.
    root.detectCompositor = () => root.calls.push("detectCompositor");

    // Set snapshot readiness through the shipped WindowsChanged handler.
    root.NiriService.windowsSnapshotReceived = root.NiriService.windowsSnapshotReceived ?? false;
    root.NiriService.eventStreamUp = root.NiriService.eventStreamUp ?? false;
    root.NiriService.sortWindowsByLayout = list => list;
    // Drive shipped focus-marker handlers. Hand-setting one focused window cannot expose ambiguous markers.
    root.NiriService.focusedWorkspaceId = root.NiriService.focusedWorkspaceId ?? null;
    root.NiriService.workspaceUpdates = [];
    root.NiriService.updateWorkspace = (id, changes) => root.NiriService.workspaceUpdates.push([id, changes]);
    root.NiriService.markFocusedWindow = (id) =>
        call(bodies.markFocusedWindow, root.NiriService, ["id"], [id]);
    for (const [name, body] of [
        ["handleWorkspaceActiveWindowChanged", bodies.workspaceActiveWindowChanged],
        ["handleWindowFocusChanged", bodies.windowFocusChanged],
        ["handleWindowOpenedOrChanged", bodies.windowOpenedOrChanged],
    ])
        root.NiriService[name] = (data) => call(body, root.NiriService, ["data"], [data]);
    root.niriEvent = (event) => call(bodies.niriEvent, root.NiriService, ["event"], [event]);
    root.NiriService.fetchOutputs = () => {};
    // The socket owns linkUp; its handler assigns snapshot state on the service.
    root.niriLink = (up) => {
        root.NiriService.eventStreamUp = up;
        callInScope(bodies.niriLinkChanged, root.NiriService, { linkUp: up, send: () => {} });
    };

    root.rememberNiriFocus = () => call(bodies.remember, root);
    root.seedRememberedFocus = () => call(bodies.seed, root);
    root.construct = () => call(bodies.completed, root);
    root.detected = (name) => call(bodies.applyCompositor, root, ["name"], [name]);
    root.focusChanged = () => call(bodies.activeToplevelChanged, root);
    root.windowsChanged = () => call(bodies.windowsChanged, root);

    // Model this as a binding so reads observe detection changes.
    Object.defineProperty(root, "focusSource", { get: () => call(`return (${FOCUS_SOURCE});`, root) });
    Object.defineProperty(root, "focusReady", { get: () => call(`return (${FOCUS_READY});`, root) });

    root.focusedAppId = () => call(`return (${FOCUSED});`, root);
    root.lastFocusedAppId = () => call(`return (${LAST_FOCUSED});`, root);
    return root;
}

// Keep pre-detection startup representable instead of assuming a ready compositor in shell().
function settled(compositor, overrides = {}) {
    const root = shell(Object.assign({
        compositorDetected: true,
        isHyprland: compositor === "hyprland",
        isNiri: compositor === "niri",
        compositor,
    }, overrides));
    // Niri detection can finish before its source can answer. Represent both stages separately.
    root.NiriService.eventStreamUp = true;
    root.NiriService.windowsSnapshotReceived = true;
    return root;
}

test("focusedAppId on Hyprland resolves the active toplevel and nothing else", () => {
    const toplevel = { appId: "foot" };
    for (const [overrides, expected, why] of [
        [{ ToplevelManager: { activeToplevel: toplevel, toplevels: { values: [toplevel] } } }, "foot",
            "Hyprland resolves the active toplevel's app id"],
        [{}, "", "no active toplevel is unknown, not a target"],
        [{ NiriService: { windows: [foot] } }, "", "Hyprland does not read Niri's focused window"]
    ]) {
        assert.equal(settled("hyprland", overrides).focusedAppId(), expected, why);
    }
});

test("lastFocusedAppId on Hyprland names a remembered window only while it is open", () => {
    const toplevel = { appId: "foot" };
    const live = settled("hyprland", { _lastFocusedToplevel: toplevel, ToplevelManager: { activeToplevel: null, toplevels: { values: [toplevel] } } });
    assert.equal(live.lastFocusedAppId(), "foot", "a remembered window that is still open is a target");
    const closed = settled("hyprland", { _lastFocusedToplevel: toplevel, ToplevelManager: { activeToplevel: null, toplevels: { values: [] } } });
    assert.equal(closed.lastFocusedAppId(), "", "a remembered window that closed is not a target");
});
test("losing focus does not clear the remembered Hyprland window", () => {

    const root = shell();
    root.construct();
    root.detected("hyprland");
    const toplevel = { appId: "foot" };
    root.ToplevelManager = { activeToplevel: toplevel, toplevels: { values: [toplevel] } };
    root.focusChanged();
    root.ToplevelManager.activeToplevel = null;
    root.focusChanged();
    assert.equal(root.lastFocusedAppId(), "foot", "losing focus does not clear the remembered window");
});

test("construction seeds the focus already in place and detection does not clear it", () => {
    // A window focused before startup emits no new focus change; construction must seed its target.
    const toplevel = { appId: "foot" };
    const root = shell({ ToplevelManager: { activeToplevel: toplevel, toplevels: { values: [toplevel] } } });
    root.construct();
    assert.equal(root._lastFocusedToplevel, toplevel, "construction seeds the focus already in place");

    // Later detection must not replace a valid seed with an empty seat after a shell surface takes focus.
    root.ToplevelManager.activeToplevel = null;
    root.detected("hyprland");
    assert.equal(root._lastFocusedToplevel, toplevel, "detection does not clear what construction seeded");
    root.ToplevelManager.activeToplevel = toplevel;

    // Only the seed can supply a fallback if no non-null focus change occurred.
    root.ToplevelManager.activeToplevel = null;
    root.focusChanged();
    assert.equal(root.focusedAppId(), "", "the shell surface emptied the live value");
    assert.equal(root.lastFocusedAppId(), "foot", "the first paste of the session still resolves its target");
});
test("an empty seat seeds nothing", () => {

    const root = shell();
    root.construct();
    root.detected("hyprland");
    assert.equal(root._lastFocusedToplevel, null, "an empty seat seeds nothing");
    assert.equal(root.lastFocusedAppId(), "", "and resolves to no target");
});

test("focusedAppId on Niri resolves the window carrying is_focused and never the active toplevel", () => {
    const kittyToplevel = { appId: "kitty" };
    const withToplevel = { activeToplevel: kittyToplevel, toplevels: { values: [kittyToplevel] } };
    for (const [overrides, expected, why] of [
        [{ NiriService: { windows: [kitty, foot] } }, "foot", "Niri resolves the window carrying is_focused"],
        [{ NiriService: { windows: [kitty] } }, "", "no focused Niri window is unknown, not a target"],
        [{ NiriService: { windows: [] } }, "", "an empty Niri window list resolves to no target"],
        [{ NiriService: { windows: [foot] }, ToplevelManager: withToplevel }, "foot",
            "Niri ignores the active toplevel in favour of its own focus"],
        [{ NiriService: { windows: [kitty] }, ToplevelManager: withToplevel }, "",
            "an active toplevel does not stand in for Niri focus"]
    ]) {
        assert.equal(settled("niri", overrides).focusedAppId(), expected, why);
    }
});

test("Niri remembers the focused window across a focus gap until it closes", () => {
    const root = settled("niri", { NiriService: { windows: [kitty, foot] } });
    root.windowsChanged();
    assert.equal(root._lastFocusedNiriWindowId, foot.id, "the focused window's id is remembered");
    assert.equal(root.lastFocusedAppId(), "foot", "the remembered window resolves to its app id");

    // A shell surface can clear live focus; the remembered target must survive while its window exists.
    root.NiriService.windows = [kitty, unfocused(foot)];
    root.windowsChanged();
    assert.equal(root.focusedAppId(), "", "focus left every Niri window");
    assert.equal(root._lastFocusedNiriWindowId, foot.id, "losing focus does not clear the remembered window");
    assert.equal(root.lastFocusedAppId(), "foot", "the fallback carries the target across the gap");

    // Remove a closed window from fallback targeting to avoid applying its keystroke to a replacement window.
    root.NiriService.windows = [kitty];
    root.windowsChanged();
    assert.equal(root.lastFocusedAppId(), "", "a remembered Niri window that closed is not a target");
    assert.equal(root.focusedAppId(), "", "and nothing else resolves in its place");
});
test("the remembered Niri window follows focus", () => {

    const root = settled("niri", { NiriService: { windows: [kitty, foot] } });
    root.windowsChanged();
    root.NiriService.windows = [Object.assign({}, kitty, { is_focused: true }), unfocused(foot)];
    root.windowsChanged();
    assert.equal(root.lastFocusedAppId(), "kitty", "the remembered window follows focus");
});
test("a remembered id no live window carries resolves to nothing", () => {

    const root = settled("niri", { NiriService: { windows: [kitty] }, _lastFocusedNiriWindowId: 404 });
    assert.equal(root.lastFocusedAppId(), "", "an id no live window carries resolves to nothing");
});
test("an unset remembered id matches no window", () => {
    // An absent remembered ID must not match a window with an undefined ID.
    const root = settled("niri", { NiriService: { windows: [{ app_id: "foot", is_focused: true }] } });
    assert.equal(root.lastFocusedAppId(), "", "an unset remembered id matches no window");
});

test("Niri detection seeds the focus already reported and the first paste resolves it", () => {
    // Niri events before compositor detection cannot update an isNiri-gated listener. Seed when detection resolves.
    const root = shell({ NiriService: { windows: [kitty, foot] } });
    root.construct();
    assert.equal(root._lastFocusedNiriWindowId, null, "construction predates detection, so nothing Niri is seeded yet");

    root.detected("niri");
    assert.equal(root.isNiri, true, "detection applied");
    assert.equal(root._lastFocusedNiriWindowId, foot.id, "detection seeds the focus niri already reported");

    // Snapshot delivery follows socket connection independently of compositor detection.
    root.NiriService.eventStreamUp = true;
    root.niriEvent({ WindowsChanged: { windows: [kitty, foot] } });

    root.niriEvent({ WindowsChanged: { windows: [kitty, unfocused(foot)] } });
    root.windowsChanged();
    assert.equal(root.focusedAppId(), "", "the shell surface emptied the live value");
    assert.equal(root.lastFocusedAppId(), "foot", "the first paste of the session still resolves its target");
});
test("no focused Niri window at detection seeds nothing", () => {

    const root = shell({ NiriService: { windows: [kitty] } });
    root.construct();
    root.detected("niri");
    root.NiriService.eventStreamUp = true;
    root.niriEvent({ WindowsChanged: { windows: [kitty] } });
    assert.equal(root.focusReady, true, "the source can answer");
    assert.equal(root._lastFocusedNiriWindowId, null, "no focused Niri window seeds nothing");
    assert.equal(root.lastFocusedAppId(), "", "and resolves to no target");
});
test("Hyprland detection does not seed a Niri target", () => {
    // A Hyprland detection result must not seed a Niri target.
    const kittyToplevel = { appId: "kitty" };
    const root = shell({
        NiriService: { windows: [foot] },
        ToplevelManager: { activeToplevel: kittyToplevel, toplevels: { values: [kittyToplevel] } },
    });
    root.construct();
    root.detected("hyprland");
    assert.equal(root._lastFocusedNiriWindowId, null, "the Hyprland seed leaves Niri's list alone");
    assert.equal(root.focusedAppId(), "kitty", "and resolves its own source instead");
});

test("focusSource is pending before detection and names each answer", () => {
    // Pending and failed detection both have false compositor booleans but require distinct states.
    const root = shell();
    assert.equal(root.focusSource, "pending", "nothing has been asked yet");
    root.detected("hyprland");
    assert.equal(root.focusSource, "hyprland", "detection answered Hyprland");
    assert.equal(shell().focusSource, "pending", "and a fresh component is pending again");

    const niri = shell();
    niri.detected("niri");
    assert.equal(niri.focusSource, "niri", "detection answered Niri");

    const failed = shell();
    failed.detected("unknown");
    assert.equal(failed.focusSource, "unknown", "detection answered that it could not tell");
    assert.notEqual(failed.focusSource, "pending", "which is an answer, not a wait");
});
test("nothing resolves while detection is pending, and the same state resolves after", () => {
    // While detection is pending, neither compositor's available state authorizes a paste target.
    const toplevel = { appId: "foot" };
    const root = shell({
        _lastFocusedToplevel: toplevel,
        _lastFocusedNiriWindowId: foot.id,
        NiriService: { windows: [foot] },
        ToplevelManager: { activeToplevel: toplevel, toplevels: { values: [toplevel] } },
    });
    assert.equal(root.focusSource, "pending", "detection has not answered");
    assert.equal(root.focusedAppId(), "", "no live target before the compositor is known");
    assert.equal(root.lastFocusedAppId(), "", "and no remembered one either");

    // After detection answers, the same state must resolve without losing the pending paste.
    root.detected("hyprland");
    assert.equal(root.focusedAppId(), "foot", "the live target resolves once detection answers");
    assert.equal(root.lastFocusedAppId(), "foot", "and so does the remembered one");
});

// Use competing windows and shipped event handlers. One window cannot reveal ambiguous focus markers.

function niriSession(windows, focusedWorkspaceId) {
    const root = shell();
    root.detected("niri");
    root.niriLink(true);
    root.NiriService.focusedWorkspaceId = focusedWorkspaceId;
    root.niriEvent({ WindowsChanged: { windows } });
    return root;
}

const focusedCount = (root) => root.NiriService.windows.filter(window => window.is_focused).length;

const term = { id: 1, app_id: "foot", workspace_id: 1, is_focused: true };
const editor = { id: 2, app_id: "code", workspace_id: 2, is_focused: false };
const browser = { id: 3, app_id: "firefox", workspace_id: 2, is_focused: false };

test("a background workspace's active-window change does not mark a second focused window", () => {
    // A background workspace's active-window change must not mark it globally focused.
    const root = niriSession([editor, term], 1);
    assert.equal(root.focusedAppId(), "foot", "the terminal holds focus");

    root.niriEvent({ WorkspaceActiveWindowChanged: { workspace_id: 2, active_window_id: editor.id } });

    assert.equal(focusedCount(root), 1, "a background workspace's active window must not be a second focused window");
    assert.equal(root.focusedAppId(), "foot", "so focus is still the terminal");
    assert.equal(root.NiriService.windows.find(window => window.is_focused).id, term.id, "and it is the window the seat actually focuses");
});
test("the focus answer does not depend on window order", () => {
    // Reverse window order so first-match lookup cannot conceal competing focus markers.
    const root = niriSession([editor, browser, term], 1);
    root.niriEvent({ WorkspaceActiveWindowChanged: { workspace_id: 2, active_window_id: browser.id } });
    assert.equal(root.focusedAppId(), "foot", "the answer does not depend on where the window sits in the list");
    assert.equal(focusedCount(root), 1, "with still exactly one marked");
});
test("an active-window change on the focused workspace moves focus", () => {
    // The same event on the focused workspace must still move focus.
    const root = niriSession([term, editor], 1);
    const second = { id: 4, app_id: "kitty", workspace_id: 1, is_focused: false };
    root.niriEvent({ WindowsChanged: { windows: [term, editor, second] } });
    root.niriEvent({ WorkspaceActiveWindowChanged: { workspace_id: 1, active_window_id: second.id } });
    assert.equal(root.focusedAppId(), "kitty", "focus moves within the focused workspace");
    assert.equal(focusedCount(root), 1, "and still exactly one window is marked");
});
test("a window arriving focused clears the outgoing marker", () => {
    // An incoming focused window can precede WindowFocusChanged; its handler must clear the outgoing marker.
    const root = niriSession([term, editor], 1);
    const popup = { id: 5, app_id: "kitty", workspace_id: 1, is_focused: true };
    root.niriEvent({ WindowOpenedOrChanged: { window: popup } });
    assert.equal(focusedCount(root), 1, "a window arriving focused does not make two");
    assert.equal(root.focusedAppId(), "kitty", "and it is the one that arrived focused");
});
test("WindowFocusChanged marks one window or none", () => {

    const root = niriSession([term, editor], 1);
    root.niriEvent({ WindowFocusChanged: { id: editor.id } });
    assert.equal(focusedCount(root), 1, "focus moving across workspaces marks one window");
    assert.equal(root.focusedAppId(), "code", "the one the event named");
    root.niriEvent({ WindowFocusChanged: { id: null } });
    assert.equal(focusedCount(root), 0, "and focus leaving every window marks none");
    assert.equal(root.focusedAppId(), "", "which resolves to no target");
});
test("the remembered fallback ignores background workspace changes and a focus clear", () => {
    // The remembered fallback must also ignore active-window changes in background workspaces.
    const root = niriSession([term, editor], 1);
    root.windowsChanged();
    assert.equal(root.lastFocusedAppId(), "foot", "the terminal is remembered");

    root.niriEvent({ WorkspaceActiveWindowChanged: { workspace_id: 2, active_window_id: editor.id } });
    root.windowsChanged();
    assert.equal(root.lastFocusedAppId(), "foot", "and stays remembered through a background workspace's change");

    root.niriEvent({ WindowFocusChanged: { id: null } });
    root.windowsChanged();
    assert.equal(root.focusedAppId(), "", "nothing is focused");
    assert.equal(root.lastFocusedAppId(), "foot", "and the remembered target is still the terminal");
});

test("Niri readiness needs the snapshot after the link, and link loss invalidates it", () => {
    // Niri detection can finish before the initial window snapshot. That gap must remain unready for paste.
    const root = shell();
    root.construct();
    root.detected("niri");
    assert.equal(root.focusSource, "niri", "detection has answered");
    assert.equal(root.focusReady, false, "but the source cannot answer yet");

    // An open socket does not prove that the initial window list arrived.
    root.niriLink(true);
    assert.equal(root.focusReady, false, "an open socket is not an answer");

    // Use the shipped snapshot handler to establish readiness.
    root.niriEvent({ WindowsChanged: { windows: [foot] } });
    assert.equal(root.NiriService.windowsSnapshotReceived, true, "the WindowsChanged event marks it received");
    assert.equal(root.focusReady, true, "now the source can answer");
    assert.equal(root.focusedAppId(), "foot", "and it names the focused window");

    // A dropped link makes retained window data stale immediately.
    root.NiriService.eventStreamUp = false;
    assert.equal(root.NiriService.windowsSnapshotReceived, true, "the snapshot flag is untouched so far");
    assert.equal(root.focusReady, false, "but a dropped link is not an answer");
    assert.equal(root.focusedAppId(), "", "and names no target while it is down");

    // Link loss must clear snapshot state so reconnection cannot authorize the old list.
    root.niriLink(false);
    assert.equal(root.NiriService.windowsSnapshotReceived, false, "the link transition invalidated it");
    root.niriLink(true);
    assert.equal(root.NiriService.windowsSnapshotReceived, false, "and coming back up does not restore it");
    assert.equal(root.focusReady, false, "readiness waits for the new snapshot");
    root.niriEvent({ WindowsChanged: { windows: [foot] } });
    assert.equal(root.focusReady, true, "which the reconnected stream delivers");
});
test("an empty Niri snapshot is an answer", () => {
    // An empty snapshot is a completed answer and must not be confused with no snapshot.
    const root = shell();
    root.detected("niri");
    root.niriLink(true);
    root.niriEvent({ WindowsChanged: { windows: [] } });
    assert.equal(root.focusReady, true, "no windows is an answer, not a wait");
    assert.equal(root.focusedAppId(), "", "and the answer is that nothing is focused");
});
test("a single-window event is not the snapshot", () => {
    // An individual window event cannot substitute for the full snapshot.
    const root = shell();
    root.detected("niri");
    root.niriLink(true);
    root.niriEvent({ WindowOpenedOrChanged: { window: kitty } });
    assert.equal(root.NiriService.windows.length, 1, "the event was dispatched and the window recorded");
    assert.equal(root.focusReady, false, "a single-window event is not the snapshot");
});
test("the toplevel path is ready once the source is named", () => {
    // Quickshell exposes no initial-list signal for the toplevel path. An empty list there resolves as no focus.
    const root = shell();
    root.construct();
    root.detected("hyprland");
    assert.equal(root.focusReady, true, "naming the source is what makes the toplevel path ready");
    assert.equal(root.focusedAppId(), "", "and its answer is that nothing is focused");
    assert.equal(root.lastFocusedAppId(), "", "with nothing remembered either");
});
test("an empty Hyprland or unknown session is ready with no target", () => {
    // An empty Hyprland seat must remain ready even though it has never exposed a toplevel.
    for (const compositor of ["hyprland", "unknown"]) {
        const empty = shell({ ToplevelManager: { activeToplevel: null, toplevels: { values: [] } } });
        empty.construct();
        empty.detected(compositor);
        assert.equal(empty.focusReady, true, `an empty ${compositor} session is ready, not waiting`);
        assert.equal(empty.focusedAppId(), "", "it resolves no target");
        assert.equal(empty.lastFocusedAppId(), "", "and no remembered one");
    }
});
test("a Hyprland session with a focused toplevel is ready and names it", () => {

    const toplevel = { appId: "foot" };
    const root = shell({ ToplevelManager: { activeToplevel: toplevel, toplevels: { values: [toplevel] } } });
    root.construct();
    root.detected("hyprland");
    assert.equal(root.focusReady, true, "ready");
    assert.equal(root.focusedAppId(), "foot", "and it names the focused window");
});
test("failed detection is ready on the toplevel path", () => {
    // Failed detection follows the service's toplevel fallback decision.
    const toplevel = { appId: "foot" };
    const root = shell({ ToplevelManager: { activeToplevel: toplevel, toplevels: { values: [toplevel] } } });
    root.detected("unknown");
    assert.equal(root.focusReady, true, "ready on the same terms as Hyprland");
    assert.equal(root.focusedAppId(), "foot", "resolving through the toplevel path");
});
test("Niri waits for its snapshot while the toplevel path does not", () => {
    // Niri can distinguish an empty snapshot from silence, so it uses the stricter readiness check.
    const niri = shell();
    niri.detected("niri");
    assert.equal(niri.focusReady, false, "Niri waits, because it can tell the difference");
    const hyprland = shell();
    hyprland.detected("hyprland");
    assert.equal(hyprland.focusReady, true, "the toplevel path does not, because it cannot");
});
test("nothing is ready while detection is pending, whatever data is present", () => {

    const toplevel = { appId: "foot" };
    const root = shell({
        NiriService: { windows: [foot], eventStreamUp: true, windowsSnapshotReceived: true },
        ToplevelManager: { activeToplevel: toplevel, toplevels: { values: [toplevel] } },
    });
    assert.equal(root.focusSource, "pending", "detection has not answered");
    assert.equal(root.focusReady, false, "so nothing is ready, however much data is lying around");
});

test("failed detection resolves the toplevel fallback and never a dead window", () => {
    // Failed detection resolves through the declared toplevel fallback rather than waiting for another answer.
    const toplevel = { appId: "foot" };
    const root = shell({
        _lastFocusedToplevel: toplevel,
        ToplevelManager: { activeToplevel: toplevel, toplevels: { values: [toplevel] } },
    });
    root.detected("unknown");
    assert.equal(root.focusedAppId(), "foot", "a failed detection still resolves the active toplevel");
    assert.equal(root.lastFocusedAppId(), "foot", "and the remembered window with it");

    // The fallback can be absent but must never name a dead window.
    root.ToplevelManager.toplevels.values = [];
    assert.equal(root.lastFocusedAppId(), "", "a closed window is not a target on this path either");
});
test("failed detection does not consult Niri's list", () => {
    // Failed detection must not consult Niri's list; that service connects only after positive Niri detection.
    const root = shell({ NiriService: { windows: [foot] } });
    root.detected("unknown");
    assert.equal(root.focusedAppId(), "", "a failed detection resolves no Niri window");
    assert.equal(root.lastFocusedAppId(), "", "not even a remembered one");
});

test("Niri focus bookkeeping runs only on Niri and refreshes the toplevel list", () => {

    const root = shell({ NiriService: { windows: [foot] } });
    root.windowsChanged();
    assert.equal(root._lastFocusedNiriWindowId, null, "Hyprland does not run the Niri focus bookkeeping");
    assert.deepEqual(root.calls, [], "and does not refresh off Niri's events");
    root.isNiri = true;
    root.windowsChanged();
    assert.equal(root._lastFocusedNiriWindowId, foot.id, "every Niri window change updates the remembered focus");
    assert.deepEqual(root.calls, ["refreshToplevels"], "and refreshes the toplevel list");
});
test("extracted handlers assign on the component, not the global scope", () => {
    // with assigns to an object only for an existing property. Assert against accidental global writes.
    const root = shell();
    root.construct();
    root.detected("niri");
    for (const name of ["isNiri", "isHyprland", "compositor", "compositorDetected"])
        assert.ok(!(name in globalThis), `${name} must be assigned on the component, not leaked to the global scope`);
    assert.equal(root.compositor, "niri", "the model's component actually received the assignment");
});
