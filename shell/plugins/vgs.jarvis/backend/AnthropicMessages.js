// Anthropic Messages encoding and ordered event judge. WireBrain owns release,
// history, keys and cancellation; Sse owns the byte stream.
// Contract and vendor sources: docs/architecture/jarvis-anthropic.md.
"use strict";
const WireBrain = require("./WireBrain.js");
const TOOL_CALLS = 16;
function fail(code) { throw new Error("jarvis: brain=" + code); }
function plain(value) { return value !== null && typeof value === "object" && !Array.isArray(value); }

// Only fields this driver consumes are narrowed. Vendor usage extensions and
// new event types remain unread, as the vendor versioning policy requires.
function eventOf(event) {
    let value;
    try { value = JSON.parse(event.data); } catch { fail("event-json"); }
    if (!plain(value) || typeof value.type !== "string" || value.type !== event.event) fail("event-shape");
    switch (value.type) {
    case "error": return fail("stream-error");
    case "message_start":
        if (!plain(value.message) || value.message.role !== "assistant"
                || !Array.isArray(value.message.content) || value.message.content.length !== 0
                || value.message.stop_reason !== null) fail("event-shape");
        break;
    case "content_block_start": case "content_block_delta": case "content_block_stop":
        if (!Number.isSafeInteger(value.index) || value.index < 0) fail("event-shape");
        if (value.type === "content_block_start" && !plain(value.content_block)) fail("event-shape");
        if (value.type === "content_block_delta" && !plain(value.delta)) fail("event-shape");
        break;
    case "message_delta":
        if (!plain(value.delta) || (value.delta.stop_reason !== undefined && value.delta.stop_reason !== null
                && typeof value.delta.stop_reason !== "string")) fail("event-shape");
        break;
    default: break;
    }
    return value;
}

function outcome(reason, count) {
    switch (reason) {
    case "end_turn": case "stop_sequence":
        if (count !== 0) fail("finish reason=unanswered-tools");
        return "stop";
    case "tool_use":
        if (count === 0) fail("finish reason=tool-use-without-call");
        return "tool-calls";
    case null: return fail("finish-missing");
    default: return fail("finish reason=" + (["max_tokens", "refusal", "pause_turn", "model_context_window_exceeded"].includes(reason)
        ? reason : "unknown"));
    }
}

function reader(names) {
    let phase = "initial";
    let block = null;
    const content = [];
    const calls = [];
    let text = "";
    let reason = null;
    return event => {
        const value = eventOf(event);
        if (["content_block_start", "content_block_delta", "content_block_stop"].includes(value.type)
                && value.index !== content.length) fail("block-index");
        switch (value.type) {
        case "message_start":
            if (phase !== "initial") fail("event-order");
            phase = "blocks";
            break;
        case "content_block_start": {
            if (phase !== "blocks" || block !== null) fail("event-order");
            const start = value.content_block;
            switch (start.type) {
            case "text":
                if (typeof start.text !== "string") fail("block-shape");
                block = { kind: "text", text: start.text };
                text += start.text;
                if (start.text !== "") return { kind: "text", text: start.text };
                break;
            case "tool_use":
                if (typeof start.id !== "string" || start.id === "" || typeof start.name !== "string" || start.name === ""
                        || !plain(start.input)) fail("block-shape");
                if (calls.length === TOOL_CALLS) fail("tool-call-limit");
                if (calls.some(call => call.id === start.id)) fail("tool-call-id");
                if (!names.has(start.name)) fail("tool-call-name");
                block = { kind: "tool", id: start.id, name: start.name, input: start.input, fragments: "" };
                break;
            default: return fail("block-unsupported");
            }
            break;
        }
        case "content_block_delta":
            if (phase !== "blocks" || block === null) fail("event-order");
            switch (block.kind) {
            case "text":
                if (value.delta.type !== "text_delta" || typeof value.delta.text !== "string") fail("delta-shape");
                block.text += value.delta.text;
                text += value.delta.text;
                if (value.delta.text !== "") return { kind: "text", text: value.delta.text };
                break;
            case "tool":
                if (value.delta.type !== "input_json_delta" || typeof value.delta.partial_json !== "string") fail("delta-shape");
                block.fragments += value.delta.partial_json;
                break;
            default: throw new Error("jarvis: brain=block-state");
            }
            break;
        case "content_block_stop":
            if (phase !== "blocks" || block === null) fail("event-order");
            switch (block.kind) {
            case "text": content.push({ type: "text", text: block.text }); break;
            case "tool": {
                let parsed = block.input;
                if (block.fragments !== "") {
                    // Streaming starts with an empty input; deltas replace it.
                    if (Object.keys(block.input).length !== 0) fail("tool-call-conflict");
                    try { parsed = JSON.parse(block.fragments); } catch { fail("tool-call-arguments"); }
                }
                if (!plain(parsed)) fail("tool-call-arguments");
                calls.push({ id: block.id, name: block.name, tool: names.get(block.name), parsed });
                content.push({ type: "tool_use", id: block.id, name: block.name, input: parsed });
                break;
            }
            default: throw new Error("jarvis: brain=block-state");
            }
            block = null;
            break;
        case "message_delta":
            if (phase === "initial" || block !== null) fail("event-order");
            phase = "ending";
            if (value.delta.stop_reason !== undefined && value.delta.stop_reason !== null) {
                if (reason !== null) fail("event-order");
                reason = value.delta.stop_reason;
            }
            break;
        case "message_stop":
            if (phase !== "ending" || block !== null) fail("event-order");
            return { kind: "complete", text, calls, content, reason: outcome(reason, calls.length) };
        default: break; // Ping and future event types do not change the message.
        }
        return { kind: "continue" };
    };
}
// One image block, or the release marker in its place.
function imageBlock(image) {
    return image.decision.kind === "send"
        ? { type: "image", source: { type: "base64", media_type: image.type, data: image.decision.content.toString("base64") } }
        : { type: "text", text: image.decision.content };
}
const protocol = {
    driver: "anthropic-messages", path: "/messages",
    auth: { header: "x-api-key", prefix: "" }, headers: { "anthropic-version": "2023-06-01" },
    status: { 400: "request-rejected", 401: "unauthorized", 402: "billing", 403: "forbidden", 404: "not-found",
        409: "conflict", 413: "request-too-large", 429: "rate-limited", 500: "provider-error", 504: "timeout", 529: "overloaded" },
    reader,
    tool: (name, tool) => ({ name, description: tool.description, input_schema: structuredClone(tool.parameters) }),
    // A fixed output allowance, not a model-window claim. The session owns
    // context budgeting; a response that reaches this allowance fails.
    request: (model, system, messages) => ({ model, system, messages, max_tokens: 4096, stream: true }),
    user: (texts, images) => ({ role: "user", content: [...texts.map(text => ({ type: "text", text })), ...images.map(imageBlock)] }),
    assistant: entry => ({ role: "assistant", content: entry.content }),
    // A result's image is a block of its own tool_result's content.
    results: results => [{ role: "user", content: results.map(result => ({ type: "tool_result", tool_use_id: result.id,
        content: result.image === null ? result.content : [{ type: "text", text: result.content }, imageBlock(result.image)] })) }]
};
/** Create the Messages implementation of the shared brain contract. */
function create(options) { return WireBrain.create(options, protocol); }
module.exports = { create };
