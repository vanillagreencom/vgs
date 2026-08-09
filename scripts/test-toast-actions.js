#!/usr/bin/env node

"use strict";

// VGS-65: toast actions.
//
// Four things are worth proving mechanically, and none is visible to qmllint.
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
// 3. Guaranteed delivery. The queue cap silently drops a non-error toast once
//    three are waiting, which is not acceptable for the one message that
//    explains an unrequested change to the user's system.
// 4. That every `settingsTab:` literal in the tree resolves to a real settings
//    tab. The declarative form is a bare string resolved at click time; a typo
//    or a renamed registry id turns the button into a silent no-op.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.resolve(__dirname, "..");
const Action = require(path.join(repoRoot, "quickshell/vshell/Services/ToastAction.js"));
const Queue = require(path.join(repoRoot, "quickshell/vshell/Services/ToastQueue.js"));
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

// --- reading QML literals ---------------------------------------------------
//
// Both checks below read arrays straight out of their .qml files rather than
// transcribing them, so a rename or a restructure surfaces as a failure here
// instead of leaving this script asserting about a list that no longer exists.

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

// Both lists are plain string arrays; parsed rather than transcribed so a
// rename in ToastService.qml cannot leave this check asserting about a list
// that no longer exists. (extractArrayLiteral/evalArrayLiteral are defined
// below for the settings-tab check and hoist as function declarations.)
const stickyCategories = evalArrayLiteral(
    extractArrayLiteral(serviceSource, "readonly property var stickyCategories:")
);
const undroppableCategories = evalArrayLiteral(
    extractArrayLiteral(serviceSource, "readonly property var undroppableCategories:")
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
// Asserting the drop existed somewhere in the file proved only that at least
// one of them survived, so each is checked on its own below.
//
// The property is REACHABILITY -- after the drop, the entry must not be
// reachable from the queue the service goes on to hold -- and that is a
// behavioural property, so it is tested behaviourally rather than by pattern.
// The earlier version demanded the literal `toastQueue = toastQueue.filter(...)`
// and listed a splice loop among the forms it must reject, which was wrong:
// Array.prototype.splice() removes the array's reference to the entry exactly
// as a filter does. Requiring one syntax rejected a correct implementation,
// and a check that fails correct code gets weakened later by someone who
// cannot tell it from a real finding.
//
// So the drop itself lives in ToastQueue.js and is exercised for real. The
// property check is proved on THREE implementations: this one, a splice-based
// one that must also pass, and a marking one that must fail.

function releasesDroppedEntry(dropImplementation) {
    const dropped = { category: "doomed", message: "drop me" };
    const kept = { category: "other", message: "keep me" };
    const result = dropImplementation([dropped, kept], "doomed");
    // `result` is what every call site assigns back to toastQueue, so this is
    // the queue the singleton will hold. However the implementation got there,
    // the dropped entry must not be reachable from it.
    return result.indexOf(dropped) === -1 && result.indexOf(kept) >= 0;
}

assert.equal(
    releasesDroppedEntry(Queue.dropCategory),
    true,
    "ToastQueue.dropCategory must release the dropped entry"
);
assert.equal(
    releasesDroppedEntry((entries, category) => {
        // The implementation the old check wrongly forbade. splice() removes
        // the array's reference, so this releases the entry too and must pass.
        const copy = entries.slice();
        for (let i = copy.length - 1; i >= 0; i--) {
            if (copy[i].category === category)
                copy.splice(i, 1);
        }
        return copy;
    }),
    true,
    "a splice-based drop releases the entry just as a filter does, and must not be rejected"
);
assert.equal(
    releasesDroppedEntry((entries, category) => {
        // Marking instead of removing: the entry is still reachable.
        entries.forEach(entry => {
            if (entry.category === category)
                entry.dropped = true;
        });
        return entries;
    }),
    false,
    "the reachability check must reject a drop that only marks entries"
);

// Both drop sites route through that one audited implementation. This is a
// one-owner claim, not a ban on any syntax: a second inline drop would be a
// second thing to keep correct, and it is the drop that was silently deleted
// in the first place.
for (const fn of ["showToast", "dismissCategory"]) {
    assert.ok(
        /toastQueue\s*=\s*ToastQueue\.dropCategory\(toastQueue,\s*category\)/.test(qmlFunctionBody(fn)),
        `${fn} must drop its category through ToastQueue.dropCategory, or the dropped entries' actions outlive them`
    );
}

// --- undroppable entries survive every trim, not just admission -------------
//
// The admission exemption alone was not enough: an error arriving later takes
// the eviction path, which drops queued errors and then shortens the queue, and
// that could discard the takeover announcement anyway. "Undroppable" has to
// hold everywhere the queue is trimmed or it is a claim the code does not keep.

const protectedCategory = "notification-server-takeover";
const isProtected = category => undroppableCategories.includes(category);
const droppable = (n, level = 0) => ({ category: `plain-${n}`, level, message: `m${n}` });

const announcement = { category: protectedCategory, level: 0, message: "VGS is now handling notifications" };
const failureNotice = { category: "notification-server-takeover-failed", level: 2, message: "could not record it" };

// dropLevel: an undroppable ERROR is still undroppable.
assert.deepEqual(
    Queue.dropLevel([droppable(1, 2), failureNotice, droppable(2, 0)], 2, isProtected),
    [failureNotice, droppable(2, 0)],
    "dropping a level must keep protected entries whatever their level"
);

// trimToLimit: protected entries are never removed, droppables go from the end.
assert.deepEqual(
    Queue.trimToLimit([droppable(1), announcement, droppable(2), droppable(3)], 2, isProtected),
    [droppable(1), announcement],
    "trimming must remove droppable entries from the end"
);
assert.deepEqual(
    Queue.trimToLimit([droppable(1), droppable(2), announcement, failureNotice], 1, isProtected),
    [announcement, failureNotice],
    "a trim below the protected count must keep every protected entry rather than honour the limit"
);
assert.deepEqual(
    Queue.trimToLimit([announcement], 0, isProtected),
    [announcement],
    "a protected entry survives a trim to nothing"
);

// The instrument must be able to fail: an unprotected entry in the same place
// is removed.
assert.deepEqual(
    Queue.trimToLimit([droppable(1), droppable(9)], 1, isProtected),
    [droppable(1)],
    "trimming must actually remove something, or the assertions above prove nothing"
);

// The input is left alone, so a caller that has not yet reassigned still holds
// a consistent queue.
const original = [droppable(1), announcement, droppable(2)];
Queue.trimToLimit(original, 1, isProtected);
assert.equal(original.length, 3, "trimToLimit must not mutate the queue it was given");

// And the eviction path in showToast must route through both.
assert.ok(
    /ToastQueue\.trimToLimit\(\s*ToastQueue\.dropLevel\(toastQueue,\s*levelError,\s*isUndroppableCategory\)/.test(qmlFunctionBody("showToast")),
    "the error eviction path must protect undroppable entries, not just the admission check"
);

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

// --- guaranteed delivery ----------------------------------------------------
//
// The queue cap silently drops a non-error toast once three are waiting:
// showToast() simply returns. That is acceptable for a message the user can
// reconstruct from what they just did. It is not acceptable for the first-run
// takeover announcement, which explains a change VGS made to the user's system
// without being asked -- which daemon owns org.freedesktop.Notifications -- and
// carries the only in-UI pointer at the undo. Dropped, the user's notifications
// change appearance for no stated reason.
//
// Two properties, and the toast needs both: it must reach the queue (the cap
// must not drop it) and it must stay on screen (no 10s auto-dismiss for a
// message that may arrive while the user is away from the machine).

const takeoverCategory = "notification-server-takeover";

assert.ok(
    undroppableCategories.includes(takeoverCategory),
    `${takeoverCategory} must be undroppable, or the queue cap can silently discard the only explanation of an unrequested change`
);
assert.ok(
    stickyCategories.includes(takeoverCategory),
    `${takeoverCategory} must be sticky; reaching the queue is not delivery if it auto-dismisses in 10s`
);

// Reaching the queue and staying on screen are one guarantee, not two: an
// undroppable category that times out is only half delivered.
for (const category of undroppableCategories) {
    assert.ok(
        stickyCategories.includes(category),
        `${category} is undroppable but not sticky -- guaranteed into the queue and then auto-dismissed is not guaranteed delivery`
    );
}

// The cap check itself must consult the exemption. Asserting only that the
// list contains the category would pass with the list never read.
const showToastBody = qmlFunctionBody("showToast");
assert.ok(
    /toastQueue\.length\s*>=\s*maxQueueSize\s*&&\s*!isUndroppableCategory\(category\)/.test(showToastBody),
    "the queue cap must exempt undroppable categories, or the list is decorative"
);

// And the announcing side has to use that exact string. A rename on one side
// only silently returns the toast to droppable.
const notificationSource = fs.readFileSync(
    path.join(repoRoot, "quickshell/vshell/Services/NotificationService.qml"),
    "utf8"
);
// Checked on the announcing CALL, not on the file: the same string also appears
// in dismissCategory() nearby, so a file-wide search passed with the show call
// renamed -- exactly the mistake that returns the toast to droppable.
//
// The call is located by the CATEGORY, never by ordinal position. Taking the
// first `ToastService.showInfo(` in the file meant any earlier showInfo added
// later would silently repoint this assertion at an unrelated call and it would
// go on passing -- an instrument quietly measuring the wrong thing, which is
// the pattern this whole file exists to catch.

// Every ToastService.show* call in `src`, each bounded by the next one.
function toastCalls(src) {
    const re = /ToastService\.show(Info|Warning|Error)\(/g;
    const starts = [];
    let match;
    while ((match = re.exec(src)) !== null)
        starts.push({ index: match.index, level: match[1] });
    return starts.map((call, i) => ({
        level: call.level,
        text: src.slice(call.index, i + 1 < starts.length ? starts[i + 1].index : src.length)
    }));
}

// The quotes are part of the needle: "notification-server-takeover-failed" is a
// different category that shares the prefix, and an unquoted search would match
// both.
const announcements = toastCalls(notificationSource).filter(call => call.text.includes(`"${takeoverCategory}"`));
assert.equal(
    announcements.length,
    1,
    `exactly one ToastService.show* call should raise the ${takeoverCategory} category`
);
assert.equal(
    announcements[0].level,
    "Info",
    "the first-run announcement is informational; VGS did something deliberate rather than something going wrong"
);

// Prove the locator can fail: a category nothing raises must find nothing.
assert.equal(
    toastCalls(notificationSource).filter(c => c.text.includes('"no-such-category"')).length,
    0,
    "the call locator must find nothing for a category that is never raised"
);

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
