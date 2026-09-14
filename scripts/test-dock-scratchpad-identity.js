#!/usr/bin/env node

// Execute the extracted dock scratchpad reads that decide the corner badge and reveal-on-click.
// Quickshell tracks HyprlandToplevel.workspace from the Hyprland event stream and refetches
// lastIpcObject only on request, so the two can disagree about where a window lives.
// This models reported Hyprland state; it does not verify a live compositor's event contract.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
// Use the shared comment-aware and string-aware brace reader to prevent truncated extraction.
const { extractBlock } = require("./lib/qml-block.js");

const QML = path.join(__dirname, "..", "quickshell", "vshell", "Modules", "Dock", "DockAppButton.qml");
const source = fs.readFileSync(QML, "utf8");

const bodies = {
    lookup: extractBlock(source, "function getHyprToplevelForWayland(waylandToplevel)"),
    specialName: extractBlock(source, "function getSpecialWorkspaceName(waylandToplevel)"),
};

test("the extracted reads carry the fields the model relies on", () => {
    for (const [label, text, needles] of [
        ["getHyprToplevelForWayland", bodies.lookup, ["CompositorService.isHyprland", "Hyprland.toplevels", "wayland"]],
        ["getSpecialWorkspaceName", bodies.specialName, ["getHyprToplevelForWayland", "workspace", "lastIpcObject", "special:"]],
    ]) {
        for (const needle of needles)
            assert.ok(text.includes(needle), `the extracted ${label} must contain ${needle}`);
    }
});

// with models QML's unqualified component lookup without rewriting the extracted function bodies.
function callInScope(body, root, scope, parameters, args) {
    return new Function("root", "scope", ...parameters, `with (scope) { with (root) {\n${body}\n} }`)(root, scope, ...args);
}

// Build one Hyprland toplevel whose live workspace and last-fetched workspace can disagree.
function hyprToplevel(wayland, live, fetched) {
    const toplevel = { wayland };
    if (live !== undefined)
        toplevel.workspace = live === null ? null : { name: live };
    if (fetched !== undefined)
        toplevel.lastIpcObject = { workspace: { name: fetched } };
    return toplevel;
}

function button(toplevels, isHyprland = true) {
    const scope = {
        CompositorService: { isHyprland },
        Hyprland: { toplevels: toplevels === null ? null : { values: toplevels } },
    };
    const root = {};
    root.getHyprToplevelForWayland = (wayland) => callInScope(bodies.lookup, root, scope, ["waylandToplevel"], [wayland]);
    root.getSpecialWorkspaceName = (wayland) => callInScope(bodies.specialName, root, scope, ["waylandToplevel"], [wayland]);
    return root;
}

const window = { appId: "foot" };

test("the live workspace decides the scratchpad name, not the last fetched one", () => {
    for (const [live, fetched, expected, why] of [
        ["special:term", "5", "term",
            "a window moved into a scratchpad is a scratchpad before the next fetch"],
        ["5", "special:term", "",
            "a window moved out of a scratchpad stops being one before the next fetch"],
        ["special:term", undefined, "term", "the live name alone names the scratchpad"],
        ["5", undefined, "", "an ordinary live workspace is not a scratchpad"],
        [null, "special:term", "term", "the last fetched name answers until workspace is populated"],
        [null, "5", "", "the last fetched name of an ordinary workspace is not a scratchpad"],
        [undefined, undefined, "", "a toplevel reporting no workspace at all is not a scratchpad"],
    ]) {
        const wayland = {};
        assert.equal(button([hyprToplevel(wayland, live, fetched)]).getSpecialWorkspaceName(wayland), expected, why);
    }
});

test("a window Hyprland does not report is not a scratchpad", () => {
    const wayland = {};
    for (const [toplevels, isHyprland, why] of [
        [[hyprToplevel({}, "special:term")], true, "another window's scratchpad does not claim this one"],
        [[], true, "an empty Hyprland toplevel list names no scratchpad"],
        [null, true, "an absent Hyprland toplevel model names no scratchpad"],
        [[hyprToplevel(wayland, "special:term")], false, "off Hyprland there are no special workspaces to read"],
    ]) {
        assert.equal(button(toplevels, isHyprland).getSpecialWorkspaceName(wayland), "", why);
    }
    assert.equal(button([hyprToplevel(wayland, "special:term")]).getSpecialWorkspaceName(null), "",
        "a tile with no window names no scratchpad");
});

test("the extracted reads assign on the component, not the global scope", () => {
    button([hyprToplevel({}, "special:term")]).getSpecialWorkspaceName({});
    for (const name of ["hyprToplevel", "wsName", "hyprToplevels", "waylandToplevel"])
        assert.ok(!(name in globalThis), `${name} must not leak to the global scope`);
});
