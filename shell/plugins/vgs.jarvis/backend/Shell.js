// Router adapter for kernel-confined commands. Sandbox owns every child and
// its bounds; this owner binds readiness, abort and results to the service lease.
"use strict";
const path = require("node:path");
const Sandbox = require("./Sandbox.js");
const Denied = require("./Denied.js");
const { Accounts } = require("./Accounts.js");
const Guidance = require("./Guidance.js");

/** Trusted metadata producer shared by Policy and the kernel sandbox. */
function roots(environment, directories, install) {
    const accounts = new Accounts(directories.state, environment);
    return () => ({ home: accounts.home, config: accounts.config, data: accounts.data,
        state: environment.XDG_STATE_HOME || path.join(accounts.home, ".local/state"),
        runtime: environment.XDG_RUNTIME_DIR, install,
        accountRoots: accounts.candidates().map(candidate => candidate.directory) });
}

function answer(result) {
    let outcome;
    switch (result.kind) {
    case "exited": outcome = result.code === 0 ? "completed" : "failed"; break;
    case "stopped": outcome = "unknown"; break;
    case "refused":
    case "unavailable":
    case "error": outcome = "failed"; break;
    default: throw new Error("jarvis: shell=result-kind");
    }
    // The status precedes output so router clipping never hides an exit or
    // timeout. The router supplies the command label and outbound release.
    const { stdout, stderr, ...status } = result;
    return { outcome, content: JSON.stringify(status) + (stdout === undefined ? ""
        : "\n" + JSON.stringify({ stdout, stderr })) };
}

/**
 * install({router, roots, status, failed, clock?}) registers commands only
 * after the real sandbox probe and protected-root construction succeed.
 * status receives {kind:"checking"|"available"|"unavailable", reason?}.
 * refresh repeats readiness on a core requirement scan and withdraws offers
 * while checking. roots is a fresh trusted producer, never model arguments. close aborts
 * both readiness and the serial command and suppresses late publication.
 */
function install({ router, roots: currentRoots, status, failed, clock }) {
    let closed = false;
    let active = null;
    let probe = null;
    let readiness = { kind: "checking" };
    let registered = false;
    const executor = {
        available: () => !closed && readiness.kind === "available",
        commands: ["bwrap"], timeoutMs: Sandbox.BOUNDS.timeoutMs, cancellable: true,
        start(call, done) {
            if (closed) { done(answer({ kind: "refused", reason: "shell-closed" })); return; }
            if (active !== null) throw new Error("jarvis: shell=serial-slot");
            const abort = new AbortController();
            active = abort;
            let request, trusted;
            try {
                trusted = currentRoots();
                request = { cwd: call.args.cwd, network: call.args.network,
                    argv: call.id === "shell.line" ? ["/bin/sh", "-c", call.args.line] : call.args.argv };
            } catch (error) {
                active = null;
                done(answer({ kind: "error", reason: "protected-roots", error: error.code || error.message }));
                return;
            }
            Sandbox.run(request, trusted, { signal: abort.signal, clock }).then(result => {
                active = null;
                if (!closed) done(answer(result));
            }).catch(failed);
        },
        cancel() { if (active !== null) active.abort(); }
    };
    // Help explains shell confinement even when the host cannot provide it.
    // Guidance is the one bounded reader; missing families fail explicitly.
    router.register("guidance", { commands: [], timeoutMs: Sandbox.BOUNDS.timeoutMs, cancellable: false,
        start(call, done) {
            try { done({ outcome: "completed", content: Guidance.help(call.args.topic) }); }
            catch (error) { done({ outcome: "failed", content: error.message }); }
        } });
    function refresh() {
        if (closed) return Promise.resolve();
        if (probe !== null) probe.abort();
        const acquired = new AbortController();
        probe = acquired;
        readiness = { kind: "checking" };
        status(readiness);
        return (async () => {
            try { Denied.create(currentRoots()); }
            catch { return { kind: "unavailable", reason: "protected-roots" }; }
            return Sandbox.available({ signal: acquired.signal, clock });
        })().then(result => {
            if (closed || probe !== acquired) return;
            switch (result.kind) {
            case "available":
                if (!registered) { router.register("sandbox", executor); registered = true; }
                break;
            case "unavailable": break;
            default: throw new Error("jarvis: shell=probe-kind");
            }
            readiness = result.kind === "available" ? result : { kind: "unavailable", reason: result.reason };
            status(readiness);
            probe = null;
        }).catch(error => { if (!closed && probe === acquired) failed(error); });
    }
    const ready = refresh();
    return Object.freeze({ ready, refresh, close() {
        if (closed) return;
        closed = true;
        if (probe !== null) probe.abort();
        executor.cancel();
    } });
}

module.exports = { roots, install };
