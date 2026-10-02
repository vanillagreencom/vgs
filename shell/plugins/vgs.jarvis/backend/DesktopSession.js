// Desktop executors: windows, workspaces, applications and notices. Reads
// come from `hyprctl -j`; every change is a service request, and settle()
// is the one judge that reads its effect back from Hyprland.
"use strict";
const cp = require("node:child_process");

/**
 * Production bounds in milliseconds and bytes. They are recovery rules for a
 * compositor or service that does not answer, not measured latency budgets.
 * Tests pass smaller ones.
 */
const BOUNDS = Object.freeze({
    hyprctlMs: 2000, hyprctlBytes: 1024 * 1024, requestMs: 2000,
    settleMs: 2000, launchMs: 10000, pollMs: 100,
    // Scheduling slack between the executor's own bounds and Session's limit.
    slackMs: 1000
});

// An executor's answer, thrown to end a call's chain early.
class Ended {
    constructor(outcome, content) { this.value = { outcome, content }; }
}
const failed = content => new Ended("failed", content);

function lower(address) { return String(address || "").toLowerCase(); }

function clientOf(state, address) {
    return state.clients.find(c => c.mapped && lower(c.address) === address);
}

function focusedMonitor(state) {
    return state.monitors.find(m => m.focused) || null;
}

function describe(client, state) {
    const monitor = state.monitors.find(m => m.id === client.monitor);
    const flags = [client.floating ? "floating" : "", client.fullscreen ? "fullscreen=" + client.fullscreen : "",
        lower(state.active.address) === lower(client.address) ? "focused" : ""].filter(Boolean);
    return lower(client.address) + " workspace=" + JSON.stringify(client.workspace.name)
        + " monitor=" + (monitor ? monitor.name : client.monitor) + " class=" + JSON.stringify(client.class)
        + " title=" + JSON.stringify(client.title) + (flags.length ? " " + flags.join(" ") : "");
}

// Expectations. Each reads one state and says whether the effect is there
// and what was seen, which becomes the brain's result either way.
const expect = {
    active: address => state => {
        const active = lower(state.active.address);
        return { met: active === address, seen: active === "" ? "no window has the focus" : "window " + active + " has the focus" };
    },
    field: (address, name, met, show = value => JSON.stringify(value)) => state => {
        const client = clientOf(state, address);
        if (client === undefined) return { met: false, seen: "window " + address + " is not open" };
        return { met: met(client[name]), seen: "window " + address + " " + name + "=" + show(client[name])
            + (name === "at" || name === "size" ? " floating=" + client.floating : "") };
    },
    closed: address => state => {
        const open = clientOf(state, address) !== undefined;
        return { met: !open, seen: "window " + address + (open ? " is still open" : " is closed") };
    },
    monitor: name => state => {
        const focused = focusedMonitor(state);
        return { met: focused !== null && focused.name === name, seen: "monitor " + (focused ? focused.name : "none") + " has the focus" };
    },
    workspace: id => state => {
        const focused = focusedMonitor(state);
        const shown = focused === null ? null : focused.activeWorkspace.id;
        return { met: shown === id, seen: "workspace " + shown + " is shown on the focused monitor" };
    },
    special: want => state => {
        const focused = focusedMonitor(state);
        const shown = focused === null ? "" : focused.specialWorkspace.name;
        return { met: shown === want, seen: shown === "" ? "no special workspace is shown" : shown + " is shown" };
    },
    // A new mapped window that `match` accepts, absent from `before`.
    appears: (before, match) => state => {
        const old = new Set(before.clients.map(c => lower(c.address)));
        const fresh = state.clients.filter(c => c.mapped && !old.has(lower(c.address)));
        const found = fresh.find(match);
        return { met: found !== undefined, seen: found !== undefined ? "new window " + describe(found, state)
            : fresh.length === 0 ? "no new window" : "new windows of other classes: "
                + fresh.map(c => JSON.stringify(c.class)).join(", ") };
    }
};

// Hyprland's fullscreen state is a bit set: 1 maximized, 2 fullscreen.
const MODE_BIT = { maximized: 1, fullscreen: 2 };
const wanted = (action, before) => action === "set" ? true : action === "unset" ? false : !before;

/**
 * Each changing tool's plan from its arguments and the state read before
 * it: the requests in order, each with the state that proves it, and the
 * outcome when that state does not appear. A plan needing a target that is
 * not there fails before any request.
 */
const PLANS = {
    "windows.focus": (a, before) => targetWindow(a.window, before, address => [step("compositor.focusWindow", [address], expect.active(address))]),
    "windows.reveal": (a, before) => targetWindow(a.window, before, address => [step("compositor.reveal", [address], expect.active(address))]),
    "windows.move": (a, before) => targetWindow(a.window, before, address => [step("compositor.moveWindow", [address, a.x, a.y],
        expect.field(address, "at", at => at[0] === a.x && at[1] === a.y))]),
    "windows.resize": (a, before) => targetWindow(a.window, before, address => [step("compositor.resizeWindow", [address, a.width, a.height],
        expect.field(address, "size", size => size[0] === a.width && size[1] === a.height))]),
    // An application can keep its window open, such as to ask about unsaved
    // work, so a window still open is not proof that close failed.
    "windows.close": (a, before) => targetWindow(a.window, before, address => [step("compositor.closeWindow", [address], expect.closed(address))], "unknown"),
    // Fullscreen acts on the focused window: focus the target, read that
    // focus back, then request the mode.
    "windows.fullscreen": (a, before) => targetWindow(a.window, before, address => {
        const bit = MODE_BIT[a.mode];
        const want = wanted(a.action, (clientOf(before, address).fullscreen & bit) !== 0);
        return [step("compositor.focusWindow", [address], expect.active(address)),
            step("compositor.fullscreenWindow", [a.mode, a.action],
                expect.field(address, "fullscreen", value => ((value & bit) !== 0) === want))];
    }),
    "windows.float": (a, before) => targetWindow(a.window, before, address => {
        const want = wanted(a.action, clientOf(before, address).floating);
        return [step("compositor.floatWindow", [address, a.action], expect.field(address, "floating", value => value === want))];
    }),
    "windows.workspace": (a, before) => targetWindow(a.window, before, address => [step("compositor.moveWindowToWorkspace",
        [address, String(a.workspace)], expect.field(address, "workspace", ws => ws.id === a.workspace, ws => JSON.stringify(ws.name)))]),
    "windows.monitor": (a, before) => {
        const monitor = before.monitors.find(m => m.name === a.monitor || String(m.id) === a.monitor);
        if (monitor === undefined) throw failed("No monitor is named " + JSON.stringify(a.monitor) + ".");
        return { steps: [step("compositor.focusMonitor", [monitor.name], expect.monitor(monitor.name))], unmet: "failed" };
    },
    "workspaces.focus": a => ({ steps: [step("compositor.focusWorkspace", [String(a.workspace)], expect.workspace(a.workspace))], unmet: "failed" }),
    "workspaces.special": (a, before) => {
        const focused = focusedMonitor(before);
        const name = "special:" + a.name;
        const shown = focused === null ? "" : focused.specialWorkspace.name;
        return { steps: [step("compositor.toggleSpecialWorkspace", [a.name], expect.special(shown === name ? "" : name))], unmet: "failed" };
    }
};

function step(kind, args, judge) { return { kind, args, judge }; }

function targetWindow(value, before, steps, unmet = "failed") {
    const address = lower(value);
    if (clientOf(before, address) === undefined) throw failed("Window " + address + " is not open.");
    return { steps: steps(address), unmet };
}

/**
 * create({Dispatch, Launch, request, environment, clock, bounds, commands})
 * builds the four executor records the router registers, sharing one
 * Hyprland reader and one lifetime. Dispatch is the core's batch reader and
 * Launch the shared launch rule, shell/Commons/DesktopLaunch.js, both loaded
 * from the VGS tree. request(kind, args, timeoutMs, done) is
 * ShellRequests.send. environment is hyprctl's whole environment.
 * commands lists the optional commands present beside hyprctl.
 */
function create({ Dispatch, Launch, request, environment, clock, bounds = BOUNDS, commands = [] }) {
    const children = new Set();
    let closed = false;

    // A poll's wait is at most pollMs; after close its next read refuses.
    function sleep(ms) {
        return new Promise(resolve => clock.set(resolve, ms));
    }

    function hyprctl(args) {
        return new Promise((resolve, reject) => {
            if (closed) { reject(new Error("closed")); return; }
            const child = cp.execFile("hyprctl", args, { env: environment, encoding: "utf8",
                timeout: bounds.hyprctlMs, maxBuffer: bounds.hyprctlBytes, killSignal: "SIGKILL" }, (error, stdout) => {
                children.delete(child);
                if (error === null) resolve(stdout);
                else reject(new Error(error.code === "ERR_CHILD_PROCESS_STDIO_MAXBUFFER" ? "output-limit"
                    : error.killed ? "timeout" : "exit=" + error.code));
            });
            children.add(child);
        });
    }

    // One batch read through its Dispatch parser; any failure ends the call.
    async function read(batch, parse, label) {
        let text;
        try { text = await hyprctl(["--batch", batch]); }
        catch (error) { throw failed("Hyprland " + label + " could not be read: hyprctl " + error.message + "."); }
        const value = parse(text);
        if (!value.ok) throw failed("Hyprland " + label + " could not be read: " + value.error + ".");
        return value;
    }

    const state = () => read(Dispatch.REVEAL_STATE_REQUEST, Dispatch.revealState, "state");

    async function ask(kind, args) {
        const reply = await new Promise(resolve => request(kind, args, bounds.requestMs, resolve));
        switch (reply.kind) {
        case "answer":
            if (reply.answer !== "ok") throw failed("The shell refused " + kind + ": " + reply.answer);
            return reply.data;
        case "busy": throw failed("Too many desktop requests await the shell.");
        case "refused": throw failed("The request could not be sent: " + reply.reason);
        // The shell may still act on it, so the effect is undecided.
        case "timeout": throw new Ended("unknown", "The shell did not answer " + kind + " within " + bounds.requestMs + " ms.");
        default: throw new Error("jarvis: desktop=reply-kind");
        }
    }

    /**
     * The read-back judge: poll Hyprland until `judge` sees the effect or
     * `deadline` ms pass. A read that fails after a request is not proof
     * either way, so it answers unread.
     */
    async function settle(judge, deadline) {
        const start = clock.now();
        for (;;) {
            let verdict;
            try { verdict = judge(await state()); }
            catch (error) {
                if (!(error instanceof Ended)) throw error;
                return { kind: "unread", seen: error.value.content };
            }
            if (verdict.met) return { kind: "met", seen: verdict.seen };
            if (clock.now() - start >= deadline) return { kind: "unmet", seen: verdict.seen };
            await sleep(bounds.pollMs);
        }
    }

    async function change(call) {
        const plan = PLANS[call.id](call.args, await state());
        let seen = "";
        for (const { kind, args, judge } of plan.steps) {
            await ask(kind, args);
            const result = await settle(judge, bounds.settleMs);
            if (result.kind === "unread") return { outcome: "unknown", content: "The change was requested. " + result.seen };
            if (result.kind === "unmet")
                return { outcome: plan.unmet, content: "The shell accepted " + kind + ", but Hyprland did not show the change within "
                    + bounds.settleMs + " ms. Read back: " + result.seen + "." };
            seen = result.seen;
        }
        return { outcome: "completed", content: "Read back: " + seen + "." };
    }

    async function windows(call) {
        if (call.id === "windows.list") {
            const s = await state();
            const mapped = s.clients.filter(c => c.mapped);
            return { outcome: "completed", content: [mapped.length + " windows"].concat(mapped.map(c => describe(c, s))).join("\n") };
        }
        const { workspaces, monitors } = await read(Dispatch.WORKSPACE_STATE_REQUEST, Dispatch.workspaceState, "workspaces");
        const lines = workspaces.slice().sort((a, b) => a.id - b.id).map(w => {
            const shown = monitors.filter(m => m.activeWorkspace.id === w.id || m.specialWorkspace.id === w.id);
            return "workspace id=" + w.id + " name=" + JSON.stringify(w.name) + " monitor=" + w.monitor + " windows=" + w.windows
                + (shown.length ? " shown" + (shown.some(m => m.focused) ? " focused" : "") : "");
        });
        return { outcome: "completed", content: [lines.length + " workspaces"].concat(lines).join("\n") };
    }

    async function apps(call) {
        if (call.id === "apps.list") {
            const data = await ask("desktop.list", []);
            // A query keeps a desktop with hundreds of entries under the
            // router's result bound: it matches the id or name, ignoring case.
            const query = (call.args.query || "").toLowerCase();
            const lines = data.entries.filter(e => (e.id + "\n" + e.name).toLowerCase().includes(query))
                .map(e => e.id + " name=" + JSON.stringify(e.name));
            return { outcome: "completed", content: [lines.length + " applications" + (data.complete ? "" : " (list cut)")].concat(lines).join("\n") };
        }
        const before = await state();
        let match, label;
        if (call.id === "apps.launch") {
            // The service launches the entry by the shared launch rule and
            // answers what the read-back needs. A terminal entry's window
            // carries the terminal's class, not the application's.
            const entry = await ask("desktop.launch", [call.args.desktop.replace(/\.desktop$/, "")]);
            const classes = [entry.startupClass, entry.id].filter(Boolean).map(value => value.toLowerCase());
            match = entry.terminal ? () => true
                : c => classes.includes(lower(c.class)) || classes.includes(lower(c.initialClass));
            label = JSON.stringify(entry.name || entry.id);
        } else {
            const target = call.id === "apps.open" ? call.args.path : call.args.url;
            await ask("run.detached", Launch.open(target));
            match = () => true;
            label = JSON.stringify(target);
        }
        const result = await settle(expect.appears(before, match), bounds.launchMs);
        if (result.kind === "met") return { outcome: "completed", content: "Started " + label + ". Read back: " + result.seen + "." };
        return { outcome: "unknown", content: "The shell started " + label + ", but no window of it appeared within "
            + bounds.launchMs + " ms. It may still be starting, run without a window, or have opened in an existing window. Read back: "
            + result.seen + "." };
    }

    async function wire(call) {
        await ask("toast", [call.args.title, call.args.body]);
        // The reply proves the core took the toast; it may wait in the
        // core's queue behind others before it is drawn.
        return { outcome: "completed", content: "The notice was posted." };
    }

    function executor(run, commandsPresent, timeoutMs) {
        return {
            commands: commandsPresent, timeoutMs, cancellable: false,
            start(call, done) {
                run(call).then(done, error => {
                    if (error instanceof Ended) done(error.value);
                    else done({ outcome: "failed", content: "desktop-executor-error" });
                });
            }
        };
    }

    // Each timeoutMs is the longest path's bounds: the state read before a
    // change, each request with its settle, whose last read can start just
    // before the settle deadline and take a whole hyprctl bound.
    const hyprctlWorst = bounds.hyprctlMs;
    const settleWorst = bounds.requestMs + bounds.settleMs + bounds.pollMs + hyprctlWorst;
    const records = {
        windows: executor(windows, ["hyprctl"], hyprctlWorst + bounds.slackMs),
        // Fullscreen's two steps are the longest plan.
        compositor: executor(change, ["hyprctl"], hyprctlWorst + 2 * settleWorst + bounds.slackMs),
        apps: executor(apps, ["hyprctl"].concat(commands.filter(c => c === "gio")),
            hyprctlWorst + bounds.requestMs + bounds.launchMs + bounds.pollMs + hyprctlWorst + bounds.slackMs),
        wire: executor(wire, [], bounds.requestMs + bounds.slackMs)
    };

    // Lease loss: no read starts after close, and a read in flight ends.
    function close() {
        closed = true;
        for (const child of children) child.kill("SIGKILL");
    }

    // The vision executor's reading of the same state: {kind:"state", state}
    // or {kind:"failed", content}, content naming the failed read.
    function reading() {
        return state().then(value => ({ kind: "state", state: value }), error => {
            if (error instanceof Ended) return { kind: "failed", content: error.value.content };
            throw error;
        });
    }

    return Object.freeze({ records, probe: state, reading, close });
}

/**
 * install(options) registers the wire executor at once and the Hyprland
 * executors once one state read answers, the probe that proves hyprctl
 * reaches this session. Without it those tools stay unoffered. The lifetime
 * lends its reader to the vision executor: ready resolves whether the probe
 * registered the Hyprland executors, read is create's reading, readMs one
 * read's bound.
 */
function install({ router, ...options }) {
    const desktop = create(options);
    let lifetime = "open";
    router.register("wire", desktop.records.wire);
    const ready = desktop.probe().then(() => {
        if (lifetime !== "open") return false;
        for (const id of ["windows", "compositor", "apps"]) router.register(id, desktop.records[id]);
        return true;
    }, () => {
        // No reachable Hyprland: its tools stay unoffered, as a missing
        // command's do. The router refuses a call for them as unavailable.
        return false;
    });
    return { ready, read: desktop.reading, readMs: (options.bounds || BOUNDS).hyprctlMs,
        close() { lifetime = "closed"; desktop.close(); } };
}

module.exports = { create, install };
