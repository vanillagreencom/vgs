// The action judge only. J19 routes and holds; J21 records; J22 releases
// outbound data; J23 confines programs. The daemon exposes no tools yet.
"use strict";
const Tools = require("./Tools.js");

/** @typedef {{kind: "clean"}|{kind: "tainted"}} Taint */
/** @typedef {import("./Tools.js").Effect} Effect */
/** @typedef {{kind: "allow", effect: Effect}|{kind: "confirm", effect: Effect, physical: boolean, scope?: string}|{kind: "refuse", reason: string}} Decision */

const PROFILES = {
    cautious: { read: "allow", reversible: "allow", input: "confirm", persistent: "confirm", exec: "confirm", external: "confirm", destructive: "physical" },
    standard: { read: "allow", reversible: "allow", input: "application", persistent: "allow", exec: "confirm", external: "confirm", destructive: "physical" },
    trusted: { read: "allow", reversible: "allow", input: "allow", persistent: "allow", exec: "allow", external: "confirm", destructive: "physical" }
};
const SOURCES = ["speech", "desktop", "clipboard", "file", "screen", "web", "command", "agent"];
const TAINT_SOURCES = ["file", "screen", "web", "agent"];

/** J11 owns the turn. J19 calls observe only after content reaches that turn. */
function observe(taint, source) {
    if (!taint || !["clean", "tainted"].includes(taint.kind) || !SOURCES.includes(source))
        throw new Error("jarvis: taint=invalid");
    return { kind: taint.kind === "tainted" || TAINT_SOURCES.includes(source) ? "tainted" : "clean" };
}

function chord(value) {
    return value && Array.isArray(value.modifiers)
        && value.modifiers.every(mod => typeof mod === "string" && mod !== "")
        && new Set(value.modifiers).size === value.modifiers.length
        && Number.isSafeInteger(value.keycode) && value.keycode > 0;
}

function sameChord(left, right) {
    return left.keycode === right.keycode
        && left.modifiers.slice().sort().join(",") === right.modifiers.slice().sort().join(",");
}

/**
 * Decide one model call using executor-owned facts.
 *
 * context: {profile, locked, taint, denied, input?, grants?}. Missing or
 * unknown lock refuses. denied is Denied.create's current snapshot.
 * J47/J51 supply input {target:{kind,id,password?}, key?} at send time.
 * For a key, key is {request, chord, effective}, where chord and effective
 * are layout-resolved {modifiers, keycode} records. J47 uses the core key
 * judge, then resolves symbols against the live keymap. A literal comparison
 * cannot distinguish keycode/symbol aliases. A missing resolution refuses.
 * grants are J19-owned application/site ids for this conversation only.
 *
 * Allow is not an execution permit: J19 must also enforce held-action
 * serialization, approval and J21's pre-action audit. Rejudge fresh targets
 * and paths before execution. No digest, timer or approval matching lives here.
 * @param {unknown} call
 * @returns {Decision}
 */
function decide(call, context) {
    if (!context || context.locked !== false) return { kind: "refuse", reason: "session-locked" };
    if (!Object.hasOwn(PROFILES, context.profile)) return { kind: "refuse", reason: "policy-profile" };
    if (!context.taint || !["clean", "tainted"].includes(context.taint.kind))
        return { kind: "refuse", reason: "turn-taint" };
    const refined = Tools.refine(call);
    if (refined.kind === "refuse") return refined;
    let effect = refined.effect;
    for (const [field, role] of refined.paths) {
        if (!context.denied || typeof context.denied.inspect !== "function")
            return { kind: "refuse", reason: "path-context" };
        const target = context.denied.inspect(refined.call.args[field], role);
        if (target.kind === "refuse") return target;
        if (target.execution || role === "remove" || (role === "write" && target.exists))
            effect = "destructive";
    }
    let scope = null;
    if (refined.input !== null) {
        const input = context.input;
        if (!input || !input.target || !["application", "terminal", "site", "vgs", "lock", "polkit"].includes(input.target.kind))
            return { kind: "refuse", reason: "input-target" };
        if (["vgs", "lock", "polkit"].includes(input.target.kind))
            return { kind: "refuse", reason: "protected-target" };
        if (typeof input.target.id !== "string" || input.target.id === "")
            return { kind: "refuse", reason: "input-identity" };
        if (refined.input === "browser") {
            if (input.target.kind !== "site") return { kind: "refuse", reason: "browser-target" };
            if (input.target.password !== false) return { kind: "refuse", reason: "password-target" };
        } else if (input.target.kind === "site") return { kind: "refuse", reason: "desktop-target" };
        // J47 keys and pointer calls can enter or paste commands without
        // showing their text. Only the explicit text tool can hold that text.
        if (input.target.kind === "terminal" && refined.input !== "text")
            return { kind: "refuse", reason: "terminal-input" };
        if (refined.input === "key") {
            const key = input.key;
            if (!key || key.request !== call.args.chord || !chord(key.chord)
                    || !Array.isArray(key.effective) || !key.effective.every(chord))
                return { kind: "refuse", reason: "key-context" };
            if (key.effective.some(bound => sameChord(key.chord, bound)))
                return { kind: "refuse", reason: "jarvis-chord" };
        }
        if (refined.input === "text" && input.target.kind === "terminal") {
            if (context.profile !== "trusted") return { kind: "refuse", reason: "terminal-text" };
            effect = "destructive";
        }
        if (input.target.kind !== "terminal") scope = input.target.kind + ":" + input.target.id;
    }
    const rule = PROFILES[context.profile][effect];
    if (rule === "physical") return { kind: "confirm", effect, physical: true };
    if (context.taint.kind === "tainted" && ["persistent", "exec", "input", "external"].includes(effect))
        return { kind: "confirm", effect, physical: false };
    if (rule === "confirm") return { kind: "confirm", effect, physical: false };
    if (rule === "application") {
        if (!Array.isArray(context.grants) || !context.grants.every(grant => typeof grant === "string"))
            return { kind: "refuse", reason: "input-grants" };
        if (!context.grants.includes(scope)) return { kind: "confirm", effect, physical: false, scope };
        return { kind: "allow", effect };
    }
    if (rule === "allow") return { kind: "allow", effect };
    throw new Error("jarvis: policy=unhandled-effect");
}

module.exports = { decide, observe };
