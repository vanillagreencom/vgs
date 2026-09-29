#!/usr/bin/env node
// Table-driven checks for the floating TUI decisions in
// shell/Core/PluginLogic.js: the manifest's `tui` key and its normalized
// shape, the arguments a plugin's script takes, the launch of a plugin's own
// script and of a listed TUI by key, the listed rows and the log line of a
// launcher's end. The file loads under node through bin/lib/qml-library.js,
// as the shell loads it. The controls at the end edit a copy of the judge,
// one rule at a time, and the suite must fail on every copy. Exit 1 when a
// row or a control fails.
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

const hello = { script: "tui/hello.sh", title: "Hello" };
const listed = { script: "tui/update.sh", title: "Update", size: "wide", presentation: "plain", entry: { label: "Update the system", icon: "terminal", group: "System" } };
function manifestWith(tui, capabilities) {
    const raw = { schemaVersion: 1, id: "acme.tui", name: "T", version: "1", author: "a", description: "d", kinds: ["service"], entryPoints: { service: "S.qml" }, capabilities: capabilities === undefined ? ["tui"] : capabilities };
    if (tui !== undefined) raw.tui = tui;
    return raw;
}

// Every row against one loaded judge, `ctx`, each result handed to `check`.
function suite(ctx, check) {
    // The manifest's `tui` key: [name, tui value, capabilities or undefined
    // for ["tui"], null for accepted or the start of the refusal].
    const keyRows = [
        ["one script with a title", { hello: hello }, undefined, null],
        ["a listed script with every key", { update: listed }, undefined, null],
        ["a script in a subdirectory of tui/", { hello: { script: "tui/sub/run_1.sh", title: "Hello" } }, undefined, null],
        ["a title of 60 characters", { hello: { script: "tui/hello.sh", title: "t".repeat(60) } }, undefined, null],
        ["no tui key with capability tui", undefined, undefined, null],
        ["tui that is a list", [hello], undefined, "tui must be an object of script names to scripts"],
        ["tui with no script", {}, undefined, "tui must declare at least one script"],
        ["tui without capability tui", { hello: hello }, [], "tui needs capability tui"],
        ["a name with an upper case letter", { Hello: hello }, undefined, "tui name \"Hello\" must be lower case letters, digits and dashes"],
        ["a name with a slash", { "a/b": hello }, undefined, "tui name \"a/b\" must be lower case letters"],
        ["a script entry that is a string", { hello: "tui/hello.sh" }, undefined, "tui.hello must be an object"],
        ["a script entry with an unknown key", { hello: Object.assign({ command: "sh -c x" }, hello) }, undefined, "tui.hello has unknown key \"command\""],
        ["a script that is an absolute path", { hello: { script: "/bin/sh", title: "Hello" } }, undefined, "tui.hello.script must be a relative path under tui/ inside the plugin, got \"/bin/sh\""],
        ["a script outside tui/", { hello: { script: "hello.sh", title: "Hello" } }, undefined, "tui.hello.script must be a relative path under tui/"],
        ["a script that climbs out of tui/", { hello: { script: "tui/../manifest.json", title: "Hello" } }, undefined, "tui.hello.script must be a relative path under tui/"],
        ["a script with a dot segment", { hello: { script: "tui/./hello.sh", title: "Hello" } }, undefined, "tui.hello.script must be a relative path under tui/"],
        ["a hidden script", { hello: { script: "tui/.hello.sh", title: "Hello" } }, undefined, "tui.hello.script must be a relative path under tui/"],
        ["the tui directory itself", { hello: { script: "tui/", title: "Hello" } }, undefined, "tui.hello.script must be a relative path under tui/"],
        ["a script with an empty segment", { hello: { script: "tui//hello.sh", title: "Hello" } }, undefined, "tui.hello.script must be a relative path under tui/"],
        ["a script with a space", { hello: { script: "tui/hel lo.sh", title: "Hello" } }, undefined, "tui.hello.script must be a relative path under tui/"],
        ["a script that is not a string", { hello: { script: ["tui/hello.sh"], title: "Hello" } }, undefined, "tui.hello.script must be a relative path under tui/"],
        ["a script without a title", { hello: { script: "tui/hello.sh" } }, undefined, "tui.hello.title must be one printable line of 1 to 60 characters"],
        ["a blank title", { hello: { script: "tui/hello.sh", title: "  " } }, undefined, "tui.hello.title must be one printable line"],
        ["a title of 61 characters", { hello: { script: "tui/hello.sh", title: "t".repeat(61) } }, undefined, "tui.hello.title must be one printable line"],
        ["a title with a newline", { hello: { script: "tui/hello.sh", title: "a\nb" } }, undefined, "tui.hello.title must be one printable line"],
        ["a title with a C1 control character", { hello: { script: "tui/hello.sh", title: "a\u009bb" } }, undefined, "tui.hello.title must be one printable line"],
        ["a size no window class has", { hello: Object.assign({ size: "huge" }, hello) }, undefined, "tui.hello.size must be one of default, wide, tall, got \"huge\""],
        ["a size naming a prototype member", { hello: Object.assign({ size: "toString" }, hello) }, undefined, "tui.hello.size must be one of"],
        ["an unknown presentation", { hello: Object.assign({ presentation: "loud" }, hello) }, undefined, "tui.hello.presentation must be one of full, plain, got \"loud\""],
        ["an entry that is a string", { hello: Object.assign({ entry: "Hello" }, hello) }, undefined, "tui.hello.entry must be an object"],
        ["an entry with an unknown key", { hello: Object.assign({ entry: Object.assign({ action: "x" }, listed.entry) }, hello) }, undefined, "tui.hello.entry has unknown key \"action\""],
        ["an entry without a label", { hello: Object.assign({ entry: { icon: "terminal", group: "System" } }, hello) }, undefined, "tui.hello.entry.label must be one printable line of 1 to 60 characters"],
        ["an entry label of 61 characters", { hello: Object.assign({ entry: { label: "l".repeat(61), icon: "terminal", group: "System" } }, hello) }, undefined, "tui.hello.entry.label must be one printable line"],
        ["an entry icon outside the shipped set", { hello: Object.assign({ entry: { label: "L", icon: "no-such-icon", group: "System" } }, hello) }, undefined, "tui.hello.entry.icon must name an icon of the shipped set, shell/Ui/icons/Lucide.js, got \"no-such-icon\""],
        ["an entry without an icon", { hello: Object.assign({ entry: { label: "L", group: "System" } }, hello) }, undefined, "tui.hello.entry.icon must name an icon of the shipped set"],
        ["an entry without a group", { hello: Object.assign({ entry: { label: "L", icon: "terminal" } }, hello) }, undefined, "tui.hello.entry.group must be one printable line of 1 to 60 characters"],
        ["an entry group with a tab", { hello: Object.assign({ entry: { label: "L", icon: "terminal", group: "a\tb" } }, hello) }, undefined, "tui.hello.entry.group must be one printable line"],
    ];
    for (const [name, tui, capabilities, want] of keyRows) {
        const r = ctx.validateManifest(manifestWith(tui, capabilities), "/p");
        check("validateManifest tui: " + name, r.ok ? null : r.error.slice(0, want === null ? 0 : want.length), want);
    }

    // The size classes are the Hyprland layer's window table's.
    check("TUI_SIZES are the layer's size classes", ctx.TUI_SIZES, ["default", "wide", "tall"]);

    // The normalized manifest.
    const plain = ctx.validateManifest(manifestWith(undefined), "/p").manifest;
    check("a manifest without tui carries an empty tui", plain.tui, {});
    const normal = ctx.validateManifest(manifestWith({ hello: hello, update: listed }), "/p").manifest;
    check("an absent size, presentation and entry are normalized", normal.tui.hello, { script: "tui/hello.sh", title: "Hello", size: "default", presentation: "full", entry: null });
    check("a declared size, presentation and entry are kept", normal.tui.update, listed);
    check("the normalized entry does not alias the raw manifest", (() => { const raw = manifestWith({ update: JSON.parse(JSON.stringify(listed)) }); const m = ctx.validateManifest(raw, "/p").manifest; m.tui.update.entry.label = "x"; return raw.tui.update.entry.label; })(), "Update the system");

    // tuiArgsValid: [name, args, accepted].
    const argRows = [
        ["absent arguments", undefined, true],
        ["no arguments", [], true],
        ["sixteen arguments", Array(16).fill("a"), true],
        ["seventeen arguments", Array(17).fill("a"), false],
        ["an argument of 256 characters", ["a".repeat(256)], true],
        ["an argument of 257 characters", ["a".repeat(257)], false],
        ["an empty argument", ["a", ""], false],
        ["an argument with a newline", ["a\nb"], false],
        ["an argument with a C1 control character", ["a\u0085b"], false],
        ["shell syntax is an argument like any other", ["$(touch x); rm -rf ~", "a b"], true],
        ["a number", [3], false],
        ["an object with a length", [{ length: 1 }], false],
        ["null", null, false],
        ["a string instead of a list", "abc", false],
    ];
    for (const [name, args, want] of argRows) check("tuiArgsValid: " + name, ctx.tuiArgsValid(args), want);

    // tuiRun: [name, enabled, script name, args, answer or argv].
    const runRows = [
        ["a declared script with arguments", true, "hello", ["a b", "$(x)"], ["launch", "--title", "Hello", "--size", "default", "--presentation", "full", "--plugin", "acme.tui", "--dir", "/run/src/r1", "--", "tui/hello.sh", "a b", "$(x)"]],
        ["a declared script without arguments", true, "update", undefined, ["launch", "--title", "Update", "--size", "wide", "--presentation", "plain", "--plugin", "acme.tui", "--dir", "/run/src/r1", "--", "tui/update.sh"]],
        ["a name the manifest does not declare", true, "other", [], "refused: tui=other reason=undeclared"],
        ["a name that is a prototype member", true, "constructor", [], "refused: tui=constructor reason=undeclared"],
        ["a name that is not a string", true, 3, [], "refused: tui=3 reason=undeclared"],
        ["a name with a space is quoted", true, "a b", [], "refused: tui=\"a b\" reason=undeclared"],
        ["a disabled plugin", false, "hello", [], "refused: tui=hello reason=disabled"],
        ["arguments the judge refuses", true, "hello", ["a\nb"], "refused: tui=hello reason=args"],
    ];
    const running = Object.assign({ __revision: "r1" }, normal);
    for (const [name, enabled, script, args, want] of runRows) {
        const r = ctx.tuiRun(running, enabled, "/run/src", script, args);
        check("tuiRun: " + name, r.ok ? r.argv : r.answer, want);
    }
    check("tuiRun keys a launch by plugin and name", ctx.tuiRun(running, true, "/run/src", "hello", []).key, "acme.tui/hello");

    // tuiOpen and tuiEntries over two plugins, one disabled, and a core table.
    const other = Object.assign({ __revision: "r2" }, ctx.validateManifest(Object.assign(manifestWith({ fix: { script: "tui/fix.sh", title: "Fix", entry: { label: "Fix it", icon: "wrench", group: "Tools" } } }), { id: "acme.other" }), "/q").manifest);
    const manifests = { "acme.tui": running, "acme.other": other };
    const core = { doctor: { argv: ["vgsh", "doctor"], title: "Doctor", size: "tall", presentation: "full", entry: { label: "Check the system", icon: "stethoscope", group: "System" } }, quiet: { argv: ["true"], title: "Quiet", size: "default", presentation: "plain", entry: null } };
    const openRows = [
        ["a listed plugin script opens with no arguments", ["acme.tui"], "acme.tui/update", ["launch", "--title", "Update", "--size", "wide", "--presentation", "plain", "--plugin", "acme.tui", "--dir", "/run/src/r1", "--", "tui/update.sh"]],
        ["a core TUI opens its command with no plugin", [], "core/doctor", ["launch", "--title", "Doctor", "--size", "tall", "--presentation", "full", "--", "vgsh", "doctor"]],
        ["a declared script without an entry is not listed", ["acme.tui"], "acme.tui/hello", "refused: tui=acme.tui/hello reason=undeclared"],
        ["a disabled plugin's listed script", ["acme.tui"], "acme.other/fix", "refused: tui=acme.other/fix reason=disabled"],
        ["an unknown plugin", ["acme.tui"], "acme.none/fix", "refused: tui=acme.none/fix reason=undeclared"],
        ["an unknown core TUI", [], "core/none", "refused: tui=core/none reason=undeclared"],
        ["a core name that is a prototype member", [], "core/constructor", "refused: tui=core/constructor reason=undeclared"],
        ["a key with no slash", ["acme.tui"], "acme.tui", "refused: tui=acme.tui reason=undeclared"],
        ["a key with no owner", ["acme.tui"], "/update", "refused: tui=/update reason=undeclared"],
        ["a key that is not a string", ["acme.tui"], null, "refused: tui=null reason=undeclared"],
    ];
    for (const [name, enabledIds, key, want] of openRows) {
        const r = ctx.tuiOpen(manifests, enabledIds, "/run/src", core, key);
        check("tuiOpen: " + name, r.ok ? r.argv : r.answer, want);
    }
    check("tuiOpen keys a launch by the key it opened", ctx.tuiOpen(manifests, [], "/run/src", core, "core/doctor").key, "core/doctor");
    check("tuiEntries: the core's and every enabled plugin's listed TUIs, by key", ctx.tuiEntries(manifests, ["acme.tui"], core), [
        { key: "acme.tui/update", plugin: "acme.tui", name: "update", title: "Update", label: "Update the system", icon: "terminal", group: "System" },
        { key: "core/doctor", plugin: "core", name: "doctor", title: "Doctor", label: "Check the system", icon: "stethoscope", group: "System" },
    ]);
    check("tuiEntries: a plugin enabled again lists its TUIs again", ctx.tuiEntries(manifests, ["acme.other", "acme.tui"], {}).map(e => e.key), ["acme.other/fix", "acme.tui/update"]);
    check("tuiEntries: an enabled id with no manifest lists nothing", ctx.tuiEntries(manifests, ["acme.gone"], {}), []);
    check("the core's own table lists only judged sizes and presentations", Object.keys(ctx.CORE_TUIS).filter(n => ctx.TUI_SIZES.indexOf(ctx.CORE_TUIS[n].size) === -1 || ctx.TUI_PRESENTATIONS.indexOf(ctx.CORE_TUIS[n].presentation) === -1), []);

    // tuiLaunchOutcome: [name, completion, stderr, log line].
    const outcomeRows = [
        ["a launcher that handed the terminal its command", { code: 0, status: 0 }, "", ""],
        ["no xdg-terminal-exec on PATH", { code: 69, status: 0 }, "vgsh-tui: refused: terminal=missing\nxdg-terminal-exec is not on PATH", "tui: refused: tui=acme.tui/hello reason=launcher-missing"],
        ["a launcher that never started", null, "", "tui: launcher=unstarted tui=acme.tui/hello"],
        ["a bad invocation", { code: 2, status: 0 }, "vgsh-tui: refused: size=huge\nusage", "tui: launcher=failed tui=acme.tui/hello exit=2 status=0 vgsh-tui: refused: size=huge"],
        ["a launcher that crashed", { code: 0, status: 1 }, "", "tui: launcher=failed tui=acme.tui/hello exit=0 status=1 "],
    ];
    for (const [name, completion, stderr, want] of outcomeRows)
        check("tuiLaunchOutcome: " + name, ctx.tuiLaunchOutcome("acme.tui/hello", completion, stderr), want);
}

suite(load(LOGIC), report);

// Each control removes one rule from a copy of the judge and keeps the text
// around it; the suite must fail on every copy. The copy sits at the
// judge's own place in a temporary tree, beside the files it imports.
const CONTROLS = [
    ["tui is an object", "if (!isPlainObject(tui))\n        return \"tui must be an object", "if (false)\n        return \"tui must be an object"],
    ["tui declares a script", "if (names.length === 0)", "if (false)"],
    ["tui needs its capability", "if (capabilities.indexOf(\"tui\") === -1)", "if (false)"],
    ["a script name is a name", "if (!NAME_PATTERN.test(name))\n            return \"tui name ", "if (false)\n            return \"tui name "],
    ["a script entry is an object", "if (!isPlainObject(row))\n            return at + \" must be an object\";", "if (false)\n            return at + \" must be an object\";"],
    ["a script entry holds known keys", "if (TUI_KEYS.indexOf(keys[k]) === -1)", "if (false)"],
    ["a script matches the path rule", "|| !TUI_SCRIPT.test(row.script))", ")"],
    ["a script segment is neither dot nor hidden", "/^tui(\\/[A-Za-z0-9_][A-Za-z0-9._-]*)+$/", "/^tui(\\/[A-Za-z0-9._-]+)+$/"],
    ["a title is required", "if (!tuiText(row.title))", "if (false)"],
    ["text is not blank", "value.trim().length > 0 && ", ""],
    ["text is at most 60 characters", "Array.from(value).length <= TUI_TEXT_MAX && ", ""],
    ["text holds no control character", " && !CONTROL_CHARACTER.test(value);", ";"],
    ["a size is a window class", "row.size !== undefined && TUI_SIZES.indexOf(row.size) === -1", "false"],
    ["a presentation is known", "row.presentation !== undefined && TUI_PRESENTATIONS.indexOf(row.presentation) === -1", "false"],
    ["an entry is an object", "if (!isPlainObject(row.entry))", "if (false)"],
    ["an entry holds known keys", "if (TUI_ENTRY_KEYS.indexOf(entryKeys[e]) === -1)", "if (false)"],
    ["an entry has a label", "if (!tuiText(row.entry.label))", "if (false)"],
    ["an entry icon is shipped", "if (typeof row.entry.icon !== \"string\" || !hasOwn(Lucide.ICONS, row.entry.icon))", "if (false)"],
    ["an entry has a group", "if (!tuiText(row.entry.group))", "if (false)"],
    ["the manifest judge runs the tui judge", "var badTui = tuiError(raw.tui, capabilities);", "var badTui = \"\";"],
    ["the manifest carries its tui normalized", "manifest.tui = normalTui(raw.tui === undefined ? {} : raw.tui);", "manifest.tui = raw.tui;"],
    ["an absent size is default", "size: row.size === undefined ? \"default\" : row.size", "size: row.size"],
    ["an absent presentation is full", "presentation: row.presentation === undefined ? \"full\" : row.presentation", "presentation: row.presentation"],
    ["an absent entry is null", "entry: row.entry === undefined ? null : clone(row.entry)", "entry: row.entry"],
    ["at most sixteen arguments", "if (!Array.isArray(args) || args.length > TUI_ARGS_MAX)", "if (!Array.isArray(args))"],
    ["arguments are a list", "if (!Array.isArray(args) || ", "if ("],
    ["an argument is a string", "typeof arg === \"string\" && arg.length > 0", "arg.length > 0"],
    ["an argument is not empty", "typeof arg === \"string\" && arg.length > 0 && ", "typeof arg === \"string\" && "],
    ["an argument is at most 256 characters", "Array.from(arg).length <= TUI_ARG_MAX && ", ""],
    ["an argument holds no control character", " && !CONTROL_CHARACTER.test(arg);", ";"],
    ["run opens only a declared script", "if (typeof name !== \"string\" || !hasOwn(manifest.tui, name))", "if (false)"],
    ["run refuses a disabled plugin", "if (!enabled)\n        return tuiRefusal(name, \"disabled\");", "if (false)\n        return tuiRefusal(name, \"disabled\");"],
    ["run judges its arguments", "if (!tuiArgsValid(args))", "if (false)"],
    ["run starts from the published snapshot", "dir: sourceDir + \"/\" + manifest.__revision", "dir: manifest.__sourceDir"],
    ["the launch names the plugin", "argv.push(\"--plugin\", plugin.id, \"--dir\", plugin.dir);", "argv.push(\"--dir\", plugin.dir);"],
    ["open needs a key with a slash", "if (slash === -1)", "if (false)"],
    ["open finds a core TUI in the table", "if (!hasOwn(core, name))\n            return tuiRefusal(key, \"undeclared\");", "if (core[name] === undefined)\n            return tuiRefusal(key, \"undeclared\");"],
    ["open needs an entry", " || manifests[owner].tui[name].entry === null)", ")"],
    ["open refuses a disabled plugin", "if (enabledIds.indexOf(owner) === -1)", "if (false)"],
    ["entries skip a script without an entry", "if (row.entry === null)\n            return;", "if (false)\n            return;"],
    ["entries list enabled plugins alone", "    enabledIds.forEach(function (id) {", "    Object.keys(manifests).forEach(function (id) {"],
    ["entries sort by key", "return rows.sort(function (a, b) { return a.key < b.key ? -1 : a.key > b.key ? 1 : 0; });", "return rows;"],
    ["a label is quoted unless one visible word", "/^[\\x21-\\x7e]+$/.test(name)", "true"],
    ["a crashed launcher is a failure", "if (completion.status === 0 && completion.code === 0)", "if (completion.code === 0)"],
    ["exit 69 is launcher-missing", "completion.code === TUI_LAUNCHER_MISSING", "false"],
    ["a launcher that never started is logged", "if (completion === null)\n        return \"tui: launcher=unstarted", "if (false)\n        return \"tui: launcher=unstarted"],
];

const temp = fs.mkdtempSync(path.join(os.tmpdir(), "tui-logic-control-"));
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

if (failures > 0) { console.log("test-tui-logic: " + failures + " failing"); process.exit(1); }
console.log("test-tui-logic: ok");
