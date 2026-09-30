#!/usr/bin/env node
// Synthetic fixtures from the voice class contract in v2-jarvis-plan.md § 5,
// authored 2026-09-30. They have no provider wire or recording.
"use strict";
const { assert, fs, path, backend, world, control } = require("./fixtures/jarvis-voice/assertions.js");
const Guidance = require(path.join(backend, "Guidance.js"));
const fixtures = require("./fixtures/jarvis-voice/guidance.json");
function composed(logic, row, root = backend) {
    const value = logic.compose(row.engine, row.class, row.language);
    assert.deepEqual(value.layers, row.layers);
    assert.equal(value.instructions, row.layers.map(name =>
        fs.readFileSync(path.join(root, "skills/voice", name), "utf8").trim()).join("\n\n"));
    assert.equal(value.afterToolResult, row.repeat ? ["core.md", "class/local.md"].map(name =>
        fs.readFileSync(path.join(root, "skills/voice", name), "utf8").trim()).join("\n\n") : null);
}
assert.equal(fixtures.length, 7, "class/language coverage floor");
assert.deepEqual([...new Set(fixtures.map(row => row.class))].sort(), ["duplex", "local", "text"]);
for (const row of fixtures) composed(Guidance, row);
assert.equal(Guidance.compose("chained", "text", "").instructions, Guidance.compose("chained", "text", "en").instructions);
const invalid = [
    ["other", "text", "en", "engine"], ["chained", "other", "en", "class"],
    ["chained", "duplex", "en", "consumer"], ["chained", "text", "../en", "speech=language"]
];
for (const [engine, brain, language, cause] of invalid)
    assert.throws(() => Guidance.compose(engine, brain, language),
        { message: cause.startsWith("speech") ? "jarvis: " + cause : "jarvis: guidance=" + cause });

let controls = 0;
world("jg", root => {
    const rows = [
        ["voice-layers", '["core-short.md", "speech.md", "turns.md", "class/duplex.md"]',
            '["core.md", "speech.md", "turns.md", "class/duplex.md"]', logic => composed(logic, fixtures[0])],
        ["delegation-layers", '["core.md", "speech.md", "actions.md"]',
            '["core.md", "speech.md", "turns.md"]', logic => composed(logic, fixtures[1])],
        ["frontier-language", 'names.push("lang/" + code + ".md");', 'names.push("lang/en.md");',
            logic => composed(logic, fixtures[4])],
        ["local-layer", 'if (brainClass === "local") names.push("class/local.md");',
            'if (false) names.push("class/local.md");', logic => composed(logic, fixtures[5])],
        ["tool-repeat", 'engine === "chained" && brainClass === "local" ? content[0] + "\\n\\n" + content[4] : null',
            'engine === "chained" && brainClass === "local" ? null : null', logic => composed(logic, fixtures[5])],
        ["engine", 'engine !== "chained" && engine !== "duplex"', 'false',
            logic => assert.throws(() => logic.compose("other", "text", "en"), { message: "jarvis: guidance=engine" })],
        ["class", '!["duplex", "text", "local"].includes(brainClass)', 'false',
            logic => assert.throws(() => logic.compose("chained", "other", "en"), { message: "jarvis: guidance=class" })],
        ["consumer", 'engine === "chained" && brainClass === "duplex"', 'false',
            logic => assert.throws(() => logic.compose("chained", "duplex", "en"), { message: "jarvis: guidance=consumer" })]
    ];
    for (const [name, needle, replacement, check] of rows) {
        control(root, name, "Guidance.js", needle, replacement, check); controls++;
    }
    for (const [name, content, cause] of [
        ["missing", null, "ENOENT"], ["empty", "", "layer-empty"],
        ["oversize", "x".repeat(8193), "layer-too-large"], ["utf8", Buffer.from([255]), "ERR_ENCODING_INVALID_ENCODED_DATA"]
    ]) {
        const copy = path.join(root, name);
        fs.cpSync(backend, copy, { recursive: true });
        const file = path.join(copy, "skills/voice/core.md");
        if (content === null) fs.unlinkSync(file); else fs.writeFileSync(file, content);
        assert.throws(() => require(path.join(copy, "Guidance.js")).compose("chained", "text", "en"),
            { message: "jarvis: guidance=layer file=core.md cause=" + cause });
    }
    // Actual boundary input: all selected files reach their per-layer cap.
    const large = path.join(root, "large");
    fs.cpSync(backend, large, { recursive: true });
    for (const file of fixtures[5].layers) fs.writeFileSync(path.join(large, "skills/voice", file), "x".repeat(8192));
    assert.throws(() => require(path.join(large, "Guidance.js")).compose("chained", "local", "en"),
        { message: "jarvis: guidance=compose-too-large" });
    control(root, "layer-bound", "Guidance.js", 'if (size > MAX_LAYER_BYTES)', 'if (false)', logic => {
        const copy = path.join(root, "layer-bound/skills/voice/core.md");
        fs.writeFileSync(copy, "x".repeat(8193));
        assert.throws(() => logic.compose("duplex", "text", "en"), /layer-too-large/);
    }); controls++;
    control(root, "compose-bound", "Guidance.js", 'Buffer.byteLength(instructions) > MAX_COMPOSE_BYTES', 'false', logic => {
        for (const file of fixtures[5].layers)
            fs.writeFileSync(path.join(root, "compose-bound/skills/voice", file), "x".repeat(8192));
        assert.throws(() => logic.compose("chained", "local", "en"), { message: "jarvis: guidance=compose-too-large" });
    }); controls++;
    for (const [name, needle, replacement, content, cause] of [
        ["empty-bound", 'if (text === "")', 'if (false)', "", "layer-empty"],
        ["utf8-bound", '{ fatal: true }', '{ fatal: false }', Buffer.from([255]), "ERR_ENCODING_INVALID_ENCODED_DATA"]
    ]) {
        control(root, name, "Guidance.js", needle, replacement, logic => {
            fs.writeFileSync(path.join(root, name, "skills/voice/core.md"), content);
            assert.throws(() => logic.compose("chained", "text", "en"),
                { message: "jarvis: guidance=layer file=core.md cause=" + cause });
        }); controls++;
    }
});
console.log("test-jarvis-guidance: ok fixtures=" + fixtures.length + " controls=" + controls);
