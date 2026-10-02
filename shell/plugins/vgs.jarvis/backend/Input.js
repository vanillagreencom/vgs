// Synthetic input owns no Hyprland reader: core capabilities supply fresh
// targets and layout identities through ShellRequests. No device is opened.
"use strict";
const cp = require("node:child_process");
const Tools = require("./Tools.js");

/** create({request,environment,commands}) owns command children and observations.
 * wtype's single-key map emits raw XKB code 9 (atx/wtype main.c upload_keymap).
 * Core also resolves that code in the global translation map: Hyprland resolves symbols against its
 * native map when resolve_binds_by_sym is false. Policy judges text's generated
 * codes and symbols, including possible held physical modifiers.
 * ydotool debug connects its existing daemon socket and emits no input event
 * (ReimuNotMoe/ydotool Client/ydotool.c). It never starts a daemon.
 */
function create({ request, environment, commands, timeoutMs = 2000 }) {
    let closed = false;
    const children = new Set();
    const observations = new WeakMap();
    function command(name, args) {
        return new Promise((resolve, reject) => {
            if (closed) { reject(new Error("input-closed")); return; }
            const child = cp.execFile(name, args, { env: environment, encoding: "utf8", timeout: timeoutMs,
                maxBuffer: 16384, killSignal: "SIGKILL" }, (error, stdout) => {
                children.delete(child);
                if (error) {
                    const failure = new Error("input-command:" + name);
                    failure.deliveryPossible = child.pid !== undefined;
                    reject(failure);
                } else resolve(stdout);
            });
            children.add(child);
        });
    }
    function ask(kind, args, checkpoint) {
        return new Promise(resolve => request(kind, args, timeoutMs, resolve)).then(reply => {
            if (closed) throw new Error("input-closed");
            if (checkpoint !== undefined) checkpoint();
            if (reply.kind !== "answer" || reply.answer !== "ok")
                throw new Error(reply.kind === "answer" ? reply.answer : "input-request:" + reply.kind);
            return reply.data;
        });
    }
    let pointer = commands.includes("wlrctl") ? "wlrctl" : null;
    async function ready() {
        const offered = [];
        if (commands.includes("wtype")) {
            try { await command("wtype", ["--", ""]); offered.push("wtype"); }
            catch { /* No keys are emitted by the empty-text readiness probe. */ }
        }
        if (pointer === "wlrctl") {
            try { await command("wlrctl", ["pointer", "scroll", "0", "0"]); }
            catch { pointer = null; }
        }
        if (pointer === null && commands.includes("ydotool")) {
            try { await command("ydotool", ["debug"]); pointer = "ydotool"; }
            catch { pointer = null; }
        }
        return offered.concat(pointer === null ? [] : [pointer]);
    }
    async function observe(call, checkpoint) {
        const a = call.args;
        if (call.id === "input.text" && Buffer.byteLength(a.text) > 4096) return { refusal: "input-size" };
        const isPointer = call.id === "input.click" || call.id === "input.scroll";
        if (isPointer && pointer === "ydotool") {
            try { await command("ydotool", ["debug"]); }
            catch { return { refusal: "input-daemon-unavailable" }; }
            if (checkpoint !== undefined) checkpoint();
        }
        try {
            const input = {};
            if (!isPointer) {
                const resolved = await ask("input.keys", call.id === "input.key" ? [a.chord, "code:9"] : ["code:9"], checkpoint);
                const offset = call.id === "input.key" ? 2 : 1;
                const effective = resolved.keys.slice(offset);
                if (call.id === "input.text") input.text = { effective: effective.concat(resolved.translation.slice(offset)) };
                else {
                    const chord = resolved.keys[0], raw = resolved.translation[1];
                    input.key = { request: a.chord, chord, effective,
                        emitted: { ...raw, modifiers: chord.modifiers },
                        emittedEffective: resolved.translation.slice(offset) };
                    input.keysym = chord.keysym;
                }
            }
            // Read the target last, after XKB resolution. A slow keymap read
            // must not retain the earlier window or keyboard focus.
            const fact = await ask("input.observe", isPointer ? [a.x, a.y] : [], checkpoint);
            input.target = fact.target; input.cursor = fact.cursor;
            observations.set(call, input);
            return input;
        } catch (error) { return { refusal: error.message }; }
    }
    function argv(call, input) {
        const a = call.args;
        if (call.id === "input.text") return ["wtype", ["--", a.text]];
        if (call.id === "input.key") {
            const names = { SUPER: "logo", CTRL: "ctrl", ALT: "alt", SHIFT: "shift" };
            const modifiers = input.key.chord.modifiers.map(mod => names[mod]);
            return ["wtype", modifiers.flatMap(mod => ["-M", mod]).concat(["-k", input.keysym],
                modifiers.slice().reverse().flatMap(mod => ["-m", mod]))];
        }
        if (pointer === "wlrctl") return [pointer, call.id === "input.click" ? ["pointer", "click", a.button]
            : ["pointer", "scroll", String(a.direction === "down" ? a.steps : a.direction === "up" ? -a.steps : 0),
                String(a.direction === "right" ? a.steps : a.direction === "left" ? -a.steps : 0)]];
        if (pointer === "ydotool") return [pointer, call.id === "input.click" ? ["click", { left: "0xC0", right: "0xC1", middle: "0xC2" }[a.button]]
            : ["mousemove", "--wheel", "-x", String(a.direction === "right" ? a.steps : a.direction === "left" ? -a.steps : 0),
                "-y", String(a.direction === "up" ? a.steps : a.direction === "down" ? -a.steps : 0)]];
        throw new Error("input-pointer-unavailable");
    }
    async function send(call, authorize) {
        let input = observations.get(call);
        if (input === undefined || input.refusal !== undefined) throw new Error("input-unobserved");
        if (typeof authorize !== "function") throw new Error("input-authority");
        const checkpoint = () => {
            const answer = authorize(input);
            if (answer.kind !== "allow") throw new Error(answer.reason);
        };
        if (Tools.refine(call).input === "pointer") {
            await ask("compositor.moveCursor", [call.args.x, call.args.y], checkpoint);
            const prior = input;
            input = await observe(call, checkpoint);
            if (input.refusal !== undefined) throw new Error(input.refusal);
            if (JSON.stringify(input.target) !== JSON.stringify(prior.target)) throw new Error("input-target-changed");
            if (input.cursor.x !== call.args.x || input.cursor.y !== call.args.y) throw new Error("input-cursor-unverified");
        }
        const [name, args] = argv(call, input);
        checkpoint();
        try { await command(name, args); }
        catch (error) {
            if (!error.deliveryPossible) throw error;
            return { outcome: "unknown", content: "Input transport did not finish. Delivery may be partial: " + error.message };
        }
        // Delivery already happened. A failed readback cannot turn it into
        // a failed action that a caller could safely retry.
        let detail;
        try {
            const after = await ask("input.observe", Tools.refine(call).input === "pointer" ? [call.args.x, call.args.y] : []);
            detail = "Read back target: " + after.target.id + ".";
        } catch (error) { detail = "Readback unavailable: " + error.message + "."; }
        return { outcome: "unknown", content: "Input was sent. The application effect is not observable. " + detail };
    }
    const record = { commands: [], timeoutMs: 20000, cancellable: false, observe,
        start(call, done, authorize) { send(call, authorize).then(done, error => done({ outcome: "failed", content: error.message })); } };
    return { record, ready: async () => { record.commands = await ready(); return record; },
        close() { closed = true; for (const child of children) child.kill("SIGKILL"); } };
}

module.exports = { create };
