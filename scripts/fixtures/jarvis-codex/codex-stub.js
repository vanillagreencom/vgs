#!/usr/bin/env node
// Stand-in `codex` built from the codex-cli 0.160.0 app-server schema excerpt
// (app-server.schema.json) and the sanitized recording beside it. It speaks
// the app-server subset Jarvis uses on stdio and replays a scenario the test
// writes to $XDG_STATE_HOME/codex-scenario.json:
//   { servers: {name: config}, thread: {overrides}, features: [extra feature rows],
//     reply: "text" (Verify), turns: [[step, ...], ...], hang: bool, crash: "handshake",
//     refuse: method (answered with a JSON-RPC error) }
// A step is {notify, params}, {request, params} (waits for the answer),
// {mcp: {tool, arguments}} (a tools/call through the thread's bridge server,
// with tools/list first), {interrupt: true} (waits for turn/interrupt) or
// {complete: status}. "$THREAD", "$TURN" and "$CWD" are substituted.
// Every message received is appended to $XDG_STATE_HOME/codex-log as
// {direction, message}, with the count of Jarvis's audit lines when a turn
// starts; argv and environment to codex-calls.
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const cp = require("node:child_process");
const state = process.env.XDG_STATE_HOME;
const args = process.argv.slice(2);
fs.appendFileSync(path.join(state, "codex-calls"), JSON.stringify({ args, env: process.env, cwd: process.cwd() }) + "\n");
if (JSON.stringify(args) === JSON.stringify(["login", "status"])) {
    console.error("Logged in using ChatGPT");
    process.exit(0);
}
if (JSON.stringify(args) !== JSON.stringify(["app-server", "--listen", "stdio://"])) process.exit(9);
const scenario = JSON.parse(fs.readFileSync(path.join(state, "codex-scenario.json"), "utf8"));
const recorded = fs.readFileSync(path.join(state, "codex-recorded.ndjson"), "utf8").trim().split("\n").map(line => JSON.parse(line));
const reply = (flow, test) => structuredClone(recorded.find(entry => entry.flow === flow && test(entry.line)).line.result);
const log = (direction, message) => fs.appendFileSync(path.join(state, "codex-log"), JSON.stringify({ direction, message }) + "\n");
const THREAD = "01a0fbb0-fc74-7383-b55a-3b1d89059cb8";
let cwd = null, servers = null, turnCount = 0, serverId = 0;
const answers = new Map();
let interrupted = null;

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
function substitute(value, turn) {
    return JSON.parse(JSON.stringify(value).replaceAll("$THREAD", THREAD).replaceAll("$TURN", turn).replaceAll("$CWD", cwd));
}
function ask(method, params) {
    const id = serverId++;
    return new Promise(resolve => { answers.set(id, resolve); write({ id, method, params }); });
}

// A minimal MCP client of the thread's bridge server, as Codex starts it.
async function mcp(call) {
    const server = servers.vgs_jarvis;
    const child = cp.spawn(server.command, server.args, { env: { ...process.env, ...server.env }, stdio: ["pipe", "pipe", "inherit"] });
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
    await request(0, "initialize", { protocolVersion: "2025-06-18", capabilities: { elicitation: {} },
        clientInfo: { name: "codex-mcp-client", title: "Codex", version: "0.160.0" } });
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n");
    const tools = await request(1, "tools/list", {});
    const result = await request(2, "tools/call", { name: call.tool, arguments: call.arguments });
    child.stdin.end();
    log("mcp", { tools: tools.result?.tools?.map(tool => tool.name) ?? null, result });
}

async function turn(id, steps) {
    for (const step of steps) {
        if (step.notify) write({ method: step.notify, params: substitute(step.params, id), emittedAtMs: 1 });
        else if (step.request) await ask(step.request, substitute(step.params, id));
        else if (step.mcp) await mcp(step.mcp);
        else if (step.interrupt) await new Promise(resolve => { interrupted = resolve; });
        else if (step.complete) write({ method: "turn/completed", params: { threadId: THREAD,
            turn: { id, items: [], status: step.complete, error: step.complete === "failed" ? { message: "fixture failure" } : null } }, emittedAtMs: 1 });
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
        if (message.method === "turn/start") log("audit", { lines: auditLines() });
        handle(message);
    }
});
process.stdin.on("end", () => { if (!scenario.hang) process.exit(0); });

function handle(message) {
    if (message.method === undefined) { answers.get(message.id)?.(message); answers.delete(message.id); return; }
    const respond = result => write({ id: message.id, result });
    if (message.method === scenario.refuse) { write({ id: message.id, error: { code: -32600, message: "fixture: refused" } }); return; }
    switch (message.method) {
    case "initialize":
        if (scenario.crash === "handshake") process.exit(3);
        respond({ ...reply("patch", line => line.id === 1), codexHome: process.env.CODEX_HOME });
        return;
    case "initialized": return;
    case "config/read":
        cwd = message.params.cwd;
        respond({ config: { mcp_servers: scenario.servers ?? {} }, origins: {} });
        return;
    case "thread/start": {
        servers = message.params.config.mcp_servers;
        const value = reply("patch", line => line.id === 2);
        value.thread.cwd = value.cwd = message.params.cwd;
        respond({ ...value, ...(scenario.thread ?? {}) });
        return;
    }
    case "experimentalFeature/list": {
        const value = reply("features", line => Array.isArray(line.result?.data));
        value.data.push(...(scenario.features ?? []));
        respond(value);
        return;
    }
    case "turn/start": {
        const id = "turn-" + ++turnCount;
        respond({ turn: { id, items: [], status: "inProgress", error: null } });
        write({ method: "turn/started", params: { threadId: THREAD, turn: { id, items: [], status: "inProgress", error: null } }, emittedAtMs: 1 });
        const steps = scenario.reply !== undefined ? [
            { notify: "item/agentMessage/delta", params: { threadId: "$THREAD", turnId: "$TURN", itemId: "m", delta: scenario.reply } },
            { complete: "completed" }] : scenario.turns[turnCount - 1];
        void turn(id, steps);
        return;
    }
    case "turn/interrupt":
        respond({});
        write({ method: "turn/completed", params: { threadId: THREAD, turn: { id: message.params.turnId, items: [],
            status: "interrupted", error: null } }, emittedAtMs: 1 });
        interrupted?.();
        return;
    default:
        write({ id: message.id, error: { code: -32601, message: "fixture: unscripted method" } });
    }
}
