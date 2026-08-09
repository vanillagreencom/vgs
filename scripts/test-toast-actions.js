#!/usr/bin/env node

"use strict";

// VGS-65: toast actions.
//
// Three things are worth proving mechanically, and none is visible to qmllint.
//
// 1. The normaliser. A toast action is data whenever it can be; a label with
//    nowhere to go must not become a button that does nothing.
// 2. The lifetime of the callback form. ToastService is a singleton, so a
//    closure it stores outlives the toast unless every exit path releases it.
//    `showToast` drops queued entries by category, and the displayed toast's
//    copy has to be cleared by `hideToast`. Both are asserted against
//    ToastService.qml's own source, because the bug would be a missing line,
//    and a test that only exercised the normaliser would pass with that line
//    gone. There are two independent drop paths, so each is checked in its own
//    function body -- asserting the shared line exists somewhere in the file
//    passed with either one of them deleted.
// 3. That every `settingsTab:` literal in the tree resolves to a real settings
//    tab. The declarative form is a bare string resolved at click time; a typo
//    or a renamed registry id turns the button into a silent no-op.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.resolve(__dirname, "..");
const Action = require(path.join(repoRoot, "quickshell/vshell/Services/ToastAction.js"));
const servicePath = path.join(repoRoot, "quickshell/vshell/Services/ToastService.qml");
const serviceSource = fs.readFileSync(servicePath, "utf8");

// --- normalise --------------------------------------------------------------

assert.equal(Action.normalizeAction(null), null, "no action is not an action");
assert.equal(Action.normalizeAction(undefined), null);
assert.equal(Action.normalizeAction("notifications"), null, "a bare string is not an action");
assert.equal(Action.normalizeAction({}), null, "an empty object is not an action");
assert.equal(
    Action.normalizeAction({ label: "Open settings" }),
    null,
    "a label with nowhere to go must not render a button that does nothing"
);
assert.equal(
    Action.normalizeAction({ label: "   ", settingsTab: "notifications" }),
    null,
    "a blank label is no label"
);
assert.equal(
    Action.normalizeAction({ settingsTab: "notifications" }),
    null,
    "an unlabelled button cannot be rendered"
);

const declarative = Action.normalizeAction({ label: " Open settings ", settingsTab: " notifications " });
assert.deepEqual(
    declarative,
    { label: "Open settings", settingsTab: "notifications", callback: null },
    "the declarative form normalises to plain strings and holds no reference"
);
assert.equal(Action.hasAction(declarative), true);

let called = 0;
const live = Action.normalizeAction({ label: "Use VGS", callback: () => { called += 1; } });
assert.equal(live.settingsTab, "", "the callback form carries no route");
assert.equal(typeof live.callback, "function");
live.callback();
assert.equal(called, 1, "the normalised record keeps the handler callable");

// Both given: the declarative half wins, so behaviour does not depend on which
// property the caller happened to write first.
const both = Action.normalizeAction({
    label: "Open settings",
    settingsTab: "notifications",
    callback: () => { throw new Error("the callback must not win over a settings tab"); }
});
assert.equal(both.settingsTab, "notifications");
assert.equal(both.callback, null, "a settings tab must displace the callback, not sit beside it");

assert.equal(Action.hasAction(null), false);
assert.equal(Action.hasAction({ label: "x", settingsTab: "", callback: null }), false);

// --- the normaliser can fail -----------------------------------------------
//
// Everything above is a passing assertion, which proves nothing about the
// instrument. Feed it the shape it must reject and confirm the rejection is
// real rather than an artefact of how the assertions are written.
assert.throws(
    () => assert.notEqual(Action.normalizeAction({ label: "Open settings" }), null),
    "the reject-path assertions must be capable of failing"
);

// --- lifetime ---------------------------------------------------------------

function qmlFunctionBody(name) {
    const start = serviceSource.indexOf(`function ${name}(`);
    assert.ok(start >= 0, `ToastService.qml should define ${name}`);
    const end = serviceSource.indexOf("\n    }", start);
    assert.ok(end > start, `${name} should be a closed function body`);
    return serviceSource.slice(start, end);
}

// One writer for the live reference. If a second assignment to
// currentActionCallback appears, one of them will eventually forget to clear.
const callbackAssignments = serviceSource.match(/currentActionCallback\s*=/g) || [];
assert.equal(
    callbackAssignments.length,
    1,
    "currentActionCallback must be written in exactly one place (_setCurrentAction), " +
        "or a new path can leave a closure held by the singleton"
);
assert.ok(
    qmlFunctionBody("_setCurrentAction").includes("currentActionCallback = normalized ? normalized.callback : null"),
    "_setCurrentAction must null the callback when given no action"
);

// The displayed toast's copy is released on dismissal.
assert.ok(
    qmlFunctionBody("hideToast").includes("_setCurrentAction(null)"),
    "hideToast must release the displayed toast's action, or the closure outlives the toast"
);

// A queued entry's copy is released when the entry is dropped, and there are
// TWO independent drop paths: showToast() drops a superseded category before
// enqueueing its replacement, and dismissCategory() drops one on request.
//
// Both contain the same line, so asserting it exists somewhere in the file
// proved only that at least one of them survived: deleting either load-bearing
// drop entirely still passed. Each body is therefore checked on its own.
//
// The property being checked is reference RELEASE, not the absence of any
// particular method. Banning `splice` did not express that -- `shift` and
// `push` mutate the queue too and are correct where they are used, and a
// `splice` removes the array's reference to the entry just as a filter does.
// What actually releases is REPLACING the queue with a new array that never
// contained the entry, which is what this predicate requires and what the
// counterexamples below confirm it can tell apart.
function dropsCategoryByReassignment(source) {
    return /(?:^|[^\w.])toastQueue\s*=\s*toastQueue\s*\.filter\(\s*t\s*=>\s*t\.category\s*!==\s*category\s*\)/.test(source);
}

// Prove the instrument before trusting it: it must reject every in-place
// alternative, each of which leaves the dropped entry reachable from the same
// array object, and accept only the reassignment.
assert.equal(
    dropsCategoryByReassignment("toastQueue = toastQueue.filter(t => t.category !== category)"),
    true,
    "the drop predicate must accept the reassigning form"
);
for (const [label, counterexample] of [
    ["a bare filter whose result is thrown away", "toastQueue.filter(t => t.category !== category)"],
    ["an in-place splice", "for (var i = 0; i < toastQueue.length; i++) toastQueue.splice(i, 1)"],
    ["marking entries instead of dropping them", "toastQueue.forEach(t => { if (t.category === category) t.dropped = true })"],
    ["truncating the same array", "toastQueue.length = 0"],
    ["assigning some other array", "other = toastQueue.filter(t => t.category !== category)"]
]) {
    assert.equal(
        dropsCategoryByReassignment(counterexample),
        false,
        `the drop predicate must reject ${label}, which does not release the entry`
    );
}

for (const fn of ["showToast", "dismissCategory"]) {
    assert.ok(
        dropsCategoryByReassignment(qmlFunctionBody(fn)),
        `${fn} must drop its category by reassigning toastQueue, or the dropped entries' actions outlive them`
    );
}
assert.ok(
    qmlFunctionBody("processQueue").includes("_setCurrentAction(toast.action || null)"),
    "processQueue must install the dequeued entry's action, overwriting the previous one"
);

// invokeAction reads the action out before hideToast() releases it, and the
// declarative route is taken without ever calling a handler.
const invokeBody = qmlFunctionBody("invokeAction");
const readIndex = invokeBody.indexOf("const callback = currentActionCallback");
const hideIndex = invokeBody.indexOf("hideToast()");
assert.ok(readIndex >= 0, "invokeAction must capture the callback");
assert.ok(hideIndex > readIndex, "invokeAction must capture the action before hideToast() releases it");
assert.ok(
    invokeBody.indexOf("PopoutService.openSettingsWithTab(settingsTab)") > hideIndex,
    "the settings route should run after the toast is dismissed"
);

// Every public entry point must forward the action, or a caller would set one
// and silently get a plain toast.
for (const fn of ["showInfo", "showWarning", "showError"]) {
    const body = qmlFunctionBody(fn);
    assert.ok(
        /showToast\([^)]*category,\s*action\)/.test(body),
        `${fn} must forward its action argument to showToast`
    );
}

// --- settingsTab literals resolve to real tabs ------------------------------
//
// The declarative action form is a bare string that is resolved at click time
// by SettingsSidebar.resolveTabIndex(). Nothing binds that string to anything:
// a typo, or a future sidebar restructure that renames an id, makes
// setTabIndex(-1) a no-op and the button silently does nothing. Nobody sees a
// stack trace, and qmllint cannot see a string.
//
// So every settingsTab literal in the tree is resolved here, against the real
// SettingsSidebar category structure and the real SettingsRegistry, using the
// same matching rule resolveTabIndex() implements.

// The smallest balanced-bracket reader that can lift a QML array-literal
// property out of its file. Regexes cannot: the structures nest.
function extractArrayLiteral(source, marker) {
    const markerAt = source.indexOf(marker);
    assert.ok(markerAt >= 0, `expected to find ${JSON.stringify(marker)}`);
    const open = source.indexOf("[", markerAt + marker.length - 1);
    assert.ok(open >= 0, `expected an array literal after ${JSON.stringify(marker)}`);
    let depth = 0;
    for (let i = open; i < source.length; i++) {
        const ch = source[i];
        if (ch === "[" || ch === "{" || ch === "(")
            depth += 1;
        else if (ch === "]" || ch === "}" || ch === ")") {
            depth -= 1;
            if (depth === 0)
                return source.slice(open, i + 1);
        }
    }
    assert.fail(`unbalanced array literal after ${JSON.stringify(marker)}`);
}

// Both literals are plain data apart from the labels, which call out to QML
// singletons (I18n.tr, CompositorService...). Only ids and structure matter
// here, so every free identifier resolves to one inert stub: it is callable,
// truthy, has every property, and stringifies to "". Evaluating the real text
// rather than re-declaring the ids is the point -- a hand-copied list would
// drift from the file it is supposed to be checking.
const qmlStub = new Proxy(function () {}, {
    get(target, prop) {
        // `with` consults Symbol.unscopables first; a truthy answer there would
        // send every identifier back out to the global scope.
        if (prop === Symbol.unscopables)
            return undefined;
        if (prop === "toString" || prop === "valueOf" || prop === Symbol.toPrimitive)
            return () => "";
        return qmlStub;
    },
    has: () => true,
    apply: () => qmlStub
});

function evalArrayLiteral(text) {
    // `with` is what makes every unknown identifier reach the stub, so this
    // body is deliberately sloppy-mode; new Function() bodies are, regardless
    // of this file's own "use strict".
    // eslint-disable-next-line no-new-func
    return new Function("__qml", `with (__qml) { return (${text}); }`)(qmlStub);
}

const sidebarPath = path.join(repoRoot, "quickshell/vshell/Modals/Settings/SettingsSidebar.qml");
const registryPath = path.join(repoRoot, "quickshell/vshell/Modals/Settings/SettingsRegistry.qml");
const sidebarSource = fs.readFileSync(sidebarPath, "utf8");
const registrySource = fs.readFileSync(registryPath, "utf8");

const registryTabs = evalArrayLiteral(extractArrayLiteral(registrySource, "readonly property var tabs:"));
const categoryStructure = evalArrayLiteral(
    extractArrayLiteral(sidebarSource, "readonly property var categoryStructure:")
);
assert.ok(registryTabs.length > 0, "SettingsRegistry should declare tabs");
assert.ok(categoryStructure.length > 0, "SettingsSidebar should declare a category structure");

function tabIndexFor(id) {
    const tab = registryTabs.find(t => t.id === id);
    return tab ? tab.tabIndex : -1;
}

// The same normalisation SettingsSidebar.resolveTabIndex() applies, including
// its one alias. Kept as a transcription rather than a paraphrase: if the rule
// there changes, this is the line to change with it.
function normalizeTabName(name) {
    const normalized = String(name).toLowerCase().replace(/[_\-\s]/g, "");
    return normalized === "compositor" ? "workspaces" : normalized;
}

// resolveTabIndex(), reimplemented over the parsed structure with tab indexes
// supplied from the registry the way _withTabIndexes() supplies them.
function resolveTabIndex(name) {
    if (!name)
        return -1;
    const normalized = normalizeTabName(name);

    for (const cat of categoryStructure) {
        if (cat.separator)
            continue;

        if (normalizeTabName(cat.id || "") === normalized) {
            if (!cat.children || cat.children.length === 0)
                return tabIndexFor(cat.id);
            return tabIndexFor(cat.children[0].id);
        }

        for (const child of cat.children || []) {
            if (normalizeTabName(child.id || "") === normalized)
                return tabIndexFor(child.id);
        }
    }
    return -1;
}

// Prove the resolver can fail before its passes mean anything. The control is
// taken from the registry rather than hard-coded, so it stays independent of
// the literals actually under test below -- a rename there must surface as a
// failure about that literal, not as a broken control.
const controlId = registryTabs[0].id;
assert.ok(resolveTabIndex(controlId) >= 0, `the resolver must find ${controlId}, a declared tab`);
assert.equal(
    resolveTabIndex(controlId + "x"),
    -1,
    "a misspelled tab id must resolve to -1, or this check cannot detect a typo"
);
assert.equal(resolveTabIndex(""), -1, "an empty tab id is not a tab");

// Every literal in the tree, from every file that can carry one.
function qmlSources(dir) {
    const out = [];
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const full = path.join(dir, entry.name);
        if (entry.isDirectory())
            out.push(...qmlSources(full));
        else if (/\.(qml|js)$/.test(entry.name))
            out.push(full);
    }
    return out;
}

const literals = new Map();
for (const file of qmlSources(path.join(repoRoot, "quickshell"))) {
    // Whole-line comments only: ToastAction.js documents the form in prose, and
    // that example is not a call site. Anything else is left intact so a real
    // literal cannot be hidden by a `//` inside a string on the same line.
    const code = fs
        .readFileSync(file, "utf8")
        .split("\n")
        .filter(line => !line.trim().startsWith("//"))
        .join("\n");
    for (const match of code.matchAll(/settingsTab:\s*"([^"]*)"/g)) {
        if (!literals.has(match[1]))
            literals.set(match[1], []);
        literals.get(match[1]).push(path.relative(repoRoot, file));
    }
}

assert.ok(literals.size > 0, "expected at least one settingsTab literal to check");
for (const [literal, files] of literals) {
    const index = resolveTabIndex(literal);
    assert.notEqual(
        index,
        -1,
        `settingsTab: "${literal}" (${files.join(", ")}) does not resolve to any tab — ` +
            "the action button would silently do nothing"
    );
    assert.ok(
        registryTabs.some(t => t.tabIndex === index),
        `settingsTab: "${literal}" resolved to ${index}, which is not a SettingsRegistry tabIndex`
    );
}

console.log(`Toast action tests passed (${literals.size} settingsTab literals resolved).`);
