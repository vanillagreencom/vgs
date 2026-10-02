#!/usr/bin/env node
// The Codex harness's app-server judge. Every message it builds is checked
// against the excerpt of the schema codex-cli 0.160.0 generated
// (fixtures/jarvis-codex/app-server.schema.json); every line it narrows comes
// from the sanitized 0.160.0 recording in fixtures/jarvis-codex/recorded.ndjson,
// made 2026-10-02 against a loopback model stub with no account, or is a
// synthetic refusal row. Mutants run in J09.
"use strict";
const { assert, fs, path, tree, world, mutant } = require("./fixtures/jarvis/policy.js");
const Check = require("./fixtures/schema-check.js");
const excerpt = require("./fixtures/jarvis-codex/app-server.schema.json");
const file = path.join(tree, "shell/plugins/vgs.jarvis/backend/CodexAppServer.js");
const recorded = fs.readFileSync(path.join(tree, "scripts/fixtures/jarvis-codex/recorded.ndjson"), "utf8")
    .trim().split("\n").map(line => JSON.parse(line));

// Independent of the production table: the switches whose recorded effect
// left the model apply_patch and MCP access alone.
const OFF = ["shell_tool", "unified_exec", "view_image", "image_generation", "browser_use", "browser_use_external",
    "computer_use", "multi_agent", "apps", "plugins", "memories", "goals", "tool_suggest", "skill_search",
    "sleep_tool", "in_app_browser", "hooks", "code_mode_host", "realtime_conversation", "remote_plugin",
    "workspace_dependencies", "skill_mcp_dependency_install", "shell_snapshot", "worktrees"];
const RESPONSES = { "turn/started": "TurnStartedNotification", "turn/completed": "TurnCompletedNotification",
    "item/started": "ItemStartedNotification", "item/completed": "ItemCompletedNotification",
    "item/agentMessage/delta": "AgentMessageDeltaNotification", "error": "ErrorNotification" };
const REQUESTS = { "item/fileChange/requestApproval": "FileChangeRequestApprovalParams",
    "mcpServer/elicitation/request": "McpServerElicitationRequestParams",
    "item/commandExecution/requestApproval": "CommandExecutionRequestApprovalParams",
    "item/permissions/requestApproval": "PermissionsRequestApprovalParams" };
const PINNED_ITEMS = ["userMessage", "agentMessage", "fileChange", "commandExecution", "mcpToolCall"];

function valid(name, value, label) { assert.deepEqual(Check.errors(excerpt, name, value), [], label + " matches " + name); }
function refused(fn, code, label) { assert.throws(fn, { message: "jarvis: brain=codex-" + code }, label); }

world(() => {
    const Codex = require(file);
    const bridge = { command: "/usr/bin/node", args: ["/plugin/backend/mcp-shim"],
        env: { VGS_JARVIS_TOOLS_SOCKET: "/run/vgs/jarvis/tools.sock", VGS_JARVIS_TOOLS_TOKEN: "f".repeat(64) } };
    const cwd = "/home/fixture/.local/state/vgs/jarvis/codex-cwd";

    function builders(logic) {
        const init = logic.initialize(1);
        valid("JSONRPCRequest", init, "initialize");
        valid("InitializeParams", init.params, "initialize");
        assert.deepEqual(init, { id: 1, method: "initialize", params: { clientInfo: { name: "vgs-jarvis", title: "VGS Jarvis", version: "1" } } });
        valid("JSONRPCNotification", logic.initialized(), "initialized");
        assert.deepEqual(logic.initialized(), { method: "initialized" });
        const config = logic.configRead(2, cwd);
        valid("ConfigReadParams", config.params, "config/read");
        assert.deepEqual(config, { id: 2, method: "config/read", params: { cwd, includeLayers: false } });

        const start = logic.threadStart(3, { cwd, model: "", instructions: "Be brief.", foreign: ["userfs", "notes"], bridge });
        valid("JSONRPCRequest", start, "thread/start");
        valid("ThreadStartParams", start.params, "thread/start");
        const p = start.params;
        assert.equal(start.method, "thread/start");
        assert.deepEqual([p.approvalPolicy, p.approvalsReviewer, p.sandbox, p.ephemeral, p.cwd, p.baseInstructions],
            ["untrusted", "user", "read-only", true, cwd, "Be brief."]);
        assert.equal(Object.hasOwn(p, "model"), false, "an empty model leaves the account's default");
        assert.deepEqual(p.config.features, Object.fromEntries(OFF.map(name => [name, false])));
        assert.equal(p.config.web_search, "disabled");
        assert.deepEqual(p.config.tools, { experimental_request_user_input: { enabled: false } });
        assert.deepEqual(p.config.mcp_servers, { userfs: { enabled: false }, notes: { enabled: false },
            vgs_jarvis: { command: bridge.command, args: bridge.args, env: bridge.env } });
        assert.deepEqual(Object.keys(p).sort(), ["approvalPolicy", "approvalsReviewer", "baseInstructions", "config",
            "cwd", "ephemeral", "sandbox"]);
        const bare = logic.threadStart(4, { cwd, model: "gpt-fixture", instructions: "x", foreign: [], bridge: null });
        valid("ThreadStartParams", bare.params, "thread/start without tools");
        assert.equal(bare.params.model, "gpt-fixture");
        assert.deepEqual(bare.params.config.mcp_servers, {}, "a probe thread has no MCP server");
        refused(() => logic.threadStart(5, { cwd, model: "", instructions: "x", foreign: ["vgs_jarvis"], bridge }),
            "mcp-name", "a user server of the bridge's name");

        const list = logic.featureList(6, "thread-1");
        valid("ExperimentalFeatureListParams", list.params, "experimentalFeature/list");
        assert.deepEqual(list, { id: 6, method: "experimentalFeature/list", params: { threadId: "thread-1", limit: 500 } });
        const turn = logic.turnStart(7, "thread-1", "hello");
        valid("TurnStartParams", turn.params, "turn/start");
        assert.deepEqual(turn.params, { threadId: "thread-1", input: [{ type: "text", text: "hello", text_elements: [] }] });
        const interrupt = logic.turnInterrupt(8, "thread-1", "turn-1");
        valid("TurnInterruptParams", interrupt.params, "turn/interrupt");
        assert.deepEqual(interrupt.params, { threadId: "thread-1", turnId: "turn-1" });
    }

    const where = { threadId: "t", turnId: "u" };
    function answers(logic) {
        for (const [kind, schema] of [["file-change", "FileChangeRequestApprovalResponse"], ["command", "CommandExecutionRequestApprovalResponse"]]) {
            const yes = logic.answer(9, { kind, ...where }, true), no = logic.answer(9, { kind, ...where }, false);
            valid("JSONRPCResponse", yes, kind);
            valid(schema, yes.result, kind);
            valid(schema, no.result, kind);
            assert.deepEqual([yes.result, no.result], [{ decision: "accept" }, { decision: "decline" }], kind);
        }
        const permissions = logic.answer("p", { kind: "permissions", ...where }, false);
        valid("PermissionsRequestApprovalResponse", permissions.result, "permissions");
        assert.deepEqual(permissions.result, { permissions: {}, scope: "turn" });
        refused(() => logic.answer("p", { kind: "permissions" }, true), "permissions-admitted", "no permission is granted");
        const accept = logic.answer(0, { kind: "elicitation" }, true), decline = logic.answer(0, { kind: "elicitation" }, false);
        valid("McpServerElicitationRequestResponse", accept.result, "elicitation");
        valid("McpServerElicitationRequestResponse", decline.result, "elicitation");
        assert.deepEqual([accept.result, decline.result], [{ action: "accept", content: {} }, { action: "decline", content: null }]);
        const error = logic.answer(3, { kind: "unsupported", method: "item/tool/call" }, false);
        valid("JSONRPCError", error, "unsupported");
        assert.deepEqual(error, { id: 3, error: { code: -32601, message: "Method not found" } });
    }

    // The recording: every pinned line validates against the excerpt, and the
    // judge narrows it to the expected value.
    function replay(logic) {
        const flows = {};
        for (const { flow, line } of recorded) {
            const value = logic.accept(JSON.stringify(line));
            (flows[flow] ??= []).push({ line, value });
            if (line.method !== undefined && line.id !== undefined) {
                valid("JSONRPCRequest", line, "recorded request");
                if (REQUESTS[line.method]) valid(REQUESTS[line.method], line.params, line.method);
            } else if (line.method !== undefined) {
                valid("JSONRPCNotification", line, "recorded notification");
                const pinned = RESPONSES[line.method] && (!line.params.item || PINNED_ITEMS.includes(line.params.item.type));
                if (pinned) valid(RESPONSES[line.method], line.params, line.method);
            } else valid("JSONRPCResponse", line, "recorded response");
        }
        const patch = flows.patch.map(entry => entry.value);
        assert.equal(logic.thread(flows.patch.find(entry => entry.line.id === 2).line.result), "01a0fbb0-fc74-7383-b55a-3b1d89059cb8");
        assert.equal(logic.turnId(patch.find(v => v.kind === "response" && v.id === 3).result), "01a0fbb0-fc93-7da0-a43c-46f6c70998cb");
        const turnId = "01a0fbb0-fc93-7da0-a43c-46f6c70998cb", threadId = "01a0fbb0-fc74-7383-b55a-3b1d89059cb8";
        const announced = patch.find(v => v.kind === "notification" && v.event.kind === "item-started" && v.event.item.kind === "file-change");
        assert.deepEqual(announced.event.item, { kind: "file-change", id: "call_patch", status: "inProgress",
            changes: [{ path: "/home/fixture/.local/state/vgs/jarvis/codex-cwd/hello.txt", change: "add", movePath: null, diff: "hi\n" }] });
        assert.deepEqual(patch.find(v => v.kind === "request"),
            { kind: "request", id: 0, request: { kind: "file-change", threadId, turnId, itemId: "call_patch" } });
        assert.deepEqual(patch.filter(v => v.kind === "notification" && v.event.kind === "delta").map(v => v.event),
            [{ kind: "delta", threadId, turnId, itemId: "msg_resp_3", delta: "Done." }]);
        assert.deepEqual(patch.filter(v => v.kind === "notification" && v.event.kind === "turn-completed").map(v => v.event),
            [{ kind: "turn-completed", threadId, turnId, status: "completed" }]);
        assert.ok(patch.some(v => v.kind === "notification" && v.event.kind === "other" && v.event.method === "turn/diff/updated"));
        const mcp = flows.mcp.map(entry => entry.value);
        assert.deepEqual(mcp.find(v => v.kind === "request").request,
            { kind: "elicitation", threadId: "01a0fbb2-d0aa-7b60-8cff-7618f0d4bf70", server: "jarvis", toolCall: true });
        assert.deepEqual(mcp.filter(v => v.kind === "notification" && v.event.kind === "item-completed" && v.event.item.kind === "mcp")
            .map(v => v.event.item), [{ kind: "mcp", id: "call_mcp", server: "jarvis", tool: "windows_list", status: "completed" }]);
        const featureReply = flows.features.find(entry => Array.isArray(entry.line.result?.data));
        valid("ExperimentalFeatureListResponse", featureReply.line.result, "recorded features");
        assert.doesNotThrow(() => logic.features(featureReply.line.result), "every recorded enabled feature is judged");
        const threadReply = flows.features.find(entry => entry.line.result?.thread);
        valid("ThreadStartResponse", threadReply.line.result, "recorded thread");
        assert.equal(logic.thread(threadReply.line.result), threadReply.line.result.thread.id);
    }

    const threadReply = recorded.find(entry => entry.flow === "patch" && entry.line.id === 2).line.result;
    const featureReply = recorded.find(entry => Array.isArray(entry.line.result?.data)).line.result;
    function refusals(logic) {
        for (const [label, change] of [["policy", { approvalPolicy: "never" }], ["reviewer", { approvalsReviewer: "auto_review" }],
            ["sandbox", { sandbox: { type: "dangerFullAccess" } }], ["network", { sandbox: { type: "readOnly", networkAccess: true } }]]) {
            const reply = { ...threadReply, ...change };
            valid("ThreadStartResponse", reply, label);
            refused(() => logic.thread(reply), "lockdown", label);
        }
        refused(() => logic.thread({ ...threadReply, thread: {} }), "thread", "no thread id");
        const extra = { ...featureReply, data: [...featureReply.data, { name: "new_tool", stage: "stable", enabled: true, defaultEnabled: true }] };
        valid("ExperimentalFeatureListResponse", extra, "an unjudged feature");
        refused(() => logic.features(extra), "feature name=new_tool", "an unjudged enabled feature");
        const listed = { ...featureReply, data: featureReply.data.map(f => f.name === "shell_tool" ? { ...f, enabled: true } : f) };
        refused(() => logic.features(listed), "feature name=shell_tool", "a switched-off tool reads enabled");
        assert.doesNotThrow(() => logic.features({ ...featureReply, data: [...featureReply.data,
            { name: "new_tool", stage: "stable", enabled: false, defaultEnabled: false }] }), "a disabled unknown feature");
        refused(() => logic.features({ ...featureReply, nextCursor: "more" }), "feature-page", "a second page");
        refused(() => logic.features({ data: [] }), "features", "an empty list proves nothing");
        assert.deepEqual(logic.servers({ config: { mcp_servers: { userfs: { env: { TOKEN: "fixture-secret" } } } }, origins: {} }), ["userfs"]);
        assert.deepEqual(logic.servers({ config: {}, origins: {} }), []);
        refused(() => logic.servers({ config: { mcp_servers: { "bad name": {} } }, origins: {} }), "mcp-name", "server name");
        refused(() => logic.servers({ config: { mcp_servers: [] } }), "config", "server table");
        const completed = (status, extra = {}) => JSON.stringify({ method: "turn/completed", params: { threadId: "t",
            turn: { id: "u", items: [], status, error: null, ...extra } } });
        refused(() => logic.accept(completed("inProgress")), "turn-status", "a completed turn in progress");
        assert.deepEqual(logic.accept(completed("failed", { error: { message: "usage limit" } })).event,
            { kind: "turn-completed", threadId: "t", turnId: "u", status: "failed" });
        refused(() => logic.accept("x".repeat(Codex.LINE_BYTES)), "line-size", "a line past the bound");
        assert.equal(logic.accept(JSON.stringify({ id: 1, result: "x".repeat(Codex.LINE_BYTES - 32) })).kind, "response");
        refused(() => logic.accept("{"), "json", "unreadable");
        for (const line of ["[]", "null", JSON.stringify({ id: null, result: {} }), JSON.stringify({ id: 1.5, result: {} }),
            JSON.stringify({ result: {} }), JSON.stringify({ id: 1 }), JSON.stringify({ id: 1, error: { code: "x", message: "m" } })])
            refused(() => logic.accept(line), "message", line);
        assert.deepEqual(logic.accept(JSON.stringify({ id: 4, error: { code: -32600, message: "bad" } })), { kind: "failure", id: 4, code: -32600 });
        assert.deepEqual(logic.accept(JSON.stringify({ id: "r", method: "item/tool/requestUserInput", params: {} })),
            { kind: "request", id: "r", request: { kind: "unsupported", method: "item/tool/requestUserInput" } });
        const elicit = (mode, meta) => logic.accept(JSON.stringify({ id: 1, method: "mcpServer/elicitation/request",
            params: { threadId: "t", turnId: "u", serverName: "vgs_jarvis", mode, message: "m", requestedSchema: {}, _meta: meta } })).request.toolCall;
        assert.equal(elicit("form", { codex_approval_kind: "mcp_tool_call" }), true);
        assert.equal(elicit("form", { codex_approval_kind: "other" }), false, "only a tool-call approval");
        assert.equal(elicit("url", { codex_approval_kind: "mcp_tool_call" }), false, "a URL elicitation is never a tool call");
        const command = { id: 5, method: "item/commandExecution/requestApproval", params: { threadId: "t", turnId: "u",
            itemId: "i", startedAtMs: 1, command: "ls -la", cwd: "/home/fixture" } };
        valid("CommandExecutionRequestApprovalParams", command.params, "command approval");
        assert.deepEqual(logic.accept(JSON.stringify(command)).request,
            { kind: "command", threadId: "t", turnId: "u", itemId: "i", command: "ls -la", cwd: "/home/fixture" });
        const permissions = { id: 6, method: "item/permissions/requestApproval", params: { threadId: "t", turnId: "u", itemId: "i",
            startedAtMs: 1, cwd: "/home/fixture", permissions: {} } };
        valid("PermissionsRequestApprovalParams", permissions.params, "permissions approval");
        assert.deepEqual(logic.accept(JSON.stringify(permissions)).request, { kind: "permissions", threadId: "t", turnId: "u", itemId: "i" });
    }

    function proposals(logic) {
        const item = changes => ({ kind: "file-change", id: "i", status: "inProgress", changes });
        const change = (filePath, kind, movePath = null, diff = "+x") => ({ path: filePath, change: kind, movePath, diff });
        assert.deepEqual(logic.proposal({ kind: "file-change" }, item([change("/h/a", "add"), change("/h/b", "delete", null, "-y\n"),
            change("/h/c", "update"), change("/h/d", "update", "/h/e")])), { tool: "harness.files", arguments: {
            write: ["/h/a", "/h/c", "/h/e"], move: ["/h/d"], remove: ["/h/b"], diff: "/h/a\n+x\n/h/b\n-y\n/h/c\n+x\n/h/d\n+x\n" } });
        assert.deepEqual(logic.proposal({ kind: "file-change" }, null), { tool: "harness.files", arguments: {} },
            "an unannounced change carries no arguments, which the gate refuses");
        assert.deepEqual(logic.proposal({ kind: "command", command: null, cwd: null },
            { kind: "command", id: "i", command: "make", cwd: "/h", status: "inProgress" }),
            { tool: "harness.command", arguments: { command: "make", cwd: "/h" } });
        assert.deepEqual(logic.proposal({ kind: "permissions" }, null), { tool: "harness.permissions", arguments: {} });
    }

    const table = logic => { builders(logic); answers(logic); replay(logic); refusals(logic); proposals(logic); };
    table(Codex);

    let controls = 0;
    const source = fs.readFileSync(file, "utf8");
    const control = (name, needle, replacement) => { mutant(file, name, needle, replacement, table); controls++; };
    const offBlock = source.slice(source.indexOf("const FEATURES_OFF = "), source.indexOf("]);", source.indexOf("const FEATURES_OFF = ")) + 3);
    for (const name of OFF) {
        assert.equal(offBlock.split(`"${name}"`).length - 1, 1, name + " is switched off once");
        control("feature-off-" + name, offBlock, offBlock.replace(`"${name}"`, "\"removed_" + name + "\""));
    }
    for (const [name, needle, replacement] of [
        ["web-search", 'web_search: "disabled"', 'web_search: "cached"'],
        ["user-input", "experimental_request_user_input: { enabled: false }", "experimental_request_user_input: {}"],
        ["foreign-servers", "foreign.map(name => [name, { enabled: false }])", "[]"],
        ["server-name-collision", 'if (foreign.includes(SERVER)) fail("mcp-name");', ""],
        ["bridge-env", "env: { ...bridge.env }", "env: {}"],
        ["approval-policy", 'approvalPolicy: "untrusted", approvalsReviewer', 'approvalPolicy: "on-request", approvalsReviewer'],
        ["approval-reviewer", 'approvalsReviewer: "user", sandbox', 'approvalsReviewer: "auto_review", sandbox'],
        ["sandbox", 'sandbox: "read-only",\n', 'sandbox: "workspace-write",\n'],
        ["ephemeral", "ephemeral: true, baseInstructions", "ephemeral: false, baseInstructions"],
        ["default-model", 'if (model !== "") params.model = model;', "params.model = model;"],
        ["lockdown-policy", 'result.approvalPolicy !== "untrusted" || ', ""],
        ["lockdown-reviewer", 'result.approvalsReviewer !== "user"\n', "false\n"],
        ["lockdown-sandbox", 'result.sandbox.type !== "readOnly" || ', ""],
        ["lockdown-network", ' || result.sandbox.networkAccess === true)', ")"],
        ["feature-allow", "if (feature.enabled && !FEATURES_ENABLED.includes(feature.name))", "if (false)"],
        ["feature-page", 'if (result.nextCursor !== undefined && result.nextCursor !== null) fail("feature-page");', ""],
        ["feature-empty", " || result.data.length === 0) fail(\"features\");", ") fail(\"features\");"],
        ["server-names", 'if (!names.every(name => NAME.test(name))) fail("mcp-name");', ""],
        ["accept-decision", 'decision: admitted ? "accept" : "decline"', 'decision: "accept"'],
        ["permission-grant", 'if (admitted) fail("permissions-admitted");', ""],
        ["elicitation-decline", 'admitted ? { action: "accept", content: {} } : { action: "decline", content: null }', '{ action: "accept", content: {} }'],
        ["elicitation-kind", ' && params._meta.codex_approval_kind === "mcp_tool_call"', ""],
        ["elicitation-mode", 'params.mode === "form" && ', ""],
        ["turn-status", '["completed", "interrupted", "failed"].includes(status)', "true"],
        ["line-size", "Buffer.byteLength(line) + 1 > LINE_BYTES", "false"],
        ["integer-id", "Number.isSafeInteger(id)", 'typeof id === "number"'],
        ["move-source", "args.move.push(change.path); args.write.push(change.movePath);", "args.write.push(change.movePath);"],
        ["delete-role", 'else if (change.change === "delete") args.remove.push(change.path);', 'else if (change.change === "delete") args.write.push(change.path);']
    ]) {
        assert.equal(source.split(needle).length - 1, 1, name + " needle");
        control(name, needle, replacement);
    }
    console.log("test-jarvis-codex-protocol: ok recorded=" + recorded.length + " controls=" + controls);
});
