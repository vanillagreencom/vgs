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
const { extractBlock, callInScope } = require("./lib/qml-block.js");

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

// Read each Timer out of the shipped file: its onTriggered body is the half of the change that
// makes one action cost one refresh, and writing that call here would certify the test's own copy.
function timerBlock(id) {
    const owner = source.slice(0, source.indexOf(`id: ${id}`)).lastIndexOf("Timer {");
    assert.ok(owner !== -1, `${id} must be declared inside a Timer`);
    const declaration = extractBlock(source, "Timer {", owner);
    assert.ok(declaration.includes(`id: ${id}`), `${id} must be the id of the Timer that encloses it`);
    return { id, declaration, body: handlerBody(declaration, id) };
}

// QML writes a handler as a braced block or as one expression after the colon. Read whichever
// the file uses, so the shipped call runs here instead of a stand-in written in this file.
function handlerBody(declaration, id) {
    const at = declaration.indexOf("onTriggered:");
    assert.ok(at !== -1, `${id} must declare an onTriggered handler`);
    const rest = declaration.slice(at + "onTriggered:".length);
    const body = rest.trimStart().startsWith("{")
        ? extractBlock(declaration, "onTriggered:")
        : rest.slice(0, rest.indexOf("\n") === -1 ? rest.length : rest.indexOf("\n"));
    // An empty body is reported by the timer case below, not thrown here: a throw at load
    // hides every other verdict in the file behind the first broken timer.
    return body;
}

// The second producer of the toplevel view. A direct call here rebuilt every consumer twice
// for one window open, so this handler shares the timer and the test must run the shipped body.
const VALUES_CHANGED = extractBlock(source, "function onValuesChanged()", source.indexOf("target: ToplevelManager.toplevels"));
const TIMERS = ["hyprMonitorRefreshTimer", "toplevelViewTimer"].map(timerBlock);

// Model the zero-interval Timer: restart re-arms a pending trigger, and a turn fires it once.
// Firing on restart instead would hide every missing coalesce.
function timer(fire) {
    return { pending: false, restart() { this.pending = true; }, fire() { this.pending = false; fire(); } };
}

function shell() {
    const root = { calls: [], _hyprMonitorRefreshEvents: MONITOR_EVENTS, _hyprToplevelViewEvents: TOPLEVEL_EVENTS };
    root.refreshToplevels = () => root.calls.push("toplevelsChanged");
    root.refreshMonitors = () => root.calls.push("refreshMonitors");
    const scope = {
        Hyprland: {
            refreshMonitors: () => root.calls.push("Hyprland.refreshMonitors"),
            refreshToplevels: () => root.calls.push("Hyprland.refreshToplevels"),
        },
    };
    // Run each shipped onTriggered body rather than a hand-written stand-in for it.
    for (const { id, body } of TIMERS)
        scope[id] = timer(() => callInScope(body, root, scope));

    // Deliver one socket batch: every producer this action reaches, then one event-loop turn.
    // wayland: true adds the ToplevelManager producer, which a window open or close reaches too.
    root.action = (...names) => root.deliver({}, ...names);
    root.deliver = ({ wayland = false }, ...names) => {
        for (const name of names)
            callInScope(RAW_EVENT, root, scope, ["event"], [{ name }]);
        if (wayland)
            callInScope(VALUES_CHANGED, root, scope);
        for (const { id } of TIMERS)
            if (scope[id].pending) scope[id].fire();
        return root.calls;
    };
    return root;
}

test("every timer this shell arms fires once per turn and nothing more", () => {
    for (const { id, declaration, body } of TIMERS) {
        assert.ok(body.trim(), `${id} must run something when it fires`);
        assert.match(declaration, /(^|\n)\s*interval:\s*0\s*(\n|$)/, `${id} must fire on the next turn, not after a delay`);
        assert.match(declaration, /(^|\n)\s*repeat:\s*false\s*(\n|$)/, `${id} must fire once, not on a loop`);
    }
});

test("both producers of the toplevel view share one coalescing timer", () => {
    const timerId = TIMERS.find(t => t.body.includes("refreshToplevels")).id;
    assert.ok(VALUES_CHANGED.includes(`${timerId}.restart()`),
        "the ToplevelManager handler must share the timer, or one window open rebuilds every consumer twice");
    assert.deepEqual(shell().deliver({ wayland: true }), ["toplevelsChanged"],
        "the Wayland list alone rebuilds once");

    // openwindow and closewindow reach both producers. The shared timer keeps that at one rebuild.
    for (const name of ["openwindow", "closewindow"]) {
        assert.deepEqual(shell().deliver({ wayland: true }, name), ["toplevelsChanged"],
            `${name} reaches both producers and must still rebuild every consumer once`);
    }
});

test("the extracted handler routes through both shipped event lists and the coalescing timers", () => {
    for (const needle of ["_hyprMonitorRefreshEvents", "_hyprToplevelViewEvents", ...TIMERS.map(t => t.id), "restart"])
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

test("the fan-out never issues an explicit toplevel fetch", () => {
    // Every HyprlandToplevel property the bar, dock and workspace filters read is a dedicated
    // one Quickshell tracks from the event stream. lastIpcObject is the exception: it holds
    // geometry and class, which no property carries, and the overview fetches it for itself.
    for (const name of [...MONITOR_EVENTS, ...TOPLEVEL_EVENTS])
        assert.ok(!shell().action(name).includes("Hyprland.refreshToplevels"),
            `${name} must not issue a j/clients fetch`);
    assert.ok(!shell().deliver({ wayland: true }).includes("Hyprland.refreshToplevels"),
        "the Wayland list producer must not issue a j/clients fetch either");
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
        ["monitor hotplug", ["monitoradded"], ["refreshMonitors", "toplevelsChanged"],
            "a new monitor refetches monitor state and re-runs the per-screen window filters"],
        ["monitor removal", ["monitorremoved"], ["refreshMonitors", "toplevelsChanged"],
            "a hotplug migrates workspaces, so the surviving bar re-runs its per-screen filter"],
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
    for (const name of [...TIMERS.map(t => t.id), "event"])
        assert.ok(!(name in globalThis), `${name} must not leak to the global scope`);
});
