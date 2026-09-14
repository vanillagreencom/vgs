#!/usr/bin/env node

// Drive ControlCenterPopout.qml's onEditModeChanged handler and the EditControls
// availableWidgets binding against a modelled popout scope. The probe,
// WidgetModel.getPluginWidgets(), instantiates every plugin widget and can reload a stale
// plugin, which writes the PluginService state it read. QML re-evaluates a binding on every
// dependency change, so each step below re-evaluates the binding and counts the probes: the
// widget library must probe once per edit-mode open, never on a re-evaluation.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const qmlSource = require("./lib/qml-source.js");

const POPOUT_QML = path.join(__dirname, "..", "quickshell", "vshell", "Modules", "ControlCenter",
    "ControlCenterPopout.qml");
const popout = qmlSource(fs.readFileSync(POPOUT_QML, "utf8"), "ControlCenterPopout.qml");

const handlerBlocks = popout.handlers("onEditModeChanged");
assert.equal(handlerBlocks.length, 1, "ControlCenterPopout.qml must define onEditModeChanged once");
const editControls = popout.objectBlocks("EditControls", 1)[0];
const bindingBlock = editControls.q.binding("availableWidgets").block;
assert.ok(bindingBlock, "EditControls.availableWidgets must be a block binding");

// Unqualified names resolve against the scope, as they do against the popout in QML.
const inScope = block => new Function("scope", `with (scope) ${block}`);
const runHandler = inScope(handlerBlocks[0]);
const evaluateBinding = inScope(bindingBlock);

const BASE = [
    { id: "wifi" },
    { id: "diskUsage", allowMultiple: true }
];
const PLUGINS = [{ id: "plugin_cloudSync" }, { id: "plugin_tailscale" }];

function popoutScope() {
    const scope = {
        editMode: false,
        pluginWidgetDefinitions: [],
        probes: 0,
        collapseAll() {},
        queueTargetPopupHeightUpdate() {},
        SettingsData: { controlCenterWidgets: [] },
        widgetModel: {
            baseWidgetDefinitions: BASE,
            getPluginWidgets() {
                scope.probes += 1;
                return PLUGINS.slice();
            }
        }
    };
    scope.root = scope;
    return scope;
}

test("the widget library probes plugin widgets once per edit-mode open", () => {
    // [why, steps, probes, offered ids after the last step]
    for (const [why, steps, probes, offered] of [
        ["closed edit mode offers nothing and probes nothing", [], 0, []],
        ["opening probes once and offers base and plugin widgets",
            ["open"], 1, ["wifi", "diskUsage", "plugin_cloudSync", "plugin_tailscale"]],
        ["re-evaluations while open reuse the snapshot, and a placed widget leaves the list",
            ["open", "place:plugin_cloudSync", "place:wifi", "reevaluate"], 1,
            ["diskUsage", "plugin_tailscale"]],
        ["a widget that allows several instances stays offered once placed",
            ["open", "place:diskUsage"], 1,
            ["wifi", "diskUsage", "plugin_cloudSync", "plugin_tailscale"]],
        ["closing drops the snapshot without probing", ["open", "close"], 1, []],
        ["each open probes again", ["open", "close", "open"], 2,
            ["wifi", "diskUsage", "plugin_cloudSync", "plugin_tailscale"]]
    ]) {
        const scope = popoutScope();
        let available = evaluateBinding(scope);
        for (const step of steps) {
            const [verb, id] = step.split(":");
            switch (verb) {
            case "open":
            case "close":
                scope.editMode = verb === "open";
                runHandler(scope);
                break;
            case "place":
                scope.SettingsData.controlCenterWidgets = scope.SettingsData.controlCenterWidgets.concat([{ id }]);
                break;
            case "reevaluate":
                break;
            default:
                assert.fail(`unknown step ${step}`);
            }
            available = evaluateBinding(scope);
        }
        assert.equal(scope.probes, probes, `${why}: probe count`);
        assert.deepEqual(available.map(w => w.id), offered, `${why}: offered widgets`);
        if (!scope.editMode)
            assert.deepEqual(scope.pluginWidgetDefinitions, [], `${why}: snapshot after close`);
    }
});
