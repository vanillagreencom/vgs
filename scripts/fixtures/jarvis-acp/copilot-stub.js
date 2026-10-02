#!/usr/bin/env node
// Stand-in `copilot` built from the ACP v1 schema excerpt (acp.schema.json)
// and the sanitized Copilot 1.0.91 recording beside it, whose initialize
// result it answers with. It speaks the ACP subset Jarvis uses on stdio and
// replays a scenario the test writes to $XDG_STATE_HOME/acp-scenario.json:
//   { agent: {agentInfo overrides}, signedOut: bool, crash: "handshake",
//     refuse: method (answered with a JSON-RPC error), reply: "text" (Verify),
//     turns: [[step, ...], ...] }
// A step is {update} (one session/update), {request, params} (waits for the
// answer), {mcp: {tool, arguments}} (a tools/call through the session's
// bridge server, tools/list first), {cancel: true} (waits for session/cancel)
// or {stop: reason}, which answers the prompt. "$SESSION" and "$CWD" are
// substituted. Every message is appended to $XDG_STATE_HOME/acp-log as
// {direction, message}, with the count of Jarvis's audit lines when a prompt
// arrives; argv, environment and cwd to acp-calls.
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const cp = require("node:child_process");
const state = process.env.XDG_STATE_HOME;
const args = process.argv.slice(2);
fs.appendFileSync(path.join(state, "acp-calls"), JSON.stringify({ args, env: process.env, cwd: process.cwd() }) + "\n");
if (args[0] !== "--acp") process.exit(9);
const scenario = JSON.parse(fs.readFileSync(path.join(state, "acp-scenario.json"), "utf8"));
const recorded = fs.readFileSync(path.join(state, "acp-recorded.ndjson"), "utf8").trim().split("\n").map(line => JSON.parse(line));
const log = (direction, message) => fs.appendFileSync(path.join(state, "acp-log"), JSON.stringify({ direction, message }) + "\n");
const SESSION = "6f1c0a52-3c1e-4d7a-9a0e-5b8f2f1d7c11";
let cwd = null, servers = [], prompts = 0, agentId = 0;
const answers = new Map();
// A cancel can arrive before the turn reaches its cancel step.
let cancelled = null, cancelSeen = false;

// Jarvis's audit lines at this moment: a release record precedes a Verify turn.
function auditLines() {
    const directory = path.join(state, "vgs/jarvis/audit");
    if (!fs.existsSync(directory)) return 0;
    return fs.readdirSync(directory).reduce((count, name) =>
        count + fs.readFileSync(path.join(directory, name), "utf8").split("\n").filter(Boolean).length, 0);
}
function write(message) {
    log("out", message);
    process.stdout.write(JSON.stringify(message) + "\n");
}
function substitute(value) {
    return JSON.parse(JSON.stringify(value).replaceAll("$SESSION", SESSION).replaceAll("$CWD", cwd));
}
function ask(method, params) {
    const id = "agent-" + agentId++;
    return new Promise(resolve => { answers.set(id, resolve); write({ jsonrpc: "2.0", id, method, params }); });
}

// A minimal MCP client of the session's bridge server, as the agent starts it.
async function mcp(call) {
    const server = servers.find(entry => entry.name === "vgs_jarvis");
    const env = Object.fromEntries(server.env.map(entry => [entry.name, entry.value]));
    const child = cp.spawn(server.command, server.args, { env: { ...process.env, ...env }, stdio: ["pipe", "pipe", "inherit"] });
    let tail = "";
    const waiting = new Map();
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", chunk => {
        tail += chunk;
        let end;
        while ((end = tail.indexOf("\n")) >= 0) {
            const message = JSON.parse(tail.slice(0, end));
            tail = tail.slice(end + 1);
            waiting.get(message.id)?.(message);
        }
    });
    const request = (id, method, params) => new Promise(resolve => {
        waiting.set(id, resolve);
        child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
    });
    await request(0, "initialize", { protocolVersion: "2025-06-18", capabilities: {},
        clientInfo: { name: "copilot-mcp-client", version: "1.0.91" } });
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n");
    const tools = await request(1, "tools/list", {});
    const result = await request(2, "tools/call", { name: call.tool, arguments: call.arguments });
    child.stdin.end();
    log("mcp", { tools: tools.result?.tools?.map(tool => tool.name) ?? null, result });
}

async function turn(id, steps) {
    for (const step of steps) {
        if (step.update) write({ jsonrpc: "2.0", method: "session/update", params: { sessionId: SESSION, update: substitute(step.update) } });
        else if (step.request) await ask(step.request, substitute(step.params));
        else if (step.mcp) await mcp(step.mcp);
        else if (step.cancel) { if (!cancelSeen) await new Promise(resolve => { cancelled = resolve; }); }
        else if (step.stop) { write({ jsonrpc: "2.0", id, result: { stopReason: step.stop } }); return; }
    }
}

let tail = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", chunk => {
    tail += chunk;
    let end;
    while ((end = tail.indexOf("\n")) >= 0) {
        const message = JSON.parse(tail.slice(0, end));
        tail = tail.slice(end + 1);
        log("in", message);
        if (message.method === "session/prompt") log("audit", { lines: auditLines() });
        handle(message);
    }
});
process.stdin.on("end", () => process.exit(0));

function handle(message) {
    if (message.method === undefined) { answers.get(message.id)?.(message); answers.delete(message.id); return; }
    const respond = result => write({ jsonrpc: "2.0", id: message.id, result });
    if (message.method === scenario.refuse) {
        write({ jsonrpc: "2.0", id: message.id, error: { code: -32603, message: "fixture: refused" } });
        return;
    }
    switch (message.method) {
    case "initialize": {
        if (scenario.crash === "handshake") process.exit(3);
        const result = structuredClone(recorded.find(entry => entry.line.id === 1 && entry.direction === "out").line.result);
        Object.assign(result.agentInfo, scenario.agent ?? {});
        respond(result);
        return;
    }
    case "session/new":
        if (scenario.signedOut) {
            write(recorded.find(entry => entry.line.id === 2 && entry.direction === "out").line);
            return;
        }
        cwd = message.params.cwd;
        servers = message.params.mcpServers;
        respond({ sessionId: SESSION });
        return;
    case "session/prompt": {
        const steps = scenario.reply !== undefined
            ? [{ update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: scenario.reply } } }, { stop: "end_turn" }]
            : scenario.turns[prompts];
        prompts++;
        void turn(message.id, steps);
        return;
    }
    case "session/cancel": cancelSeen = true; cancelled?.(); return;
    default:
        if (message.id !== undefined) write({ jsonrpc: "2.0", id: message.id, error: { code: -32601, message: "fixture: unscripted method" } });
    }
}
