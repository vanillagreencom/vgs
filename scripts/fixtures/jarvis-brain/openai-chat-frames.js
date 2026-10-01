// Stream frames for OpenAI-compatible loopback servers. Each schema-shaped
// frame is validated against the pinned excerpt before a server sends it:
// openai-chat.schema.json names its source commit and date.
"use strict";
const assert = require("node:assert/strict");
const Check = require("../schema-check.js");
const excerpt = require("./openai-chat.schema.json");

const BASE = { id: "chatcmpl-fixture", object: "chat.completion.chunk", created: 1790000000, model: "fixture-model" };
function pinned(name, value, label) {
    assert.deepEqual(Check.errors(excerpt, name, value), [], label + " matches the pinned " + name);
}
// A frame is a script entry or a raw string that is deliberately outside
// the pinned schema. Schema-shaped frames are validated before they are sent.
function encode(frame, label) {
    if (frame === "[DONE]") return "data: [DONE]\n\n";
    if (typeof frame === "string") return frame;
    if (Object.hasOwn(frame, "error")) {
        pinned("ErrorResponse", frame, label);
        return "data: " + JSON.stringify(frame) + "\n\n";
    }
    const chunk = Object.hasOwn(frame, "usage") ? { ...BASE, choices: [], usage: frame.usage }
        : { ...BASE, choices: [{ index: 0, delta: frame.delta, finish_reason: frame.finish_reason }] };
    pinned("CreateChatCompletionStreamResponse", chunk, label);
    return "data: " + JSON.stringify(chunk) + "\n\n";
}
const delta = (value, finish = null) => ({ delta: value, finish_reason: finish });

module.exports = { BASE, pinned, encode, delta };
