#!/usr/bin/env node

// Test that pill hover cannot stop recording or cancel countdowns.
// The runtime requires a click origin for destructive actions; an unannounced call has no click origin.
// Source checks inspect direct identifier use but cannot follow aliases or computed property access.

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.join(__dirname, "..");
const COMPONENT = path.join(repoRoot, "quickshell", "vshell", "Modules", "Plugins", "PluginComponent.qml");
const SCREEN_RECORD = path.join(repoRoot, "config", "vshell", "plugins", "screenRecord", "ScreenRecordWidget.qml");
const PLUGIN_ROOT = path.join(repoRoot, "config", "vshell", "plugins");
const HOVER_CONTROLLER = path.join(repoRoot, "quickshell", "vshell", "Modules", "Bar", "BarHoverController.qml");

const component = fs.readFileSync(COMPONENT, "utf8");
const screenRecord = fs.readFileSync(SCREEN_RECORD, "utf8");
const hoverController = fs.readFileSync(HOVER_CONTROLLER, "utf8");

// Scan comments and strings together. Preserve template interpolation code while blanking literal text
// so an invocation inside interpolation cannot escape the scan.
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


const componentCode = normalise(component, { blankStrings: true });
// Keep literals for value assertions while blanking comments and normalizing whitespace.
const componentText = normalise(component);



// These checks require normalized expressions, not function-body boundaries.
const present = (needle, message) =>
    assert.ok(componentText.includes(needle), `${message} (looked for: ${needle})`);

present("property bool pillClickOnHover: false",
    "pillClickOnHover must ship defaulting to false, or every widget inherits hover-activation silently");

present('property string pillActionOrigin: ""',
    "pillActionOrigin must default empty so an unannounced caller cannot read as a click");

present("if (pillClickAction && pillClickOnHover)",
    "triggerHoverPopout must require the opt-in before running a pill action");



// Restrict direct pillClickAction identifier use to known non-invocation forms and its handoff
// to _runPillAction. Unknown forms fail. This cannot track an aliased function value or computed name.
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

    const before = componentCode.slice(0, m.index).replace(/ +$/, "");
    if (!before.endsWith("_runPillAction("))
        directCalls.push(`${m[0]} passed to something other than _runPillAction`);
}
assert.deepEqual(
    directCalls,
    [],
    `pill actions must only be invoked via _runPillAction; found: ${JSON.stringify(directCalls)}`
);


present('pillActionOrigin = origin || "ipc"',
    "_runPillAction must fail closed to a non-click origin when the caller does not name one");

present("finally { root.pillActionOrigin = previousOrigin;",
    "_runPillAction must restore the previous origin even if the action throws");

// Count handlers that claim a click so adding a pill requires explicit origin-coverage review.
const clickClaims = componentText.match(/_runPillAction\([^)]*"click"[^)]*\)/g) || [];
assert.equal(clickClaims.length, 4,
    'exactly the two pills\' onClicked and onRightClicked handlers may pass "click"; ' +
    `found ${clickClaims.length} — if a pill was added, confirm it is a real pointer press and update this count`);



// Check explicit opt-ins as well as the safe default.
const OPTED_IN = []; // No bundled plugin is expected to opt into hover actions; deduplicate reports by plugin.
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



const marked = screenRecord.match(
    /\/\/ BEGIN PILL ACTION DECISION\n([\s\S]*?)\/\/ END PILL ACTION DECISION/
);
assert.ok(marked, "ScreenRecordWidget.qml must carry the PILL ACTION DECISION markers");


const { pillActionFor } = new Function(
    `${marked[1].replace(/^\s*function /m, "function ")}\nreturn { pillActionFor };`
)();


assert.equal(pillActionFor("hover", false, true), "ignore",
    "hovering while recording must not stop the recording");
assert.equal(pillActionFor("hover", true, false), "ignore",
    "hovering during the countdown must not cancel it");


assert.equal(pillActionFor("click", false, true), "stop", "clicking while recording must stop it");
assert.equal(pillActionFor("click", true, false), "cancel", "clicking during the countdown must cancel it");
assert.equal(pillActionFor("click", false, false), "chooser", "clicking while idle opens the chooser");

// An empty default origin must refuse destructive actions even if a caller bypasses _runPillAction.
assert.equal(pillActionFor("", false, true), "ignore",
    "an invocation that never set an origin must not be able to stop a recording");

// An omitted origin must also remain non-click.
for (const origin of ["", "ipc", undefined, null, "Click", "CLICK", "hover "]) {
    assert.equal(pillActionFor(origin, false, true), "ignore",
        `origin ${JSON.stringify(origin)} must not be able to stop a recording`);
    assert.equal(pillActionFor(origin, true, false), "ignore",
        `origin ${JSON.stringify(origin)} must not be able to cancel a countdown`);
}

// Chooser opening remains available through IPC and hover because it does not stop recording.
assert.equal(pillActionFor("ipc", false, false), "chooser",
    "an explicit IPC widget toggle may still open the chooser");


assert.equal(pillActionFor("click", true, true), "cancel",
    "a countdown must be cancelled before a recording is stopped");



// Method existence does not establish hover behavior. Bar discovery must read respondsToHover.

const controllerText = normalise(hoverController);

// Execute the capability expression across widget states; a token list cannot detect inverted composition.
const respondsDecl = componentText.match(
    /readonly property bool respondsToHover: (.+?)(?= readonly | property | function | signal |$)/
);
assert.ok(respondsDecl,
    "PluginComponent must declare respondsToHover — the bar has nothing else to ask");

const respondsToHover = new Function(
    "pillClickAction", "pillClickOnHover", "hasPopout",
    `return !!(${respondsDecl[1].trim()});`
);


assert.equal(respondsToHover(() => {}, false, false), false,
    "a widget with a pill action and no hover opt-in and no popout does nothing on hover");

assert.equal(respondsToHover(() => {}, true, false), true,
    "a widget that opted into hover-activation does respond to hover");

assert.equal(respondsToHover(null, false, true), true,
    "a popout widget must keep responding to hover");
assert.equal(respondsToHover(() => {}, false, true), true,
    "an opted-out action pill that also has a popout still opens the popout on hover");

assert.equal(respondsToHover(null, false, false), false,
    "a widget with neither an opt-in nor a popout does nothing on hover");

// Require the bar to consume the capability instead of accepting every exposed method.
const presentInController = (needle, message) =>
    assert.ok(controllerText.includes(needle), `${message} (looked for: ${needle})`);

presentInController('if (widgetItem.respondsToHover !== undefined) return widgetItem.respondsToHover === true;',
    "_widgetSupportsHoverPopout must report the widget's real hover capability, not the method's existence");

assert.ok(
    !/typeof widgetItem\.triggerHoverPopout === "function"\) return true;/.test(controllerText),
    "the method's presence alone must not arm a hover cycle — that is the shape check VGS-37 removed"
);



// Watch capability changes before rejecting a candidate. Otherwise a runtime false-to-true change
// can remain invisible until unrelated cache invalidation.

// Execute brace-extracted functions so changed decisions fail behavior assertions.
function extractFunction(text, name) {
    const start = text.indexOf(`function ${name}(`);
    assert.notEqual(start, -1, `BarHoverController must still define ${name}`);
    let depth = 0;
    for (let i = text.indexOf("{", start); i < text.length; i++) {
        if (text[i] === "{") depth++;
        else if (text[i] === "}" && --depth === 0) return text.slice(start, i + 1);
    }
    throw new Error(`unbalanced braces extracting ${name}`);
}

// Run addCandidate with the shipped capability decision and stubbed collaborators.
const supportsSrc = extractFunction(controllerText, "_widgetSupportsHoverPopout");
const addCandidateSrc = extractFunction(controllerText, "addCandidate");

function runAddCandidate(widgetItem) {
    const watched = [];
    const candidates = [];
    const seen = new Set();
    const root = {
        _itemBelongsToThisBar: () => true,
        _watchHoverCapability: item => watched.push(item),
        barContent: { getWidgetVisible: () => true }
    };
    const harness = new Function(
        "root", "candidates", "seen",
        `${supportsSrc}\nroot._widgetSupportsHoverPopout = _widgetSupportsHoverPopout;\n` +
        `${addCandidateSrc}\nreturn addCandidate;`
    )(root, candidates, seen);
    harness("fixedGeometryPlugin", widgetItem, "right");
    return { watched, candidates };
}

// A currently ineligible widget must still be watched for capability changes.
const inert = { triggerHoverPopout() {}, respondsToHover: false };
const inertRun = runAddCandidate(inert);
assert.deepEqual(inertRun.candidates, [],
    "a widget that does nothing on hover must still not get a hover cycle armed");
assert.ok(inertRun.watched.includes(inert),
    "a widget rejected for not responding to hover must be watched anyway, or its " +
    "respondsToHover flipping to true can never invalidate the candidate cache");

// A later eligible widget must become a candidate without depending on duplicate watch setup.
const live = { triggerHoverPopout() {}, respondsToHover: true };
const liveRun = runAddCandidate(live);
assert.equal(liveRun.candidates.length, 1,
    "a widget that responds to hover must become a candidate");
assert.equal(liveRun.candidates[0].widgetItem, live);

// Both capability-only and full candidate watches must include the capability-change signal.
const capabilityWatch = extractFunction(controllerText, "_watchHoverCapability");
assert.ok(/respondsToHoverChanged/.test(capabilityWatch),
    "_watchHoverCapability must connect respondsToHoverChanged — it is the only " +
    "signal that can change a rejected widget's answer");
const fullWatch = extractFunction(controllerText, "_watchCandidateObject");
assert.ok(/respondsToHoverChanged/.test(fullWatch),
    "the default watch list must include respondsToHoverChanged so a cached " +
    "candidate losing its hover behaviour invalidates too");

// Deduplicate watches by object and signal so a capability watch cannot suppress later geometry watches.
assert.ok(/watcher\.object === object && watcher\.signalName === signalName/.test(controllerText),
    "watcher de-duplication must be per (object, signal); per-object dedup makes a " +
    "capability watch suppress the geometry watch that same widget needs later");

// The inline host-discovery path needs the same watch-before-admission order.
const hostWatch = controllerText.indexOf("_watchHoverCapability(entry.host.item)");
const hostFilter = controllerText.indexOf("if (!_widgetSupportsHoverPopout(entry.host.widgetId");
assert.ok(hostWatch !== -1 && hostFilter !== -1 && hostWatch < hostFilter,
    "the host-discovery path must watch the widget's hover capability before the " +
    "predicate filters it out, same as addCandidate");

console.log("pill hover safety: all checks passed");
