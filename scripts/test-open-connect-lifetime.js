#!/usr/bin/env node

// Drive the shipped open paths of the Bluetooth codec selector and the window-rule modal against
// modelled long-lived targets. Both targets outlive every open, so a connection made inside an
// open path stays registered after the popout closes and a later emission runs one handler per
// open. The accumulation cases open repeatedly and then emit once: the effect must run exactly
// once, whatever the number of opens. Two further cases pin the ends of that range — an emission
// before any open has happened, and a read-only compositor that opens and connects nothing.
//
// The model also reads each element's `enabled` binding, so a connection the shipped file declares
// but disables is not counted as a live one.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const qmlSource = require("./lib/qml-source.js");

const ROOT = path.join(__dirname, "..", "quickshell", "vshell");
const DETAIL_HOST = path.join(ROOT, "Modules/ControlCenter/Components/DetailHost.qml");
const WINDOW_RULES_TAB = path.join(ROOT, "Modules/Settings/WindowRulesTab.qml");

const detailHostText = fs.readFileSync(DETAIL_HOST, "utf8");
const windowRulesTabText = fs.readFileSync(WINDOW_RULES_TAB, "utf8");
const detailHost = qmlSource(detailHostText, "DetailHost.qml");
const windowRulesTab = qmlSource(windowRulesTabText, "WindowRulesTab.qml");

// Build a callable from a shipped function, under its own parameter names. Calling it with the
// wrong name would leave the argument undefined and the case green on an untaken path.
function shippedFunction(text, q, label, name) {
    const at = q.indexOf(`function ${name}(`);
    assert.notEqual(at, -1, `${label} must define ${name}()`);
    const close = q.indexOf(")", at);
    const params = text.slice(text.indexOf("(", at) + 1, close).trim();
    // eslint-disable-next-line no-new-func -- with() models QML scope lookup, which needs non-strict
    const fn = new Function("scope", params, `with (scope) ${q.body(name)}`);
    return (scope, ...args) => fn(scope, ...args);
}

// How many times each case opens before it emits. One open cannot tell a per-open connection from
// a per-lifetime one, so every accumulation case opens more than once.
const OPENS = 4;

// A Qt signal: connect appends, disconnect removes one registration, emit runs what is registered.
// Connecting the same function twice registers it twice, which is the accumulation under test.
function signal() {
    const handlers = [];
    return {
        connect: fn => handlers.push(fn),
        disconnect(fn) {
            const at = handlers.indexOf(fn);
            if (at !== -1)
                handlers.splice(at, 1);
        },
        get count() {
            return handlers.length;
        },
        emit: (...args) => handlers.slice().forEach(fn => fn(...args)),
    };
}

// A Connections target is a property path, so evaluating it needs no calls, no indexing and no
// literals. Refuse anything else rather than running arbitrary repository text.
const TARGET_EXPRESSION =
    /^[A-Za-z_$][A-Za-z0-9_$]*(?:\s*(?:\?\.|\.)\s*[A-Za-z_$][A-Za-z0-9_$]*)*(?:\s*\?\?\s*null)?$/;

// Read one binding of a Connections element as an evaluator. An absent binding takes `fallback`,
// which is how Qt reads an omitted `enabled`. A present one must be a property path: evaluating a
// Connections binding needs no calls, no indexing and no literals.
function bindingReader(block, label, name, fallback) {
    if (block.q.indexOf(`${name}:`) === -1)
        return () => fallback;
    const expression = block.q.binding(name).value;
    assert.match(expression, TARGET_EXPRESSION,
        `${label}: refusing to evaluate Connections ${name} ${JSON.stringify(expression)}`);
    // eslint-disable-next-line no-new-func -- with() models QML scope lookup, which needs non-strict
    const read = new Function("scope", `with (scope) return (${expression});`);
    return scope => read(scope);
}

// Model the one Connections element in `file` that handles `signalName`. Qt holds a single
// connection per element, drops it while `enabled` reads false, and moves it when the `target`
// binding re-evaluates, so this element is the whole of what the file connects declaratively to
// that signal. The returned retarget() re-reads both bindings and moves that connection; it runs
// at creation and again whenever the model changes a property either binding reads. It returns
// the object now connected, or null when nothing is.
function connectionsElement(q, label, scope, signalName, signalOf) {
    const chosen = q.objectBlocks("Connections")
        .filter(block => block.q.indexOf(`function ${signalName}(`) !== -1);
    assert.equal(chosen.length, 1,
        `${label} must hold exactly one Connections element handling ${signalName}, found ` +
        `${chosen.length} — without it every open connects a handler of its own`);
    const readTarget = bindingReader(chosen[0], label, "target", null);
    const readEnabled = bindingReader(chosen[0], label, "enabled", true);
    const run = shippedFunction(chosen[0].text, chosen[0].q, `${label} ${signalName}`, signalName);
    const handler = (...args) => run(scope, ...args);
    let bound = null;
    return function retarget() {
        const next = readEnabled(scope) ? readTarget(scope) ?? null : null;
        if (next === bound)
            return bound;
        if (bound)
            signalOf(bound).disconnect(handler);
        bound = next;
        if (bound)
            signalOf(bound).connect(handler);
        return bound;
    };
}

// The codec selector is a sibling of the Control Center detail and outlives it, so a handler
// connected while showing it is still registered after the detail collapses.
function makeCodecHost() {
    const updates = [];
    const selector = {
        codecSelected: signal(),
        shown: [],
        show(device) {
            this.shown.push(device);
        },
    };
    const scope = {
        root: { bluetoothCodecSelector: selector },
        bluetoothDetail: {
            updateDeviceCodecDisplay: (address, codec) => updates.push([address, codec]),
        },
    };
    const blocks = detailHost.handlers("onShowCodecSelector");
    assert.equal(blocks.length, 1,
        `DetailHost.qml must declare onShowCodecSelector once, found ${blocks.length}`);
    // eslint-disable-next-line no-new-func
    const onShow = new Function("scope", "device", `with (scope) ${blocks[0]}`);
    // Creating the detail binds whatever the file connects declaratively; nothing else does.
    const bound = connectionsElement(
        detailHost, "DetailHost.qml", scope, "onCodecSelected", target => target.codecSelected)();
    assert.equal(bound, selector, "the declared connection targets the selector the detail shows");
    return { selector, updates, showCodecSelector: device => onShow(scope, device) };
}

// The window-rule modal lives in a LazyLoader outside the settings tab. The loader creates its
// item on the first open and keeps it, so the item outlives every later open too. The tab's own
// loader keeps it alive once visited, so `pageActive` — bound by SettingsContent to whether this
// tab is the one on screen — is the only thing that says the user is looking at it.
function makeRulesTab(pageActive = true) {
    // QML reaches one signal under both spellings: `ruleSubmitted` and the handler property
    // `onRuleSubmitted`. Connecting through either registers on the same signal.
    const modal = { ruleSubmitted: signal(), calls: [] };
    modal.onRuleSubmitted = modal.ruleSubmitted;
    for (const name of ["show", "showEdit", "showCopy"])
        modal[name] = argument => modal.calls.push([name, argument]);
    // Quickshell's LazyLoader creates its item when active turns true and keeps it from then on,
    // so a path that activates the loader reads item on the very next line. The target binding
    // then re-evaluates and Qt moves the Connections element's single connection to that item.
    const loader = { item: null };
    let loaderActive = false;
    Object.defineProperty(loader, "active", {
        get: () => loaderActive,
        set(value) {
            loaderActive = value;
            if (!value || loader.item)
                return;
            loader.item = modal;
            retarget();
        },
    });
    const warnings = [];
    const loads = [];
    const countLoad = () => loads.push(true);
    const scope = {
        readOnly: false,
        pageActive: pageActive,
        PopoutService: { windowRuleModalLoader: loader },
        showReadOnlyWarning: () => warnings.push(true),
        loadWindowRules: countLoad,
    };
    scope.root = scope;
    const retarget = connectionsElement(
        windowRulesTab, "WindowRulesTab.qml", scope, "onRuleSubmitted",
        target => target.ruleSubmitted);
    assert.equal(retarget(), null, "an inactive loader has no item to connect to yet");
    // _openModal holds the guard and the activation the three public paths share, so the model
    // runs the shipped helper rather than a second copy of what it does.
    scope._openModal = present =>
        shippedFunction(windowRulesTabText, windowRulesTab, "WindowRulesTab.qml", "_openModal")(
            scope, present);
    const open = {};
    for (const name of ["openRuleModal", "editRule", "copyRuleToVgs"]) {
        const fn = shippedFunction(windowRulesTabText, windowRulesTab, "WindowRulesTab.qml", name);
        open[name] = argument => fn(scope, argument);
    }
    return {
        modal,
        loads,
        warnings,
        open,
        connectedCount: () => modal.ruleSubmitted.count,
        setReadOnly: value => {
            scope.readOnly = value;
        },
        // SettingsContent binds pageActive to whether this tab is on screen; the element's
        // enabled binding reads it, so Qt drops and restores the connection with it.
        setPageActive: value => {
            scope.pageActive = value;
            retarget();
        },
    };
}

test("one codec selection updates the detail once, however often the selector was shown", () => {
    const host = makeCodecHost();
    for (let i = 0; i < OPENS; i++)
        host.showCodecSelector({ address: "AA:BB" });
    assert.equal(host.selector.shown.length, OPENS, "every open still shows the selector");
    assert.equal(host.selector.codecSelected.count, 1,
        `showing the selector ${OPENS} times left ${host.selector.codecSelected.count} handlers ` +
        "on a selector that outlives the detail; each later selection runs them all");
    host.selector.codecSelected.emit("AA:BB", "aptX");
    assert.deepEqual(host.updates, [["AA:BB", "aptX"]],
        "the chosen codec reaches the detail exactly once");
});

test("a codec selection reaches the detail before any open has connected anything", () => {
    const host = makeCodecHost();
    host.selector.codecSelected.emit("CC:DD", "LDAC");
    assert.deepEqual(host.updates, [["CC:DD", "LDAC"]],
        "the detail listens for its whole lifetime, not from its first open onward");
});

test("one rule submission re-reads the rule list once, however often the modal was opened", () => {
    for (const name of ["openRuleModal", "editRule", "copyRuleToVgs"]) {
        const tab = makeRulesTab();
        for (let i = 0; i < OPENS; i++)
            tab.open[name]({ id: i });
        assert.equal(tab.modal.calls.length, OPENS, `${name} still opens the modal every time`);
        assert.equal(tab.modal.ruleSubmitted.count, 1,
            `${name} run ${OPENS} times left ${tab.modal.ruleSubmitted.count} handlers on a modal ` +
            "that outlives the tab; each later submission re-reads the rule list once per handler");
        tab.loads.length = 0;
        tab.modal.ruleSubmitted.emit();
        assert.equal(tab.loads.length, 1, `${name}: one submission re-reads the rule list once`);
    }
});

test("the three open paths share one registration rather than one each", () => {
    const tab = makeRulesTab();
    tab.open.openRuleModal(null);
    tab.open.editRule({ id: 1 });
    tab.open.copyRuleToVgs({ id: 2 });
    assert.deepEqual(tab.modal.calls.map(call => call[0]), ["show", "showEdit", "showCopy"],
        "each path opens the modal its own way");
    assert.equal(tab.modal.ruleSubmitted.count, 1,
        "the tab connects to the modal once, not once per path that can open it");
    tab.loads.length = 0;
    tab.modal.ruleSubmitted.emit();
    assert.equal(tab.loads.length, 1, "one submission re-reads the rule list once");
});

test("a submission reaching a tab the user is not on re-reads nothing", () => {
    const tab = makeRulesTab();
    tab.open.editRule({ id: 1 });
    tab.setPageActive(false);
    assert.equal(tab.connectedCount(), 0,
        "a tab the user left is not connected; the rule modal also opens from IPC, and a " +
        "submission would otherwise spawn the list helper and could raise a toast off-screen");
    tab.loads.length = 0;
    tab.modal.ruleSubmitted.emit();
    assert.equal(tab.loads.length, 0, "so nothing re-reads the rule list");
    // onPageActiveChanged re-reads the list on return, so the gate costs no freshness.
    tab.setPageActive(true);
    assert.equal(tab.connectedCount(), 1, "returning to the tab connects it again, once");
});

test("a tab the user is on is connected for real, not declared and disabled", () => {
    const tab = makeRulesTab();
    tab.open.editRule({ id: 1 });
    assert.equal(tab.connectedCount(), 1, "the element the tab declares is a live connection");
    tab.modal.ruleSubmitted.emit();
    assert.equal(tab.loads.length, 1, "and a submission re-reads the rule list");
});

test("a read-only compositor warns, opens nothing, and connects nothing", () => {
    const tab = makeRulesTab();
    tab.setReadOnly(true);
    for (const name of ["openRuleModal", "editRule", "copyRuleToVgs"])
        tab.open[name]({ id: 1 });
    assert.equal(tab.modal.calls.length, 0, "a read-only compositor opens no modal");
    assert.equal(tab.warnings.length, 3, "each refused path warns");
    assert.equal(tab.modal.ruleSubmitted.count, 0,
        "and the loader never activated, so nothing is connected to its item");
});
