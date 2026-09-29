import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "../Commons/ThemeLogic.js" as ThemeLogic

// Owns the `vgsh theme` processes the theme capability runs: the queue,
// one process that runs its jobs in order, and the download lane, a
// second process that runs one wallpaper download at a time, so a list or
// an apply never waits behind a download. It keeps the jobs, the last
// list, the last apply result and the running download's progress. The
// state lives here, outside every plugin instance, so a panel or an
// overlay closed during a job and reopened after it reads the result or
// the progress from `last`. A job's callbacks belong to their instances'
// lifetimes: a destroyed instance's callback is dropped and its job still
// runs. The runner judges no package; every answer but an immediate
// refusal of a malformed argument or a busy slot is what `vgsh` printed.
// shell.qml queues `vgsh theme follow` at the end of every scan in the
// guarded instance, which applies the applied package again once it
// changed; no plugin reaches it.
Scope {
    id: root

    // The queue's jobs in order, the first one running once started. A job
    // is { verb, name, argv, started, waiters, lines, completion }: `verb`
    // one of the verbs `command` names, `name` the package, step, scope or
    // path the job acts on, or null; `argv` its arguments after `vgsh
    // theme`; each waiter { id, done, release }, `release` ending its
    // registration in the instance's lifetime; `lines` every stdout line
    // that is no progress; `completion` { code, status } of its exit, null
    // until it exits. Replaced whole on every change so `last` re-evaluates.
    property var jobs: []
    // The download lane's one job, a job as above, or null.
    property var download: null
    // The last list `vgsh theme list --json` printed, or null before the
    // first and after one that failed.
    property var listing: null
    // The last apply's structured result, or a follow's that applied again,
    // null before the first.
    property var lastResult: null
    // The running download's progress { name, state, bytes, total }: the
    // package, then the last progress line `vgsh theme wallpapers --json`
    // printed, `state` null, `bytes` 0 and `total` null before the first.
    // Null while no download runs.
    property var downloading: null
    // The steps `vgsh theme background` takes, and the scopes of `images`.
    readonly property var backgroundSteps: ["next", "previous"]
    readonly property var imageScopes: ["applied", "all"]

    // The running state and the last structured apply result: `applying`
    // is the name of the apply running or waiting, or null; `downloading`
    // the running download's progress, or null.
    readonly property var last: Object.freeze({
        applying: (root.jobs.find(job => job.verb === "apply") || { name: null }).name,
        result: root.lastResult,
        downloading: root.downloading
    })

    function provider(ctx) {
        return {
            list: done => root.list(ctx, done),
            get current() { return Theme.name; },
            get revision() { return Theme.revision; },
            get fileState() { return Theme.fileState; },
            get modified() { return root.listing === null ? null : root.listing.file.modified; },
            apply: (name, done) => root.apply(ctx, name, done),
            background: (step, done) => root.background(ctx, step, done),
            catalog: done => root.catalog(ctx, done),
            install: (name, done) => root.install(ctx, name, done),
            wallpapers: (name, done) => root.wallpapers(ctx, name, done),
            images: (scope, done) => root.images(ctx, scope, done),
            set: (path, screen, done) => root.set(ctx, path, screen, done),
            swatch: name => root.swatch(name),
            get last() { return root.last; }
        };
    }

    // list: `done` receives { file, packages, reason } as the runner
    // printed them with reason null, or file and packages null beside the
    // reason the runner could not report them. A list asked for while the
    // last job is a list joins it.
    function list(ctx, done) {
        joined(ctx, "list", done);
    }

    // catalog: `done` receives { entries, reason }, the entries `vgsh theme
    // catalog --json` printed with reason null, or entries null beside the
    // reason the runner could not report them. A catalog asked for while
    // the last job is a catalog joins it.
    function catalog(ctx, done) {
        joined(ctx, "catalog", done);
    }

    // apply: `ok` once the apply is queued, or an immediate refusal while
    // another apply is running or waiting and for a name no package can
    // carry; `done` receives the structured result, every other refusal
    // included.
    function apply(ctx, name, done) {
        if (!ThemeLogic.isPackageName(name)) return "refused: theme=" + JSON.stringify(name) + " reason=malformed-name";
        if (jobs.some(job => job.verb === "apply")) return "refused: theme=" + name + " reason=busy";
        enqueue(newJob(ctx, "apply", name, done));
        return "ok";
    }

    // background: `ok` once a step through the applied package's images is
    // queued, or an immediate refusal for a step that is neither `next` nor
    // `previous`; `done` receives the structured result `{ state,
    // background, theme, path, reason }` `vgsh theme background --json`
    // prints, every refusal included.
    function background(ctx, step, done) {
        if (root.backgroundSteps.indexOf(step) === -1) return "refused: background=" + JSON.stringify(step) + " reason=malformed-step";
        enqueue(newJob(ctx, "background", step, done));
        return "ok";
    }

    // install: `ok` once the install of catalog package NAME is queued, or
    // an immediate refusal for a name no package can carry; `done`
    // receives `{ state, theme, path, shadows, reason }`, every other
    // refusal included.
    function install(ctx, name, done) {
        if (!ThemeLogic.isPackageName(name)) return "refused: theme=" + JSON.stringify(name) + " reason=malformed-name";
        enqueue(newJob(ctx, "install", name, done));
        return "ok";
    }

    // images: `ok` once the list of the applied package's images, or with
    // scope `all` every source's, is queued, or an immediate refusal for
    // any other scope; `done` receives `{ state, images, reason }`, every
    // refusal included.
    function images(ctx, scope, done) {
        if (root.imageScopes.indexOf(scope) === -1) return "refused: images=" + JSON.stringify(scope) + " reason=malformed-scope";
        enqueue(newJob(ctx, "images", scope, done, scope === "all" ? ["--all"] : []));
        return "ok";
    }

    // set: `ok` once the image at PATH is queued to become the current
    // one, or with SCREEN, an output name, that screen's own; an immediate
    // refusal for a path that is not absolute and an output name no
    // output can carry; `done` receives `{ state, background, theme, path,
    // screen, reason }`, every other refusal included.
    function set(ctx, path, screen, done) {
        if (!ThemeLogic.isAbsolutePath(path)) return "refused: set=" + JSON.stringify(path) + " reason=malformed-path";
        const toScreen = screen !== null && screen !== undefined;
        if (toScreen && !ThemeLogic.isOutputName(screen)) return "refused: set=" + JSON.stringify(screen) + " reason=malformed-screen";
        enqueue(newJob(ctx, "set", path, done, toScreen ? ["--screen", screen] : []));
        return "ok";
    }

    // wallpapers: `ok` once the download of catalog install NAME's
    // wallpapers starts on the download lane, or an immediate refusal for
    // a name no package can carry and while a download runs; `done`
    // receives `{ state, theme, wallpapers, images, sha256, reason }`,
    // every other refusal included. `last.downloading` follows it.
    function wallpapers(ctx, name, done) {
        if (!ThemeLogic.isPackageName(name)) return "refused: wallpapers=" + JSON.stringify(name) + " reason=malformed-name";
        if (download !== null) return "refused: wallpapers=" + name + " reason=busy";
        startDownload(newJob(ctx, "wallpapers", name, done));
        return "ok";
    }

    // follow: queue `vgsh theme follow --json`. A follow asked for while a
    // follow waits joins it; one asked for while a follow runs waits, since
    // the running one may have read the packages before they changed.
    function follow() {
        const tail = jobs[jobs.length - 1];
        if (tail !== undefined && tail.verb === "follow" && !tail.started) return;
        enqueue(newJob(null, "follow", null, null));
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

    // The arguments after `vgsh theme` that run VERB on NAME, EXTRA after.
    function command(verb, name, extra) {
        switch (verb) {
        case "list":
        case "follow":
        case "catalog":
            return [verb, "--json"];
        case "apply":
        case "install":
        case "wallpapers":
            return [verb, "--json", name];
        case "background":
            return ["background", "--json", name];
        case "images":
            return ["background", "--json", "list"].concat(extra);
        case "set":
            return ["background", "--json", "set", name].concat(extra);
        }
        throw new Error("theme: command for unknown verb=" + verb);
    }

    // A job for VERB on NAME with CTX's DONE waiting on it; a follow has no
    // waiter.
    function newJob(ctx, verb, name, done, extra) {
        const made = { verb: verb, name: name, argv: command(verb, name, extra || []), started: false, waiters: [], lines: [], completion: null };
        if (ctx !== null) wait(ctx, made, done);
        return made;
    }

    // A list or a catalog: joins the last queued job of the same verb.
    function joined(ctx, verb, done) {
        const tail = jobs[jobs.length - 1];
        if (tail !== undefined && tail.verb === verb) {
            wait(ctx, tail, done);
            return;
        }
        enqueue(newJob(ctx, verb, null, done));
    }

    function wait(ctx, job, done) {
        if (typeof done !== "function")
            throw new Error("refused: theme=" + job.verb + " done=not-a-function");
        const waiter = { id: ctx.id, done: done };
        waiter.release = ctx.onDispose(() => {
            job.waiters = job.waiters.filter(w => w !== waiter);
        });
        job.waiters = job.waiters.concat([waiter]);
    }

    // A job starts after the call that queued it returns, so `done` never
    // runs before the member answers, even for a process that fails to
    // start.
    function enqueue(job) {
        jobs = jobs.concat([job]);
        Qt.callLater(startNext);
    }

    function startNext() {
        if (jobs.length === 0 || jobs[0].started) return;
        start(jobs[0], queueProcess);
    }

    function startDownload(job) {
        download = job;
        Qt.callLater(startDownloadNow);
    }

    function startDownloadNow() {
        if (download === null || download.started) return;
        start(download, downloadProcess);
    }

    function start(job, process) {
        job.started = true;
        if (job.verb === "wallpapers") downloading = Object.freeze({ name: job.name, state: null, bytes: 0, total: null });
        process.job = job;
        process.command = [Quickshell.shellDir + "/../bin/vgsh", "theme"].concat(job.argv);
        process.running = true;
    }

    // One stdout line of JOB: a download's progress line moves
    // `downloading`; every other line is kept for the result.
    function read(job, line) {
        if (job.verb === "wallpapers") {
            const progress = progressOf(line);
            if (progress !== null) {
                downloading = Object.freeze({ name: job.name, state: progress.state, bytes: progress.bytes, total: progress.total });
                return;
            }
        }
        job.lines.push(line);
    }

    // `{ state, bytes, total }`, the whole of a progress line, or null for
    // any other line.
    function progressOf(line) {
        let value;
        try {
            value = JSON.parse(line);
        } catch (e) {
            return null;
        }
        if (value === null || typeof value !== "object" || Array.isArray(value)) return null;
        const keys = Object.keys(value).sort();
        if (keys.join(",") !== "bytes,state,total") return null;
        if (typeof value.state !== "string" || !Number.isSafeInteger(value.bytes) || !Number.isSafeInteger(value.total)) return null;
        return value;
    }

    // The runner prints one JSON object on every path, a refusal's non-zero
    // exit included, so that object is the answer whatever the exit code.
    // No exit recorded is a failed start; an exit without the object is
    // logged and answered as a failure, never as an empty list.
    function resultOf(job) {
        if (job.completion === null) return failure(job, "start-failed", "");
        const exit = " exit=" + job.completion.code + " status=" + job.completion.status;
        let value;
        try {
            value = JSON.parse(job.lines.join("\n"));
        } catch (e) {
            return failure(job, "output-unreadable", exit + " error=" + e.message);
        }
        const isObject = v => v !== null && typeof v === "object" && !Array.isArray(v);
        switch (job.verb) {
        case "list":
            if (isObject(value) && isObject(value.file) && Array.isArray(value.packages)) return { file: value.file, packages: value.packages, reason: null };
            break;
        case "catalog":
            if (isObject(value) && Array.isArray(value.entries)) return { entries: value.entries, reason: null };
            break;
        case "apply":
        case "background":
        case "follow":
        case "install":
        case "images":
        case "set":
        case "wallpapers":
            if (isObject(value) && typeof value.state === "string") return value;
            break;
        default:
            throw new Error("theme: result for unknown verb=" + job.verb);
        }
        return failure(job, "output-unreadable", exit + " error=shape");
    }

    function failure(job, reason, detail) {
        console.error("theme: vgsh theme " + job.verb + " reason=" + reason + (job.name === null ? "" : " name=" + job.name) + detail);
        switch (job.verb) {
        case "apply":
            return { state: "failed", shell: "failed", targets: [], theme: job.name, reason: reason };
        case "background":
            return { state: "failed", background: null, theme: null, path: null, reason: reason };
        case "follow":
            return { state: "failed", shell: "failed", targets: [], theme: null, reason: reason, follow: null };
        case "list":
            return { file: null, packages: null, reason: reason };
        case "catalog":
            return { entries: null, reason: reason };
        case "install":
            return { state: "failed", theme: job.name, path: null, shadows: null, reason: reason };
        case "images":
            return { state: "failed", images: null, reason: reason };
        case "set":
            return { state: "failed", background: null, theme: null, path: null, screen: null, reason: reason };
        case "wallpapers":
            return { state: "failed", theme: job.name, wallpapers: null, images: null, sha256: null, reason: reason };
        }
        throw new Error("theme: failure for unknown verb=" + job.verb);
    }

    // PROCESS's job ended: record its answer, take it off its lane, hand
    // the answer to every waiter still alive, and start the next job.
    function finish(process) {
        const job = process.job;
        if (job === null || !job.started) throw new Error("theme: runner process stopped with no started job");
        process.job = null;
        // Every waiter and every later reader shares the one answer, so none
        // can change what another reads.
        const result = frozen(resultOf(job));
        switch (job.verb) {
        case "apply":
            lastResult = result;
            break;
        case "follow": {
            if (result.follow === "reapplied") lastResult = result;
            // One line per follow; a follow that did not run is an error.
            const line = "theme: follow=" + result.follow + " state=" + result.state + (result.reason === null ? "" : " reason=" + result.reason);
            if (result.state === "failed") console.error(line);
            else console.info(line);
            break;
        }
        case "list":
            listing = result.reason === null ? result : null;
            break;
        case "wallpapers":
            downloading = null;
            break;
        case "background":
        case "catalog":
        case "install":
        case "images":
        case "set":
            break;
        default:
            throw new Error("theme: finish for unknown verb=" + job.verb);
        }
        if (job === download) {
            download = null;
        } else {
            if (jobs[0] !== job) throw new Error("theme: finished job verb=" + job.verb + " is not the queue's first");
            jobs = jobs.slice(1);
        }
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
        const shown = job => ({ verb: job.verb, name: job.name, started: job.started, waiters: job.waiters.length });
        return {
            jobs: jobs.map(shown),
            download: download === null ? null : shown(download),
            last: last
        };
    }

    // A process that fails to start emits only runningChanged, so the exit
    // is read there: no exit recorded is a failed start. A SplitParser's
    // lines all arrive before the exit.
    Process {
        id: queueProcess
        property var job: null
        stdout: SplitParser { onRead: data => root.read(queueProcess.job, data) }
        onExited: (code, status) => { queueProcess.job.completion = { code: code, status: status }; }
        onRunningChanged: {
            if (running) return;
            root.finish(queueProcess);
        }
    }

    Process {
        id: downloadProcess
        property var job: null
        stdout: SplitParser { onRead: data => root.read(downloadProcess.job, data) }
        onExited: (code, status) => { downloadProcess.job.completion = { code: code, status: status }; }
        onRunningChanged: {
            if (running) return;
            root.finish(downloadProcess);
        }
    }
}
