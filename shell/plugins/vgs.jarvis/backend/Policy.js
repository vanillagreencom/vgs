// The action and release judges. Routing, approvals, audit and confinement
// belong to their separate owners.
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
const SOURCES = Object.freeze(["speech", "desktop", "clipboard", "file", "screen", "web", "command", "agent"]);
const TAINT_SOURCES = ["file", "screen", "web", "agent"];
const recipientSets = new WeakSet();

function labels(value) {
    if (!Array.isArray(value) || value.length === 0 || !value.every(source => SOURCES.includes(source)))
        throw new Error("jarvis: release=labels");
    return Object.freeze(SOURCES.filter(source => value.includes(source)));
}

/** Copy a producer's labelled text or bytes. Tool sources come from Tools.refine. */
function item(content, sources) {
    if (typeof content !== "string" && !(content instanceof Uint8Array))
        throw new Error("jarvis: release=content");
    return Object.freeze({ content: typeof content === "string" ? content : Buffer.from(content), labels: labels(sources) });
}

/** The session's summarizer retains every contributing source for the conversation. */
function summary(content, items) {
    if (!Array.isArray(items) || items.length === 0)
        throw new Error("jarvis: release=summary");
    return item(content, items.flatMap(value => labels(value.labels)));
}

/**
 * Freeze one whole conversation recipient set, never one transfer's destination.
 * The session creates a new set when provider, account or policy changes and
 * closes its old net owner. Grants reference this exact set, not its text ids.
 * brain and each speech entry: {kind:"local"|"network", provider, account, origin?}.
 * A harness with cloud inference is network, even though its vendor owns sockets.
 */
function recipients({ conversation, profile, cloudVision, brain, speech }) {
    if (typeof conversation !== "string" || conversation === "" || !Object.hasOwn(PROFILES, profile)
            || !["ask", "allow", "never"].includes(cloudVision))
        throw new Error("jarvis: release=context");
    if (!Array.isArray(speech) || speech.length === 0)
        throw new Error("jarvis: release=speech-recipients");
    function recipient(value) {
        if (!value || !["local", "network"].includes(value.kind)
                || typeof value.provider !== "string" || value.provider === "" || typeof value.account !== "string")
            throw new Error("jarvis: release=recipient");
        if (value.kind === "local") {
            if (value.origin !== undefined) throw new Error("jarvis: release=local-origin");
            return Object.freeze({ kind: "local", provider: value.provider, account: value.account });
        }
        const target = require("./net.js").endpoint(value.origin);
        if (value.origin !== target.origin) throw new Error("jarvis: release=recipient-origin");
        return Object.freeze({ kind: "network", provider: value.provider, account: value.account, origin: target.origin });
    }
    const selectedBrain = recipient(brain);
    const selectedSpeech = Object.freeze(speech.map(recipient));
    const offline = [selectedBrain, ...selectedSpeech].every(value =>
        value.kind === "local" || require("./net.js").endpoint(value.origin).loopback);
    const result = Object.freeze({ conversation, profile, cloudVision,
        brain: selectedBrain, speech: selectedSpeech, offline });
    recipientSets.add(result);
    return result;
}

/** Check the session-owned set without reimplementing its shape in transports. */
function assertRecipients(value) {
    if (!recipientSets.has(value)) throw new Error("jarvis: release=recipient-set");
}

/**
 * Judge a transfer against brain AND speech. Conversation-local grants are
 * {recipients, labels}, issued only by the user approval owner. A new immutable
 * set invalidates old grants, including an identical selection in a new session.
 * Non-send answers contain a marker, never the withheld original bytes.
 * @returns {{kind:"send"|"withhold", content:string|Buffer, labels:readonly string[]}|{kind:"ask", content:string, labels:readonly string[], needed:readonly string[]}}
 */
function release(value, selected, grants = []) {
    assertRecipients(selected);
    const current = item(value.content, value.labels);
    if (!Array.isArray(grants)) throw new Error("jarvis: release=grants");
    for (const grant of grants) {
        if (!grant || !recipientSets.has(grant.recipients)) throw new Error("jarvis: release=grant-context");
        labels(grant.labels);
    }
    if (selected.offline) return { kind: "send", ...current };
    const marker = "[withheld: " + current.labels.map(source => source === "file" ? "file text" : source + " content").join(", ") + "]";
    if (current.labels.includes("screen") && selected.cloudVision === "never")
        return { kind: "withhold", content: marker, labels: current.labels };
    const missing = current.labels.filter(source => {
        if (source === "speech" || source === "desktop") return false;
        if (source === "screen" && selected.cloudVision === "allow") return false;
        if (source !== "screen" && selected.profile === "trusted") return false;
        return !grants.some(grant => grant.recipients === selected && grant.labels.includes(source));
    });
    if (missing.length !== 0) return { kind: "ask", content: marker, labels: current.labels, needed: Object.freeze(missing) };
    return { kind: "send", ...current };
}

/** Session owns the turn. The router observes only content reaching that turn. */
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
        // Hyprland ORs modifiers from physical and virtual keyboards. The
        // public read-only interfaces expose no held physical mask.
        && left.modifiers.every(mod => right.modifiers.includes(mod));
}

function textChord(bound, symbols) {
    // wtype assigns raw XKB codes from 9 in distinct-character order. Its
    // symbol map remaps newline to Return, tab to Tab and escape to Escape.
    return bound.modifiers.length === 0
        || bound.keycode >= 9 && bound.keycode < 9 + symbols.length
        || bound.codepoint !== 0 && symbols.some(symbol =>
            symbol.toLowerCase() === String.fromCodePoint(bound.codepoint).toLowerCase());
}

/**
 * Decide one model call using executor-owned facts.
 *
 * context: {profile, locked, taint, denied, input?, grants?}. Missing or
 * unknown lock refuses. denied is Denied.create's current snapshot.
 * J47/J51 supply input {target:{kind,id,password?}, key?} at send time.
 * For a key, key is {request, chord, effective, emitted, emittedEffective}.
 * Each identity is a layout-resolved {modifiers, keycode} record. J47 uses the core key
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
        // A field holds one path, or a list a harness program proposes at once.
        for (const file of [refined.call.args[field]].flat()) {
            const target = context.denied.inspect(file, role);
            if (target.kind === "refuse") return target;
            if (target.execution || role === "remove" || (role === "write" && target.exists))
                effect = "destructive";
        }
    }
    // A program's own command escapes Sandbox.js, as text typed at a terminal does.
    if (refined.unconfined) {
        if (context.profile === "trusted") effect = "destructive";
        else return { kind: "refuse", reason: "unconfined-command" };
    }
    let scope = null;
    if (refined.input !== null) {
        const input = context.input;
        if (input && typeof input.refusal === "string") return { kind: "refuse", reason: input.refusal };
        if (!input || !input.target || !["application", "terminal", "site", "vgs", "lock", "polkit"].includes(input.target.kind))
            return { kind: "refuse", reason: "input-target" };
        if (["vgs", "lock", "polkit"].includes(input.target.kind))
            return { kind: "refuse", reason: "protected-target" };
        if (typeof input.target.id !== "string" || input.target.id === "")
            return { kind: "refuse", reason: "input-identity" };
        if (refined.input === "browser") {
            if (input.target.kind !== "site") return { kind: "refuse", reason: "browser-target" };
            if (input.target.password !== false) return { kind: "refuse", reason: "password-target" };
            if (input.target.submit === true) effect = "external";
        } else if (input.target.kind === "site") return { kind: "refuse", reason: "desktop-target" };
        // J47 keys and pointer calls can enter or paste commands without
        // showing their text. Only the explicit text tool can hold that text.
        if (input.target.kind === "terminal" && refined.input !== "text")
            return { kind: "refuse", reason: "terminal-input" };
        if (refined.input === "key") {
            const key = input.key;
            if (!key || key.request !== call.args.chord || !chord(key.chord)
                    || !Array.isArray(key.effective) || !key.effective.every(chord)
                    || !chord(key.emitted) || !Array.isArray(key.emittedEffective) || !key.emittedEffective.every(chord))
                return { kind: "refuse", reason: "key-context" };
            if (key.effective.some(bound => sameChord(key.chord, bound)))
                return { kind: "refuse", reason: "jarvis-chord" };
            if (key.emittedEffective.some(bound => sameChord(key.emitted, bound)))
                return { kind: "refuse", reason: "jarvis-chord" };
        }
        if (refined.input === "text" && input.target.kind === "terminal") {
            if (context.profile !== "trusted") return { kind: "refuse", reason: "terminal-text" };
            effect = "destructive";
        }
        if (refined.input === "text") {
            if (!input.text || !Array.isArray(input.text.effective) || !input.text.effective.every(bound => chord(bound)
                    && Number.isSafeInteger(bound.codepoint) && bound.codepoint >= 0 && bound.codepoint <= 0x10ffff
                    && !(bound.codepoint >= 0xd800 && bound.codepoint <= 0xdfff)))
                return { kind: "refuse", reason: "text-context" };
            // Model text travels through Node's UTF-8 encoder; an unpaired
            // surrogate becomes U+FFFD before wtype reads it.
            const symbols = [...new Set(Buffer.from(call.args.text).toString("utf8"))]
                .map(symbol => symbol === "\n" ? "\r" : symbol);
            if (input.text.effective.some(bound => textChord(bound, symbols)))
                return { kind: "refuse", reason: "own-shortcut" };
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

module.exports = { decide, observe, item, summary, recipients, assertRecipients, release };
