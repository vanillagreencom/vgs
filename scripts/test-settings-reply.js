#!/usr/bin/env node
// Manager replies and Registry errors retain their machine contracts.
// This suite runs the Settings display mapper and its actual QML callers;
// controls remove mapping or success handling in disposable source copies.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { load } = require("../bin/lib/qml-library.js");
const dir = path.join(__dirname, "..", "shell", "plugins", "vgs.settings");
const file = path.join(dir, "Reply.js");
const windowSource = fs.readFileSync(path.join(dir, "Window.qml"), "utf8");
const pageSource = fs.readFileSync(path.join(dir, "PluginPage.qml"), "utf8");
const same = (got, want) => assert.deepEqual(JSON.parse(JSON.stringify(got)), want);

// Real producers: Plugins/Config, PluginLogic's setting/key/action/secret
// judges, SecretWriter, Registry.managerRows and HyprlandLayer.problems.
// The expected cause stays independent of the mapper's pattern table.
const CASES = [
    ["unknown: acme.missing", /plugin is no longer available/],
    ["refused: user-config=pending path=/fixture", /loading your settings/],
    ["refused: user-config=unparseable path=/fixture", /saved settings are invalid/],
    ["refused: user-config=malformed path=/fixture", /saved settings are invalid/],
    ["refused: user-config=unreadable path=/fixture", /could not read your settings/],
    ["refused: user-config=unwritable path=/fixture error=permission denied\nsecond line", /could not save this change/],
    ...["refused: disabled=acme.example", ...["action", "secret", "placed", "tui"].map(kind => `refused: ${kind}=example reason=disabled`)].map(raw => [raw, /Turn on this plugin/]),
    ["refused: bundled=acme.example", /included with VGS/],
    ...["undeclared", "entry=none"].map(reason => [`refused: setting=example ${reason}`, /setting is no longer available/]),
    ["refused: setting=example want=number", /Enter a number/],
    ["refused: setting=example want=string", /Enter text/],
    ["refused: setting=example want=boolean", /Use the switch/],
    ...["one-of-presets", "one-of:a|b"].map(want => [`refused: setting=example want=${want}`, /Choose a value from the list/]),
    ...["empty", "multiline", "too-long", "unclosed-quote", "no-field"].map(reason => [`refused: setting=example want=datetime-format reason=${reason}`, /date or time format is invalid/]),
    ["refused: setting=example want=at-least:0", /at least 0/],
    ["refused: setting=example want=at-most:40", /at most 40/],
    ["refused: key=example undeclared", /shortcut is no longer available/],
    ...["want=string-or-null", "must be a string such as SUPER+SPACE"].map(reason => [`refused: key=example ${reason}`, /Select the shortcut field/]),
    ...['has an empty part: "SUPER+"', "ends in the modifier SUPER and names no key", 'names no key: ""'].map(reason => [`refused: key=example ${reason}`, /shortcut needs a key/]),
    ['refused: key=example has the unknown modifier "META", want one of SUPER, SHIFT, CTRL, ALT, MOD2, MOD3, MOD5', /could not use this shortcut/],
    ["refused: key=example repeats the modifier SUPER", /shortcut repeats a key/],
    ["refused: placed=acme.example reason=no-bar-widget", /no bar item/],
    ...["refused: action=example reason=undeclared", "refused: tui=example reason=undeclared", "refused: tui=example reason=args"].map(raw => [raw, /action is no longer available/]),
    ["refused: action=example reason=not-offered", /setup step is not needed/],
    ["refused: requirements=acme.example reason=satisfied", /All tools are installed/],
    ["refused: notices=full limit=8", /Close an open setup notice/],
    ["refused: tui=core/plugin-add reason=launcher-missing", /missing its terminal launcher, xdg-terminal-exec/],
    ["refused: secret=slack:T0ACME reason=busy", /saving another account/],
    ...["undeclared", "unlisted"].map(reason => [`refused: secret=slack:T0ACME reason=${reason}`, /account is no longer available/]),
    ["refused: secret=slack:T0ACME reason=not-offered", /account has changed/],
    ["refused: secret=slack:T0ACME reason=value", /key on one line/],
    ["refused: secret write failed start-failed", /could not open the key store/],
    ["refused: secret write failed exit=1", /could not change the saved account/],
    ["build failed: service: refused: capability=notifications held-by=acme.other", /Another plugin uses this feature/],
    ["build failed: service: file:///fixture/Service.qml:12: No such type", /plugin could not start/],
    ["hyprland: SUPER+SPACE for acme.example:toggle skipped: already bound by acme.other:toggle", /Another plugin uses this shortcut/],
    ["hyprland: appearance declaration ignored for acme.example: already owned by acme.other", /Another plugin controls the window appearance/],
    ["hyprland: input:scroll_factor for acme.example:speed skipped: already set by acme.other:speed", /Another plugin controls this setting/],
    ["hyprland: input:scroll_factor for acme.example:speed skipped: want=at-most:2", /saved setting is invalid/],
    ["hyprland: shell.json keys.old names no bind of acme.example", /ignored a saved shortcut/]
];
// Already parsed device facts only. No device or compositor command runs.
const core = path.join(__dirname, "..", "shell", "Core");
const producer = load(path.join(core, "PluginLogic.js"));
const layer = load(path.join(core, "HyprlandLayer.js"));
const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, "smoke", "fixtures", "plugins", "acme.hyprland", "manifest.json"), "utf8"));
const problemsSource = fs.readFileSync(path.join(core, "HyprlandLayer.qml"), "utf8");
const problemBlocks = [...problemsSource.matchAll(/readonly property var problems: \{\n([\s\S]*?)^    \}/gm)];
assert.equal(problemBlocks.length, 1, "extractor: one actual HyprlandLayer.problems binding");
const HYPRLAND = [
    ["touchpad", false, ["fixture-touchpad"], "", null, null, null],
    ["touchpad", false, null, "", null, null, null],
    ["touchpad", false, [], "", null, "Hyprland lists no touchpad", /could not complete this action/],
    ["touchpad", false, null, "fixture-read-failed", null, "touchpads unread: fixture-read-failed", /could not complete this action/],
    ["touchpad", false, ['fixture-"touchpad'], "", null, "touchpad name refused", /could not complete this action/],
    ["touchpad", false, ["fixture-\\touchpad"], "", null, "touchpad name refused", /could not complete this action/],
    ["touchpad", false, ["fixture-\ntouchpad"], "", null, "touchpad name refused", /could not complete this action/],
    ["touchpad", false, ["fixture-touchpad"], "", "acme.other:touchpad", "already set by acme.other:touchpad", /Another plugin controls this setting/],
    ["touchpad", "false", [], "", null, "want=boolean", /saved setting is invalid/],
    ["repeatRate", "25", [], "", null, "want=number", /saved setting is invalid/],
    ["repeatRate", 0, [], "", null, "want=at-least:1", /saved setting is invalid/],
    ["repeatRate", 201, [], "", null, "want=at-most:200", /saved setting is invalid/],
    ["repeatRate", 25.5, [], "", null, "want=whole-number", /saved setting is invalid/],
    ["layouts", false, [], "", null, "want=string", /saved setting is invalid/],
    ["layouts", 'us"', [], "", null, "want=characters:" + layer.OPTION_STRING.source, /saved setting is invalid/]
];
for (const [setting, value, touchpads, failure, heldBy, reason, cause] of HYPRLAND) {
    const section = producer.hyprlandSection({ plugins: [{ id: manifest.id, [setting]: value }] }, manifest);
    const out = { written: [], conflicts: [], refusals: [] };
    const held = heldBy === null ? {} : { [manifest.hyprland.options[setting]]: heldBy };
    layer.optionLines(section, held, touchpads, failure, out);
    const errors = vm.runInNewContext("(() => {" + problemBlocks[0][1] + "})()", {
        Logic: producer, Registry: { manifests: {} }, sections: [section], monitorDocument: null,
        machine: { failure: "" }, rendered: { conflicts: [], appearanceConflicts: [], optionConflicts: out.conflicts, optionRefusals: out.refusals }
    });
    if (reason === null) {
        same(errors, []);
        assert.equal(out.written.length, touchpads === null ? 0 : 1, "a valid touchpad value is not refused");
    } else {
        assert.equal(errors.length, 1, "the shipped producer must reach the display");
        assert.equal(errors[0].error, `hyprland: ${manifest.hyprland.options[setting]} for ${manifest.id}:${setting} skipped: ${reason}`);
        CASES.push([errors[0].error, cause]);
    }
}
const UNKNOWN = [
    "hyprland: input.repeat_rate for acme.hyprland:repeatRate skipped: future failure",
    "hyprland: input.repeat_rate for acme.hyprland:repeatRate skipped: want=future",
    "hyprland: input.repeat_rate for acme.hyprland:repeatRate skipped: want=number trailing",
    "hyprland: input.repeat_rate for acme.hyprland:repeatRate skipped: want=at-most:unknown",
    "hyprland: device.touchpad.enabled for acme.hyprland:touchpad skipped: touchpads unread: want=boolean",
    "someone quoted hyprland: input.repeat_rate for acme.hyprland:repeatRate skipped: want=number",
    "", "unexpected diagnostic=failed", "refused: secret=x reason=future", "refused: tui=core/x reason=launcher-missing-extra", "refused: setting=x want=number trailing", "someone quoted refused: user-config=unwritable", "build failed: service: script says reason=launcher-missing"];

function verify(logic) {
    for (const raw of ["ok", "ok hidden=acme.widget"]) assert.equal(logic.line(raw), "");
    for (const [raw, cause] of CASES) {
        const text = logic.line(raw);
        assert.match(text, cause, raw);
        assert.notEqual(text, raw);
        assert.doesNotMatch(text, /(?:refused:|build failed:|hyprland:|\b[a-z][a-z-]*=|file:\/\/)/, raw);
    }
    for (const raw of UNKNOWN.slice(0, -1)) {
        const text = logic.line(raw);
        assert.match(text, /could not complete this action/, raw);
        assert.doesNotMatch(text, /(?:hyprland:|refused:|\b[a-z][a-z-]*=)/, raw);
    }
    assert.match(logic.line(UNKNOWN.at(-1)), /plugin could not start/, "embedded unrelated codes must not change the failure cause");
}

// Like the Dev Tools handler test, execute the QML source under Node with
// capability doubles. No second implementation or QML parsing library.
function windowContext(logic, source) {
    const names = ["stepKey", "replyOf", "keep", "secretStep", "addPlugin", "storeSecret", "clearSecret"];
    const functions = names.map(name => {
        const found = [...source.matchAll(new RegExp("^    function " + name + "\\([^\\n]*\\) \\{\\n[\\s\\S]*?^    \\}", "gm"))];
        assert.equal(found.length, 1, `extractor: one actual Window.${name}`);
        return found[0][0];
    });
    const logs = [];
    const ctx = { Reply: logic, replies: {}, writing: "", notice: "", shell: { manager: {} }, console: { warn: line => logs.push(line) } };
    ctx.root = ctx;
    vm.createContext(ctx);
    vm.runInContext(functions.join("\n"), ctx);
    return { ctx, logs };
}

function verifyCallers(logic, source, page) {
    const { ctx, logs } = windowContext(logic, source);
    for (const [raw] of CASES) {
        assert.equal(ctx.keep("plugin", raw), raw, "keep returns the unchanged machine reply");
        assert.equal(ctx.replyOf("plugin"), logic.line(raw), "page reads the mapped manager reply");
        assert.equal(logs.at(-1), "settings: plugin " + raw, "logs retain the original diagnostic");
        ctx.shell.manager.add = () => raw;
        assert.equal(ctx.addPlugin(), raw, "add returns the unchanged machine reply");
        assert.equal(ctx.notice, logic.line(raw), "the list reads the mapped refusal");
        assert.equal(logs.at(-1), "settings: add " + raw);
    }
    for (const raw of ["ok", "ok hidden=acme.widget"]) {
        const before = logs.length;
        assert.equal(ctx.keep("plugin", raw), raw);
        assert.equal(ctx.replyOf("plugin"), "");
        ctx.shell.manager.add = () => raw;
        assert.equal(ctx.addPlugin(), raw);
        assert.equal(ctx.notice, "");
        assert.equal(logs.length, before, "success clears the message without a refusal log");
    }
    for (const reason of ["start-failed", "exit=1", "future=unknown"]) {
        let done;
        ctx.shell.manager.storeSecret = (id, key, account, value, callback) => { same([id, key, account, value], ["plugin", "accounts", "account", "fixture-key"]); done = callback; return "ok"; };
        assert.equal(ctx.storeSecret("plugin", "accounts", "account", "fixture-key"), "ok");
        assert.equal(ctx.writing, "plugin/accounts/account");
        done({ ok: false, reason });
        assert.equal(ctx.writing, "");
        assert.equal(ctx.replyOf("plugin", "accounts", "account"), logic.line("refused: secret write failed " + reason));
        assert.equal(logs.at(-1), "settings: plugin/accounts/account refused: secret write failed " + reason);
    }
    let done;
    ctx.shell.manager.clearSecret = (id, key, account, callback) => { done = callback; return "ok"; };
    assert.equal(ctx.clearSecret("plugin", "accounts", "account"), "ok");
    done({ ok: true, reason: null });
    assert.equal(ctx.writing, "");
    assert.equal(ctx.replyOf("plugin", "accounts", "account"), "");
    ctx.writing = "other";
    ctx.secretStep("plugin", callback => { done = callback; return "refused: secret=account reason=busy"; });
    assert.equal(ctx.writing, "other", "a refused write leaves the current owner alone");
    done({ ok: false, reason: "exit=1" });
    assert.equal(ctx.writing, "other", "another owner's completion cannot clear this owner");

    const bindings = [...page.matchAll(/required property string modelData\n\s+role: "hint"\n\s+text: ([^\n]+)/g)];
    assert.equal(bindings.length, 1, "extractor: the Registry error delegate has one display binding");
    for (const [modelData] of CASES.filter(([raw]) => raw.startsWith("build failed:") || raw.startsWith("hyprland:"))) {
        const drawn = vm.runInNewContext(bindings[0][1], { Reply: logic, modelData });
        assert.equal(drawn, logic.line(modelData), "the actual delegate maps its current error");
    }
}

// Run the registered Launcher bind, the actual KeyField label expression
// and Probe's window reader over one visual fixture. The shell snippet is
// the Settings scene's real argument list, before its Keys capture.
const shotsSource = fs.readFileSync(path.join(__dirname, "sandbox-shots.sh"), "utf8");
const keySource = fs.readFileSync(path.join(dir, "KeyField.qml"), "utf8");
const launcherSource = fs.readFileSync(path.join(dir, "..", "vgs.launcher", "Service.qml"), "utf8");
const probeSource = fs.readFileSync(path.join(__dirname, "smoke", "Probe.qml"), "utf8");
function verifyKeys(shots, key) {
    const registrations = [...launcherSource.matchAll(/^        shell\.shortcut\.register\([^\n]+/gm)];
    assert.equal(registrations.length, 1, "extractor: one actual Launcher shortcut registration");
    let bind;
    vm.runInNewContext(registrations[0][0], { shell: { shortcut: { register: (shortcut, description) => { bind = { shortcut, description }; } } } });
    const labels = [...key.matchAll(/^    label: ([^\n]+)$/gm)];
    assert.equal(labels.length, 1, "extractor: one actual KeyField label");
    const field = { label: vm.runInNewContext(labels[0][1], { bind }), children: [], visible: true, enabled: true,
        width: 300, height: 40, mapToItem: () => ({ x: 10, y: 20 }), toString: () => "KeyField_QMLTYPE_1(0xfixture)" };
    const ctx = { Plugins: { built: { window: [{ id: "vgs.settings", instance: { children: [field] } }] } }, answer: text => text };
    ctx.root = ctx;
    vm.createContext(ctx);
    for (const name of ["json", "instance", "descendants", "reads", "labelledBox", "windowBox", "typeName"]) {
        const functions = [...probeSource.matchAll(new RegExp("^    function " + name + "\\([^\\n]*\\) \\{\\n[\\s\\S]*?^    \\}", "gm"))];
        assert.equal(functions.length, 1, `extractor: one actual Probe.${name}`);
        vm.runInContext(functions[0][0], ctx);
    }
    const windowReaders = [...probeSource.matchAll(/function windowGeometry\([^\n]+\n\s+return ([^\n]+);/g)];
    assert.equal(windowReaders.length, 1, "extractor: one actual Probe.windowGeometry return");
    const selections = [...shots.matchAll(/settings_section Keys KeyField [^\n]*?(?=\)"; then)/g)];
    assert.equal(selections.length, 1, "extractor: one actual Keys scene selection");
    assert.ok(selections[0].index < shots.indexOf('take "settings-$1-keys"'), "select the KeyField before capture");
    const { execFileSync } = require("node:child_process");
    const args = execFileSync("/bin/bash", ["-c", 'settings_section() { printf "%s\\n" "$@"; }\n' + selections[0][0]], { env: { PATH: "/usr/bin:/bin", LC_ALL: "C" }, encoding: "utf8" }).trimEnd().split("\n");
    same(args.slice(0, 2), ["Keys", "KeyField"]);
    Object.assign(ctx, { hostKey: "window", id: "vgs.settings", type: args[1], text: args[2] });
    assert.equal(vm.runInContext(windowReaders[0][1], ctx), "[10,20,300,40]", "Keys selection must find actual KeyField");
    ctx.text = "toggle";
    assert.equal(vm.runInContext(windowReaders[0][1], ctx), "absent", "the old toggle reader must fail");
}
verifyKeys(shotsSource, keySource);
const logic = load(file);
verify(logic);
verifyCallers(logic, windowSource, pageSource);
const source = fs.readFileSync(file, "utf8");
const temp = fs.mkdtempSync(path.join(__dirname, "..", "tmp", "settings-reply-control-"));
let controls = 0;
try {
    const patterns = source.match(/^    \[\/.*$/gm);
    assert.ok(patterns.length >= 30, "extractor: mapper pattern table incomplete");
    for (const row of patterns) {
        assert.equal(source.split(row).length, 2, "control: each mapping row is unique");
        const mutant = path.join(temp, "Reply.js");
        const removed = row.replace(/\[\/.*?\//, "[/never-produced/");
        assert.notEqual(row, removed);
        fs.writeFileSync(mutant, source.replace(row, () => removed));
        assert.throws(() => verify(load(mutant)), undefined, "removing a cause mapping must fail its consumer test");
        controls++;
    }
    const broad = source.match(/^    \[\/\^hyprland:.*A saved setting is invalid.*$/m);
    assert.ok(broad, "extractor: one value refusal mapping");
    assert.equal(source.split(broad[0]).length, 2);
    const oldRule = '    [/^hyprland: .+ for \\S+:\\S+ skipped: /, "A saved setting is invalid. Choose another value."],';
    const mutant = path.join(temp, "Reply.js");
    fs.writeFileSync(mutant, source.replace(broad[0], () => oldRule));
    assert.throws(() => verify(load(mutant)), /Hyprland lists no touchpad/, "the broad wrong-cause rule must fail");
    controls++;
    const reader = "settings_section Keys KeyField 'Open or close the launcher'";
    assert.equal(shotsSource.split(reader).length, 2);
    assert.throws(() => verifyKeys(shotsSource.replace(reader, "settings_section Keys KeyField toggle"), keySource), /Keys selection must find actual KeyField/, "the old screenshot reader must fail on absent geometry");
    controls++;
    for (const [needle, replacement, check] of [
        ['if (isOk(reply)) return "";', '', mutated => { const f = path.join(temp, "Reply.js"); fs.writeFileSync(f, mutated); verify(load(f)); }],
        ['reply.indexOf("ok ") === 0', 'false', mutated => { const f = path.join(temp, "Reply.js"); fs.writeFileSync(f, mutated); verify(load(f)); }]
    ]) {
        assert.equal(source.split(needle).length, 2);
        assert.throws(() => check(source.replace(needle, replacement)));
        controls++;
    }
    for (const [needle, replacement] of [
        ["next[step] = Reply.line(reply);", "next[step] = reply;"],
        ["notice = Reply.line(reply);", 'notice = Reply.isOk(reply) ? "" : reply;'],
        ['root.keep(step, result.ok ? "ok" : "refused: secret write failed " + result.reason);', 'root.keep(step, "ok");']
    ]) {
        assert.equal(windowSource.split(needle).length, 2);
        assert.throws(() => verifyCallers(logic, windowSource.replace(needle, replacement), pageSource));
        controls++;
    }
    const needle = "text: Reply.line(modelData)";
    assert.equal(pageSource.split(needle).length, 2);
    assert.throws(() => verifyCallers(logic, windowSource, pageSource.replace(needle, "text: modelData")));
    controls++;
} finally {
    fs.rmSync(temp, { recursive: true, force: true });
}
console.log(`test-settings-reply: ok causes=${CASES.length} unknown=${UNKNOWN.length} hyprland=${HYPRLAND.length} controls=${controls} keys=actual-Probe-windowGeometry actual-callers=keep,add,secret,errors`);
