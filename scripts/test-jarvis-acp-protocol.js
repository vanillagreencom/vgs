#!/usr/bin/env node
// The ACP harness's protocol judge. Every message it builds is checked
// against the excerpt of the ACP v1 schema (fixtures/jarvis-acp/acp.schema.json);
// the handshake it narrows comes from the sanitized Copilot 1.0.91 recording
// in fixtures/jarvis-acp/recorded.ndjson, made 2026-10-02 in a loopback-only
// namespace with no account; the other agent lines are synthetic rows, each
// checked against the excerpt first. Mutants run in J09.
"use strict";
const { assert, fs, path, tree, world, mutant } = require("./fixtures/jarvis/policy.js");
const Check = require("./fixtures/schema-check.js");
const excerpt = require("./fixtures/jarvis-acp/acp.schema.json");
const file = path.join(tree, "shell/plugins/vgs.jarvis/backend/AcpClient.js");
const recorded = fs.readFileSync(path.join(tree, "scripts/fixtures/jarvis-acp/recorded.ndjson"), "utf8")
    .trim().split("\n").map(line => JSON.parse(line));
const PARAMS = { "initialize": "InitializeRequest", "session/new": "NewSessionRequest", "session/prompt": "PromptRequest",
    "session/cancel": "CancelNotification" };
const COPILOT = { agent: "Copilot", floor: "1.0.60" };

function valid(name, value, label) { assert.deepEqual(Check.errors(excerpt, name, value), [], label + " matches " + name); }
function refused(fn, code, label) { assert.throws(fn, { message: "jarvis: brain=acp-" + code }, label); }
function line(value) { return JSON.stringify({ jsonrpc: "2.0", ...value }); }

world(() => {
    const Acp = require(file);
    const bridge = { command: "/usr/bin/node", args: ["/plugin/backend/mcp-shim"],
        env: { VGS_JARVIS_TOOLS_SOCKET: "/run/vgs/jarvis/tools.sock", VGS_JARVIS_TOOLS_TOKEN: "f".repeat(64) } };
    const cwd = "/run/vgs/jarvis/acp-cwd";

    function builders(logic) {
        const init = logic.initialize(1);
        valid("JSONRPCRequest", init, "initialize");
        valid(PARAMS.initialize, init.params, "initialize");
        assert.deepEqual(init.params, { protocolVersion: 1, clientCapabilities: { fs: { readTextFile: false, writeTextFile: false },
            terminal: false }, clientInfo: { name: "vgs-jarvis", title: "VGS Jarvis", version: "1" } });
        const open = logic.sessionNew(2, { cwd, bridge });
        valid("JSONRPCRequest", open, "session/new");
        valid(PARAMS["session/new"], open.params, "session/new");
        assert.deepEqual(open.params, { cwd, mcpServers: [{ name: "vgs_jarvis", command: bridge.command, args: bridge.args,
            env: [{ name: "VGS_JARVIS_TOOLS_SOCKET", value: bridge.env.VGS_JARVIS_TOOLS_SOCKET },
                { name: "VGS_JARVIS_TOOLS_TOKEN", value: bridge.env.VGS_JARVIS_TOOLS_TOKEN }] }] });
        const bare = logic.sessionNew(3, { cwd, bridge: null });
        valid(PARAMS["session/new"], bare.params, "session/new without tools");
        assert.deepEqual(bare.params.mcpServers, [], "a probe session has no MCP server");
        const prompt = logic.prompt(4, "s", ["Be brief.", "hello"]);
        valid("JSONRPCRequest", prompt, "session/prompt");
        valid(PARAMS["session/prompt"], prompt.params, "session/prompt");
        assert.deepEqual(prompt.params, { sessionId: "s", prompt: [{ type: "text", text: "Be brief." }, { type: "text", text: "hello" }] });
        const cancel = logic.cancel("s");
        valid("JSONRPCNotification", cancel, "session/cancel");
        valid(PARAMS["session/cancel"], cancel.params, "session/cancel");
        assert.deepEqual(cancel, { jsonrpc: "2.0", method: "session/cancel", params: { sessionId: "s" } });
    }

    const permission = { kind: "permission", sessionId: "s", call: null, allow: "a1", reject: "r1" };
    function answers(logic) {
        for (const [choice, outcome] of [["allow", { outcome: "selected", optionId: "a1" }],
            ["reject", { outcome: "selected", optionId: "r1" }], ["cancelled", { outcome: "cancelled" }]]) {
            const reply = logic.answer(7, permission, choice);
            valid("JSONRPCResponse", reply, choice);
            valid("RequestPermissionResponse", reply.result, choice);
            assert.deepEqual(reply.result, { outcome }, choice);
        }
        assert.deepEqual(logic.answer(7, { ...permission, reject: null }, "reject").result, { outcome: { outcome: "cancelled" } },
            "no one-time reject option answers cancelled");
        refused(() => logic.answer(7, permission, "always"), "answer", "an unknown choice");
        const error = logic.answer(8, { kind: "unsupported", method: "fs/read_text_file" }, "cancelled");
        valid("JSONRPCError", error, "unsupported");
        assert.deepEqual(error, { jsonrpc: "2.0", id: 8, error: { code: -32601, message: "Method not found" } });
    }

    // The recording: Jarvis's own lines match its builders, and the agent's
    // validate and narrow to the expected value.
    function replay(logic) {
        for (const { direction, line: message } of recorded) {
            if (direction === "in") {
                valid("JSONRPCRequest", message, "recorded request");
                valid(PARAMS[message.method], message.params, message.method);
            } else valid(message.error ? "JSONRPCError" : "JSONRPCResponse", message, "recorded answer");
        }
        assert.deepEqual(recorded[0].line, logic.initialize(1), "the recorded initialize is the built one");
        const init = recorded.find(entry => entry.direction === "out" && entry.line.id === 1).line;
        valid("InitializeResponse", init.result, "recorded initialize");
        assert.deepEqual(logic.accept(JSON.stringify(init)), { kind: "response", id: 1, result: init.result });
        assert.doesNotThrow(() => logic.agent(init.result, COPILOT), "the recorded agent passes");
        assert.equal(logic.agent(init.result, COPILOT), "1.0.91");
        const signedOut = recorded.find(entry => entry.direction === "out" && entry.line.id === 2).line;
        assert.deepEqual(logic.accept(JSON.stringify(signedOut)), { kind: "failure", id: 2, code: -32000 });
    }

    const init = recorded.find(entry => entry.direction === "out" && entry.line.id === 1).line.result;
    const update = value => line({ method: "session/update", params: { sessionId: "s", update: value } });
    function narrowing(logic) {
        for (const [label, version, ok] of [["floor", "1.0.60", true], ["newer", "1.0.91", true], ["minor", "1.1.0", true],
            ["prerelease", "1.0.92-3", true], ["below", "1.0.59", false], ["older major", "0.9.99", false]]) {
            const result = { ...init, agentInfo: { ...init.agentInfo, version } };
            valid("InitializeResponse", result, label);
            if (ok) assert.doesNotThrow(() => logic.agent(result, COPILOT), label);
            else refused(() => logic.agent(result, COPILOT), "agent-version", label);
        }
        refused(() => logic.agent({ ...init, agentInfo: { ...init.agentInfo, name: "Other" } }, COPILOT), "agent", "another agent");
        refused(() => logic.agent({ ...init, agentInfo: null }, COPILOT), "agent", "no agent info");
        refused(() => logic.agent({ ...init, protocolVersion: 2 }, COPILOT), "protocol", "another protocol version");
        refused(() => logic.agent({ ...init, agentInfo: { ...init.agentInfo, version: "1.0" } }, COPILOT), "agent-version", "unreadable");
        assert.equal(logic.sessionId({ sessionId: "abc" }), "abc");
        refused(() => logic.sessionId({ sessionId: "" }), "session", "an empty session id");
        for (const stop of ["end_turn", "max_tokens", "max_turn_requests", "refusal", "cancelled"]) {
            valid("PromptResponse", { stopReason: stop }, stop);
            assert.equal(logic.stopReason({ stopReason: stop }), stop);
        }
        refused(() => logic.stopReason({ stopReason: "done" }), "stop-reason", "an unknown stop reason");

        const rows = [
            [{ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Hi." } }, { kind: "text", sessionId: "s", text: "Hi." }],
            [{ sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "hm" } }, { kind: "other", sessionId: "s", update: "agent_thought_chunk" }],
            [{ sessionUpdate: "available_commands_update", availableCommands: [] }, { kind: "other", sessionId: "s", update: "available_commands_update" }],
            [{ sessionUpdate: "tool_call", toolCallId: "t1", title: "Edit", kind: "edit", status: "pending",
                locations: [{ path: "/h/a" }], content: [{ type: "diff", path: "/h/a", oldText: "x", newText: "y" }], rawInput: { file: "/h/a" } },
            { kind: "tool-call", sessionId: "s", call: { id: "t1", title: "Edit", kind: "edit", status: "pending", locations: ["/h/a"],
                diffs: [{ path: "/h/a", newText: "y" }], rawInput: { file: "/h/a" } } }],
            [{ sessionUpdate: "tool_call_update", toolCallId: "t1", status: "completed" },
                { kind: "tool-update", sessionId: "s", call: { id: "t1", title: null, kind: null, status: "completed", locations: [],
                    diffs: [], rawInput: null } }]];
        for (const [value, expected] of rows) {
            valid("SessionNotification", { sessionId: "s", update: value }, value.sessionUpdate);
            assert.deepEqual(logic.accept(update(value)), { kind: "notification", event: expected }, value.sessionUpdate);
        }
        const image = update({ sessionUpdate: "agent_message_chunk", content: { type: "image", data: "", mimeType: "image/png" } });
        assert.doesNotThrow(() => logic.accept(image), "a non-text reply block is narrowed");
        assert.deepEqual(logic.accept(image).event,
            { kind: "content", sessionId: "s", type: "image" }, "a non-text reply block is named, not spoken");
        refused(() => logic.accept(update({ sessionUpdate: "tool_call", toolCallId: "t", title: "x", kind: "teleport" })), "tool-kind", "kind");
        refused(() => logic.accept(update({ sessionUpdate: "tool_call", toolCallId: "t", title: "x", status: "done" })), "tool-status", "status");
        refused(() => logic.accept(update({ sessionUpdate: "tool_call", toolCallId: "t" })), "tool-call", "a new call names its title");
        refused(() => logic.accept(update({ sessionUpdate: "tool_call", toolCallId: "", title: "x" })), "tool-call", "an empty id");

        const request = { jsonrpc: "2.0", id: 5, method: "session/request_permission", params: { sessionId: "s",
            toolCall: { toolCallId: "t1", kind: "execute", rawInput: { command: "make" } },
            options: [{ optionId: "always", name: "Always", kind: "allow_always" }, { optionId: "once", name: "Allow", kind: "allow_once" },
                { optionId: "no", name: "Reject", kind: "reject_once" }, { optionId: "never", name: "Never", kind: "reject_always" }] } };
        valid("JSONRPCRequest", request, "permission request");
        valid("RequestPermissionRequest", request.params, "permission request");
        assert.deepEqual(logic.accept(JSON.stringify(request)), { kind: "request", id: 5, request: { kind: "permission", sessionId: "s",
            call: { id: "t1", title: null, kind: "execute", status: null, locations: [], diffs: [], rawInput: { command: "make" } },
            allow: "once", reject: "no" } }, "only one-time options are chosen");
        const standing = { ...request, params: { ...request.params, options: request.params.options.filter(o => o.kind.endsWith("always")) } };
        assert.deepEqual([logic.accept(JSON.stringify(standing)).request.allow, logic.accept(JSON.stringify(standing)).request.reject],
            [null, null], "a standing grant is never an option Jarvis takes");
        refused(() => logic.accept(JSON.stringify({ ...request, params: { ...request.params, options: [] } })), "message", "no options");
        assert.deepEqual(logic.accept(line({ id: 6, method: "fs/read_text_file", params: { sessionId: "s", path: "/etc/passwd" } })),
            { kind: "request", id: 6, request: { kind: "unsupported", method: "fs/read_text_file" } });
        assert.deepEqual(logic.accept(line({ method: "$/cancel_request", params: { requestId: 1 } })),
            { kind: "notification", event: { kind: "other", method: "$/cancel_request" } });
        refused(() => logic.accept("x".repeat(Acp.LINE_BYTES)), "line-size", "a line past the bound");
        assert.equal(logic.accept(line({ id: 1, result: "x".repeat(Acp.LINE_BYTES - 64) })).kind, "response");
        refused(() => logic.accept("{"), "json", "unreadable");
        for (const bad of ["[]", "null", JSON.stringify({ id: 1, result: {} }), line({ id: null, result: {} }), line({ id: 1.5, result: {} }),
            line({ result: {} }), line({ id: 1 }), line({ id: 1, error: { code: "x", message: "m" } })])
            refused(() => logic.accept(bad), "message", bad);
        assert.deepEqual(logic.accept(line({ id: 4, error: { code: -32603, message: "bad" } })), { kind: "failure", id: 4, code: -32603 });
    }

    function proposals(logic) {
        const call = (kind, extra = {}) => ({ id: "t", title: null, kind, status: null, locations: [], diffs: [], rawInput: null, ...extra });
        const ask = value => ({ kind: "permission", sessionId: "s", call: value, allow: "a", reject: "r" });
        assert.deepEqual(logic.proposal(ask(call("edit", { locations: ["/h/a"], diffs: [{ path: "/h/b", newText: "x" }] })), null, cwd),
            { tool: "harness.files", arguments: { write: ["/h/a", "/h/b"], move: [], remove: [], diff: "/h/b\nx\n" } });
        assert.deepEqual(logic.proposal(ask(call(null)), call("delete", { locations: ["/h/c"] }), cwd),
            { tool: "harness.files", arguments: { write: [], move: [], remove: ["/h/c"], diff: "" } }, "the announced call's kind and paths");
        assert.deepEqual(logic.proposal(ask(call("move", { locations: ["/h/d", "/h/e"] })), null, cwd),
            { tool: "harness.files", arguments: { write: ["/h/d", "/h/e"], move: ["/h/d", "/h/e"], remove: [], diff: "" } });
        assert.deepEqual(logic.proposal(ask(call("edit")), null, cwd), { tool: "harness.files", arguments: {} },
            "an edit that names no path carries no arguments, which the gate refuses");
        assert.deepEqual(logic.proposal(ask(call("execute", { rawInput: { command: "make", cwd: "/h/p" } })), null, cwd),
            { tool: "harness.command", arguments: { command: "make", cwd: "/h/p" } });
        assert.deepEqual(logic.proposal(ask(call("execute", { rawInput: { command: ["git", "push"] } })), null, cwd),
            { tool: "harness.command", arguments: { command: "git push", cwd } }, "argv, run in the session's directory");
        assert.deepEqual(logic.proposal(ask(call("execute")), null, cwd), { tool: "harness.command", arguments: {} });
        assert.deepEqual(logic.proposal(ask(call("execute", { rawInput: { command: "" } })), null, cwd),
            { tool: "harness.command", arguments: {} }, "an empty command is no command");
        for (const kind of ["read", "search", "fetch", "think", "switch_mode", "other", null])
            assert.deepEqual(logic.proposal(ask(call(kind)), null, cwd), { tool: "harness.permissions", arguments: {} }, String(kind));
    }

    const table = logic => { builders(logic); answers(logic); replay(logic); narrowing(logic); proposals(logic); };
    table(Acp);

    let controls = 0;
    const source = fs.readFileSync(file, "utf8");
    for (const [name, needle, replacement] of [
        ["fs-capability", "fs: { readTextFile: false, writeTextFile: false }", "fs: { readTextFile: true, writeTextFile: false }"],
        ["terminal-capability", "}, terminal: false }, clientInfo", "}, terminal: true }, clientInfo"],
        ["bridge-env", "env: Object.entries(bridge.env).map(([name, value]) => ({ name, value }))", "env: []"],
        ["server-name", 'const SERVER = "vgs_jarvis";', 'const SERVER = "jarvis";'],
        ["protocol-version", "result.protocolVersion !== VERSION", "false"],
        ["agent-name", "info.name !== row.agent || ", ""],
        ["version-floor", 'if (part < floor[i]) fail("agent-version");', ""],
        ["version-order", "if (part > floor[i]) break;", ""],
        ["stop-reasons", "!STOPS.includes(result.stopReason)", "!string(result.stopReason)"],
        ["allow-once", 'if (option.kind === "allow_once" && allow === null)', 'if (option.kind.startsWith("allow") && allow === null)'],
        ["reject-once", 'if (option.kind === "reject_once" && reject === null)', 'if (option.kind.startsWith("reject") && reject === null)'],
        ["answer-choice", 'case "reject": option = value.reject; break;', 'case "reject": option = value.allow; break;'],
        ["unsupported", 'case "unsupported": return { jsonrpc: "2.0", id, error: { code: -32601, message: "Method not found" } };',
            'case "unsupported": return { jsonrpc: "2.0", id, result: {} };'],
        ["tool-kind", 'if (!absent(value.kind) && !KINDS.includes(value.kind)) fail("tool-kind");', ""],
        ["tool-title", 'if (partial ? !(absent(value.title) || string(value.title)) : !string(value.title)) fail("tool-call");', ""],
        ["text-only", 'if (u.content.type !== "text") return { kind: "content", sessionId, type: u.content.type };', ""],
        ["line-size", "Buffer.byteLength(line) + 1 > LINE_BYTES", "false"],
        ["envelope", '!plain(message) || message.jsonrpc !== "2.0"', "!plain(message)"],
        ["integer-id", "Number.isSafeInteger(id)", 'typeof id === "number"'],
        ["announced-paths", "...(announced?.locations ?? []), ", ""],
        ["delete-role", 'case "delete": return files([], [], paths);', 'case "delete": return files(paths, [], []);'],
        ["move-roles", 'case "move": return files(paths, paths, []);', 'case "move": return files(paths, [], []);'],
        ["empty-paths", "arguments: paths.length === 0 ? {} : { write, move, remove, diff } });", "arguments: { write, move, remove, diff } });"],
        ["command-text", 'if (string(value) && value !== "") return value;', "if (string(value)) return value;"],
        ["unknown-kind", 'default: return { tool: "harness.permissions", arguments: {} };', 'default: return { tool: "harness.files", arguments: {} };']
    ]) {
        assert.equal(source.split(needle).length - 1, 1, name + " needle");
        mutant(file, name, needle, replacement, table);
        controls++;
        console.log("control=" + name + " detected");
    }
    console.log("test-jarvis-acp-protocol: ok recorded=" + recorded.length + " controls=" + controls);
});
