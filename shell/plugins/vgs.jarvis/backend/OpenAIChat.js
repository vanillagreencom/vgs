// OpenAI-compatible encoding and stream judge. WireBrain owns the conversation.
// Contract: docs/architecture/jarvis-brain.md.
"use strict";
const WireBrain = require("./WireBrain.js");
const AUTH = Object.freeze({ header: "authorization", prefix: "Bearer " });
const TOOL_CALLS = 16;
const STATUS = Object.freeze({ 400: "request-rejected", 401: "unauthorized", 403: "forbidden",
    404: "not-found", 429: "rate-limited", 500: "provider-error", 503: "unavailable" });
function fail(code) { throw new Error("jarvis: brain=" + code); }
function plain(value) { return value !== null && typeof value === "object" && !Array.isArray(value); }
function optionalString(value) { return value === undefined || typeof value === "string"; }

function chunkOf(data) {
    let value;
    try { value = JSON.parse(data); } catch { fail("chunk-json"); }
    if (!plain(value)) fail("chunk-shape");
    if (Object.hasOwn(value, "error")) fail("stream-error");
    if (!Array.isArray(value.choices) || value.choices.length > 1) fail("chunk-shape");
    if (value.choices.length === 0) return null;
    const choice = value.choices[0];
    if (!plain(choice) || choice.index !== 0 || !plain(choice.delta)) fail("chunk-shape");
    const { content, refusal, tool_calls: fragments } = choice.delta;
    const finish = choice.finish_reason;
    if ((content !== null && !optionalString(content)) || (refusal !== null && !optionalString(refusal))
            || (finish !== null && !optionalString(finish))) fail("chunk-shape");
    if (fragments !== undefined && (!Array.isArray(fragments) || !fragments.every(fragment => plain(fragment)
            && Number.isSafeInteger(fragment.index) && fragment.index >= 0 && optionalString(fragment.id)
            && (fragment.type === undefined || fragment.type === "function")
            && (fragment.function === undefined || (plain(fragment.function)
                && optionalString(fragment.function.name) && optionalString(fragment.function.arguments))))))
        fail("chunk-shape");
    if (typeof refusal === "string" && refusal !== "") fail("refusal");
    return { text: content ?? "", fragments: fragments ?? [], finish: finish ?? null };
}
function assembler(names) {
    const calls = [];
    function add(fragment) {
        const name = fragment.function?.name;
        const piece = fragment.function?.arguments ?? "";
        if (fragment.index > calls.length) fail("tool-call-index");
        if (fragment.index === calls.length) {
            if (calls.length === TOOL_CALLS) fail("tool-call-limit");
            if (typeof fragment.id !== "string" || fragment.id === "" || typeof name !== "string" || name === "")
                fail("tool-call-start");
            calls.push({ id: fragment.id, name, arguments: piece });
            return;
        }
        const call = calls[fragment.index];
        if ((fragment.id !== undefined && fragment.id !== call.id) || (name !== undefined && name !== call.name))
            fail("tool-call-conflict");
        call.arguments += piece;
    }
    function complete() {
        if (new Set(calls.map(call => call.id)).size !== calls.length) fail("tool-call-id");
        return calls.map(call => {
            if (!names.has(call.name)) fail("tool-call-name");
            let parsed;
            try { parsed = JSON.parse(call.arguments); } catch { fail("tool-call-arguments"); }
            if (!plain(parsed)) fail("tool-call-arguments");
            return Object.freeze({ ...call, tool: names.get(call.name), parsed });
        });
    }
    return { add, complete, get count() { return calls.length; } };
}
function outcome(finish, count) {
    switch (finish) {
    // Gemini ends tool-call turns with stop.
    case "stop": return count === 0 ? "stop" : "tool-calls";
    case "tool_calls":
        if (count === 0) fail("finish reason=tool-calls-without-call");
        return "tool-calls";
    case "length": return fail("finish reason=length");
    case "content_filter": return fail("finish reason=content-filter");
    case "function_call": return fail("finish reason=function-call");
    case null: return fail("finish-missing");
    default: return fail("chunk-shape");
    }
}
function reader(names) {
    const calls = assembler(names);
    let text = "";
    let finish = null;
    return event => {
        if (event.event !== "message") fail("chunk-shape");
        if (event.data === "[DONE]") {
            const reason = outcome(finish, calls.count);
            return { kind: "complete", text, calls: calls.complete(), reason };
        }
        const chunk = chunkOf(event.data);
        if (chunk === null) return { kind: "continue" };
        if (finish !== null) fail("chunk-order");
        for (const fragment of chunk.fragments) calls.add(fragment);
        text += chunk.text;
        finish = chunk.finish;
        return chunk.text === "" ? { kind: "continue" } : { kind: "text", text: chunk.text };
    };
}
const protocol = {
    driver: "openai-chat", path: "/chat/completions", auth: AUTH, headers: {}, status: STATUS, reader,
    tool: (name, tool) => ({ type: "function",
        function: { name, description: tool.description, parameters: structuredClone(tool.parameters) } }),
    request: (model, instructions, messages) =>
        ({ model, messages: [{ role: "system", content: instructions }, ...messages], stream: true }),
    user(texts, images) {
        return { role: "user", content: images.length === 0 ? texts.join("\n\n") : [
            ...texts.map(text => ({ type: "text", text })),
            ...images.map(image => image.decision.kind === "send"
                ? { type: "image_url", image_url: { url: "data:" + image.type + ";base64," + image.decision.content.toString("base64") } }
                : { type: "text", text: image.decision.content })] };
    },
    assistant(entry) {
        const message = { role: "assistant", content: entry.text === "" ? null : entry.text };
        if (entry.calls.length !== 0) message.tool_calls = entry.calls.map(call =>
            ({ id: call.id, type: "function", function: { name: call.name, arguments: call.arguments } }));
        return message;
    },
    results: results => results.map(result => ({ role: "tool", tool_call_id: result.id, content: result.content }))
};
/** Create the OpenAI-compatible implementation of the shared brain contract. */
function create(options) { return WireBrain.create(options, protocol); }
module.exports = { create };
