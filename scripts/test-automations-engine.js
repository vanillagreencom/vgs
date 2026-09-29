#!/usr/bin/env node
// The automations engine, shell/plugins/vgs.automations/bin/automations,
// end to end: the store verbs, sync against a stand-in systemctl and a
// stand-in crontab, the runner (success, a non-zero exit, a timeout that
// ends the command's process group, a failed start, the transcript cap, the
// records it writes before and after the command), the notifications it
// sends through a stand-in notify-send, run-now through a stand-in
// systemd-run, the scheduled trigger's guard, history with a running and a
// vanished run, clear and pruning with the plugin's historyDays setting, a
// timed-out run that waits for a descendant ignoring SIGTERM, and output
// with no line break, which reaches the transcript in pieces. The snippet
// keeps each candidate line cut to what a snippet shows; that bounds the
// runner's memory alone and changes no snippet, so no case reddens without
// it, and the snippet rows hold what a snippet shows.
//
// Every case runs in its own scratch home with a PATH of stand-ins and an
// allow-list of host tools, and an XDG_RUNTIME_DIR of its own with no
// session bus: no case can reach the user's systemd manager, crontab,
// notification server or ~/.config/systemd. The command under test runs in
// the user's login shell, as the runner runs it, so every command here is
// valid in sh, bash, zsh and fish.
//
// The controls at the end edit a copy of the engine, one rule at a time,
// and require the case that rule serves to fail on the copy.
"use strict";
const assert = require("node:assert/strict");
const childProcess = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { load } = require("../bin/lib/qml-library.js");

// The cases and the engine read local time in one zone.
process.env.TZ = "UTC";
const repo = path.join(__dirname, "..");
const pluginDir = path.join(repo, "shell", "plugins", "vgs.automations");
const Logic = load(path.join(pluginDir, "AutomationsLogic.js"));
const scratch = path.join(repo, "tmp", "test-automations-engine-" + process.pid);
// The host tools a case may run: the engine's own, the ones vgsh plugin
// settings needs, and the ones the commands under test use. systemctl,
// systemd-run, loginctl, crontab and notify-send are stand-ins alone.
const TOOLS = ["bash", "sh", "env", "flock", "sleep", "yes", "head", "cat", "python3", "systemd-analyze", "dirname", "readlink", "basename", "mkdir", "rm", "mv", "cp", "ls", "id", "date", "sed", "grep", "tr", "mktemp", "true", "false", "realpath", "stat", "sort", "uname", "wc", "cut", "awk", "touch", "chmod", "ln", "find", "tail", "tee", "kill", "setsid", "printf", "test"];
const FORBIDDEN = ["systemctl", "systemd-run", "loginctl", "crontab", "notify-send"];

// ------------------------------------------------------------ the world

function which(command) {
    for (const dir of String(process.env.PATH || "").split(path.delimiter)) {
        const candidate = path.join(dir, command);
        try {
            fs.accessSync(candidate, fs.constants.X_OK);
            if (fs.statSync(candidate).isFile()) return fs.realpathSync(candidate);
        } catch (_e) {
            // Keep looking.
        }
    }
    return null;
}

function write(file, text, mode) {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, text, { mode: mode || 0o644 });
}

// The stand-ins: each appends its argv, one JSON list a line, to
// $STUB/<name>.calls. systemctl answers show-environment with
// $STUB/systemd (up or down); systemd-run runs the argv after `--`;
// notify-send prints the next id; crontab keeps the table in $STUB/crontab;
// loginctl answers $STUB/linger.
const STUBS = {
    systemctl: `#!/usr/bin/env bash
printf '%s\\n' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "$@")" >>"$STUB/systemctl.calls"
if [[ \${2:-} == show-environment ]]; then [[ $(<"$STUB/systemd") == up ]] || exit 1; fi
exit 0
`,
    "systemd-run": `#!/usr/bin/env bash
printf '%s\\n' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "$@")" >>"$STUB/systemd-run.calls"
while [[ $# -gt 0 && $1 != -- ]]; do
  case "$1" in --setenv=*) export "\${1#--setenv=}" ;; esac
  shift
done
shift
"$@" >>"$STUB/systemd-run.out" 2>&1 || true
`,
    "notify-send": `#!/usr/bin/env bash
printf '%s\\n' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "$@")" >>"$STUB/notify-send.calls"
n=$(( $(wc -l <"$STUB/notify-send.calls") + 40 ))
printf '%s\\n' "$n"
`,
    crontab: `#!/usr/bin/env bash
printf '%s\\n' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "$@")" >>"$STUB/crontab.calls"
case "$1" in
  -l) if [[ -f $STUB/crontab ]]; then cat "$STUB/crontab"; else echo "no crontab for $(id -un)" >&2; exit 1; fi ;;
  -) cat >"$STUB/crontab" ;;
  *) exit 2 ;;
esac
`,
    loginctl: `#!/usr/bin/env bash
printf '%s\\n' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "$@")" >>"$STUB/loginctl.calls"
cat "$STUB/linger"
`
};

let worlds = 0;
// A fresh home, stand-ins and PATH. `stubs` names the stand-ins present;
// systemd `up` or `down`.
function world(options) {
    const opts = Object.assign({ systemd: "up", stubs: FORBIDDEN, linger: "no" }, options || {});
    const root = path.join(scratch, "w" + (worlds += 1));
    const stub = path.join(root, "stub");
    const bin = path.join(root, "bin");
    const tools = path.join(root, "tools");
    fs.mkdirSync(stub, { recursive: true });
    fs.mkdirSync(tools, { recursive: true });
    fs.mkdirSync(path.join(root, "home"), { recursive: true });
    fs.mkdirSync(path.join(root, "run"), { recursive: true, mode: 0o700 });
    for (const name of opts.stubs) write(path.join(bin, name), STUBS[name], 0o755);
    fs.mkdirSync(bin, { recursive: true });
    for (const tool of TOOLS) {
        const real = which(tool);
        if (real !== null) fs.symlinkSync(real, path.join(tools, tool));
    }
    fs.symlinkSync(process.execPath, path.join(tools, "node"));
    write(path.join(stub, "systemd"), opts.systemd + "\n");
    write(path.join(stub, "linger"), opts.linger + "\n");
    const home = path.join(root, "home");
    return {
        root, stub, home,
        runs: path.join(home, ".local", "state", "vgs", "automations", "runs"),
        units: path.join(home, ".config", "systemd", "user"),
        store: path.join(home, ".config", "vgs", "automations", "automations.json"),
        env: { HOME: home, PATH: bin + ":" + tools, XDG_RUNTIME_DIR: path.join(root, "run"), STUB: stub, LANG: "C.UTF-8", TZ: "UTC" }
    };
}

function cli(w, engine, args, options) {
    const out = childProcess.spawnSync(engine, ["--tree", repo].concat(args), Object.assign({ encoding: "utf8", env: w.env, cwd: w.home, timeout: 60000 }, options || {}));
    return { status: out.status, stdout: out.stdout, stderr: out.stderr, first: (out.stderr || "").split("\n")[0] };
}

function calls(w, name) {
    const file = path.join(w.stub, name + ".calls");
    return fs.existsSync(file) ? fs.readFileSync(file, "utf8").trim().split("\n").filter(Boolean).map(JSON.parse) : [];
}

function def(extra) {
    return Object.assign({ name: "Job", command: "echo done", schedule: { frequency: "daily", interval: 1, times: ["09:00"], start: "2026-01-01", end: { type: "never" } } }, extra);
}

function add(w, engine, extra) {
    const out = cli(w, engine, ["add", "--definition", JSON.stringify(def(extra))]);
    assert.equal(out.status, 0, "add: " + out.stderr);
    return out.stdout.trim().split("\n").pop().replace(/^added=/, "");
}

function runFiles(w) {
    return fs.existsSync(w.runs) ? fs.readdirSync(w.runs).sort() : [];
}

function ended(w, id) {
    const names = runFiles(w).filter(n => n.startsWith(id + "@") && n.endsWith(".ended.json"));
    assert.equal(names.length, 1, "one ended record for " + id + ": " + runFiles(w).join(" "));
    return JSON.parse(fs.readFileSync(path.join(w.runs, names[0]), "utf8"));
}

function manual(w, engine, id) {
    return cli(w, engine, ["run", "--manual", id]);
}

// ------------------------------------------------------------ the cases

const CASES = {
    "sync with nothing runs nothing"(engine) {
        const w = world();
        const out = cli(w, engine, ["sync"]);
        assert.equal(out.stdout, "sync=idle changed=0\n");
        for (const name of FORBIDDEN) same(calls(w, name), [], "no " + name + " call");
        assert.equal(fs.existsSync(w.units), false);
    },

    "add writes the units, reloads and enables the timer"(engine) {
        const w = world();
        const id = add(w, engine, { name: "Back up", schedule: { frequency: "weekly", interval: 2, weekdays: ["mon", "thu"], times: ["08:30", "17:00"], start: "2026-01-05", end: { type: "never" } }, catchUp: true });
        assert.equal(id, "back-up");
        same(calls(w, "systemctl"), [["--user", "show-environment"], ["--user", "daemon-reload"], ["--user", "enable", "--now", "vgs-automation-back-up.timer"]]);
        const timer = fs.readFileSync(path.join(w.units, "vgs-automation-back-up.timer"), "utf8");
        assert.match(timer, /\nOnCalendar=Mon,Thu \*-\*-\* 08:30:00\nOnCalendar=Mon,Thu \*-\*-\* 17:00:00\n/);
        assert.match(timer, /\nPersistent=true\n/);
        const service = fs.readFileSync(path.join(w.units, "vgs-automation-back-up.service"), "utf8");
        const exec = /\nExecStart=(.*)\n/.exec(service)[1];
        assert.match(exec, /^"[^"]*\/flock" "-n" "-E" "75" "-o" "[^"]*\/locks\/back-up\.lock" "[^"]*node[^"]*" "[^"]*\/engine\/[0-9a-f]{16}\/bin\/automations" "--tree" "[^"]*" "run" "--scheduled" "back-up"$/);
        const engineCopy = /"([^"]*\/engine\/[0-9a-f]{16})\/bin\/automations"/.exec(exec)[1];
        assert.equal(fs.readFileSync(path.join(engineCopy, "AutomationsLogic.js"), "utf8"), fs.readFileSync(path.join(pluginDir, "AutomationsLogic.js"), "utf8"), "the units run a copy of the judge");
        assert.ok(JSON.parse(fs.readFileSync(path.join(w.home, ".local", "state", "vgs", "automations", "guard", "back-up.json"), "utf8")).handledThrough > Date.now() - 60000, "add marks the past handled");
        const refused = cli(w, engine, ["add", "--definition", JSON.stringify(def({ command: "a\nb" }))]);
        assert.equal(refused.status, 1);
        assert.equal(refused.first, "automations: refused: definition=definition.command:-want=one-line-of-1..4096");
        assert.equal(JSON.parse(fs.readFileSync(w.store, "utf8")).automations.length, 1, "a refused add leaves the store");
        assert.equal(cli(w, engine, ["add", "--definition", "{"]).first, "automations: refused: definition=not-json");
    },

    "edit, disable, enable and remove follow the store"(engine) {
        const w = world();
        const id = add(w, engine, {});
        fs.rmSync(path.join(w.stub, "systemctl.calls"));
        assert.equal(cli(w, engine, ["edit", id, "--definition", JSON.stringify({ schedule: { frequency: "yearly", interval: 1, yearly: { month: 3, day: 15 }, times: ["07:00"], start: "2026-01-01", end: { type: "never" } } })]).status, 0);
        assert.match(fs.readFileSync(path.join(w.units, "vgs-automation-job.timer"), "utf8"), /\nOnCalendar=\*-03-15 07:00:00\n/);
        same(calls(w, "systemctl").slice(1), [["--user", "daemon-reload"], ["--user", "enable", "--now", "vgs-automation-job.timer"], ["--user", "restart", "vgs-automation-job.timer"]], "a changed timer restarts");
        fs.rmSync(path.join(w.stub, "systemctl.calls"));
        assert.equal(cli(w, engine, ["disable", id]).stdout.trim().split("\n").pop(), "disabled=job");
        same(calls(w, "systemctl").slice(1), [["--user", "disable", "--now", "vgs-automation-job.timer"], ["--user", "daemon-reload"]]);
        same(fs.readdirSync(w.units), []);
        assert.equal(cli(w, engine, ["enable", id]).status, 0);
        same(fs.readdirSync(w.units).sort(), ["vgs-automation-job.service", "vgs-automation-job.timer"]);
        assert.equal(manual(w, engine, id).status, 0);
        assert.equal(cli(w, engine, ["remove", id]).stdout.trim().split("\n").pop(), "removed=job");
        same(fs.readdirSync(w.units), []);
        same(runFiles(w), [], "remove drops the automation's runs");
        same(JSON.parse(fs.readFileSync(w.store, "utf8")).automations, []);
        assert.equal(cli(w, engine, ["remove", id]).first, "automations: refused: id=unknown value=job");
    },

    "a run that succeeds writes both records and its transcript"(engine) {
        const w = world();
        const id = add(w, engine, { command: "echo one; echo two >&2; cat " + JSON.stringify(w.runs) + "/job@$VGS_AUTOMATION_RUN.started.json" });
        const out = manual(w, engine, id);
        assert.equal(out.status, 0, out.stderr);
        const rec = ended(w, id);
        same([rec.outcome, rec.exitCode, rec.signal, rec.trigger, rec.slot, rec.truncated, rec.snippet], ["succeeded", 0, null, "manual", null, false, ""]);
        assert.equal(Logic.recordError(rec, "ended"), "");
        const files = runFiles(w);
        same(files.map(n => n.replace(/@\d+-\d+/, "@R")), ["job@R.ended.json", "job@R.log", "job@R.started.json"], "no temporary file is left");
        const transcript = fs.readFileSync(rec.transcript, "utf8");
        assert.match(transcript, /^# vgs\.automations run \d+-\d+\n# automation: job \(Job\)\n# command: echo one/);
        assert.match(transcript, /\n\d\d:\d\d:\d\d\.\d{3} out \| one\n/);
        assert.match(transcript, /\n\d\d:\d\d:\d\d\.\d{3} err \| two\n/);
        assert.match(transcript, /\n\d\d:\d\d:\d\d\.\d{3} out \| \{"version":1,"automation":"job"/, "the started record is on disk before the command runs");
        assert.match(transcript, /\n# outcome: succeeded exit=0\n# duration: \d+ s\n$/);
        same(calls(w, "notify-send"), [], "a success sends nothing without notifyEveryRun");
    },

    "a failing run sends the error notification whatever the toggle"(engine) {
        const w = world();
        const id = add(w, engine, { name: "Nightly <sync>", command: "echo fine; echo 'disk full' >&2; exit 3" });
        assert.equal(manual(w, engine, id).status, 1);
        const rec = ended(w, id);
        same([rec.outcome, rec.exitCode, rec.snippet], ["failed", 3, "disk full"]);
        same(calls(w, "notify-send"), [["--app-name=Automations", "--urgency=critical", "--print-id", "--hint=string:x-vgs-icon:circle-x", "--hint=string:x-vgs-tone:danger", "--hint=string:x-vgs-click:open", "--hint=string:x-vgs-open:" + rec.transcript, "--", "Nightly <sync> failed", "Exit code 3\ndisk full"]]);
    },

    "notifyEveryRun sends the start, then replaces it with the finish"(engine) {
        const w = world();
        const id = add(w, engine, { notifyEveryRun: true });
        assert.equal(manual(w, engine, id).status, 0);
        const rec = ended(w, id);
        same(calls(w, "notify-send"), [
            ["--app-name=Automations", "--urgency=low", "--print-id", "--hint=string:x-vgs-icon:play", "--hint=string:x-vgs-tone:warning", "--hint=string:x-vgs-click:none", "--", "Job started", "echo done"],
            ["--app-name=Automations", "--urgency=low", "--print-id", "--hint=string:x-vgs-icon:circle-check", "--hint=string:x-vgs-tone:success", "--hint=string:x-vgs-click:open", "--hint=string:x-vgs-open:" + rec.transcript, "--replace-id=41", "--", "Job finished", "Finished in 0 s"]
        ]);
    },

    "a timeout ends the command's whole process group"(engine) {
        const w = world();
        const pidFile = path.join(w.root, "grandchild.pid");
        const id = add(w, engine, { command: "sh -c 'sleep 30 & echo $! > " + pidFile + "; wait'", timeoutSeconds: 1 });
        const started = Date.now();
        assert.equal(manual(w, engine, id).status, 1);
        assert.ok(Date.now() - started < 15000, "the timeout ended the run");
        const rec = ended(w, id);
        same([rec.outcome, rec.reason], ["timeout", "timeout=1s"]);
        const pid = Number(fs.readFileSync(pidFile, "utf8"));
        let alive = true;
        try {
            process.kill(pid, 0);
        } catch (_e) {
            alive = false;
        }
        if (alive) process.kill(pid, "SIGKILL");
        assert.equal(alive, false, "the command's background child was ended too");
        assert.match(calls(w, "notify-send")[0].slice(-1)[0], /^Timed out after 1 s/);
    },

    "a missing working directory is a failed start"(engine) {
        const w = world();
        const id = add(w, engine, { workingDirectory: path.join(w.root, "gone") });
        assert.equal(manual(w, engine, id).status, 1);
        const rec = ended(w, id);
        same([rec.outcome, rec.exitCode, rec.reason], ["failed-start", null, "directory=ENOENT path=" + path.join(w.root, "gone")]);
        assert.equal(calls(w, "notify-send")[0].slice(-1)[0], "Failed to start: directory=ENOENT path=" + path.join(w.root, "gone"));
    },

    "a refused store is a failed start the user is told of"(engine) {
        const w = world();
        const id = add(w, engine, {});
        fs.writeFileSync(w.store, "{ broken");
        assert.equal(cli(w, engine, ["list"]).first, "automations: refused: store=store:-not-json");
        assert.equal(manual(w, engine, id).status, 1);
        same([ended(w, id).outcome, ended(w, id).reason], ["failed-start", "store=store:-not-json"]);
        assert.equal(calls(w, "notify-send")[0].slice(-2)[0], "job failed");
    },

    "the transcript stops at its cap and the run goes on"(engine) {
        const w = world();
        const id = add(w, engine, { command: "yes line | head -n 70000; echo last" });
        assert.equal(manual(w, engine, id).status, 0);
        const rec = ended(w, id);
        assert.equal(rec.truncated, true);
        const text = fs.readFileSync(rec.transcript, "utf8");
        assert.ok(Buffer.byteLength(text) < Logic.TRANSCRIPT_MAX_BYTES + 4096, "the transcript holds the cap and its header and footer");
        assert.match(text, /\n# transcript cut at \d+ bytes; later output is not kept\n/);
        assert.doesNotMatch(text, / out \| last\n/, "output past the cap is dropped");
        assert.match(text, /\n# outcome: succeeded exit=0\n/, "the footer is written past the cap");
    },

    "output with no line break reaches the transcript in pieces"(engine) {
        const w = world();
        // 20000 characters, one line break, then a short line: under the cap.
        const long = add(w, engine, { name: "Long", command: "head -c 20000 /dev/zero | tr '\\0' y; echo; echo after" });
        assert.equal(manual(w, engine, long).status, 0);
        const rec = ended(w, long);
        const text = fs.readFileSync(rec.transcript, "utf8");
        const pieces = text.split("\n").filter(line => / out \| y+$/.test(line)).map(line => line.length - line.indexOf("| ") - 2);
        same([rec.truncated, pieces], [false, [Logic.TRANSCRIPT_LINE_MAX, Logic.TRANSCRIPT_LINE_MAX, 20000 - 2 * Logic.TRANSCRIPT_LINE_MAX]], "a long line arrives as pieces of the line ceiling");
        assert.match(text, / out \| after\n/, "the line after the long one follows it");
        // 3 MB with no line break at all: the runner holds one piece at a
        // time, so the transcript fills to its cap with pieces while the
        // pipe drains. A runner that kept the line whole would write none of
        // it, since the one line passes the cap.
        const flat = add(w, engine, { name: "Flat", command: "head -c 3000000 /dev/zero | tr '\\0' x" });
        assert.equal(manual(w, engine, flat).status, 0);
        const cut = ended(w, flat);
        const flatText = fs.readFileSync(cut.transcript, "utf8");
        assert.equal(cut.truncated, true);
        assert.match(flatText, new RegExp(" out \\| x{" + Logic.TRANSCRIPT_LINE_MAX + "}\\n"), "the first pieces are in the transcript");
        assert.ok(Buffer.byteLength(flatText) < Logic.TRANSCRIPT_MAX_BYTES + 4096, "the transcript holds the cap");
        assert.match(flatText, /\n# transcript cut at \d+ bytes; later output is not kept\n[^]*\n# outcome: succeeded exit=0\n/, "the marker and the footer follow the pieces");
    },

    "a timed-out run ends after a descendant that ignores SIGTERM"(engine) {
        const w = world();
        const pidFile = path.join(w.root, "stubborn.pid");
        const script = path.join(w.root, "stubborn.sh");
        // The descendant ignores SIGTERM and lets go of the output pipes, so
        // the shell's end closes them while it lives on.
        write(script, "#!/bin/sh\nsh -c 'trap \"\" TERM; exec </dev/null >/dev/null 2>&1; echo $$ >\"$1\"; exec sleep 60' sh \"$1\" &\nexec sleep 60\n", 0o755);
        const id = add(w, engine, { command: "sh " + script + " " + pidFile, timeoutSeconds: 1 });
        const started = Date.now();
        assert.equal(manual(w, engine, id).status, 1);
        const took = Date.now() - started;
        const pid = Number(fs.readFileSync(pidFile, "utf8"));
        let alive = true;
        try {
            process.kill(pid, 0);
        } catch (_e) {
            alive = false;
        }
        if (alive) process.kill(pid, "SIGKILL");
        assert.equal(alive, false, "the SIGTERM-proof descendant was killed before the run ended");
        assert.ok(took >= Logic.KILL_GRACE_MS, "the run waited for the SIGKILL: " + took + " ms");
        same([ended(w, id).outcome, ended(w, id).reason], ["timeout", "timeout=1s"]);
    },

    "a scheduled trigger runs only what the guard allows"(engine) {
        const w = world();
        const now = new Date();
        const pad = n => String(n).padStart(2, "0");
        const today = now.getFullYear() + "-" + pad(now.getMonth() + 1) + "-" + pad(now.getDate());
        const id = add(w, engine, { schedule: { frequency: "daily", interval: 1, times: [pad(now.getHours()) + ":" + pad(now.getMinutes())], start: today, end: { type: "never" } } });
        const skipped = cli(w, engine, ["run", "--scheduled", id]);
        same([skipped.status, skipped.first], [0, "automations: skipped=job reason=handled"], "add marked the occurrence due now handled");
        same(runFiles(w), []);
        write(path.join(w.home, ".local", "state", "vgs", "automations", "guard", "job.json"), JSON.stringify({ handledThrough: 0 }));
        assert.equal(cli(w, engine, ["run", "--scheduled", id]).status, 0);
        const rec = ended(w, id);
        same([rec.trigger, typeof rec.slot], ["scheduled", "number"]);
        assert.equal(cli(w, engine, ["run", "--scheduled", id]).first, "automations: skipped=job reason=handled", "one occurrence runs once");
        assert.equal(JSON.parse(fs.readFileSync(path.join(w.home, ".local", "state", "vgs", "automations", "guard", "job.json"), "utf8")).handledThrough, rec.slot);
        assert.equal(cli(w, engine, ["disable", id]).status, 0);
        assert.equal(cli(w, engine, ["run", "--scheduled", id]).first, "automations: skipped=job reason=paused");
    },

    "run-now goes through systemd-run and refuses a busy automation"(engine) {
        const w = world();
        const id = add(w, engine, {});
        const out = cli(w, engine, ["run-now", id]);
        assert.equal(out.stdout, "started=job\n", out.stderr);
        const call = calls(w, "systemd-run")[0];
        same(call.slice(0, 3), ["--user", "--collect", "--quiet"]);
        assert.match(call[3], /^--unit=vgs-automation-job-now-\d+$/);
        same(call.slice(4, 7).map(a => a.replace(/=.*/, "")), ["--setenv", "--setenv", "--setenv"]);
        same(call.slice(7, 13).map(a => a.replace(/^.*\//, "")), ["--", "flock", "-n", "-E", "75", "-o"]);
        same(call.slice(-3), ["run", "--manual", "job"]);
        same(ended(w, id).trigger, "manual");
        const lock = path.join(w.home, ".local", "state", "vgs", "automations", "locks", "job.lock");
        const holder = childProcess.spawn("flock", [lock, "sleep", "10"], { stdio: "ignore", env: w.env });
        try {
            waitFor(() => cli(w, engine, ["run-now", id]).status === 1, "the held lock");
            assert.equal(cli(w, engine, ["run-now", id]).first, "automations: refused: run=busy id=job");
        } finally {
            holder.kill("SIGKILL");
        }
        assert.equal(calls(w, "systemd-run").length, 1, "a busy automation starts nothing");
    },

    "history names a running and a vanished run"(engine) {
        const w = world();
        const id = add(w, engine, { command: "sleep 5" });
        const lock = path.join(w.home, ".local", "state", "vgs", "automations", "locks", "job.lock");
        const runner = childProcess.spawn("flock", ["-n", "-E", "75", "-o", lock, engine, "--tree", repo, "run", "--manual", id], { stdio: "ignore", env: w.env, detached: true });
        try {
            waitFor(() => runFiles(w).some(n => n.endsWith(".started.json")), "the started record");
            waitFor(() => JSON.parse(cli(w, engine, ["history", "--json"]).stdout).rows[0].outcome === "running", "the running run");
            // The run's lock goes with its whole group, the runner and
            // flock alike, as a killed service's cgroup does.
            process.kill(-runner.pid, "SIGKILL");
            waitFor(() => JSON.parse(cli(w, engine, ["history", "--json"]).stdout).rows[0].outcome === "vanished", "the vanished run");
        } finally {
            try { process.kill(-runner.pid, "SIGKILL"); } catch (_e) { /* gone */ }
        }
        const text = cli(w, engine, ["history", id]).stdout;
        assert.match(text, /^job\t\d+-\d+\tvanished\t\/.*\.log\n$/);
    },

    "clear keeps a running run and prune keeps the retention"(engine) {
        const w = world();
        const DAY = 24 * 60 * 60 * 1000;
        for (const [id, age] of [["a", 31], ["a", 2], ["b", 40], ["b", 0]]) plant(w, id, Date.now() - age * DAY - 1000);
        assert.equal(cli(w, engine, ["prune", "--days", "30"]).stdout, "pruned=2\n");
        same(runFiles(w).map(n => n.replace(/@\d+-\d+/, "@R")), ["a@R.ended.json", "a@R.log", "b@R.ended.json", "b@R.log"]);
        // The plugin's historyDays setting, read through vgsh plugin settings.
        write(path.join(w.home, ".config", "vgs", "shell.json"), JSON.stringify({ version: 1, plugins: [{ id: "vgs.automations", historyDays: 1 }] }));
        const pruned = cli(w, engine, ["prune"]);
        assert.equal(pruned.stdout, "pruned=1\n", pruned.stderr);
        same(runFiles(w).map(n => n.slice(0, 2)), ["b@", "b@"]);
        plant(w, "b", Date.now() - 5000, true);
        const lock = path.join(w.home, ".local", "state", "vgs", "automations", "locks", "b.lock");
        const holder = childProcess.spawn("flock", [lock, "sleep", "10"], { stdio: "ignore", env: w.env });
        try {
            waitFor(() => JSON.parse(cli(w, engine, ["history", "--json"]).stdout).rows.some(r => r.outcome === "running"), "the held lock");
            assert.equal(cli(w, engine, ["clear", "b"]).stdout, "cleared=1\n");
            same(JSON.parse(cli(w, engine, ["history", "--json"]).stdout).rows.map(r => r.outcome), ["running"]);
        } finally {
            holder.kill("SIGKILL");
        }
        waitFor(() => JSON.parse(cli(w, engine, ["history", "--json"]).stdout).rows.every(r => r.outcome === "vanished"), "the released lock");
        assert.equal(cli(w, engine, ["clear", "--all"]).stdout, "cleared=1\n");
        same(runFiles(w), []);
    },

    "without a systemd user manager sync keeps a crontab block"(engine) {
        const w = world({ systemd: "down" });
        const id = add(w, engine, { schedule: { frequency: "monthly", interval: 1, monthly: { by: "weekday", week: 2, weekday: "tue" }, times: ["09:00"], start: "2026-01-01", end: { type: "never" } } });
        same(calls(w, "systemctl"), [["--user", "show-environment"]], "no unit is written");
        same(calls(w, "crontab"), [["-l"], ["-"]], "a user without a table gets one");
        const block = fs.readFileSync(path.join(w.stub, "crontab"), "utf8");
        write(path.join(w.stub, "crontab"), "MAILTO=me\n5 * * * * mine\n" + block);
        const table = fs.readFileSync(path.join(w.stub, "crontab"), "utf8").split("\n");
        same(table.slice(0, 3), ["MAILTO=me", "5 * * * * mine", Logic.CRON_BEGIN]);
        assert.match(table[3], /^0 9 \* \* 2 env 'XDG_CONFIG_HOME=[^']*' 'XDG_STATE_HOME=[^']*' 'XDG_DATA_HOME=[^']*' '[^']*\/flock' '-n' '-E' '75' '-o' '[^']*\/job\.lock' '[^']*' '[^']*\/bin\/automations' '--tree' '[^']*' 'run' '--scheduled' 'job'$/);
        same(table.slice(4), [Logic.CRON_END, ""]);
        const listed = JSON.parse(cli(w, engine, ["list", "--json"]).stdout);
        same([listed.scheduler, listed.linger, listed.automations[0].summary], ["cron", "no", "Monthly on the second Tuesday at 09:00"]);
        assert.equal(cli(w, engine, ["remove", id]).status, 0);
        assert.equal(fs.readFileSync(path.join(w.stub, "crontab"), "utf8"), "MAILTO=me\n5 * * * * mine\n", "remove drops the block alone");
    },

    "with neither scheduler sync refuses"(engine) {
        const w = world({ systemd: "down", stubs: ["systemctl", "notify-send", "loginctl"] });
        const out = cli(w, engine, ["add", "--definition", JSON.stringify(def({}))]);
        same([out.status, out.first], [1, "automations: refused: scheduler=none"]);
    },

    "preview prints the judge's answer"(engine) {
        const w = world();
        const s = { frequency: "weekly", interval: 2, weekdays: ["mon"], times: ["09:00"], start: "2026-01-05", end: { type: "count", count: 3 } };
        const out = cli(w, engine, ["preview", "--schedule", JSON.stringify(s), "--count", "5", "--after", String(Date.parse("2026-01-01T00:00:00Z"))]);
        same(JSON.parse(out.stdout), { summary: Logic.summaryText(s), calendar: ["Mon *-*-* 09:00:00"], cron: ["0 9 * * 1"], occurrences: Logic.nextOccurrences(s, Date.parse("2026-01-01T00:00:00Z"), 5) });
        assert.equal(cli(w, engine, ["preview", "--schedule", JSON.stringify(Object.assign({}, s, { interval: 0 }))]).first, "automations: refused: schedule=schedule.interval:-want=1..99");
        same(JSON.parse(cli(world({ linger: "yes" }), engine, ["list", "--json"]).stdout).linger, "yes");
    }
};

function same(got, want, message) {
    assert.deepEqual(JSON.parse(JSON.stringify(got)), JSON.parse(JSON.stringify(want)), message);
}

// Polls CHECK every 50 ms for at most 10 s: a process the case started
// takes its lock or writes its record on its own clock.
function waitFor(check, what) {
    const until = Date.now() + 10000;
    while (Date.now() < until) {
        if (check()) return;
        childProcess.spawnSync("sleep", ["0.05"]);
    }
    assert.fail("timed out waiting for " + what);
}

// An ended run of automation ID that started at MS, with its transcript;
// with `open`, only its started record.
function plant(w, id, ms, open) {
    const run = ms + "-" + (worlds * 100 + runFiles(w).length);
    const transcript = path.join(w.runs, Logic.runFile(id, run, "log"));
    const rec = { version: 1, automation: id, run: run, name: id, command: "true", directory: w.home, trigger: "manual", slot: null, startedAt: ms, transcript: transcript };
    write(transcript, "# planted\n");
    if (open) return write(path.join(w.runs, Logic.runFile(id, run, "started")), JSON.stringify(rec));
    write(path.join(w.runs, Logic.runFile(id, run, "ended")), JSON.stringify(Object.assign(rec, { endedAt: ms + 1, durationMs: 1, outcome: "succeeded", exitCode: 0, signal: null, reason: "", transcriptBytes: 10, truncated: false, snippet: "" })));
}

// ------------------------------------------------------------ the controls

// [label, the case, text in bin/automations, its replacement].
const CONTROLS = [
    ["sync starts nothing with nothing to schedule", "sync with nothing runs nothing", "if (store.automations.length === 0 && ownedUnits().length === 0 && !fs.existsSync(engineRoot)) {", "if (false) {"],
    ["sync reloads after a unit change", "add writes the units, reloads and enables the timer", "if (removed.length + changed.length > 0) systemctl([\"daemon-reload\"]);", ""],
    ["the units run a copy of the engine", "add writes the units, reloads and enables the timer", "if (fs.existsSync(path.join(dir, \"bin\", \"automations\"))) return dir;", "return PLUGIN_DIR;"],
    ["add marks the past handled", "a scheduled trigger runs only what the guard allows", "    markHandled(judged.automation.id, Date.now());\n", "\n"],
    ["a changed active timer restarts", "edit, disable, enable and remove follow the store", "if (restarted.length > 0) systemctl([\"restart\"].concat(restarted));", ""],
    ["a disabled timer is stopped", "edit, disable, enable and remove follow the store", "if (timersGone.length > 0) systemctl([\"disable\", \"--now\"].concat(timersGone));", ""],
    ["the started record comes before the command", "a run that succeeds writes both records and its transcript", "writeAtomic(path.join(runsDir, Logic.runFile(id, runId, \"started\")), JSON.stringify(started) + \"\\n\", 0o600);", ""],
    ["a record lands by rename", "a run that succeeds writes both records and its transcript", "    fs.renameSync(temp, file);\n}", "}"],
    ["an error notifies", "a failing run sends the error notification whatever the toggle", "notify(Logic.notificationFor(\"end\", automation, ended), noticeId, env);", ""],
    ["the finish replaces the start", "notifyEveryRun sends the start, then replaces it with the finish", "notify(Logic.notificationFor(\"end\", automation, ended), noticeId, env);", "notify(Logic.notificationFor(\"end\", automation, ended), null, env);"],
    ["the timeout signals the group", "a timeout ends the command's whole process group", "process.kill(-child.pid, sig);", "process.kill(child.pid, sig);"],
    ["the timeout fires", "a timeout ends the command's whole process group", "timedOut = true;\n        signalGroup(\"SIGTERM\");", "timedOut = true;"],
    ["a timed-out run waits for its group", "a timed-out run ends after a descendant that ignores SIGTERM", "if (!timedOut) return finish(ending);", "return finish(ending);"],
    ["a long line ending in a break is split too", "output with no line break reaches the transcript in pieces", "        for (let at = 0; at < line.length; at += Logic.TRANSCRIPT_LINE_MAX) onLine(line.slice(at, at + Logic.TRANSCRIPT_LINE_MAX));\n        if (line === \"\") onLine(line);", "        onLine(line);"],
    ["a long line is split into pieces", "output with no line break reaches the transcript in pieces", "        while (pending.length > Logic.TRANSCRIPT_LINE_MAX) {", "        while (false) {"],
    ["a missing directory fails the start", "a missing working directory is a failed start", "return finish({ started: false, timedOut: false, exitCode: null, signal: null, reason: \"directory=\" + e.code + \" path=\" + directory });", "directory; // unchecked"],
    ["a refused store fails the start", "a refused store is a failed start the user is told of", "if (!judged.ok) return execute(standIn(id), trigger, null, now, \"store=\" + judged.error.replace(/\\s+/g, \"-\"));", "if (!judged.ok) process.exit(1);"],
    ["the transcript keeps its cap", "the transcript stops at its cap and the run goes on", "if (body + bytes > Logic.TRANSCRIPT_MAX_BYTES) {", "if (false) {"],
    ["the footer follows the cap", "the transcript stops at its cap and the run goes on", "put(footer.map(line => \"# \" + line + \"\\n\").join(\"\"));", ""],
    ["a scheduled trigger asks the guard", "a scheduled trigger runs only what the guard allows", "if (!decision.run) {\n        log(\"skipped=\" + id + \" reason=\" + decision.reason);\n        return;\n    }", ""],
    ["the guard records the handled occurrence", "a scheduled trigger runs only what the guard allows", "if (decision.slot !== null && (handled === null || decision.slot > handled)) markHandled(id, decision.slot);", ""],
    ["run-now goes through systemd-run", "run-now goes through systemd-run and refuses a busy automation", "if (scheduler() === \"systemd\") {\n        const unit", "if (false) {\n        const unit"],
    ["run-now refuses a busy automation", "run-now goes through systemd-run and refuses a busy automation", "if (lockHeld(id)) refuse(\"run=busy id=\" + id, \"a run of it is live\");", ""],
    ["a held lock is a running run", "history names a running and a vanished run", "if (out.status === 75) return true;", "if (out.status === 75) return false;"],
    ["prune keeps the retention", "clear keeps a running run and prune keeps the retention", "return removeRuns(Logic.prunable(judged.rows, Date.now(), days), judged.groups);", "return removeRuns(judged.rows.map(row => row.automation + \"@\" + row.run), judged.groups);"],
    ["prune reads historyDays", "clear keeps a running run and prune keeps the retention", "return { ok: true, days: Logic.retentionDays(JSON.parse(out.stdout).historyDays) };", "return { ok: true, days: 30 };"],
    ["clear keeps a running run", "clear keeps a running run and prune keeps the retention", "judged.rows.filter(row => row.outcome !== \"running\")", "judged.rows"],
    ["cron is the fallback", "without a systemd user manager sync keeps a crontab block", "changed = writeCrontab(requireCommand(\"crontab\"), Logic.cronLines(", "changed = writeCrontab(requireCommand(\"crontab\"), [] || Logic.cronLines("],
    ["a crontab without a table reads empty", "without a systemd user manager sync keeps a crontab block", "if (out.status === 1 && /^no crontab for /.test(firstLine(out.stderr))) return \"\";", ""],
    ["no scheduler refuses", "with neither scheduler sync refuses", "if (chosen === \"none\") refuse(\"scheduler=none\", \"neither a systemd user manager nor crontab answered\");", ""]
];

fs.rmSync(scratch, { recursive: true, force: true });
fs.mkdirSync(scratch, { recursive: true });
let passed = 0;
try {
    const engine = path.join(pluginDir, "bin", "automations");
    for (const [name, check] of Object.entries(CASES)) {
        check(engine);
        passed += 1;
    }
    const source = fs.readFileSync(engine, "utf8");
    CONTROLS.forEach(([label, name, needle, replacement], i) => {
        assert.ok(Object.prototype.hasOwnProperty.call(CASES, name), `control "${label}": no case "${name}"`);
        assert.equal(source.split(needle).length, 2, `control "${label}": the text to replace must occur once`);
        const copy = path.join(scratch, "control-" + i, "vgs.automations");
        fs.cpSync(pluginDir, copy, { recursive: true });
        fs.writeFileSync(path.join(copy, "bin", "automations"), source.replace(needle, () => replacement), { mode: 0o755 });
        let failed = false;
        try {
            CASES[name](path.join(copy, "bin", "automations"));
        } catch (_e) {
            failed = true;
        }
        assert.ok(failed, `control "${label}": case "${name}" passed on an engine without that rule`);
    });
} finally {
    fs.rmSync(scratch, { recursive: true, force: true });
}
console.log(`test-automations-engine: ok cases=${passed} controls=${CONTROLS.length}`);
