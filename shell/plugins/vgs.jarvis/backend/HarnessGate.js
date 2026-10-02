// One owner per daemon for the approval requests a harness brain's own
// program sends before it acts. Each reaches the router as an approval of a
// harness row, so Policy, the held approval and the pre-action audit judge it
// as they judge a brain's tool call. The router's executor here only tells the
// program to proceed and reports how its own action ended.
// Contract: docs/architecture/jarvis-codex.md.
"use strict";
const crypto = require("node:crypto");

// A program's file change or command ends well inside the shell tool's bound.
const TIMEOUT_MS = 120000;

/**
 * A port answers one program request: accept() tells the program to proceed
 * and resolves with {outcome, content} once its action ends; decline() refuses.
 * @typedef {{accept(): Promise<{outcome: "completed"|"failed"|"unknown", content: string}>, decline(): void}} Port
 */

/**
 * create({router, state}) owns the router's "harness" executor and the
 * requests pending in the router. state returns the runner's Session state.
 */
function create({ router, state }) {
    // Router call id -> {call, port, started, answered}. The one judge of
    // whether a router result answers a program request, and of which request
    // a start is for: the router holds one call at a time and refuses every
    // other one finally, so exactly one unanswered request matches the call.
    const pending = new Map();
    let closed = false;

    const executor = Object.freeze({ commands: [], timeoutMs: TIMEOUT_MS, cancellable: false,
        start(call, done) {
            const matches = [...pending.values()].filter(entry => !entry.started && !entry.answered
                && entry.call.id === call.id && JSON.stringify(entry.call.args) === JSON.stringify(call.args));
            if (matches.length !== 1) throw new Error("jarvis: gate=start-identity");
            const [entry] = matches;
            entry.started = true;
            entry.port.accept().then(done, () => done({ outcome: "unknown", content: "harness-request-failed" }));
        } });

    /**
     * Route one program request for the conversation of generation gen. A
     * request outside that conversation's live thinking turn is declined
     * without reaching the router, as the bridge refuses a stale call.
     * @param {number} gen
     * @param {{tool: string, arguments: object}} proposal from the harness's judge
     * @param {Port} port
     */
    function ask(gen, proposal, port) {
        const s = state();
        if (closed || s.gen !== gen || s.turn.kind !== "thinking") { port.decline(); return { kind: "refuse", reason: "stale-turn" }; }
        const id = "harness-" + crypto.randomUUID();
        const entry = { call: { id: proposal.tool, args: proposal.arguments }, port, started: false, answered: false };
        // Registered first: the router delivers a refusal before route
        // returns, and may start an allowed call before it does.
        pending.set(id, entry);
        return router.route({ kind: "approval", id, tool: proposal.tool, arguments: proposal.arguments },
            { gen: s.turn.gen, op: s.turn.op });
    }

    /**
     * The router's result port asks here before the bridge and the brain.
     * Returns whether the value answers a program request. A refusal of a
     * request whose action never started declines it.
     */
    function deliver(value) {
        const [answer] = value.results;
        const entry = pending.get(answer.id);
        if (entry === undefined) return false;
        if (value.final) pending.delete(answer.id);
        if (!entry.started && !entry.answered) {
            entry.answered = true;
            entry.port.decline();
        }
        return true;
    }

    return Object.freeze({ executor, ask, deliver,
        /** Daemon teardown: later requests are declined. Idempotent. */
        close() {
            closed = true;
            pending.clear();
        } });
}

module.exports = { create };
