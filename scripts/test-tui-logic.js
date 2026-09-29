#!/usr/bin/env node
// Table-driven checks for the floating TUI decisions in
// shell/Core/PluginLogic.js: the manifest's `tui` key and its normalized
// shape, the core's own TUI table, the arguments a plugin's script takes,
// the launch of a plugin's own script, of a listed TUI by key and of the
// core's own TUI with arguments, the core answer for a TUI shown on screen,
// the busy key and the launcher state among the refusals, the listed rows,
// the log lines of a launcher's, a probe's and a reap's end, the exit records
// and the runs, state and `done` answers they make, and a run's window. The
// file loads under node through bin/lib/qml-library.js,
// as the shell loads it. The controls at the end edit a copy of the judge,
// one rule at a time, and the suite must fail on every copy. Exit 1 when a
// row or a control fails.
"use strict";
const fs = require("fs");
const os = require("os");
const path = require("path");
const { load } = require("../bin/lib/qml-library.js");

const CORE = path.join(__dirname, "..", "shell", "Core");
const BIN = path.join(__dirname, "..", "bin");
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

    // tuiRun: [name, enabled, launcher state, busy keys, script name, args,
    // argv, or the answer and the action it asks for].
    const record = ["--record", "acme.tui/hello", "--run", "7-1"];
    const argvHello = ["launch", "--title", "Hello", "--size", "default", "--presentation", "full", "--plugin", "acme.tui", "--dir", "/run/src/r1"].concat(record, ["--", "tui/hello.sh"]);
    const runRows = [
        ["a declared script with arguments", true, "present", [], "hello", ["a b", "$(x)"], argvHello.concat(["a b", "$(x)"])],
        ["a declared script without arguments", true, "present", [], "update", undefined, ["launch", "--title", "Update", "--size", "wide", "--presentation", "plain", "--plugin", "acme.tui", "--dir", "/run/src/r1", "--record", "acme.tui/update", "--run", "7-1", "--", "tui/update.sh"]],
        ["a launcher no probe has answered yet starts the launch", true, "unknown", [], "hello", [], argvHello],
        ["another key's live run starts the launch", true, "present", ["acme.tui/update", "acme.other/hello"], "hello", [], argvHello],
        ["a name the manifest does not declare", true, "present", [], "other", [], ["refused: tui=other reason=undeclared", "none"]],
        ["a name that is a prototype member", true, "present", [], "constructor", [], ["refused: tui=constructor reason=undeclared", "none"]],
        ["a name that is not a string", true, "present", [], 3, [], ["refused: tui=3 reason=undeclared", "none"]],
        ["a name with a space is quoted", true, "present", [], "a b", [], ["refused: tui=\"a b\" reason=undeclared", "none"]],
        ["a disabled plugin", false, "present", [], "hello", [], ["refused: tui=hello reason=disabled", "none"]],
        ["arguments the judge refuses", true, "present", [], "hello", ["a\nb"], ["refused: tui=hello reason=args", "none"]],
        ["a busy key refuses and asks for its window", true, "present", ["acme.tui/hello"], "hello", [], ["refused: tui=hello reason=busy", "focus"]],
        ["a missing launcher refuses and asks for a probe", true, "missing", [], "hello", [], ["refused: tui=hello reason=launcher-missing", "probe"]],
        ["a busy key is refused before a missing launcher", true, "missing", ["acme.tui/hello"], "hello", [], ["refused: tui=hello reason=busy", "focus"]],
        ["an undeclared name is refused before a busy key", true, "present", ["acme.tui/other"], "other", [], ["refused: tui=other reason=undeclared", "none"]],
        ["an undeclared name is refused before a missing launcher", true, "missing", [], "other", [], ["refused: tui=other reason=undeclared", "none"]],
        ["a disabled plugin is refused before a busy key", false, "present", ["acme.tui/hello"], "hello", [], ["refused: tui=hello reason=disabled", "none"]],
        ["a disabled plugin is refused before a missing launcher", false, "missing", [], "hello", [], ["refused: tui=hello reason=disabled", "none"]],
        ["refused arguments come before a busy key", true, "present", ["acme.tui/hello"], "hello", ["a\nb"], ["refused: tui=hello reason=args", "none"]],
        ["refused arguments come before a missing launcher", true, "missing", [], "hello", ["a\nb"], ["refused: tui=hello reason=args", "none"]],
    ];
    const running = Object.assign({ __revision: "r1" }, normal);
    const runner = (launcher, busy) => ({ launcher: launcher, busy: busy, run: "7-1" });
    for (const [name, enabled, launcher, busy, script, args, want] of runRows) {
        const r = ctx.tuiRun(running, enabled, "/run/src", runner(launcher, busy), script, args);
        check("tuiRun: " + name, r.ok ? r.argv : [r.answer, r.action], want);
    }
    check("tuiRun keys a launch by plugin and name", ctx.tuiRun(running, true, "/run/src", runner("present", []), "hello", []).key, "acme.tui/hello");
    check("tuiRun hands the launch the runner's run id", ctx.tuiRun(running, true, "/run/src", runner("present", []), "hello", []).run, "7-1");
    check("tuiRun names the busy key it asks to focus", ctx.tuiRun(running, true, "/run/src", runner("present", ["acme.tui/hello"]), "hello", []).key, "acme.tui/hello");
    check("tuiRun throws on a launcher state no rule covers", (() => { try { ctx.tuiRun(running, true, "/run/src", runner("gone", []), "hello", []); return "answered"; } catch (e) { return e.message; } })(), "tui: launcher state \"gone\" is not one of unknown, present, missing");

    // tuiOpen and tuiEntries over two plugins, one disabled, and a core table.
    const other = Object.assign({ __revision: "r2" }, ctx.validateManifest(Object.assign(manifestWith({ fix: { script: "tui/fix.sh", title: "Fix", entry: { label: "Fix it", icon: "wrench", group: "Tools" } } }), { id: "acme.other" }), "/q").manifest);
    const manifests = { "acme.tui": running, "acme.other": other };
    const core = {
        doctor: { argv: ["vgsh", "doctor"], title: "Doctor", size: "tall", presentation: "full", entry: { label: "Check the system", icon: "stethoscope", group: "System" } },
        quiet: { argv: ["true"], title: "Quiet", size: "default", presentation: "plain", entry: null },
    };
    const doctorArgv = ["launch", "--title", "Doctor", "--size", "tall", "--presentation", "full", "--record", "core/doctor", "--run", "7-1", "--", "/core/bin/vgsh", "doctor"];
    // tuiOpen: [name, enabled ids, launcher state, busy keys, key, argv, or
    // the answer and the action it asks for].
    const openRows = [
        ["a listed plugin script opens with no arguments", ["acme.tui"], "present", [], "acme.tui/update", ["launch", "--title", "Update", "--size", "wide", "--presentation", "plain", "--plugin", "acme.tui", "--dir", "/run/src/r1", "--record", "acme.tui/update", "--run", "7-1", "--", "tui/update.sh"]],
        ["a core TUI opens its command with no plugin", [], "present", [], "core/doctor", doctorArgv],
        ["a declared script without an entry is not listed", ["acme.tui"], "present", [], "acme.tui/hello", ["refused: tui=acme.tui/hello reason=undeclared", "none"]],
        ["a disabled plugin's listed script", ["acme.tui"], "present", [], "acme.other/fix", ["refused: tui=acme.other/fix reason=disabled", "none"]],
        ["an unknown plugin", ["acme.tui"], "present", [], "acme.none/fix", ["refused: tui=acme.none/fix reason=undeclared", "none"]],
        ["an unknown core TUI", [], "present", [], "core/none", ["refused: tui=core/none reason=undeclared", "none"]],
        ["a core name that is a prototype member", [], "present", [], "core/constructor", ["refused: tui=core/constructor reason=undeclared", "none"]],
        ["a core TUI with no entry is not listed", [], "present", [], "core/quiet", ["refused: tui=core/quiet reason=undeclared", "none"]],
        ["a key with no slash", ["acme.tui"], "present", [], "acme.tui", ["refused: tui=acme.tui reason=undeclared", "none"]],
        ["a key with no owner", ["acme.tui"], "present", [], "/update", ["refused: tui=/update reason=undeclared", "none"]],
        ["a key that is not a string", ["acme.tui"], "present", [], null, ["refused: tui=null reason=undeclared", "none"]],
        ["a listed plugin script with a busy key", ["acme.tui"], "present", ["acme.tui/update"], "acme.tui/update", ["refused: tui=acme.tui/update reason=busy", "focus"]],
        ["a core TUI with a busy key", [], "present", ["core/doctor"], "core/doctor", ["refused: tui=core/doctor reason=busy", "focus"]],
        ["a listed plugin script with a missing launcher", ["acme.tui"], "missing", [], "acme.tui/update", ["refused: tui=acme.tui/update reason=launcher-missing", "probe"]],
        ["a core TUI with a missing launcher", [], "missing", [], "core/doctor", ["refused: tui=core/doctor reason=launcher-missing", "probe"]],
        ["an unknown key is refused before a busy key", [], "present", ["core/none"], "core/none", ["refused: tui=core/none reason=undeclared", "none"]],
        ["an unknown key is refused before a missing launcher", [], "missing", [], "core/none", ["refused: tui=core/none reason=undeclared", "none"]],
        ["a disabled plugin is refused before a busy key", ["acme.tui"], "present", ["acme.other/fix"], "acme.other/fix", ["refused: tui=acme.other/fix reason=disabled", "none"]],
        ["a disabled plugin is refused before a missing launcher", ["acme.tui"], "missing", [], "acme.other/fix", ["refused: tui=acme.other/fix reason=disabled", "none"]],
        ["a launcher no probe has answered yet opens the key", [], "unknown", [], "core/doctor", doctorArgv],
        ["a core TUI with no entry is not listed", [], "present", [], "core/quiet", ["refused: tui=core/quiet reason=undeclared", "none"]],
    ];
    for (const [name, enabledIds, launcher, busy, key, want] of openRows) {
        const r = ctx.tuiOpen(manifests, enabledIds, "/run/src", "/core/bin", runner(launcher, busy), core, key);
        check("tuiOpen: " + name, r.ok ? r.argv : [r.answer, r.action], want);
    }
    check("tuiOpen keys a launch by the key it opened", ctx.tuiOpen(manifests, [], "/run/src", "/core/bin", runner("present", []), core, "core/doctor").key, "core/doctor");
    check("tuiOpen hands a plugin launch the runner's run id", ctx.tuiOpen(manifests, ["acme.tui"], "/run/src", "/core/bin", runner("present", []), core, "acme.tui/update").run, "7-1");
    check("tuiOpen names the busy key it asks to focus", ctx.tuiOpen(manifests, [], "/run/src", "/core/bin", runner("present", ["core/doctor"]), core, "core/doctor").key, "core/doctor");
    // tuiCore: [name, launcher state, busy keys, core name, arguments, argv,
    // or the answer and the action it asks for]. The core opens its own
    // rows, listed or not, with arguments after their argv.
    const quietArgv = rest => ["launch", "--title", "Quiet", "--size", "default", "--presentation", "plain", "--record", "core/quiet", "--run", "7-1", "--", "/core/bin/true"].concat(rest);
    const coreOpenRows = [
        ["an unlisted core TUI opens with its arguments", "present", [], "quiet", ["--manager", "aur", "a;b"], quietArgv(["--manager", "aur", "a;b"])],
        ["a listed core TUI opens with its arguments", "present", [], "doctor", ["--json"], doctorArgv.concat(["--json"])],
        ["no argument list opens the argv alone", "present", [], "quiet", undefined, quietArgv([])],
        ["an unknown core name", "present", [], "none", ["a"], ["refused: tui=core/none reason=undeclared", "none"]],
        ["a core name that is a prototype member", "present", [], "constructor", [], ["refused: tui=core/constructor reason=undeclared", "none"]],
        ["a name that is not a string", "present", [], null, [], ["refused: tui=core/null reason=undeclared", "none"]],
        ["seventeen arguments", "present", [], "quiet", Array(17).fill("a"), ["refused: tui=core/quiet reason=args", "none"]],
        ["an empty argument", "present", [], "quiet", [""], ["refused: tui=core/quiet reason=args", "none"]],
        ["arguments that are not a list", "present", [], "quiet", "a", ["refused: tui=core/quiet reason=args", "none"]],
        ["a busy key", "present", ["core/quiet"], "quiet", ["a"], ["refused: tui=core/quiet reason=busy", "focus"]],
        ["a missing launcher", "missing", [], "quiet", ["a"], ["refused: tui=core/quiet reason=launcher-missing", "probe"]],
        ["arguments are judged before a busy key", "present", ["core/quiet"], "quiet", [""], ["refused: tui=core/quiet reason=args", "none"]],
    ];
    for (const [name, launcher, busy, coreName, args, want] of coreOpenRows) {
        const r = ctx.tuiCore(core, "/core/bin", runner(launcher, busy), coreName, args);
        check("tuiCore: " + name, r.ok ? r.argv : [r.answer, r.action], want);
    }
    check("tuiCore keys a launch by core/<name>", ctx.tuiCore(core, "/core/bin", runner("present", []), "quiet", []).key, "core/quiet");
    check("tuiEntries: the core's and every enabled plugin's listed TUIs, by key", ctx.tuiEntries(manifests, ["acme.tui"], core), [
        { key: "acme.tui/update", plugin: "acme.tui", name: "update", title: "Update", label: "Update the system", icon: "terminal", group: "System" },
        { key: "core/doctor", plugin: "core", name: "doctor", title: "Doctor", label: "Check the system", icon: "stethoscope", group: "System" },
    ]);
    check("tuiEntries: a plugin enabled again lists its TUIs again", ctx.tuiEntries(manifests, ["acme.other", "acme.tui"], {}).map(e => e.key), ["acme.other/fix", "acme.tui/update"]);
    check("tuiEntries: an enabled id with no manifest lists nothing", ctx.tuiEntries(manifests, ["acme.gone"], {}), []);

    // coreTuiError: [name, TUI name, row, null for accepted or the start of
    // the refusal].
    const doctor = core.doctor;
    const coreRow = (change) => Object.assign({}, doctor, change);
    const without = (key) => { const row = coreRow({}); delete row[key]; return row; };
    const coreRows = [
        ["a row with every key", "doctor", doctor, null],
        ["a row without an entry", "quiet", coreRow({ entry: null }), null],
        ["a command with arguments at the limit", "doctor", coreRow({ argv: ["vgsh"].concat(Array(16).fill("a")) }), null],
        ["a helper of the core's bin/", "doctor", coreRow({ argv: ["vgsh-sudo-grant", "status"] }), null],
        ["a name with an upper case letter", "Doctor", doctor, "core TUI name \"Doctor\" must be lower case letters, digits and dashes"],
        ["a row that is a string", "doctor", "vgsh doctor", "core/doctor must be an object"],
        ["a row with a script", "doctor", coreRow({ script: "tui/x.sh" }), "core/doctor has unknown key \"script\""],
        ["a row without an entry key", "doctor", without("entry"), "core/doctor needs key entry"],
        ["a row without a size", "doctor", without("size"), "core/doctor needs key size"],
        ["a row without a presentation", "doctor", without("presentation"), "core/doctor needs key presentation"],
        ["an argv that is a string", "doctor", coreRow({ argv: "vgsh doctor" }), "core/doctor.argv must start with a command of the core's bin/ directory, got \"vgsh doctor\""],
        ["an empty argv", "doctor", coreRow({ argv: [] }), "core/doctor.argv must start with a command of the core's bin/ directory"],
        ["a command that is a path", "doctor", coreRow({ argv: ["/usr/bin/vgsh", "doctor"] }), "core/doctor.argv must start with a command of the core's bin/ directory"],
        ["a command outside the core", "doctor", coreRow({ argv: ["sh", "-c", "x"] }), "core/doctor.argv must start with a command of the core's bin/ directory"],
        ["a command with a trailing dash", "doctor", coreRow({ argv: ["vgsh-"] }), "core/doctor.argv must start with a command of the core's bin/ directory"],
        ["an empty argument", "doctor", coreRow({ argv: ["vgsh", ""] }), "core/doctor.argv takes at most 16 arguments of 1 to 256 characters with no control character"],
        ["an argument with a control character", "doctor", coreRow({ argv: ["vgsh", "a\nb"] }), "core/doctor.argv takes at most 16 arguments"],
        ["seventeen arguments", "doctor", coreRow({ argv: ["vgsh"].concat(Array(17).fill("a")) }), "core/doctor.argv takes at most 16 arguments"],
        ["a blank title", "doctor", coreRow({ title: " " }), "core/doctor.title must be one printable line"],
        ["a size no window class has", "doctor", coreRow({ size: "huge" }), "core/doctor.size must be one of default, wide, tall"],
        ["an unknown presentation", "doctor", coreRow({ presentation: "loud" }), "core/doctor.presentation must be one of full, plain"],
        ["an entry that is a string", "doctor", coreRow({ entry: "Doctor" }), "core/doctor.entry must be an object"],
        ["an entry icon outside the shipped set", "doctor", coreRow({ entry: { label: "L", icon: "no-such-icon", group: "System" } }), "core/doctor.entry.icon must name an icon of the shipped set"],
    ];
    for (const [name, tuiName, row, want] of coreRows) {
        const got = ctx.coreTuiError(tuiName, row);
        check("coreTuiError: " + name, want === null ? got : got.slice(0, want.length), want === null ? "" : want);
    }
    const thrown = (table) => { try { return ctx.coreTuiTable(table) === table ? "accepted" : "replaced"; } catch (e) { return e.message; } };
    check("coreTuiTable returns a judged table", thrown({ doctor: doctor }), "accepted");
    check("coreTuiTable throws on a row's first defect", thrown({ doctor: doctor, bad: without("argv") }), "tui: core/bad needs key argv");

    // The shipped table: the package pickers, the passwordless sudo grant,
    // the requirement report, the plugin and theme adds, the requirement
    // notice's install and the plugin manager's rows for one plugin, each
    // command a file of the core's bin/ its owner may run.
    const shipped = {
        "pkg-install": { argv: ["vgsh", "pkg", "install"], title: "Install packages", size: "default", presentation: "full", entry: { label: "Install packages", icon: "package-plus", group: "Packages" } },
        "pkg-remove": { argv: ["vgsh", "pkg", "remove"], title: "Remove packages", size: "default", presentation: "full", entry: { label: "Remove packages", icon: "package-minus", group: "Packages" } },
        "sudo-grant": { argv: ["vgsh", "sudo", "grant"], title: "Passwordless sudo", size: "default", presentation: "full", entry: { label: "Passwordless sudo", icon: "shield-alert", group: "System" } },
        "doctor": { argv: ["vgsh", "doctor"], title: "Requirements", size: "default", presentation: "full", entry: { label: "Check requirements", icon: "stethoscope", group: "System" } },
        "plugin-add": { argv: ["vgsh", "plugin", "add"], title: "Add a plugin", size: "default", presentation: "full", entry: { label: "Add a plugin", icon: "circle-plus", group: "Plugins" } },
        "theme-add": { argv: ["vgsh", "theme", "add"], title: "Add a theme", size: "default", presentation: "full", entry: { label: "Add a theme", icon: "palette", group: "Themes" } },
        "requirements-install": { argv: ["vgsh", "pkg", "run", "install"], title: "Install requirements", size: "default", presentation: "full", entry: null },
        "plugin-update": { argv: ["vgsh", "plugin", "update"], title: "Update a plugin", size: "wide", presentation: "full", entry: null },
        "plugin-remove": { argv: ["vgsh", "plugin", "remove"], title: "Remove a plugin", size: "default", presentation: "full", entry: null },
    };
    check("the core's TUI table holds its rows and no other", Object.keys(ctx.CORE_TUIS).sort(), Object.keys(shipped).sort());
    for (const name of Object.keys(shipped))
        check("the core's TUI " + name, ctx.CORE_TUIS[name], shipped[name]);
    check("every core command is an executable file of bin/", Object.keys(ctx.CORE_TUIS).filter(n => {
        const file = path.join(BIN, ctx.CORE_TUIS[n].argv[0]);
        const stat = fs.lstatSync(file, { throwIfNoEntry: false });
        return stat === undefined || !stat.isFile() || (stat.mode & 0o100) === 0;
    }), []);

    // managerTui: [name, action, id, source, the core name and arguments,
    // or the manager's reply].
    const managerRows = [
        ["update opens the plugin update for an installed plugin", "update", "acme.tui", "installed", ["plugin-update", ["acme.tui"]]],
        ["remove opens the plugin remove for an installed plugin", "remove", "acme.tui", "installed", ["plugin-remove", ["acme.tui"]]],
        ["update refuses a bundled plugin", "update", "vgs.bar", "bundled", "refused: bundled=vgs.bar"],
        ["remove refuses a bundled plugin", "remove", "vgs.bar", "bundled", "refused: bundled=vgs.bar"],
        ["an id no plugin has", "update", "acme.none", null, "unknown: acme.none"],
        ["an id that is not a string", "remove", 7, null, "unknown: 7"],
    ];
    for (const [name, action, id, source, want] of managerRows) {
        const r = ctx.managerTui(action, id, source);
        check("managerTui: " + name, r.ok ? [r.name, r.args] : r.answer, want);
    }
    const managerThrown = (action, source) => { try { ctx.managerTui(action, "acme.tui", source); return "answered"; } catch (e) { return e.message; } };
    check("managerTui throws on an action no row covers", managerThrown("add", "installed"), "manager: no TUI action \"add\", want one of update, remove");
    check("managerTui throws on a source no rule covers", managerThrown("update", "linked"), "manager: plugin source \"linked\" is not one of bundled, installed");
    // tuiShownAnswer: [name, key, answer, the shared shown answer].
    const answerRows = [
        ["a launch the runner started", "core/plugin-update", "ok", "ok"],
        ["the live window of the same core TUI the runner focused", "core/plugin-update", "refused: tui=core/plugin-update reason=busy", "ok"],
        ["the live window of the same plugin TUI the runner focused", "acme.tui/update", "refused: tui=acme.tui/update reason=busy", "ok"],
        ["a busy key of another TUI", "core/plugin-update", "refused: tui=core/plugin-remove reason=busy", "refused: tui=core/plugin-remove reason=busy"],
        ["no terminal", "core/plugin-add", "refused: tui=core/plugin-add reason=launcher-missing", "refused: tui=core/plugin-add reason=launcher-missing"],
        ["refused arguments", "core/plugin-remove", "refused: tui=core/plugin-remove reason=args", "refused: tui=core/plugin-remove reason=args"],
        ["a disabled plugin", "acme.tui/update", "refused: tui=acme.tui/update reason=disabled", "refused: tui=acme.tui/update reason=disabled"],
        ["an undeclared key", "acme.tui/missing", "refused: tui=acme.tui/missing reason=undeclared", "refused: tui=acme.tui/missing reason=undeclared"],
    ];
    for (const [name, key, answer, want] of answerRows)
        check("tuiShownAnswer: " + name, ctx.tuiShownAnswer(key, answer), want);
    check("every manager TUI opens an unlisted core row", Object.keys(ctx.MANAGER_TUIS).filter(a => {
        const row = ctx.CORE_TUIS[ctx.MANAGER_TUIS[a]];
        return row === undefined || row.entry !== null;
    }), []);

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

    // tuiLauncherAfter: [name, state before, completion, state after].
    const stateRows = [
        ["exit 0 finds the terminal", "unknown", { code: 0, status: 0 }, "present"],
        ["exit 0 after a missing state finds it again", "missing", { code: 0, status: 0 }, "present"],
        ["exit 69 finds no terminal", "present", { code: 69, status: 0 }, "missing"],
        ["exit 69 before any answer", "unknown", { code: 69, status: 0 }, "missing"],
        ["a process that never started says nothing", "missing", null, "missing"],
        ["a crash says nothing", "missing", { code: 0, status: 1 }, "missing"],
        ["a bad invocation says nothing", "unknown", { code: 2, status: 0 }, "unknown"],
    ];
    for (const [name, before, completion, want] of stateRows)
        check("tuiLauncherAfter: " + name, ctx.tuiLauncherAfter(before, completion), want);

    // tuiProbeOutcome: [name, completion, stderr, log line].
    const probeRows = [
        ["a probe that found the terminal", { code: 0, status: 0 }, "", ""],
        ["a probe that found none is recorded, not logged", { code: 69, status: 0 }, "vgsh-tui: refused: terminal=missing", ""],
        ["a probe that never started", null, "", "tui: probe=unstarted"],
        ["a probe with a bad invocation", { code: 2, status: 0 }, "vgsh-tui: refused: argument=x\nusage", "tui: probe=failed exit=2 status=0 vgsh-tui: refused: argument=x"],
        ["a probe that crashed", { code: 0, status: 1 }, "", "tui: probe=failed exit=0 status=1 "],
    ];
    for (const [name, completion, stderr, want] of probeRows)
        check("tuiProbeOutcome: " + name, ctx.tuiProbeOutcome(completion, stderr), want);

    // tuiLaunchDone: [name, completion, what `done` receives or null].
    const launchDoneRows = [
        ["a launcher that saw the record waits for the run", { code: 0, status: 0 }, null],
        ["no terminal", { code: 69, status: 0 }, { code: null, reason: "launcher-missing" }],
        ["a silent terminal", { code: 1, status: 0 }, { code: null, reason: "launcher-failed" }],
        ["a launcher that never started", null, { code: null, reason: "launcher-failed" }],
        ["a launcher that crashed", { code: 0, status: 1 }, { code: null, reason: "launcher-failed" }],
        ["a crash with the missing code", { code: 69, status: 1 }, { code: null, reason: "launcher-failed" }],
    ];
    for (const [name, completion, want] of launchDoneRows)
        check("tuiLaunchDone: " + name, ctx.tuiLaunchDone(completion), want);

    // tuiRecord: [name, record object, null for accepted or the start of
    // the refusal].
    const win = { appId: "org.vgs.tui", title: "VGS · Hello" };
    const runningRecord = { key: "acme.tui/hello", run: "7-1", state: "running", code: null, startedAt: "2026-09-29T07:00:00.000Z", endedAt: null, window: win };
    const endedRecord = Object.assign({}, runningRecord, { state: "ended", code: 3, endedAt: "2026-09-29T07:00:05.000Z" });
    const recordRows = [
        ["a running record", runningRecord, null],
        ["an ended record", endedRecord, null],
        ["a reaped record with a null code", Object.assign({}, endedRecord, { code: null }), null],
        ["a core key", Object.assign({}, runningRecord, { key: "core/doctor" }), null],
        ["a list", [runningRecord], "record is not an object"],
        ["a key with no slash", Object.assign({}, runningRecord, { key: "acme.tui" }), "record key \"acme.tui\" is not a launch key"],
        ["a key whose owner is no plugin id", Object.assign({}, runningRecord, { key: "acme/hello" }), "record key \"acme/hello\" is not a launch key"],
        ["a key whose name is no name", Object.assign({}, runningRecord, { key: "acme.tui/Hello" }), "record key \"acme.tui/Hello\" is not a launch key"],
        ["a key with no slash that splits into two valid halves", Object.assign({}, runningRecord, { key: "corex" }), "record key \"corex\" is not a launch key"],
        ["a key with two slashes", Object.assign({}, runningRecord, { key: "acme.tui/a/b" }), "record key \"acme.tui/a/b\" is not a launch key"],
        ["a run that is a number", Object.assign({}, runningRecord, { run: 7 }), "record run 7 is malformed"],
        ["a run with a slash", Object.assign({}, runningRecord, { run: "7/1" }), "record run \"7/1\" is malformed"],
        ["an unknown state", Object.assign({}, runningRecord, { state: "paused" }), "record state \"paused\" is not one of running, ended"],
        ["a running record with a code", Object.assign({}, runningRecord, { code: 0 }), "record code 0 does not fit state running"],
        ["an ended record with a fractional code", Object.assign({}, endedRecord, { code: 1.5 }), "record code 1.5 does not fit state ended"],
        ["an ended record with a string code", Object.assign({}, endedRecord, { code: "0" }), "record code \"0\" does not fit state ended"],
        ["no startedAt", Object.assign({}, runningRecord, { startedAt: "" }), "record startedAt must be a string"],
        ["a running record with an endedAt", Object.assign({}, runningRecord, { endedAt: "2026-09-29T07:00:05.000Z" }), "record endedAt \"2026-09-29T07:00:05.000Z\" does not fit state running"],
        ["an ended record with no endedAt", Object.assign({}, endedRecord, { endedAt: null }), "record endedAt null does not fit state ended"],
        ["no window", Object.assign({}, runningRecord, { window: null }), "record window must be { appId, title }"],
        ["a window with no title", Object.assign({}, runningRecord, { window: { appId: "org.vgs.tui" } }), "record window must be { appId, title }"],
    ];
    for (const [name, value, want] of recordRows) {
        const r = ctx.tuiRecord(JSON.stringify(value));
        check("tuiRecord: " + name, r.ok ? null : r.error.slice(0, want === null ? 0 : want.length), want);
    }
    check("tuiRecord: text that is no JSON", ctx.tuiRecord("{ nope").error.startsWith("record is not JSON: "), true);
    check("tuiRecord keeps the known fields alone", ctx.tuiRecord(JSON.stringify(Object.assign({ extra: 1 }, endedRecord))).record, endedRecord);

    // tuiRuns, tuiBusyKeys, tuiState and tuiRunDone over one set of records:
    // hello's first run ended, its second is running, update's run was
    // reaped and fix's first run ended before its second ended.
    const at = (s) => "2026-09-29T07:00:" + s + ".000Z";
    const rec = (key, run, state, code, started, ended) => ({ key: key, run: run, state: state, code: code, startedAt: at(started), endedAt: ended === null ? null : at(ended), window: win });
    const set = [
        rec("acme.tui/hello", "1-1", "ended", 0, "01", "02"),
        rec("acme.tui/hello", "2-1", "running", null, "03", null),
        rec("acme.tui/update", "3-1", "running", null, "04", null),
        rec("acme.tui/update", "3-1", "ended", null, "04", "09"),
        rec("acme.other/fix", "4-1", "ended", 4, "04", "06"),
        rec("acme.other/fix", "5-1", "ended", 1, "05", "07"),
    ];
    const runs = ctx.tuiRuns(set);
    check("tuiRuns: a key's live run is its running record", runs.keys["acme.tui/hello"].running.run, "2-1");
    check("tuiRuns: a key's ended run survives its next run's start", runs.keys["acme.tui/hello"].ended.run, "1-1");
    check("tuiRuns: a run with an ended record is not running", runs.keys["acme.tui/update"].running, null);
    check("tuiRuns: an ended record wins over its run's running one in either order", ctx.tuiRuns(set.slice().reverse()).keys["acme.tui/update"].running, null);
    check("tuiRuns: the ended run is the one that started last", runs.keys["acme.other/fix"].ended.run, "5-1");
    check("tuiRuns: a run reap ended late does not stand over a later run", ctx.tuiRuns([rec("acme.tui/hello", "9-1", "ended", 0, "10", "11"), rec("acme.tui/hello", "8-1", "ended", null, "08", "12")]).keys["acme.tui/hello"].ended.run, "9-1");
    check("tuiRuns: the live run is the one that started last", ctx.tuiRuns([rec("acme.tui/hello", "6-1", "running", null, "06", null), rec("acme.tui/hello", "8-1", "running", null, "08", null)]).keys["acme.tui/hello"].running.run, "8-1");
    check("tuiRuns: runs by id", Object.keys(runs.runs).sort(), ["1-1", "2-1", "3-1", "4-1", "5-1"]);
    check("tuiRuns: no record, no key", ctx.tuiRuns([]), { runs: {}, keys: {} });
    check("tuiBusyKeys: running keys and launching keys, once each", ctx.tuiBusyKeys(runs, ["core/doctor", "acme.tui/hello"]), ["acme.tui/hello", "core/doctor"]);
    check("tuiBusyKeys: a key whose runs all ended is free", ctx.tuiBusyKeys(runs, []).indexOf("acme.tui/update"), -1);
    check("tuiState: the plugin's own names, running and last ended", ctx.tuiState(runs, "acme.tui", ["hello", "update", "never"]), {
        hello: { running: true, code: 0, endedAt: at("02") },
        update: { running: false, code: null, endedAt: at("09") },
        never: { running: false, code: null, endedAt: null },
    });
    check("tuiState: another plugin's keys stay its own", ctx.tuiState(runs, "acme.other", ["hello"]), { hello: { running: false, code: null, endedAt: null } });
    check("tuiRunDone: an ended run answers its code", ctx.tuiRunDone(runs, "1-1"), { code: 0, reason: null });
    check("tuiRunDone: a failed run answers its code", ctx.tuiRunDone(runs, "5-1"), { code: 1, reason: null });
    check("tuiRunDone: a reaped run vanished", ctx.tuiRunDone(runs, "3-1"), { code: null, reason: "vanished" });
    check("tuiRunDone: a running run answers nothing yet", ctx.tuiRunDone(runs, "2-1"), null);
    check("tuiRunDone: a run with no record answers nothing yet", ctx.tuiRunDone(runs, "9-1"), null);

    // tuiWaitRuns and tuiWaitOutcome: the QML owner starts a wait for a
    // launched run once the launcher exits 0, and for a running record read
    // after restart. Only this judge accepts the wait's stdout as a record.
    check("tuiWaitRuns: a launched run without an ended record gets a wait", ctx.tuiWaitRuns(runs, [{ key: "acme.tui/new", run: "9-1" }]), [{ key: "acme.tui/hello", run: "2-1" }, { key: "acme.tui/new", run: "9-1" }]);
    check("tuiWaitRuns: a launched run that already ended gets no wait", ctx.tuiWaitRuns(runs, [{ key: "acme.tui/hello", run: "1-1" }]), [{ key: "acme.tui/hello", run: "2-1" }]);
    check("tuiWaitRuns: a running record after restart gets a wait", ctx.tuiWaitRuns(runs, []), [{ key: "acme.tui/hello", run: "2-1" }]);
    const waitEnded = JSON.stringify(rec("acme.tui/hello", "2-1", "ended", 7, "03", "08"));
    check("tuiWaitOutcome: accepts one ended record for this run", ctx.tuiWaitOutcome("acme.tui/hello", "2-1", { code: 0, status: 0 }, waitEnded + "\n", ""), { record: rec("acme.tui/hello", "2-1", "ended", 7, "03", "08"), logs: [] });
    check("tuiWaitOutcome: a vanished record is accepted", ctx.tuiWaitOutcome("acme.tui/hello", "2-1", { code: 0, status: 0 }, JSON.stringify(rec("acme.tui/hello", "2-1", "ended", null, "03", "08")) + "\n", ""), { record: rec("acme.tui/hello", "2-1", "ended", null, "03", "08"), logs: [] });
    check("tuiWaitOutcome: a failed wait is logged", ctx.tuiWaitOutcome("acme.tui/hello", "2-1", { code: 1, status: 0 }, "", "vgsh-tui: refused: wait=acme.tui/hello reason=gone\n"), { record: null, logs: ["tui: wait=acme.tui/hello run=2-1 reason=failed exit=1 status=0 vgsh-tui: refused: wait=acme.tui/hello reason=gone"] });
    check("tuiWaitOutcome: stdout must hold one line", ctx.tuiWaitOutcome("acme.tui/hello", "2-1", { code: 0, status: 0 }, waitEnded + "\n" + waitEnded + "\n", ""), { record: null, logs: ["tui: wait=acme.tui/hello run=2-1 reason=stdout-lines count=2"] });
    check("tuiWaitOutcome: stdout must be a record", ctx.tuiWaitOutcome("acme.tui/hello", "2-1", { code: 0, status: 0 }, "{ nope\n", "").logs[0].startsWith("tui: wait=acme.tui/hello run=2-1 reason=record is not JSON: "), true);
    check("tuiWaitOutcome: stdout must be this run's ended record", ctx.tuiWaitOutcome("acme.tui/hello", "2-1", { code: 0, status: 0 }, JSON.stringify(rec("acme.tui/hello", "2-2", "ended", 0, "03", "08")) + "\n", ""), { record: null, logs: ["tui: wait=acme.tui/hello run=2-1 reason=record-mismatch"] });
    check("tuiWaitOutcome: a running record is refused", ctx.tuiWaitOutcome("acme.tui/hello", "2-1", { code: 0, status: 0 }, JSON.stringify(rec("acme.tui/hello", "2-1", "running", null, "03", null)) + "\n", ""), { record: null, logs: ["tui: wait=acme.tui/hello run=2-1 reason=record-mismatch"] });
    check("tuiWaitOutcome: a wait that never started is logged", ctx.tuiWaitOutcome("acme.tui/hello", "2-1", null, "", ""), { record: null, logs: ["tui: wait=acme.tui/hello run=2-1 reason=unstarted"] });

    // tuiWindow: [name, windows, the result].
    const w = (address, appId, title) => ({ address: address, appId: appId, title: title });
    const windowRows = [
        ["one window with the app-id and the title", [w("a1", "org.vgs.tui", "VGS · Hello"), w("b2", "org.vgs.tui", "VGS · Other")], { state: "found", address: "0xa1" }],
        ["an address that has its prefix", [w("0xa1", "org.vgs.tui", "VGS · Hello")], { state: "found", address: "0xa1" }],
        ["the title under another app-id", [w("a1", "org.vgs.tui.wide", "VGS · Hello")], { state: "none" }],
        ["the app-id under another title", [w("a1", "org.vgs.tui", "VGS · Hello!")], { state: "none" }],
        ["a match with no address yet", [w("", "org.vgs.tui", "VGS · Hello")], { state: "none" }],
        ["no window", [], { state: "none" }],
        ["two windows alike", [w("a1", "org.vgs.tui", "VGS · Hello"), w("b2", "org.vgs.tui", "VGS · Hello")], { state: "ambiguous", count: 2 }],
    ];
    for (const [name, windows, want] of windowRows)
        check("tuiWindow: " + name, ctx.tuiWindow(windows, win), want);

    // tuiReapOutcome: [name, completion, stdout, stderr, log lines].
    const reapRows = [
        ["a reap that ended nothing", { code: 0, status: 0 }, "", "", []],
        ["a reap that ended two runs", { code: 0, status: 0 }, "reaped=acme.tui/hello run=2-1\nreaped=core/doctor run=3-1\n", "", [{ level: "info", text: "tui: reaped=acme.tui/hello run=2-1" }, { level: "info", text: "tui: reaped=core/doctor run=3-1" }]],
        ["a line no reap prints", { code: 0, status: 0 }, "reaped everything\n", "", [{ level: "error", text: "tui: reap=unparsed line=\"reaped everything\"" }]],
        ["a reap that failed on one record", { code: 1, status: 0 }, "reaped=core/doctor run=3-1\n", "vgsh-tui: refused: reap=/r/x reason=malformed\n", [{ level: "info", text: "tui: reaped=core/doctor run=3-1" }, { level: "error", text: "tui: reap=failed exit=1 status=0 vgsh-tui: refused: reap=/r/x reason=malformed" }]],
        ["a reap that crashed", { code: 0, status: 1 }, "", "", [{ level: "error", text: "tui: reap=failed exit=0 status=1 " }]],
        ["a reap that never started", null, "", "", [{ level: "error", text: "tui: reap=unstarted" }]],
    ];
    for (const [name, completion, stdout, stderr, want] of reapRows)
        check("tuiReapOutcome: " + name, ctx.tuiReapOutcome(completion, stdout, stderr), want);
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
    ["an entry is an object", "if (!isPlainObject(entry))\n        return at + \".entry must be an object\";", "if (false)\n        return at + \".entry must be an object\";"],
    ["an entry holds known keys", "if (TUI_ENTRY_KEYS.indexOf(entryKeys[e]) === -1)", "if (false)"],
    ["an entry has a label", "if (!tuiText(entry.label))", "if (false)"],
    ["an entry icon is shipped", "if (typeof entry.icon !== \"string\" || !hasOwn(Lucide.ICONS, entry.icon))", "if (false)"],
    ["an entry has a group", "if (!tuiText(entry.group))", "if (false)"],
    ["the tui judge runs the window judge", "        var windowError = tuiWindowError(at, row);\n        if (windowError !== \"\")\n            return windowError;\n", ""],
    ["the tui judge runs the entry judge", "        var entryError = tuiEntryError(at, row.entry);\n        if (entryError !== \"\")\n            return entryError;\n", ""],
    ["a core TUI name is a name", "if (!NAME_PATTERN.test(name))\n        return \"core TUI name ", "if (false)\n        return \"core TUI name "],
    ["a core row is an object", "if (!isPlainObject(row))\n        return at + \" must be an object\";", "if (false)\n        return at + \" must be an object\";"],
    ["a core row holds known keys", "if (CORE_TUI_KEYS.indexOf(keys[k]) === -1)", "if (false)"],
    ["a core row holds every key", "if (row[CORE_TUI_KEYS[m]] === undefined)", "if (false)"],
    ["a core command is judged", " || !CORE_TUI_COMMAND.test(row.argv[0]))", ")"],
    ["a core command is a core file name", "var CORE_TUI_COMMAND = /^vgsh(-[a-z]+)*$/;", "var CORE_TUI_COMMAND = /^[a-z\\/-]+$/;"],
    ["a core row's arguments are judged", "if (!tuiArgsValid(row.argv.slice(1)))", "if (false)"],
    ["a core row's window is judged", "    var windowError = tuiWindowError(at, row);\n    if (windowError !== \"\")\n        return windowError;\n    return row.entry", "    return row.entry"],
    ["a core row's entry is judged", "return row.entry === null ? \"\" : tuiEntryError(at, row.entry);", "return \"\";"],
    ["a core row may have no entry", "return row.entry === null ? \"\" : tuiEntryError(at, row.entry);", "return tuiEntryError(at, row.entry);", "tui: core/requirements-install.entry must be an object"],
    ["the core table throws on a defect", "if (error !== \"\")\n            throw new Error(\"tui: \" + error);", "if (false)\n            throw new Error(\"tui: \" + error);"],
    ["open resolves a core command under the core's bin/", "[coreBin + \"/\" + row.argv[0]]", "[row.argv[0]]"],
    ["the manager's actions are a table", "if (!hasOwn(MANAGER_TUIS, action))", "if (false)"],
    ["the manager refuses an unknown id", "if (typeof id !== \"string\" || source === null)", "if (false)"],
    ["the plugin update asks before it fast-forwards", "argv: [\"vgsh\", \"plugin\", \"update\"],", "argv: [\"vgsh\", \"plugin\", \"update\", \"--yes\"],"],
    ["the plugin remove asks before it deletes", "argv: [\"vgsh\", \"plugin\", \"remove\"],", "argv: [\"vgsh\", \"plugin\", \"remove\", \"--yes\"],"],
    ["the shared answer maps a focused live window", "return answer === tuiRefusal(key, \"busy\").answer ? \"ok\" : answer;", "return answer;"],
    ["the shared answer maps only its own busy key", "return answer === tuiRefusal(key, \"busy\").answer ? \"ok\" : answer;", "return /reason=busy$/.test(answer) ? \"ok\" : answer;"],
    ["the plugin update opens wide", "title: \"Update a plugin\",\n        size: \"wide\",", "title: \"Update a plugin\",\n        size: \"default\","],
    ["the manager's sources are known", "    throw new Error(\"manager: plugin source \" + JSON.stringify(source)", "    return { ok: false, answer: \"refused: bundled=\" + id };\n    throw new Error(\"manager: plugin source \" + JSON.stringify(source)"],
    ["the manager refuses a bundled plugin", "    case \"bundled\":\n        return { ok: false, answer: \"refused: bundled=\" + id };", "    case \"bundled\":"],
    ["the manager's update opens the plugin update", "    update: \"plugin-update\",", "    update: \"plugin-remove\","],
    ["the manager's remove opens the plugin remove", "    remove: \"plugin-remove\"\n", "    remove: \"plugin-update\"\n"],
    ["the manifest judge runs the tui judge", "var badTui = tuiError(raw.tui, capabilities);", "var badTui = \"\";"],
    ["the manifest carries its tui normalized", "manifest.tui = normalTui(raw.tui === undefined ? {} : raw.tui);", "manifest.tui = raw.tui;"],
    ["an absent size is default", "size: row.size === undefined ? \"default\" : row.size", "size: row.size"],
    ["an absent presentation is full", "presentation: row.presentation === undefined ? \"full\" : row.presentation", "presentation: row.presentation"],
    ["an absent entry is null", "entry: row.entry === undefined ? null : clone(row.entry)", "entry: row.entry"],
    ["at most sixteen arguments", "if (!Array.isArray(args) || args.length > TUI_ARGS_MAX)", "if (!Array.isArray(args))"],
    ["arguments are a list", "if (!Array.isArray(args) || args.length > TUI_ARGS_MAX)", "if (args.length > TUI_ARGS_MAX)"],
    ["an argument is a string", "typeof arg === \"string\" && arg.length > 0", "arg.length > 0"],
    ["an argument is not empty", "typeof arg === \"string\" && arg.length > 0 && ", "typeof arg === \"string\" && "],
    ["an argument is at most 256 characters", "Array.from(arg).length <= TUI_ARG_MAX && ", ""],
    ["an argument holds no control character", " && !CONTROL_CHARACTER.test(arg);", ";"],
    ["run opens only a declared script", "if (typeof name !== \"string\" || !hasOwn(manifest.tui, name))", "if (false)"],
    ["run refuses a disabled plugin", "if (!enabled)\n        return tuiRefusal(name, \"disabled\");", "if (false)\n        return tuiRefusal(name, \"disabled\");"],
    ["run judges its arguments", "    if (!tuiArgsValid(args))\n        return tuiRefusal(name, \"args\");", "    if (false)\n        return tuiRefusal(name, \"args\");"],
    ["run starts from the published snapshot", "dir: sourceDir + \"/\" + manifest.__revision", "dir: manifest.__sourceDir"],
    ["the launch names the plugin", "argv.push(\"--plugin\", plugin.id, \"--dir\", plugin.dir);", "argv.push(\"--dir\", plugin.dir);"],
    ["open needs a key with a slash", "if (slash === -1)\n        return tuiRefusal(key, \"undeclared\");", "if (false)\n        return tuiRefusal(key, \"undeclared\");"],
    ["the core's install picker runs vgsh pkg install", "argv: [\"vgsh\", \"pkg\", \"install\"]", "argv: [\"vgsh\", \"pkg\", \"remove\"]"],
    ["a core TUI is found in the table by its own key", "if (typeof name !== \"string\" || !hasOwn(core, name))", "if (typeof name !== \"string\" || core[name] === undefined)"],
    ["open lists only a core TUI with an entry", "if (!hasOwn(core, name) || core[name].entry === null)", "if (!hasOwn(core, name))"],
    ["open needs an entry", " || manifests[owner].tui[name].entry === null)", ")"],
    ["open refuses a disabled plugin", "if (enabledIds.indexOf(owner) === -1)", "if (false)"],
    ["entries skip a script without an entry", "if (row.entry === null)\n            return;", "if (false)\n            return;"],
    ["entries list enabled plugins alone", "    enabledIds.forEach(function (id) {", "    Object.keys(manifests).forEach(function (id) {"],
    ["entries sort by key", "return rows.sort(function (a, b) { return a.key < b.key ? -1 : a.key > b.key ? 1 : 0; });", "return rows;"],
    ["a label is quoted unless one visible word", "/^[\\x21-\\x7e]+$/.test(name)", "true"],
    ["a crashed launcher is a failure", "if (completion.status === 0 && completion.code === 0)", "if (completion.code === 0)"],
    ["exit 69 is launcher-missing", "if (completion.status === 0 && completion.code === TUI_LAUNCHER_MISSING)\n        return \"tui: refused: tui=\"", "if (false)\n        return \"tui: refused: tui=\""],
    ["a busy key refuses", "if (runner.busy.indexOf(key) !== -1) {", "if (false) {"],
    ["a busy key asks for its window", "        refusal.action = \"focus\";\n", ""],
    ["a missing launcher refuses", "} else if (runner.launcher === \"missing\") {", "} else if (false) {"],
    ["a missing launcher asks for a probe", "        refusal.action = \"probe\";\n", ""],
    ["a runner refusal names its key", "    refusal.key = key;\n", ""],
    ["a launcher state outside the table throws", "if (TUI_LAUNCHER_STATES.indexOf(runner.launcher) === -1)", "if (false)"],
    ["run consults the runner after the judge", "    var refusal = tuiRunnerRefusal(runner, name, key);\n    if (refusal !== null)\n        return refusal;\n", ""],
    ["open consults the runner for a core TUI", "    var refusal = tuiRunnerRefusal(runner, key, key);\n    if (refusal !== null)\n        return refusal;\n    var row = core[name];", "    var row = core[name];"],
    ["open consults the runner for a plugin TUI", "    if (pluginRefusal !== null)\n        return pluginRefusal;\n", ""],
    ["a launch carries its record key and run", "    argv.push(\"--record\", key, \"--run\", run);\n", ""],
    ["a launcher that saw the record waits for the run", "if (completion !== null && completion.status === 0 && completion.code === 0)\n        return null;", "if (false)\n        return null;"],
    ["a crashed launcher fails its done", "if (completion !== null && completion.status === 0 && completion.code === 0)\n        return null;", "if (completion !== null && completion.code === 0)\n        return null;"],
    ["no terminal answers done launcher-missing", "if (completion !== null && completion.status === 0 && completion.code === TUI_LAUNCHER_MISSING)\n        return { code: null, reason: \"launcher-missing\" };", "if (false)\n        return { code: null, reason: \"launcher-missing\" };"],
    ["a record that is no JSON is refused", "    try {\n        value = JSON.parse(text);\n    } catch (e) {\n        return { ok: false, error: \"record is not JSON: \" + e.message };\n    }", "    value = JSON.parse(text);"],
    ["a record is an object", "if (!isPlainObject(value))\n        return { ok: false, error: \"record is not an object\" };", "if (false)\n        return { ok: false, error: \"record is not an object\" };"],
    ["a record key is a launch key", "if (!tuiKeyValid(value.key))", "if (false)"],
    ["a launch key has a slash", "if (slash === -1)\n        return false;\n    var owner", "if (false)\n        return false;\n    var owner"],
    ["a launch key's owner is core or a plugin id", "(owner === \"core\" || ID_PATTERN.test(owner))", "true"],
    ["a launch key's name is a name", " && NAME_PATTERN.test(key.slice(slash + 1));", ";"],
    ["a record run matches the run pattern", "if (typeof value.run !== \"string\" || !TUI_RUN_PATTERN.test(value.run))", "if (typeof value.run !== \"string\")"],
    ["a record run is a string", "if (typeof value.run !== \"string\" || !TUI_RUN_PATTERN.test(value.run))", "if (!TUI_RUN_PATTERN.test(value.run))"],
    ["a record state is known", "if (TUI_RECORD_STATES.indexOf(value.state) === -1)", "if (false)"],
    ["a running record has no code", "if (!(value.code === null || (ended && Number.isInteger(value.code))))", "if (!(value.code === null || Number.isInteger(value.code)))"],
    ["an ended record's code is an integer", "(ended && Number.isInteger(value.code))", "(ended && typeof value.code === \"number\")"],
    ["a record has a startedAt", "if (typeof value.startedAt !== \"string\" || value.startedAt.length === 0)", "if (false)"],
    ["a record's endedAt fits its state", "if (ended ? typeof value.endedAt !== \"string\" || value.endedAt.length === 0 : value.endedAt !== null)", "if (false)"],
    ["a record's window has an app-id and a title", "if (!isPlainObject(value.window) || typeof value.window.appId !== \"string\" || typeof value.window.title !== \"string\")", "if (!isPlainObject(value.window))"],
    ["an ended record wins over its run's running one", "if (!hasOwn(runs, record.run) || record.state === \"ended\")", "if (true)"],
    ["the live run is the one that started last", "if (slot.running === null || record.startedAt > slot.running.startedAt)", "if (slot.running === null)"],
    ["the ended run is the one that started last", "} else if (slot.ended === null || record.startedAt > slot.ended.startedAt) {", "} else if (slot.ended === null) {"],
    ["the ended run is not the one that ended last", "} else if (slot.ended === null || record.startedAt > slot.ended.startedAt) {", "} else if (slot.ended === null || record.endedAt > slot.ended.endedAt) {"],
    ["a key whose runs ended is not busy", "if (runs.keys[key].running !== null && busy.indexOf(key) === -1)", "if (busy.indexOf(key) === -1)"],
    ["a busy key is listed once", "if (runs.keys[key].running !== null && busy.indexOf(key) === -1)", "if (runs.keys[key].running !== null)"],
    ["busy keys are sorted", "    return busy.sort();", "    return busy;"],
    ["state reads running from the live run", "running: slot.running !== null,", "running: false,"],
    ["state reads the code of the last ended run", "code: slot.ended === null ? null : slot.ended.code,", "code: null,"],
    ["state reads the end of the last ended run", "endedAt: slot.ended === null ? null : slot.ended.endedAt", "endedAt: null"],
    ["a running run's done waits", "if (!hasOwn(runs.runs, run) || runs.runs[run].state !== \"ended\")", "if (!hasOwn(runs.runs, run))"],
    ["a reaped run's done says vanished", "reason: code === null ? \"vanished\" : null", "reason: null"],
    ["a launched run waits until it ended", "if (!hasOwn(runs.runs, row.run) || runs.runs[row.run].state !== \"ended\")", "if (false)"],
    ["a listed running run waits after restart", "if (running !== null)\n            add(key, running.run);", "if (false)\n            add(key, running.run);"],
    ["a wait prints exactly one record line", "if (lines.length !== 1)\n        return { record: null, logs: [prefix + \" reason=stdout-lines count=\" + lines.length] };", "if (false)\n        return { record: null, logs: [prefix + \" reason=stdout-lines count=\" + lines.length] };"],
    ["a wait record is this run and ended", "if (judged.record.key !== key || judged.record.run !== run || judged.record.state !== \"ended\")", "if (false)"],
    ["a window matches the app-id", "        return w.appId === window.appId && ", "        return "],
    ["a window matches the title", "w.title === window.title && typeof w.address", "typeof w.address"],
    ["a window needs an address", " && typeof w.address === \"string\" && w.address !== \"\";", ";"],
    ["two windows alike are ambiguous", "if (matches.length > 1)\n        return { state: \"ambiguous\"", "if (false)\n        return { state: \"ambiguous\""],
    ["an address gets its prefix once", "address.indexOf(\"0x\") === 0 ? address : \"0x\" + address", "\"0x\" + address"],
    ["a reap line is parsed", "/^reaped=[a-z0-9.-]+\\/[a-z0-9-]+ run=[a-z0-9-]+$/.test(line)", "true"],
    ["a crashed reap is a failure", "else if (completion.status !== 0 || completion.code !== 0)", "else if (completion.code !== 0)"],
    ["a reap that never started is logged", "if (completion === null)\n        lines.push({ level: \"error\", text: \"tui: reap=unstarted\" });\n    else if", "if (false)\n        lines.push({ level: \"error\", text: \"tui: reap=unstarted\" });\n    else if"],
    ["exit 0 is present", "    if (completion.code === 0)\n        return \"present\";", "    if (false)\n        return \"present\";"],
    ["exit 69 is missing", "    if (completion.code === TUI_LAUNCHER_MISSING)\n        return \"missing\";", "    if (false)\n        return \"missing\";"],
    ["a crash keeps the state", "if (completion === null || completion.status !== 0)\n        return state;", "if (completion === null)\n        return state;"],
    ["a probe that answered logs nothing", "if (completion.status === 0 && (completion.code === 0 || completion.code === TUI_LAUNCHER_MISSING))", "if (completion.status === 0 && completion.code === 0)"],
    ["a probe that never started is logged", "if (completion === null)\n        return \"tui: probe=unstarted\";", "if (false)\n        return \"tui: probe=unstarted\";"],
    ["openTui opens a listed core row only", "if (!hasOwn(core, name) || core[name].entry === null)", "if (!hasOwn(core, name))"],
    ["a core request's arguments are judged", "    if (!tuiArgsValid(args))\n        return tuiRefusal(key, \"args\");\n    var refusal = tuiRunnerRefusal(runner, key, key);", "    var refusal = tuiRunnerRefusal(runner, key, key);"],
    ["a core request's arguments follow its argv", "row.argv.slice(1), args === undefined ? [] : args)", "row.argv.slice(1))"],
    ["a launcher that never started is logged", "if (completion === null)\n        return \"tui: launcher=unstarted", "if (false)\n        return \"tui: launcher=unstarted"],
];

const temp = fs.mkdtempSync(path.join(os.tmpdir(), "tui-logic-control-"));
try {
    for (const [source, relative] of IMPORTS) {
        fs.mkdirSync(path.dirname(path.join(temp, relative)), { recursive: true });
        fs.symlinkSync(source, path.join(temp, relative));
    }
    const source = fs.readFileSync(LOGIC, "utf8");
    for (const [label, needle, replacement, loadRefusal] of CONTROLS) {
        const count = source.split(needle).length - 1;
        if (count !== 1) { report("control: " + label + ": the text to replace occurs once", count, 1); continue; }
        const mutant = path.join(temp, "shell", "Core", "PluginLogic.js");
        fs.writeFileSync(mutant, source.replace(needle, () => replacement));
        // A control whose rule the shipped CORE_TUIS table reaches when the
        // file loads names the refusal coreTuiTable throws; the load is its
        // red.
        if (loadRefusal !== undefined) {
            let thrown = "loaded";
            try { load(mutant); } catch (e) { thrown = e.message; }
            report("control: the shipped table refuses to load without the rule: " + label, thrown, loadRefusal);
            continue;
        }
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
