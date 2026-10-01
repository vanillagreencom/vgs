#!/usr/bin/env node
// The pinned-schema checker's keyword table, synthetic schemas 2026-09-30,
// and the real OpenAI excerpt it serves. In-process; no network.
"use strict";
const { assert, fs, path, world } = require("./fixtures/jarvis-voice/assertions.js");
const file = path.join(__dirname, "fixtures/schema-check.js");
const Check = require(file);
const excerpt = require("./fixtures/jarvis-brain/openai-chat.schema.json");

const doc = schemas => ({ schemas });
// [name, schemas, root, value, expected errors]. One row per keyword rule.
const rows = [
    ["type-match", { a: { type: "string" } }, "a", "x", []],
    ["type-miss", { a: { type: "string" } }, "a", 1, ["$: type integer not string"]],
    ["type-list", { a: { type: ["string", "null"] } }, "a", null, []],
    ["integer-is-number", { a: { type: "number" } }, "a", 2, []],
    ["number-not-integer", { a: { type: "integer" } }, "a", 2.5, ["$: type number not integer"]],
    ["array-not-object", { a: { type: "object" } }, "a", [], ["$: type array not object"]],
    ["nullable", { a: { type: "boolean", nullable: true } }, "a", null, []],
    ["not-nullable", { a: { type: "boolean" } }, "a", null, ["$: type null not boolean"]],
    ["enum-match", { a: { enum: ["x", null] } }, "a", null, []],
    ["enum-miss", { a: { enum: ["x"] } }, "a", "y", ["$: enum"]],
    ["required", { a: { type: "object", properties: { k: { type: "string" } }, required: ["k"] } }, "a", {}, ["$: required k"]],
    ["property", { a: { type: "object", properties: { k: { type: "string" } } } }, "a", { k: 1 }, ["$.k: type integer not string"]],
    ["closed", { a: { type: "object", properties: { k: { type: "string" } } } }, "a", { k: "x", extra: 1 }, ["$: property extra not pinned"]],
    ["closed-false", { a: { type: "object", additionalProperties: false } }, "a", { extra: 1 }, ["$: property extra not pinned"]],
    ["open", { a: { type: "object", additionalProperties: true } }, "a", { extra: 1 }, []],
    ["additional-schema", { a: { type: "object", additionalProperties: { type: "string" } } }, "a", { extra: 1 },
        ["$.extra: type integer not string"]],
    ["items", { a: { type: "array", items: { type: "string" } } }, "a", ["x", 1], ["$[1]: type integer not string"]],
    ["min-items", { a: { type: "array", minItems: 1 } }, "a", [], ["$: minItems"]],
    ["ref", { a: { $ref: "#/schemas/b" }, b: { type: "string" } }, "a", 1, ["$: type integer not string"]],
    ["one-of-one", { a: { oneOf: [{ type: "string" }, { type: "integer" }] } }, "a", 1, []],
    ["one-of-none", { a: { oneOf: [{ type: "string" }] } }, "a", 1, ["$: oneOf matched 0"]],
    ["one-of-two", { a: { oneOf: [{ type: "number" }, { type: "integer" }] } }, "a", 1, ["$: oneOf matched 2"]],
    ["any-of", { a: { anyOf: [{ type: "number" }, { type: "integer" }] } }, "a", 1, []],
    ["any-of-none", { a: { anyOf: [{ type: "string" }] } }, "a", 1, ["$: anyOf matched 0"]]
];
function table(logic) {
    for (const [name, schemas, root, value, expected] of rows)
        assert.deepEqual(logic.errors(doc(schemas), root, value), expected, name);
}
table(Check);

// An instrument failure is a thrown error, never a list of findings.
for (const [schemas, root, reason] of [
    [{ a: { type: "string", pattern: "x" } }, "a", "keyword=pattern path=$"],
    [{ a: { allOf: [] } }, "a", "keyword=allOf path=$"],
    [{ a: { $ref: "#/components/schemas/b" } }, "a", "ref=#/components/schemas/b"],
    [{ a: { $ref: "#/schemas/missing" } }, "a", "ref=#/schemas/missing"],
    [{ a: { type: "string" } }, "missing", "schema=missing"],
    [{ a: true }, "a", "schema-shape path=$"]
]) assert.throws(() => Check.errors(doc(schemas), root, "x"), { message: "schema-check: " + reason });

// The OpenAI excerpt uses only implemented keywords and keeps the shapes the
// driver emits and the fixtures replay.
const request = { model: "m", stream: true, store: false, messages: [
    { role: "system", content: "guidance" },
    { role: "user", content: [{ type: "text", text: "a" }, { type: "image_url", image_url: { url: "data:image/png;base64,AA==" } }] },
    { role: "assistant", content: null, tool_calls: [{ id: "c", type: "function", function: { name: "n", arguments: "{}" } }] },
    { role: "tool", tool_call_id: "c", content: "r" }],
tools: [{ type: "function", function: { name: "n", description: "d", parameters: { type: "object", properties: {} } } }] };
assert.deepEqual(Check.errors(excerpt, "CreateChatCompletionRequest", request), []);
assert.deepEqual(Check.errors(excerpt, "CreateChatCompletionRequest", { ...request, stream_option: {} }),
    ["$: property stream_option not pinned"], "a misspelt field fails");
assert.deepEqual(Check.errors(excerpt, "CreateChatCompletionRequest", { ...request, messages: [{ role: "developer", content: "x" }] }),
    ["$.messages[0]: oneOf matched 0"], "an omitted message kind fails");
const chunk = { id: "x", object: "chat.completion.chunk", created: 1, model: "m",
    choices: [{ index: 0, delta: { tool_calls: [{ index: 0, function: { arguments: "{" } }] }, finish_reason: null }] };
assert.deepEqual(Check.errors(excerpt, "CreateChatCompletionStreamResponse", chunk), []);
assert.deepEqual(Check.errors(excerpt, "CreateChatCompletionStreamResponse", { ...chunk, choices: [{ index: 0, delta: {} }] }),
    ["$.choices[0]: required finish_reason"]);
assert.deepEqual(Check.errors(excerpt, "ErrorResponse", { error: { message: "m", type: "t", param: null, code: null } }), []);

let controls = 0;
world("schema-check", root => {
    const mutants = [
        ["type", "if (!allowed.includes(actual)", "if (false"],
        ["integer-number", ' && !(actual === "integer" && allowed.includes("number"))', ""],
        ["nullable", 'if (schema.nullable === true) allowed.push("null");', ""],
        ["enum", "!schema.enum.some(option => same(option, current))", "false"],
        ["required", "if (!Object.hasOwn(current, key)) found.push", "if (false) found.push"],
        ["properties", 'if (Object.hasOwn(properties, key)) check(properties[key], item, where + "." + key);',
            "if (Object.hasOwn(properties, key)) continue;"],
        ["closed", 'else found.push(where + ": property " + key + " not pinned");', ""],
        ["additional-true", "else if (schema.additionalProperties === true) continue;", ""],
        ["additional-schema", 'else if (typeof schema.additionalProperties === "object") check(', 'else if (false) check('],
        ["items", 'current.forEach((item, index) => check(schema.items, item, where + "[" + index + "]"));', ";"],
        ["min-items", "current.length < schema.minItems", "false"],
        ["ref", "check(excerpt.schemas[match[1]], current, where);", ""],
        ["one-of", 'keyword === "oneOf" ? matches !== 1 : matches === 0', "matches === 0"],
        ["any-of", 'keyword === "oneOf" ? matches !== 1 : matches === 0', 'keyword === "oneOf" ? matches !== 1 : false'],
        ["member-reset", "found.length = mark;", ""],
        ["array-type", 'if (Array.isArray(value)) return "array";', ""],
        ["integer-type", 'Number.isInteger(value) ? "integer" : "number"', '"number"'],
        ["unknown-keyword", '"minItems", "oneOf", "anyOf"]', '"minItems", "oneOf", "anyOf", "pattern"]',
            logic => assert.throws(() => logic.errors(doc({ a: { pattern: "x" } }), "a", "x"),
                { message: "schema-check: keyword=pattern path=$" })]
    ];
    const source = fs.readFileSync(file, "utf8");
    for (const [name, needle, replacement, check = table] of mutants) {
        assert.equal(source.split(needle).length - 1, 1, name + " mutation match");
        const changed = source.replace(needle, replacement);
        assert.notEqual(changed, source);
        const copy = path.join(root, name + ".js");
        fs.writeFileSync(copy, changed);
        assert.throws(() => check(require(copy)), assert.AssertionError, name + " must turn red");
        controls++;
    }
});
console.log("test-schema-check: ok rows=" + rows.length + " controls=" + controls);
