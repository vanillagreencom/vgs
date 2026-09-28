import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "../Commons/ThemeLogic.js" as ThemeLogic

// Owns the one `vgsh theme` process the theme capability runs, the jobs
// waiting for it, the last list and the last apply result. The state lives
// here, outside every plugin instance, so a panel closed during an apply
// and reopened after it reads the result from `last`. A job's callbacks
// belong to their instances' lifetimes: a destroyed instance's callback is
// dropped and its job still runs. The runner judges no package; every
// answer but an immediate busy or malformed name is what `vgsh` printed.
Scope {
    id: root

    // Waiting and running jobs in order, the first one running once
    // started: { verb: "list" | "apply", name, started, waiters }, each
    // waiter { id, done, release }, `release` ending its registration in
    // the instance's lifetime. Replaced whole on every change so `last`
    // re-evaluates.
    property var jobs: []
    // { code, status } of the running job's exit, null until it exits.
    property var completion: null
    // The last list `vgsh theme list --json` printed, or null before the
    // first and after one that failed.
    property var listing: null
    // The last apply's structured result, null before the first.
    property var lastResult: null

    // The running state and the last structured apply result: `applying`
    // is the name of the apply running or waiting, or null.
    readonly property var last: Object.freeze({
        applying: (root.jobs.find(job => job.verb === "apply") || { name: null }).name,
        result: root.lastResult
    })

    function provider(ctx) {
        return {
            list: done => root.list(ctx, done),
            get current() { return Theme.name; },
            get revision() { return Theme.revision; },
            get fileState() { return Theme.fileState; },
            get modified() { return root.listing === null ? null : root.listing.file.modified; },
            apply: (name, done) => root.apply(ctx, name, done),
            swatch: name => root.swatch(name),
            get last() { return root.last; }
        };
    }

    // list: `done` receives { file, packages, reason } as the runner
    // printed them with reason null, or file and packages null beside the
    // reason the runner could not report them. A list asked for while the
    // last job is a list joins it.
    function list(ctx, done) {
        const tail = jobs[jobs.length - 1];
        const job = tail !== undefined && tail.verb === "list" ? tail : { verb: "list", name: null, started: false, waiters: [] };
        wait(ctx, job, "list", done);
        if (job !== tail) enqueue(job);
    }

    // apply: `ok` once the apply is queued, or an immediate refusal while
    // another apply is running or waiting and for a name no package can
    // carry; `done` receives the structured result, every other refusal
    // included.
    function apply(ctx, name, done) {
        if (!ThemeLogic.isPackageName(name)) return "refused: theme=" + JSON.stringify(name) + " reason=malformed-name";
        if (jobs.some(job => job.verb === "apply")) return "refused: theme=" + name + " reason=busy";
        const job = { verb: "apply", name: name, started: false, waiters: [] };
        wait(ctx, job, "apply", done);
        enqueue(job);
        return "ok";
    }

    // One package's resolved palette from the last list, each colour as the
    // `#aarrggbb` string a colour property takes; null for a package the
    // last list did not accept or does not name.
    function swatch(name) {
        if (listing === null) return null;
        const row = listing.packages.find(p => p.name === name && p.state === "ok");
        if (row === undefined) return null;
        const out = {};
        for (const key of Object.keys(row.palette)) out[key] = Theme.toColor(row.palette[key]);
        return out;
    }

    function wait(ctx, job, verb, done) {
        if (typeof done !== "function")
            throw new Error("refused: theme=" + verb + " done=not-a-function");
        const waiter = { id: ctx.id, done: done };
        waiter.release = ctx.onDispose(() => {
            job.waiters = job.waiters.filter(w => w !== waiter);
        });
        job.waiters = job.waiters.concat([waiter]);
    }

    // A job starts after the call that queued it returns, so `done` never
    // runs before `apply` answers, even for a process that fails to start.
    function enqueue(job) {
        jobs = jobs.concat([job]);
        Qt.callLater(startNext);
    }

    function startNext() {
        if (jobs.length === 0 || jobs[0].started) return;
        const job = jobs[0];
        job.started = true;
        const command = [Quickshell.shellDir + "/../bin/vgsh", "theme", job.verb, "--json"];
        process.command = job.verb === "apply" ? command.concat([job.name]) : command;
        completion = null;
        process.running = true;
    }

    // The runner prints one JSON object on every path, a refusal's non-zero
    // exit included, so that object is the answer whatever the exit code.
    // No exit recorded is a failed start; an exit without the object is
    // logged and answered as a failure, never as an empty list.
    function resultOf(job) {
        if (completion === null) return failure(job, "start-failed", "");
        const exit = " exit=" + completion.code + " status=" + completion.status;
        let value;
        try {
            value = JSON.parse(output.text);
        } catch (e) {
            return failure(job, "output-unreadable", exit + " error=" + e.message);
        }
        const isObject = v => v !== null && typeof v === "object" && !Array.isArray(v);
        if (job.verb === "apply" && isObject(value) && typeof value.state === "string") return value;
        if (job.verb === "list" && isObject(value) && isObject(value.file) && Array.isArray(value.packages))
            return { file: value.file, packages: value.packages, reason: null };
        return failure(job, "output-unreadable", exit + " error=shape");
    }

    function failure(job, reason, detail) {
        console.error("theme: vgsh theme " + job.verb + " reason=" + reason + (job.name === null ? "" : " name=" + job.name) + detail);
        return job.verb === "apply"
            ? { state: "failed", shell: "failed", targets: [], theme: job.name, reason: reason }
            : { file: null, packages: null, reason: reason };
    }

    // The running job ended: record its answer, take it off the queue, hand
    // the answer to every waiter still alive, and start the next job.
    function finish() {
        const job = jobs[0];
        if (job === undefined || !job.started) throw new Error("theme: runner process stopped with no started job");
        // Every waiter and every later reader shares the one answer, so none
        // can change what another reads.
        const result = frozen(resultOf(job));
        if (job.verb === "apply") lastResult = result;
        else listing = result.reason === null ? result : null;
        jobs = jobs.slice(1);
        for (const waiter of job.waiters.slice()) {
            waiter.release();
            try {
                waiter.done(result);
            } catch (e) {
                console.error("capabilities: theme " + job.verb + " callback of " + waiter.id + " threw: " + e.message);
            }
        }
        startNext();
    }

    function frozen(value) {
        if (value === null || typeof value !== "object") return value;
        for (const key of Object.keys(value)) frozen(value[key]);
        return Object.freeze(value);
    }

    // Every job's state, for the lending record.
    function record() {
        return {
            jobs: jobs.map(job => ({ verb: job.verb, name: job.name, started: job.started, waiters: job.waiters.length })),
            last: last
        };
    }

    // A process that fails to start emits only runningChanged, so the exit
    // is read there: no exit recorded is a failed start.
    Process {
        id: process
        stdout: StdioCollector { id: output }
        onExited: (code, status) => { root.completion = { code: code, status: status }; }
        onRunningChanged: {
            if (running) return;
            root.finish();
        }
    }
}
