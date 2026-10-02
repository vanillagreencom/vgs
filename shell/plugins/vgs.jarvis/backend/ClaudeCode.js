// One Claude Code conversation: Anthropic's unmodified `claude` program, which
// owns its login and its sockets, started with every built-in tool off and the
// tool bridge as its only MCP server. Every tool call it makes reaches the
// router through mcp-shim; this owner judges the stream-json wire, releases
// what each user turn carries and owns the process for the conversation.
// Contract: docs/architecture/jarvis-claude.md.
"use strict";
const cp = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const { StringDecoder } = require("node:string_decoder");
const Policy = require("./Policy.js");
const Private = require("./Private.js");
const Tools = require("./Tools.js");

const COMMAND = "claude";
// The MCP server name; Claude Code names its tools mcp__<server>__<tool>.
const SERVER = "vgs-jarvis";
const PREFIX = "mcp__" + SERVER + "__";
// Claude Code keeps this one built-in while any MCP tool remains, and no flag
// removes it. It ends the harness conversation and reads or changes nothing
// (code.claude.com/docs/en/tools-reference, EndConversation tool behavior).
const END_CONVERSATION = "EndConversation";
// One stream-json line holds one assistant message; the turn bounds the reply.
const LINE_BYTES = 1024 * 1024;
const TURN_BYTES = 8 * 1024 * 1024;
// The wire brains' request ceiling: the lowest documented provider limit.
const REQUEST_BYTES = 20 * 1024 * 1024;
const TOOLS = 64;
// The plan's context bound in user turns; nothing is summarised or dropped.
const TURNS = 40;
// The plan's cancel bound: the turn holds in cancelling at most 2 s.
const CANCEL_MS = 2000;
const IMAGE_TYPES = ["image/png", "image/jpeg"];
const RESULT_ERRORS = ["error_during_execution", "error_max_turns", "error_max_budget_usd",
    "error_max_structured_output_retries"];
// Only these reach the vendor program; no key variable, token or runner pid.
const ENVIRONMENT = ["PATH", "HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME",
    "XDG_CACHE_HOME", "XDG_RUNTIME_DIR"];

function fail(code) { throw new Error("jarvis: brain=" + code); }
function plain(value) { return value !== null && typeof value === "object" && !Array.isArray(value); }
// A vendor-supplied name enters a keyed error only in this spelling.
function named(value) { return typeof value === "string" && /^[A-Za-z0-9_-]{1,64}$/.test(value) ? value : "invalid"; }
function textItem(item) {
    if (!item || typeof item.content !== "string") fail("item-text");
    return item;
}

/**
 * The one narrowing door for a stream-json output line. It returns the
 * tagged value the turn matches; fields it does not read pass unread.
 */
function messageOf(line) {
    let value;
    try { value = JSON.parse(line); } catch { fail("harness-json"); }
    if (!plain(value) || typeof value.type !== "string") fail("harness-message");
    switch (value.type) {
    case "system":
        if (value.subtype !== "init") return { kind: "other" };
        if (!Array.isArray(value.tools) || !value.tools.every(tool => typeof tool === "string")
                || !Array.isArray(value.mcp_servers) || !value.mcp_servers.every(server =>
                    plain(server) && typeof server.name === "string" && typeof server.status === "string"))
            fail("harness-init");
        return { kind: "init", tools: value.tools, servers: value.mcp_servers };
    case "assistant": {
        const message = value.message;
        if (!plain(message) || message.role !== "assistant" || !Array.isArray(message.content))
            fail("harness-assistant");
        // No Agent tool exists, so no subagent can speak in this stream.
        if (value.parent_tool_use_id !== null) fail("harness-subagent");
        const blocks = message.content.map(block => {
            if (!plain(block) || typeof block.type !== "string") fail("harness-block");
            switch (block.type) {
            case "text":
                if (typeof block.text !== "string") fail("harness-block");
                return { kind: "text", text: block.text };
            case "tool_use":
                if (typeof block.name !== "string") fail("harness-block");
                return { kind: "tool", name: block.name };
            case "thinking": case "redacted_thinking": return { kind: "thinking" };
            // A server tool or any other block is an operation outside the gate.
            default: return fail("harness-block type=" + named(block.type));
            }
        });
        return { kind: "assistant", blocks };
    }
    // Tool result echoes carry what the bridge already released.
    case "user": return { kind: "other" };
    case "result":
        if (value.subtype === "success") {
            if (typeof value.is_error !== "boolean") fail("harness-result");
            return value.is_error ? { kind: "result", outcome: "api-error",
                status: Number.isSafeInteger(value.api_error_status) ? value.api_error_status : 0 }
                : { kind: "result", outcome: "success" };
        }
        if (RESULT_ERRORS.includes(value.subtype)) return { kind: "result", outcome: value.subtype };
        return fail("harness-result");
    case "control_response":
        if (!plain(value.response) || typeof value.response.request_id !== "string"
                || !["success", "error"].includes(value.response.subtype)) fail("harness-control");
        return { kind: "control", id: value.response.request_id, subtype: value.response.subtype };
    // A request needs an answer only a permission host gives; none exists.
    case "control_request": return { kind: "control-request" };
    default: return { kind: "other" };
    }
}

/**
 * The child's whole environment: the daemon's paths, the account's directory
 * and the vendor's switch for its nonessential traffic. Nothing else passes.
 */
function environmentOf(environment, directory) {
    const result = { LANG: "C.UTF-8" };
    for (const name of ENVIRONMENT)
        if (typeof environment[name] === "string" && environment[name] !== "") result[name] = environment[name];
    result.CLAUDE_CONFIG_DIR = directory;
    result.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";
    return result;
}

/**
 * The argv every harness conversation starts with. Built-in tools are off,
 * the bridge is the only MCP server and its tools run without a prompt, since
 * the router is the gate. Hooks, slash commands and session files are off.
 */
function argvOf({ config, instructions, model }) {
    const args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
        "--tools", "", "--strict-mcp-config", "--mcp-config", config,
        "--allowedTools", "mcp__" + SERVER, "--permission-mode", "dontAsk",
        "--settings", JSON.stringify({ disableAllHooks: true }),
        "--disable-slash-commands", "--no-session-persistence"];
    if (instructions !== "") args.push("--system-prompt", instructions);
    if (model !== "") args.push("--model", model);
    return args;
}

/**
 * create({directory, model, recipients, bridge, parent, environment, clock?})
 * owns one harness conversation. directory is the Claude account directory
 * (CLAUDE_CONFIG_DIR); model is "" for the program's own default; recipients
 * is the conversation's frozen set; bridge is null or {open()} resolving the
 * tool bridge's launch contract; parent is the private runtime directory the
 * working directory is made in; environment is the daemon's environment.
 */
function create({ directory, model = "", recipients, bridge = null, parent, environment,
    clock = { set: setTimeout, clear: clearTimeout } }) {
    if (typeof directory !== "string" || !path.isAbsolute(directory) || path.normalize(directory) !== directory)
        fail("harness-directory");
    if (typeof model !== "string" || model.length > 120 || /[\x00-\x1f\x7f]/.test(model) || model.startsWith("-"))
        fail("model");
    Policy.assertRecipients(recipients);
    if (bridge !== null && typeof bridge?.open !== "function") fail("harness-bridge");
    if (typeof parent !== "string" || !path.isAbsolute(parent)) fail("harness-runtime");
    const childEnvironment = environmentOf(environment, directory);
    let context = null;
    // none: not started; starting; running; ended: the conversation's
    // process is gone and no later turn can reach it.
    let process_ = { kind: "none" };
    // The one program this conversation started, kept for close after a fault.
    let owned = null;
    let launch = null;
    let workdir = null;
    let active = null;
    let sent = 0;
    let closed = false;
    let requests = 0;

    function usable() {
        if (closed) fail("closed");
        if (active !== null) fail("busy");
    }

    function start({ instructions, tools }) {
        usable();
        if (context !== null) fail("started");
        if (typeof instructions !== "string") fail("instructions");
        if (!Array.isArray(tools) || tools.length > TOOLS) fail("tools");
        const names = Tools.wireNames(tools.map(tool => tool.id));
        if (names === null) fail("tool-name");
        if (names.size !== 0 && bridge === null) fail("harness-bridge");
        context = { instructions, offered: new Set([...names.keys()].map(name => PREFIX + name)) };
    }

    function allowed(name) {
        return context.offered.has(name) || (name === END_CONVERSATION && context.offered.size !== 0);
    }

    // The init message names every tool the model can call. Anything outside
    // the offer, or a server other than the connected bridge, refuses the brain.
    function admit(record, init) {
        for (const name of init.tools) if (!allowed(name)) fail("harness-tool name=" + named(name));
        const servers = init.servers;
        if (context.offered.size === 0 ? servers.length !== 0
            : servers.length !== 1 || servers[0].name !== SERVER || servers[0].status !== "connected")
            fail("harness-mcp");
        record.initialized = true;
    }

    function signal(record, name) {
        if (record.child.pid === undefined) return; // The spawn failed; close reports its cause.
        try { process.kill(-record.child.pid, name); }
        catch (error) { if (error.code !== "ESRCH") throw error; }
    }

    async function spawn() {
        process_ = { kind: "starting" };
        Private.directory(parent);
        workdir = fs.mkdtempSync(path.join(parent, "claude-"));
        fs.chmodSync(workdir, 0o700);
        const cwd = path.join(workdir, "cwd");
        fs.mkdirSync(cwd, { mode: 0o700 });
        if (context.offered.size !== 0) launch = await bridge.open();
        // close() ran while the session opened; it could not close it then.
        if (closed) { launch?.close(); fail("closed"); }
        // The token stays out of argv: the config is a private file.
        const servers = launch === null ? {} : { [SERVER]: { type: "stdio", command: launch.command,
            args: [...launch.args], env: { ...launch.env } } };
        const config = path.join(workdir, "mcp.json");
        fs.writeFileSync(config, JSON.stringify({ mcpServers: servers }), { mode: 0o600, flag: "wx" });
        const child = cp.spawn(COMMAND, argvOf({ config, instructions: context.instructions, model }),
            { cwd, env: childEnvironment, stdio: ["pipe", "pipe", "pipe"], detached: true });
        const record = { kind: "running", child, initialized: false, consumer: null, cause: null,
            exited: null };
        record.exited = new Promise(resolve => child.once("close", (code, signalName) => {
            record.kind = "exited";
            const status = record.cause !== null ? "cause=" + record.cause
                : signalName !== null ? "signal=" + signalName : "code=" + code;
            if (process_ === record) process_ = { kind: "ended" };
            record.consumer?.exit("harness-exit " + status);
            resolve();
        }));
        child.once("error", error => { record.cause = named(error.code ?? "unknown"); });
        child.stdin.on("error", () => {});
        // Stderr can echo conversation text; it is drained and never kept.
        child.stderr.resume();
        const decoder = new StringDecoder("utf8");
        let tail = "";
        child.stdout.on("data", chunk => {
            tail += decoder.write(chunk);
            let end;
            while ((end = tail.indexOf("\n")) >= 0) {
                const line = tail.slice(0, end);
                tail = tail.slice(end + 1);
                if (Buffer.byteLength(line) > LINE_BYTES) { fault(record, new Error("jarvis: brain=harness-line-limit")); return; }
                if (line.trim() !== "") deliver(record, line);
            }
            // An unterminated line past the bound fails before it completes.
            if (Buffer.byteLength(tail) > LINE_BYTES) fault(record, new Error("jarvis: brain=harness-line-limit"));
        });
        process_ = record;
        owned = record;
        return record;
    }

    function deliver(record, line) {
        if (record.kind !== "running") return;
        try {
            const consumer = record.consumer;
            if (consumer !== null) { consumer.handle(line); return; }
            // Between turns only notices may arrive. A reply with no turn is
            // a harness fault, and the conversation ends with its process.
            const message = messageOf(line);
            if (message.kind === "init") admit(record, message);
            else if (message.kind !== "other") fail("harness-order");
        } catch (error) { fault(record, error); }
    }

    // A fault ends the conversation: the group is killed and the live turn
    // fails with the fault's key once the process is gone.
    function fault(record, error) {
        if (record.kind !== "running") return;
        record.kind = "faulted";
        if (process_ === record) process_ = { kind: "ended" };
        record.consumer?.fault(error);
        signal(record, "SIGKILL");
    }

    function encode(turn, grants) {
        if (turn?.kind === "tool-results") fail("tool-results"); // The bridge answers each call.
        if (turn?.kind !== "user") fail("turn");
        if (sent >= TURNS) fail("context-limit");
        const images = turn.images ?? [];
        if (!Array.isArray(turn.items) || !Array.isArray(images) || turn.items.length + images.length === 0)
            fail("turn");
        for (const image of images) {
            if (!plain(image) || !IMAGE_TYPES.includes(image.type)) fail("image-type");
            if (!image.item || !(image.item.content instanceof Uint8Array)) fail("image-bytes");
        }
        const labels = new Set(), withheld = new Set(), needed = new Set();
        function released(item) {
            const decision = Policy.release(item, recipients, grants);
            switch (decision.kind) {
            case "send": for (const label of item.labels) labels.add(label); break;
            case "ask": for (const label of decision.needed) needed.add(label); break;
            case "withhold": for (const label of decision.labels) withheld.add(label); break;
            default: throw new Error("jarvis: brain=release-kind");
            }
            return decision;
        }
        const content = [
            ...turn.items.map(item => ({ type: "text", text: released(textItem(item)).content })),
            ...images.map(image => {
                const decision = released(image.item);
                return decision.kind === "send"
                    ? { type: "image", source: { type: "base64", media_type: image.type, data: decision.content.toString("base64") } }
                    : { type: "text", text: decision.content };
            })];
        const line = JSON.stringify({ type: "user", message: { role: "user", content }, parent_tool_use_id: null });
        if (Buffer.byteLength(line) > REQUEST_BYTES) fail("request-limit");
        return { line, release: Object.freeze({ withheld: Object.freeze([...withheld]),
            needed: Object.freeze([...needed]), labels: Object.freeze([...labels]) }) };
    }

    function send(turn, grants = []) {
        usable();
        if (context === null) fail("not-started");
        if (process_.kind === "ended") fail("harness-ended");
        const request = encode(turn, grants);
        const queue = [];
        // unstarted, streaming, complete (result read), failed, cancelling,
        // cancelled, ended (the caller read done or the error).
        let state = { kind: "unstarted" };
        let written = false;
        let bytes = 0;
        let timer = null;
        let record = null;
        let wake = () => {};
        let settle;
        const finished = new Promise(resolve => { settle = resolve; });
        const notify = () => wake();
        function release() { if (active === current) active = null; }
        function detach() {
            if (record !== null && record.consumer === current) record.consumer = null;
            if (timer !== null) { clock.clear(timer); timer = null; }
        }
        // A failed turn has ended its process; it settles once the exit is read.
        function failed(error) {
            if (state.kind === "streaming") state = { kind: "failed", error };
            else if (state.kind === "cancelling") state = { kind: "cancelled" };
            detach();
            notify();
            if (record === null) settle();
            else void record.exited.then(settle);
        }

        const current = {
            handle(line) {
                bytes += Buffer.byteLength(line) + 1;
                if (bytes > TURN_BYTES) fail("harness-turn-limit");
                const message = messageOf(line);
                switch (message.kind) {
                case "other": return;
                case "init": admit(record, message); return;
                case "control":
                    if (state.kind !== "cancelling" || message.id !== state.request) fail("harness-control");
                    return;
                case "control-request": return fail("harness-control-request");
                case "assistant":
                    if (!record.initialized) fail("harness-order");
                    for (const block of message.blocks) {
                        if (block.kind === "tool" && !allowed(block.name)) fail("harness-tool name=" + named(block.name));
                        // Text read after the interrupt never reaches the caller.
                        if (block.kind === "text" && block.text !== "" && state.kind === "streaming")
                            queue.push({ kind: "text", text: block.text });
                    }
                    notify();
                    return;
                case "result":
                    if (state.kind === "cancelling") {
                        state = { kind: "cancelled" };
                    } else if (message.outcome === "success") {
                        queue.push({ kind: "done", reason: "stop" });
                        state = { kind: "complete" };
                    } else fail(message.outcome === "api-error" ? "harness-api-error status=" + message.status
                        : "harness-" + message.outcome.replaceAll("_", "-"));
                    detach();
                    settle();
                    notify();
                    return;
                default: throw new Error("jarvis: brain=harness-message-kind");
                }
            },
            fault: failed,
            exit(status) { failed(new Error("jarvis: brain=" + status)); },
            cancel() {
                switch (state.kind) {
                case "unstarted":
                    state = { kind: "cancelled" };
                    settle();
                    break;
                case "streaming":
                    if (!written) { state = { kind: "cancelled" }; break; } // begin() settles.
                    state = { kind: "cancelling", request: "jarvis-interrupt-" + ++requests };
                    queue.length = 0;
                    record.child.stdin.write(JSON.stringify({ type: "control_request", request_id: state.request,
                        request: { subtype: "interrupt" } }) + "\n");
                    // An unanswered interrupt ends the conversation's process.
                    timer = clock.set(() => { timer = null; fault(record, new Error("jarvis: brain=harness-cancel-timeout")); }, CANCEL_MS);
                    break;
                case "complete": case "failed":
                    state = { kind: "cancelled" };
                    notify();
                    break;
                case "cancelling": case "cancelled": case "ended": break;
                default: throw new Error("jarvis: brain=turn-state");
                }
                return finished.then(release);
            }
        };

        async function begin() {
            try {
                if (request.release.labels.length === 0) fail("release-empty");
                record = process_.kind === "running" ? process_ : await spawn();
                if (state.kind !== "streaming") { settle(); return; } // Cancelled while it started.
                if (record.kind !== "running") fail("harness-ended");
                record.consumer = current;
                record.child.stdin.write(request.line + "\n");
                written = true;
                sent++;
            } catch (error) {
                if (process_.kind === "starting") process_ = { kind: "ended" };
                failed(error);
            }
        }

        const events = {
            [Symbol.asyncIterator]() { return this; },
            async next() {
                if (state.kind === "unstarted") {
                    state = { kind: "streaming" };
                    void begin();
                }
                for (;;) {
                    switch (state.kind) {
                    case "cancelled":
                        state = { kind: "ended" };
                        release();
                        throw new Error("jarvis: brain=cancelled");
                    case "ended": return { value: undefined, done: true };
                    case "cancelling": break;
                    case "streaming": case "complete": case "failed":
                        if (queue.length !== 0) {
                            const value = queue.shift();
                            if (value.kind === "done") { state = { kind: "ended" }; release(); }
                            return { value, done: false };
                        }
                        if (state.kind === "failed") {
                            const error = state.error;
                            state = { kind: "ended" };
                            release();
                            throw error;
                        }
                        if (state.kind === "complete") throw new Error("jarvis: brain=turn-state");
                        break;
                    default: throw new Error("jarvis: brain=turn-state");
                    }
                    await new Promise(resolve => { wake = resolve; });
                }
            },
            async return() {
                await current.cancel();
                return { value: undefined, done: true };
            }
        };
        active = current;
        return Object.freeze({ release: request.release, events });
    }

    function cancel() { return active === null ? Promise.resolve() : active.cancel(); }

    /**
     * End the conversation: the live turn is cancelled, stdin closes and the
     * process group gets SIGTERM, then SIGKILL after the cancel bound. The
     * bridge session closes and the working directory is removed once the
     * process is gone. Resolves then; callers may ignore it.
     */
    function close() {
        if (closed) return Promise.resolve();
        closed = true;
        if (active !== null) void active.cancel();
        const record = owned;
        process_ = { kind: "ended" };
        launch?.close();
        let exited = Promise.resolve();
        if (record !== null && record.kind !== "exited") {
            record.child.stdin.end();
            signal(record, "SIGTERM");
            const timer = clock.set(() => signal(record, "SIGKILL"), CANCEL_MS);
            exited = record.exited.finally(() => clock.clear(timer));
        }
        return exited.then(() => {
            if (workdir !== null) fs.rmSync(workdir, { recursive: true, force: true });
        });
    }

    return Object.freeze({ start, send, cancel, close });
}

/**
 * Account verification: one tool-less harness conversation sends the release
 * item the caller judged and audited, and resolves the reply text only after
 * a successful result. start(events) runs the first read inside the caller's
 * audit record. Login status or a model list never reaches here.
 */
async function verify({ directory, model, recipients, item, grants, parent, environment, instructions, start }) {
    const brain = create({ directory, model, recipients, bridge: null, parent, environment });
    try {
        brain.start({ instructions, tools: [] });
        const reply = brain.send({ kind: "user", items: [item] }, grants);
        let text = "";
        for (let step = await start(reply.events); ; step = await reply.events.next()) {
            if (step.done) fail("harness-unfinished");
            if (step.value.kind === "text") text += step.value.text;
            else if (step.value.kind === "done") return text;
            else fail("harness-event");
        }
    } finally { await brain.close(); }
}

module.exports = { create, verify };
