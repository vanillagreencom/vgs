#!/usr/bin/env node

// Guards the focus target CompositorService publishes to the paste path, on BOTH
// supported compositors.
//
// Paste injects a keystroke, and the right keystroke depends on the window it
// lands in — so a focus target that resolves to "" is the stray-input bug
// VGS-119 fixed, reappearing. Hyprland's focus arrives as the seat's active
// toplevel; Niri does not populate that the same way, and everywhere else in the
// tree Niri activation is read from `NiriService.windows[].is_focused` instead.
// An unbranched toplevel read therefore passes every Hyprland test while leaving
// every Niri paste with no target at all.
//
// `scripts/check-paste-injection.py` pins the SHAPE of that wiring — that each
// property branches per compositor and that each fallback is liveness-gated and
// maintained. This runs the shipped expressions and asks what they RESOLVE TO,
// which no structural rule can answer: a branch can be correctly shaped and
// still read the wrong field.
//
// The bindings and the handler body are extracted from the QML rather than
// restated, so a test passing here is a statement about the code the shell
// ships. Neither compositor's focus is reachable from
// `scripts/qml-smoke.sh --nested`, which starts a shell with no windows in it.
//
// LIMIT, stated because it matters: this models Niri's window list from the
// shapes `NiriService` builds out of niri's IPC events. It does not prove niri
// itself reports what the model assumes — that needs a live Niri session.

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
// Comment- and string-aware, so a brace inside either cannot truncate a body
// and leave the test silently covering nothing. See scripts/lib/qml-block.js.
const { extractBlock } = require("./lib/qml-block.js");

const QML = path.join(__dirname, "..", "quickshell", "vshell", "Services", "CompositorService.qml");
const source = fs.readFileSync(QML, "utf8");

// ---- extract the shipped expressions --------------------------------------

// A binding spans QML's continuation lines: the lines below it that are indented
// further belong to it, and a blank line or a dedent ends it. Reading only the
// declaration's own line would extract `isNiri` and drop both branches — the
// test would then pass on nothing, which is the failure mode it exists to catch,
// so every extraction is asserted on below.
function bindingExpression(name) {
    const opener = new RegExp(`^([ \\t]*)(?:readonly[ \\t]+)?property[ \\t]+string[ \\t]+${name}[ \\t]*:(.*)$`, "m");
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

const FOCUSED = bindingExpression("focusedAppId");
const LAST_FOCUSED = bindingExpression("lastFocusedAppId");
const REMEMBER = extractBlock(source, "function rememberNiriFocus()");
const WINDOWS_CHANGED = extractBlock(source, "function onWindowsChanged()", source.indexOf("target: NiriService"));

// An extraction that came back short would leave the branch each test exists to
// exercise unexamined while every case still passed.
for (const [label, text, needles] of [
    ["focusedAppId", FOCUSED, ["isNiri", "is_focused", "activeToplevel"]],
    ["lastFocusedAppId", LAST_FOCUSED, ["isNiri", "NiriService.windows", "ToplevelManager.toplevels"]],
    ["rememberNiriFocus", REMEMBER, ["is_focused", "_lastFocusedNiriWindowId"]],
    ["onWindowsChanged", WINDOWS_CHANGED, ["rememberNiriFocus"]],
]) {
    for (const needle of needles)
        assert.ok(text.includes(needle), `the extracted ${label} must contain ${needle}`);
}

// ---- the model -------------------------------------------------------------

// Only what the expressions read. `windows` entries carry the fields NiriService
// keeps from niri's IPC events; `toplevels.values` is Quickshell's live list.
function evaluate(expression, state) {
    const body = `
        const { isNiri, NiriService, ToplevelManager, _lastFocusedToplevel, _lastFocusedNiriWindowId } = state;
        return (${expression});`;
    return new Function("state", body)(state);
}

function scenario(overrides = {}) {
    return Object.assign({
        isNiri: false,
        NiriService: { windows: [] },
        ToplevelManager: { activeToplevel: null, toplevels: { values: [] } },
        _lastFocusedToplevel: null,
        _lastFocusedNiriWindowId: null,
    }, overrides);
}

const foot = { id: 7, app_id: "foot", is_focused: true };
const kitty = { id: 9, app_id: "kitty", is_focused: false };

// The remember handler, run as the shell runs it: against `root` and the same
// window list the bindings read.
function remember(state) {
    new Function("root", "NiriService", REMEMBER)(state, state.NiriService);
    return state;
}

// ---- Hyprland: unchanged, and not reading Niri's list ----------------------

{
    const state = scenario({ ToplevelManager: { activeToplevel: { appId: "foot" }, toplevels: { values: [] } } });
    assert.equal(evaluate(FOCUSED, state), "foot", "Hyprland resolves the active toplevel's app id");
}
{
    assert.equal(evaluate(FOCUSED, scenario()), "", "no active toplevel is unknown, not a target");
}
{
    // The branch is a branch: Niri's list must not leak into the Hyprland path,
    // or a stale Niri window would name the target on the wrong compositor.
    const state = scenario({ NiriService: { windows: [foot] } });
    assert.equal(evaluate(FOCUSED, state), "", "Hyprland does not read Niri's focused window");
}
{
    const toplevel = { appId: "foot" };
    const live = scenario({ _lastFocusedToplevel: toplevel, ToplevelManager: { activeToplevel: null, toplevels: { values: [toplevel] } } });
    assert.equal(evaluate(LAST_FOCUSED, live), "foot", "a remembered window that is still open is a target");
    const closed = scenario({ _lastFocusedToplevel: toplevel, ToplevelManager: { activeToplevel: null, toplevels: { values: [] } } });
    assert.equal(evaluate(LAST_FOCUSED, closed), "", "a remembered window that closed is not a target");
}

// ---- Niri: the live focused app id -----------------------------------------

{
    const state = scenario({ isNiri: true, NiriService: { windows: [kitty, foot] } });
    assert.equal(evaluate(FOCUSED, state), "foot", "Niri resolves the window carrying is_focused");
}
{
    // WindowFocusChanged with no window clears every is_focused. The live value
    // is then unknown — which is precisely when the fallback has to carry.
    const state = scenario({ isNiri: true, NiriService: { windows: [kitty] } });
    assert.equal(evaluate(FOCUSED, state), "", "no focused Niri window is unknown, not a target");
}
{
    const state = scenario({ isNiri: true, NiriService: { windows: [] } });
    assert.equal(evaluate(FOCUSED, state), "", "an empty Niri window list resolves to no target");
}
{
    // The regression this whole round is about: on Niri the active toplevel is
    // not the focus source, so reading it would resolve the wrong window — or,
    // when it is empty, no window at all.
    const state = scenario({
        isNiri: true,
        NiriService: { windows: [foot] },
        ToplevelManager: { activeToplevel: { appId: "kitty" }, toplevels: { values: [] } },
    });
    assert.equal(evaluate(FOCUSED, state), "foot", "Niri ignores the active toplevel in favour of its own focus");
}
{
    const state = scenario({
        isNiri: true,
        NiriService: { windows: [kitty] },
        ToplevelManager: { activeToplevel: { appId: "kitty" }, toplevels: { values: [] } },
    });
    assert.equal(evaluate(FOCUSED, state), "", "an active toplevel does not stand in for Niri focus");
}

// ---- Niri: the remembered fallback -----------------------------------------

{
    const state = remember(scenario({ isNiri: true, NiriService: { windows: [kitty, foot] } }));
    assert.equal(state._lastFocusedNiriWindowId, foot.id, "the focused window's id is remembered");
    assert.equal(evaluate(LAST_FOCUSED, state), "foot", "the remembered window resolves to its app id");

    // A shell surface takes keyboard focus: niri reports no focused window, and
    // the live value empties. The remembered one must survive that, or the paste
    // fires with no target — the bug, one layer down.
    state.NiriService.windows = [kitty, Object.assign({}, foot, { is_focused: false })];
    remember(state);
    assert.equal(evaluate(FOCUSED, state), "", "focus left every Niri window");
    assert.equal(state._lastFocusedNiriWindowId, foot.id, "losing focus does not clear the remembered window");
    assert.equal(evaluate(LAST_FOCUSED, state), "foot", "the fallback carries the target across the gap");

    // WindowClosed drops it from the list, and the fallback must empty with it:
    // held on, it would name a dead window and paste a terminal's keystroke into
    // whatever replaced it.
    state.NiriService.windows = [kitty];
    remember(state);
    assert.equal(evaluate(LAST_FOCUSED, state), "", "a remembered Niri window that closed is not a target");
    assert.equal(evaluate(FOCUSED, state), "", "and nothing else resolves in its place");
}
{
    // Focus moving on is recorded, so the fallback names the newest window
    // rather than the first one ever focused.
    const state = remember(scenario({ isNiri: true, NiriService: { windows: [kitty, foot] } }));
    state.NiriService.windows = [Object.assign({}, kitty, { is_focused: true }), Object.assign({}, foot, { is_focused: false })];
    remember(state);
    assert.equal(evaluate(LAST_FOCUSED, state), "kitty", "the remembered window follows focus");
}
{
    // An id from an earlier session, or one never seen, must not resolve.
    const state = scenario({ isNiri: true, NiriService: { windows: [kitty] }, _lastFocusedNiriWindowId: 404 });
    assert.equal(evaluate(LAST_FOCUSED, state), "", "an id no live window carries resolves to nothing");
}
{
    // Nothing remembered yet, and a window whose id the model leaves undefined:
    // a null id must not match by accident and name an arbitrary window.
    const state = scenario({ isNiri: true, NiriService: { windows: [{ app_id: "foot", is_focused: true }] } });
    assert.equal(evaluate(LAST_FOCUSED, state), "", "an unset remembered id matches no window");
}

// ---- the wiring ------------------------------------------------------------

{
    // The handler is what keeps the fallback current. Reached only on Niri, so
    // Hyprland pays nothing for it.
    const calls = [];
    const root = {
        isNiri: false,
        rememberNiriFocus: () => calls.push("remember"),
        refreshToplevels: () => calls.push("refresh"),
    };
    const handler = new Function("root", WINDOWS_CHANGED);
    handler(root);
    assert.deepEqual(calls, [], "Hyprland does not run the Niri focus bookkeeping");
    root.isNiri = true;
    handler(root);
    assert.deepEqual(calls, ["remember", "refresh"], "every Niri window change updates the remembered focus");
}

console.log("test-compositor-focus: ok");
