#!/usr/bin/env node
"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { extractBlock } = require("./lib/qml-block.js");
const base = path.resolve(__dirname, "../quickshell/vshell");
const read = file => fs.readFileSync(path.join(base, file), "utf8");
const registryBody = extractBlock(read("Modals/Settings/SettingsRegistry.qml"), "Singleton {")
    .replace("id: root", "").replace("readonly property var tabs:", "const tabs =");
const registry = new Function(registryBody + "; return { tabs, tabIndexFor };")();
assert.ok(registry.tabs.some(tab => tab.id === "typography"));
const source = read("Modals/Settings/SettingsNavigation.qml");

function navigation(text, overrides = {}) {
    const body = extractBlock(text, "Singleton {").replace("readonly property var categories:", "const categories =");
    const services = {
        SettingsRegistry: registry,
        I18n: { tr: text => text },
        CompositorService: { isHyprland: true, isNiri: false, isMango: false },
        NetworkService: { usingLegacy: false },
        CupsService: { cupsAvailable: true },
        KeybindsService: { available: true },
        AudioService: { soundsAvailable: true },
        VGSBackendService: { isConnected: true, capabilities: ["clipboard"], methods: ["clipboard.getConfig"] },
        DesktopService: { autostartAvailable: true },
        ...overrides
    };
    return new Function(...Object.keys(services), body + "; return { categories, tabsFor, pageIds };")(...Object.values(services));
}

function checkNavigation(text) {
    const nav = navigation(text);
    assert.deepEqual(nav.pageIds().slice().sort(), registry.tabs.map(tab => tab.id).sort());
    const order = nav.categories.map(category => category.id);
    assert.equal(order.indexOf("displays") + 1, order.indexOf("personalization"));
    assert.equal(order.indexOf("personalization") + 1, order.indexOf("dock_launcher"));
    assert.ok(order.indexOf("workspaces_widgets") < order.indexOf("windows"));
    for (const category of nav.categories.filter(category => category.children)) {
        for (const tab of category.children)
            assert.deepEqual(nav.tabsFor(tab.tabIndex).map(item => item.id), category.children.map(item => item.id));
    }
    assert.deepEqual(nav.tabsFor(-1), []);
    assert.deepEqual(nav.tabsFor(registry.tabIndexFor("about")), []);
    for (const [service, state, page] of [
        ["AudioService", { soundsAvailable: false }, "sounds"],
        ["CupsService", { cupsAvailable: false }, "printers"],
        ["KeybindsService", { available: false }, "keybinds"],
        ["NetworkService", { usingLegacy: true }, "network_wifi"],
        ["VGSBackendService", { isConnected: false, capabilities: [], methods: [] }, "clipboard"],
        ["DesktopService", { autostartAvailable: false }, "autostart"]
    ]) {
        const limited = navigation(text, { [service]: state });
        assert.ok(!limited.pageIds().includes(page), page);
        assert.ok(!limited.tabsFor(registry.tabIndexFor(page)).some(item => item.id === page), page);
    }
}
checkNavigation(source);
const unfiltered = source.replace("group.children.filter(item => isItemVisible(item))", "group.children");
assert.notEqual(unfiltered, source);
assert.throws(() => checkNavigation(unfiltered), assert.AssertionError);

const scrollBody = extractBlock(read("Services/SettingsSearchService.qml"), "function scrollToTarget()");
function checkSearch(body) {
    let timerCalls = 0;
    const contentItem = {};
    const outer = { parent: contentItem, collapsible: true, expanded: false };
    const inner = { parent: outer, collapsible: true, expanded: false };
    const item = { parent: inner, mapToItem: () => ({ y: 150 }) };
    const flickable = { contentItem, contentHeight: 600, height: 200, contentY: 0 };
    const state = {
        targetSection: "test", highlightSection: "",
        registeredCards: { test: { item, flickable } },
        scrollTimer: { restart: () => timerCalls++ },
        highlightTimer: { restart: () => {} }
    };
    const scroll = new Function("state", "with (state) {" + body + "}");
    scroll(state);
    assert.equal(outer.expanded, true);
    assert.equal(inner.expanded, true);
    assert.equal(flickable.contentY, 0, "wait for layout after expansion");
    assert.equal(timerCalls, 1);
    scroll(state);
    assert.equal(flickable.contentY, 134);
    assert.equal(state.highlightSection, "test");
    assert.equal(state.targetSection, "");
    state.targetSection = "missing";
    scroll(state);
    assert.equal(state.targetSection, "missing", "wait for lazy page registration");
}
checkSearch(scrollBody);
const collapsed = scrollBody.replace("ancestor.expanded = true", "ancestor.expanded = false");
assert.notEqual(collapsed, scrollBody);
assert.throws(() => checkSearch(collapsed), assert.AssertionError);
console.log("Settings navigation and search checks passed");
