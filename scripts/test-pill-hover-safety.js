#!/usr/bin/env node

// Guards the rule that hovering a bar pill must not perform its click action.
//
// With `hoverPopouts` enabled, BarHoverController reaches every PluginComponent
// through triggerHoverPopout, which used to short-circuit straight into
// pillClickAction. For screenRecord that meant mousing over the pill stopped an
// in-progress recording — unrecoverable — cancelled a countdown, or opened the
// chooser unprompted (VGS-36).
//
// WHAT ACTUALLY PREVENTS THE DATA LOSS is a runtime property, not this file:
// pillActionOrigin is "" at rest and only _runPillAction ever sets it, so an
// invocation that reaches pillClickAction by any route the code does not
// announce arrives with a non-click origin — and screenRecord refuses to stop a
// recording or cancel a countdown unless the origin is "click". A bypass fails
// safe on its own. Section 4 below proves exactly that, by running the shipped
// decision against an unannounced origin.
//
// The static checks are therefore a lint on the shipped source, not the thing
// standing between a hover and a lost recording. They keep the invocation path
// single and readable — the duplicated arity branches are how the original bug
// hid — and they catch a default being flipped back. Read them as "the design
// is still intact", not as "the property is proven": a static scan cannot
// follow a value, so it can always be walked around by someone determined.
//
// Bundled plugins get no runtime coverage from `qml-smoke.sh --nested`
// (VGS-19), and that smoke cannot see a ReferenceError either (VGS-31), which
// is why this reads the source directly rather than exercising the widget.

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

// Strip comments, optionally blank out string contents, and collapse
// whitespace, so the checks below match expressions rather than lines. Single
// pass rather than sequential regexes because a `//` inside a string, or a
// quote inside a comment, defeats the sequential version.
//
// Template literals keep their `${…}` interpolations: those are executable
// code, and discarding the whole literal is how a call written inside one would
// go unseen. Only the inert text around them is dropped.
function normalise(src, { blankStrings = false } = {}) {
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
        if (blankStrings && (c === '"' || c === "'")) {
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
        if (blankStrings && c === "`") {
            i++;
            out += '""';
            while (i < src.length && src[i] !== "`") {
                if (src[i] === "\\") { i += 2; continue; }
                if (src[i] === "$" && src[i + 1] === "{") {
                    i += 2;
                    let depth = 1;
                    out += " ";
                    while (i < src.length) {
                        if (src[i] === "{") depth++;
                        else if (src[i] === "}" && --depth === 0) break;
                        out += src[i];
                        i++;
                    }
                    i++;
                    out += " ";
                    continue;
                }
                i++;
            }
            i++;
            continue;
        }
        out += c;
        i++;
    }
    return out.replace(/\s+/g, " ");
}

// Code only, for the invocation scan. Strings cannot contribute a false match.
const componentCode = normalise(component, { blankStrings: true });
// Strings intact, for the assertions that are about a literal value. Comment
// and indentation changes still cannot break these, which is the point: no
// check here depends on how the file happens to be formatted.
const componentText = normalise(component);

// --- 1. PluginComponent: hover-activation is opt-in --------------------------

// Substring checks over normalised text, not extracted function bodies. Body
// extraction had to hard-code the closing brace's indentation, so reindenting
// correct code broke CI — a false failure, which is its own harm and buys
// nothing here: what these assert is that a specific expression is present, and
// that does not need the enclosing structure parsed.
const present = (needle, message) =>
    assert.ok(componentText.includes(needle), `${message} (looked for: ${needle})`);

present("property bool pillClickOnHover: false",
    "pillClickOnHover must ship defaulting to false, or every widget inherits hover-activation silently");

present('property string pillActionOrigin: ""',
    "pillActionOrigin must default empty so an unannounced caller cannot read as a click");

present("if (pillClickAction && pillClickOnHover)",
    "triggerHoverPopout must require the opt-in before running a pill action");

// --- 2. PluginComponent: one invocation path, always naming an origin --------

// Every place that calls a pill action must go through _runPillAction. A direct
// call would reintroduce exactly the unguarded branch this issue was about —
// the arity>0 path that the first fix missed.
//
// This is a design lint, not the safety net: a call that skips _runPillAction
// leaves pillActionOrigin at "", which section 4 proves screenRecord already
// refuses. What it buys is that the invocation path stays single and legible,
// which is what the original duplication cost us.
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

// The two properties the runtime guarantee rests on.
present('pillActionOrigin = origin || "ipc"',
    "_runPillAction must fail closed to a non-click origin when the caller does not name one");

present("finally { root.pillActionOrigin = previousOrigin;",
    "_runPillAction must restore the previous origin even if the action throws");

// Only the pills' own handlers may claim a press. A count, so adding a third
// pill fails loudly and gets a deliberate update rather than silently widening
// what may claim one.
const clickClaims = componentText.match(/_runPillAction\([^)]*"click"[^)]*\)/g) || [];
assert.equal(clickClaims.length, 4,
    'exactly the two pills\' onClicked and onRightClicked handlers may pass "click"; ' +
    `found ${clickClaims.length} — if a pill was added, confirm it is a real pointer press and update this count`);

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
        if (/pillClickOnHover\s*:\s*true/.test(normalise(text))) optIns.add(dir.name);
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

// THE ONE THAT MAKES A BYPASS SURVIVABLE. pillActionOrigin is "" at rest, so an
// invocation that skips _runPillAction entirely — the thing section 2 lints for
// and cannot fully prevent — still cannot reach a destructive branch. This is
// why the static scan being walkable around is not a data-loss risk.
assert.equal(pillActionFor("", false, true), "ignore",
    "an invocation that never set an origin must not be able to stop a recording");

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
