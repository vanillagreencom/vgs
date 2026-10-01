// One bounded child process: an argv without a shell, an explicit whole
// environment, a deadline, one byte ceiling over stdout and stderr together,
// cancellation and exactly one end. The kernel sandbox and the desktop
// executors decide what runs; this owner bounds only its lifetime and output.
"use strict";
const { spawn } = require("node:child_process");
const { StringDecoder } = require("node:string_decoder");

const CLOCK = { set: (fn, ms) => setTimeout(fn, ms), clear: timer => clearTimeout(timer) };

/**
 * Resolve exactly once, matched by kind, never truthiness:
 *   {kind:"exited", code, signal, stdout, stderr} after the child and its pipes closed;
 *   {kind:"stopped", reason, stdout, stderr} after this owner ended it, reason
 *     "timeout", "cancelled", "output-limit" or one attach passed to end;
 *   {kind:"error", reason:"spawn"|"input", error, stdout, stderr} when it
 *     never ran, or its stdin failed other than by the child closing it.
 * Options:
 *   env       the child's whole environment; nothing is inherited.
 *   limit     bytes of stdout and stderr together, counted as the decoded text
 *             the caller receives; past it the child is ended and the text cut.
 *   deadline  milliseconds from spawn until the child is ended.
 *   group     true: the child leads a new session and process group, and its
 *             end kills that whole group, including a forked descendant.
 *             false: its end kills the child alone, for a child that ends its
 *             own descendants (bwrap --die-with-parent).
 *   input     text written to stdin, then closed; absent, stdin is /dev/null.
 *   output    "pipe" collects stdout and stderr; "ignore" sends them to
 *             /dev/null, for a child that forks a server which must not hold
 *             this owner's pipes open after the child exits.
 *   extra     pipes after descriptor 2, wired by attach(child, end).
 *   signal    an AbortSignal; abort ends the child as "cancelled".
 *   clock     {set, clear} for the deadline.
 */
function run(file, argv, { env, limit, deadline, group, input, output = "pipe", extra = 0, attach, signal, clock = CLOCK }) {
    return new Promise(resolve => {
        if (signal && signal.aborted) { resolve({ kind: "stopped", reason: "cancelled", stdout: "", stderr: "" }); return; }
        let child = null;
        let stop = null;
        let error = null;
        let bytes = 0;
        const chunks = { stdout: [], stderr: [] };
        const end = reason => {
            if (stop !== null) return;
            stop = reason;
            if (child === null || child.pid === undefined) return;
            if (!group) { child.kill("SIGKILL"); return; }
            // The group also holds what the child forked and any member
            // that outlives it while holding a pipe.
            try { process.kill(-child.pid, "SIGKILL"); }
            catch (cause) { if (cause.code !== "ESRCH") throw cause; }
        };
        // Arm the deadline first: a clock that throws leaves no child behind.
        const timer = clock.set(() => end("timeout"), deadline);
        child = spawn(file, argv, { env, detached: group, stdio: [input === undefined ? "ignore" : "pipe",
            output, output, ...Array.from({ length: extra }, () => "pipe")] });
        const cancel = () => end("cancelled");
        if (signal) signal.addEventListener("abort", cancel, { once: true });
        const collect = (name, text) => {
            // Count the text the consumer receives. Invalid UTF-8 becomes a
            // replacement character, which can use more bytes than its input.
            const encoded = Buffer.from(text, "utf8");
            chunks[name].push(encoded.subarray(0, Math.max(0, limit - bytes)));
            bytes += encoded.length;
            if (bytes > limit) end("output-limit");
        };
        if (output === "pipe") {
            for (const name of ["stdout", "stderr"]) {
                const decoder = new StringDecoder("utf8");
                child[name].on("data", chunk => collect(name, decoder.write(chunk)));
                child[name].on("end", () => collect(name, decoder.end()));
            }
        }
        if (input !== undefined) {
            // A child may exit before it reads; its exit status is the answer.
            child.stdin.on("error", cause => {
                if (cause.code !== "EPIPE" && error === null) error = { reason: "input", error: cause.code || cause.message };
            });
            child.stdin.end(input);
        }
        if (attach !== undefined) attach(child, end);
        child.on("error", cause => { error = { reason: "spawn", error: cause.code || cause.message }; });
        child.on("close", (code, killed) => {
            clock.clear(timer);
            if (signal) signal.removeEventListener("abort", cancel);
            const text = Object.fromEntries(Object.entries(chunks).map(([key, parts]) =>
                [key, new TextDecoder().decode(Buffer.concat(parts), { stream: true })]));
            if (stop !== null) resolve({ kind: "stopped", reason: stop, ...text });
            else if (error !== null) resolve({ kind: "error", ...error, ...text });
            else resolve({ kind: "exited", code, signal: killed, ...text });
        });
    });
}

module.exports = { run };
