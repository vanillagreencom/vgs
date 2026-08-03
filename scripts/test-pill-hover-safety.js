#!/usr/bin/env node

// Guards the rule that hovering a bar pill must not perform its click action.
//
// With `hoverPopouts` enabled, BarHoverController reaches every PluginComponent
// through triggerHoverPopout, which used to short-circuit straight into
// pillClickAction. For screenRecord that meant mousing over the pill stopped an
// in-progress recording — unrecoverable — cancelled a countdown, or opened the
// chooser unprompted (VGS-36).
//
// Two independent things are checked, because either alone can be defeated:
//   1. PluginComponent's structural guarantees: hover-activation is opt-in, and
//      every pill action is invoked through one path that names its origin.
//   2. screenRecord's own decision, extracted verbatim from the shipped QML
//      between its BEGIN/END PILL ACTION DECISION markers, so this tests the
//      real source rather than a re-implementation of it.
//
// Bundled plugins get no runtime coverage from `qml-smoke.sh --nested`
// (VGS-19), and that smoke cannot see a ReferenceError either (VGS-31), which
// is why this harness reads the source directly.

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.join(__dirname, "..");
const COMPONENT = path.join(repoRoot, "quickshell", "vshell", "Modules", "Plugins", "PluginComponent.qml");
const SCREEN_RECORD = path.join(repoRoot, "config", "vshell", "plugins", "screenRecord", "ScreenRecordWidget.qml");
const PLUGIN_ROOT = path.join(repoRoot, "config", "vshell", "plugins");

const component = fs.readFileSync(COMPONENT, "utf8");
const screenRecord = fs.readFileSync(SCREEN_RECORD, "utf8");

// Strip comments and string literals in one pass, then collapse whitespace, so
// the checks below match call *expressions* rather than lines. A line-oriented
// scan cannot see a call split across lines, and treats "this line is already
// accounted for" as "this line is safe" — a second call appended to it slips
// through. Single pass rather than sequential regexes because a `//` inside a
// string, or a quote inside a comment, defeats the sequential version.
function normaliseSource(src) {
    let out = "";
    for (let i = 0; i < src.length; ) {
        const c = src[i];
        const d = src[i + 1];
        if (c === "/" && d === "/") {
            while (i < src.length && src[i] !== "\n") i++;
            continue;
        }
        if (c === "/" && d === "*") {
            i += 2;
            while (i < src.length && !(src[i] === "*" && src[i + 1] === "/")) i++;
            i += 2;
            out += " ";
            continue;
        }
        if (c === '"' || c === "'" || c === "`") {
            const quote = c;
            i++;
            while (i < src.length && src[i] !== quote) {
                if (src[i] === "\\") i++;
                i++;
            }
            i++;
            out += '""';
            continue;
        }
        out += c;
        i++;
    }
    return out.replace(/\s+/g, " ");
}

const componentCode = normaliseSource(component);

// --- 1. PluginComponent: hover-activation is opt-in --------------------------

assert.match(
    component,
    /property bool pillClickOnHover:\s*false/,
    "pillClickOnHover must ship defaulting to false, or every widget inherits hover-activation silently"
);

assert.match(
    component,
    /property string pillActionOrigin:\s*""/,
    "pillActionOrigin must default empty so an unannounced caller cannot read as a click"
);

const hoverBody = component.match(
    /function triggerHoverPopout\(widgetHostId\)\s*\{([\s\S]*?)\n    \}/
);
assert.ok(hoverBody, "PluginComponent must still declare triggerHoverPopout");
assert.match(
    hoverBody[1],
    /if \(pillClickAction && pillClickOnHover\)/,
    "triggerHoverPopout must require the opt-in before running a pill action"
);

// --- 2. PluginComponent: one invocation path, always naming an origin --------

// Every place that calls a pill action must go through _runPillAction. A direct
// call would reintroduce exactly the unguarded branch this issue was about —
// the arity>0 path that the first fix missed.
//
// Allowlist rather than a list of call syntaxes, because enumerating call forms
// only ever covers the ones someone thought of: `pillClickAction(`,
// `pillClickAction?.()`, `.call(`, `.apply(`, `?.call(`, `["call"](` all invoke
// it. So instead, whatever follows the identifier must be one of the few things
// that provably is not an invocation, and everything else fails. A new syntax
// fails closed by default instead of needing the guard extended to notice it.
//
// The one legitimate mention is the pass-along `_runPillAction(pillClickAction,
// …)`, and that is checked positionally: a comma after the identifier is only
// accepted when _runPillAction( immediately precedes it, so handing the action
// to some other helper that calls it does not pass either.
//
// WHAT THIS DOES NOT COVER, so the next reader does not over-trust it: a static
// scan cannot follow a value. Aliasing (`const f = pillClickAction; f();`),
// reaching the property by a computed name, or stashing it on another object
// and calling it from there are all invisible here. The guard enforces that the
// *identifier* is only ever handed to _runPillAction — not that the underlying
// function can never be reached another way.
const SAFE_AFTER = /^[,)&|;:]/;
const directCalls = [];
for (const m of componentCode.matchAll(/\b(pillClickAction|pillRightClickAction)\b/g)) {
    const after = componentCode.slice(m.index + m[0].length).replace(/^ +/, "");
    if (!SAFE_AFTER.test(after)) {
        directCalls.push(`${m[0]}${after.slice(0, 12).trimEnd()}`);
        continue;
    }
    if (!after.startsWith(","))
        continue;
    // A comma only means "passed along", and only to the one helper allowed to
    // invoke it.
    const before = componentCode.slice(0, m.index).replace(/ +$/, "");
    if (!before.endsWith("_runPillAction("))
        directCalls.push(`${m[0]} passed to something other than _runPillAction`);
}
assert.deepEqual(
    directCalls,
    [],
    `pill actions must only be invoked via _runPillAction; found: ${JSON.stringify(directCalls)}`
);

const runBody = component.match(/function _runPillAction\(action, origin, pill\)\s*\{([\s\S]*?)\n    \}/);
assert.ok(runBody, "PluginComponent must declare _runPillAction");
assert.match(
    runBody[1],
    /pillActionOrigin = origin \|\| "ipc"/,
    "_runPillAction must fail closed to a non-click origin when the caller does not name one"
);
assert.match(
    runBody[1],
    /finally\s*\{[\s\S]*pillActionOrigin = previousOrigin/,
    "_runPillAction must restore the previous origin even if the action throws"
);

// Only the pills' own handlers may claim a press.
const clickClaims = component.match(/_runPillAction\([^)]*"click"[^)]*\)/g) || [];
assert.equal(clickClaims.length, 4,
    'exactly the two pills\' onClicked and onRightClicked handlers may pass "click"');

// --- 3. No bundled plugin opts in without being considered -------------------

// The default protects a widget that says nothing. This catches the other
// direction: someone opting a destructive widget in without thinking about it.
const OPTED_IN = []; // no bundled plugin currently opts into hover-activation
// A Set, because a plugin with several QML files would otherwise be reported
// once per file and skew the diagnostic. Normalised so a commented-out opt-in
// does not count as one.
const optIns = new Set();
for (const dir of fs.readdirSync(PLUGIN_ROOT, { withFileTypes: true })) {
    if (!dir.isDirectory()) continue;
    for (const file of fs.readdirSync(path.join(PLUGIN_ROOT, dir.name))) {
        if (!file.endsWith(".qml")) continue;
        const text = fs.readFileSync(path.join(PLUGIN_ROOT, dir.name, file), "utf8");
        if (/pillClickOnHover\s*:\s*true/.test(normaliseSource(text))) optIns.add(dir.name);
    }
}
assert.deepEqual(
    [...optIns].sort(),
    OPTED_IN.slice().sort(),
    "a bundled plugin opted into hover-activation; confirm its pill action is non-destructive and add it to OPTED_IN"
);

// --- 4. screenRecord: destructive transitions require a real click -----------

const marked = screenRecord.match(
    /\/\/ BEGIN PILL ACTION DECISION\n([\s\S]*?)\/\/ END PILL ACTION DECISION/
);
assert.ok(marked, "ScreenRecordWidget.qml must carry the PILL ACTION DECISION markers");

// The extracted text is plain JavaScript with no QML API use, so it evaluates
// as an ordinary function.
const { pillActionFor } = new Function(
    `${marked[1].replace(/^\s*function /m, "function ")}\nreturn { pillActionFor };`
)();

// The reported bug, both halves.
assert.equal(pillActionFor("hover", false, true), "ignore",
    "hovering while recording must not stop the recording");
assert.equal(pillActionFor("hover", true, false), "ignore",
    "hovering during the countdown must not cancel it");

// A real press still does what the user asked.
assert.equal(pillActionFor("click", false, true), "stop", "clicking while recording must stop it");
assert.equal(pillActionFor("click", true, false), "cancel", "clicking during the countdown must cancel it");
assert.equal(pillActionFor("click", false, false), "chooser", "clicking while idle opens the chooser");

// Anything that did not announce itself is treated as not-a-click. This is the
// case that matters most: a future caller that forgets to pass an origin.
for (const origin of ["", "ipc", undefined, null, "Click", "CLICK", "hover "]) {
    assert.equal(pillActionFor(origin, false, true), "ignore",
        `origin ${JSON.stringify(origin)} must not be able to stop a recording`);
    assert.equal(pillActionFor(origin, true, false), "ignore",
        `origin ${JSON.stringify(origin)} must not be able to cancel a countdown`);
}

// Opening the chooser is reversible, so it stays available to IPC and hover.
assert.equal(pillActionFor("ipc", false, false), "chooser",
    "an explicit IPC widget toggle may still open the chooser");

// Countdown takes precedence over recording, as the shipped order does.
assert.equal(pillActionFor("click", true, true), "cancel",
    "a countdown must be cancelled before a recording is stopped");

console.log("pill hover safety: all checks passed");
