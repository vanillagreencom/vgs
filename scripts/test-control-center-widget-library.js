#!/usr/bin/env node

// Drive ControlCenterPopout.qml's onEditModeChanged handler and the EditControls
// availableWidgets binding, with WidgetModel.qml's getPluginWidgets() and
// createProbeInstance() as the probe, against a modelled PluginService. The probe
// instantiates every plugin widget and reloads a stale plugin, which writes the PluginService
// state it read. QML re-evaluates a binding on every dependency change, so each step below
// re-evaluates the binding and counts the probes: the widget library must probe once per
// edit-mode open, never on a re-evaluation, and a plugin the probe reloaded is offered in
// that same open.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const qmlSource = require("./lib/qml-source.js");
const { callInScope } = require("./lib/qml-block.js");

const CONTROL_CENTER = path.join(__dirname, "..", "quickshell", "vshell", "Modules", "ControlCenter");
const popout = qmlSource(fs.readFileSync(path.join(CONTROL_CENTER, "ControlCenterPopout.qml"), "utf8"),
    "ControlCenterPopout.qml");
const model = qmlSource(fs.readFileSync(path.join(CONTROL_CENTER, "Models", "WidgetModel.qml"), "utf8"),
    "WidgetModel.qml");

const handlerBlocks = popout.handlers("onEditModeChanged");
assert.equal(handlerBlocks.length, 1, "ControlCenterPopout.qml must define onEditModeChanged once");
const editControls = popout.objectBlocks("EditControls", 1)[0];
const bindingBlock = editControls.q.binding("availableWidgets").block;
assert.ok(bindingBlock, "EditControls.availableWidgets must be a block binding");
const pluginWidgetsBody = model.body("getPluginWidgets");
const probeBody = model.body("createProbeInstance");

const BASE = [
    { id: "wifi" },
    { id: "diskUsage", allowMultiple: true }
];
const PLUGIN_IDS = ["cloudSync", "tailscale"];
const ALL_OFFERED = ["wifi", "diskUsage", "plugin_cloudSync", "plugin_tailscale"];

const STALE_ERROR = "stale component";
const REBUILT_ERROR = "rebuilt component still throws";

// `error` is the message createObject throws, or null for a working component.
function widgetComponent(error) {
    return {
        createObject() {
            if (error)
                throw new TypeError(error);
            return { ccWidgetIcon: "extension", destroy() {} };
        }
    };
}

// `reloads` maps each plugin whose loaded component is stale to what reloadPlugin does for it:
// "fresh" rebuilds a working component, "stale" rebuilds one that still throws, "fails"
// returns false and keeps the old component, as loadPlugin does on a component error.
function pluginService(reloads) {
    const service = {
        reloaded: [],
        pluginWidgetComponents: Object.fromEntries(PLUGIN_IDS.map(id =>
            [id, widgetComponent(id in reloads ? STALE_ERROR : null)])),
        getLoadedPlugins: () => PLUGIN_IDS.map(id => ({ id, name: id })),
        reloadPlugin(id) {
            service.reloaded.push(id);
            switch (reloads[id]) {
            case "fresh":
            case "stale":
                service.pluginWidgetComponents = Object.assign({}, service.pluginWidgetComponents,
                    { [id]: widgetComponent(reloads[id] === "stale" ? REBUILT_ERROR : null) });
                return true;
            case "fails":
                return false;
            default:
                return assert.fail(`reloadPlugin called for ${id}, which the row does not mark stale`);
            }
        }
    };
    return service;
}

// Popout members are the handler's and binding's root; singletons are the outer scope, as in QML.
function popoutWorld(reloads = {}) {
    const service = pluginService(reloads);
    const modelScope = { PluginService: service, I18n: { tr: text => text } };
    const widgetModel = {
        baseWidgetDefinitions: BASE,
        warnings: [],
        log: { warn: (...args) => widgetModel.warnings.push(args) },
        createProbeInstance: pluginId => callInScope(probeBody, widgetModel, modelScope, ["pluginId"], [pluginId]),
        getPluginWidgets() {
            root.probes += 1;
            return callInScope(pluginWidgetsBody, widgetModel, modelScope);
        }
    };
    const root = {
        editMode: false,
        pluginWidgetDefinitions: [],
        probes: 0,
        collapseAll() {},
        queueTargetPopupHeightUpdate() {},
        widgetModel
    };
    const scope = { SettingsData: { controlCenterWidgets: [] } };
    return {
        root,
        scope,
        service,
        widgetModel,
        runHandler: () => callInScope(handlerBlocks[0], root, scope),
        evaluateBinding: () => callInScope(bindingBlock, root, scope)
    };
}

test("the widget library probes plugin widgets once per edit-mode open", () => {
    // [why, steps, probes, offered ids after the last step]
    for (const [why, steps, probes, offered] of [
        ["closed edit mode offers nothing and probes nothing", [], 0, []],
        ["opening probes once and offers base and plugin widgets", ["open"], 1, ALL_OFFERED],
        ["re-evaluations while open reuse the snapshot, and a placed widget leaves the list",
            ["open", "place:plugin_cloudSync", "place:wifi", "reevaluate"], 1,
            ["diskUsage", "plugin_tailscale"]],
        ["a widget that allows several instances stays offered once placed",
            ["open", "place:diskUsage"], 1, ALL_OFFERED],
        ["closing drops the snapshot without probing", ["open", "close"], 1, []],
        ["each open probes again", ["open", "close", "open"], 2, ALL_OFFERED]
    ]) {
        const world = popoutWorld();
        let available = world.evaluateBinding();
        for (const step of steps) {
            const [verb, id] = step.split(":");
            switch (verb) {
            case "open":
            case "close":
                world.root.editMode = verb === "open";
                world.runHandler();
                break;
            case "place":
                world.scope.SettingsData.controlCenterWidgets =
                    world.scope.SettingsData.controlCenterWidgets.concat([{ id }]);
                break;
            case "reevaluate":
                break;
            default:
                assert.fail(`unknown step ${step}`);
            }
            available = world.evaluateBinding();
        }
        assert.equal(world.root.probes, probes, `${why}: probe count`);
        assert.deepEqual(available.map(w => w.id), offered, `${why}: offered widgets`);
        if (!world.root.editMode)
            assert.deepEqual(world.root.pluginWidgetDefinitions, [], `${why}: snapshot after close`);
    }
});

test("a stale plugin the probe reloads is offered in the same open, or named and left out", () => {
    // [why, reloads, offered ids after one open, plugins reloaded,
    //  [plugin id, thrown message or undefined] named by each warning]
    for (const [why, reloads, offered, reloaded, warned] of [
        ["a reload that rebuilds a working component offers the plugin",
            { tailscale: "fresh" }, ALL_OFFERED, ["tailscale"], [["tailscale", STALE_ERROR]]],
        ["every stale plugin reloads once and each is offered",
            { cloudSync: "fresh", tailscale: "fresh" }, ALL_OFFERED, ["cloudSync", "tailscale"],
            [["cloudSync", STALE_ERROR], ["tailscale", STALE_ERROR]]],
        ["a rebuilt component that still throws leaves only that plugin out",
            { tailscale: "stale" }, ["wifi", "diskUsage", "plugin_cloudSync"], ["tailscale"],
            [["tailscale", STALE_ERROR], ["tailscale", REBUILT_ERROR], ["tailscale", undefined]]],
        ["a failed reload leaves only that plugin out",
            { tailscale: "fails" }, ["wifi", "diskUsage", "plugin_cloudSync"], ["tailscale"],
            [["tailscale", STALE_ERROR], ["tailscale", undefined]]]
    ]) {
        const world = popoutWorld(reloads);
        world.root.editMode = true;
        world.runHandler();
        const available = world.evaluateBinding();
        assert.equal(world.root.probes, 1, `${why}: probe count`);
        assert.deepEqual(available.map(w => w.id), offered, `${why}: offered widgets`);
        assert.deepEqual(world.service.reloaded, reloaded, `${why}: reloaded plugins`);
        assert.deepEqual(world.widgetModel.warnings.map(args => [args[1], args[3]]), warned, `${why}: warnings`);
    }
});
