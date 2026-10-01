// The monitor preview's transaction and its guard, run through
// bin/vgsh-monitor-guard, which closes every inherited descriptor first.
// shell/Core/MonitorLogic.js decides each step; this runs hyprctl, the
// record, the locks and the guard process
// (docs/architecture/hyprland-monitors-preview.md).
//
//   preview <seconds> <request>   apply a preview of <request>'s rules,
//                                 `{ "rules": [...], "saved": [...] }`,
//                                 guarded for <seconds>; prints
//                                 `ok token=<hex> deadline=<epoch>`
//   confirm <token>               keep it: remove the record; prints `ok`
//   revert <token>                restore the captured state now; prints
//                                 `ok restored=<n>`
//   adopt                         at shell start: arm a guard for a record
//                                 whose guard is gone; prints
//                                 `ok adopt=none|stale|foreign|guarded|armed`
//   guard <token>                 the guard; bin/vgsh-monitor-guard <token>
//                                 runs it
//
// Every file is under $XDG_RUNTIME_DIR/vgs: the record
// monitors-preview.json, mode 0600, written by rename; the transaction lock
// monitors-preview.lock, held across every read-modify-write of the record,
// so a confirm, a revert and a guard's deadline take turns, and waited on
// for TX_WAIT_S at most; the guard lock monitors-guard.lock, whose only line
// is the pid of the guard holding it; and the guard's log
// monitors-guard.log, one keyed line per event. Every hyprctl call names the
// instance the record names with --instance. A restore that fails keeps the
// record with its `failure`, so the armed guard, or the guard the next
// adopt arms, tries again; a record of an instance that no longer runs is
// removed.
//
// Each refusal is one line on stderr, `vgsh: refused: <key>=<value>`, and
// exit 1; exit 2 for a bad invocation. Under the test-run marker,
// VGS_TEST_RUN non-empty, VGS_MONITOR_PREVIEW_FAULT=<step> makes a preview
// SIGKILL itself right after that step: capture, record, arm, apply or
// verify. Without the marker the variable is not read.
"use strict";
const childProcess = require("child_process");
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const { refuse, main, replaceFile, lockFile } = require(path.join(__dirname, "judge-files.js"));
const Monitors = require(path.join(__dirname, "qml-library.js")).load(path.join(__dirname, "..", "..", "shell", "Core", "MonitorLogic.js"));

const GUARD = path.join(__dirname, "..", "vgsh-monitor-guard");
const STEPS = ["capture", "record", "arm", "apply", "verify"];
// How long one hyprctl call may run.
const HYPRCTL_TIMEOUT_MS = 5000;
// How long a guard may take to hold the guard lock: a guard of an earlier
// preview holds it until its next check, a second at most, finds its
// record gone.
const ARM_TIMEOUT_MS = 5000;
// How long applied rules may take to read back: Hyprland applies an
// `hl.monitor` on its next monitor refresh, not before eval answers.
const SETTLE_MS = 5000;
const POLL_MS = 100;
// How often a guard reads its record before the deadline.
const GUARD_POLL_MS = 1000;
// How long a verb, or a guard at its deadline, waits on the transaction
// lock: past the longest a preview holds it, its arm, apply, read back and
// undo, each bounded above.
const TX_WAIT_S = 30;
// How long a guard waits on the guard lock an earlier guard holds: past
// that guard's life, a deadline of PREVIEW_SECONDS_MAX and its attempts.
const GUARD_LOCK_WAIT_S = 300;
// How many times a guard tries a restore that failed, and the pause
// between two tries. Each try is bounded by the hyprctl and settle bounds.
const RESTORE_ATTEMPTS = 5;
const RESTORE_PAUSE_MS = 1000;

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const now = () => Date.now() / 1000;

function signatureOf(env) {
    const signature = env.HYPRLAND_INSTANCE_SIGNATURE;
    if (signature === undefined || !Monitors.SIGNATURE.test(signature)) refuse("signature=" + JSON.stringify(signature === undefined ? null : signature) + " want=signature");
    return signature;
}

// The files under $XDG_RUNTIME_DIR/vgs. The directory is made 0700 when
// absent and refused when it is a symlink, no directory or another user's.
function files() {
    const base = process.env.XDG_RUNTIME_DIR;
    if (base === undefined || base === "") refuse("runtime-dir=unset");
    const dir = path.join(base, "vgs");
    try {
        fs.mkdirSync(dir, { mode: 0o700 });
    } catch (e) {
        if (e.code !== "EEXIST") refuse("runtime-dir=unwritable path=" + dir + " error=" + e.code);
    }
    const stat = fs.lstatSync(dir);
    if (stat.isSymbolicLink() || !stat.isDirectory()) refuse("runtime-dir=not-a-directory path=" + dir);
    if (stat.uid !== process.getuid()) refuse("runtime-dir=foreign-owner path=" + dir + " uid=" + stat.uid);
    return {
        record: path.join(dir, "monitors-preview.json"), transaction: path.join(dir, "monitors-preview.lock"),
        guard: path.join(dir, "monitors-guard.lock"), log: path.join(dir, "monitors-guard.log")
    };
}

function hold(file, wait) {
    const lock = lockFile(file, wait);
    if (lock.state === "failed") refuse("lock=failed path=" + file + " error=" + lock.error);
    return lock;
}

// The judged record, or null when there is none. A symlink or another
// user's file is refused, never read.
function readRecord(paths) {
    let stat;
    try {
        stat = fs.lstatSync(paths.record);
    } catch (e) {
        if (e.code === "ENOENT") return null;
        refuse("record=unreadable path=" + paths.record + " error=" + e.code);
    }
    if (stat.isSymbolicLink() || !stat.isFile()) refuse("record=not-a-file path=" + paths.record);
    if (stat.uid !== process.getuid()) refuse("record=foreign-owner path=" + paths.record + " uid=" + stat.uid);
    let text;
    try {
        text = fs.readFileSync(paths.record, "utf8");
    } catch (e) {
        if (e.code === "ENOENT") return null;
        refuse("record=unreadable path=" + paths.record + " error=" + e.code);
    }
    const read = Monitors.readRecord(text);
    if (!read.ok) refuse(read.error.slice("refused: ".length) + " path=" + paths.record);
    return read.record;
}

function removeRecord(paths) {
    try {
        fs.rmSync(paths.record, { force: true });
    } catch (e) {
        refuse("record=unremovable path=" + paths.record + " error=" + e.code);
    }
}

// hyprctl --instance SIGNATURE ARGS: { ok: true, text } or { ok: false,
// error } for a run that failed or exited non-zero.
function hyprctl(signature, args) {
    const run = childProcess.spawnSync("hyprctl", ["--instance", signature].concat(args), { encoding: "utf8", timeout: HYPRCTL_TIMEOUT_MS, stdio: ["ignore", "pipe", "pipe"] });
    if (run.error !== undefined) return { ok: false, error: "hyprctl=failed error=" + run.error.code };
    if (run.status !== 0) return { ok: false, error: "hyprctl=failed status=" + run.status + " stderr=" + JSON.stringify(run.stderr.trim()) };
    return { ok: true, text: run.stdout };
}

function readOutputs(signature) {
    const run = hyprctl(signature, Monitors.OUTPUTS_REQUEST.slice(1));
    if (!run.ok) return { ok: false, error: "refused: outputs=unread " + run.error };
    return Monitors.parseOutputs(run.text);
}

// LINE through `hyprctl eval`: Hyprland's reply, `ok` when it applied, or
// the run's failure.
function evalLine(signature, line) {
    const run = hyprctl(signature, ["eval", line]);
    return run.ok ? run.text.trim() : run.error;
}

// Read the outputs every POLL_MS until RULES read back, for up to
// SETTLE_MS: { ok: true, differs } with the identifiers still read
// otherwise, or { ok: false, error } for a read that failed.
async function settle(signature, rules) {
    const until = Date.now() + SETTLE_MS;
    for (;;) {
        const read = readOutputs(signature);
        if (!read.ok) return read;
        const differs = Monitors.overridden(rules, read.outputs);
        if (differs.length === 0 || Date.now() >= until) return { ok: true, differs: differs };
        await sleep(POLL_MS);
    }
}

// Put CAPTURED back on instance SIGNATURE: every listed output's captured
// state through `hyprctl eval`, each line sent whatever the line before
// answered, then the read back. Never a reload: a reload leaves an output
// no file rule names as it is, so it would keep the preview. Answers the
// outcome's keyed words.
async function restore(signature, captured) {
    const read = readOutputs(signature);
    if (!read.ok) return { ok: false, words: "restore=unread " + read.error.slice("refused: ".length) };
    const plan = Monitors.restorePlan(captured, read.outputs);
    const skipped = plan.skipped.length === 0 ? "" : " skipped=" + plan.skipped.join(",");
    const failed = [];
    for (const line of plan.lines) {
        const reply = evalLine(signature, line);
        if (reply !== "ok") failed.push({ line: line, reply: reply });
    }
    if (failed.length > 0)
        return { ok: false, words: "restore=failed lines=" + failed.length + " line=" + JSON.stringify(failed[0].line) + " reply=" + JSON.stringify(failed[0].reply) + skipped };
    const verified = await settle(signature, plan.rules);
    if (!verified.ok) return { ok: false, words: "restore=unread " + verified.error.slice("refused: ".length) + skipped };
    if (verified.differs.length > 0) return { ok: false, words: "restore=unverified output=" + verified.differs.join(",") + skipped };
    return { ok: true, words: "restored=" + plan.rules.length + skipped };
}

// Whether Hyprland instance SIGNATURE runs: hyprctl reaches it through
// $XDG_RUNTIME_DIR/hypr/<signature>/.socket.sock, which Hyprland removes
// when it exits.
function instanceAlive(signature) {
    try {
        return fs.statSync(path.join(process.env.XDG_RUNTIME_DIR, "hypr", signature, ".socket.sock")).isSocket();
    } catch (e) {
        if (e.code === "ENOENT" || e.code === "ENOTDIR") return false;
        throw e;
    }
}

// Keep RECORD after a failed restore, its `failure` the restore's WORDS,
// so a guard tries again.
function keepFailure(paths, record, words) {
    const failure = words.replace(/[^\x20-\x7e]/g, "?").slice(0, 400);
    replaceFile(paths.record, Monitors.recordText(Object.assign({}, record, { failure: failure })), "record", 0o600);
}

// The transaction lock, waited on up to TX_WAIT_S; refused `lock=busy`
// past it.
function holdTransaction(paths) {
    const lock = hold(paths.transaction, TX_WAIT_S);
    if (lock.state === "busy") refuse("lock=busy path=" + paths.transaction + " wait-s=" + TX_WAIT_S);
    return lock;
}

// Whether a guard holds the guard lock.
function guardRuns(paths) {
    const probe = hold(paths.guard, false);
    if (probe.state === "held") probe.release();
    return probe.state === "busy";
}

// One keyed line in the guard's log, from a verb.
function note(paths, words) {
    try {
        fs.appendFileSync(paths.log, new Date().toISOString() + " " + words + "\n", { mode: 0o600 });
    } catch (e) {
        refuse("log=unwritable path=" + paths.log + " error=" + e.code);
    }
}

// What to do with the record in place before a preview or at adopt, and
// the stale one removed.
function settleRecord(paths, signature, by) {
    const record = readRecord(paths);
    const action = Monitors.adoptAction(record, signature, guardRuns(paths), record !== null && instanceAlive(record.signature));
    if (action === "stale") {
        removeRecord(paths);
        note(paths, "record=stale-removed token=" + record.token + " signature=" + record.signature + " by=" + by);
    }
    return { record: record, action: action };
}

// Start a guard for TOKEN in a session of its own, its output in the log,
// and wait until it holds the guard lock with its pid as the lock file's
// only line. Answers whether it did within ARM_TIMEOUT_MS.
async function arm(paths, token) {
    let log;
    try {
        log = fs.openSync(paths.log, "a", 0o600);
    } catch (e) {
        refuse("log=unwritable path=" + paths.log + " error=" + e.code);
    }
    const child = childProcess.spawn(GUARD, [token], { detached: true, stdio: ["ignore", log, log] });
    fs.closeSync(log);
    let exited = false;
    child.on("exit", () => { exited = true; });
    child.on("error", () => { exited = true; });
    child.unref();
    const until = Date.now() + ARM_TIMEOUT_MS;
    while (!exited && Date.now() < until) {
        let line = "";
        try {
            line = fs.readFileSync(paths.guard, "utf8");
        } catch (e) {
            if (e.code !== "ENOENT") throw e;
        }
        if (line === child.pid + "\n") {
            const probe = hold(paths.guard, false);
            if (probe.state === "busy") return true;
            probe.release();
        }
        await sleep(POLL_MS / 2);
    }
    return false;
}

// The step a preview kills itself after, under the test-run marker alone.
function faultStep() {
    if (!process.env.VGS_TEST_RUN) return null;
    const value = process.env.VGS_MONITOR_PREVIEW_FAULT;
    if (value === undefined || value === "") return null;
    if (!STEPS.includes(value)) refuse("fault=" + JSON.stringify(value) + " want=" + STEPS.join("|"), undefined, 2);
    return value;
}

function after(step, fault) {
    if (step === fault) process.kill(process.pid, "SIGKILL");
}

// Undo a preview that failed after it applied: the captured state back
// and the record gone, then the refusal FIRST with the restore's outcome. A
// restore that failed keeps the record, so the armed guard tries again at
// the deadline.
async function undo(paths, signature, record, first) {
    const result = await restore(signature, record.captured);
    if (result.ok) {
        removeRecord(paths);
        refuse(first + " " + result.words);
    }
    keepFailure(paths, record, result.words);
    refuse(first + " " + result.words + " record=kept");
}

async function preview(secondsText, requestText) {
    const fault = faultStep();
    const seconds = /^[0-9]{1,6}$/.test(secondsText) ? Number(secondsText) : secondsText;
    const secondsError = Monitors.previewSecondsError(seconds);
    if (secondsError !== "") refuse(secondsError.slice("refused: ".length), undefined, 2);
    let request;
    try {
        request = JSON.parse(requestText);
    } catch (e) {
        refuse("request=unparsed", undefined, 2);
    }
    if (request === null || typeof request !== "object" || !Array.isArray(request.rules) || !Array.isArray(request.saved))
        refuse("request=" + JSON.stringify(requestText).slice(0, 60) + " want={rules,saved}", undefined, 2);
    const saved = Monitors.judge({ version: Monitors.VERSION, rules: request.saved }, null);
    if (!saved.ok) refuse("saved=refused " + saved.error.slice("refused: ".length), undefined, 2);
    const signature = signatureOf(process.env);
    const paths = files();
    holdTransaction(paths);
    const before = settleRecord(paths, signature, "preview");
    if (before.action !== "none" && before.action !== "stale") refuse("preview=busy path=" + paths.record);

    // 1. Capture the outputs the rules name.
    const read = readOutputs(signature);
    if (!read.ok) refuse(read.error.slice("refused: ".length));
    const plan = Monitors.previewPlan(request.rules, read.outputs, saved.rules);
    if (!plan.ok) refuse(plan.error.slice("refused: ".length));
    after("capture", fault);

    // 2. Write the record.
    const record = {
        version: Monitors.PREVIEW_VERSION, token: crypto.randomBytes(16).toString("hex"),
        deadline: Math.ceil(now()) + seconds, signature: signature, captured: plan.captured, failure: ""
    };
    replaceFile(paths.record, Monitors.recordText(record), "record", 0o600);
    after("record", fault);

    // 3. Arm the guard.
    if (!(await arm(paths, record.token))) {
        removeRecord(paths);
        refuse("guard=unarmed timeout-ms=" + ARM_TIMEOUT_MS + " log=" + paths.log);
    }
    after("arm", fault);

    // 4. Apply.
    for (const line of Monitors.render(plan.applied)) {
        const reply = evalLine(signature, line);
        if (reply !== "ok") await undo(paths, signature, record, "preview=apply-failed line=" + JSON.stringify(line) + " reply=" + JSON.stringify(reply));
    }
    after("apply", fault);

    // 5. Verify: an output that reads another mode fell back.
    const verified = await settle(signature, plan.applied);
    if (!verified.ok) await undo(paths, signature, record, verified.error.slice("refused: ".length));
    if (verified.differs.length > 0) await undo(paths, signature, record, "preview=fallback output=" + verified.differs.join(","));
    after("verify", fault);
    process.stdout.write("ok token=" + record.token + " deadline=" + record.deadline + "\n");
}

function judgeToken(token) {
    if (!Monitors.TOKEN.test(token)) refuse("token=" + JSON.stringify(token) + " want=32-hex", undefined, 2);
}

function confirm(token) {
    judgeToken(token);
    const signature = signatureOf(process.env);
    const paths = files();
    holdTransaction(paths);
    const error = Monitors.tokenError(readRecord(paths), token, signature);
    if (error !== "") refuse(error.slice("refused: ".length));
    removeRecord(paths);
    process.stdout.write("ok\n");
}

// Restore now. A restore that failed keeps the record and its armed guard,
// which tries again at the deadline.
async function revert(token) {
    judgeToken(token);
    const signature = signatureOf(process.env);
    const paths = files();
    holdTransaction(paths);
    const record = readRecord(paths);
    const error = Monitors.tokenError(record, token, signature);
    if (error !== "") refuse(error.slice("refused: ".length));
    const result = await restore(record.signature, record.captured);
    if (!result.ok) {
        keepFailure(paths, record, result.words);
        refuse("revert=restore-failed " + result.words + " record=kept");
    }
    removeRecord(paths);
    process.stdout.write("ok " + result.words + "\n");
}

async function adopt() {
    const signature = signatureOf(process.env);
    const paths = files();
    holdTransaction(paths);
    const { record, action } = settleRecord(paths, signature, "adopt");
    switch (action) {
    case "none":
    case "stale":
    case "foreign":
    case "guarded":
        process.stdout.write("ok adopt=" + action + "\n");
        return;
    case "arm":
        if (!(await arm(paths, record.token))) refuse("guard=unarmed timeout-ms=" + ARM_TIMEOUT_MS + " log=" + paths.log);
        process.stdout.write("ok adopt=armed token=" + record.token + "\n");
        return;
    default:
        throw new Error("monitor-preview: adoptAction answered " + JSON.stringify(action));
    }
}

function log(words) {
    process.stdout.write(new Date().toISOString() + " " + words + "\n");
}

// The guard: hold the guard lock, then read the record each GUARD_POLL_MS
// until it is gone or its deadline comes. At the deadline it reads the
// record again under the transaction lock before it restores, so a confirm
// or a revert that took the lock first wins, and releases the lock before
// anything else. A restore that failed keeps the record and is tried again
// after RESTORE_PAUSE_MS, up to RESTORE_ATTEMPTS times, unless the record's
// Hyprland instance is gone; after the last the record stays for the next
// shell start's adopt. It leaves another instance's record alone.
async function guard(token) {
    judgeToken(token);
    const signature = signatureOf(process.env);
    const paths = files();
    if (hold(paths.guard, GUARD_LOCK_WAIT_S).state === "busy") {
        log("guard=unarmed token=" + token + " reason=guard-lock-busy wait-s=" + GUARD_LOCK_WAIT_S);
        return;
    }
    let record = readRecord(paths);
    let action = Monitors.guardAction(record, token, signature, now());
    if (action === "gone" || action === "foreign") {
        log("guard=" + action + " token=" + token + " pid=" + process.pid);
        return;
    }
    fs.writeFileSync(paths.guard, process.pid + "\n");
    log("guard=armed token=" + token + " pid=" + process.pid + " deadline=" + record.deadline);
    let attempts = 0;
    for (;;) {
        switch (action) {
        case "wait":
            await sleep(GUARD_POLL_MS);
            record = readRecord(paths);
            action = Monitors.guardAction(record, token, signature, now());
            continue;
        case "gone":
        case "foreign":
            log("guard=" + action + " token=" + token);
            return;
        case "restore":
            break;
        default:
            throw new Error("monitor-preview: guardAction answered " + JSON.stringify(action));
        }
        let words;
        const tx = hold(paths.transaction, TX_WAIT_S);
        if (tx.state === "busy") {
            words = "lock=busy path=" + paths.transaction + " wait-s=" + TX_WAIT_S;
        } else {
            record = readRecord(paths);
            action = Monitors.guardAction(record, token, signature, now());
            if (action !== "restore") {
                tx.release();
                continue;
            }
            const result = await restore(record.signature, record.captured);
            if (result.ok) {
                removeRecord(paths);
                tx.release();
                log("guard=restored token=" + token + " " + result.words);
                return;
            }
            if (!instanceAlive(record.signature)) {
                removeRecord(paths);
                tx.release();
                log("guard=instance-gone token=" + token + " signature=" + record.signature + " " + result.words);
                return;
            }
            keepFailure(paths, record, result.words);
            tx.release();
            words = result.words;
        }
        attempts += 1;
        if (attempts >= RESTORE_ATTEMPTS) {
            log("guard=failed token=" + token + " attempts=" + attempts + " " + words + " record=kept");
            return;
        }
        log("guard=retry token=" + token + " attempt=" + attempts + " " + words);
        await sleep(RESTORE_PAUSE_MS);
        record = readRecord(paths);
        action = Monitors.guardAction(record, token, signature, now());
    }
}

const VERBS = { preview: [2, preview], confirm: [1, confirm], revert: [1, revert], adopt: [0, adopt], guard: [1, guard] };

main(() => {
    const [verb, ...args] = process.argv.slice(2);
    if (verb === undefined || !Object.prototype.hasOwnProperty.call(VERBS, verb)) refuse("verb=" + JSON.stringify(verb === undefined ? null : verb) + " want=" + Object.keys(VERBS).join("|"), undefined, 2);
    const [arity, run] = VERBS[verb];
    if (args.length !== arity) refuse(verb + ".arguments=" + args.length + " want=" + arity, undefined, 2);
    return run(...args);
});
