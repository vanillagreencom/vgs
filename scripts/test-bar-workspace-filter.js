#!/usr/bin/env node

// Execute the extracted Hyprland workspace list the bar runs, through both of its call sites: the
// switch list BarContent scrolls through and the row WorkspaceSwitcher draws. Both must answer
// with the same workspaces, resolve the same active workspace, and dispatch the same target, so a
// scroll cannot land on a workspace the row never drew. Quickshell tracks
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

const qmlPath = (...parts) => path.join(__dirname, "..", "quickshell", "vshell", ...parts);
const serviceSource = fs.readFileSync(qmlPath("Services", "CompositorService.qml"), "utf8");
const barSource = fs.readFileSync(qmlPath("Modules", "Bar", "BarContent.qml"), "utf8");
const switcherSource = fs.readFileSync(qmlPath("Modules", "Bar", "Widgets", "WorkspaceSwitcher.qml"), "utf8");

const SHARED_LIST_CALL = "CompositorService.hyprlandWorkspacesForScreen(";
const SHARED_ACTIVE_CALL = "CompositorService.hyprlandActiveWorkspaceId(";

// Every CompositorService function the two call sites reach, with its parameter names.
const SERVICE_FUNCTIONS = [
    ["function hyprlandWorkspacesForScreen(screenName, followFocus, occupiedOnly)", ["screenName", "followFocus", "occupiedOnly"]],
    ["function _hyprlandWorkspaceIsSpecial(ws)", ["ws"]],
    ["function _hyprlandWorkspacePlaceholder()", []],
    ["function hyprlandWorkspaceOrder(a, b)", ["a", "b"]],
    ["function hyprlandActiveWorkspaceId(screenName, followFocus)", ["screenName", "followFocus"]],
    ["function hyprlandWorkspaceSelector(ws)", ["ws"]],
];

const bodies = {
    barList: extractBlock(barSource, "function getRealWorkspaces()"),
    barCurrent: extractBlock(barSource, "function getCurrentWorkspace()"),
    barScroll: extractBlock(barSource, "function switchWorkspace(direction)"),
    rowList: extractBlock(switcherSource, "property var workspaceList:"),
    rowCurrent: extractBlock(switcherSource, "property var currentWorkspace:"),
    rowRealList: extractBlock(switcherSource, "function getRealWorkspaces()"),
    rowScroll: extractBlock(switcherSource, "function switchWorkspace(direction)"),
    rowClick: extractBlock(switcherSource, "function switchToWorkspaceByModelData(data)"),
    rowPadding: extractBlock(switcherSource, "function _makePlaceholder()"),
    rowLabel: extractBlock(switcherSource, "function getWorkspaceIndex(modelData, index)"),
    rowLabelFallback: extractBlock(switcherSource, "function getWorkspaceIndexFallback(modelData, index)"),
    drawnIsActive: extractBlock(switcherSource, "property bool isActive:"),
    drawnIsPlaceholder: extractBlock(switcherSource, "property bool isPlaceholder:"),
};

// One Hyprland workspace whose live monitor and last-fetched monitor can disagree. `monitor` is
// what Quickshell tracks from the event stream and nulls when a monitor is removed; lastIpcObject
// holds whatever the last j/workspaces fetch wrote.
function workspace(id, name, live, fetched) {
    return { id, name, monitor: live === null ? null : { name: live }, lastIpcObject: { monitor: fetched } };
}

// A two-monitor desktop after the user moved workspace 12 from DP-1 to DP-2 with no refetch since.
// No workspace here carries id 1, which is the id the list gives its empty-screen placeholder: a
// row expecting the placeholder must not be satisfiable by a real workspace. Only 11 and 13 hold a
// window, so every workspace a screen reports as active is empty and the occupied-only exemption
// for the active workspace is the only thing that can keep it.
const WORKSPACES = [
    workspace(11, "11", "DP-1", "DP-1"),
    workspace(12, "12", "DP-2", "DP-1"),
    workspace(13, "13", "DP-2", "DP-2"),
    // Quickshell nulls the binding when a monitor is removed, leaving the fetched name behind.
    workspace(14, "14", null, "DP-1"),
    // Hyprland gives an ordinary named workspace a negative id, which does not make it special.
    // Id -1 is also the id the row's padding carries, so a real workspace holds it here.
    workspace(-1, "notes", "DP-1", "DP-1"),
    workspace(-3, "scratch", "DP-1", "DP-1"),
    // A special workspace carries the "special:" name prefix and is never a row on any screen.
    workspace(-99, "special:term", "DP-1", "DP-1"),
];

const TOPLEVELS = [{ workspace: { id: 11 } }, { workspace: { id: 13 } }];
// Each screen reports its own active workspace, and the focused one is neither of them, so the
// per-screen answer and the follow-focus answer can never be confused for each other. DP-1 is
// active on the named workspace at id -1, the id the row's padding also carries, so a drawn marker
// that reads the id alone cannot tell the two apart.
const MONITORS = [
    { name: "DP-1", activeWorkspace: { id: -1 } },
    { name: "DP-2", activeWorkspace: { id: 12 } },
];
const FOCUSED_WORKSPACE = { id: 14 };

function hyprlandScope() {
    return {
        Hyprland: {
            workspaces: { values: WORKSPACES },
            toplevels: { values: TOPLEVELS },
            monitors: { values: MONITORS },
            focusedWorkspace: FOCUSED_WORKSPACE,
        },
        NiriService: {},
        MangoService: {},
    };
}

// The CompositorService singleton, with every body the shared answers reach bound on it the way
// unqualified lookup reaches them in QML.
function compositorService() {
    const scope = hyprlandScope();
    const singleton = {
        isNiri: false,
        isHyprland: true,
        isMango: false,
        isSway: false,
        isScroll: false,
        isMiracle: false,
        compositor: "hyprland",
    };
    for (const [opener, parameters] of SERVICE_FUNCTIONS) {
        const body = extractBlock(serviceSource, opener);
        const name = opener.slice("function ".length, opener.indexOf("("));
        singleton[name] = (...args) => callInScope(body, singleton, scope, parameters, args);
    }
    return singleton;
}

function settings(followFocus, occupiedOnly, showWorkspacePadding = false) {
    return {
        workspaceFollowFocus: followFocus,
        showOccupiedWorkspacesOnly: occupiedOnly,
        showWorkspacePadding,
        showWorkspaceApps: false,
        showWorkspaceName: false,
        showWorkspaceIndex: false,
    };
}

// The bar background: its switch list, its current-workspace answer and its scroll handler, with
// a stand-in HyprlandService that records what the scroll dispatches.
function barSite(screenName, followFocus, occupiedOnly) {
    const dispatched = [];
    const scope = {
        CompositorService: compositorService(),
        SettingsData: settings(followFocus, occupiedOnly),
        HyprlandService: { focusWorkspace: target => dispatched.push(target) },
        NiriService: {},
        MangoService: {},
    };
    const component = { _barScreenName: screenName };
    component.getRealWorkspaces = () => callInScope(bodies.barList, component, scope);
    component.getCurrentWorkspace = () => callInScope(bodies.barCurrent, component, scope);
    component.switchWorkspace = direction => callInScope(bodies.barScroll, component, scope, ["direction"], [direction]);
    return { component, dispatched };
}

// The drawn workspace row: the list it draws, the list its own scroll walks, its current-workspace
// answer, its scroll handler and its click handler. `extraEntries` appends to the drawn list, for
// the padding the row mints when it has fewer entries than slots.
function rowSite(screenName, followFocus, occupiedOnly, extraEntries = []) {
    const dispatched = [];
    const scope = {
        CompositorService: compositorService(),
        SettingsData: settings(followFocus, occupiedOnly),
        HyprlandService: { focusWorkspace: target => dispatched.push(target) },
        NiriService: {},
        MangoService: {},
    };
    const component = { screenName, useExtWorkspace: false, isMango: false, mangoOverviewActive: false, isVertical: false, dwlActiveTags: [] };
    component._makePlaceholder = () => callInScope(bodies.rowPadding, component, scope);
    component.workspaceList = callInScope(bodies.rowList, component, scope).concat(extraEntries);
    component.currentWorkspace = callInScope(bodies.rowCurrent, component, scope);
    component.getRealWorkspaces = () => callInScope(bodies.rowRealList, component, scope);
    component.switchWorkspace = direction => callInScope(bodies.rowScroll, component, scope, ["direction"], [direction]);
    component.switchToWorkspaceByModelData = data => callInScope(bodies.rowClick, component, scope, ["data"], [data]);
    component.getWorkspaceIndexFallback = (modelData, index) => callInScope(bodies.rowLabelFallback, component, scope, ["modelData", "index"], [modelData, index]);
    // What the row draws for one entry. The delegate reads its own `modelData` and the widget's
    // state by bare name, so the entry joins the component the bodies already resolve against.
    component.drawn = (modelData, index) => {
        const view = Object.assign(Object.create(null), component, { modelData });
        return {
            isActive: callInScope(bodies.drawnIsActive, view, scope),
            isPlaceholder: callInScope(bodies.drawnIsPlaceholder, view, scope),
            label: callInScope(bodies.rowLabel, view, scope, ["modelData", "index"], [modelData, index]),
        };
    };
    return { component, dispatched };
}

const ids = list => Array.from(list).map(ws => ws.id);

// screen name, follow focus, occupied only, the ids the list must answer with, the workspace both
// call sites must treat as current.
const LIST_ROWS = [
    ["a screen keeps the workspaces its monitor property names", "DP-1", false, false, [11, -1, -3], -1],
    ["a workspace moved between monitors reaches its new screen before the next fetch", "DP-2", false, false, [12, 13], 12],
    ["a screen with no workspaces of its own falls back to one placeholder", "DP-3", false, false, [1], 14],
    ["following focus ignores the screen entirely", "DP-1", true, false, [11, 12, 13, 14, -1, -3], 14],
    ["an unknown screen lists every ordinary workspace", "", false, false, [11, 12, 13, 14, -1, -3], 14],
    ["occupied-only keeps an empty active workspace even when it is a named one", "DP-1", false, true, [11, -1], -1],
    ["occupied-only keeps an empty active workspace and drops an empty idle one", "DP-2", false, true, [12, 13], 12],
    ["occupied-only under follow-focus keeps the focused workspace, empty or not", "DP-1", true, true, [11, 13, 14], 14],
];

test("the extracted call sites both delegate to the shared answers", () => {
    for (const [label, listBody, currentBody] of [
        ["BarContent", bodies.barList, bodies.barCurrent],
        ["WorkspaceSwitcher", bodies.rowList, bodies.rowCurrent],
    ]) {
        assert.ok(listBody.includes(SHARED_LIST_CALL), `${label}'s list must call ${SHARED_LIST_CALL}`);
        assert.ok(listBody.includes("SettingsData.showOccupiedWorkspacesOnly"),
            `${label}'s list must pass the occupied-only setting to the shared list`);
        assert.ok(currentBody.includes(SHARED_ACTIVE_CALL), `${label}'s current workspace must call ${SHARED_ACTIVE_CALL}`);
    }
});

test("both call sites answer with the same workspaces", () => {
    for (const [label, screenName, followFocus, occupiedOnly, expected] of LIST_ROWS) {
        assert.deepEqual(ids(barSite(screenName, followFocus, occupiedOnly).component.getRealWorkspaces()), expected,
            `the bar's switch list: ${label}`);
        assert.deepEqual(ids(rowSite(screenName, followFocus, occupiedOnly).component.workspaceList), expected,
            `the bar's workspace row: ${label}`);
    }
});

test("both call sites treat the same workspace as current", () => {
    for (const [label, screenName, followFocus, occupiedOnly, , expectedCurrent] of LIST_ROWS) {
        assert.equal(barSite(screenName, followFocus, occupiedOnly).component.getCurrentWorkspace(), expectedCurrent,
            `the bar's switch list: ${label}`);
        assert.equal(rowSite(screenName, followFocus, occupiedOnly).component.currentWorkspace, expectedCurrent,
            `the bar's workspace row: ${label}`);
    }
});

// screen name, follow focus, occupied only, scroll direction, what the scroll must dispatch.
// `null` means the scroll must dispatch nothing.
const SCROLL_ROWS = [
    ["scrolling onto a named workspace dispatches its name, which is its only reachable target", "DP-1", false, false, 1, "name:scratch"],
    ["scrolling off a named active workspace onto a numbered one dispatches its id", "DP-1", false, false, -1, 11],
    ["scrolling back from an empty focused workspace steps to its neighbour in the drawn list", "DP-1", true, true, -1, 13],
    ["scrolling back from the first workspace dispatches nothing", "DP-2", false, false, -1, null],
];

test("both call sites dispatch the same scroll target", () => {
    for (const [label, screenName, followFocus, occupiedOnly, direction, expected] of SCROLL_ROWS)
        for (const [site, build] of [["the bar's background scroll", barSite], ["the workspace row's scroll", rowSite]]) {
            const { component, dispatched } = build(screenName, followFocus, occupiedOnly);
            component.switchWorkspace(direction);
            assert.deepEqual(dispatched, expected === null ? [] : [expected], `${site}: ${label}`);
        }
});

test("clicking a drawn workspace dispatches it, and clicking padding dispatches nothing", () => {
    const { component, dispatched } = rowSite("DP-1", false, false);
    component.switchToWorkspaceByModelData(component.workspaceList.find(ws => ws.id === -1));
    assert.deepEqual(dispatched, ["name:notes"], "a named workspace at id -1 is a real click target");
    component.switchToWorkspaceByModelData(component._makePlaceholder());
    assert.deepEqual(dispatched, ["name:notes"], "padding is not a click target and adds no dispatch");
});

test("padding is marked out of band, so a real workspace at id -1 survives the row's scroll list", () => {
    const padded = rowSite("DP-1", false, false);
    const padding = padded.component._makePlaceholder();
    assert.equal(padding._placeholder, true, "the row's Hyprland padding must carry the out-of-band marker");
    const withPadding = rowSite("DP-1", false, false, [padding]);
    assert.deepEqual(ids(withPadding.component.workspaceList), [11, -1, -3, -1], "the drawn list holds the padding beside the named workspace");
    assert.deepEqual(ids(withPadding.component.getRealWorkspaces()), [11, -1, -3], "the row's own scroll list drops the padding and keeps the named workspace");
});

test("the row draws a real workspace at id -1 as itself and its padding as an empty slot", () => {
    // DP-1 is active on the named workspace at id -1, so every marker that reads the id alone
    // gives the padding the drawn workspace's answer.
    const site = rowSite("DP-1", false, false);
    const named = site.component.workspaceList.find(ws => ws.id === -1);
    const padding = site.component._makePlaceholder();
    assert.equal(site.component.currentWorkspace, -1, "the fixture must leave DP-1 active on the named workspace");

    const drawnNamed = site.component.drawn(named, 4);
    assert.equal(drawnNamed.isPlaceholder, false, "a real workspace at id -1 is not padding");
    assert.equal(drawnNamed.isActive, true, "the workspace the screen is active on is drawn as active");
    assert.equal(drawnNamed.label, "notes", "a real workspace is labelled by its own name, not by its slot");

    const drawnPadding = site.component.drawn(padding, 4);
    assert.equal(drawnPadding.isPlaceholder, true, "padding is drawn as padding");
    assert.equal(drawnPadding.isActive, false, "padding is never the active workspace, whatever id it carries");
    assert.equal(drawnPadding.label, 5, "padding is labelled by its slot");
});

test("a special workspace is judged by its name, not by its negative id", () => {
    const singleton = compositorService();
    for (const [name, isSpecial] of [["special", true], ["special:term", true], ["scratch", false], ["11", false]])
        assert.equal(singleton._hyprlandWorkspaceIsSpecial({ id: -3, name }), isSpecial,
            `a workspace named ${JSON.stringify(name)} with a negative id`);
});

test("the extracted bodies assign on the component, not the global scope", () => {
    for (const build of [barSite, rowSite]) {
        const site = build("DP-1", false, true);
        site.component.switchWorkspace(1);
    }
    for (const name of ["screenName", "workspaces", "ordinary", "perScreen", "scoped", "ordered", "toplevels", "activeWsId", "mon",
        "baseList", "fallbackWorkspaces", "realWorkspaces", "currentWs", "currentIndex", "validIndex", "nextIndex", "activeTags"])
        assert.ok(!(name in globalThis), `${name} must not leak to the global scope`);
});
