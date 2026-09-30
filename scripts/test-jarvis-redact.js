#!/usr/bin/env node
// Synthetic planted credentials, binary payloads and private text. No wire.
"use strict";
const { assert, path, tree, world, mutant } = require("./fixtures/jarvis/policy.js");
const file = path.join(tree, "shell/plugins/vgs.jarvis/backend/Redact.js");
const Redact = require(file);

world(() => {
    const planted = [
        "sk-proj-synthetic-private-credential", "github_pat_synthetic-private-credential",
        "Bearer synthetic-password", "https://name:password@example.test/?token=private",
        "PRIVATE IMAGE CONTENT", "PRIVATE AUDIO CONTENT", "arbitrary unrecognized key",
        123456
    ];
    const cases = [
        ["action", "files.write", ["path", "text"]],
        ["action", "shell.argv", ["argv", "cwd", "network"]],
        ["action", "browser", ["command", "args"]],
        ["action", "task.start", ["goal", "cwd", "agent", "account"]],
        ["release", "release", ["labels", "recipients"]]
    ];
    function check(logic, kind, tool, fields) {
        const args = Object.fromEntries(fields.map(field => [field, planted]));
        args["secret-property-synthetic"] = { nested: Buffer.from("binary credential") };
        const output = logic.argumentsFor(kind, tool, args);
        assert.deepEqual(output, Object.fromEntries(fields.map(field => [field, "[redacted]"])));
        const encoded = JSON.stringify(output);
        for (const secret of planted) assert.equal(encoded.includes(String(secret)), false, "planted value absent");
        assert.equal(encoded.includes("secret-property-synthetic"), false, "unknown field absent");
    }
    for (const row of cases) check(Redact, ...row);
    for (const value of [null, undefined, [], "private text"])
        assert.equal(Redact.argumentsFor("action", "files.write", value), "[redacted]");
    assert.deepEqual(Redact.argumentsFor("action", "unknown-private-tool", { password: "private" }), {});
    assert.deepEqual(Redact.argumentsFor("action", "files.write", {}), {});
    const cycle = {}; cycle.text = cycle;
    assert.deepEqual(Redact.argumentsFor("action", "files.write", cycle), { text: "[redacted]" });
    const args = { path: "/private", text: "z".repeat(1024 * 1024) };
    Object.defineProperty(args, "text", { get() { throw new Error("argument contents opened"); } });
    assert.deepEqual(Redact.argumentsFor("action", "files.write", args), { path: "[redacted]", text: "[redacted]" });
    mutant(file, "argument values", 'result[field] = "[redacted]";', "result[field] = args[field];",
        logic => check(logic, ...cases[0]));
    mutant(file, "unknown property names", "const result = {};", "const result = { ...args };",
        logic => check(logic, ...cases[0]));
    console.log("jarvis-redact: planted-keys=absent controls=values,unknown-fields");
});
