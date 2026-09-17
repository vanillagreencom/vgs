#!/usr/bin/env node

// Execute the extracted Hyprland per-screen workspace list the bar runs, through both of its call
// sites: the switch list BarContent scrolls through and the row WorkspaceSwitcher draws. Both must
// answer with the same workspaces, so a scroll cannot land on a workspace the row never drew.
// Quickshell tracks HyprlandWorkspace.monitor from the event stream and rewrites lastIpcObject
// only on an explicit fetch, so the two disagree about which screen a moved workspace sits on
// until something refetches. This models reported Hyprland state; it does not verify a live
// compositor.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
// Use the shared comment-aware and string-aware brace reader to prevent truncated extraction.
const { extractBlock, callInScope } = require("./lib/qml-block.js");

const qmlPath = (...parts) => path.join(__dirname, "..", "quickshell", "vshell", ...parts);
const serviceSource = fs.readFileSync(qmlPath("Services", "CompositorService.qml"), "utf8");
const barSource = fs.readFileSync(qmlPath("Modules", "Bar", "BarContent.qml"), "utf8");
const switcherSource = fs.readFileSync(qmlPath("Modules", "Bar", "Widgets", "WorkspaceSwitcher.qml"), "utf8");

const SHARED_CALL = "CompositorService.hyprlandWorkspacesForScreen(";

const bodies = {
    shared: extractBlock(serviceSource, "function hyprlandWorkspacesForScreen(screenName, followFocus, occupiedOnly)"),
    isSpecial: extractBlock(serviceSource, "function _hyprlandWorkspaceIsSpecial(ws)"),
    placeholder: extractBlock(serviceSource, "function _hyprlandWorkspacePlaceholder()"),
    order: extractBlock(serviceSource, "function hyprlandWorkspaceOrder(a, b)"),
    activeForScreen: extractBlock(serviceSource, "function _activeWorkspaceIdForScreen(screenName)"),
    bar: extractBlock(barSource, "function getRealWorkspaces()"),
    switcher: extractBlock(switcherSource, "property var workspaceList:"),
};

// One Hyprland workspace whose live monitor and last-fetched monitor can disagree. `monitor` is
// what Quickshell tracks from the event stream and nulls when a monitor is removed; lastIpcObject
// holds whatever the last j/workspaces fetch wrote.
function workspace(id, name, live, fetched) {
    return { id, name, monitor: live === null ? null : { name: live }, lastIpcObject: { monitor: fetched } };
}

// A two-monitor desktop after the user moved workspace 12 from DP-1 to DP-2 with no refetch since.
// No workspace here carries id 1, which is the id the list gives its empty-screen placeholder: a
// row expecting the placeholder must not be satisfiable by a real workspace. Workspaces 11 and 13
// hold a window; 12, 14 and the named workspace are empty.
const WORKSPACES = [
    workspace(11, "11", "DP-1", "DP-1"),
    workspace(12, "12", "DP-2", "DP-1"),
    workspace(13, "13", "DP-2", "DP-2"),
    // Quickshell nulls the binding when a monitor is removed, leaving the fetched name behind.
    workspace(14, "14", null, "DP-1"),
    // Hyprland gives an ordinary named workspace a negative id, which does not make it special.
    workspace(-3, "scratch", "DP-1", "DP-1"),
    // A special workspace carries the "special:" name prefix and is never a row on any screen.
    workspace(-99, "special:term", "DP-1", "DP-1"),
];

const TOPLEVELS = [{ workspace: { id: 11 } }, { workspace: { id: 13 } }];
const MONITORS = [
    { name: "DP-1", activeWorkspace: { id: 11 } },
    { name: "DP-2", activeWorkspace: { id: 13 } },
];

function hyprlandScope() {
    return {
        Hyprland: {
            workspaces: { values: WORKSPACES },
            toplevels: { values: TOPLEVELS },
            monitors: { values: MONITORS },
            focusedWorkspace: { id: 11 },
        },
        NiriService: {},
    };
}

// The CompositorService singleton, with every body the shared list reaches bound on it the way
// unqualified lookup reaches them in QML.
function compositorService() {
    const scope = hyprlandScope();
    const service = {
        isNiri: false,
        isHyprland: true,
        isMango: false,
        isSway: false,
        isScroll: false,
        isMiracle: false,
        compositor: "hyprland",
    };
    for (const [name, body, parameters] of [
        ["_hyprlandWorkspaceIsSpecial", bodies.isSpecial, ["ws"]],
        ["_hyprlandWorkspacePlaceholder", bodies.placeholder, []],
        ["hyprlandWorkspaceOrder", bodies.order, ["a", "b"]],
        ["_activeWorkspaceIdForScreen", bodies.activeForScreen, ["screenName"]],
        ["hyprlandWorkspacesForScreen", bodies.shared, ["screenName", "followFocus", "occupiedOnly"]],
    ])
        service[name] = (...args) => callInScope(body, service, scope, parameters, args);
    return service;
}

function settings(followFocus, occupiedOnly) {
    return { workspaceFollowFocus: followFocus, showOccupiedWorkspacesOnly: occupiedOnly, showWorkspacePadding: false };
}

function bar(screenName, followFocus, occupiedOnly) {
    const scope = { CompositorService: compositorService(), SettingsData: settings(followFocus, occupiedOnly) };
    return callInScope(bodies.bar, { _barScreenName: screenName }, scope);
}

function switcher(screenName, followFocus, occupiedOnly) {
    const scope = { CompositorService: compositorService(), SettingsData: settings(followFocus, occupiedOnly) };
    return callInScope(bodies.switcher, { screenName, useExtWorkspace: false, mangoOverviewActive: false }, scope);
}

const CALL_SITES = [["the bar's switch list", bar], ["the bar's workspace row", switcher]];

const ids = list => Array.from(list).map(ws => ws.id);

// screen name, follow focus, occupied only, the ids the shared list must answer with.
const ROWS = [
    ["a screen keeps the workspaces its monitor property names", "DP-1", false, false, [11, -3]],
    ["a workspace moved between monitors reaches its new screen before the next fetch", "DP-2", false, false, [12, 13]],
    ["a screen with no workspaces of its own falls back to one placeholder", "DP-3", false, false, [1]],
    ["following focus ignores the screen entirely", "DP-1", true, false, [11, 12, 13, 14, -3]],
    ["an unknown screen lists every ordinary workspace", "", false, false, [11, 12, 13, 14, -3]],
    ["occupied-only keeps the active workspace and the ones holding a window", "DP-1", false, true, [11]],
    ["occupied-only drops an empty workspace on the other screen", "DP-2", false, true, [13]],
    ["occupied-only under follow-focus scores every screen's workspaces", "DP-1", true, true, [11, 13]],
];

test("the extracted call sites both delegate to the shared list", () => {
    for (const [label, text] of [["BarContent.getRealWorkspaces", bodies.bar], ["WorkspaceSwitcher.workspaceList", bodies.switcher]]) {
        assert.ok(text.includes(SHARED_CALL), `the extracted ${label} must call ${SHARED_CALL}`);
        assert.ok(text.includes("SettingsData.showOccupiedWorkspacesOnly"),
            `the extracted ${label} must pass the occupied-only setting to the shared list`);
    }
});

test("both call sites answer with the same workspaces", () => {
    for (const [label, screenName, followFocus, occupiedOnly, expected] of ROWS)
        for (const [site, run] of CALL_SITES)
            assert.deepEqual(ids(run(screenName, followFocus, occupiedOnly)), expected, `${site}: ${label}`);
});

test("a special workspace is judged by its name, not by its negative id", () => {
    const service = compositorService();
    for (const [name, isSpecial] of [["special", true], ["special:term", true], ["scratch", false], ["11", false]])
        assert.equal(service._hyprlandWorkspaceIsSpecial({ id: -3, name }), isSpecial,
            `a workspace named ${JSON.stringify(name)} with a negative id`);
});

test("a named workspace is dispatched by name and a numbered one by id", () => {
    const selector = extractBlock(serviceSource, "function hyprlandWorkspaceSelector(ws)");
    const run = ws => callInScope(selector, compositorService(), hyprlandScope(), ["ws"], [ws]);
    assert.equal(run({ id: 11, name: "11" }), 11, "a numbered workspace is reachable by its id");
    assert.equal(run({ id: -3, name: "scratch" }), "name:scratch", "a named workspace is reachable by its name only");
    assert.equal(run(null), 1, "a missing workspace falls back to the first one");
});

test("the extracted bodies assign on the component, not the global scope", () => {
    for (const [, run] of CALL_SITES)
        run("DP-1", false, true);
    for (const name of ["screenName", "workspaces", "ordinary", "perScreen", "scoped", "ordered", "toplevels", "activeWsId", "baseList", "fallbackWorkspaces", "mon"])
        assert.ok(!(name in globalThis), `${name} must not leak to the global scope`);
});
