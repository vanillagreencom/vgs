// The tool bridge's one MCP judge: it accepts or refuses one JSON-RPC line of
// the initialization-era protocol and builds every answer the bridge writes.
// No other file parses MCP. Contract and sources: docs/architecture/jarvis-bridge.md.
"use strict";

// The newest first: an unsupported request is answered with VERSIONS[0].
const VERSIONS = Object.freeze(["2025-11-25", "2025-06-18"]);
// JSON-RPC 2.0 codes, plus one implementation-defined server error for a
// request the lifecycle does not permit yet or any more.
const CODES = Object.freeze({ parse: -32700, request: -32600, method: -32601, params: -32602, lifecycle: -32000 });
const SERVER = Object.freeze({ name: "vgs-jarvis", version: "1" });

/** @typedef {"new"|"initializing"|"ready"} Phase */
/** @typedef {string|number} Id */
/**
 * @typedef {{kind: "reply", message: object}
 *   | {kind: "none"}
 *   | {kind: "list", id: Id}
 *   | {kind: "call", id: Id, name: string, arguments: Record<string, unknown>}} Act
 */

function plain(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value);
}

function validId(id) {
    return typeof id === "string" || Number.isSafeInteger(id);
}

function result(id, value) {
    return { jsonrpc: "2.0", id, result: value };
}

// An id the request did not carry readably is omitted, as the schema allows.
function error(id, code, message) {
    return id === undefined ? { jsonrpc: "2.0", error: { code, message } }
        : { jsonrpc: "2.0", id, error: { code, message } };
}

/**
 * A tool result: one text block, then an image block {data, mimeType} when
 * one is given, or a second text block holding the release marker in its
 * place. A refusal or failed outcome sets isError.
 */
function content(id, text, isError, image = null) {
    const blocks = [{ type: "text", text }];
    if (image !== null) blocks.push(image.kind === "image" ? { type: "image", data: image.data, mimeType: image.mimeType }
        : { type: "text", text: image.text });
    return result(id, { content: blocks, isError });
}

/**
 * Judge one line received in a phase. The bridge keeps the returned phase and
 * performs the act: write a reply, answer a list or route a call. Requests
 * other than ping wait for initialize, and tools wait for its notification.
 * @param {string} line
 * @param {Phase} phase
 * @returns {{phase: Phase, act: Act}}
 */
function accept(line, phase) {
    const reply = message => ({ phase, act: { kind: "reply", message } });
    let message;
    try { message = JSON.parse(line); } catch { return reply(error(undefined, CODES.parse, "Parse error")); }
    if (!plain(message)) return reply(error(undefined, CODES.request, "Invalid Request"));
    const id = validId(message.id) ? message.id : undefined;
    if (message.jsonrpc !== "2.0" || typeof message.method !== "string"
            || (Object.hasOwn(message, "id") && id === undefined))
        return reply(error(id, CODES.request, "Invalid Request"));
    const params = Object.hasOwn(message, "params") ? message.params : {};
    if (id === undefined) {
        // A notification is never answered. Only the end of initialization changes state.
        if (message.method === "notifications/initialized" && phase === "initializing")
            return { phase: "ready", act: { kind: "none" } };
        return { phase, act: { kind: "none" } };
    }
    if (!["ping", "initialize", "tools/list", "tools/call"].includes(message.method))
        return reply(error(id, CODES.method, "Method not found"));
    if (!plain(params)) return reply(error(id, CODES.params, "Invalid params"));
    switch (message.method) {
    case "ping": return reply(result(id, {}));
    case "initialize": {
        if (phase !== "new") return reply(error(id, CODES.lifecycle, "Already initialized"));
        if (typeof params.protocolVersion !== "string" || !plain(params.capabilities) || !plain(params.clientInfo))
            return reply(error(id, CODES.params, "Invalid params"));
        const version = VERSIONS.includes(params.protocolVersion) ? params.protocolVersion : VERSIONS[0];
        return { phase: "initializing", act: { kind: "reply", message: result(id, {
            protocolVersion: version, capabilities: { tools: {} }, serverInfo: SERVER }) } };
    }
    case "tools/list":
        if (phase !== "ready") return reply(error(id, CODES.lifecycle, "Not initialized"));
        return { phase, act: { kind: "list", id } };
    case "tools/call":
        if (phase !== "ready") return reply(error(id, CODES.lifecycle, "Not initialized"));
        if (typeof params.name !== "string" || (params.arguments !== undefined && !plain(params.arguments)))
            return reply(error(id, CODES.params, "Invalid params"));
        return { phase, act: { kind: "call", id, name: params.name, arguments: params.arguments ?? {} } };
    default: throw new Error("jarvis: mcp=method");
    }
}

module.exports = { VERSIONS, CODES, accept, result, error, content };
