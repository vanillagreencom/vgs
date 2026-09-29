#!/usr/bin/env node
// Checks for the Hyprland layer's decisions: the manifest's `hyprland` key
// and the key grammar in shell/Core/PluginLogic.js, a plugins row's `keys`
// under PluginLogic.configError, PluginLogic.hyprlandSection, the text
// shell/Core/HyprlandLayer.js renders, and the writer's sequence,
// HyprlandLayer.step. Both files load under node through
// bin/lib/qml-library.js, as the shell loads them.
//
// The controls at the end edit a copy of one file, one rule at a time, and
// the suite must fail on every copy. Exit 1 when a row or a control fails.
"use strict";
const assert = require("assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { load } = require("../bin/lib/qml-library.js");

// A library's objects come from another realm, so they are compared as the
// JSON they write.
const same = (got, want, message) => assert.deepStrictEqual(JSON.parse(JSON.stringify(got === undefined ? null : got)), JSON.parse(JSON.stringify(want === undefined ? null : want)), message);

const logicFile = path.join(__dirname, "..", "shell", "Core", "PluginLogic.js");
const layerFile = path.join(__dirname, "..", "shell", "Core", "HyprlandLayer.js");

const service = { schemaVersion: 1, id: "acme.keys", name: "K", version: "1.0.0", author: "a", description: "d", kinds: ["service"], entryPoints: { service: "S.qml" }, capabilities: ["shortcut"] };
const overlayRule = { namespace: "^vgs:overlay$", blur: true, ignoreAlpha: 0.6 };
const toggle = { shortcut: "toggle", key: "SUPER+SPACE" };
// The border colours as Theme publishes them, `#aarrggbb`.
const colours = { accent: "#ff5a3659", border: "#80112233", borderSubtle: "#ff222222", warning: "#ffffaa00", surfaceRaised: "#ff333333", onAccent: "#ff000000", text: "#ffeeeeee", onWarning: "#ff010101" };
// The floating TUIs' window rules as the layer writes them, byte for byte:
// in the Lua literal `\\.` is the regex `\.`, a literal dot. Hyprland
// v0.56.2 reads these fields back in scripts/smoke/rows/hyprland.sh.
const TUI_SECTION = [
    "-- Floating TUIs: each size class's app-id floats, centred, at its size.",
    "hl.window_rule({ name = \"vgs:tui\", match = { class = \"^org\\\\.vgs\\\\.tui$\" }, float = true, center = true, size = { 875, 600 } })",
    "hl.window_rule({ name = \"vgs:tui-wide\", match = { class = \"^org\\\\.vgs\\\\.tui\\\\.wide$\" }, float = true, center = true, size = { 1200, 720 } })",
    "hl.window_rule({ name = \"vgs:tui-tall\", match = { class = \"^org\\\\.vgs\\\\.tui\\\\.tall$\" }, float = true, center = true, size = { 875, 900 } })"
];

// hyprlandKey rows: [text, want key or the start of the error].
const KEYS = [
    ["SUPER+SPACE", { key: "SUPER+SPACE" }],
    ["super + space", { key: "SUPER+SPACE" }],
    ["SHIFT+SUPER+n", { key: "SUPER+SHIFT+N" }],
    ["ALT+CTRL+SHIFT+SUPER+F1", { key: "SUPER+CTRL+ALT+SHIFT+F1" }],
    ["F12", { key: "F12" }],
    ["XF86AudioMute", { key: "XF86AUDIOMUTE" }],
    [7, { error: "must be a string" }],
    ["SUPER+", { error: "has an empty part" }],
    ["SUPER++N", { error: "has an empty part" }],
    ["SUPER", { error: "ends in the modifier SUPER" }],
    ["SUPER+HYPER+N", { error: "has the unknown modifier \"HYPER\"" }],
    ["SUPER+super+N", { error: "repeats the modifier SUPER" }],
    ["SUPER+a-b", { error: "names no key" }],
    ["SUPER+\"", { error: "names no key" }]
];

// validateManifest rows over `service`: [name, patch, want error start or null].
const MANIFESTS = [
    ["binds and a layer rule", { hyprland: { binds: [toggle], layerRules: [overlayRule] } }, null],
    ["a layer rule alone, with no shortcut capability", { capabilities: [], hyprland: { layerRules: [{ namespace: "^vgs:layer$", blur: true }] } }, null],
    ["a rule setting ignoreAlpha alone", { hyprland: { layerRules: [{ namespace: "^vgs:layer$", ignoreAlpha: 0 }] } }, null],
    ["hyprland not an object", { hyprland: [] }, "hyprland must be an object"],
    ["hyprland with an unknown key", { hyprland: { binds: [toggle], windowRules: [] } }, "hyprland has unknown key \"windowRules\""],
    ["binds not a list", { hyprland: { binds: toggle } }, "hyprland.binds must be a list"],
    ["layerRules not a list", { hyprland: { layerRules: overlayRule } }, "hyprland.layerRules must be a list"],
    ["no binds and no rules", { hyprland: { binds: [], layerRules: [] } }, "hyprland declares no binds and no layer rules"],
    ["binds without capability shortcut", { capabilities: [], hyprland: { binds: [toggle] } }, "hyprland.binds needs capability shortcut"],
    ["a bind that is no object", { hyprland: { binds: ["toggle"] } }, "hyprland.binds.0 must be an object"],
    ["a bind with an unknown key", { hyprland: { binds: [{ shortcut: "toggle", key: "SUPER+N", lua: "x" }] } }, "hyprland.binds.0 has unknown key \"lua\""],
    ["a bind naming no shortcut", { hyprland: { binds: [{ key: "SUPER+N" }] } }, "hyprland.binds.0.shortcut must be a shortcut name"],
    ["a malformed shortcut name", { hyprland: { binds: [{ shortcut: "Toggle", key: "SUPER+N" }] } }, "hyprland.binds.0.shortcut must be a shortcut name"],
    ["a shortcut bound twice", { hyprland: { binds: [toggle, { shortcut: "toggle", key: "SUPER+N" }] } }, "hyprland.binds.1.shortcut toggle is bound twice"],
    ["a key the grammar refuses", { hyprland: { binds: [{ shortcut: "toggle", key: "SUPER+" }] } }, "hyprland.binds.0.key has an empty part"],
    ["a modifier after the key", { hyprland: { binds: [toggle, { shortcut: "open", key: "space+super" }] } }, "hyprland.binds.1.key ends in the modifier SUPER"],
    ["one key bound twice", { hyprland: { binds: [toggle, { shortcut: "open", key: "super + space" }] } }, "hyprland.binds.1.key SUPER+SPACE is bound twice"],
    ["a rule that is no object", { hyprland: { layerRules: ["^vgs:overlay$"] } }, "hyprland.layerRules.0 must be an object"],
    ["a rule with an unknown key", { hyprland: { layerRules: [{ namespace: "^vgs:overlay$", blur: true, xray: true }] } }, "hyprland.layerRules.0 has unknown key \"xray\""],
    ["an unanchored namespace", { hyprland: { layerRules: [{ namespace: "vgs:overlay", blur: true }] } }, "hyprland.layerRules.0.namespace must be ^vgs:<name>$"],
    ["another application's namespace", { hyprland: { layerRules: [{ namespace: "^waybar$", blur: true }] } }, "hyprland.layerRules.0.namespace must be ^vgs:<name>$"],
    ["a namespace pattern wider than one name", { hyprland: { layerRules: [{ namespace: "^vgs:.*$", blur: true }] } }, "hyprland.layerRules.0.namespace must be ^vgs:<name>$"],
    ["a namespace with a rule already", { hyprland: { layerRules: [overlayRule, { namespace: "^vgs:overlay$", blur: false }] } }, "hyprland.layerRules.1.namespace ^vgs:overlay$ has a rule already"],
    ["a rule with no effect", { hyprland: { layerRules: [{ namespace: "^vgs:overlay$" }] } }, "hyprland.layerRules.0 sets neither blur nor ignoreAlpha"],
    ["blur not a boolean", { hyprland: { layerRules: [{ namespace: "^vgs:overlay$", blur: "yes" }] } }, "hyprland.layerRules.0.blur must be a boolean"],
    ["ignoreAlpha above 1", { hyprland: { layerRules: [{ namespace: "^vgs:overlay$", ignoreAlpha: 1.5 }] } }, "hyprland.layerRules.0.ignoreAlpha must be a number from 0 to 1"],
    ["ignoreAlpha below 0", { hyprland: { layerRules: [{ namespace: "^vgs:overlay$", ignoreAlpha: -0.1 }] } }, "hyprland.layerRules.0.ignoreAlpha must be a number from 0 to 1"],
    ["ignoreAlpha a string", { hyprland: { layerRules: [{ namespace: "^vgs:overlay$", ignoreAlpha: "0.6" }] } }, "hyprland.layerRules.0.ignoreAlpha must be a number from 0 to 1"],
    ["a default setting named keys", { settings: { keys: {} } }, "settings must not carry a keys key"]
];

// configError rows over a plugins row's `keys`: [name, keys, want error start or ""].
const CONFIG_KEYS = [
    ["a key and an unbinding null", { toggle: "super+space", inbox: null }, ""],
    ["a name no bind declares", { later: "SUPER+L" }, ""],
    ["keys not an object", ["SUPER+SPACE"], "plugins.0.keys must be an object"],
    ["a malformed name", { Toggle: "SUPER+SPACE" }, "plugins.0.keys.Toggle is not a shortcut name"],
    ["a key the grammar refuses", { toggle: "SUPER+" }, "plugins.0.keys.toggle has an empty part"],
    ["a key that is a number", { toggle: 32 }, "plugins.0.keys.toggle must be a string"]
];

function manifestOf(logic, patch) {
    const r = logic.validateManifest(Object.assign(JSON.parse(JSON.stringify(service)), patch), "/p");
    assert.ok(r.ok, "fixture manifest refused: " + r.error);
    return r.manifest;
}

function verify(logic, layer) {
    for (const [text, want] of KEYS) {
        const got = logic.hyprlandKey(text);
        if (want.key !== undefined) same(got, { ok: true, key: want.key }, "hyprlandKey " + JSON.stringify(text));
        else assert.ok(!got.ok && got.error.startsWith(want.error), "hyprlandKey " + JSON.stringify(text) + " refused with " + JSON.stringify(want.error) + ", got " + JSON.stringify(got));
    }
    for (const [name, patch, want] of MANIFESTS) {
        const r = logic.validateManifest(Object.assign(JSON.parse(JSON.stringify(service)), patch), "/p");
        if (want === null) assert.ok(r.ok, "manifest " + name + " accepted, got " + r.error);
        else assert.ok(!r.ok && r.error.startsWith(want), "manifest " + name + " refused with " + JSON.stringify(want) + ", got " + JSON.stringify(r.ok ? "accepted" : r.error));
    }
    const declared = manifestOf(logic, { hyprland: { binds: [{ shortcut: "toggle", key: "super + space" }, { shortcut: "inbox", key: "SUPER+N" }], layerRules: [overlayRule] } });
    same(declared.hyprland, { binds: [{ shortcut: "toggle", key: "SUPER+SPACE" }, { shortcut: "inbox", key: "SUPER+N" }], layerRules: [overlayRule] }, "a normalised manifest holds normalised keys");
    same(manifestOf(logic, { hyprland: { layerRules: [overlayRule] } }).hyprland.binds, [], "a normalised manifest without binds holds none");
    assert.strictEqual(manifestOf(logic, {}).hyprland, undefined, "a manifest declaring no hyprland key carries none");

    for (const [name, keys, want] of CONFIG_KEYS) {
        const got = logic.configError({ plugins: [{ id: "acme.keys", keys: keys }] });
        assert.ok(want === "" ? got === "" : got.startsWith(want), "configError " + name + ": want " + JSON.stringify(want) + ", got " + JSON.stringify(got));
    }
    const config = { plugins: [{ id: "acme.keys", keys: { toggle: "ctrl+super+t", inbox: null, later: "SUPER+L", early: null }, size: 3 }] };
    same(logic.settingsFor(config, declared, "plugins", null), { size: 3 }, "a plugins row's keys are no setting");
    same(logic.hyprlandSection(config, declared), {
        id: "acme.keys", version: "1.0.0",
        binds: [{ shortcut: "toggle", key: "SUPER+CTRL+T" }, { shortcut: "inbox", key: null }],
        layerRules: [overlayRule],
        unknownKeys: ["early", "later"]
    }, "hyprlandSection takes the row's keys over the manifest's and names the unknown ones");
    same(logic.hyprlandSection({}, declared).binds, declared.hyprland.binds, "hyprlandSection keeps the manifest's keys without a row");
    same(logic.hyprlandSection(config, manifestOf(logic, {})), { id: "acme.keys", version: "1.0.0", binds: [], layerRules: [], unknownKeys: ["early", "inbox", "later", "toggle"] }, "a manifest asking nothing leaves every row name unknown");

    const section = (id, binds, layerRules, version) => ({ id: id, version: version || "1.0.0", binds: binds, layerRules: layerRules, unknownKeys: [] });
    const lines = out => out.text.split("\n");
    const bare = layer.render([], colours, "vgs");
    same(lines(bare).slice(lines(bare).indexOf("})") + 1), ["", ...TUI_SECTION, ""], "a layer with no plugin section ends with the floating TUIs' window rules, right after the border colours");
    assert.ok(lines(bare).some(line => line.includes("`" + layer.REGENERATE + "`")), "the header names the regenerate command");
    assert.strictEqual(layer.REGENERATE, "vgsh hypr render", "the regenerate command is the runner's verb");
    assert.ok(lines(bare).includes("-- Theme vgs: window, group and group bar borders."), "the border block names its theme");
    assert.ok(lines(bare).includes("            active_border = \"rgba(5a3659ff)\","), "a #aarrggbb accent is written rgba(rrggbbaa)");
    assert.ok(lines(bare).includes("            inactive_border = \"rgba(11223380)\","), "the border keeps its alpha last");
    assert.ok(lines(bare).includes("            text_color_locked_active = \"rgba(010101ff)\","), "the group bar's text colour is written");
    assert.throws(() => layer.render([], Object.assign({}, colours, { accent: "#5a36" }), "vgs"), /colour accent must be #aarrggbb/, "a colour Theme never publishes is refused");

    const out = layer.render([
        section("vgs.notes", [{ shortcut: "inbox", key: "SUPER+N" }, { shortcut: "open", key: "SUPER+SPACE" }], [{ namespace: "^vgs:layer$", blur: true, ignoreAlpha: 0.6 }, overlayRule]),
        section("acme.keys", [{ shortcut: "toggle", key: "SUPER+SPACE" }, { shortcut: "gone", key: null }], [overlayRule, { namespace: "^vgs:layer$", blur: false }], "2\nos.exit()"),
        section("acme.quiet", [], [])
    ], colours, "night\nos.exit()");
    const text = lines(out);
    const tail = text.slice(text.indexOf("})") + 1);
    same(tail, [
        "",
        ...TUI_SECTION,
        "",
        "-- acme.keys 2?os.exit(): binds and layer rules from its manifest",
        "hl.layer_rule({ name = \"acme.keys:overlay\", match = { namespace = \"^vgs:overlay$\" }, blur = true, ignore_alpha = 0.6 })",
        "hl.layer_rule({ name = \"acme.keys:layer\", match = { namespace = \"^vgs:layer$\" }, blur = false })",
        "hl.bind(\"SUPER + SPACE\", hl.dsp.global(\"acme.keys:toggle\"), { description = \"acme.keys:toggle\" })",
        "-- unbound acme.keys:gone: shell.json sets its key to null",
        "",
        "-- vgs.notes 1.0.0: binds and layer rules from its manifest",
        "hl.layer_rule({ name = \"vgs.notes:layer\", match = { namespace = \"^vgs:layer$\" }, blur = true, ignore_alpha = 0.6 })",
        "-- layer rule for ^vgs:overlay$ already written by acme.keys",
        "hl.bind(\"SUPER + N\", hl.dsp.global(\"vgs.notes:inbox\"), { description = \"vgs.notes:inbox\" })",
        "-- skipped SUPER+SPACE: already bound by acme.keys",
        ""
    ], "the floating TUIs' rules, then sections by id, rules then binds, a key to the first id, an identical rule once, a differing one twice");
    assert.ok(text.includes("-- Theme night?os.exit(): window, group and group bar borders."), "a theme name cannot leave its comment");
    same(out.conflicts, [{ id: "vgs.notes", shortcut: "open", key: "SUPER+SPACE", heldBy: "acme.keys" }], "the skipped bind is the one conflict");

    for (const [name, events, wantActions, wantState] of SEQUENCES) {
        let state = layer.initialState();
        const actions = [];
        for (const [event, text] of events) {
            const next = layer.step(state, event, text);
            state = next.state;
            actions.push(next.action);
        }
        same(actions, wantActions, "step " + name + ": actions");
        const picked = {};
        for (const key of Object.keys(wantState)) picked[key] = state[key];
        same(picked, wantState, "step " + name + ": state");
    }
    assert.throws(() => layer.step(layer.initialState(), { type: "saved" }, "T1"), /event saved arrived in phase reading, want writing/, "a step result out of its phase is refused");
    assert.throws(() => layer.step(layer.initialState(), { type: "later" }, "T1"), /unknown event "later"/, "an unknown event is refused");
}

// HyprlandLayer.step rows: [name, [[event, text]...], actions, state subset].
// T0 is what the file held, T1 and T2 what the shell renders.
const loaded = content => ({ type: "loaded", content: content });
const absent = { type: "loadFailed", notFound: true, detail: "" };
const render = { type: "render" };
const force = { type: "force" };
const mkdirOk = { type: "mkdirDone", failure: "" };
const saved = { type: "saved" };
const saveFailed = { type: "saveFailed", failure: "write=failed error=4" };
const reloaded = { type: "reloadDone", failure: "" };
const SEQUENCES = [
    ["a first run writes, wires and reloads",
        [[absent, "T1"], [mkdirOk, "T1"], [saved, "T1"], [{ type: "wireDone" }, "T1"], [reloaded, "T1"]],
        ["mkdir", "write", "wire", "reload", "none"], { phase: "idle", onDisk: "T1", firstRun: false, failure: "" }],
    ["a file holding the text is left", [[loaded("T1"), "T1"]], ["none"], { phase: "idle", onDisk: "T1" }],
    ["a changed file is written and reloaded, not wired",
        [[loaded("T0"), "T1"], [mkdirOk, "T1"], [saved, "T1"], [reloaded, "T1"]],
        ["mkdir", "write", "reload", "none"], { phase: "idle", onDisk: "T1" }],
    ["a render during a cycle waits for it, then writes its text",
        [[loaded("T0"), "T1"], [render, "T2"], [mkdirOk, "T2"], [saved, "T2"], [reloaded, "T2"], [mkdirOk, "T2"]],
        ["mkdir", "none", "write", "reload", "mkdir", "write"], { phase: "writing", pending: "T2", onDisk: "T1" }],
    ["a failed save reads the file before another write and retries its text only once the text changes",
        [[loaded("T0"), "T1"], [mkdirOk, "T1"], [saveFailed, "T1"], [loaded("T0"), "T1"], [render, "T1"], [render, "T2"], [mkdirOk, "T2"], [saved, "T2"], [reloaded, "T2"]],
        ["mkdir", "write", "read", "none", "none", "mkdir", "write", "reload", "none"], { phase: "idle", onDisk: "T2", failedText: null, stale: false, failure: "" }],
    ["a render after a failed save rereads and writes the same text again",
        [[loaded("T0"), "T1"], [mkdirOk, "T1"], [saveFailed, "T1"], [loaded("T0"), "T1"], [force, "T1"], [loaded("T0"), "T1"], [mkdirOk, "T1"], [saved, "T1"], [reloaded, "T1"]],
        ["mkdir", "write", "read", "none", "read", "mkdir", "write", "reload", "none"], { phase: "idle", onDisk: "T1", forcing: false, failedText: null }],
    ["a failed mkdir tries its text once",
        [[loaded("T0"), "T1"], [{ type: "mkdirDone", failure: "mkdir=failed status=1" }, "T1"], [render, "T1"]],
        ["mkdir", "none", "none"], { phase: "idle", failedText: "T1", failure: "mkdir=failed status=1" }],
    ["a render during a reload, after the file was removed, writes it again",
        [[loaded("T0"), "T1"], [mkdirOk, "T1"], [saved, "T1"], [force, "T1"], [reloaded, "T1"], [absent, "T1"], [mkdirOk, "T1"], [saved, "T1"], [reloaded, "T1"]],
        ["mkdir", "write", "reload", "none", "read", "mkdir", "write", "reload", "none"], { phase: "idle", onDisk: "T1", queuedForce: false, forcing: false, firstRun: false }],
    ["a render of unchanged bytes reloads without a write",
        [[loaded("T1"), "T1"], [force, "T1"], [loaded("T1"), "T1"], [mkdirOk, "T1"], [reloaded, "T1"]],
        ["none", "read", "mkdir", "reload", "none"], { phase: "idle", onDisk: "T1", forcing: false }],
    ["a first read before the text waits, and wires after the first write",
        [[absent, null], [render, "T1"], [mkdirOk, "T1"], [saved, "T1"]],
        ["none", "mkdir", "write", "wire"], { phase: "wiring", firstRun: false }],
    ["an unreadable file is reported and written",
        [[{ type: "loadFailed", notFound: false, detail: "error=3" }, "T1"]],
        ["mkdir"], { onDisk: null, firstRun: false, failure: "read=failed error=3" }],
    ["a reread that finds no file is no first run",
        [[loaded("T1"), "T1"], [force, "T1"], [absent, "T1"], [mkdirOk, "T1"], [saved, "T1"]],
        ["none", "read", "mkdir", "write", "reload"], { firstRun: false }]
];

verify(load(logicFile), load(layerFile));

// Each control removes one rule from a copy of one file and keeps the text
// around it. The suite must fail on every copy.
const CONTROLS = [
    [logicFile, "hyprland is a manifest key", "\"appearance\", \"hyprland\", ", "\"appearance\", "],
    [logicFile, "key parts upper case", "return part.trim().toUpperCase();", "return part.trim();"],
    [logicFile, "modifier order", "var ordered = HYPRLAND_MODIFIERS.filter(function (mod) { return mods.indexOf(mod) !== -1; });", "var ordered = mods;"],
    [logicFile, "key string", "if (typeof text !== \"string\")\n        return { ok: false, error: \"must be a string", "if (false)\n        return { ok: false, error: \"must be a string"],
    [logicFile, "key empty part", "if (parts.some(function (part) { return part.length === 0; }))", "if (false)"],
    [logicFile, "key not a modifier", "if (HYPRLAND_MODIFIERS.indexOf(name) !== -1)\n        return", "if (false)\n        return"],
    [logicFile, "key name", "if (!HYPRLAND_KEY_NAME.test(name))", "if (false)"],
    [logicFile, "known modifier", "if (HYPRLAND_MODIFIERS.indexOf(mods[i]) === -1)", "if (false)"],
    [logicFile, "modifier once", "if (mods.indexOf(mods[i]) !== i)", "if (false)"],
    [logicFile, "hyprland object", "if (!isPlainObject(hyprland))", "if (false)"],
    [logicFile, "hyprland keys", "if (HYPRLAND_KEYS.indexOf(keys[u]) === -1)", "if (false)"],
    [logicFile, "binds list", "if (!Array.isArray(binds))", "if (false)"],
    [logicFile, "rules list", "if (!Array.isArray(rules))", "if (false)"],
    [logicFile, "declares something", "if (binds.length === 0 && rules.length === 0)", "if (false)"],
    [logicFile, "binds need shortcut", "if (binds.length > 0 && capabilities.indexOf(\"shortcut\") === -1)", "if (false)"],
    [logicFile, "bind object", "if (!isPlainObject(bind))", "if (false)"],
    [logicFile, "bind keys", "if (HYPRLAND_BIND_KEYS.indexOf(bindKeys[k]) === -1)", "if (false)"],
    [logicFile, "shortcut name", "if (typeof bind.shortcut !== \"string\" || !NAME_PATTERN.test(bind.shortcut))", "if (typeof bind.shortcut !== \"string\")"],
    [logicFile, "shortcut once", "if (shortcuts.indexOf(bind.shortcut) !== -1)", "if (false)"],
    [logicFile, "bind key judged", "if (!key.ok)\n            return at + \".key \" + key.error;", "if (false)\n            return at + \".key \" + key.error;"],
    [logicFile, "key once", "if (boundKeys.indexOf(key.key) !== -1)", "if (false)"],
    [logicFile, "rule object", "if (!isPlainObject(rule))", "if (false)"],
    [logicFile, "rule keys", "if (HYPRLAND_RULE_KEYS.indexOf(ruleKeys[q]) === -1)", "if (false)"],
    [logicFile, "namespace anchored", "var HYPRLAND_NAMESPACE = /^\\^vgs:[a-z][a-z0-9-]*\\$$/;", "var HYPRLAND_NAMESPACE = /vgs:/;"],
    [logicFile, "namespace once", "if (namespaces.indexOf(rule.namespace) !== -1)", "if (false)"],
    [logicFile, "rule has an effect", "if (rule.blur === undefined && rule.ignoreAlpha === undefined)", "if (false)"],
    [logicFile, "blur boolean", "if (rule.blur !== undefined && typeof rule.blur !== \"boolean\")", "if (false)"],
    [logicFile, "ignoreAlpha range", "rule.ignoreAlpha < 0 || rule.ignoreAlpha > 1))", "false))"],
    [logicFile, "keys setting reserved", "if (hasOwn(settings, \"keys\"))", "if (false)"],
    [logicFile, "manifest keys normalised", "return { shortcut: bind.shortcut, key: hyprlandKey(bind.key).key };", "return { shortcut: bind.shortcut, key: bind.key };"],
    [logicFile, "config keys judged", "if (config.plugins[p].keys !== undefined && (bad = keysError(", "if (false && (bad = keysError("],
    [logicFile, "keys object", "if (!isPlainObject(keys))\n        return at + \" must be an object\";", "if (false)\n        return at + \" must be an object\";"],
    [logicFile, "keys names", "if (!NAME_PATTERN.test(names[i]))", "if (false)"],
    [logicFile, "keys null unbinds", "if (keys[names[i]] === null)\n            continue;", "if (false)\n            continue;"],
    [logicFile, "keys values", "if (!key.ok)\n            return at + \".\" + names[i] + \" \" + key.error;", "if (false)\n            return at + \".\" + names[i] + \" \" + key.error;"],
    [logicFile, "keys no setting", "var ENTRY_RESERVED_KEYS = [\"id\", \"keys\"];", "var ENTRY_RESERVED_KEYS = [\"id\"];"],
    [logicFile, "row key wins", "if (!hasOwn(keys, bind.shortcut)) return { shortcut: bind.shortcut, key: bind.key };", "return { shortcut: bind.shortcut, key: bind.key };"],
    [logicFile, "null unbinds", "if (keys[bind.shortcut] === null) return { shortcut: bind.shortcut, key: null };", ""],
    [logicFile, "row key normalised", "return { shortcut: bind.shortcut, key: key.key };\n    });", "return { shortcut: bind.shortcut, key: keys[bind.shortcut] };\n    });"],
    [logicFile, "unknown keys", "return names.indexOf(name) === -1; }).sort()", "return false; }).sort()"],
    [layerFile, "sections by id", "sections.slice().sort(function (a, b) { return a.id < b.id ? -1 : a.id > b.id ? 1 : 0; })", "sections.slice()"],
    [layerFile, "empty section unwritten", "if (section.binds.length === 0 && section.layerRules.length === 0) return;", ""],
    [layerFile, "first id keeps a key", "if (held[bind.key] !== undefined) {", "if (false) {"],
    [layerFile, "unbound bind", "if (bind.key === null) {", "if (false) {"],
    [layerFile, "identical rule once", "if (written[key] !== undefined) {", "if (false) {"],
    [layerFile, "rule effects compared", "return JSON.stringify([rule.namespace, rule.blur", "return JSON.stringify([rule.namespace]); ([rule.namespace, rule.blur"],
    [layerFile, "comment text", "return String(text).replace(/[^\\x20-\\x7e]/g, \"?\");", "return String(text);"],
    [layerFile, "colour order", "return \"rgba(\" + value.slice(3, 9) + value.slice(1, 3) + \")\";", "return \"rgba(\" + value.slice(1, 9) + \")\";"],
    [layerFile, "colour judged", "if (typeof value !== \"string\" || !/^#[0-9a-fA-F]{8}$/.test(value))", "if (false)"],
    [layerFile, "bind keys spaced", "return key.split(\"+\").join(\" + \");", "return key;"],
    [layerFile, "floating TUI rules written", ".concat(borderLines(colours, themeName), [\"\"], tuiWindowLines());", ".concat(borderLines(colours, themeName));"],
    [layerFile, "floating TUI rules after the borders", ".concat(borderLines(colours, themeName), [\"\"], tuiWindowLines());", ".concat(tuiWindowLines(), [\"\"], borderLines(colours, themeName));"],
    [layerFile, "floating TUI class escapes each dot", ".join(\"\\\\\\\\.\")", ".join(\".\")"],
    [layerFile, "floating TUI class anchored", "return \"\\\"^\" + appId.split(\".\").join(\"\\\\\\\\.\") + \"$\\\"\";", "return \"\\\"\" + appId.split(\".\").join(\"\\\\\\\\.\") + \"\\\"\";"],
    [layerFile, "a stale view is read first", "if (state.queuedForce || state.stale)", "if (state.queuedForce)"],
    [layerFile, "a queued render reads first", "if (state.queuedForce || state.stale)", "if (state.stale)"],
    [layerFile, "a queued render forces its cycle", "forcing: state.forcing || state.queuedForce,", "forcing: state.forcing,"],
    [layerFile, "a failed text waits for a change", "(text === state.onDisk || text === state.failedText)", "(text === state.onDisk)"],
    [layerFile, "a forced cycle writes whatever the bytes", "if (!state.forcing && (text === state.onDisk", "if ((text === state.onDisk"],
    [layerFile, "a failed save leaves the view stale", "withChanges(state, { stale: true, failedText: state.pending })", "withChanges(state, { failedText: state.pending })"],
    [layerFile, "a failed mkdir keeps its text", "return settle(withChanges(state, { failedText: state.pending }), event.failure, text);", "return settle(state, event.failure, text);"],
    [layerFile, "held bytes skip the write", "if (state.pending === state.onDisk) return written(", "if (false) return written("],
    [layerFile, "a write clears the failed text", "{ onDisk: state.pending, failedText: null }", "{ onDisk: state.pending }"],
    [layerFile, "first run only on the first read", "(state.onDisk === undefined && event.notFound)", "event.notFound"],
    [layerFile, "a settled cycle stops forcing", "{ phase: \"idle\", failure: failure, forcing: false }", "{ phase: \"idle\", failure: failure }"],
    [layerFile, "a render waits for the step", "return state.phase === \"idle\" ? begin(state, text) : { state: state, action: \"none\" };", "return begin(state, text);"],
    [layerFile, "a render request starts when idle", "return state.phase === \"idle\" ? begin(queued, text) : { state: queued, action: \"none\" };", "return { state: queued, action: \"none\" };"],
    [layerFile, "a result out of its phase is refused", "if (state.phase !== phase)", "if (false)"],
    [layerFile, "an unreadable file is reported", "failure: event.notFound ? state.failure : \"read=failed \" + event.detail", "failure: state.failure"]
];

// A copy sits at its file's own place in a temporary tree, beside the icon
// set and the package-manager table PluginLogic.js imports.
const temp = fs.mkdtempSync(path.join(os.tmpdir(), "hyprland-layer-control-"));
try {
    fs.mkdirSync(path.join(temp, "shell", "Core"), { recursive: true });
    fs.mkdirSync(path.join(temp, "shell", "Ui", "icons"), { recursive: true });
    fs.symlinkSync(path.join(__dirname, "..", "shell", "Ui", "icons", "Lucide.js"), path.join(temp, "shell", "Ui", "icons", "Lucide.js"));
    fs.symlinkSync(path.join(__dirname, "..", "shell", "Core", "PackageManagers.js"), path.join(temp, "shell", "Core", "PackageManagers.js"));
    CONTROLS.forEach(([file, label, needle, replacement], index) => {
        const source = fs.readFileSync(file, "utf8");
        assert.equal(source.split(needle).length, 2, `control "${label}": the text to replace must occur once in ${path.basename(file)}`);
        const mutant = path.join(temp, "shell", "Core", `${index}-${path.basename(file)}`);
        fs.writeFileSync(mutant, source.replace(needle, () => replacement));
        // Loaded outside the try, so a copy that does not evaluate fails the
        // suite instead of passing for a control.
        const logic = load(file === logicFile ? mutant : logicFile);
        const layer = load(file === layerFile ? mutant : layerFile);
        let failed = false;
        try {
            verify(logic, layer);
        } catch (e) {
            failed = true;
        }
        assert.ok(failed, `control "${label}": the suite passed on ${path.basename(file)} without that rule`);
    });
} finally {
    fs.rmSync(temp, { recursive: true, force: true });
}
console.log(`test-hyprland-layer: ok keys=${KEYS.length} manifests=${MANIFESTS.length} config=${CONFIG_KEYS.length} steps=${SEQUENCES.length} controls=${CONTROLS.length}`);
