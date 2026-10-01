// One leased router owns serial calls, immutable approval snapshots and grants.
// Session judges confirmation; Policy judges actions; Audit gates each start.
"use strict";
const crypto = require("node:crypto");
const Tools = require("./Tools.js");
const Policy = require("./Policy.js");
const RESULT_BYTES = 16 * 1024;
const GRANT_SCOPES = 64;

function canonical(value) {
    if (Array.isArray(value)) return "[" + value.map(canonical).join(",") + "]";
    if (value !== null && typeof value === "object")
        return "{" + Object.keys(value).sort().map(key => JSON.stringify(key) + ":" + canonical(value[key])).join(",") + "}";
    return JSON.stringify(value);
}

function sentence(call, scope) {
    const text = Tools.TABLE[call.id].sentence.replace(/\{(\w+)\}/g, (_, field) => {
        const value = call.args[field];
        return value === undefined ? "default" : typeof value === "string" ? value : canonical(value);
    });
    return scope === undefined ? text : text + "\nAllow input in " + scope + " for this conversation. Jarvis can act as you there.";
}

/**
 * create({session, state, dispatch, context, audit, result}) owns the daemon's
 * action lifetime. state/dispatch belong to SessionRunner. context returns
 * current trusted profile, locked and denied facts, never model metadata.
 * result receives {gen, op, outcome, final, kind:"tool-results", results:[{id,item}]};
 * final is false only for a timeout whose actual completion is still to come.
 * A generation change clears grants. Each new turn starts with clean taint.
 */
function create({ session, state, dispatch, context, audit, result }) {
    const registry = new Map();
    let pending = null;
    let grants = new Set();
    let generation = null;
    let turnOp = null;
    let taint = { kind: "clean" };
    let closed = false;

    function sync(s) {
        if (generation !== s.gen || s.conversation.kind === "ended") {
            grants = new Set();
            generation = s.gen;
        }
        if (s.turn.kind === "thinking" && turnOp !== s.turn.op) {
            turnOp = s.turn.op;
            taint = { kind: "clean" };
        }
    }

    function record(value, decision, outcome) {
        return audit.record({ kind: "action", gen: value.turn.gen, op: value.turn.op,
            tool: value.call.id, args: value.call.args, effect: value.decision?.effect ?? null,
            decision, confirmed: value.confirmed ?? "none", outcome });
    }

    // final is false only while Session still holds a timed-out action, whose
    // actual completion delivers again under the same call id.
    function deliver(value, outcome, content, source = null, final = true) {
        const s = state();
        if (source !== null && s.gen === value.turn.gen && s.turn.kind === "thinking" && s.turn.op === value.turn.op)
            taint = Policy.observe(taint, source);
        const bytes = Buffer.from(content);
        const bounded = bytes.length <= RESULT_BYTES ? content
            : new TextDecoder().decode(bytes.subarray(0, RESULT_BYTES - 32), { stream: true }) + "\n[result clipped]";
        result({ gen: value.turn.gen, op: value.turn.op, outcome, final, kind: "tool-results",
            results: [{ id: value.request, item: Policy.item(bounded, [source ?? "desktop"]) }] });
    }

    function refuse(value, reason, final = true) {
        const written = record(value, "refuse", "cancelled");
        const refusal = { kind: "refuse", reason: written.kind === "refuse" ? written.reason : reason };
        deliver(value, "cancelled", JSON.stringify(refusal), null, final);
        return refusal;
    }

    function judge(value) {
        const facts = context();
        return Policy.decide(value.call, { profile: facts.profile, locked: facts.locked,
            denied: facts.denied, taint, grants: [...grants],
            input: value.executor.observe === undefined ? undefined : value.executor.observe(value.call) });
    }

    /**
     * Executor owners register once after confinement and command probes pass.
     * commands lists commands actually present. start(call, done) receives a
     * frozen {id,args}; done is {outcome:"completed"|"failed"|"unknown",content}.
     * Input executors supply observe(call) for fresh trusted target/key facts.
     */
    function register(id, executor) {
        if (closed || registry.has(id) || !Object.values(Tools.TABLE).some(row => row.executor === id)
                || typeof executor.start !== "function" || !Number.isFinite(executor.timeoutMs) || executor.timeoutMs <= 0
                || typeof executor.cancellable !== "boolean" || !Array.isArray(executor.commands)
                || !executor.commands.every(command => typeof command === "string")
                || (executor.cancellable && typeof executor.cancel !== "function")
                || (executor.observe !== undefined && typeof executor.observe !== "function"))
            throw new Error("jarvis: router=executor");
        registry.set(id, Object.freeze({ ...executor, commands: Object.freeze(executor.commands.slice()) }));
    }

    function available(refined) {
        const executor = registry.get(refined.executor);
        return executor !== undefined && (refined.command === null || executor.commands.includes(refined.command)) ? executor : null;
    }

    function offer() {
        if (closed) return [];
        return Object.entries(Tools.TABLE).filter(([, row]) => available(row) !== null)
            .map(([id, row]) => ({ id, description: row.sentence, parameters: structuredClone(row.schema) }));
    }

    /** Route only brain tool calls. There is deliberately no confirmation API. */
    function route(request, turn) {
        const value = { request: request.id, call: { id: request.tool, args: request.arguments }, turn };
        if (!Number.isSafeInteger(turn.gen) || turn.gen < 0 || !Number.isSafeInteger(turn.op) || turn.op < 1)
            throw new Error("jarvis: router=turn");
        if (closed) return refuse(value, "router-closed");
        // Arriving calls cannot outrun Session's monotonic deadline judge.
        dispatch({ type: "deadline", gen: turn.gen, op: turn.op });
        const s = state();
        if (s.gen !== turn.gen || s.turn.kind !== "thinking" || s.turn.gen !== turn.gen || s.turn.op !== turn.op)
            return refuse(value, "stale-turn");
        // pending reserves a proposal queued by a synchronous runner callback.
        if (!session.canPropose(s) || pending !== null) return refuse(value, "busy");
        const refined = Tools.refine(value.call);
        if (refined.kind === "refuse") return refuse(value, refined.reason);
        value.call = refined.call;
        value.refined = refined;
        value.executor = available(refined);
        if (value.executor === null) return refuse(value, "executor-unavailable");
        const decision = judge(value);
        value.decision = decision;
        if (decision.kind === "refuse") return refuse(value, decision.reason);
        if (decision.scope !== undefined && !grants.has(decision.scope) && grants.size >= GRANT_SCOPES)
            return refuse(value, "grant-limit");
        const id = crypto.randomUUID();
        value.id = id;
        pending = value;
        const proposal = { gen: turn.gen, op: turn.op, id, tool: value.call.id,
            timeoutMs: value.executor.timeoutMs, cancellable: value.executor.cancellable };
        switch (decision.kind) {
        case "allow":
            dispatch({ type: "tool", ...proposal });
            return { kind: "proposed", id };
        case "confirm": {
            const digest = crypto.createHash("sha256").update(value.call.id + "\n" + canonical(value.call.args)).digest("hex");
            const text = sentence(value.call, decision.scope);
            if (Buffer.byteLength(text) > RESULT_BYTES) { pending = null; return refuse(value, "approval-size"); }
            const written = record(value, "confirm", "pending");
            if (written.kind === "refuse") { pending = null; return refuse(value, written.reason); }
            dispatch({ type: "approval", ...proposal, digest, text, physical: decision.physical });
            return { kind: "held", id, digest };
        }
        default: throw new Error("jarvis: router=decision");
        }
    }

    function start(e, done) {
        const value = pending;
        if (value === null || value.id !== e.id) throw new Error("jarvis: router=start-identity");
        const fresh = judge(value);
        const prior = value.decision;
        const accepted = e.confirmed !== undefined;
        const authorized = fresh.kind === "allow" && fresh.effect === prior.effect
            || accepted && fresh.kind === "confirm" && fresh.effect === prior.effect
                && fresh.physical === prior.physical && fresh.scope === prior.scope;
        if (!authorized) {
            value.refusal = fresh.kind === "refuse" ? fresh.reason : "policy-changed";
            done("failed");
            return;
        }
        value.confirmed = !accepted ? "none" : e.confirmed === "voice" ? "voice" : "physical";
        value.action = { gen: e.gen, op: e.op };
        const admitted = audit.before({ kind: "action", gen: value.turn.gen, op: value.turn.op,
            tool: value.call.id, args: value.call.args, effect: fresh.effect, decision: prior.kind,
            confirmed: value.confirmed, outcome: "pending" }, () => {
            if (accepted && prior.scope !== undefined) grants.add(prior.scope);
            try {
                value.executor.start(value.call, answer => {
                    if (closed) return;
                    if (!answer || !["completed", "failed", "unknown"].includes(answer.outcome) || typeof answer.content !== "string")
                        throw new Error("jarvis: router=outcome");
                    value.answer = answer;
                    done(answer.outcome);
                });
            } catch (error) {
                value.answer = { outcome: "failed", content: "executor-failed" };
                done("failed");
            }
        });
        if (admitted.kind === "refuse") {
            value.refusal = admitted.reason;
            done("failed");
        }
    }

    function outcome(e) {
        const value = pending;
        if (value === null || value.turn.gen !== e.gen || value.turn.op !== e.target)
            throw new Error("jarvis: router=outcome-identity");
        // Unknown timeout retains Session's serial slot until actual completion.
        const final = state().action.kind === "none";
        if (value.refusal !== undefined) refuse(value, value.refusal, final);
        else {
            const written = record(value, value.decision.kind, e.outcome);
            deliver(value, e.outcome, written.kind === "refuse" ? JSON.stringify(written)
                : value.answer?.content ?? "tool-outcome:" + e.outcome, value.refined.source, final);
        }
        if (final) pending = null;
    }

    const ports = {
        tools: { sync, start, outcome,
            cancel() { if (pending !== null) pending.executor.cancel(pending.call); },
            close() {
                if (closed) return;
                audit.cleanup("teardown", () => {
                    if (pending !== null) {
                        record(pending, pending.decision.kind, "unknown");
                        pending = null;
                    }
                    closed = true;
                    grants.clear();
                    registry.clear();
                });
            } },
        approval: {
            show() {},
            end(e) {
                if (pending === null || pending.id !== e.id) throw new Error("jarvis: router=approval-identity");
                refuse(pending, e.reason);
                pending = null;
            },
            refused(e) {
                const value = pending !== null && pending.id === e.id ? pending
                    : { turn: { gen: e.gen, op: e.op }, call: { id: "unknown", args: {} } };
                const written = record(value, "refuse", "cancelled");
                if (written.kind === "refuse")
                    throw new Error("jarvis: audit=write cause=" + written.cause);
            }
        }
    };
    return Object.freeze({ register, offer, route, ports });
}

module.exports = { create };
