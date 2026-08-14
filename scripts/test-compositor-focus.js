#!/usr/bin/env node

// Guards the focus target CompositorService publishes to the paste path, on BOTH
// supported compositors, and from the first paste after startup rather than only
// once focus has moved.
//
// Paste injects a keystroke, and the right keystroke depends on the window it
// lands in — so a focus target that resolves to "" is the stray-input bug
// VGS-119 fixed, reappearing. Two ways it can resolve to nothing:
//
//   - Wrong source. Hyprland's focus arrives as the seat's active toplevel; Niri
//     does not populate that the same way, and everywhere else in the tree Niri
//     activation is read from `NiriService.windows[].is_focused` instead. An
//     unbranched toplevel read passes every Hyprland test while leaving every
//     Niri paste with no target at all.
//   - Never seeded. Focus already in place when the service is constructed fires
//     no change signal, so a remembered value maintained only from listeners
//     stays empty until focus next MOVES. The paste surface taking keyboard
//     focus is itself what empties the live value, so the first paste of a
//     session would fall back to Ctrl+V.
//   - Guessed compositor. Detection is asynchronous, and `isNiri` reads false
//     both before it answers and when it answers "cannot tell" — so a property
//     branching on that boolean resolves those two states through the Hyprland
//     arm. `focusSource` carries them apart, and what each one resolves to is a
//     decision stated in the QML; this file exercises the decisions rather than
//     rediscovering them.
//
// `scripts/check-paste-injection.py` pins the SHAPE of the wiring — that each
// property branches per compositor and that each remembered value is
// liveness-gated and maintained. This runs the shipped expressions and asks what
// they RESOLVE TO, which no structural rule can answer: a branch can be
// correctly shaped and still read the wrong field, and a value can be correctly
// maintained and never initialised.
//
// The bindings, the handler bodies and the construction path are extracted from
// the QML rather than restated, so a test passing here is a statement about the
// code the shell ships. None of this is reachable from
// `scripts/qml-smoke.sh --nested`, which starts a shell with no windows in it.
//
// LIMIT, stated because it matters: this models each compositor's focus state
// from the shapes `NiriService` and Quickshell's `ToplevelManager` present. It
// does not prove niri itself reports what the model assumes — that needs a live
// Niri session.

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

const FOCUS_SOURCE = bindingExpression("focusSource");
const FOCUSED = bindingExpression("focusedAppId");
const LAST_FOCUSED = bindingExpression("lastFocusedAppId");
const bodies = {
    remember: extractBlock(source, "function rememberNiriFocus()"),
    seed: extractBlock(source, "function seedRememberedFocus()"),
    completed: extractBlock(source, "Component.onCompleted:"),
    applyCompositor: extractBlock(source, "function _applyCompositor(name)"),
    activeToplevelChanged: extractBlock(source, "function onActiveToplevelChanged()"),
    windowsChanged: extractBlock(source, "function onWindowsChanged()", source.indexOf("target: NiriService")),
};

// An extraction that came back short would leave the branch each test exists to
// exercise unexamined while every case still passed.
for (const [label, text, needles] of [
    ["focusSource", FOCUS_SOURCE, ["compositorDetected", "pending", "niri", "hyprland", "unknown"]],
    ["focusedAppId", FOCUSED, ["focusSource", "is_focused", "activeToplevel"]],
    ["lastFocusedAppId", LAST_FOCUSED, ["focusSource", "NiriService.windows", "ToplevelManager.toplevels"]],
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

// ---- the model -------------------------------------------------------------

// QML resolves an unqualified name in a component's function against that
// component, so the shipped bodies say `isNiri` and `rememberNiriFocus()` with
// no receiver. `with` is the one JS construct with those semantics, which is why
// it is used here: the alternative is rewriting the extracted source before
// running it, and a test that edits its subject proves something about the edit.
function call(body, root, parameters = [], args = []) {
    return new Function("root", ...parameters, `with (root) {\n${body}\n}`)(root, ...args);
}

const foot = { id: 7, app_id: "foot", is_focused: true };
const kitty = { id: 9, app_id: "kitty", is_focused: false };
const unfocused = (window) => Object.assign({}, window, { is_focused: false });

// Only the state the shipped code reads, plus the seams it calls out through.
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
    // Asynchronous in the shell: it shells out and applies the result later, so
    // construction never sees a compositor. That gap is the point of the second
    // seeding call, and a model that resolved detection synchronously would hide
    // it.
    root.detectCompositor = () => root.calls.push("detectCompositor");

    root.rememberNiriFocus = () => call(bodies.remember, root);
    root.seedRememberedFocus = () => call(bodies.seed, root);
    root.construct = () => call(bodies.completed, root);
    root.detected = (name) => call(bodies.applyCompositor, root, ["name"], [name]);
    root.focusChanged = () => call(bodies.activeToplevelChanged, root);
    root.windowsChanged = () => call(bodies.windowsChanged, root);

    // A binding, not a value: the focus properties read it on every evaluation,
    // and half of what this file tests is that it changes underneath them as
    // detection lands.
    Object.defineProperty(root, "focusSource", { get: () => call(`return (${FOCUS_SOURCE});`, root) });

    root.focusedAppId = () => call(`return (${FOCUSED});`, root);
    root.lastFocusedAppId = () => call(`return (${LAST_FOCUSED});`, root);
    return root;
}

// A session past compositor detection — the state every case is about except
// the startup ones below, which begin from shell() and drive detection
// themselves. Spelled out rather than defaulted into shell(), because "before
// detection answered" is a real state of the component and a model that could
// not represent it would be unable to test the half of this file that matters
// most.
function settled(compositor, overrides = {}) {
    return shell(Object.assign({
        compositorDetected: true,
        isHyprland: compositor === "hyprland",
        isNiri: compositor === "niri",
        compositor,
    }, overrides));
}

// ---- Hyprland: the live value ----------------------------------------------

{
    const root = settled("hyprland", { ToplevelManager: { activeToplevel: { appId: "foot" }, toplevels: { values: [] } } });
    assert.equal(root.focusedAppId(), "foot", "Hyprland resolves the active toplevel's app id");
}
{
    assert.equal(settled("hyprland").focusedAppId(), "", "no active toplevel is unknown, not a target");
}
{
    // The branch is a branch: Niri's list must not leak into the Hyprland path,
    // or a stale Niri window would name the target on the wrong compositor.
    const root = settled("hyprland", { NiriService: { windows: [foot] } });
    assert.equal(root.focusedAppId(), "", "Hyprland does not read Niri's focused window");
}

// ---- Hyprland: the remembered fallback -------------------------------------

{
    const toplevel = { appId: "foot" };
    const live = settled("hyprland", { _lastFocusedToplevel: toplevel, ToplevelManager: { activeToplevel: null, toplevels: { values: [toplevel] } } });
    assert.equal(live.lastFocusedAppId(), "foot", "a remembered window that is still open is a target");
    const closed = settled("hyprland", { _lastFocusedToplevel: toplevel, ToplevelManager: { activeToplevel: null, toplevels: { values: [] } } });
    assert.equal(closed.lastFocusedAppId(), "", "a remembered window that closed is not a target");
}
{
    // Focus arriving after construction is the case the listener covers.
    const root = shell();
    root.construct();
    root.detected("hyprland");
    const toplevel = { appId: "foot" };
    root.ToplevelManager = { activeToplevel: toplevel, toplevels: { values: [toplevel] } };
    root.focusChanged();
    root.ToplevelManager.activeToplevel = null;
    root.focusChanged();
    assert.equal(root.lastFocusedAppId(), "foot", "losing focus does not clear the remembered window");
}

// ---- Hyprland: focus that was already there at startup ---------------------

{
    // The startup hole: a terminal focused before the shell started fires no
    // change signal, so a value maintained only from the listener stays null.
    // The first paste is then the one that misfires.
    const toplevel = { appId: "foot" };
    const root = shell({ ToplevelManager: { activeToplevel: toplevel, toplevels: { values: [toplevel] } } });
    root.construct();
    assert.equal(root._lastFocusedToplevel, toplevel, "construction seeds the focus already in place");

    // Compositor detection returns later, and by then the seat may already be
    // empty — a shell surface grabs focus early. Seeding twice must not be a way
    // to overwrite a good target with nothing.
    root.ToplevelManager.activeToplevel = null;
    root.detected("hyprland");
    assert.equal(root._lastFocusedToplevel, toplevel, "detection does not clear what construction seeded");
    root.ToplevelManager.activeToplevel = toplevel;

    // The paste surface takes keyboard focus. No non-null focus change has EVER
    // fired, so only the seed can answer here.
    root.ToplevelManager.activeToplevel = null;
    root.focusChanged();
    assert.equal(root.focusedAppId(), "", "the shell surface emptied the live value");
    assert.equal(root.lastFocusedAppId(), "foot", "the first paste of the session still resolves its target");
}
{
    // Nothing focused at startup must not be recorded as a target, and must not
    // fabricate one out of a null.
    const root = shell();
    root.construct();
    root.detected("hyprland");
    assert.equal(root._lastFocusedToplevel, null, "an empty seat seeds nothing");
    assert.equal(root.lastFocusedAppId(), "", "and resolves to no target");
}

// ---- Niri: the live focused app id -----------------------------------------

{
    const root = settled("niri", { NiriService: { windows: [kitty, foot] } });
    assert.equal(root.focusedAppId(), "foot", "Niri resolves the window carrying is_focused");
}
{
    // WindowFocusChanged with no window clears every is_focused. The live value
    // is then unknown — which is precisely when the fallback has to carry.
    const root = settled("niri", { NiriService: { windows: [kitty] } });
    assert.equal(root.focusedAppId(), "", "no focused Niri window is unknown, not a target");
}
{
    const root = settled("niri", { NiriService: { windows: [] } });
    assert.equal(root.focusedAppId(), "", "an empty Niri window list resolves to no target");
}
{
    // The regression the per-compositor branch is about: on Niri the active
    // toplevel is not the focus source, so reading it would resolve the wrong
    // window — or, when it is empty, no window at all.
    const root = settled("niri", {
        NiriService: { windows: [foot] },
        ToplevelManager: { activeToplevel: { appId: "kitty" }, toplevels: { values: [] } },
    });
    assert.equal(root.focusedAppId(), "foot", "Niri ignores the active toplevel in favour of its own focus");
}
{
    const root = settled("niri", {
        NiriService: { windows: [kitty] },
        ToplevelManager: { activeToplevel: { appId: "kitty" }, toplevels: { values: [] } },
    });
    assert.equal(root.focusedAppId(), "", "an active toplevel does not stand in for Niri focus");
}

// ---- Niri: the remembered fallback -----------------------------------------

{
    const root = settled("niri", { NiriService: { windows: [kitty, foot] } });
    root.windowsChanged();
    assert.equal(root._lastFocusedNiriWindowId, foot.id, "the focused window's id is remembered");
    assert.equal(root.lastFocusedAppId(), "foot", "the remembered window resolves to its app id");

    // A shell surface takes keyboard focus: niri reports no focused window, and
    // the live value empties. The remembered one must survive that, or the paste
    // fires with no target — the bug, one layer down.
    root.NiriService.windows = [kitty, unfocused(foot)];
    root.windowsChanged();
    assert.equal(root.focusedAppId(), "", "focus left every Niri window");
    assert.equal(root._lastFocusedNiriWindowId, foot.id, "losing focus does not clear the remembered window");
    assert.equal(root.lastFocusedAppId(), "foot", "the fallback carries the target across the gap");

    // WindowClosed drops it from the list, and the fallback must empty with it:
    // held on, it would name a dead window and paste a terminal's keystroke into
    // whatever replaced it.
    root.NiriService.windows = [kitty];
    root.windowsChanged();
    assert.equal(root.lastFocusedAppId(), "", "a remembered Niri window that closed is not a target");
    assert.equal(root.focusedAppId(), "", "and nothing else resolves in its place");
}
{
    // Focus moving on is recorded, so the fallback names the newest window
    // rather than the first one ever focused.
    const root = settled("niri", { NiriService: { windows: [kitty, foot] } });
    root.windowsChanged();
    root.NiriService.windows = [Object.assign({}, kitty, { is_focused: true }), unfocused(foot)];
    root.windowsChanged();
    assert.equal(root.lastFocusedAppId(), "kitty", "the remembered window follows focus");
}
{
    // An id from an earlier session, or one never seen, must not resolve.
    const root = settled("niri", { NiriService: { windows: [kitty] }, _lastFocusedNiriWindowId: 404 });
    assert.equal(root.lastFocusedAppId(), "", "an id no live window carries resolves to nothing");
}
{
    // Nothing remembered yet, and a window whose id the model leaves undefined:
    // a null id must not match by accident and name an arbitrary window.
    const root = settled("niri", { NiriService: { windows: [{ app_id: "foot", is_focused: true }] } });
    assert.equal(root.lastFocusedAppId(), "", "an unset remembered id matches no window");
}

// ---- Niri: focus that was already there when detection landed --------------

{
    // Niri's own listener cannot cover this window on its own: it is gated on
    // isNiri, and at construction the compositor is not yet known. Whatever
    // niri already reported by the time detection lands has to be picked up
    // where it lands.
    const root = shell({ NiriService: { windows: [kitty, foot] } });
    root.construct();
    assert.equal(root._lastFocusedNiriWindowId, null, "construction predates detection, so nothing Niri is seeded yet");

    root.detected("niri");
    assert.equal(root.isNiri, true, "detection applied");
    assert.equal(root._lastFocusedNiriWindowId, foot.id, "detection seeds the focus niri already reported");

    // And the first paste: the surface takes focus, niri clears is_focused, and
    // only the seeded value can name the terminal.
    root.NiriService.windows = [kitty, unfocused(foot)];
    root.windowsChanged();
    assert.equal(root.focusedAppId(), "", "the shell surface emptied the live value");
    assert.equal(root.lastFocusedAppId(), "foot", "the first paste of the session still resolves its target");
}
{
    // Detection landing on Niri with nothing focused must seed nothing rather
    // than record an absence as a target.
    const root = shell({ NiriService: { windows: [kitty] } });
    root.construct();
    root.detected("niri");
    assert.equal(root._lastFocusedNiriWindowId, null, "no focused Niri window seeds nothing");
    assert.equal(root.lastFocusedAppId(), "", "and resolves to no target");
}
{
    // Seeding must not cross compositors: detection landing on Hyprland must not
    // adopt a Niri window, which would name a target that cannot be pasted into.
    const root = shell({ NiriService: { windows: [foot] } });
    root.construct();
    root.detected("hyprland");
    assert.equal(root._lastFocusedNiriWindowId, null, "the Hyprland seed leaves Niri's list alone");
    assert.equal(root.lastFocusedAppId(), "", "and the Hyprland fallback stays empty");
}

// ---- detection: pending is its own state, not a third meaning of Hyprland --

{
    // The state machine itself. `isHyprland`/`isNiri` are both false before
    // detection answers AND when it answers "cannot tell", which is exactly why
    // a two-state read of them resolves both through the Hyprland arm.
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
}
{
    // A paste beating detection: a terminal is focused and remembered, and both
    // compositors' state says so — but VGS does not yet know which one is
    // reporting it, so it names no target rather than guessing one. Ctrl+V into
    // that terminal is the bug; waiting is not.
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

    // The wait is short and it ends. Same state, one answer later, and both
    // properties resolve — which is what makes waiting the right answer rather
    // than a way to lose the paste.
    root.detected("hyprland");
    assert.equal(root.focusedAppId(), "foot", "the live target resolves once detection answers");
    assert.equal(root.lastFocusedAppId(), "foot", "and so does the remembered one");
}
{
    // The same wait, ending on Niri.
    const root = shell({ NiriService: { windows: [foot] } });
    assert.equal(root.focusedAppId(), "", "no live target before the compositor is known");
    root.detected("niri");
    assert.equal(root.focusedAppId(), "foot", "Niri's own focus resolves once detection answers");
    assert.equal(root.lastFocusedAppId(), "foot", "seeded and resolvable at the same moment");
}

// ---- detection failing: the stated decision, exercised ---------------------

{
    // Decided in CompositorService and asserted here so the decision cannot
    // drift silently: a detection that could not tell resolves through the
    // toplevel path — the behaviour every target had before VGS-119 — rather
    // than disabling paste or waiting for an answer that already came.
    const toplevel = { appId: "foot" };
    const root = shell({
        _lastFocusedToplevel: toplevel,
        ToplevelManager: { activeToplevel: toplevel, toplevels: { values: [toplevel] } },
    });
    root.detected("unknown");
    assert.equal(root.focusedAppId(), "foot", "a failed detection still resolves the active toplevel");
    assert.equal(root.lastFocusedAppId(), "foot", "and the remembered window with it");

    // Still liveness-gated: the failure mode being accepted is a MISSING target,
    // never a dead one.
    root.ToplevelManager.toplevels.values = [];
    assert.equal(root.lastFocusedAppId(), "", "a closed window is not a target on this path either");
}
{
    // And it does not reach for Niri's list, which is empty anyway when
    // detection failed: NiriService only connects its socket once isNiri is
    // true. That is the reason the decision costs nothing to make either way on
    // Niri, and it is worth pinning rather than restating.
    const root = shell({ NiriService: { windows: [foot] } });
    root.detected("unknown");
    assert.equal(root.focusedAppId(), "", "a failed detection resolves no Niri window");
    assert.equal(root.lastFocusedAppId(), "", "not even a remembered one");
}

// ---- the wiring ------------------------------------------------------------

{
    // The handler is what keeps the Niri fallback current between seeds. Reached
    // only on Niri, so Hyprland pays nothing for it.
    const root = shell({ NiriService: { windows: [foot] } });
    root.windowsChanged();
    assert.equal(root._lastFocusedNiriWindowId, null, "Hyprland does not run the Niri focus bookkeeping");
    assert.deepEqual(root.calls, [], "and does not refresh off Niri's events");
    root.isNiri = true;
    root.windowsChanged();
    assert.equal(root._lastFocusedNiriWindowId, foot.id, "every Niri window change updates the remembered focus");
    assert.deepEqual(root.calls, ["refreshToplevels"], "and refreshes the toplevel list");
}
{
    // `with` assigns to a property only when the object already has it; a
    // misspelled one would silently become a global and the assertion above it
    // would read a stale value forever.
    const root = shell();
    root.construct();
    root.detected("niri");
    for (const name of ["isNiri", "isHyprland", "compositor", "compositorDetected"])
        assert.ok(!(name in globalThis), `${name} must be assigned on the component, not leaked to the global scope`);
    assert.equal(root.compositor, "niri", "the model's component actually received the assignment");
}

console.log("test-compositor-focus: ok");
