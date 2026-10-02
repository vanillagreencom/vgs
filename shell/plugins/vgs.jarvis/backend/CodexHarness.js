// The Codex harness brain: one `codex app-server` per conversation, started
// with the account's CODEX_HOME so the vendor's program owns its login and its
// sockets. Jarvis hands it released text alone; the program's tools are its
// MCP access to the tool bridge and the actions whose approval requests pass
// HarnessGate. CodexAppServer is the protocol judge.
// Contract: docs/architecture/jarvis-codex.md.
"use strict";
const cp = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const Codex = require("./CodexAppServer.js");
const Policy = require("./Policy.js");
const Private = require("./Private.js");
const { childEnvironment } = require("./Secrets.js");

// The plan's context bound in user turns, as the wire brains keep it. Past it
// the brain refuses with the wire brains' key, which the engine ends cleanly on.
const TURNS = 40;
// A program that never finishes its handshake is ended; the account's own
// configuration loads and its MCP servers start inside this bound.
const HANDSHAKE_MS = 30000;
// After its stdin closes the program has this long to exit before KILL.
const CLOSE_MS = 2000;
// One Verify turn: a bound on a stalled provider, not a latency budget.
const PROBE_MS = 60000;
const PROBE_INSTRUCTIONS = "Answer in one word.";

function fail(code) { throw new Error("jarvis: brain=codex-" + code); }

/**
 * Start the program and own its JSON-RPC connection. listener receives each
 * narrowed {kind: "notification", event} and {kind: "request", id, request},
 * and once {kind: "ended", error}. Every child, including setpriv's exec of
 * codex, ends with the daemon.
 */
function program({ directory, env, cwd }, listener) {
    const child = cp.spawn("setpriv", ["--pdeathsig", "KILL", "--", "codex", "app-server", "--listen", "stdio://"], {
        cwd, env: { ...childEnvironment(env), CODEX_HOME: directory }, stdio: ["pipe", "pipe", "pipe"] });
    const calls = new Map();
    let next = 1;
    let tail = "";
    let ended = null;
    const exited = new Promise(resolve => child.once("close", resolve));

    function end(error) {
        if (ended !== null) return;
        ended = error;
        for (const call of calls.values()) call.reject(error);
        calls.clear();
        if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
        listener({ kind: "ended", error });
    }
    child.on("error", error => end(new Error("jarvis: brain=codex-start cause=" + (error.code ?? "unknown"))));
    child.on("close", (code, signal) => end(new Error("jarvis: brain=codex-exited code=" + code + " signal=" + signal)));
    child.stdin.on("error", () => {});
    // The program's log can hold conversation text; it is read and dropped.
    child.stderr.resume();
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", chunk => {
        if (ended !== null) return;
        tail += chunk;
        try {
            let index;
            while (ended === null && (index = tail.indexOf("\n")) >= 0) {
                const line = tail.slice(0, index);
                tail = tail.slice(index + 1);
                receive(Codex.accept(line));
            }
            if (Buffer.byteLength(tail) >= Codex.LINE_BYTES) fail("line-size");
        } catch (error) { end(error); }
    });

    function receive(value) {
        switch (value.kind) {
        case "response": case "failure": {
            const call = calls.get(value.id);
            if (call === undefined) fail("response-id");
            calls.delete(value.id);
            if (value.kind === "response") call.resolve(value.result);
            else call.reject(new Error("jarvis: brain=codex-refused method=" + call.method + " code=" + value.code));
            return;
        }
        case "notification": case "request": listener(value); return;
        default: fail("message-kind");
        }
    }
    function write(message) {
        if (ended === null) child.stdin.write(JSON.stringify(message) + "\n");
    }
    return {
        /** Send build(id) and resolve with the program's result. */
        call(build) {
            if (ended !== null) return Promise.reject(ended);
            const id = next++;
            const message = build(id);
            return new Promise((resolve, reject) => {
                calls.set(id, { method: message.method, resolve, reject });
                write(message);
            });
        },
        write,
        /** Close stdin, the program's lease; KILL it if it outlives CLOSE_MS. */
        close() {
            if (ended === null) child.stdin.end();
            const timer = setTimeout(() => end(new Error("jarvis: brain=codex-closed")), CLOSE_MS);
            return exited.then(() => clearTimeout(timer));
        }
    };
}

/**
 * One thread on one program, locked down and verified before its first turn.
 * hooks: {event(event), request(id, request, session)} for the owner's
 * turn and approval handling, and ended(error).
 */
async function open({ directory, env, runtime, model, instructions, bridge }, hooks) {
    Private.directory(runtime);
    const cwd = fs.mkdtempSync(path.join(runtime, "codex-"));
    let session = null;
    const p = program({ directory, env, cwd }, value => {
        if (value.kind === "notification") hooks.event(value.event);
        // Before the thread exists a request is answered on the bare program.
        else if (value.kind === "request") hooks.request(value.id, value.request, session ?? { program: p, thread: null });
        // A handshake failure rejects its pending call instead.
        else if (session !== null) hooks.ended(value.error);
    });
    const timer = setTimeout(() => p.close(), HANDSHAKE_MS);
    try {
        await p.call(id => Codex.initialize(id));
        p.write(Codex.initialized());
        const foreign = Codex.servers(await p.call(id => Codex.configRead(id, cwd)));
        const thread = Codex.thread(await p.call(id => Codex.threadStart(id, { cwd, model, instructions, foreign, bridge })));
        Codex.features(await p.call(id => Codex.featureList(id, thread)));
        session = { program: p, thread, cwd };
        return session;
    } catch (error) {
        await p.close();
        fs.rmSync(cwd, { recursive: true, force: true });
        throw error;
    } finally { clearTimeout(timer); }
}

async function shut(session) {
    await session.program.close();
    fs.rmSync(session.cwd, { recursive: true, force: true });
}

/**
 * The conversation's brain, behind the plan's interface: start, send as a
 * stream of text and done, cancel with an acknowledgement, and close. options
 * carries the engine's {model, recipients} and the harness facts: account (a
 * Codex directory), gen, and {bridge, gate, env, runtime}. A harness turn
 * yields no tool-call event: the program's tool calls reach the router itself.
 */
function create({ model, recipients, account, gen, harness }) {
    Policy.assertRecipients(recipients);
    if (!account || account.kind !== "cli" || typeof account.directory !== "string") fail("account");
    if (!harness) fail("unwired");
    const { bridge, gate, env, runtime } = harness;
    let instructions = null;
    let opening = null;
    let launch = null;
    let session = null;
    let turns = 0;
    let active = null;
    let closed = false;
    let ended = null;

    function usable() {
        if (closed) fail("closed");
        if (active !== null) fail("busy");
        if (ended !== null) throw ended;
    }

    function start(value) {
        usable();
        if (typeof value.instructions !== "string") fail("instructions");
        instructions = value.instructions;
    }

    // One program per conversation, with the bridge session of its generation.
    function ensure() {
        if (opening === null) opening = (async () => {
            launch = await bridge.open({ gen, recipients });
            // A close during the open found no launch to end.
            if (closed) { launch.close(); fail("closed"); }
            const opened = await open({ directory: account.directory, env, runtime: runtime(), model,
                instructions, bridge: launch }, { event, request, ended: error => { ended ??= error; active?.fault(error); } });
            if (closed) { await shut(opened); fail("closed"); }
            session = opened;
            return opened;
        })();
        return opening;
    }

    // The turn's announced items: an approval request names one by id.
    function event(e) {
        const turn = active;
        if (turn === null || session === null || e.threadId !== session.thread) return;
        if (e.kind === "turn-started" && turn.id === null) turn.id = e.turnId;
        if (e.turnId !== turn.id) return;
        switch (e.kind) {
        case "delta": turn.push({ kind: "text", text: e.delta }); break;
        case "item-started": turn.items.set(e.item.id, e.item); break;
        case "item-completed": {
            turn.items.set(e.item.id, e.item);
            const waiter = turn.waiters.get(e.item.id);
            if (waiter !== undefined) { turn.waiters.delete(e.item.id); waiter(e.item); }
            break;
        }
        case "error": break;
        case "turn-completed": turn.complete(e.status); break;
        case "turn-started": case "other": break;
        default: fail("event-kind");
        }
    }

    function request(id, value, current) {
        const respond = admitted => current.program.write(Codex.answer(id, value, admitted));
        const turn = active;
        switch (value.kind) {
        case "elicitation":
            // The bridge routes the call that follows; any other server's is declined.
            respond(value.toolCall && value.server === Codex.SERVER && value.threadId === current.thread);
            return;
        case "unsupported": respond(false); return;
        case "file-change": case "command": case "permissions": {
            if (turn === null || value.threadId !== current.thread || value.turnId !== turn.id) { respond(false); return; }
            let answered = false;
            const once = admitted => { if (!answered) { answered = true; respond(admitted); } };
            gate.ask(gen, Codex.proposal(value, turn.items.get(value.itemId) ?? null), {
                decline: () => once(false),
                accept: () => {
                    once(true);
                    return new Promise(resolve => turn.waiters.set(value.itemId, item => resolve({
                        outcome: item.status === "completed" ? "completed"
                            : ["failed", "declined"].includes(item.status) ? "failed" : "unknown",
                        content: JSON.stringify({ kind: "harness", status: item.status }) })));
                }
            });
            return;
        }
        default: fail("request-kind");
        }
    }

    function send(turn, grants = []) {
        usable();
        if (instructions === null) fail("not-started");
        if (turn?.kind !== "user") fail("turn");
        if (!Array.isArray(turn.items) || turn.items.length === 0 || (turn.images ?? []).length !== 0) fail("turn");
        if (turns >= TURNS) throw new Error("jarvis: brain=context-limit");
        const sent = [], withheld = new Set(), needed = new Set();
        const text = turn.items.map(item => {
            if (!item || typeof item.content !== "string") fail("item-text");
            const decision = Policy.release(item, recipients, grants);
            if (decision.kind === "send") sent.push(item);
            else if (decision.kind === "ask") for (const label of decision.needed) needed.add(label);
            else for (const label of decision.labels) withheld.add(label);
            return decision.content;
        }).join("\n\n");
        const labels = [...new Set(sent.flatMap(item => item.labels))];
        const release = Object.freeze({ withheld: Object.freeze([...withheld]), needed: Object.freeze([...needed]),
            labels: Object.freeze(labels) });

        const queue = [];
        let wake = () => {};
        let state = { kind: "unstarted" };
        let acknowledged;
        const finished = new Promise(resolve => { acknowledged = resolve; });
        // requested: turn/start is written, so only the program's completion
        // acknowledges a cancel.
        const current = { id: null, requested: false, items: new Map(), waiters: new Map(),
            push(value) { queue.push(value); wake(); },
            complete(status) {
                if (state.kind === "streaming") state = status === "completed" ? { kind: "complete" }
                    : status === "interrupted" ? { kind: "cancelled" } : { kind: "failed", error: new Error("jarvis: brain=codex-turn-" + status) };
                for (const waiter of current.waiters.values()) waiter({ status: "unknown" });
                current.waiters.clear();
                wake();
                acknowledged();
            },
            fault(error) {
                if (state.kind === "streaming") state = { kind: "failed", error };
                wake();
                acknowledged();
            },
            cancel() {
                switch (state.kind) {
                case "unstarted": state = { kind: "cancelled" }; acknowledged(); break;
                case "streaming":
                    state = { kind: "cancelling" };
                    if (current.id !== null && session !== null)
                        session.program.call(id => Codex.turnInterrupt(id, session.thread, current.id)).catch(() => {});
                    else if (!current.requested) acknowledged();
                    wake();
                    break;
                default: break;
                }
                return finished.then(() => { if (active === current) active = null; });
            } };

        async function run() {
            try {
                if (labels.length === 0) fail("release-empty");
                const opened = await ensure();
                if (state.kind !== "streaming") return;
                turns++;
                current.requested = true;
                const id = Codex.turnId(await opened.program.call(n => Codex.turnStart(n, opened.thread, text)));
                if (current.id === null) current.id = id;
                else if (current.id !== id) fail("turn-id");
                if (state.kind === "cancelling") opened.program.call(n => Codex.turnInterrupt(n, opened.thread, id)).catch(() => {});
            } catch (error) { current.fault(error); }
        }
        const events = {
            [Symbol.asyncIterator]() { return this; },
            async next() {
                if (state.kind === "unstarted") {
                    state = { kind: "streaming" };
                    run();
                }
                for (;;) {
                    if (queue.length !== 0 && state.kind !== "cancelled" && state.kind !== "cancelling")
                        return { value: queue.shift(), done: false };
                    switch (state.kind) {
                    case "streaming": break;
                    case "complete":
                        state = { kind: "ended" };
                        if (active === current) active = null;
                        return { value: { kind: "done", reason: "stop" }, done: false };
                    case "cancelled": case "cancelling":
                        state = { kind: "ended" };
                        if (active === current) active = null;
                        throw new Error("jarvis: brain=cancelled");
                    case "failed": {
                        const error = state.error;
                        state = { kind: "ended" };
                        if (active === current) active = null;
                        throw error;
                    }
                    case "ended": return { value: undefined, done: true };
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
        return Object.freeze({ release, events });
    }

    return Object.freeze({ start, send,
        /** A harness turn is never answered by tool results. */
        record() { fail("record"); },
        cancel() { return active === null ? Promise.resolve() : active.cancel(); },
        close() {
            if (closed) return;
            closed = true;
            active?.cancel();
            launch?.close();
            if (session !== null) void shut(session);
            session = null;
        } });
}

/**
 * Account Verify's smallest real request: one turn of text on a thread with
 * no tools, through the vendor's own program. Resolves with the reply's
 * text; throws a keyed error when the program, the turn or the reply fails.
 * The caller owns release and audit.
 */
async function probe({ directory, env, runtime, model, text }) {
    let session = null;
    let turn = null;
    let reply = "";
    let settle;
    const done = new Promise((resolve, reject) => { settle = { resolve, reject }; });
    // The turn's failure is read at `await done`. After an earlier throw, the
    // program's end during shut() rejects it too, and that throw is the outcome.
    done.catch(() => {});
    const hooks = {
        event(e) {
            if (session === null || e.threadId !== session.thread) return;
            if (e.kind === "turn-started" && turn === null) turn = e.turnId;
            if (e.turnId !== turn) return;
            if (e.kind === "delta") reply += e.delta;
            else if (e.kind === "item-completed" && e.item.kind === "message") reply = e.item.text;
            else if (e.kind === "turn-completed")
                if (e.status === "completed") settle.resolve(); else settle.reject(new Error("jarvis: brain=codex-turn-" + e.status));
        },
        // A probe thread offers no tool, so it admits no request.
        request(id, value, current) { current?.program.write(Codex.answer(id, value, false)); },
        ended(error) { settle.reject(error); }
    };
    const timer = setTimeout(() => settle.reject(new Error("jarvis: brain=codex-probe-deadline")), PROBE_MS);
    try {
        session = await open({ directory, env, runtime, model, instructions: PROBE_INSTRUCTIONS, bridge: null }, hooks);
        const id = Codex.turnId(await session.program.call(n => Codex.turnStart(n, session.thread, text)));
        turn ??= id;
        await done;
        if (reply.trim() === "") fail("no-reply");
        return reply;
    } finally {
        clearTimeout(timer);
        if (session !== null) await shut(session);
    }
}

module.exports = { create, probe };
