#!/usr/bin/env node

// Execute the extracted overview refetch producers in OverviewWidget.
// HyprlandToplevel carries no geometry or class property, so every tile's rectangle and icon
// comes from lastIpcObject, which only Hyprland.refreshToplevels() fills. CompositorService
// issues no such fetch, so the overview is the producer for its own data while it is open.
// This models the shipped handlers; it does not verify a live Hyprland's event contract.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
// Use the shared comment-aware and string-aware brace reader to prevent truncated extraction.
const { extractBlock, callInScope } = require("./lib/qml-block.js");

const QML = path.join(__dirname, "..", "quickshell", "vshell", "Modules", "WorkspaceOverlays", "OverviewWidget.qml");
const source = fs.readFileSync(QML, "utf8");

// The fields the overview reads out of lastIpcObject, and nothing else carries them.
const WINDOW_QML = path.join(__dirname, "..", "quickshell", "vshell", "Modules", "WorkspaceOverlays", "OverviewWindow.qml");
const windowSource = fs.readFileSync(WINDOW_QML, "utf8");
// The Loader that decides whether this widget can exist while the overview is closed.
const OVERVIEW_QML = path.join(__dirname, "..", "quickshell", "vshell", "Modules", "WorkspaceOverlays", "HyprlandOverview.qml");
const overviewSource = fs.readFileSync(OVERVIEW_QML, "utf8");

const bodies = {
    refetch: extractBlock(source, "function refetchOverviewState()"),
    toplevelsChanged: extractBlock(source, "function onToplevelsChanged()"),
    dragRelease: extractBlock(source, "onReleased:"),
};

const SUBSCRIPTION = extractBlock(source, "Connections {", source.indexOf("function onToplevelsChanged()") - 400);

test("the overview reads its geometry and class from lastIpcObject alone", () => {
    // If a dedicated property ever carries these, the producer below stops being load-bearing.
    assert.ok(windowSource.includes("readonly property var windowData: toplevel?.lastIpcObject"),
        "OverviewWindow must still derive windowData from lastIpcObject");
    for (const read of ["windowData?.at?.[0]", "windowData?.size?.[0]", "windowData?.class"])
        assert.ok(windowSource.includes(read), `OverviewWindow must still read ${read}`);
    assert.ok(source.includes("windowData.address"), "OverviewWidget must still click through windowData.address");
});

test("the refetch subscription is armed only while the overview is on screen", () => {
    for (const needle of ["target: root.overviewOpen ? CompositorService : null", "enabled: root.overviewOpen", "function onToplevelsChanged()"])
        assert.ok(SUBSCRIPTION.includes(needle), `the refetch Connections must contain ${needle}`);
});

// with models QML's unqualified component lookup without rewriting the extracted handler bodies.
function widget() {
    const root = { calls: [], overviewOpen: true };
    root.refetchOverviewState = () => callInScope(bodies.refetch, root, scope);
    const scope = {
        Hyprland: {
            refreshToplevels: () => root.calls.push("refreshToplevels"),
            refreshWorkspaces: () => root.calls.push("refreshWorkspaces"),
            refreshMonitors: () => root.calls.push("refreshMonitors"),
        },
    };
    root.run = (name) => {
        root.calls.length = 0;
        callInScope(bodies[name], root, scope);
        return root.calls;
    };
    return root;
}

const FETCHES = ["refreshToplevels", "refreshWorkspaces", "refreshMonitors"];

test("a toplevel change while the overview is open refetches everything a tile draws from", () => {
    // Without this the overview keeps the rectangles, icons and addresses it had when it opened:
    // a window launched over it draws as a default box with a generic icon and will not click.
    assert.deepEqual(widget().run("toplevelsChanged"), FETCHES,
        "every open-overview toplevel change must refetch the toplevels, workspaces and monitors");
});

test("one function owns the fetch set and every producer calls it", () => {
    // A second copy drifts: the drag-release path used to fetch two of the three.
    assert.deepEqual(widget().run("refetch"), FETCHES, "refetchOverviewState must issue the full set");
    assert.match(source, /Component\.onCompleted:\s*refetchOverviewState\(\)/,
        "construction must fetch through the shared function");
    assert.ok(bodies.toplevelsChanged.includes("refetchOverviewState()"),
        "the open-overview subscription must fetch through the shared function");
    assert.ok(bodies.dragRelease.includes("refetchOverviewState()"),
        "the drag-release path must fetch through the shared function");
    for (const [label, body] of [["the subscription", bodies.toplevelsChanged], ["drag release", bodies.dragRelease]])
        for (const fetch of FETCHES)
            assert.ok(!body.includes(`Hyprland.${fetch}()`), `${label} must not call Hyprland.${fetch} directly`);
});

test("the widget exists only while the overview is open, so it holds no open-state branch", () => {
    // HyprlandOverview builds this widget from a Loader whose active is overviewOpen, and binds
    // overviewOpen to the same value. A second producer keyed on that flag is unreachable or a
    // duplicate fetch at every open; either way it is not carried.
    assert.ok(!source.includes("onOverviewOpenChanged"),
        "an overviewOpen change handler duplicates the construction producer");
    assert.ok(overviewSource.includes("active: overviewScope.overviewOpen"),
        "the premise is the Loader's active binding; re-check this case if that changes");
});

test("the extracted handlers assign on the component, not the global scope", () => {
    widget().run("toplevelsChanged");
    for (const name of ["overviewOpen", "calls"])
        assert.ok(!(name in globalThis), `${name} must not leak to the global scope`);
});
