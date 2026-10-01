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
//   revert <token>                restore the captured state now; prints `ok`
//   adopt                         at shell start: arm a guard for a record
//                                 whose guard is gone; prints
//                                 `ok adopt=none|foreign|guarded|armed`
//   guard <token>                 the guard; bin/vgsh-monitor-guard <token>
//                                 runs it
//
// Every file is under $XDG_RUNTIME_DIR/vgs: the record
// monitors-preview.json, mode 0600, written by rename; the transaction lock
// monitors-preview.lock, held across every read-modify-write of the record,
// so a confirm, a revert and a guard's deadline take turns; the guard lock
// monitors-guard.lock, whose only line is the pid of the guard holding it;
// and the guard's log monitors-guard.log, one keyed line per event. Every
// hyprctl call names the instance the record names with --instance.
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

// Each line through `hyprctl eval`, in order: { ok: true } or { ok: false,
// line, reply } at the first one Hyprland does not answer `ok`.
function applyLines(signature, lines) {
    for (const line of lines) {
        const run = hyprctl(signature, ["eval", line]);
        const reply = run.ok ? run.text.trim() : run.error;
        if (reply !== "ok") return { ok: false, line: line, reply: reply };
    }
    return { ok: true };
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
// state through `hyprctl eval`, then the read back. Never a reload: a reload
// leaves an output no file rule names as it is, so it would keep the
// preview. Answers the outcome's keyed words.
async function restore(signature, captured) {
    const read = readOutputs(signature);
    if (!read.ok) return { ok: false, words: read.error.slice("refused: ".length) };
    const plan = Monitors.restorePlan(captured, read.outputs);
    const skipped = plan.skipped.length === 0 ? "" : " skipped=" + plan.skipped.join(",");
    const applied = applyLines(signature, plan.lines);
    if (!applied.ok) return { ok: false, words: "restore=failed line=" + JSON.stringify(applied.line) + " reply=" + JSON.stringify(applied.reply) + skipped };
    const verified = await settle(signature, plan.rules);
    if (!verified.ok) return { ok: false, words: verified.error.slice("refused: ".length) + skipped };
    if (verified.differs.length > 0) return { ok: false, words: "restore=unverified output=" + verified.differs.join(",") + skipped };
    return { ok: true, words: "restored=" + plan.rules.length + skipped };
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

// Undo a preview that failed after it applied: the captured state back,
// the record gone, then the refusal FIRST with the restore's outcome.
async function undo(paths, signature, captured, first) {
    const result = await restore(signature, captured);
    removeRecord(paths);
    refuse(first + " " + result.words);
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
    hold(paths.transaction, true);
    if (readRecord(paths) !== null) refuse("preview=busy path=" + paths.record);

    // 1. Capture the outputs the rules name.
    const read = readOutputs(signature);
    if (!read.ok) refuse(read.error.slice("refused: ".length));
    const plan = Monitors.previewPlan(request.rules, read.outputs, saved.rules);
    if (!plan.ok) refuse(plan.error.slice("refused: ".length));
    after("capture", fault);

    // 2. Write the record.
    const record = {
        version: Monitors.PREVIEW_VERSION, token: crypto.randomBytes(16).toString("hex"),
        deadline: Math.ceil(now()) + seconds, signature: signature, captured: plan.captured
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
    const applied = applyLines(signature, Monitors.render(plan.applied));
    if (!applied.ok) await undo(paths, signature, plan.captured, "preview=apply-failed line=" + JSON.stringify(applied.line) + " reply=" + JSON.stringify(applied.reply));
    after("apply", fault);

    // 5. Verify: an output that reads another mode fell back.
    const verified = await settle(signature, plan.applied);
    if (!verified.ok) await undo(paths, signature, plan.captured, verified.error.slice("refused: ".length));
    if (verified.differs.length > 0) await undo(paths, signature, plan.captured, "preview=fallback output=" + verified.differs.join(","));
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
    hold(paths.transaction, true);
    const error = Monitors.tokenError(readRecord(paths), token, signature);
    if (error !== "") refuse(error.slice("refused: ".length));
    removeRecord(paths);
    process.stdout.write("ok\n");
}

async function revert(token) {
    judgeToken(token);
    const signature = signatureOf(process.env);
    const paths = files();
    hold(paths.transaction, true);
    const record = readRecord(paths);
    const error = Monitors.tokenError(record, token, signature);
    if (error !== "") refuse(error.slice("refused: ".length));
    const result = await restore(record.signature, record.captured);
    removeRecord(paths);
    if (!result.ok) refuse(result.words);
    process.stdout.write("ok " + result.words + "\n");
}

async function adopt() {
    const signature = signatureOf(process.env);
    const paths = files();
    hold(paths.transaction, true);
    const record = readRecord(paths);
    const probe = hold(paths.guard, false);
    if (probe.state === "held") probe.release();
    const action = Monitors.adoptAction(record, signature, probe.state === "busy");
    switch (action) {
    case "none":
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
// until it is gone or its deadline comes, and at the deadline read it again
// under the transaction lock before it restores, so a confirm or a revert
// that took the lock first wins. It leaves another instance's record alone.
async function guard(token) {
    judgeToken(token);
    const signature = signatureOf(process.env);
    const paths = files();
    hold(paths.guard, true);
    let record = readRecord(paths);
    let action = Monitors.guardAction(record, token, signature, now());
    if (action === "gone" || action === "foreign") {
        log("guard=" + action + " token=" + token + " pid=" + process.pid);
        return;
    }
    fs.writeFileSync(paths.guard, process.pid + "\n");
    log("guard=armed token=" + token + " pid=" + process.pid + " deadline=" + record.deadline);
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
        case "restore": {
            hold(paths.transaction, true);
            record = readRecord(paths);
            action = Monitors.guardAction(record, token, signature, now());
            if (action !== "restore") continue;
            const result = await restore(record.signature, record.captured);
            removeRecord(paths);
            log("guard=" + (result.ok ? "restored" : "failed") + " token=" + token + " " + result.words);
            return;
        }
        default:
            throw new Error("monitor-preview: guardAction answered " + JSON.stringify(action));
        }
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
