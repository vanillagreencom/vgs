#!/usr/bin/env node
// Reserved tool contracts, not executable tools. Fixtures are synthetic.
"use strict";
const { assert, fs, path, tree, world, seed, mutant } = require("./fixtures/jarvis/policy.js");
const file = path.join(tree, "shell/plugins/vgs.jarvis/backend/Tools.js");
const Tools = require(file);

world(() => {
    const { project } = seed();
    const target = path.join(project, "new");
    const window = "0x123";
    const toolsSource = fs.readFileSync(file, "utf8");
    const cases = [
        ["help", { topic: "files" }, "read"],
        ["windows.list", {}, "read"], ["windows.focus", { window }, "reversible"],
        ["windows.reveal", { window }, "reversible"],
        ["windows.move", { window, x: 0, y: -1 }, "reversible"],
        ["windows.resize", { window, width: 1, height: 100 }, "reversible"],
        ["windows.close", { window }, "persistent"],
        ["windows.fullscreen", { window, mode: "fullscreen", action: "set" }, "reversible"],
        ["windows.float", { window, action: "unset" }, "reversible"],
        ["windows.monitor", { monitor: "DP-1" }, "reversible"],
        ["windows.workspace", { window, workspace: 2 }, "reversible"],
        ["workspaces.list", {}, "read"], ["workspaces.focus", { workspace: 1 }, "reversible"],
        ["workspaces.special", { name: "magic_1-x" }, "reversible"],
        ["apps.list", {}, "read"], ["apps.list", { query: "fire" }, "read"], ["apps.launch", { desktop: "org.example.App.desktop" }, "reversible"],
        ["apps.open", { path: target }, "reversible"],
        ["apps.url", { url: "https://example.test/" }, "reversible"],
        ["input.text", { text: "-literal" }, "input", null, "text"],
        ["input.key", { chord: "SUPER+Y" }, "input", null, "key"],
        ["input.click", { x: -10, y: 0, button: "left" }, "input", null, "pointer"],
        ["input.scroll", { x: 0, y: 0, direction: "down", steps: 1 }, "input", null, "pointer"],
        ["clipboard.read", {}, "read", "clipboard"], ["clipboard.write", { text: "literal" }, "reversible"],
        ["media.play", {}, "reversible"], ["media.pause", {}, "reversible"], ["media.next", {}, "reversible"],
        ["media.volume", { value: 0 }, "reversible"], ["media.mute", { muted: false }, "reversible"],
        ["media.brightness", { value: 1 }, "reversible"],
        ["notify.notification", { title: "title", body: "body" }, "reversible"],
        ["notify.toast", { title: "title", body: "body" }, "reversible"],
        ["files.list", { path: target }, "read"],
        ["files.read", { path: target }, "read", "file"],
        ["files.search", { path: project, query: "word" }, "read", "file"],
        ["files.write", { path: target, text: "" }, "persistent"],
        ["files.move", { from: target, to: target + "-other" }, "persistent"],
        ["files.delete", { path: target }, "destructive"],
        ["shell.argv", { argv: ["echo", "literal"], cwd: project, network: false }, "exec", "command"],
        ["shell.line", { line: "echo literal", cwd: project, network: false }, "exec", "command"],
        ["vision.screen", {}, "read", "screen"], ["vision.monitor", { monitor: "DP-1" }, "read", "screen"],
        ["vision.window", { window }, "read", "screen"],
        ["vision.region", { x: 0, y: 0, width: 1, height: 1 }, "read", "screen"],
        ["task.start", { goal: "synthetic task", cwd: project }, "exec", "agent"],
        ["browser", { command: "open", args: { url: "https://example.test/" } }, "read", "web"],
        ["browser", { command: "read", args: {} }, "read", "web"],
        ["browser", { command: "click", args: { ref: "@e1" } }, "input", "web", "browser"],
        ["browser", { command: "fill", args: { ref: "@e1", text: "literal" } }, "input", "web", "browser"],
        ["browser", { command: "submit", args: { ref: "@e1" } }, "external", "web", "browser"]
    ];
    const check = (logic, [id, args, effect, source = null, input = null]) => {
        const result = logic.refine({ id, args });
        assert.deepEqual([result.kind, result.effect, result.source, result.input],
            ["call", effect, source, input], id);
    };
    for (const row of cases) check(Tools, row);
    check(Tools, ["task.start", { goal: "task", cwd: project, agent: "claude", account: "work" }, "exec", "agent"]);
    assert.doesNotThrow(() => JSON.parse(JSON.stringify(Tools.TABLE)));
    assert.doesNotThrow(() => JSON.parse(JSON.stringify(Tools.BROWSER)));
    // Independent inventory, not a set extracted from the production table.
    assert.deepEqual(Object.keys(Tools.TABLE).sort(), [...new Set(cases.map(row => row[0]))].sort());
    const bad = (logic, call, reason) => {
        let result;
        assert.doesNotThrow(() => { result = logic.refine(call); }, "typed refusals must not throw");
        assert.deepEqual(result, { kind: "refuse", reason });
    };
    const badArgs = [
        ["files.read", { path: "relative" }], ["input.text", { text: "" }],
        ["input.text", { text: "nul\0text" }], ["windows.move", { window, x: 0.5, y: 1 }],
        ["windows.resize", { window, width: 0, height: 1 }],
        ["media.mute", { muted: 0 }], ["input.click", { x: 0, y: 0, button: "unknown" }],
        ["apps.url", { url: "file:///etc/hosts" }], ["apps.url", { url: "https://user:secret@example.test/" }],
        ["apps.launch", { desktop: "sh -c id" }], ["windows.focus", { window: "all" }],
        ["workspaces.focus", { workspace: 0 }], ["workspaces.focus", { workspace: "1" }],
        ["workspaces.focus", { workspace: 2147483648 }], ["windows.workspace", { window, workspace: -1 }],
        ["workspaces.special", { name: "magic space" }], ["workspaces.special", { name: "special:magic" }],
        ["shell.argv", { argv: ["echo", null], cwd: project, network: false }],
        ["shell.argv", { argv: [], cwd: project, network: false }],
        ["files.read", { path: target, effect: "read" }],
        ["files.read", { path: target + "\n" }], ["files.write", { path: target }],
        ["media.volume", { value: 1.01 }], ["media.volume", { value: NaN }],
        ["media.brightness", { value: 0 }], ["media.brightness", { value: 101 }], ["media.brightness", { value: 1.5 }],
        ["browser", { command: "read", args: [] }]
    ];
    for (const [id, args] of badArgs) bad(Tools, { id, args }, "argument-shape");
    bad(Tools, { id: "files.read", args: Object.create({ path: target }) }, "call-shape");
    for (const call of [null, [], { id: "files.read", args: { path: target }, effect: "read" }])
        bad(Tools, call, "call-shape");
    bad(Tools, { id: "sudo", args: {} }, "unknown-tool");
    const browserCalls = [
        ["eval", { script: "literal" }], ["upload", {}], ["download", {}],
        ["state", {}], ["network", {}], ["cookies", {}], ["--profile", {}], ["state load", {}]
    ];
    for (const [command, args] of browserCalls) bad(Tools, { id: "browser", args: { command, args } }, "browser-command");
    for (const args of [{ url: "file:///etc/hosts" }, { url: "https://example.test/", flags: ["--cdp"] }])
        bad(Tools, { id: "browser", args: { command: "open", args } }, "browser-arguments");
    for (const ref of ["--cdp", "--profile", "state load", "@e0", "@e1\n"])
        bad(Tools, { id: "browser", args: { command: "click", args: { ref } } }, "browser-arguments");
    for (const command of ["sudo", "/usr/bin/pkexec", "doas", "/bin/run0", "su", "/usr/bin/su", "sudoedit", "/usr/bin/sudoedit"])
        bad(Tools, { id: "shell.argv", args: { argv: [command, "true"], cwd: project, network: false } }, "privilege-elevation");
    for (const argv of [["pwd"], ["uname", "-s"], ["uname", "-m"]])
        check(Tools, ["shell.argv", { argv, cwd: project, network: false }, "read", "command"]);
    for (const argv of [["pwd", "extra"], ["/usr/bin/pwd"], ["sh", "-c", "pwd"], ["env", "sudo", "true"]])
        check(Tools, ["shell.argv", { argv, cwd: project, network: false }, "exec", "command"]);
    for (const row of [
        ["shell.argv", { argv: ["pwd"], cwd: project, network: true }, "external", "command"],
        ["shell.line", { line: "pwd", cwd: project, network: true }, "external", "command"]
    ]) check(Tools, row);
    const original = { id: "files.write", args: { path: target, text: "old" } };
    const narrowed = Tools.refine(original);
    original.args.text = "changed";
    assert.equal(narrowed.call.args.text, "old");

    // Model-facing names: the one spelling the wire brains and the MCP bridge share.
    const wireRows = [
        ["dots", ["windows.list", "help"], [["windows_list", "windows.list"], ["help", "help"]]],
        ["empty", [], []],
        ["at-bound", ["x".repeat(64)], [["x".repeat(64), "x".repeat(64)]]],
        ["past-bound", ["x".repeat(65)], null],
        ["space", ["bad tool"], null],
        ["shared-name", ["a.b", "a_b"], null]
    ];
    const names = logic => {
        for (const [name, ids, expected] of wireRows) {
            const actual = logic.wireNames(ids);
            assert.deepEqual(actual === null ? null : [...actual], expected, "wire names " + name);
        }
    };
    names(Tools);

    let controls = 0;
    function control(name, needle, replacement, assertion) {
        mutant(file, name, needle, replacement, assertion);
        controls++;
    }
    for (const row of cases) {
        if (row[0] === "browser") {
            const command = row[1].command;
            const needle = `${command}: { effect: "${row[2]}"`;
            control("browser-effect-" + command, needle, `${command}: { effect: "destructive"`, logic => check(logic, row));
        } else {
            const needle = toolsSource.split("\n").find(line => line.trim().startsWith(`"${row[0]}": {`));
            const wrong = row[2] === "read" ? "exec" : "read";
            control("effect-" + row[0], needle, needle.replace(`effect: "${row[2]}"`, `effect: "${wrong}"`),
                logic => check(logic, row));
        }
        if (row[3] != null) {
            const line = toolsSource.split("\n").find(line => row[0] === "browser"
                ? line.trim().startsWith(row[1].command + ": {") : line.trim().startsWith(`"${row[0]}": {`));
            control("source-" + row[0] + "-" + (row[1].command || ""),
                line, line.replace(`source: "${row[3]}"`, 'source: "speech"'), logic => check(logic, row));
        }
        if (row[4] !== undefined) {
            const line = toolsSource.split("\n").find(line => row[0] === "browser"
                ? line.trim().startsWith(row[1].command + ": {") : line.trim().startsWith(`"${row[0]}": {`));
            control("input-route-" + row[0] + "-" + (row[1].command || ""),
                line, line.replace(`input: "${row[4]}"`, "input: null"), logic => check(logic, row));
        }
    }
    const validators = [
        ["string-type", 'if (typeof value !== "string")', 'if (false && typeof value !== "string")', { id: "input.text", args: { text: 1 } }],
        ["text", 'if (rule.minLength !== undefined && value.length < rule.minLength)', 'if (false && rule.minLength !== undefined && value.length < rule.minLength)', { id: "input.text", args: { text: "" } }],
        ["pattern", 'if (rule.pattern !== undefined && !new RegExp(rule.pattern).test(value))', 'if (false && rule.pattern !== undefined && !new RegExp(rule.pattern).test(value))', { id: "files.read", args: { path: "relative" } }],
        ["integer", 'if (rule.type === "integer" && !Number.isSafeInteger(value))', 'if (false && rule.type === "integer" && !Number.isSafeInteger(value))', { id: "windows.move", args: { window, x: 0.5, y: 0 } }],
        ["minimum", 'if (rule.minimum !== undefined && value < rule.minimum)', 'if (false && rule.minimum !== undefined && value < rule.minimum)', { id: "windows.resize", args: { window, width: 0, height: 1 } }],
        ["maximum", 'if (rule.maximum !== undefined && value > rule.maximum)', 'if (false && rule.maximum !== undefined && value > rule.maximum)', { id: "media.volume", args: { value: 2 } }],
        ["number-type", 'if (typeof value !== "number" || !Number.isFinite(value))', 'if (false && (typeof value !== "number" || !Number.isFinite(value)))', { id: "media.volume", args: { value: "1" } }],
        ["boolean", 'case "boolean": return typeof value === "boolean";', 'case "boolean": return true;', { id: "media.mute", args: { muted: 0 } }],
        ["enum", 'if (rule.enum !== undefined && !rule.enum.includes(value))', 'if (false && rule.enum !== undefined && !rule.enum.includes(value))', { id: "input.click", args: { x: 0, y: 0, button: "bad" } }],
        ["argv-elements", 'value.every(item => valid(item, rule.items))', 'true', { id: "shell.argv", args: { argv: ["echo", null], cwd: project, network: false } }],
        ["argv-empty", 'value.length >= rule.minItems', 'true', { id: "shell.argv", args: { argv: [], cwd: project, network: false } }],
        ["array-type", 'Array.isArray(value) && value.length >= rule.minItems', 'value.length >= rule.minItems', { id: "shell.argv", args: { argv: { length: 1 }, cwd: project, network: false } }],
        ["url-secret", 'if (parsed.username !== "" || parsed.password !== "")', 'if (false && (parsed.username !== "" || parsed.password !== ""))', { id: "apps.url", args: { url: "https://u:p@example.test/" } }],
        ["required", 'if (!rule.required.every(key => Object.hasOwn(value, key)))', 'if (false && !rule.required.every(key => Object.hasOwn(value, key)))', { id: "files.write", args: { path: target } }],
        ["closed-object", 'if (rule.additionalProperties === false && Object.keys(value).some(key => !Object.hasOwn(rule.properties, key)))', 'if (false && rule.additionalProperties === false && Object.keys(value).some(key => !Object.hasOwn(rule.properties, key)))', { id: "files.read", args: { path: target, effect: "read" } }]
    ];
    for (const [name, needle, replacement, call] of validators)
        control(name, needle, replacement, logic => bad(logic, call, "argument-shape"));
    const descriptorCases = [
        ["text", { id: "input.text", args: { text: "nul\0text" } }],
        ["absolute", { id: "files.read", args: { path: "relative" } }],
        ["url", { id: "apps.url", args: { url: "file:///etc/hosts" } }],
        ["desktop", { id: "apps.launch", args: { desktop: "sh -c id" } }],
        ["windowId", { id: "windows.focus", args: { window: "all" } }]
    ];
    for (const [name, call] of descriptorCases) {
        const line = toolsSource.split("\n").find(line => line.startsWith("const " + name + " ="));
        // Change the pattern only, retaining the declared type and other bounds.
        const replacement = line.replace(/pattern: "(?:\\.|[^"])*"/, 'pattern: ".*"');
        assert.notEqual(replacement, line);
        control("descriptor-" + name, line, replacement, logic => bad(logic, call, "argument-shape"));
    }
    const referenceLine = toolsSource.split("\n").find(line => line.startsWith("const reference ="));
    control("browser-reference", referenceLine, referenceLine.replace(/pattern: "(?:\\.|[^"])*"/, 'pattern: ".*"'),
        logic => bad(logic, { id: "browser", args: { command: "click", args: { ref: "--cdp" } } }, "browser-arguments"));
    for (const argv of [["pwd"], ["uname", "-s"], ["uname", "-m"]]) {
        const needle = JSON.stringify(argv).replaceAll(",", ", ");
        const row = ["shell.argv", { argv, cwd: project, network: false }, "read", "command"];
        control("readonly-" + argv.join("-"), needle, '["removed"]', logic => check(logic, row));
    }
    control("plain-object", '[Object.prototype, null].includes(Object.getPrototypeOf(value))', 'true',
        logic => bad(logic, { id: "files.read", args: Object.create({ path: target }) }, "call-shape"));
    control("call-shape", 'if (!valid(call, schema({ id: text, args: objectValue })))', 'if (false && !valid(call, schema({ id: text, args: objectValue })))',
        logic => bad(logic, { id: "files.read", args: { path: target }, effect: "read" }, "call-shape"));
    control("argument-shape", 'if (!valid(call.args, row.schema))', 'if (false && !valid(call.args, row.schema))',
        logic => bad(logic, { id: "files.read", args: { path: target, effect: "read" } }, "argument-shape"));
    control("unknown", 'if (row === null) return { kind: "refuse", reason: "unknown-tool" };',
        'if (row === null) return { kind: "call", effect: "read" };',
        logic => bad(logic, { id: "unknown", args: {} }, "unknown-tool"));
    control("browser-command", 'if (sub === null) return { kind: "refuse", reason: "browser-command" };',
        'if (sub === null) return { kind: "call", effect: "read" };',
        logic => bad(logic, { id: "browser", args: { command: "eval", args: {} } }, "browser-command"));
    control("browser-shape", 'if (!valid(call.args.args, sub.schema))', 'if (false && !valid(call.args.args, sub.schema))',
        logic => bad(logic, { id: "browser", args: { command: "read", args: { flags: [] } } }, "browser-arguments"));
    control("elevation", 'if (ELEVATION.has(path.basename(call.args.argv[0])))', 'if (false && ELEVATION.has(path.basename(call.args.argv[0])))',
        logic => bad(logic, { id: "shell.argv", args: { argv: ["sudo", "true"], cwd: project, network: false } }, "privilege-elevation"));
    for (const command of ["su", "sudoedit"]) {
        const line = toolsSource.split("\n").find(line => line.startsWith("const ELEVATION ="));
        control("elevation-" + command, line, line.replace(`"${command}"`, '"removed"'),
            logic => bad(logic, { id: "shell.argv", args: { argv: ["/usr/bin/" + command, "synthetic"], cwd: project, network: false } }, "privilege-elevation"));
    }
    control("readonly-exact", 'JSON.stringify(argv) === JSON.stringify(call.args.argv)', 'argv[0] === call.args.argv[0]',
        logic => check(logic, ["shell.argv", { argv: ["pwd", "extra"], cwd: project, network: false }, "exec", "command"]));
    control("network", 'if (call.args.network) effect = "external";', 'if (false && call.args.network) effect = "external";',
        logic => check(logic, ["shell.argv", { argv: ["pwd"], cwd: project, network: true }, "external", "command"]));
    control("snapshot", 'call: freeze(structuredClone(call))', 'call: call', logic => {
        const call = { id: "files.write", args: { path: target, text: "old" } };
        const result = logic.refine(call);
        call.args.text = "changed";
        assert.equal(result.call.args.text, "old");
    });
    const frozen = logic => {
        const result = logic.refine({ id: "shell.argv", args: { argv: ["pwd"], cwd: project, network: false } });
        assert.equal(Object.isFrozen(result.call), true);
        assert.equal(Object.isFrozen(result.call.args), true);
        assert.equal(Object.isFrozen(result.call.args.argv), true);
    };
    frozen(Tools);
    control("wire-name-pattern", "!WIRE_NAME.test(name) || ", "", names);
    control("wire-name-unique", " || names.has(name)", "", names);
    control("wire-name-bound-low", "{1,64}", "{1,63}", names);
    control("wire-name-bound-high", "{1,64}", "{1,65}", names);
    control("wire-name-spelling", 'id.replaceAll(".", "_")', "id", names);
    control("immutable-call", "call: freeze(structuredClone(call))", "call: structuredClone(call)", frozen);
    console.log("test-jarvis-tools: ok calls=" + cases.length + " controls=" + controls);
});
