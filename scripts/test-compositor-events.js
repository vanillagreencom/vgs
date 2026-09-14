#!/usr/bin/env node

// Execute the extracted Hyprland raw-event fan-out in CompositorService.
// Hyprland announces one action under a v1 and a v2 name, so the cost of a focus change or a
// workspace switch is set by which names are matched and by whether the matches coalesce.
// This models the shipped event names and the zero-interval timers; it does not verify what a
// live Hyprland emits.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
// Use the shared comment-aware and string-aware brace reader to prevent truncated extraction.
const { extractBlock } = require("./lib/qml-block.js");

const QML = path.join(__dirname, "..", "quickshell", "vshell", "Services", "CompositorService.qml");
const source = fs.readFileSync(QML, "utf8");

const RAW_EVENT = extractBlock(source, "function onRawEvent(event)", source.indexOf("target: root.isHyprland"));

// Read each event list out of the shipped property so a name added or removed moves this test.
function eventList(name) {
    const match = source.match(new RegExp(`^[ \\t]*readonly[ \\t]+property[ \\t]+var[ \\t]+${name}[ \\t]*:[ \\t]*(\\[[^\\]]*\\])`, "m"));
    assert.ok(match, `could not find the ${name} list`);
    const names = JSON.parse(match[1].replace(/'/g, '"'));
    assert.ok(names.length > 0, `${name} must not be empty`);
    return names;
}

const MONITOR_EVENTS = eventList("_hyprMonitorRefreshEvents");
const TOPLEVEL_EVENTS = eventList("_hyprToplevelViewEvents");

// Model the zero-interval Timer: restart re-arms a pending trigger, and turn() runs the event
// loop once. Firing on restart instead would hide every missing coalesce.
function timer(onTriggered) {
    return { pending: false, restart() { this.pending = true; }, fire() { this.pending = false; onTriggered(); } };
}

// with models QML's unqualified component lookup without rewriting the extracted handler body.
function callInScope(body, root, scope, parameters, args) {
    return new Function("root", "scope", ...parameters, `with (scope) { with (root) {\n${body}\n} }`)(root, scope, ...args);
}

function shell() {
    const root = { calls: [], _hyprMonitorRefreshEvents: MONITOR_EVENTS, _hyprToplevelViewEvents: TOPLEVEL_EVENTS };
    root.refreshToplevels = () => root.calls.push("toplevelsChanged");
    const scope = {
        Hyprland: {
            refreshMonitors: () => root.calls.push("refreshMonitors"),
            refreshToplevels: () => root.calls.push("Hyprland.refreshToplevels"),
        },
        hyprMonitorRefreshTimer: timer(() => scope.Hyprland.refreshMonitors()),
        hyprToplevelViewTimer: timer(() => root.refreshToplevels()),
    };
    // Deliver one socket batch: every event of one action, then a single event-loop turn.
    root.action = (...names) => {
        for (const name of names)
            callInScope(RAW_EVENT, root, scope, ["event"], [{ name }]);
        for (const t of [scope.hyprMonitorRefreshTimer, scope.hyprToplevelViewTimer])
            if (t.pending) t.fire();
        return root.calls;
    };
    return root;
}

test("the extracted handler routes through both shipped event lists and the coalescing timers", () => {
    for (const needle of ["_hyprMonitorRefreshEvents", "_hyprToplevelViewEvents", "hyprMonitorRefreshTimer", "hyprToplevelViewTimer", "restart"])
        assert.ok(RAW_EVENT.includes(needle), `the extracted onRawEvent must contain ${needle}`);
});

test("no matched event name has a v2 twin that is also matched", () => {
    // Derive the duplicates from the lists themselves: a v1 name is a duplicate exactly when the
    // same list carries its v2 form. Re-adding activewindow beside activewindowv2 reddens this.
    for (const [label, names] of [["monitor", MONITOR_EVENTS], ["toplevel view", TOPLEVEL_EVENTS]]) {
        const v2 = names.filter(name => name.endsWith("v2"));
        assert.ok(v2.length > 0, `the ${label} list must carry at least one v2 name for this to constrain anything`);
        for (const name of v2)
            assert.ok(!names.includes(name.slice(0, -"v2".length)),
                `the ${label} list matches both ${name} and its v1 form, so one action costs two refreshes`);
    }
});

test("the handler never issues an explicit toplevel fetch", () => {
    // Quickshell maintains every HyprlandToplevel property this shell reads from the event stream.
    assert.ok(!RAW_EVENT.includes("refreshToplevels()") || !RAW_EVENT.includes("Hyprland.refreshToplevels"),
        "the handler must not call Hyprland.refreshToplevels");
    for (const name of [...MONITOR_EVENTS, ...TOPLEVEL_EVENTS])
        assert.ok(!shell().action(name).includes("Hyprland.refreshToplevels"),
            `${name} must not issue a j/clients fetch`);
});

test("one user action costs one refresh of each kind", () => {
    for (const [action, names, expected, why] of [
        ["focus change", ["activewindow", "activewindowv2"], ["toplevelsChanged"],
            "a focus change re-runs the workspace filters once and fetches no monitors"],
        ["workspace switch", ["workspace", "workspacev2", "activewindow", "activewindowv2"], ["toplevelsChanged"],
            "a workspace switch coalesces its three matched events into one filter pass"],
        ["monitor focus change", ["focusedmon", "focusedmonv2", "activewindow", "activewindowv2"],
            ["refreshMonitors", "toplevelsChanged"],
            "a monitor focus change costs one j/monitors fetch, not one per matched event"],
        ["window move", ["movewindow", "movewindowv2"], ["toplevelsChanged"],
            "a move re-runs the workspace filters once"],
        ["scratchpad toggle", ["activespecial"], ["refreshMonitors", "toplevelsChanged"],
            "activespecial refetches the monitor lastIpcObject the scratchpad badge reads"],
        ["monitor hotplug", ["monitoradded"], ["refreshMonitors"],
            "a new monitor refetches monitor state and leaves the toplevel filters alone"],
        ["monitor removal", ["monitorremoved"], ["refreshMonitors"],
            "a removed monitor refetches monitor state and leaves the toplevel filters alone"],
        ["fullscreen toggle", ["fullscreen"], ["toplevelsChanged"],
            "a fullscreen toggle re-runs the bar's hide decision and fetches no monitors"],
    ]) {
        assert.deepEqual(shell().action(...names), expected, `${action}: ${why}`);
    }
});

test("an unmatched event refreshes nothing", () => {
    for (const name of ["createworkspace", "destroyworkspace", "windowtitle", "configreloaded", "urgent"]) {
        assert.ok(!MONITOR_EVENTS.includes(name) && !TOPLEVEL_EVENTS.includes(name),
            `${name} must stay out of both lists for this case to constrain anything`);
        assert.deepEqual(shell().action(name), [], `${name} must not reach either refresh`);
    }
});

test("each list drives only its own refresh", () => {
    for (const name of MONITOR_EVENTS) {
        const calls = shell().action(name);
        assert.ok(calls.includes("refreshMonitors"), `${name} must refetch monitor state`);
        assert.equal(calls.includes("toplevelsChanged"), TOPLEVEL_EVENTS.includes(name),
            `${name} re-runs the toplevel filters only if the toplevel-view list carries it`);
    }
    for (const name of TOPLEVEL_EVENTS) {
        const calls = shell().action(name);
        assert.ok(calls.includes("toplevelsChanged"), `${name} must re-run the toplevel filters`);
        assert.equal(calls.includes("refreshMonitors"), MONITOR_EVENTS.includes(name),
            `${name} refetches monitor state only if the monitor list carries it`);
    }
});

test("separate socket batches are not coalesced into one another", () => {
    // Coalescing spans one event-loop turn. A later action must still refresh.
    const root = shell();
    assert.deepEqual(root.action("activewindowv2"), ["toplevelsChanged"], "the first action refreshes");
    root.calls.length = 0;
    assert.deepEqual(root.action("activewindowv2"), ["toplevelsChanged"], "a later action refreshes again");
});

test("the extracted handler assigns on the component, not the global scope", () => {
    // with assigns to an object only for an existing property. Assert against accidental global writes.
    shell().action("activewindowv2");
    for (const name of ["hyprMonitorRefreshTimer", "hyprToplevelViewTimer", "event"])
        assert.ok(!(name in globalThis), `${name} must not leak to the global scope`);
});
