#!/usr/bin/env node

// Execute the extracted Hyprland per-screen workspace filters the bar runs: the switch list
// BarContent scrolls through and the row WorkspaceSwitcher draws. Quickshell tracks
// HyprlandWorkspace.monitor from the event stream and rewrites lastIpcObject only on an explicit
// fetch, so the two disagree about which screen a moved workspace sits on until something
// refetches. This models reported Hyprland state; it does not verify a live compositor.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
// Use the shared comment-aware and string-aware brace reader to prevent truncated extraction.
const { extractBlock, callInScope } = require("./lib/qml-block.js");

const BAR_QML = path.join(__dirname, "..", "quickshell", "vshell", "Modules", "Bar", "BarContent.qml");
const SWITCHER_QML = path.join(__dirname, "..", "quickshell", "vshell", "Modules", "Bar", "Widgets", "WorkspaceSwitcher.qml");
const barSource = fs.readFileSync(BAR_QML, "utf8");
const switcherSource = fs.readFileSync(SWITCHER_QML, "utf8");

const bodies = {
    bar: extractBlock(barSource, "function getRealWorkspaces()"),
    switcher: extractBlock(switcherSource, "function getHyprlandWorkspaces()"),
    order: extractBlock(switcherSource, "function hyprlandWorkspaceOrder(a, b)"),
};

test("the extracted filters read the state this model supplies", () => {
    for (const [label, text, needles] of [
        ["getRealWorkspaces", bodies.bar, ["CompositorService.isHyprland", "Hyprland.workspaces", "_barScreenName", "SettingsData.workspaceFollowFocus"]],
        ["getHyprlandWorkspaces", bodies.switcher, ["Hyprland.workspaces", "root.screenName", "SettingsData.workspaceFollowFocus"]],
    ]) {
        for (const needle of needles)
            assert.ok(text.includes(needle), `the extracted ${label} must contain ${needle}`);
    }
});

// One Hyprland workspace whose live monitor and last-fetched monitor can disagree. `monitor` is
// what Quickshell tracks from the event stream and nulls when a monitor is removed; lastIpcObject
// holds whatever the last j/workspaces fetch wrote.
function workspace(id, name, live, fetched) {
    return { id, name, monitor: live === null ? null : { name: live }, lastIpcObject: { monitor: fetched } };
}

// A two-monitor desktop after the user moved workspace 2 from DP-1 to DP-2 with no refetch since.
const WORLD = [
    workspace(1, "1", "DP-1", "DP-1"),
    workspace(2, "2", "DP-2", "DP-1"),
    workspace(3, "3", "DP-2", "DP-2"),
    // Quickshell nulls the binding when a monitor is removed, leaving the fetched name behind.
    workspace(4, "4", null, "DP-1"),
    // A special workspace is never a row on any screen.
    workspace(-99, "special:term", "DP-1", "DP-1"),
];

function bar(workspaces, screenName, followFocus = false) {
    const scope = {
        CompositorService: { isNiri: false, isHyprland: true, isMango: false, isSway: false, isScroll: false, isMiracle: false },
        SettingsData: { workspaceFollowFocus: followFocus },
        Hyprland: { workspaces: { values: workspaces } },
    };
    return callInScope(bodies.bar, { _barScreenName: screenName }, scope);
}

function switcher(workspaces, screenName, followFocus = false) {
    const scope = {
        SettingsData: { workspaceFollowFocus: followFocus, showOccupiedWorkspacesOnly: false },
        Hyprland: { workspaces: { values: workspaces }, toplevels: { values: [] } },
    };
    const component = { screenName, currentWorkspace: 1 };
    component.hyprlandWorkspaceOrder = (a, b) => callInScope(bodies.order, component, scope, ["a", "b"], [a, b]);
    return callInScope(bodies.switcher, component, scope);
}

const FILTERS = [["the bar's switch list", bar], ["the bar's workspace row", switcher]];

const ids = list => list.map(ws => ws.id);

test("a workspace moved between monitors changes screens before the next fetch", () => {
    for (const [label, run] of FILTERS) {
        assert.deepEqual(ids(run(WORLD, "DP-1")), [1],
            `${label}: the moved workspace must leave its old screen without waiting for a refetch`);
        assert.deepEqual(ids(run(WORLD, "DP-2")), [2, 3],
            `${label}: the moved workspace must reach its new screen without waiting for a refetch`);
    }
});

test("a workspace with no monitor and a special workspace are on no screen", () => {
    for (const [label, run] of FILTERS) {
        for (const screen of ["DP-1", "DP-2"]) {
            const shown = ids(run(WORLD, screen));
            assert.ok(!shown.includes(4), `${label}: a workspace whose monitor was removed must not sit on ${screen}`);
            assert.ok(!shown.includes(-99), `${label}: a special workspace must not sit on ${screen}`);
        }
    }
});

test("a screen with no workspaces of its own falls back to one placeholder", () => {
    for (const [label, run] of FILTERS)
        assert.deepEqual(ids(run(WORLD, "DP-3")), [1],
            `${label}: an empty screen draws one placeholder rather than another screen's workspaces`);
});

test("following focus ignores the screen entirely", () => {
    // The inverse of the per-screen branch: with follow-focus on, or before the bar knows its
    // screen, every ordinary workspace is listed wherever its monitor says it lives.
    for (const [label, run] of FILTERS) {
        assert.deepEqual(ids(run(WORLD, "DP-1", true)).filter(id => id > 0), [1, 2, 3, 4],
            `${label}: follow-focus lists every ordinary workspace, not one screen's`);
        assert.deepEqual(ids(run(WORLD, "", false)).filter(id => id > 0), [1, 2, 3, 4],
            `${label}: an unknown screen lists every ordinary workspace`);
    }
});

test("the extracted filters assign on the component, not the global scope", () => {
    for (const [, run] of FILTERS)
        run(WORLD, "DP-1");
    for (const name of ["screenName", "workspaces", "monitorWorkspaces", "filtered", "fallbackWorkspaces", "hyprlandToplevels", "activeWsId"])
        assert.ok(!(name in globalThis), `${name} must not leak to the global scope`);
});
