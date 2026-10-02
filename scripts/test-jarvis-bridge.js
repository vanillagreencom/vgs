#!/usr/bin/env node
// The tool bridge end to end: the real Session reducer, SessionRunner,
// ToolRouter, Policy, Audit and ToolBridge on scratch state, and the real
// mcp-shim as a child with an explicit environment. This suite is the stub
// harness: it speaks MCP 2025-11-25 (modelcontextprotocol/modelcontextprotocol
// schema/2025-11-25, fetched 2026-10-01) to the shim's stdin and checks every
// message against the pinned excerpt in fixtures/jarvis-bridge/mcp.schema.json.
// Executors are stand-ins registered through the router. Everything runs in J09.
"use strict";
const { assert, fs, path, tree, world, seed, mutant } = require("./fixtures/jarvis/policy.js");
const cp = require("node:child_process");
const net = require("node:net");
const Check = require("./fixtures/schema-check.js");
const excerpt = require("./fixtures/jarvis-bridge/mcp.schema.json");
const { load } = require("../bin/lib/qml-library.js");
const backend = path.join(tree, "shell/plugins/vgs.jarvis/backend");
const bridgeFile = path.join(backend, "ToolBridge.js");
const privateFile = path.join(backend, "Private.js");
const shimFile = path.join(backend, "mcp-shim");

world(async () => {
    const Session = load(path.join(tree, "shell/plugins/vgs.jarvis/Session.js"));
    const Tools = require(path.join(backend, "Tools.js"));
    const fixtures = seed();
    const owners = [];
    // Our own stdout and stderr are pipes under J09; they are the baseline.
    void process.stdout; void process.stderr;
    const held = () => process.getActiveResourcesInfo().filter(name => /Pipe|Process|TCP/.test(name)).sort();
    const baseline = held();
    let serial = 0;

    // A child crosses a pipe and a socket. Bound each read, so a lost line
    // fails its assertion instead of hanging the suite.
    function bounded(promise, what) {
        let timer;
        const limit = new Promise((resolve, reject) => {
            timer = setTimeout(() => reject(new assert.AssertionError({ message: what + " timeout" })), 3000);
        });
        return Promise.race([promise, limit]).finally(() => clearTimeout(timer));
    }
    // Poll a condition the bridge reaches across the event loop.
    async function until(predicate, what) {
        for (let turn = 0; turn < 500; turn++) {
            if (predicate()) return;
            await new Promise(resolve => setImmediate(resolve));
        }
        assert.fail(what + " never held");
    }
    function lineReader(stream, what) {
        let tail = "";
        const lines = [], waiters = [];
        stream.on("data", chunk => {
            tail += chunk;
            let end;
            while ((end = tail.indexOf("\n")) >= 0) {
                const value = JSON.parse(tail.slice(0, end));
                tail = tail.slice(end + 1);
                if (waiters.length) waiters.shift()(value); else lines.push(value);
            }
        });
        const next = () => lines.length ? Promise.resolve(lines.shift())
            : bounded(new Promise(resolve => waiters.push(resolve)), what);
        next.queued = () => lines.length;
        return next;
    }

    /** One daemon-side world: runner, router, audit and bridge from a backend folder. */
    async function make(folder = backend, options = {}) {
        const need = name => require(path.join(folder, name));
        const Router = need("ToolRouter.js"), Bridge = need("ToolBridge.js"), Audit = need("Audit.js");
        const Policy = need("Policy.js"), Denied = need("Denied.js");
        const { SessionRunner, unavailable } = need("session-runner.js");
        if (!fs.existsSync(path.join(folder, "mcp-shim"))) fs.copyFileSync(shimFile, path.join(folder, "mcp-shim"));
        const root = path.join(process.env.JARVIS_TEST_ROOT, "b" + ++serial);
        fs.mkdirSync(root);
        let at = 0, locked = false, transcript;
        const starts = [], answers = [], brain = [];
        const timers = new Map();
        const helloTimers = new Set();
        const audit = Audit.create({ state: path.join(root, "state"), now: () => Date.UTC(2026, 9, 1) });
        const auditFile = path.join(root, "state/audit/2026-10-01.jsonl");
        const rows = () => fs.existsSync(auditFile)
            ? fs.readFileSync(auditFile, "utf8").trim().split("\n").map(line => JSON.parse(line)) : [];
        const ports = { ...unavailable(), mute: { store() {} },
            capture: { open: (e, done) => done(), close: (e, done) => done(), collect: (e, done) => { transcript = done; } },
            brain: { send() {}, cancel: (e, done) => done(), close() {} } };
        const runner = new SessionRunner(Session, ports, { now: () => at, set: (fn, ms) => {
            const timer = {};
            timers.set(timer, { fn, deadline: at + ms });
            return timer;
        }, clear: timer => timers.delete(timer) }, () => {});
        let bridge = null;
        const router = Router.create({ session: Session, state: () => runner.state, dispatch: e => runner.dispatch(e),
            context: () => ({ profile: "standard", locked, denied: Denied.create(fixtures.roots) }),
            audit, result: value => bridge.deliver(value) || brain.push(value) });
        Object.assign(ports, router.ports);
        for (const executor of ["windows", "files", "sandbox"])
            router.register(executor, { commands: ["hyprctl", "bwrap"], timeoutMs: 1000, cancellable: true,
                start: (call, done) => { starts.push({ call, audit: rows().at(-1) }); answers.push(done); },
                cancel: () => {} });
        runner.dispatch({ type: "snapshot", locked: false, engine: "chained", configured: true, settings: {} });
        runner.dispatch({ type: "indicator", shown: true });
        const newTurn = () => { runner.dispatch({ type: "talk-down" }); transcript("final", "fixture user"); };
        newTurn();
        const recipients = Policy.recipients({ conversation: "fixture-" + serial, profile: "standard", cloudVision: "ask",
            brain: options.network ? { kind: "network", provider: "fixture-cloud", account: "a", origin: "https://brain.example.test" }
                : { kind: "local", provider: "fixture-local", account: "" },
            speech: [{ kind: "local", provider: "fixture-speech", account: "" }] });
        // Directly under the world root: the socket path stays shorter than
        // the session bus socket J09's length guard measures.
        const runtime = options.runtime ?? path.join(process.env.JARVIS_TEST_ROOT, "r" + serial.toString(36));
        bridge = Bridge.create({ router, state: () => runner.state, audit, directory: runtime, clock: {
            set: (fn, ms) => { const timer = { fn, ms }; helloTimers.add(timer); return timer; },
            clear: timer => helloTimers.delete(timer) } });
        owners.push(() => { bridge.close(); audit.close(); });
        const open = () => bridge.open({ gen: runner.state.gen, recipients });
        const launch = options.open === false ? null : await open();
        const w = { runner, router, bridge, rows, starts, answers, brain, launch, runtime, root, recipients, open,
            helloTimers, newTurn, dispatch: e => runner.dispatch(e), lock: value => { locked = value; },
            time: value => { at = value; },
            show: () => runner.dispatch({ type: "shown", gen: runner.state.gen, op: runner.state.approval.op, id: runner.state.approval.id }),
            confirm: () => runner.dispatch({ type: "confirm", gen: runner.state.gen, id: runner.state.approval.id,
                digest: runner.state.approval.digest, source: "key" }) };
        /** Start the real shim from a launch contract, with only the given environment. */
        w.shim = (contract = w.launch, { env, file } = {}) => {
            const child = cp.spawn(contract.command, file === undefined ? contract.args : [file], {
                env: env ?? { PATH: process.env.PATH, ...contract.env }, stdio: ["pipe", "pipe", "pipe"] });
            let stderr = "", stdout = "";
            child.stderr.on("data", chunk => { stderr += chunk; });
            child.stdout.on("data", chunk => { stdout += chunk; });
            child.stdin.on("error", () => {});
            const exited = new Promise(resolve => child.on("close", (code, signal) => resolve({ code, signal, stderr })));
            owners.push(() => { if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL"); });
            return { child, next: lineReader(child.stdout, "shim line"),
                send: message => child.stdin.write((typeof message === "string" ? message : JSON.stringify(message)) + "\n"),
                end: () => child.stdin.end(), exited: () => bounded(exited, "shim exit"), stdout: () => stdout };
        };
        /** A raw socket client: the daemon side of the shim's wire. */
        w.raw = (contract = w.launch, { halfOpen = false } = {}) => {
            // A half-open peer keeps its side open after the bridge ends its own.
            const socket = net.createConnection({ path: contract.env.VGS_JARVIS_TOOLS_SOCKET, allowHalfOpen: halfOpen });
            socket.setEncoding("utf8");
            socket.on("error", () => {});
            const closed = new Promise(resolve => socket.on("close", resolve));
            owners.push(() => socket.destroy());
            const next = lineReader(socket, "socket line");
            return { socket, next, queued: next.queued, write: text => socket.write(text),
                closed: () => bounded(closed, "socket close"),
                connected: () => bounded(new Promise(resolve => socket.once("connect", resolve)), "socket connect") };
        };
        /** A shim through initialize and its notification. */
        w.ready = async options => {
            const c = w.shim(w.launch, options);
            c.send(initialize(1, "2025-11-25"));
            const answer = await c.next();
            assert.equal(answer.result.protocolVersion, "2025-11-25");
            c.send(initialized);
            return c;
        };
        return w;
    }
    function cleanup() { while (owners.length) owners.pop()(); }

    const initialize = (id, protocolVersion) => ({ jsonrpc: "2.0", id, method: "initialize",
        params: { protocolVersion, capabilities: {}, clientInfo: { name: "fixture-harness", version: "0" } } });
    const initialized = { jsonrpc: "2.0", method: "notifications/initialized" };
    const ping = id => ({ jsonrpc: "2.0", id, method: "ping" });
    const call = (id, name, args) => ({ jsonrpc: "2.0", id, method: "tools/call", params: { name, arguments: args } });
    const shell = { argv: ["fixture"], cwd: fixtures.project, network: false };
    for (const [schema, message] of [["InitializeRequest", initialize(1, "2025-11-25")], ["InitializedNotification", initialized],
        ["PingRequest", ping(1)], ["ListToolsRequest", { jsonrpc: "2.0", id: 3, method: "tools/list" }],
        ["CallToolRequest", call(1, "windows_list", {})], ["CallToolRequest", call(1, "shell_argv", shell)]])
        assert.deepEqual(Check.errors(excerpt, schema, message), [], schema + " fixture matches the pinned schema");
    function result(answer, schema) {
        assert.deepEqual(Check.errors(excerpt, "JSONRPCResultResponse", answer), [], "result envelope");
        assert.deepEqual(Check.errors(excerpt, schema, answer.result), [], schema);
        return answer.result;
    }
    function failure(answer, id, code) {
        assert.deepEqual(Check.errors(excerpt, "JSONRPCErrorResponse", answer), [], "error envelope");
        assert.equal(answer.id, id);
        assert.equal(answer.error.code, code);
    }
    function tool(answer, id, text, isError) {
        assert.equal(answer.id, id);
        assert.deepEqual(result(answer, "CallToolResult"), { content: [{ type: "text", text }], isError });
    }
    const refusal = reason => JSON.stringify({ kind: "refuse", reason });
    const shimEnv = (w, token) => ({ PATH: process.env.PATH, VGS_JARVIS_TOOLS_SOCKET: w.launch.env.VGS_JARVIS_TOOLS_SOCKET,
        ...(token === undefined ? {} : { VGS_JARVIS_TOOLS_TOKEN: token }) });

    const cases = [
        ["lifecycle", async folder => {
            const w = await make(folder);
            const c = w.shim();
            c.send(ping(0));
            assert.deepEqual(result(await c.next(), "EmptyResult"), {}, "ping is answered before initialize");
            c.send(initialize(1, "2025-11-25"));
            assert.deepEqual(result(await c.next(), "InitializeResult"), { protocolVersion: "2025-11-25",
                capabilities: { tools: {} }, serverInfo: { name: "vgs-jarvis", version: "1" } });
            c.send({ jsonrpc: "2.0", id: 2, method: "tools/list" });
            failure(await c.next(), 2, -32000);
            c.send(initialized);
            c.send({ jsonrpc: "2.0", id: 3, method: "tools/list" });
            const list = result(await c.next(), "ListToolsResult");
            // Registered: windows (hyprctl), files and sandbox (bwrap). Nothing else is offered.
            const expected = ["windows.list", "workspaces.list", "files.list", "files.read", "files.search", "files.write", "files.move",
                "files.delete", "shell.argv", "shell.line"];
            assert.deepEqual(list.tools.map(entry => entry.name), ["windows_list", "workspaces_list", "files_list", "files_read", "files_search",
                "files_write", "files_move", "files_delete", "shell_argv", "shell_line"]);
            for (const [index, entry] of list.tools.entries()) {
                assert.deepEqual(entry.inputSchema, JSON.parse(JSON.stringify(Tools.TABLE[expected[index]].schema)));
                assert.equal(entry.description, Tools.TABLE[expected[index]].sentence);
            }
            const previous = w.shim();
            previous.send(initialize(1, "2025-06-18"));
            assert.equal(result(await previous.next(), "InitializeResult").protocolVersion, "2025-06-18");
        }],
        ["allow", async folder => {
            const w = await make(folder);
            const c = await w.ready();
            c.send(call(10, "windows_list", {}));
            c.send(ping(11));
            assert.equal((await c.next()).id, 11, "the call is still running");
            assert.equal(w.starts.length, 1, "the call reached the stand-in executor");
            assert.equal(w.starts[0].call.id, "windows.list");
            assert.deepEqual([w.starts[0].audit.kind, w.starts[0].audit.tool, w.starts[0].audit.decision, w.starts[0].audit.outcome],
                ["action", "windows.list", "allow", "pending"], "the gate audited the decision before the start");
            w.answers[0]({ outcome: "completed", content: "fixture windows" });
            tool(await c.next(), 10, "fixture windows", false);
            const released = w.rows().at(-1);
            assert.deepEqual([released.kind, released.decision, released.outcome], ["release", "send", "pending"]);
            assert.deepEqual(w.brain, [], "a bridge result never reaches the brain port");
            const turn = w.runner.state.turn;
            w.router.route({ kind: "tool-call", id: "brain-call", tool: "windows.list", arguments: {} }, { gen: turn.gen, op: turn.op });
            w.answers[1]({ outcome: "completed", content: "brain windows" });
            assert.deepEqual(w.brain.map(value => value.results[0].id), ["brain-call"], "a brain call's result reaches the brain");
        }],
        ["confirm", async folder => {
            const w = await make(folder);
            const c = await w.ready();
            c.send(call(20, "shell_argv", shell));
            c.send(call(21, "windows_list", {}));
            tool(await c.next(), 21, refusal("busy"), true);
            assert.equal(w.runner.state.approval.kind, "held", "the gate holds the approval in Session state");
            assert.equal(w.starts.length, 0);
            assert.ok(w.rows().some(row => row.tool === "shell.argv" && row.decision === "confirm" && row.outcome === "pending"));
            w.show(); w.time(700); w.confirm();
            assert.equal(w.starts.length, 1);
            w.answers[0]({ outcome: "completed", content: "fixture ran" });
            tool(await c.next(), 20, "fixture ran", false);
        }],
        ["refuse", async folder => {
            const w = await make(folder);
            const c = await w.ready();
            w.lock(true);
            c.send(call(30, "windows_list", {}));
            tool(await c.next(), 30, refusal("session-locked"), true);
            c.send(call(31, "windows_list", { extra: 1 }));
            tool(await c.next(), 31, refusal("argument-shape"), true);
            assert.equal(w.starts.length, 0);
            assert.deepEqual(w.rows().filter(row => row.kind === "action").map(row => [row.decision, row.outcome]),
                [["refuse", "cancelled"], ["refuse", "cancelled"]]);
        }],
        ["tokens", async (folder, shim) => {
            const w = await make(folder);
            const wrong = w.shim(w.launch, { env: shimEnv(w, "0".repeat(64)), file: shim });
            wrong.end();
            assert.deepEqual(await wrong.exited(), { code: 1, signal: null, stderr: "mcp-shim: bridge=refused reason=token\n" });
            const missing = w.shim(w.launch, { env: shimEnv(w), file: shim });
            assert.deepEqual(await missing.exited(), { code: 64, signal: null, stderr: "mcp-shim: environment=VGS_JARVIS_TOOLS_TOKEN\n" });
            const token = w.launch.env.VGS_JARVIS_TOOLS_TOKEN;
            const queued = JSON.stringify(call(1, "windows_list", {})) + "\n";
            for (const [name, hello, reason] of [
                ["wrong", { v: 1, type: "hello", token: "f".repeat(64) }, "token"],
                ["shorter", { v: 1, type: "hello", token: token.slice(1) }, "token"],
                ["absent", { v: 1, type: "hello" }, "hello"],
                ["extra", { v: 1, type: "hello", token, extra: true }, "hello"],
                ["type", { v: 1, type: "call", token }, "hello"]
            ]) {
                const r = w.raw();
                r.write(JSON.stringify(hello) + "\n" + queued);
                assert.deepEqual(await r.next(), { v: 1, type: "refused", reason }, name);
                await r.closed();
            }
            const malformed = w.raw();
            malformed.write("not json\n");
            assert.deepEqual(await malformed.next(), { v: 1, type: "refused", reason: "hello" });
            assert.equal(w.starts.length, 0, "a refused connection starts nothing");
            assert.deepEqual(w.rows(), [], "a refused connection routes nothing to the audited gate");
            assert.deepEqual(w.brain, []);
            const good = await w.ready();
            good.send(ping(2));
            assert.deepEqual(result(await good.next(), "EmptyResult"), {}, "refusals leave the session usable");
        }],
        ["stale", async folder => {
            const w = await make(folder);
            const c = await w.ready();
            const gen = w.runner.state.gen;
            w.dispatch({ type: "stop" }); w.newTurn();
            assert.notEqual(w.runner.state.gen, gen);
            assert.equal(w.runner.state.turn.kind, "thinking", "a newer conversation has a live turn");
            c.send(call(40, "windows_list", {}));
            tool(await c.next(), 40, refusal("stale-turn"), true);
            const idle = await make(folder);
            const d = await idle.ready();
            const idleGen = idle.runner.state.gen;
            idle.dispatch({ type: "cancel" });
            assert.equal(idle.runner.state.gen, idleGen, "cancel keeps the session's generation");
            assert.notEqual(idle.runner.state.turn.kind, "thinking");
            d.send(call(41, "windows_list", {}));
            tool(await d.next(), 41, refusal("stale-turn"), true);
            assert.equal(w.starts.length + idle.starts.length, 0);
            assert.deepEqual([...w.rows(), ...idle.rows()].filter(row => row.kind !== "cleanup"), [], "nothing was routed");
        }],
        ["release", async folder => {
            const file = path.join(fixtures.project, "existing");
            for (const [network, text, decision] of [[true, "[withheld: file text]", "ask"], [false, "private file text", "send"]]) {
                const w = await make(folder, { network });
                const c = await w.ready();
                c.send(call(50, "files_read", { path: file }));
                c.send(ping(51));
                await c.next();
                w.answers[0]({ outcome: "completed", content: "private file text" });
                tool(await c.next(), 50, text, false);
                const released = w.rows().at(-1);
                assert.deepEqual([released.kind, released.decision, released.args],
                    ["release", decision, { labels: "[redacted]", recipients: "[redacted]" }]);
            }
        }],
        ["protocol", async folder => {
            const w = await make(folder);
            const c = await w.ready();
            c.send({ jsonrpc: "2.0", id: 60, method: "server/discover", params: {} });
            failure(await c.next(), 60, -32601);
            c.send("{");
            failure(await c.next(), undefined, -32700);
            c.send(call(61, "media_play", {}));
            failure(await c.next(), 61, -32602);
            c.send({ jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: 61 } });
            c.send(ping(62));
            assert.equal((await c.next()).id, 62, "a notification is never answered");
            assert.equal(w.starts.length, 0);
        }],
        ["bounds", async (folder, shim) => {
            const w = await make(folder);
            const hello = token => JSON.stringify({ v: 1, type: "hello", token }) + "\n";
            const token = w.launch.env.VGS_JARVIS_TOOLS_TOKEN;
            // Line: accepted at 256 KiB including its newline. One byte past it
            // after ready ends the connection without a line: stdout stays MCP.
            const padded = extra => {
                const base = JSON.stringify({ jsonrpc: "2.0", id: "", method: "ping" });
                return JSON.stringify({ jsonrpc: "2.0", id: "x".repeat(256 * 1024 - 1 - base.length + extra), method: "ping" }) + "\n";
            };
            assert.equal(Buffer.byteLength(padded(0)), 256 * 1024);
            const r = w.raw();
            r.write(hello(token));
            assert.deepEqual(await r.next(), { v: 1, type: "ready" });
            r.write(padded(0));
            assert.equal((await r.next()).result !== undefined, true, "a line at the bound is answered");
            r.write(padded(1));
            await r.closed();
            assert.equal(r.queued(), 0, "an MCP connection is ended without a bridge line");
            const c = await w.ready({ file: shim });
            c.send(ping(1));
            await c.next();
            c.child.stdin.write(padded(1));
            assert.deepEqual(await c.exited(), { code: 69, signal: null, stderr: "mcp-shim: bridge=closed\n" });
            const relayed = c.stdout().split("\n").filter(line => line !== "");
            assert.equal(relayed.length, 2, "initialize and ping answers");
            for (const line of relayed) assert.equal(JSON.parse(line).jsonrpc, "2.0", "the harness's stdout carries only MCP");
            // A refused peer that keeps its side open and keeps writing is still closed.
            const half = w.raw(w.launch, { halfOpen: true });
            half.write(hello("f".repeat(64)));
            assert.deepEqual(await half.next(), { v: 1, type: "refused", reason: "token" });
            // Its writes fail once the bridge destroyed its side. Polled: the
            // reset crosses the kernel, not this event loop.
            let reset = false;
            half.socket.on("error", () => { reset = true; });
            for (let tries = 0; tries < 200 && !reset; tries++) {
                half.write("x".repeat(4096));
                await new Promise(resolve => setTimeout(resolve, 10));
            }
            assert.equal(reset, true, "a refused half-open peer is destroyed, not left reading");
            // Connections: four half-open peers may wait for their hello; a fifth is refused.
            const waiting = [];
            for (let n = 0; n < 4; n++) {
                waiting.push(w.raw(w.launch, { halfOpen: true }));
                await waiting[n].connected();
                await until(() => w.helloTimers.size === n + 1, "connection " + (n + 1) + " accepted");
            }
            const fifth = w.raw();
            assert.deepEqual(await fifth.next(), { v: 1, type: "refused", reason: "connections" });
            // Hello deadline: 2 s each; a fired timer refuses and closes its peer.
            assert.deepEqual([...w.helloTimers].map(timer => timer.ms), [2000, 2000, 2000, 2000]);
            for (const timer of [...w.helloTimers]) timer.fn();
            for (const socket of waiting)
                assert.deepEqual(await socket.next(), { v: 1, type: "refused", reason: "hello-deadline" });
            const after = w.raw();
            after.write(hello(token));
            assert.deepEqual(await after.next(), { v: 1, type: "ready" }, "refused peers free their slots");
            assert.equal(w.starts.length, 0);
        }],
        ["close", async (folder, shim) => {
            const w = await make(folder);
            const socket = w.launch.env.VGS_JARVIS_TOOLS_SOCKET;
            assert.equal(socket, path.join(w.runtime, "tools.sock"));
            assert.equal(fs.lstatSync(socket).isSocket(), true);
            assert.equal(fs.statSync(socket).mode & 0o777, 0o600);
            assert.equal(fs.statSync(w.runtime).mode & 0o777, 0o700);
            assert.deepEqual(w.launch.args, [path.join(folder, "mcp-shim")]);
            assert.equal(w.launch.command, process.execPath);
            assert.deepEqual(Object.keys(w.launch.env), ["VGS_JARVIS_TOOLS_SOCKET", "VGS_JARVIS_TOOLS_TOKEN"]);
            await assert.rejects(w.open(), { message: "jarvis: bridge=session-open" }, "one session at a time");
            const eof = await w.ready({ file: shim });
            eof.end();
            assert.deepEqual(await eof.exited(), { code: 0, signal: null, stderr: "" }, "stdin EOF exits 0");
            const live = await w.ready({ file: shim });
            w.launch.close();
            assert.deepEqual(await live.exited(), { code: 69, signal: null, stderr: "mcp-shim: bridge=closed\n" });
            assert.equal(fs.existsSync(socket), false, "close removes the socket");
            w.launch.close();
            const late = w.shim(w.launch, { file: shim });
            assert.deepEqual(await late.exited(), { code: 69, signal: null, stderr: "mcp-shim: bridge=unavailable cause=ENOENT\n" });
            const again = await w.open();
            assert.notEqual(again.env.VGS_JARVIS_TOOLS_TOKEN, w.launch.env.VGS_JARVIS_TOOLS_TOKEN);
            const revoked = w.shim(again, { env: { PATH: process.env.PATH, VGS_JARVIS_TOOLS_SOCKET: socket,
                VGS_JARVIS_TOOLS_TOKEN: w.launch.env.VGS_JARVIS_TOOLS_TOKEN }, file: shim });
            assert.equal((await revoked.exited()).code, 1, "the closed session's token is refused");
            w.bridge.close();
            assert.equal(fs.existsSync(socket), false);
            await assert.rejects(w.open(), { message: "jarvis: bridge=closed" });
        }],
        ["runtime", async folder => {
            const target = path.join(process.env.JARVIS_TEST_ROOT, "real-" + ++serial);
            fs.mkdirSync(target);
            const alias = path.join(process.env.JARVIS_TEST_ROOT, "alias-" + serial);
            fs.symlinkSync(target, alias);
            const linked = await make(folder, { open: false, runtime: path.join(alias, "vgs") });
            await assert.rejects(linked.open(), { message: "jarvis: private=directory-type" });
            assert.deepEqual(fs.readdirSync(target), [], "nothing is created through a link");
            const file = await make(folder, { open: false });
            fs.mkdirSync(file.runtime, { recursive: true, mode: 0o755 });
            fs.chmodSync(file.runtime, 0o755);
            fs.writeFileSync(path.join(file.runtime, "tools.sock"), "not a socket");
            await assert.rejects(file.open(), { message: "jarvis: bridge=socket-type" });
            assert.equal(fs.readFileSync(path.join(file.runtime, "tools.sock"), "utf8"), "not a socket");
            assert.equal(fs.statSync(file.runtime).mode & 0o777, 0o700, "an existing runtime directory becomes private");
            // A daemon killed outright leaves its socket file behind.
            const stale = await make(folder, { open: false });
            fs.mkdirSync(stale.runtime, { recursive: true });
            const killed = cp.spawnSync(process.execPath, ["-e", "require('node:net').createServer().listen(process.argv[1], "
                + "() => process.kill(process.pid, 'SIGKILL'))", path.join(stale.runtime, "tools.sock")], { env: { PATH: process.env.PATH } });
            assert.equal(killed.signal, "SIGKILL");
            assert.equal(fs.lstatSync(path.join(stale.runtime, "tools.sock")).isSocket(), true);
            stale.launch = await stale.open();
            const c = await stale.ready();
            c.send(ping(1));
            assert.deepEqual(result(await c.next(), "EmptyResult"), {}, "a stale socket is replaced");
            // Socket path: 107 bytes accepted, 108 refused.
            const name = 107 - Buffer.byteLength(path.join(process.env.JARVIS_TEST_ROOT, "tools.sock")) - 1;
            assert.ok(name >= 1, "J09's socket guard leaves room for a 107-byte bridge socket");
            const edge = await make(folder, { open: false, runtime: path.join(process.env.JARVIS_TEST_ROOT, "e".repeat(name)) });
            const bound = await edge.open().catch(error => assert.fail("a 107-byte socket path is accepted: " + error.message));
            assert.equal(Buffer.byteLength(bound.env.VGS_JARVIS_TOOLS_SOCKET), 107);
            assert.equal(fs.lstatSync(bound.env.VGS_JARVIS_TOOLS_SOCKET).isSocket(), true);
            const past = await make(folder, { open: false, runtime: path.join(process.env.JARVIS_TEST_ROOT, "e".repeat(name + 1)) });
            await assert.rejects(past.open(), { message: "jarvis: bridge=socket-path" });
        }],
        ["dropped", async folder => {
            const w = await make(folder);
            const c = await w.ready();
            c.send(call(70, "shell_argv", shell));
            c.send(ping(71));
            await c.next();
            assert.equal(w.runner.state.approval.kind, "held");
            c.end();
            assert.equal((await c.exited()).code, 0);
            const before = w.rows().length;
            w.dispatch({ type: "cancel" });
            assert.equal(w.runner.state.approval.kind, "none");
            assert.deepEqual(w.brain, [], "a closed connection's result is dropped, not given to the brain");
            assert.deepEqual(w.rows().slice(before).filter(row => row.kind === "release"), [], "nothing is released to a closed connection");
            assert.ok(w.rows().slice(before).some(row => row.kind === "action" && row.decision === "refuse"), "the router still retires its hold");
        }],
        ["timeout", async folder => {
            const w = await make(folder);
            const c = await w.ready();
            c.send(call(80, "windows_list", {}));
            c.send(ping(81));
            await c.next();
            w.time(1000);
            w.dispatch({ type: "deadline", gen: w.runner.state.action.gen, op: w.runner.state.action.op });
            tool(await c.next(), 80, "tool-outcome:unknown", true);
            w.answers[0]({ outcome: "completed", content: "late" });
            assert.deepEqual(w.brain, [], "the actual completion of a timed-out bridge call stays with the bridge");
            c.send(ping(82));
            assert.equal((await c.next()).id, 82, "the late completion writes no second answer");
        }]
    ];
    const byName = name => cases.find(row => row[0] === name)[1];
    try {
        for (const [name, check] of cases) {
            try { await check(backend, undefined); } finally { cleanup(); }
            console.log("case=" + name + " passed");
        }
        // The real cases' teardown must release every listener, socket and
        // child. Killed shims close their pipes asynchronously, so poll.
        const released = () => JSON.stringify(held()) === JSON.stringify(baseline);
        for (let tries = 0; tries < 200 && !released(); tries++) await new Promise(resolve => setTimeout(resolve, 10));
        assert.deepEqual(held(), baseline, "the bridge and its shims hold nothing after teardown");
        let controls = 0;
        const control = async (file, name, needle, replacement, row) => {
            await mutant(file, name, needle, replacement, async (_module, folder) => {
                try { await byName(row)(folder, undefined); } finally { cleanup(); }
            }, "ToolBridge.js");
            controls++;
            console.log("control=" + name + " detected");
        };
        for (const [name, needle, replacement, row] of [
            ["token", "!crypto.timingSafeEqual(digest(message.token), current.digest)", "false", "tokens"],
            ["hello-shape", 'Object.keys(message).sort().join(",") !== "token,type,v"', "false", "tokens"],
            ["router-gate", "router.route({ kind: \"tool-call\", id, tool: names.get(act.name), arguments: act.arguments },\n            { gen: s.turn.gen, op: s.turn.op });",
                "deliver({ gen: s.gen, op: s.turn.op, outcome: \"completed\", results: [{ id, item: Policy.item(\"bypassed\", [\"desktop\"]) }] });", "allow"],
            ["brain-results", "if (entry === undefined) return false;", "if (entry === undefined) return true;", "allow"],
            ["gen-binding", "s.gen !== current.gen || ", "", "stale"],
            ["release", "Policy.release(answer.item, entry.recipients)", "({ kind: \"send\", ...answer.item })", "release"],
            ["release-audit", "const admitted = audit.before(",
                "const admitted = ({ before: (event, start) => ({ kind: \"started\", value: start() }) }).before(", "release"],
            ["is-error", 'value.outcome !== "completed"', "false", "refuse"],
            ["unknown-tool", 'if (!names.has(act.name)) { write(connection, Mcp.error(act.id, Mcp.CODES.params, "Unknown tool")); return; }', "", "protocol"],
            ["socket-type", 'if (!stat.isSocket() || stat.uid !== process.getuid()) fail("socket-type");', "void stat;", "runtime"],
            ["socket-path", "Buffer.byteLength(socketPath) > SOCKET_PATH_BYTES", "false", "runtime"],
            ["line-raised", "const LINE_BYTES = 256 * 1024;", "const LINE_BYTES = 256 * 1024 + 1;", "bounds"],
            ["line-lowered", "const LINE_BYTES = 256 * 1024;", "const LINE_BYTES = 256 * 1024 - 1;", "bounds"],
            ["connections", "const CONNECTIONS = 4;", "const CONNECTIONS = 5;", "bounds"],
            ["hello-deadline", 'connection.timer = clock.set(() => refuse(connection, "hello-deadline"), HELLO_MS);', "connection.timer = null;", "bounds"],
            ["one-session", 'if (session !== null) fail("session-open");', "", "close"],
            ["close-listener", "        current.server.close();\n", "", "close"],
            ["close-connections", "            connection.socket.destroy();\n", "", "close"],
            ["owner-closed", 'if (lifetime !== "open") fail("closed");', "", "close"],
            ["drop-closed", "if (entry.answered || entry.connection.closed) return true;", "if (entry.answered) return true;", "dropped"],
            ["final-delete", "if (value.final) pending.delete(answer.id);", "pending.delete(answer.id);", "timeout"],
            ["hello-delay", "const HELLO_MS = 2000;", "const HELLO_MS = 2001;", "bounds"],
            ["socket-path-edge", "Buffer.byteLength(socketPath) > SOCKET_PATH_BYTES", "Buffer.byteLength(socketPath) >= SOCKET_PATH_BYTES", "runtime"],
            // The refusal before this fix: half-closed, still in the session's set.
            ["refusal-closes", [["drop(connection);\n        connection.tail = \"\";", "connection.closed = true;"],
                [', () => socket.destroy());\n        else', ');\n        else']], null, "bounds"],
            ["mcp-refusal-silent", "else socket.end(() => socket.destroy());",
                'else socket.end(JSON.stringify({ v: 1, type: "refused", reason }) + "\\n", () => socket.destroy());', "bounds"]
        ]) await control(bridgeFile, name, needle, replacement, row);
        // The router alone marks a timeout not final; a final timeout loses the late completion.
        await control(path.join(backend, "ToolRouter.js"), "router-final", 'outcome, final, kind: "tool-results",', 'outcome, final: true, kind: "tool-results",', "timeout");
        // The shared private-directory owner, reached through the bridge.
        await control(privateFile, "runtime-links", 'if (!fs.lstatSync(current).isDirectory()) fail("directory-type");',
            'if (!fs.statSync(current).isDirectory()) fail("directory-type");', "runtime");
        await control(privateFile, "runtime-mode", "fs.chmodSync(target, 0o700);", "", "runtime");
        // The shim, on disposable copies started from the real launch contract.
        const shimSource = fs.readFileSync(shimFile, "utf8");
        for (const [name, needle, replacement, row] of [
            ["shim-refusal", "if (first !== READY) {", "if (false) {", "tokens"],
            ["shim-environment", 'if (!token) exit(64, "environment=VGS_JARVIS_TOOLS_TOKEN");', "", "tokens"],
            ["shim-eof", 'process.stdin.on("end", () => { phase = "ending"; });', "", "close"]
        ]) {
            assert.equal(shimSource.split(needle).length - 1, 1, name + " mutation match");
            const copy = path.join(fs.mkdtempSync(path.join(process.env.JARVIS_TEST_ROOT, "shim-")), "mcp-shim");
            fs.writeFileSync(copy, shimSource.replace(needle, replacement));
            await assert.rejects(async () => {
                try { await byName(row)(backend, copy); } finally { cleanup(); }
            }, assert.AssertionError, name + " must turn red");
            controls++;
            console.log("control=" + name + " detected");
        }
        console.log("test-jarvis-bridge: ok cases=" + cases.length + " controls=" + controls);
        // A control that removes close keeps its mutant listener alive; the
        // check above already proved the real owner's teardown.
        process.exit(0);
    } finally { cleanup(); }
})?.catch(error => { console.error(error); process.exitCode = 1; });
