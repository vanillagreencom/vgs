// The ACP harness brain: one agent program per conversation, started with the
// account's own directory so the vendor's program owns its login and its
// sockets. Jarvis hands it released text alone; the program's tools are its
// MCP access to the tool bridge and the actions whose permission requests
// pass HarnessGate. AcpClient is the protocol judge.
// Contract: docs/architecture/jarvis-acp.md.
"use strict";
const cp = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const Acp = require("./AcpClient.js");
const Policy = require("./Policy.js");
const Private = require("./Private.js");
const { childEnvironment } = require("./Secrets.js");

// One row per agent program, by provider id: its command, the variable that
// names its account directory, the name its initialize reports and the
// lowest version whose ACP server honours args. Copilot's built-ins are
// excluded by name as its 1.0.91 command reference lists them, and denied by
// permission kind beside that, so a built-in the list misses still cannot
// read, write, run or fetch. The bridge's tools run unprompted: the router
// is their gate. The user's instructions files and GitHub's own MCP servers
// stay unloaded.
const PROGRAMS = Object.freeze({
    copilot: Object.freeze({ command: "copilot", variable: "COPILOT_HOME", agent: "Copilot", floor: "1.0.60",
        args: Object.freeze(["--acp", "--stdio", "--no-auto-update", "--no-custom-instructions", "--no-ask-user",
            "--disable-builtin-mcps", "--disallow-temp-dir",
            "--excluded-tools", "bash", "powershell", "list_bash", "read_bash", "stop_bash", "write_bash", "view", "create",
            "edit", "apply_patch", "task", "list_agents", "read_agent", "write_agent", "ask_user", "glob", "grep", "rg",
            "skill", "web_fetch", "web_search",
            "--deny-tool", "shell", "write", "read", "url", "memory",
            "--allow-tool", Acp.SERVER]) })
});
// The plan's context bound in user turns, as the wire brains keep it.
const TURNS = 40;
// A program that never finishes its handshake is ended; the account's own
// configuration loads and the bridge's server starts inside this bound.
const HANDSHAKE_MS = 30000;
// After its stdin closes the program has this long to exit before KILL.
const CLOSE_MS = 2000;
// One Verify turn: a bound on a stalled provider, not a latency budget.
const PROBE_MS = 60000;
const PROBE_INSTRUCTIONS = "Answer in one word.";
// Tool kinds that name a built-in operation on the machine or the network.
// A call of one of them that runs must have asked the gate first. An MCP
// call reports "other"; a server other than the bridge asks too.
const BUILTIN = Object.freeze(["read", "edit", "delete", "move", "search", "execute", "fetch", "switch_mode"]);
const RAN = Object.freeze(["in_progress", "completed", "failed"]);

function fail(code) { throw new Error("jarvis: brain=acp-" + code); }

function row(provider) {
    if (typeof provider !== "string" || !Object.hasOwn(PROGRAMS, provider)) fail("program");
    return PROGRAMS[provider];
}

/**
 * Start the program and own its JSON-RPC connection. listener receives each
 * narrowed {kind: "notification", event} and {kind: "request", id, request},
 * and once {kind: "ended", error}. Every child, including setpriv's exec of
 * the agent, ends with the daemon.
 */
function program({ program: p, directory, env, cwd, model }, listener) {
    const args = ["--pdeathsig", "KILL", "--", p.command, ...p.args, ...(model === "" ? [] : ["--model", model])];
    const child = cp.spawn("setpriv", args, {
        cwd, env: { ...childEnvironment(env), [p.variable]: directory }, stdio: ["pipe", "pipe", "pipe"] });
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
    child.on("error", error => end(new Error("jarvis: brain=acp-start cause=" + (error.code ?? "unknown"))));
    child.on("close", (code, signal) => end(new Error("jarvis: brain=acp-exited code=" + code + " signal=" + signal)));
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
                receive(Acp.accept(line));
            }
            if (Buffer.byteLength(tail) >= Acp.LINE_BYTES) fail("line-size");
        } catch (error) { end(error); }
    });

    function receive(value) {
        switch (value.kind) {
        case "response": case "failure": {
            const call = calls.get(value.id);
            if (call === undefined) fail("response-id");
            calls.delete(value.id);
            if (value.kind === "response") call.resolve(value.result);
            // ACP's auth_required: the program is not signed in, and Jarvis never signs it in.
            else call.reject(new Error(value.code === -32000 ? "jarvis: brain=acp-signed-out"
                : "jarvis: brain=acp-refused method=" + call.method + " code=" + value.code));
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
        /** End the program with error; the turn it serves fails with it. */
        abort(error) { end(error); },
        /** Close stdin, the program's lease; KILL it if it outlives CLOSE_MS. */
        close() {
            if (ended === null) child.stdin.end();
            const timer = setTimeout(() => end(new Error("jarvis: brain=acp-closed")), CLOSE_MS);
            return exited.then(() => clearTimeout(timer));
        }
    };
}

/**
 * One session on one program, its agent judged before the first turn.
 * hooks: {event(event), request(id, request, session)} for the owner's turn
 * and permission handling, and ended(error).
 */
async function open({ program: p, directory, env, runtime, model, bridge }, hooks) {
    Private.directory(runtime);
    const cwd = fs.mkdtempSync(path.join(runtime, "acp-"));
    let session = null;
    const child = program({ program: p, directory, env, cwd, model }, value => {
        if (value.kind === "notification") hooks.event(value.event);
        // Before the session exists a request is answered on the bare program.
        else if (value.kind === "request") hooks.request(value.id, value.request, session ?? { program: child, id: null, cwd });
        // A handshake failure rejects its pending call instead.
        else if (session !== null) hooks.ended(value.error);
    });
    const timer = setTimeout(() => child.close(), HANDSHAKE_MS);
    try {
        Acp.agent(await child.call(id => Acp.initialize(id)), p);
        const id = Acp.sessionId(await child.call(n => Acp.sessionNew(n, { cwd, bridge })));
        session = { program: child, id, cwd };
        return session;
    } catch (error) {
        await child.close();
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
 * carries the engine's {provider, model, recipients} and the harness facts:
 * account (the agent's account directory), gen, and {bridge, gate, env,
 * runtime}. A harness turn yields no tool-call event: the program's tool
 * calls reach the router itself.
 */
function create({ provider, model, recipients, account, gen, harness }) {
    Policy.assertRecipients(recipients);
    const p = row(provider?.id);
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
            const opened = await open({ program: p, directory: account.directory, env, runtime: runtime(), model,
                bridge: launch }, { event, request, ended: error => { ended ??= error; active?.fault(error); } });
            if (closed) { await shut(opened); fail("closed"); }
            session = opened;
            return opened;
        })();
        return opening;
    }

    // A built-in operation the program runs without asking is one the lockdown
    // did not remove: the conversation ends and the brain is refused.
    function reported(turn, call) {
        const announced = turn.calls.get(call.id) ?? null;
        const merged = { ...announced, ...Object.fromEntries(Object.entries(call).filter(([, v]) => v !== null)) };
        turn.calls.set(call.id, merged);
        // An agent announces a call as pending before it asks; it runs once it reports progress.
        if (!BUILTIN.includes(merged.kind) || turn.asked.has(call.id) || !RAN.includes(merged.status)) return;
        const error = new Error("jarvis: brain=acp-builtin kind=" + merged.kind);
        ended ??= error;
        session.program.abort(error);
    }

    function event(e) {
        const turn = active;
        if (turn === null || session === null || e.sessionId !== session.id || !turn.requested) return;
        switch (e.kind) {
        case "text": turn.push({ kind: "text", text: e.text }); break;
        // Spoken replies are text; any other content block is not heard.
        case "content": break;
        case "tool-call": case "tool-update": {
            reported(turn, e.call);
            const waiter = turn.waiters.get(e.call.id);
            if (waiter !== undefined && (e.call.status === "completed" || e.call.status === "failed")) {
                turn.waiters.delete(e.call.id);
                waiter(e.call.status);
            }
            break;
        }
        case "other": break;
        default: fail("event-kind");
        }
    }

    function request(id, value, current) {
        const turn = active;
        switch (value.kind) {
        case "unsupported": current.program.write(Acp.answer(id, value, "cancelled")); return;
        case "permission": {
            if (turn === null || !turn.requested || value.sessionId !== current.id || value.allow === null) {
                current.program.write(Acp.answer(id, value, "reject"));
                return;
            }
            turn.asked.add(value.call.id);
            let answered = false;
            const once = choice => {
                if (answered) return;
                answered = true;
                turn.pending.delete(id);
                current.program.write(Acp.answer(id, value, choice));
            };
            // A cancelled turn answers every open request cancelled, as ACP requires.
            turn.pending.set(id, () => once("cancelled"));
            gate.ask(gen, Acp.proposal(value, turn.calls.get(value.call.id) ?? null, current.cwd), {
                decline: () => once("reject"),
                accept: () => {
                    once("allow");
                    return new Promise(resolve => turn.waiters.set(value.call.id, status => resolve({
                        outcome: status === "completed" ? "completed" : status === "failed" ? "failed" : "unknown",
                        content: JSON.stringify({ kind: "harness", status }) })));
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
        // requested: session/prompt is written, so only its stop reason
        // acknowledges a cancel. calls holds each reported tool call merged
        // across its updates; asked the ids whose permission request reached the gate.
        const current = { requested: false, calls: new Map(), asked: new Set(), waiters: new Map(), pending: new Map(),
            push(value) { queue.push(value); wake(); },
            complete(stop) {
                if (state.kind === "streaming") state = stop === "end_turn" ? { kind: "complete" }
                    : stop === "cancelled" ? { kind: "cancelled" } : { kind: "failed", error: new Error("jarvis: brain=acp-stop-" + stop) };
                settle();
            },
            fault(error) {
                if (state.kind === "streaming" || state.kind === "cancelling") state = { kind: "failed", error };
                settle();
            },
            cancel() {
                switch (state.kind) {
                case "unstarted": state = { kind: "cancelled" }; acknowledged(); break;
                case "streaming":
                    state = { kind: "cancelling" };
                    if (current.requested && session !== null) {
                        for (const cancelled of [...current.pending.values()]) cancelled();
                        session.program.write(Acp.cancel(session.id));
                    } else acknowledged();
                    wake();
                    break;
                default: break;
                }
                return finished.then(() => { if (active === current) active = null; });
            } };
        function settle() {
            for (const cancelled of [...current.pending.values()]) cancelled();
            for (const waiter of current.waiters.values()) waiter("unknown");
            current.waiters.clear();
            wake();
            acknowledged();
        }

        async function run() {
            try {
                if (labels.length === 0) fail("release-empty");
                const opened = await ensure();
                if (state.kind !== "streaming") return;
                // Instructions lead the first prompt: ACP has no system prompt.
                const texts = turns === 0 ? [instructions, text] : [text];
                turns++;
                current.requested = true;
                current.complete(Acp.stopReason(await opened.program.call(n => Acp.prompt(n, opened.id, texts))));
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
 * Account Verify's smallest real request: one prompt of text in a session
 * with no tools, through the vendor's own program. Resolves with the reply's
 * text; throws a keyed error when the program, the turn or the reply fails.
 * The caller owns release and audit.
 */
async function probe({ provider, directory, env, runtime, model, text }) {
    const p = row(provider);
    let session = null;
    let reply = "";
    let failed = null;
    const hooks = {
        event(e) { if (session !== null && e.sessionId === session.id && e.kind === "text") reply += e.text; },
        // A probe session offers no tool, so it admits no request.
        request(id, value, current) { current.program.write(Acp.answer(id, value, value.kind === "permission" ? "reject" : "cancelled")); },
        ended(error) { failed ??= error; }
    };
    let timer;
    try {
        // The handshake keeps its own bound; the deadline covers the turn.
        session = await open({ program: p, directory, env, runtime, model, bridge: null }, hooks);
        const deadline = new Promise((resolve, reject) => {
            timer = setTimeout(() => reject(new Error("jarvis: brain=acp-probe-deadline")), PROBE_MS);
        });
        const stop = await Promise.race([deadline,
            session.program.call(n => Acp.prompt(n, session.id, [PROBE_INSTRUCTIONS, text])).then(Acp.stopReason)]);
        if (failed !== null) throw failed;
        if (stop !== "end_turn") fail("stop-" + stop);
        if (reply.trim() === "") fail("no-reply");
        return reply;
    } finally {
        clearTimeout(timer);
        if (session !== null) await shut(session);
    }
}

module.exports = { create, probe };
