#!/usr/bin/env node
// The bridge's MCP judge against a table of lines. Message shapes follow MCP
// 2025-11-25 (modelcontextprotocol/modelcontextprotocol schema/2025-11-25,
// fetched 2026-10-01); every line and reply is checked against the pinned
// excerpt in fixtures/jarvis-bridge/mcp.schema.json. Mutants run in J09.
"use strict";
const { assert, path, tree, world, mutant } = require("./fixtures/jarvis/policy.js");
const Check = require("./fixtures/schema-check.js");
const excerpt = require("./fixtures/jarvis-bridge/mcp.schema.json");
const file = path.join(tree, "shell/plugins/vgs.jarvis/backend/Mcp.js");

world(() => {
    const Mcp = require(file);
    const client = { name: "fixture-harness", version: "0" };
    const init = (id, protocolVersion) => ({ jsonrpc: "2.0", id, method: "initialize",
        params: { protocolVersion, capabilities: {}, clientInfo: client } });
    const server = version => ({ protocolVersion: version, capabilities: { tools: {} },
        serverInfo: { name: "vgs-jarvis", version: "1" } });
    const failure = (id, code, message) => ({ kind: "reply", message: id === undefined
        ? { jsonrpc: "2.0", error: { code, message } } : { jsonrpc: "2.0", id, error: { code, message } } });
    const success = (id, result) => ({ kind: "reply", message: { jsonrpc: "2.0", id, result } });
    // [name, phase, line, schema of the line or null, expected phase, expected act, schema of the result]
    const rows = [
        ["initialize-current", "new", init(1, "2025-11-25"), "InitializeRequest", "initializing", success(1, server("2025-11-25")), "InitializeResult"],
        ["initialize-previous", "new", init(1, "2025-06-18"), "InitializeRequest", "initializing", success(1, server("2025-06-18")), "InitializeResult"],
        ["initialize-unsupported", "new", init(1, "1900-01-01"), "InitializeRequest", "initializing", success(1, server("2025-11-25")), "InitializeResult"],
        ["initialize-twice", "initializing", init(2, "2025-11-25"), "InitializeRequest", "initializing", failure(2, -32000, "Already initialized")],
        ["initialize-shape", "new", { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-11-25" } }, null, "new", failure(1, -32602, "Invalid params")],
        ["initialized", "initializing", { jsonrpc: "2.0", method: "notifications/initialized" }, "InitializedNotification", "ready", { kind: "none" }],
        ["initialized-early", "new", { jsonrpc: "2.0", method: "notifications/initialized" }, "InitializedNotification", "new", { kind: "none" }],
        ["unknown-notification", "ready", { jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: 3 } }, null, "ready", { kind: "none" }],
        ["ping-new", "new", { jsonrpc: "2.0", id: "p", method: "ping" }, "PingRequest", "new", success("p", {}), "EmptyResult"],
        ["list-before-ready", "initializing", { jsonrpc: "2.0", id: 3, method: "tools/list" }, "ListToolsRequest", "initializing", failure(3, -32000, "Not initialized")],
        ["list", "ready", { jsonrpc: "2.0", id: 3, method: "tools/list", params: { cursor: "ignored" } }, "ListToolsRequest", "ready", { kind: "list", id: 3 }],
        ["call", "ready", { jsonrpc: "2.0", id: "c", method: "tools/call", params: { name: "windows_list", arguments: { a: 1 } } }, "CallToolRequest", "ready",
            { kind: "call", id: "c", name: "windows_list", arguments: { a: 1 } }],
        ["call-no-arguments", "ready", { jsonrpc: "2.0", id: 4, method: "tools/call", params: { name: "help" } }, "CallToolRequest", "ready",
            { kind: "call", id: 4, name: "help", arguments: {} }],
        ["call-before-ready", "new", { jsonrpc: "2.0", id: 4, method: "tools/call", params: { name: "help" } }, "CallToolRequest", "new", failure(4, -32000, "Not initialized")],
        ["call-name", "ready", { jsonrpc: "2.0", id: 4, method: "tools/call", params: { arguments: {} } }, null, "ready", failure(4, -32602, "Invalid params")],
        ["call-arguments", "ready", { jsonrpc: "2.0", id: 4, method: "tools/call", params: { name: "help", arguments: [] } }, null, "ready", failure(4, -32602, "Invalid params")],
        ["params-shape", "ready", { jsonrpc: "2.0", id: 5, method: "ping", params: [] }, null, "ready", failure(5, -32602, "Invalid params")],
        // The 2026-07-28 probe: a legacy answer makes a modern client fall back to initialize.
        ["unknown-method", "new", { jsonrpc: "2.0", id: 6, method: "server/discover", params: {} }, null, "new", failure(6, -32601, "Method not found")],
        ["parse", "ready", "{", null, "ready", failure(undefined, -32700, "Parse error")],
        ["batch", "ready", [{ jsonrpc: "2.0", id: 7, method: "ping" }], null, "ready", failure(undefined, -32600, "Invalid Request")],
        ["null", "ready", "null", null, "ready", failure(undefined, -32600, "Invalid Request")],
        ["version", "ready", { jsonrpc: "1.0", id: 7, method: "ping" }, null, "ready", failure(7, -32600, "Invalid Request")],
        ["null-id", "ready", { jsonrpc: "2.0", id: null, method: "ping" }, null, "ready", failure(undefined, -32600, "Invalid Request")],
        ["fraction-id", "ready", { jsonrpc: "2.0", id: 1.5, method: "ping" }, null, "ready", failure(undefined, -32600, "Invalid Request")]
    ];
    function table(logic) {
        for (const [name, phase, line, lineSchema, nextPhase, act, resultSchema] of rows) {
            if (lineSchema !== null) assert.deepEqual(Check.errors(excerpt, lineSchema, line), [], name + " fixture matches the pinned schema");
            let verdict;
            // A judge that throws on a line it should answer fails this row.
            try { verdict = logic.accept(typeof line === "string" ? line : JSON.stringify(line), phase); }
            catch (error) { assert.fail(name + " threw " + error.message); }
            assert.deepEqual(verdict, { phase: nextPhase, act }, name);
            if (act.kind !== "reply") continue;
            const schema = Object.hasOwn(act.message, "error") ? "JSONRPCErrorResponse" : "JSONRPCResultResponse";
            assert.deepEqual(Check.errors(excerpt, schema, act.message), [], name + " reply envelope");
            if (resultSchema !== undefined)
                assert.deepEqual(Check.errors(excerpt, resultSchema, act.message.result), [], name + " result");
        }
    }
    table(Mcp);
    for (const [name, isError] of [["completed", false], ["refused", true]]) {
        const message = Mcp.content(9, "text", isError);
        assert.deepEqual(message, { jsonrpc: "2.0", id: 9, result: { content: [{ type: "text", text: "text" }], isError } }, name);
        assert.deepEqual(Check.errors(excerpt, "CallToolResult", message.result), [], name + " tool result");
    }

    let controls = 0;
    for (const [name, needle, replacement] of [
        ["negotiation", "VERSIONS.includes(params.protocolVersion) ? params.protocolVersion : VERSIONS[0]", "params.protocolVersion"],
        ["initialize-once", 'if (phase !== "new") return reply(error(id, CODES.lifecycle, "Already initialized"));', ""],
        ["initialize-params", '!plain(params.capabilities) || !plain(params.clientInfo)', "false"],
        ["initialized-phase", 'message.method === "notifications/initialized" && phase === "initializing"', 'message.method === "notifications/initialized"'],
        ["list-ready", 'if (phase !== "ready") return reply(error(id, CODES.lifecycle, "Not initialized"));\n        return { phase, act: { kind: "list", id } };',
            'return { phase, act: { kind: "list", id } };'],
        ["call-ready", 'if (phase !== "ready") return reply(error(id, CODES.lifecycle, "Not initialized"));\n        if (typeof params.name', 'if (typeof params.name'],
        ["call-name", 'typeof params.name !== "string" || ', ""],
        ["call-arguments", "(params.arguments !== undefined && !plain(params.arguments))", "false"],
        ["params-object", 'if (!plain(params)) return reply(error(id, CODES.params, "Invalid params"));', ""],
        ["unknown-method", '!["ping", "initialize", "tools/list", "tools/call"].includes(message.method)', "false"],
        ["parse-code", 'return reply(error(undefined, CODES.parse, "Parse error"));', 'return reply(error(undefined, CODES.request, "Invalid Request"));'],
        ["message-object", "if (!plain(message)) return", "if (false) return"],
        ["jsonrpc", 'message.jsonrpc !== "2.0" || ', ""],
        ["request-id", '(Object.hasOwn(message, "id") && id === undefined)', "false"],
        ["integer-id", "Number.isSafeInteger(id)", 'typeof id === "number"']
    ]) {
        mutant(file, name, needle, replacement, table);
        controls++;
    }
    console.log("test-jarvis-mcp: ok rows=" + rows.length + " controls=" + controls);
});
