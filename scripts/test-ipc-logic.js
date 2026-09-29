#!/usr/bin/env node
// Table-driven checks for the `ipc` capability's decisions in
// shell/Core/PluginLogic.js: the answer a handler gives, through `vgsh ipc
// call <id> invoke` or a plugin's own `shell.ipc.call`, and the refusal of
// a `call` whose argument is not text. The file loads under node through
// bin/lib/qml-library.js, as the shell loads it. The controls at the end
// edit a copy of the judge, one rule at a time, and the suite must fail on
// every copy. Exit 1 when a row or a control fails.
"use strict";
const fs = require("fs");
const os = require("os");
const path = require("path");
const { load } = require("../bin/lib/qml-library.js");

const CORE = path.join(__dirname, "..", "shell", "Core");
const LOGIC = path.join(CORE, "PluginLogic.js");
const IMPORTS = [
    [path.join(__dirname, "..", "shell", "Ui", "icons", "Lucide.js"), path.join("shell", "Ui", "icons", "Lucide.js")],
    [path.join(CORE, "PackageManagers.js"), path.join("shell", "Core", "PackageManagers.js")],
    [path.join(CORE, "HyprlandLayer.js"), path.join("shell", "Core", "HyprlandLayer.js")],
];

let failures = 0;
function report(name, got, want) {
    const g = JSON.stringify(got), w = JSON.stringify(want);
    if (g === w) { console.log("  ok    " + name); return; }
    failures += 1;
    console.log("  FAIL  " + name + "\n        got  " + g + "\n        want " + w);
}

// Two plugins' records as IpcRegistry holds them. acme.one's `echo`
// answers its argument, `quiet` nothing, `count` a number and `fails`
// throws; acme.two alone holds `secret`.
function targets() {
    return {
        "acme.one": { handler: null, functions: { echo: arg => arg, quiet: () => undefined, count: () => 3, fails: () => { throw new Error("planted"); } } },
        "acme.two": { handler: null, functions: { secret: () => "reached" } }
    };
}

// Every row against one loaded judge, `ctx`, each result handed to `check`.
function suite(ctx, check) {
    // [name, plugin id, handler, argument, the answer].
    const answerRows = [
        ["a handler's result comes back as its reply", "acme.one", "echo", "hello", { reply: "hello", error: null }],
        ["a handler that returns nothing answers the empty text", "acme.one", "quiet", "", { reply: "", error: null }],
        ["a handler's result is answered as text", "acme.one", "count", "", { reply: "3", error: null }],
        ["a name the plugin holds no handler for is unknown", "acme.one", "nope", "", { reply: "unknown: nope", error: null }],
        ["a plugin with no target answers unknown", "acme.none", "echo", "", { reply: "unknown: echo", error: null }],
        ["a handler that throws answers its error", "acme.one", "fails", "", { reply: "error: planted", error: "planted" }],
        ["one plugin cannot reach another plugin's handler", "acme.one", "secret", "", { reply: "unknown: secret", error: null }],
        ["the other plugin reaches its own handler", "acme.two", "secret", "", { reply: "reached", error: null }],
        ["an inherited name is no handler", "acme.one", "toString", "", { reply: "unknown: toString", error: null }]
    ];
    for (const [name, id, handler, arg, want] of answerRows) check(name, ctx.ipcAnswer(targets(), id, handler, arg), want);

    // [name, argument, the refusal, "" for none].
    const callRows = [
        ["a text argument is taken", "x", ""],
        ["an empty text argument is taken", "", ""],
        ["a number is refused", 3, "refused: ipc=echo arg=not-a-string"],
        ["no argument is refused", undefined, "refused: ipc=echo arg=not-a-string"],
        ["an object is refused", {}, "refused: ipc=echo arg=not-a-string"]
    ];
    for (const [name, arg, want] of callRows) check(name, ctx.ipcCallRefusal("echo", arg), want);
}

suite(load(LOGIC), report);

// Controls: [label, text in PluginLogic.js, its replacement].
const CONTROLS = [
    ["a handler's result is its reply", "return { reply: result === undefined ? \"\" : String(result), error: null };", "return { reply: \"\", error: null };"],
    ["a name with no handler is unknown", "if (target === null || !hasOwn(target.functions, name))\n        return { reply: \"unknown: \" + name, error: null };", "if (target === null)\n        return { reply: \"unknown: \" + name, error: null };"],
    ["a throwing handler answers its error", "return { reply: \"error: \" + message, error: message };", "return { reply: \"\", error: null };"],
    ["only the calling plugin's target is looked up", "var target = hasOwn(targets, id) ? targets[id] : null;", "var target = Object.keys(targets).map(function (key) { return targets[key]; }).filter(function (t) { return hasOwn(t.functions, name); })[0] || null;"],
    ["a call's argument must be text", "return typeof arg === \"string\" ? \"\" : \"refused: ipc=\" + name + \" arg=not-a-string\";", "return \"\";"],
];

const temp = fs.mkdtempSync(path.join(os.tmpdir(), "ipc-logic-control-"));
try {
    for (const [source, relative] of IMPORTS) {
        fs.mkdirSync(path.dirname(path.join(temp, relative)), { recursive: true });
        fs.symlinkSync(source, path.join(temp, relative));
    }
    const source = fs.readFileSync(LOGIC, "utf8");
    for (const [label, needle, replacement] of CONTROLS) {
        const count = source.split(needle).length - 1;
        if (count !== 1) { report("control: " + label + ": the text to replace occurs once", count, 1); continue; }
        const mutant = path.join(temp, "shell", "Core", "PluginLogic.js");
        fs.writeFileSync(mutant, source.replace(needle, () => replacement));
        // Loaded outside the try, so a copy that does not evaluate fails the
        // suite instead of passing for a control.
        const ctx = load(mutant);
        let red = 0;
        try {
            suite(ctx, (name, got, want) => { if (JSON.stringify(got) !== JSON.stringify(want)) red += 1; });
        } catch (e) {
            red += 1;
        }
        report("control: the suite fails without the rule: " + label, red > 0, true);
    }
} finally {
    fs.rmSync(temp, { recursive: true, force: true });
}

if (failures > 0) { console.log("test-ipc-logic: " + failures + " failing"); process.exit(1); }
console.log("test-ipc-logic: ok");
