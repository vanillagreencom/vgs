// The Codex harness's one app-server judge: it builds every message Jarvis
// writes to `codex app-server` and narrows every line the program writes back.
// No other file parses this protocol. Contract, sources and the pinned schema
// excerpt: docs/architecture/jarvis-codex.md.
"use strict";

// One JSON-RPC message per line. A thread or turn reply can carry a whole
// patch, so the ceiling is the wire brains' total stream bound.
const LINE_BYTES = 8 * 1024 * 1024;
const CLIENT = Object.freeze({ name: "vgs-jarvis", title: "VGS Jarvis", version: "1" });
// The bridge's server name in the thread's configuration. A user's own server
// of that name refuses the thread rather than merge with it.
const SERVER = "vgs_jarvis";
// Feature switches that give the model a built-in tool or run a program the
// gate cannot see. Codex 0.160.0 with these off, web search disabled and the
// user-input tool off offered the model apply_patch alone, besides MCP access.
const FEATURES_OFF = Object.freeze(["shell_tool", "unified_exec", "view_image", "image_generation", "browser_use",
    "browser_use_external", "computer_use", "multi_agent", "apps", "plugins", "memories", "goals", "tool_suggest",
    "skill_search", "sleep_tool", "in_app_browser", "hooks", "code_mode_host", "realtime_conversation",
    "remote_plugin", "workspace_dependencies", "skill_mcp_dependency_install", "shell_snapshot", "worktrees"]);
// Every feature 0.160.0 reports enabled on a thread started with FEATURES_OFF.
// Any other enabled feature may be a new tool, so the thread is refused.
const FEATURES_ENABLED = Object.freeze(["auth_elicitation", "browser_use_full_cdp_access", "collaboration_modes",
    "compaction_image_budget", "content_item_kinds", "daemon_auto_start", "enable_request_compression", "fast_mode",
    "guardian_approval", "guardian_reuse_parent_compaction", "in_app_chat", "in_app_dictation",
    "in_app_local_automation", "in_app_updates", "item_ids", "mentions_v2", "plugin_sharing", "resize_all_images",
    "sqlite", "steer", "system_proxy_fallback", "terminal_resize_reflow", "tool_call_mcp_elicitation",
    "tool_search_always_defer_mcp_tools", "tui_app_server", "unbounded_connection_retries", "unified_exec",
    "unified_exec_tty", "unified_exec_zsh_fork", "write_stdin_approval"]);
const FEATURE_PAGE = 500;
const NAME = /^[A-Za-z0-9_-]{1,64}$/;

function fail(code) { throw new Error("jarvis: brain=codex-" + code); }
function plain(value) { return value !== null && typeof value === "object" && !Array.isArray(value); }
function string(value) { return typeof value === "string"; }
function nullable(value) { return value === undefined || value === null ? null : string(value) ? value : fail("message"); }
function validId(id) { return string(id) || Number.isSafeInteger(id); }

/** @typedef {{command: string, args: readonly string[], env: Readonly<Record<string, string>>}} Launch */

function request(id, method, params) { return { id, method, params }; }

/** The handshake's first request. */
function initialize(id) { return request(id, "initialize", { clientInfo: { ...CLIENT } }); }

/** The notification that ends initialization. */
function initialized() { return { method: "initialized" }; }

/** Read the effective configuration as the thread's working directory sees it. */
function configRead(id, cwd) { return request(id, "config/read", { cwd, includeLayers: false }); }

/**
 * Start the conversation's ephemeral thread. foreign names the user's own MCP
 * servers, each switched off; bridge is the tool bridge's launch contract,
 * or null for a thread with no tools. The bridge token travels only here, on
 * the program's stdin, never in argv.
 * @param {{cwd: string, model: string, instructions: string, foreign: string[], bridge: Launch|null}} value
 */
function threadStart(id, { cwd, model, instructions, foreign, bridge }) {
    if (foreign.includes(SERVER)) fail("mcp-name");
    const servers = Object.fromEntries(foreign.map(name => [name, { enabled: false }]));
    if (bridge !== null) servers[SERVER] = { command: bridge.command, args: [...bridge.args], env: { ...bridge.env } };
    const params = { cwd, approvalPolicy: "untrusted", approvalsReviewer: "user", sandbox: "read-only",
        ephemeral: true, baseInstructions: instructions,
        config: { features: Object.fromEntries(FEATURES_OFF.map(name => [name, false])), web_search: "disabled",
            tools: { experimental_request_user_input: { enabled: false } }, mcp_servers: servers } };
    if (model !== "") params.model = model;
    return request(id, "thread/start", params);
}

/** List the started thread's effective features in one page. */
function featureList(id, threadId) { return request(id, "experimentalFeature/list", { threadId, limit: FEATURE_PAGE }); }

/** One user turn of plain text. */
function turnStart(id, threadId, text) {
    return request(id, "turn/start", { threadId, input: [{ type: "text", text, text_elements: [] }] });
}

function turnInterrupt(id, threadId, turnId) { return request(id, "turn/interrupt", { threadId, turnId }); }

/**
 * The answer to a narrowed server request. admitted is the gate's answer;
 * a permissions request is answered with no grant, and an unsupported method
 * with a JSON-RPC error.
 */
function answer(id, value, admitted) {
    switch (value.kind) {
    case "file-change": case "command": return { id, result: { decision: admitted ? "accept" : "decline" } };
    case "permissions":
        if (admitted) fail("permissions-admitted");
        return { id, result: { permissions: {}, scope: "turn" } };
    case "elicitation": return { id, result: admitted ? { action: "accept", content: {} } : { action: "decline", content: null } };
    case "unsupported": return { id, error: { code: -32601, message: "Method not found" } };
    default: return fail("request-kind");
    }
}

/** The user's MCP server names from a config/read result. Values are dropped. */
function servers(result) {
    if (!plain(result) || !plain(result.config)) fail("config");
    const table = result.config.mcp_servers ?? {};
    if (!plain(table)) fail("config");
    const names = Object.keys(table);
    if (!names.every(name => NAME.test(name))) fail("mcp-name");
    return names;
}

/** The started thread's id, after its reply proves the lockdown took effect. */
function thread(result) {
    if (!plain(result) || !plain(result.thread) || !string(result.thread.id) || result.thread.id === "") fail("thread");
    if (result.approvalPolicy !== "untrusted" || result.approvalsReviewer !== "user"
            || !plain(result.sandbox) || result.sandbox.type !== "readOnly" || result.sandbox.networkAccess === true)
        fail("lockdown");
    return result.thread.id;
}

/** Refuse a thread whose enabled features name one this table has not judged. */
function features(result) {
    if (!plain(result) || !Array.isArray(result.data) || result.data.length === 0) fail("features");
    if (result.nextCursor !== undefined && result.nextCursor !== null) fail("feature-page");
    for (const feature of result.data) {
        if (!plain(feature) || !string(feature.name) || typeof feature.enabled !== "boolean") fail("features");
        if (feature.enabled && !FEATURES_ENABLED.includes(feature.name))
            fail("feature name=" + (NAME.test(feature.name) ? feature.name : "invalid"));
    }
}

function turnId(result) {
    if (!plain(result) || !plain(result.turn) || !string(result.turn.id) || result.turn.id === "") fail("turn");
    return result.turn.id;
}

function item(value) {
    if (!plain(value) || !string(value.type) || !string(value.id)) fail("item");
    switch (value.type) {
    case "agentMessage":
        if (!string(value.text)) fail("item");
        return { kind: "message", id: value.id, text: value.text };
    case "fileChange": {
        if (!Array.isArray(value.changes) || value.changes.length === 0
                || !["inProgress", "completed", "failed", "declined"].includes(value.status)) fail("item");
        const changes = value.changes.map(change => {
            if (!plain(change) || !string(change.path) || !string(change.diff) || !plain(change.kind)
                    || !["add", "delete", "update"].includes(change.kind.type)) fail("item");
            const movePath = change.kind.type === "update" ? nullable(change.kind.move_path) : null;
            return { path: change.path, change: change.kind.type, movePath, diff: change.diff };
        });
        return { kind: "file-change", id: value.id, changes, status: value.status };
    }
    case "commandExecution":
        if (!string(value.command) || !string(value.cwd)
                || !["inProgress", "completed", "failed", "declined"].includes(value.status)) fail("item");
        return { kind: "command", id: value.id, command: value.command, cwd: value.cwd, status: value.status };
    case "mcpToolCall":
        if (!string(value.server) || !string(value.tool) || !["inProgress", "completed", "failed"].includes(value.status))
            fail("item");
        return { kind: "mcp", id: value.id, server: value.server, tool: value.tool, status: value.status };
    default: return { kind: "other", id: value.id, type: value.type };
    }
}

function scope(params) {
    if (!plain(params) || !string(params.threadId) || !string(params.turnId)) fail("message");
    return { threadId: params.threadId, turnId: params.turnId };
}

function notification(method, params) {
    switch (method) {
    case "turn/started": case "turn/completed": {
        if (!plain(params) || !string(params.threadId) || !plain(params.turn) || !string(params.turn.id)) fail("message");
        if (method === "turn/started") return { kind: "turn-started", threadId: params.threadId, turnId: params.turn.id };
        const status = params.turn.status;
        if (!["completed", "interrupted", "failed"].includes(status)) fail("turn-status");
        const error = params.turn.error;
        if (error !== undefined && error !== null && (!plain(error) || !string(error.message))) fail("message");
        return { kind: "turn-completed", threadId: params.threadId, turnId: params.turn.id, status };
    }
    case "item/started": case "item/completed":
        return { kind: method === "item/started" ? "item-started" : "item-completed", ...scope(params), item: item(params.item) };
    case "item/agentMessage/delta":
        if (!string(params?.delta) || !string(params.itemId)) fail("message");
        return { kind: "delta", ...scope(params), itemId: params.itemId, delta: params.delta };
    case "error":
        if (!plain(params?.error) || !string(params.error.message) || typeof params.willRetry !== "boolean") fail("message");
        return { kind: "error", ...scope(params), willRetry: params.willRetry };
    default: return { kind: "other", method };
    }
}

function serverRequest(method, params) {
    switch (method) {
    case "item/fileChange/requestApproval": case "item/commandExecution/requestApproval":
    case "item/permissions/requestApproval": {
        const where = scope(params);
        if (!string(params.itemId)) fail("message");
        if (method === "item/fileChange/requestApproval") return { kind: "file-change", ...where, itemId: params.itemId };
        if (method === "item/permissions/requestApproval") return { kind: "permissions", ...where, itemId: params.itemId };
        return { kind: "command", ...where, itemId: params.itemId, command: nullable(params.command), cwd: nullable(params.cwd) };
    }
    case "mcpServer/elicitation/request":
        if (!plain(params) || !string(params.threadId) || !string(params.serverName)) fail("message");
        // Codex asks before each MCP tool call; the bridge routes the call itself.
        return { kind: "elicitation", threadId: params.threadId, server: params.serverName,
            toolCall: params.mode === "form" && plain(params._meta) && params._meta.codex_approval_kind === "mcp_tool_call" };
    default: return { kind: "unsupported", method };
    }
}

/**
 * Narrow one line the program wrote: a response, a failure, a notification
 * or a server request. An unreadable line throws a keyed error.
 */
function accept(line) {
    if (Buffer.byteLength(line) + 1 > LINE_BYTES) fail("line-size");
    let message;
    try { message = JSON.parse(line); } catch { fail("json"); }
    if (!plain(message)) fail("message");
    const hasId = Object.hasOwn(message, "id");
    if (hasId && !validId(message.id)) fail("message");
    if (string(message.method)) {
        const params = message.params;
        return hasId ? { kind: "request", id: message.id, request: serverRequest(message.method, params) }
            : { kind: "notification", event: notification(message.method, params) };
    }
    if (!hasId) fail("message");
    if (Object.hasOwn(message, "result")) return { kind: "response", id: message.id, result: message.result };
    if (plain(message.error) && Number.isSafeInteger(message.error.code) && string(message.error.message))
        return { kind: "failure", id: message.id, code: message.error.code };
    return fail("message");
}

/**
 * The gate's typed call for an approval request, from the item the program
 * announced. A file change lists each path by the role Denied judges it in.
 */
function proposal(value, announced) {
    switch (value.kind) {
    case "file-change": {
        if (announced === null || announced.kind !== "file-change") return { tool: "harness.files", arguments: {} };
        const args = { write: [], move: [], remove: [], diff: "" };
        for (const change of announced.changes) {
            if (change.change === "add") args.write.push(change.path);
            else if (change.change === "delete") args.remove.push(change.path);
            else if (change.movePath === null) args.write.push(change.path);
            else { args.move.push(change.path); args.write.push(change.movePath); }
            args.diff += change.path + "\n" + change.diff + (change.diff.endsWith("\n") ? "" : "\n");
        }
        return { tool: "harness.files", arguments: args };
    }
    case "command":
        return { tool: "harness.command", arguments: { command: value.command ?? announced?.command ?? "",
            cwd: value.cwd ?? announced?.cwd ?? "" } };
    case "permissions": return { tool: "harness.permissions", arguments: {} };
    default: return fail("request-kind");
    }
}

module.exports = { LINE_BYTES, SERVER, FEATURES_OFF, FEATURES_ENABLED, initialize, initialized, configRead,
    threadStart, featureList, turnStart, turnInterrupt, answer, servers, thread, features, turnId, accept, proposal };
