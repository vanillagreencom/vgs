// Executors for the Tools rows whose executor is clipboard, media or notify.
// ARGV is the one map from a frozen call to the arguments and stdin of the
// command its Tools row names. Each command runs as a bounded Child, without a
// shell, in its own process group, with only the variables ENVIRONMENT lists,
// under setpriv's parent-death signal: a daemon killed outright takes its
// running command with it. The kernel clears that signal across fork, so the
// server wl-copy forks keeps the selection.
// Policy, approval, audit and the result's release label stay with the router.
"use strict";
const Child = require("./Child.js");
const Tools = require("./Tools.js");

// The plan's command output bound (§ 3.11), above the router's own
// tool-result bound.
const LIMIT = 64 * 1024;
// Recovery bounds for a compositor, bus or daemon that never answers, not
// measured latency budgets. Session's limit outlasts the child's own end, so
// a stopped child reports its outcome before Session gives up on it.
const DEADLINE = 10000;
const TIMEOUT = 12000;
const SINK = "@DEFAULT_AUDIO_SINK@";
// An explicit type: without one wl-copy runs xdg-mime to infer it.
const TEXT_TYPE = "text/plain;charset=utf-8";
// Password managers offer this type beside a copied secret. Omarchy's
// clipboard capture skips such a copy; this read refuses it.
const PASSWORD_HINT = "x-kde-passwordManagerHint";
// wl-paste's words for a selection with no offer, compared with the first
// line of its stderr (wl-clipboard 2.3.0 src/wl-paste.c). Not a failure.
const EMPTY_SELECTION = ["Nothing is copied"];

// Variables each command reads, beside PATH and a fixed C.UTF-8 locale that
// keeps a decimal point a point. No other daemon variable reaches a child.
const ENVIRONMENT = {
    "wl-paste": ["WAYLAND_DISPLAY", "XDG_RUNTIME_DIR"],
    "wl-copy": ["WAYLAND_DISPLAY", "XDG_RUNTIME_DIR"],
    "playerctl": ["DBUS_SESSION_BUS_ADDRESS", "XDG_RUNTIME_DIR"],
    "wpctl": ["XDG_RUNTIME_DIR"],
    "brightnessctl": [],
    "notify-send": ["DBUS_SESSION_BUS_ADDRESS", "XDG_RUNTIME_DIR"]
};

// clipboard.read lists the offered types before it reads any byte.
const OFFERS = { args: ["--list-types"] };
const ARGV = {
    "clipboard.read": () => ({ args: ["--no-newline", "--type", "text"] }),
    // Text goes through stdin: argv is readable in /proc. wl-copy forks a
    // server that keeps the selection after wl-copy exits 0, so its output
    // goes to /dev/null rather than into pipes that server would hold open.
    "clipboard.write": args => ({ args: ["--type", TEXT_TYPE], input: args.text, output: "ignore" }),
    "media.play": () => ({ args: ["play"] }),
    "media.pause": () => ({ args: ["pause"] }),
    "media.next": () => ({ args: ["next"] }),
    "media.volume": args => ({ args: ["set-volume", SINK, args.value.toFixed(2)] }),
    "media.mute": args => ({ args: ["set-mute", SINK, args.muted ? "1" : "0"] }),
    // The backlight class keeps a keyboard LED out of reach.
    "media.brightness": args => ({ args: ["--quiet", "--class=backlight", "set", args.value + "%"] }),
    // After --, model text cannot become an option.
    "notify.notification": args => ({ args: ["--app-name=Jarvis", "--", args.title, args.body] })
};

// Omarchy's clipboard capture reads these offers as text.
const textOffer = type => type.startsWith("text/") || type === "UTF8_STRING" || type === "STRING";
const answer = (outcome, value) => ({ outcome, content: typeof value === "string" ? value : JSON.stringify(value) });
const refuse = reason => answer("failed", { kind: "refuse", reason });

function detail(stderr) {
    const line = stderr.split("\n").find(text => text.trim() !== "") ?? "";
    return line.replace(/[\x00-\x1f\x7f]/g, " ").trim().slice(0, 200);
}

// A child's end that is not its success. A tool that ran but did not exit
// with a code may have acted; only a read can call that a plain failure.
function failure(call, command, result) {
    const unsure = Tools.TABLE[call.id].effect === "read" ? "failed" : "unknown";
    switch (result.kind) {
    case "exited":
        if (result.code === null) return answer(unsure, { kind: "failed", command, signal: result.signal });
        return answer("failed", { kind: "failed", command, code: result.code, detail: detail(result.stderr) });
    case "stopped": return answer(unsure, { kind: "stopped", command, reason: result.reason });
    case "error": return answer("failed", { kind: "failed", command, reason: result.reason, error: result.error });
    default: throw new Error("jarvis: desktop=child-result kind=" + result.kind);
    }
}

const emptySelection = result => result.kind === "exited" && result.code !== 0
    && EMPTY_SELECTION.includes(result.stderr.split("\n")[0].trim());

/**
 * Build the router's executor record for Tools executor id: "clipboard",
 * "media" or "notify". commands maps each present command to the absolute
 * file the probe found. environment is the daemon's own; ENVIRONMENT picks
 * from it per command. cancel(call) ends that call's process group.
 */
function create(id, { commands, environment, clock }) {
    const rows = Object.keys(Tools.TABLE).filter(tool => Tools.TABLE[tool].executor === id);
    if (rows.length === 0 || !rows.every(tool => Object.hasOwn(ARGV, tool)))
        throw new Error("jarvis: desktop=executor id=" + id);
    const running = new Map();

    function run(command, plan, signal) {
        const file = commands.get(command);
        if (file === undefined) throw new Error("jarvis: desktop=command-absent command=" + command);
        const env = { LC_ALL: "C.UTF-8" };
        for (const name of ["PATH", ...ENVIRONMENT[command]])
            if (environment[name] !== undefined) env[name] = environment[name];
        return Child.run("setpriv", ["--pdeathsig", "KILL", "--", file, ...plan.args], { env, limit: LIMIT,
            deadline: DEADLINE, group: true, input: plan.input, output: plan.output, signal, clock });
    }

    async function perform(call, signal) {
        const command = Tools.TABLE[call.id].command;
        const read = call.id === "clipboard.read";
        if (read) {
            const offers = await run(command, OFFERS, signal);
            if (emptySelection(offers)) return answer("completed", "");
            if (offers.kind !== "exited" || offers.code !== 0) return failure(call, command, offers);
            const types = offers.stdout.split("\n").filter(type => type !== "");
            if (types.includes(PASSWORD_HINT)) return refuse("clipboard-password");
            if (types.length === 0) return answer("completed", "");
            if (!types.some(textOffer)) return refuse("clipboard-not-text");
        }
        const result = await run(command, ARGV[call.id](call.args), signal);
        if (result.kind === "exited" && result.code === 0) return answer("completed", read ? result.stdout : { kind: "done" });
        if (read && emptySelection(result)) return answer("completed", "");
        // The router cuts a long result to its own bound and marks the cut.
        if (read && result.kind === "stopped" && result.reason === "output-limit")
            return answer("completed", result.stdout);
        return failure(call, command, result);
    }

    function start(call, done) {
        if (!rows.includes(call.id) || running.has(call)) throw new Error("jarvis: desktop=call id=" + call.id);
        const abort = new AbortController();
        running.set(call, abort);
        // Like the router's own start, an internal error becomes a failed
        // outcome without its text.
        perform(call, abort.signal).catch(() => answer("failed", "executor-failed")).then(value => {
            running.delete(call);
            done(value);
        });
    }

    return { commands: [...commands.keys()], timeoutMs: TIMEOUT, cancellable: true, start,
        cancel: call => { running.get(call)?.abort(); } };
}

module.exports = { create };
