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

const bodies = {
    completed: extractBlock(source, "Component.onCompleted:"),
    opened: extractBlock(source, "onOverviewOpenChanged:"),
    toplevelsChanged: extractBlock(source, "function onToplevelsChanged()"),
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
    const root = { calls: [], overviewOpen: false };
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

test("construction refetches the same set", () => {
    const calls = widget().run("completed");
    for (const fetch of FETCHES)
        assert.ok(calls.includes(fetch), `the construction producer must call ${fetch}`);
});

test("the open-state guard is what stops the closed overview fetching", () => {
    // onOverviewOpenChanged fires in both directions; only the open direction may fetch.
    const closing = widget();
    closing.overviewOpen = false;
    assert.deepEqual(closing.run("opened"), [], "closing the overview must issue no fetch");
    const opening = widget();
    opening.overviewOpen = true;
    assert.deepEqual(opening.run("opened"), FETCHES, "opening the overview must issue the full fetch");
});

test("the extracted handlers assign on the component, not the global scope", () => {
    widget().run("toplevelsChanged");
    for (const name of ["overviewOpen", "calls"])
        assert.ok(!(name in globalThis), `${name} must not leak to the global scope`);
});
