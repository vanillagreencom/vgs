#!/usr/bin/env node

"use strict";

// Test action normalization, callback release, protected queue entries, and settings-tab targets.
// Singleton callbacks can outlive dismissed toasts, and string tab IDs resolve only when clicked.
// Source wiring checks complement the queue and normalizer behavior tests.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.resolve(__dirname, "..");
const Action = require(path.join(repoRoot, "quickshell/vshell/Services/ToastAction.js"));
const Queue = require(path.join(repoRoot, "quickshell/vshell/Services/ToastQueue.js"));
const servicePath = path.join(repoRoot, "quickshell/vshell/Services/ToastService.qml");
const serviceSource = fs.readFileSync(servicePath, "utf8");

test("normalizeAction rejects anything without both a label and somewhere to go", () => {
    for (const [input, why] of [
        [null, "no action is not an action"],
        [undefined, "no action is not an action"],
        ["notifications", "a bare string is not an action"],
        [{}, "an empty object is not an action"],
        [{ label: "Open settings" }, "a label with nowhere to go must not render a button that does nothing"],
        [{ label: "   ", settingsTab: "notifications" }, "a blank label is no label"],
        [{ settingsTab: "notifications" }, "an unlabelled button cannot be rendered"]
    ]) {
        assert.equal(Action.normalizeAction(input), null, `${JSON.stringify(input)}: ${why}`);
    }
});

test("normalizeAction yields the declarative or the callback form, the declarative winning, and hasAction reads it", () => {
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

    // Declarative actions take precedence when both forms are supplied.
    const both = Action.normalizeAction({
        label: "Open settings",
        settingsTab: "notifications",
        callback: () => { throw new Error("the callback must not win over a settings tab"); }
    });
    assert.equal(both.settingsTab, "notifications");
    assert.equal(both.callback, null, "a settings tab must displace the callback, not sit beside it");

    assert.equal(Action.hasAction(null), false);
    assert.equal(Action.hasAction({ label: "x", settingsTab: "", callback: null }), false);
});

// Read QML arrays from source so renamed or removed IDs enter the test automatically.

// Extract a balanced QML array literal, including nested arrays.
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

// Evaluate array structure with inert callable property stubs for QML label expressions.
// Only IDs and structure are relevant to these checks.
const qmlStub = new Proxy(function () {}, {
    get(target, prop) {
        // Symbol.unscopables must remain false so with does not redirect identifiers to globals.
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
    // Use non-strict generated function scope for the with-based stubs.
    // eslint-disable-next-line no-new-func
    return new Function("__qml", `with (__qml) { return (${text}); }`)(qmlStub);
}

// Read toast category arrays from source rather than maintaining a duplicate list.
const stickyCategories = evalArrayLiteral(
    extractArrayLiteral(serviceSource, "readonly property var stickyCategories:")
);
const undroppableCategories = evalArrayLiteral(
    extractArrayLiteral(serviceSource, "readonly property var undroppableCategories:")
);

function qmlFunctionBody(name) {
    const start = serviceSource.indexOf(`function ${name}(`);
    assert.ok(start >= 0, `ToastService.qml should define ${name}`);
    const end = serviceSource.indexOf("\n    }", start);
    assert.ok(end > start, `${name} should be a closed function body`);
    return serviceSource.slice(start, end);
}

// Require one current callback writer so release behavior has one owner.
test("currentActionCallback has exactly one writer, which nulls it on no action", () => {
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
});

test("hideToast releases the displayed toast's action", () => {
    assert.ok(
        qmlFunctionBody("hideToast").includes("_setCurrentAction(null)"),
        "hideToast must release the displayed toast's action, or the closure outlives the toast"
    );
});

// A dropped queue entry must become unreachable from the returned queue. Test both filter
// and splice removal as valid, and marking without removal as invalid. Inspect each call site
// separately because whole-file presence cannot cover independently removable paths.

test("dropCategory releases the dropped entry, and the reachability check rejects a mark-only drop", () => {
    function releasesDroppedEntry(dropImplementation) {
        const dropped = { category: "doomed", message: "drop me" };
        const kept = { category: "other", message: "keep me" };
        const result = dropImplementation([dropped, kept], "doomed");
        // Compare reachability from the returned queue that callers retain.
        return result.indexOf(dropped) === -1 && result.indexOf(kept) >= 0;
    }

    assert.equal(
        releasesDroppedEntry(Queue.dropCategory),
        true,
        "ToastQueue.dropCategory must release the dropped entry"
    );
    assert.equal(
        releasesDroppedEntry((entries, category) => {
            // Splice removes the array reference too and must satisfy the same release property.
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

            entries.forEach(entry => {
                if (entry.category === category)
                    entry.dropped = true;
            });
            return entries;
        }),
        false,
        "the reachability check must reject a drop that only marks entries"
    );
});

// Both drop sites must use the queue implementation exercised here.
test("both drop sites go through ToastQueue.dropCategory", () => {
    for (const fn of ["showToast", "dismissCategory"]) {
        assert.ok(
            /toastQueue\s*=\s*ToastQueue\.dropCategory\(toastQueue,\s*category\)/.test(qmlFunctionBody(fn)),
            `${fn} must drop its category through ToastQueue.dropCategory, or the dropped entries' actions outlive them`
        );
    }
});

// Protected entries must survive eviction as well as admission; later errors can trigger trimming.

const protectedCategory = "notification-server-takeover";
const isProtected = category => undroppableCategories.includes(category);
const droppable = (n, level = 0) => ({ category: `plain-${n}`, level, message: `m${n}` });

const announcement = { category: protectedCategory, level: 0, message: "VGS is now handling notifications" };
const failureNotice = { category: "notification-server-takeover-failed", level: 2, message: "could not record it" };

// Protected error entries remain protected during level eviction.
test("dropLevel keeps protected entries whatever their level", () => {
    assert.deepEqual(
        Queue.dropLevel([droppable(1, 2), failureNotice, droppable(2, 0)], 2, isProtected),
        [failureNotice, droppable(2, 0)],
        "dropping a level must keep protected entries whatever their level"
    );
});

test("trimToLimit removes droppable entries from the end and keeps every protected one", () => {
    for (const [queue, limit, expected, why] of [
        [[droppable(1), announcement, droppable(2), droppable(3)], 2, [droppable(1), announcement],
            "trimming must remove droppable entries from the end"],
        [[droppable(1), droppable(2), announcement, failureNotice], 1, [announcement, failureNotice],
            "a trim below the protected count must keep every protected entry rather than honour the limit"],
        [[announcement], 0, [announcement], "a protected entry survives a trim to nothing"],
        [[droppable(1), droppable(9)], 1, [droppable(1)],
            "trimming must actually remove something, or the protected rows prove nothing"]
    ]) {
        assert.deepEqual(Queue.trimToLimit(queue, limit, isProtected), expected, why);
    }
});

// Keep the input queue consistent for callers until they adopt the returned value.
test("trimToLimit does not mutate the queue it was given", () => {
    const original = [droppable(1), announcement, droppable(2)];
    Queue.trimToLimit(original, 1, isProtected);
    assert.equal(original.length, 3, "trimToLimit must not mutate the queue it was given");
});

test("the error eviction path protects undroppable entries and processQueue installs the dequeued action", () => {
    assert.ok(
        /ToastQueue\.trimToLimit\(\s*ToastQueue\.dropLevel\(toastQueue,\s*levelError,\s*isUndroppableCategory\)/.test(qmlFunctionBody("showToast")),
        "the error eviction path must protect undroppable entries, not just the admission check"
    );

    assert.ok(
        qmlFunctionBody("processQueue").includes("_setCurrentAction(toast.action || null)"),
        "processQueue must install the dequeued entry's action, overwriting the previous one"
    );
});

// Read the action before hideToast releases it; declarative actions must not invoke the callback.
test("invokeAction captures the callback before hideToast releases it and routes after", () => {
    const invokeBody = qmlFunctionBody("invokeAction");
    const readIndex = invokeBody.indexOf("const callback = currentActionCallback");
    const hideIndex = invokeBody.indexOf("hideToast()");
    assert.ok(readIndex >= 0, "invokeAction must capture the callback");
    assert.ok(hideIndex > readIndex, "invokeAction must capture the action before hideToast() releases it");
    assert.ok(
        invokeBody.indexOf("PopoutService.openSettingsWithTab(settingsTab)") > hideIndex,
        "the settings route should run after the toast is dismissed"
    );
});

// Public toast entrypoints must forward actions or callers silently lose their buttons.
test("every public toast entrypoint forwards its action", () => {
    for (const fn of ["showInfo", "showWarning", "showError"]) {
        const body = qmlFunctionBody(fn);
        assert.ok(
            /showToast\([^)]*category,\s*action\)/.test(body),
            `${fn} must forward its action argument to showToast`
        );
    }
});

// The first-run notification takeover message explains a system change and provides its undo action.
// It must bypass queue dropping and auto-dismiss so an absent user can still read it.

const takeoverCategory = "notification-server-takeover";

test("the takeover category is undroppable and sticky, every undroppable category is sticky, and the cap uses the list", () => {
    assert.ok(
        undroppableCategories.includes(takeoverCategory),
        `${takeoverCategory} must be undroppable, or the queue cap can silently discard the only explanation of an unrequested change`
    );
    assert.ok(
        stickyCategories.includes(takeoverCategory),
        `${takeoverCategory} must be sticky; reaching the queue is not delivery if it auto-dismisses in 10s`
    );

    // Protected admission alone does not prevent the notice from disappearing by timeout.
    for (const category of undroppableCategories) {
        assert.ok(
            stickyCategories.includes(category),
            `${category} is undroppable but not sticky -- guaranteed into the queue and then auto-dismissed is not guaranteed delivery`
        );
    }

    // Require the cap check to use the exemption list, not merely declare it.
    const showToastBody = qmlFunctionBody("showToast");
    assert.ok(
        /toastQueue\.length\s*>=\s*maxQueueSize\s*&&\s*!isUndroppableCategory\(category\)/.test(showToastBody),
        "the queue cap must exempt undroppable categories, or the list is decorative"
    );
});

// The announcing category must match its exemption key.
const notificationSource = fs.readFileSync(
    path.join(repoRoot, "quickshell/vshell/Services/NotificationService.qml"),
    "utf8"
);
// Locate the actual show call by category. A dismissal reference or an unrelated earlier show
// cannot establish that the announcement uses the protected category.

// Bound each show call by its matching parenthesis while skipping string contents.
// Ending at the next call or EOF can borrow an unrelated later category.
function toastCalls(src) {
    const re = /ToastService\.show(Info|Warning|Error)\(/g;
    const calls = [];
    let match;
    while ((match = re.exec(src)) !== null) {
        const open = match.index + match[0].length - 1;
        let depth = 0;
        let inString = false;
        let end = -1;
        for (let i = open; i < src.length; i++) {
            const ch = src[i];
            if (inString) {
                if (ch === "\\")
                    i += 1;
                else if (ch === '"')
                    inString = false;
                continue;
            }
            if (ch === '"')
                inString = true;
            else if (ch === "(")
                depth += 1;
            else if (ch === ")") {
                depth -= 1;
                if (depth === 0) {
                    end = i + 1;
                    break;
                }
            }
        }
        assert.ok(end > open, `unbalanced ToastService.show${match[1]}( call in the source`);
        calls.push({ level: match[1], text: src.slice(match.index, end) });
    }
    return calls;
}

// Check extracted calls do not contain the next call's start.
test("exactly one Info call raises the takeover category, and the call locator neither sweeps nor invents", () => {
    for (const call of toastCalls(notificationSource)) {
        assert.equal(
            (call.text.match(/ToastService\.show(Info|Warning|Error)\(/g) || []).length,
            1,
            "each located call must stop at its own closing parenthesis, or it sweeps in unrelated code"
        );
    }

    // Include quotes in the category needle so a longer category sharing its prefix cannot match.
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

    // Require a nonexistent raised category to return no call.
    assert.equal(
        toastCalls(notificationSource).filter(c => c.text.includes('"no-such-category"')).length,
        0,
        "the call locator must find nothing for a category that is never raised"
    );
});

// Resolve settingsTab literals against the parsed sidebar and registry. An invalid string
// otherwise becomes a no-op button at click time without a parse error.

const sidebarPath = path.join(repoRoot, "quickshell/vshell/Modals/Settings/SettingsNavigation.qml");
const registryPath = path.join(repoRoot, "quickshell/vshell/Modals/Settings/SettingsRegistry.qml");
const sidebarSource = fs.readFileSync(sidebarPath, "utf8");
const registrySource = fs.readFileSync(registryPath, "utf8");

const registryTabs = evalArrayLiteral(extractArrayLiteral(registrySource, "readonly property var tabs:"));
const categoryStructure = evalArrayLiteral(
    extractArrayLiteral(sidebarSource, "readonly property var categories:")
);
assert.ok(registryTabs.length > 0, "SettingsRegistry should declare tabs");
assert.ok(categoryStructure.length > 0, "SettingsSidebar should declare a category structure");

function tabIndexFor(id) {
    const tab = registryTabs.find(t => t.id === id);
    return tab ? tab.tabIndex : -1;
}

// This mirrors sidebar normalization, including its alias, and must change with that runtime rule.
function normalizeTabName(name) {
    const normalized = String(name).toLowerCase().replace(/[_\-\s]/g, "");
    return normalized === "compositor" ? "workspaces" : normalized;
}

// Resolve tab indexes over the parsed sidebar using registry-provided indexes.
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

// Derive the resolver failure control from the registry so a renamed action literal fails at its own check.
test("the tab resolver finds a declared tab and refuses a misspelled or empty one", () => {
    const controlId = registryTabs[0].id;
    assert.ok(resolveTabIndex(controlId) >= 0, `the resolver must find ${controlId}, a declared tab`);
    assert.equal(
        resolveTabIndex(controlId + "x"),
        -1,
        "a misspelled tab id must resolve to -1, or this check cannot detect a typo"
    );
    assert.equal(resolveTabIndex(""), -1, "an empty tab id is not a tab");
});

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

test("every settingsTab literal under quickshell resolves to a SettingsRegistry tab", () => {
    const literals = new Map();
    for (const file of qmlSources(path.join(repoRoot, "quickshell"))) {
        // Skip whole-line comments only; an inline double slash can belong to a real string literal.
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
});
