#!/usr/bin/env node
// Transcript checks for the Bluetooth pairing agent's decisions,
// shell/Core/BluetoothAgentModel.js, the code the core runs over its
// `bluetoothctl --agent KeyboardDisplay` child. Each case replays
// bluetoothctl 5.87's raw output as client/agent.c and src/shared/shell.c
// print it: colours, carriage returns, line clears, prompts with no newline,
// prompt redraws and the echo of each line the agent writes. Every case runs
// with the output whole and split every 1, 4 and 13 characters, mid-line
// and mid-escape, and must read the same. Expected values are written by
// hand. Controls edit a copy of the module, one rule each, and require this
// suite to fail.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { load } = require("../bin/lib/qml-library.js");

const file = path.join(__dirname, "..", "shell", "Core", "BluetoothAgentModel.js");
const same = (got, want, message) => assert.deepEqual(JSON.parse(JSON.stringify(got)), want, message);

const E = "\x1b";
const OFF = E + "[0m", RED = E + "[0;91m", BLUE = E + "[0;94m", HIGHLIGHT = E + "[1;39m", BOLDGRAY = E + "[1;30m", BOLDWHITE = E + "[1;37m";
const MAIN = BLUE + "[bluetoothctl]> " + OFF;
// bt_shell_prompt_input's prompt as readline draws it.
const prompt = msg => HIGHLIGHT + HIGHLIGHT + "[agent] " + msg + " " + OFF + OFF;
// bt_shell_printf: clear the line, print, draw the prompt shown again.
const said = (text, shown = MAIN) => "\r" + E + "[K" + text + "\n" + shown;
const request = (text, msg) => said(text) + "\r" + prompt(msg);
// DisplayPasskey: the typed digits in bold gray, the colour reset after the newline.
const passkey = (code, entered) => "\r" + E + "[K" + RED + "[agent]" + OFF + " Passkey: " + BOLDGRAY + code.slice(0, entered) + BOLDWHITE + code.slice(entered) + "\n" + OFF + MAIN;
// readline echoes each line it reads, then the main prompt.
const echo = line => line + "\n" + MAIN;
const STARTUP = "Waiting to connect to bluetoothd..." + "\r" + MAIN + said("[NEW] Controller 00:11:22:33:44:55 host [default]");
const REGISTERED = said("Agent registered");
const DEFAULTED = said("Default agent request successful");
const CONFIRM = request("Request confirmation", "Confirm passkey 004821 (yes/no):");
const CONFIRM_REDRAW = said("[CHG] Device AA:BB:CC:DD:EE:01 RSSI: 0xffffffc4 (-60)", prompt("Confirm passkey 004821 (yes/no):"));
const PIN = request("Request PIN code", "Enter PIN code:");
const PIN_DECLINE = "00000000000000000";

// One agent and the effects it asked for, its stdout fed SIZE characters at
// a time. Resolve effects wait for later(), as Qt.callLater does.
function session(M, size) {
    let model = M.initial();
    const writes = [], logs = [], kinds = [], deferred = [];
    function apply(step) {
        model = step.model;
        for (const e of step.effects) {
            kinds.push(e.kind === "timer" ? "timer=" + e.ms : e.kind);
            if (e.kind === "write") writes.push(e.line);
            if (e.kind === "log") logs.push(e.line);
            if (e.kind === "resolve") deferred.push(e.lease);
        }
        return step;
    }
    return {
        writes, logs, kinds,
        get model() { return model; },
        begin: reason => apply(M.begin(model, reason)).lease,
        out: raw => { for (let i = 0; i < raw.length; i += size) apply(M.output(model, raw.slice(i, i + size))); },
        exit: (code, stderr) => apply(M.exited(model, code, stderr || "")),
        timeout: () => apply(M.timeout(model)),
        release: id => apply(M.release(model, id)),
        answer: (id, value) => apply(M.answer(model, id, value)).answer,
        later: () => { while (deferred.length > 0) apply(M.resolve(model, deferred.shift())); },
        state: id => M.leaseOf(model, id).state,
        refusal: id => M.leaseOf(model, id).refusal,
        requests: () => JSON.parse(JSON.stringify(model.requests)),
        // Clears what was recorded so far, so a case reads one step's effects.
        mark: () => { writes.length = 0; logs.length = 0; kinds.length = 0; }
    };
}

// A session whose one lease is ready: started, registered, made default.
function readyAgent(M, size) {
    const s = session(M, size);
    const lease = s.begin("pair a mouse");
    s.out(STARTUP + REGISTERED + DEFAULTED);
    s.later();
    assert.equal(s.state(lease), "ready", "setup: the lease is ready");
    s.mark();
    return { s, lease };
}

const entry = (id, kind, fields) => Object.assign({ id: id, kind: kind, code: "", service: "", entered: 0 }, fields || {});

const CASES = [
    ["registration resolves the lease only after the default acknowledgement", (M, size) => {
        const s = session(M, size);
        const lease = s.begin("pair a mouse");
        assert.equal(s.state(lease), "pending", "a lease reads pending right after begin");
        same(s.kinds, ["start", "timer=5000"], "the first lease starts the child and arms the acknowledgement wait");
        s.mark();
        s.out(STARTUP);
        same(s.writes, [], "nothing is written before the agent registered");
        s.out(REGISTERED);
        same(s.writes, ["default-agent"], "registration asks for the default role");
        assert.equal(s.state(lease), "pending", "registration alone does not resolve the lease");
        assert.equal(M.ready(s.model), false, "not ready before the default acknowledgement");
        s.out(echo("default-agent") + DEFAULTED);
        s.later();
        assert.equal(s.state(lease), "ready", "the default acknowledgement resolves the lease");
        assert.equal(M.ready(s.model), true, "ready after the default acknowledgement");
        same(s.kinds, ["write", "timer=5000", "timer=0"], "each acknowledgement wait is armed, then stopped");
        same(M.record(s.model), { state: "ready", running: true, leases: [{ id: lease, reason: "pair a mouse", state: "ready" }], requests: 0, refusal: "" }, "the lending record");
    }],
    ["a confirm prompt lists one request with its code, through redraws, and yes answers it", (M, size) => {
        const { s } = readyAgent(M, size);
        s.out(CONFIRM);
        same(s.requests(), [entry(1, "confirm", { code: "004821" })], "the prompt lists one confirm request");
        s.out(CONFIRM_REDRAW + CONFIRM_REDRAW);
        same(s.requests(), [entry(1, "confirm", { code: "004821" })], "redraws list no second request");
        assert.equal(s.answer(1, "yes"), "refused: request=1 reason=value want=boolean", "a confirm takes a boolean");
        same(s.writes, [], "a refused answer writes nothing");
        assert.equal(s.answer(1, true), "ok");
        same(s.writes, ["yes"], "true writes yes");
        same(s.requests(), [], "the answer removes the request");
        s.out(echo("yes"));
        same(s.requests(), [], "the echo lists nothing");
        assert.equal(s.answer(1, true), "refused: request=1 reason=unknown", "an answered request is gone");
        same(s.writes, ["yes"], "and its second answer writes nothing");
    }],
    ["a PIN prompt takes a PIN and refuses a line break or a control character", (M, size) => {
        const { s } = readyAgent(M, size);
        s.out(PIN);
        same(s.requests(), [entry(1, "pin")], "the PIN prompt lists one request");
        const REFUSED = ["12\n34", "12\r34", "12\u000734", "12\u007f", "", " 1234", "1234 ", "#1234", "12345678901234567", true, 1234, null];
        for (const value of REFUSED)
            assert.equal(s.answer(1, value), "refused: request=1 reason=value want=pin", "refused PIN " + JSON.stringify(value));
        same(s.writes, [], "no refused PIN is written");
        assert.equal(s.answer(1, "1234 abcd"), "ok");
        same(s.writes, ["1234 abcd"], "a PIN is written as given");
        s.out(echo("1234 abcd"));
        s.out(PIN);
        assert.equal(s.answer(2, false), "ok");
        same(s.writes, ["1234 abcd", PIN_DECLINE], "false declines a PIN with a line BlueZ refuses as too long");
        assert.equal(PIN_DECLINE.length, 17);
    }],
    ["a passkey prompt takes 0 to 999999", (M, size) => {
        const { s } = readyAgent(M, size);
        s.out(request("Request passkey", "Enter passkey (number in 0-999999):"));
        same(s.requests(), [entry(1, "passkey-entry")]);
        for (const value of [1000000, -1, 1.5, "123456", true, NaN])
            assert.equal(s.answer(1, value), "refused: request=1 reason=value want=passkey", "refused passkey " + JSON.stringify(value));
        assert.equal(s.answer(1, 4821), "ok");
        s.out(echo("4821") + request("Request passkey", "Enter passkey (number in 0-999999):"));
        assert.equal(s.answer(2, false), "ok");
        same(s.writes, ["4821", "no"], "a passkey is written in decimal and false rejects");
    }],
    ["a displayed passkey is one entry whose typed count follows each repeat", (M, size) => {
        const { s } = readyAgent(M, size);
        s.out(passkey("482116", 0));
        same(s.requests(), [entry(1, "passkey-display", { code: "482116" })]);
        s.out(passkey("482116", 2) + passkey("482116", 5));
        same(s.requests(), [entry(1, "passkey-display", { code: "482116", entered: 5 })], "repeats update the same entry");
        assert.equal(s.answer(1, null), "ok", "any value dismisses it");
        same(s.requests(), [], "dismissed");
        same(s.writes, [], "a display is never answered to bluetoothctl");
    }],
    ["a displayed PIN code is a display entry", (M, size) => {
        const { s } = readyAgent(M, size);
        s.out(said(RED + "[agent]" + OFF + " PIN code: 0000"));
        same(s.requests(), [entry(1, "passkey-display", { code: "0000" })]);
    }],
    ["an authorization prompt lists authorize with no service", (M, size) => {
        const { s } = readyAgent(M, size);
        s.out(request("Request authorization", "Accept pairing (yes/no):"));
        same(s.requests(), [entry(1, "authorize")]);
        assert.equal(s.answer(1, false), "ok");
        same(s.writes, ["no"], "false rejects");
    }],
    ["a service authorization lists the service", (M, size) => {
        const { s } = readyAgent(M, size);
        s.out(request("Authorize service", "Authorize service 0000110d-0000-1000-8000-00805f9b34fb (yes/no):"));
        same(s.requests(), [entry(1, "authorize", { service: "0000110d-0000-1000-8000-00805f9b34fb" })]);
        assert.equal(s.answer(1, true), "ok");
        same(s.writes, ["yes"]);
    }],
    ["an inbound request is listed while a second lease joins, which resolves after begin returns", (M, size) => {
        const { s, lease } = readyAgent(M, size);
        s.out(CONFIRM);
        const second = s.begin("pairing pane");
        assert.equal(s.state(second), "pending", "a lease begun while ready reads pending right after begin");
        same(s.kinds, ["resolve"], "a joining lease starts nothing");
        s.later();
        assert.equal(s.state(second), "ready", "and ready once the caller returned");
        same(s.requests(), [entry(1, "confirm", { code: "004821" })], "the request is listed for every lease");
        s.release(lease);
        same(s.writes, [], "releasing one of two leases writes nothing");
        assert.equal(s.model.phase, "ready", "the other lease keeps the agent");
        assert.equal(s.answer(1, true), "ok");
        same(s.writes, ["yes"]);
    }],
    ["a cancelled request becomes a cancel entry with its id, dismissed without a write", (M, size) => {
        const { s } = readyAgent(M, size);
        s.out(CONFIRM + said("Request canceled"));
        same(s.requests(), [entry(1, "cancel", { code: "004821" })]);
        assert.equal(s.answer(1, true), "ok");
        same(s.writes, [], "a cancel writes nothing");
        same(s.requests(), []);
        s.out(CONFIRM);
        same(s.requests(), [entry(2, "confirm", { code: "004821" })], "the next request takes the next id");
    }],
    ["an unknown request or prompt is rejected once, logged and never listed", (M, size) => {
        const { s } = readyAgent(M, size);
        s.out(request("Request bonding", "Bond with AA:BB (yes/no):") + said("[CHG] Device AA:BB:CC:DD:EE:01 RSSI: -60", prompt("Bond with AA:BB (yes/no):")));
        same(s.writes, ["no"], "the unknown request is rejected once, through the redraw");
        same(s.logs, ["bluetoothAgent: refused: prompt=unknown text=\"Request bonding\""]);
        same(s.requests(), []);
        s.out(echo("no"));
        s.mark();
        s.out(request("Request confirmation", "Confirm pairing with AA:BB (yes/no):"));
        same(s.writes, ["no"], "a known request whose prompt is unknown is rejected");
        same(s.logs, ["bluetoothAgent: refused: prompt=unknown text=\"[agent] Confirm pairing with AA:BB (yes/no): \""]);
        same(s.requests(), []);
    }],
    ["a registration failure refuses the lease and ends the child", (M, size) => {
        const s = session(M, size);
        const lease = s.begin("pair");
        s.mark();
        s.out(STARTUP + said("Failed to register agent: org.bluez.Error.AlreadyExists"));
        assert.equal(s.state(lease), "refused");
        assert.equal(s.refusal(lease), "refused: agent=busy reason=register-failed error=org.bluez.Error.AlreadyExists");
        same(s.kinds, ["log", "close-stdin", "timer=2000"], "the refusal is logged and the child's stdin closed");
        s.exit(0);
        assert.equal(s.model.phase, "failed", "failed while the refused lease is held");
        s.release(lease);
        same(M.record(s.model), { state: "off", running: false, leases: [], requests: 0, refusal: "refused: agent=busy reason=register-failed error=org.bluez.Error.AlreadyExists" });
    }],
    ["a default-agent failure refuses every pending lease", (M, size) => {
        for (const [answer, refusal] of [
            ["Failed to request default agent: org.bluez.Error.Failed", "refused: agent=busy reason=default-failed error=org.bluez.Error.Failed"],
            ["No agent is registered", "refused: agent=busy reason=default-failed error=none"]
        ]) {
            const s = session(M, size);
            const a = s.begin("pair"), b = s.begin("pane");
            s.out(STARTUP + REGISTERED + said(answer));
            s.later();
            for (const lease of [a, b]) assert.equal(s.refusal(lease), refusal, answer);
            same(s.writes, ["default-agent"], answer);
            assert.equal(s.model.phase, "closing", answer);
        }
    }],
    ["a child that ends before both acknowledgements refuses with its code", (M, size) => {
        const s = session(M, size);
        const lease = s.begin("pair");
        s.out(STARTUP + REGISTERED);
        s.mark();
        s.exit(1, "stand-in: name=bluetoothctl transcript=diverged");
        assert.equal(s.refusal(lease), "refused: agent=busy reason=ended code=1");
        same(s.logs, ["bluetoothAgent: refused: agent=busy reason=ended code=1", "bluetoothAgent: stderr=\"stand-in: name=bluetoothctl transcript=diverged\""]);
        assert.equal(s.model.phase, "failed");
        const failed = session(M, size);
        const other = failed.begin("pair");
        failed.exit(null);
        assert.equal(failed.refusal(other), "refused: agent=busy reason=ended code=none", "a child that never started");
    }],
    ["a child that ends while ready refuses the lease with no restart", (M, size) => {
        const { s, lease } = readyAgent(M, size);
        s.exit(0);
        assert.equal(s.refusal(lease), "refused: agent=busy reason=ended code=0");
        same(s.kinds, ["log", "timer=0"], "nothing starts again");
        const again = s.begin("pair again");
        assert.equal(s.model.phase, "starting", "a new lease starts a new child");
        assert.equal(s.state(again), "pending");
    }],
    ["a silent child times out, then is killed", (M, size) => {
        const s = session(M, size);
        const lease = s.begin("pair");
        s.out(STARTUP + REGISTERED);
        s.mark();
        s.timeout();
        assert.equal(s.refusal(lease), "refused: agent=busy reason=timeout");
        same(s.kinds, ["log", "close-stdin", "timer=2000"]);
        s.timeout();
        same(s.kinds, ["log", "close-stdin", "timer=2000", "stop"], "a child that outlives its closed stdin is killed");
        s.exit(null);
        assert.equal(s.model.phase, "failed");
    }],
    ["release unregisters, closes stdin and waits for the exit", (M, size) => {
        const { s, lease } = readyAgent(M, size);
        s.release(lease);
        same(s.writes, ["agent off"]);
        same(s.kinds, ["write", "timer=2000"]);
        assert.equal(s.model.phase, "releasing");
        s.out(echo("agent off") + said("Agent unregistered"));
        same(s.kinds, ["write", "timer=2000", "close-stdin", "timer=2000"]);
        s.exit(0);
        same(M.record(s.model), { state: "off", running: false, leases: [], requests: 0, refusal: "" });
        const slow = readyAgent(M, size);
        slow.s.release(slow.lease);
        slow.s.timeout();
        slow.s.timeout();
        same(slow.s.kinds, ["write", "timer=2000", "close-stdin", "timer=2000", "stop"], "no acknowledgement closes stdin, then kills");
    }],
    ["release with a prompt open declines it before agent off", (M, size) => {
        for (const [shown, decline] of [[CONFIRM, "no"], [PIN, PIN_DECLINE]]) {
            const { s, lease } = readyAgent(M, size);
            s.out(shown);
            s.release(lease);
            same(s.writes, [decline, "agent off"], "the prompt's decline is written first: " + decline);
            same(s.requests(), []);
        }
        const awaiting = readyAgent(M, size);
        awaiting.s.out(said("Request PIN code"));
        awaiting.s.release(awaiting.lease);
        same(awaiting.s.writes, [PIN_DECLINE, "agent off"], "a prompt whose request line alone arrived is declined too");
    }],
    ["BlueZ going away makes the lease pending, and its return sends default-agent again", (M, size) => {
        const { s, lease } = readyAgent(M, size);
        s.out(CONFIRM + said("Agent released", prompt("Confirm passkey 004821 (yes/no):")));
        same(s.writes, ["no"], "the prompt bluetoothctl keeps is declined");
        same(s.requests(), [entry(1, "cancel", { code: "004821" })], "its entry is cancelled");
        assert.equal(s.state(lease), "pending");
        assert.equal(M.ready(s.model), false);
        s.out(echo("no") + said("No agent is registered") + said("Agent registered"));
        same(s.writes, ["no", "default-agent"], "a later registration asks for the default role again");
        s.out(DEFAULTED);
        assert.equal(s.state(lease), "ready");
        const direct = readyAgent(M, size);
        direct.s.out(said("Agent registered"));
        same(direct.s.writes, ["default-agent"], "an unsolicited registration while ready asks again");
        assert.equal(direct.s.state(direct.lease), "pending");
        direct.s.out(said("Agent unregistered") + REGISTERED + DEFAULTED);
        assert.equal(direct.s.state(direct.lease), "ready");
    }],
    ["a lease begun while the child ends starts it again", (M, size) => {
        const { s, lease } = readyAgent(M, size);
        s.release(lease);
        const next = s.begin("pair again");
        assert.equal(s.state(next), "pending");
        s.out(said("Agent unregistered"));
        s.mark();
        s.exit(0);
        same(s.kinds, ["timer=0", "start", "timer=5000"]);
        assert.equal(s.model.phase, "starting");
    }],
    ["output with no line end past the cap is dropped and logged once", (M, size) => {
        const { s } = readyAgent(M, size);
        const flood = "x".repeat(8193);
        s.out(flood + flood.slice(0, 8193));
        same(s.logs, ["bluetoothAgent: output=dropped chars=8192; no line end"]);
        s.out("\n" + CONFIRM);
        same(s.requests(), [entry(1, "confirm", { code: "004821" })], "the next line is read");
    }],
    ["a lease reason is 1 to 80 printable characters", M => {
        for (const reason of ["", "   ", "x".repeat(81), "a\nb", "a\u0000", 5, null, undefined])
            assert.throws(() => M.begin(M.initial(), reason), { message: "refused: bluetoothAgent reason=" + JSON.stringify(reason) }, JSON.stringify(reason));
        assert.equal(M.reasonRefusal("x".repeat(80)), "");
    }]
];

function verify(M) {
    for (const [label, run] of CASES) {
        for (const size of [Infinity, 1, 4, 13]) {
            try {
                run(M, size);
            } catch (e) {
                e.message = `${label} (chunks of ${size}): ${e.message}`;
                throw e;
            }
        }
    }
}

verify(load(file));

const CONTROLS = [
    ["registration alone does not resolve", '        s.phase = "defaulting";\n', '        s.phase = "ready";\n        setLeases(s, "pending", "ready");\n'],
    ["release writes agent off", 'effects.push({ kind: "write", line: "agent off" }, { kind: "timer", ms: UNREGISTER_GRACE_MS });', 'effects.push({ kind: "timer", ms: UNREGISTER_GRACE_MS });'],
    ["a PIN holds no line break", "var PIN_PATTERN = /^[!-\"$-~](?:[ -~]{0,14}[!-~])?$/;", "var PIN_PATTERN = /^[^#\\s][\\s\\S]{0,15}$/;"],
    ["a redraw lists no second request", '        s.prompt = { kind: "open", id: entry.id, text: text };\n', '        s.prompt = { kind: "awaiting", request: p.request };\n'],
    ["an open prompt is declined before agent off", "        decline(t, effects);\n        t.requests = [];\n", "        t.requests = [];\n"],
    ["a lease begun while ready resolves after begin", 't.leases.push({ id: id, reason: reason, state: "pending", refusal: "" });', 't.leases.push({ id: id, reason: reason, state: t.phase === "ready" ? "ready" : "pending", refusal: "" });'],
    ["a PIN is declined with a line BlueZ refuses", 'var PIN_DECLINE = "00000000000000000";', 'var PIN_DECLINE = "no";'],
    ["an unknown prompt is rejected", '    effects.push({ kind: "write", line: "no" });\n    effects.push({ kind: "log"', '    effects.push({ kind: "log"'],
    ["a redraw of an answered prompt is not rejected again", "        else if (text !== p.text) unknownPrompt(s, effects, text, text);\n", "        else unknownPrompt(s, effects, text, text);\n"],
    ["the typed count is read before the colours go", "display(s, m[1], typed === null ? 0 : typed[1].length);", "display(s, m[1], 0);"],
    ["a repeat display updates its entry", "            s.requests[i].entered = entered;\n            return;\n", "            s.requests[i].entered = entered;\n"],
    ["a cancel keeps the request's id", 'if (s.prompt.kind === "open") s.requests[entryIndex(s, s.prompt.id)].kind = "cancel";', 'if (s.prompt.kind === "open") s.requests.splice(entryIndex(s, s.prompt.id), 1);'],
    ["the default failure refuses", '            refuse(s, effects, "refused: agent=busy reason=default-failed error=" + (m[1] || "none"));\n            closeChild(s, effects);\n', "            closeChild(s, effects);\n"],
    ["an unsolicited registration while ready asks again", 'if (s.phase !== "starting" && s.phase !== "ready") return;', 'if (s.phase !== "starting") return;'],
    ["losing the agent declines its prompt", "    var index = decline(s, effects);\n    if (index !== -1) s.requests[index].kind = \"cancel\";\n", "    var index = -1;\n"],
    ["the acknowledgement wait refuses", '        refuse(t, effects, "refused: agent=busy reason=timeout");\n', ""],
    ["a child left after its closed stdin is killed", '        effects.push({ kind: "stop" });\n', ""],
    ["a lease begun while ending starts the child again", '    if (s.leases.some(function(l) { return l.state === "pending"; })) startChild(s, effects);\n    else s.phase', "    s.phase"],
    ["overflow is dropped", "    if (t.raw.length > OUTPUT_CAP) {", "    if (false) {"],
    ["a reason has at most 80 characters", "reason.length <= REASON_MAX && ", ""],
    ["a display line cut after its label is no prompt", " || DISPLAY_PREFIXES.indexOf(text) !== -1) return;", ") return;"],
    ["colours are stripped", 'function strip(raw) { return raw.replace(ESCAPES, "").replace(CONTROLS, ""); }', 'function strip(raw) { return raw.replace(CONTROLS, ""); }']
];
const scratch = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "test-bluetooth-agent-")));
try {
    const source = fs.readFileSync(file, "utf8");
    for (const [label, needle, replacement] of CONTROLS) {
        assert.equal(source.split(needle).length - 1, 1, `control pattern occurs once: ${label}`);
        const mutant = path.join(scratch, "BluetoothAgentModel.js");
        fs.writeFileSync(mutant, source.replace(needle, () => replacement));
        let red = false;
        try { verify(load(mutant)); } catch (e) { red = true; }
        assert.equal(red, true, `control passed the suite: ${label}`);
    }
} finally {
    fs.rmSync(scratch, { recursive: true, force: true });
}

console.log(`test-bluetooth-agent: ok cases=${CASES.length} controls=${CONTROLS.length}`);
