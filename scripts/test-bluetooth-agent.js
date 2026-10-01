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
// suite to fail. bluetoothctl prints a device's name raw, so the forged
// cases plant a name that holds line breaks: no line of 16 characters or
// fewer, which a held PIN or passkey prompt would accept, may be written
// unless the holder gave it.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { load } = require("../bin/lib/qml-library.js");

const file = path.join(__dirname, "..", "shell", "Core", "BluetoothAgentModel.js");
const same = (got, want, message) => assert.deepEqual(JSON.parse(JSON.stringify(got)), want, message || "");

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
const SERVICE = "Authorize service 0000110d-0000-1000-8000-00805f9b34fb (yes/no):";
// Every line the core writes on its own: 17 spaces, then the command.
const command = words => " ".repeat(17) + words;
const DECLINE = command("no");
// A device whose name holds TEXT between line breaks appears while PROMPT
// is held, which bluetoothctl draws again after the name.
const named = (text, held) => said("[NEW] Device AA:BB:CC:DD:EE:02 x\n" + text + "\nx", held === undefined ? MAIN : prompt(held));

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
        same(s.writes, [command("default-agent")], "registration asks for the default role");
        assert.equal(s.state(lease), "pending", "registration alone does not resolve the lease");
        assert.equal(M.ready(s.model), false, "not ready before the default acknowledgement");
        s.out(echo(command("default-agent")) + DEFAULTED);
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
        const ACCEPTED = ["1234 abcd", "1", "abcdefghijklmnop"];
        ACCEPTED.forEach((value, i) => {
            if (i > 0) s.out(PIN);
            assert.equal(s.answer(i + 1, value), "ok", "accepted PIN " + JSON.stringify(value));
            s.out(echo(value));
        });
        same(s.writes, ACCEPTED, "a PIN of 1 to 16 characters is written as given");
        s.out(PIN);
        assert.equal(s.answer(4, false), "ok");
        same(s.writes, ACCEPTED.concat([DECLINE]), "false declines a PIN with a line BlueZ refuses as too long");
        assert.equal(DECLINE.length, 19);
    }],
    ["a passkey prompt takes 0 to 999999", (M, size) => {
        const { s } = readyAgent(M, size);
        s.out(request("Request passkey", "Enter passkey (number in 0-999999):"));
        same(s.requests(), [entry(1, "passkey-entry")]);
        for (const value of [1000000, -1, 1.5, "123456", true, NaN])
            assert.equal(s.answer(1, value), "refused: request=1 reason=value want=passkey", "refused passkey " + JSON.stringify(value));
        [4821, 0, 999999].forEach((value, i) => {
            if (i > 0) s.out(echo(String(value)) + request("Request passkey", "Enter passkey (number in 0-999999):"));
            assert.equal(s.answer(i + 1, value), "ok", "accepted passkey " + value);
        });
        s.out(echo("999999") + request("Request passkey", "Enter passkey (number in 0-999999):"));
        assert.equal(s.answer(4, false), "ok");
        same(s.writes, ["4821", "0", "999999", DECLINE], "a passkey is written in decimal and false declines");
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
        same(s.writes, [DECLINE], "false declines");
    }],
    ["a service authorization lists the service", (M, size) => {
        const { s } = readyAgent(M, size);
        s.out(request("Authorize service", SERVICE.slice(0, -1) + ":"));
        same(s.requests(), [entry(1, "authorize", { service: "0000110d-0000-1000-8000-00805f9b34fb" })]);
        assert.equal(s.answer(1, true), "ok");
        same(s.writes, ["yes"]);
    }],
    ["a prompt readline wrapped is read from its first draw", (M, size) => {
        // An xterm TERM at 80 columns: the line break inside the draw, then
        // a cursor-up clear before the next message.
        const { s } = readyAgent(M, size);
        s.out(said("Authorize service") + "\r" + HIGHLIGHT + HIGHLIGHT + "[agent] " + SERVICE + " \n\r" + OFF + OFF);
        same(s.requests(), [entry(1, "authorize", { service: "0000110d-0000-1000-8000-00805f9b34fb" })], "listed before any redraw");
        s.out("\r" + E + "[K\r" + E + "[A" + E + "[K\r[CHG] Device AA:BB:CC:DD:EE:01 RSSI: -60\n" + prompt(SERVICE));
        same(s.requests(), [entry(1, "authorize", { service: "0000110d-0000-1000-8000-00805f9b34fb" })], "the redraw lists no second request");
        same(s.writes, []);
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
        // bluetoothctl prints the line with the prompt still saved, so it
        // draws the prompt again before letting it go.
        s.out(CONFIRM + said("Request canceled", prompt("Confirm passkey 004821 (yes/no):")));
        same(s.requests(), [entry(1, "cancel", { code: "004821" })]);
        same(s.writes, [], "a cancel writes nothing");
        same(s.logs, [], "and logs nothing");
        assert.equal(s.answer(1, true), "ok");
        same(s.writes, [], "its dismissal writes nothing");
        same(s.requests(), []);
        s.out(said("[CHG] Device AA:BB:CC:DD:EE:01 RSSI: -60") + CONFIRM);
        same(s.requests(), [entry(2, "confirm", { code: "004821" })], "the next request takes the next id");
    }],
    ["an unknown request or prompt is rejected once, logged and never listed", (M, size) => {
        const { s } = readyAgent(M, size);
        s.out(request("Request bonding", "Bond with AA:BB (yes/no):") + said("[CHG] Device AA:BB:CC:DD:EE:01 RSSI: -60", prompt("Bond with AA:BB (yes/no):")));
        same(s.writes, [DECLINE], "the unknown request is declined once, through the redraw");
        same(s.logs, ["bluetoothAgent: refused: prompt=unknown text=\"Request bonding\""]);
        same(s.requests(), []);
        s.out(echo(DECLINE));
        s.mark();
        s.out(request("Request confirmation", "Confirm passkey 004821 for AA:BB (yes/no):"));
        same(s.writes, [DECLINE], "a known request whose prompt is unknown is declined");
        same(s.logs, ["bluetoothAgent: refused: prompt=unknown text=\"[agent] Confirm passkey # for AA:BB (yes/no): \""], "no digit of the prompt is logged");
        same(s.requests(), []);
        const bare = readyAgent(M, size);
        bare.s.out("\r" + prompt("Bond with AA:BB (yes/no):"));
        same(bare.s.writes, [DECLINE], "a prompt with no request line is declined");
        same(bare.s.logs, ["bluetoothAgent: refused: prompt=unknown text=\"[agent] Bond with AA:BB (yes/no): \""]);
        same(bare.s.requests(), [], "and never listed");
    }],
    ["a registration failure refuses the lease and ends the child", (M, size) => {
        for (const [answer, refusal] of [
            ["Failed to register agent: org.bluez.Error.AlreadyExists", "refused: agent=busy reason=register-failed error=org.bluez.Error.AlreadyExists"],
            ["Failed to register agent object", "refused: agent=busy reason=register-failed error=none"],
            ["Agent is already registered", "refused: agent=busy reason=register-failed error=none"]
        ]) {
            const s = session(M, size);
            const lease = s.begin("pair");
            s.mark();
            s.out(STARTUP + said(answer));
            assert.equal(s.state(lease), "refused", answer);
            assert.equal(s.refusal(lease), refusal, answer);
            same(s.kinds, ["log", "close-stdin", "timer=2000"], "the refusal is logged and the child's stdin closed: " + answer);
            s.exit(0);
            assert.equal(s.model.phase, "failed", "failed while the refused lease is held: " + answer);
            s.release(lease);
            same(M.record(s.model), { state: "off", running: false, leases: [], requests: 0, refusal: refusal }, answer);
        }
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
            same(s.writes, [command("default-agent")], answer);
            assert.equal(s.model.phase, "closing", answer);
        }
        const s = session(M, size);
        s.begin("pair");
        s.out(STARTUP + REGISTERED + CONFIRM);
        same(s.requests(), [entry(1, "confirm", { code: "004821" })], "a request can arrive before the default acknowledgement");
        s.out(said("Failed to request default agent: org.bluez.Error.Failed", prompt("Confirm passkey 004821 (yes/no):")));
        same(s.requests(), [], "a refusal drops the listed requests");
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
        s.out(CONFIRM);
        s.mark();
        s.exit(0);
        assert.equal(s.refusal(lease), "refused: agent=busy reason=ended code=0");
        same(s.kinds, ["log", "timer=0"], "nothing starts again");
        same(s.requests(), [], "the child's requests are gone");
        assert.equal(s.answer(1, true), "refused: request=1 reason=unknown", "and answering one is refused");
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
        same(s.writes, [command("agent off")]);
        same(s.kinds, ["write", "timer=2000"]);
        assert.equal(s.model.phase, "releasing");
        s.out(echo(command("agent off")) + said("Agent unregistered"));
        same(s.kinds, ["write", "timer=2000", "close-stdin", "timer=2000"]);
        s.exit(0);
        same(M.record(s.model), { state: "off", running: false, leases: [], requests: 0, refusal: "" });
        for (const [answer, logs] of [
            ["No agent is registered", []],
            ["Failed to unregister agent: org.bluez.Error.DoesNotExist", ["bluetoothAgent: unregister=failed error=org.bluez.Error.DoesNotExist"]]
        ]) {
            const other = readyAgent(M, size);
            other.s.release(other.lease);
            other.s.mark();
            other.s.out(said(answer));
            same(other.s.kinds, logs.map(() => "log").concat(["close-stdin", "timer=2000"]), "the answer closes stdin: " + answer);
            same(other.s.logs, logs, answer);
        }
        const slow = readyAgent(M, size);
        slow.s.release(slow.lease);
        slow.s.timeout();
        slow.s.timeout();
        same(slow.s.kinds, ["write", "timer=2000", "close-stdin", "timer=2000", "stop"], "no acknowledgement closes stdin, then kills");
    }],
    ["a release before the default acknowledgement closes stdin and writes nothing", (M, size) => {
        for (const [phase, shown] of [["starting", STARTUP], ["defaulting", STARTUP + REGISTERED + CONFIRM]]) {
            const s = session(M, size);
            const lease = s.begin("pair");
            s.out(shown);
            assert.equal(s.model.phase, phase);
            s.mark();
            s.release(lease);
            same(s.kinds, ["close-stdin", "timer=2000"], "no agent off while " + phase);
            s.exit(0);
            same(M.record(s.model), { state: "off", running: false, leases: [], requests: 0, refusal: "" }, phase);
        }
    }],
    ["release with a prompt open declines it before agent off", (M, size) => {
        for (const shown of [CONFIRM, PIN]) {
            const { s, lease } = readyAgent(M, size);
            s.out(shown);
            s.release(lease);
            same(s.writes, [DECLINE, command("agent off")], "the prompt's decline is written first");
            same(s.requests(), []);
        }
        const awaiting = readyAgent(M, size);
        awaiting.s.out(said("Request PIN code"));
        awaiting.s.release(awaiting.lease);
        same(awaiting.s.writes, [DECLINE, command("agent off")], "a prompt whose request line alone arrived is declined too");
    }],
    ["a device name cannot make the core write a line a held PIN prompt accepts", (M, size) => {
        const short = s => s.writes.filter(line => line.length <= 16);
        // A forged cancel, with and without the redraw, then the release.
        for (const held of ["Enter PIN code:", undefined]) {
            const { s, lease } = readyAgent(M, size);
            s.out(PIN + named("Request canceled", held));
            same(s.requests(), [entry(1, "cancel")], "a forged cancel cancels the entry");
            assert.equal(s.answer(1, false), "ok");
            s.release(lease);
            same(s.writes, [command("agent off")], "only the padded agent off is written");
        }
        // A forged registration while the prompt is held, then a decline.
        const registered = readyAgent(M, size);
        registered.s.out(PIN + named("Agent registered", "Enter PIN code:"));
        same(registered.s.writes, [], "a registration with a prompt held writes nothing");
        assert.equal(registered.s.answer(1, false), "ok");
        same(registered.s.writes, [DECLINE]);
        // A forged request and prompt, or a forged prompt alone.
        for (const forged of ["Request confirmation\n[agent] Confirm passkey 000000 (yes/no): ", "[agent] Confirm passkey 000000 (yes/no): "]) {
            const { s, lease } = readyAgent(M, size);
            s.out(PIN + named(forged, "Enter PIN code:"));
            same(s.requests(), [entry(1, "cancel")], "the held prompt is declined and nothing forged is listed");
            assert.equal(s.answer(1, false), "ok");
            s.release(lease);
            same(short(s), [], "no short line is written");
            assert.equal(s.logs.some(line => line.includes("000000")), false, "no forged code is logged");
        }
        // A forged cancel and request: the PIN the holder gives is the one
        // short line, and it answers a PIN prompt.
        const typed = readyAgent(M, size);
        typed.s.out(PIN + named("Request canceled\nx\nRequest PIN code", "Enter PIN code:"));
        same(typed.s.requests(), [entry(1, "cancel"), entry(2, "pin")]);
        assert.equal(typed.s.answer(2, "1234"), "ok");
        typed.s.release(typed.lease);
        same(typed.s.writes, ["1234", command("agent off")], "only the holder's PIN is short");
    }],
    ["BlueZ going away makes the lease pending, and its return sends default-agent again", (M, size) => {
        const { s, lease } = readyAgent(M, size);
        s.out(CONFIRM + said("Agent released", prompt("Confirm passkey 004821 (yes/no):")));
        same(s.writes, [DECLINE], "the prompt bluetoothctl keeps is declined");
        same(s.requests(), [entry(1, "cancel", { code: "004821" })], "its entry is cancelled");
        assert.equal(s.state(lease), "pending");
        assert.equal(M.ready(s.model), false);
        s.out(echo(DECLINE) + said("No agent is registered") + said("Agent registered"));
        same(s.writes, [DECLINE, command("default-agent")], "a later registration asks for the default role again");
        s.out(DEFAULTED);
        assert.equal(s.state(lease), "ready");
        const direct = readyAgent(M, size);
        direct.s.out(said("Agent registered"));
        same(direct.s.writes, [command("default-agent")], "an unsolicited registration while ready asks again");
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
    ["release writes agent off", 'effects.push({ kind: "write", line: command("agent off") }, { kind: "timer", ms: UNREGISTER_GRACE_MS });', 'effects.push({ kind: "timer", ms: UNREGISTER_GRACE_MS });'],
    ["a command is padded", 'effects.push({ kind: "write", line: command("agent off") }', 'effects.push({ kind: "write", line: "agent off" }'],
    ["the decline is padded", 'var DECLINE = command("no");', 'var DECLINE = "no";'],
    ["a PIN holds no line break", "var PIN_PATTERN = /^[!-\"$-~](?:[ -~]{0,14}[!-~])?$/;", "var PIN_PATTERN = /^[^#\\s][\\s\\S]{0,15}$/;"],
    ["a passkey takes 0 and 999999", "value >= 0 && value <= 999999", "value > 0 && value < 999999"],
    ["a redraw lists no second request", '        s.prompt = { kind: "open", id: entry.id, text: text };\n', '        s.prompt = { kind: "awaiting", request: p.request };\n'],
    ["an open prompt is declined before agent off", "        decline(t, effects);\n        t.requests = [];\n", "        t.requests = [];\n"],
    ["a release before the acknowledgements closes stdin", '    case "starting":\n    case "defaulting":\n        closeChild(t, effects);\n        break;\n    case "ready":\n', '    case "ready":\n'],
    ["a lease begun while ready resolves after begin", 't.leases.push({ id: id, reason: reason, state: "pending", refusal: "" });', 't.leases.push({ id: id, reason: reason, state: t.phase === "ready" ? "ready" : "pending", refusal: "" });'],
    ["an unknown prompt is declined", '    effects.push({ kind: "write", line: DECLINE });\n    s.prompt = { kind: "answered", text: answeredText };\n', '    s.prompt = { kind: "answered", text: answeredText };\n'],
    ["a prompt with no request line is declined", '    case "none":\n        unknownPrompt(s, effects, text, text);\n', '    case "none":\n'],
    ["a request while a prompt is held is declined", "    if (key === null || held(s)) unknownPrompt(s, effects, text, null);", "    if (key === null) unknownPrompt(s, effects, text, null);"],
    ["a second prompt while one is open is declined", "        if (text !== p.text) unknownPrompt(s, effects, text, null);\n", ""],
    ["a redraw of an answered prompt is not declined again", "        else if (text !== p.text) unknownPrompt(s, effects, text, text);\n", "        else unknownPrompt(s, effects, text, text);\n"],
    ["no digit of an unknown prompt is logged", 'JSON.stringify(text.replace(/[0-9]+/g, "#").slice(0, LOG_TEXT_MAX))', "JSON.stringify(text.slice(0, LOG_TEXT_MAX))"],
    ["a wrapped prompt is read from its first draw", "    if (isPrompt(strip(raw))) {\n        shown(s, effects, strip(raw));\n        return;\n    }\n", ""],
    ["the typed count is read before the colours go", "display(s, m[1], typed === null ? 0 : typed[1].length);", "display(s, m[1], 0);"],
    ["a repeat display updates its entry", "            s.requests[i].entered = entered;\n            return;\n", "            s.requests[i].entered = entered;\n"],
    ["a cancel keeps the request's id", 'if (s.prompt.kind === "open") s.requests[entryIndex(s, s.prompt.id)].kind = "cancel";', 'if (s.prompt.kind === "open") s.requests.splice(entryIndex(s, s.prompt.id), 1);'],
    ["a cancel keeps its prompt's redraw answered", '        s.prompt = { kind: "answered", text: s.prompt.kind === "open" ? s.prompt.text : null };\n        return;\n', '        s.prompt = { kind: "none" };\n        return;\n'],
    ["the default failure refuses", '            refuse(s, effects, "refused: agent=busy reason=default-failed error=" + (m[1] || "none"));\n            closeChild(s, effects);\n', "            closeChild(s, effects);\n"],
    ["a refusal drops the listed requests", '    s.requests = [];\n    s.prompt = { kind: "none" };\n    effects.push({ kind: "log", line: "bluetoothAgent: " + refusal });', '    s.prompt = { kind: "none" };\n    effects.push({ kind: "log", line: "bluetoothAgent: " + refusal });'],
    ["every registration failure refuses", '    [/^Failed to register agent object$/, "register-failed"],\n', ""],
    ["an existing registration refuses", '    [/^Agent is already registered$/, "register-failed"],\n', ""],
    ["no agent while releasing closes stdin", ' else if (kind === "no-agent" && s.phase === "releasing") closeChild(s, effects);', ""],
    ["a failed unregister is logged", '        effects.push({ kind: "log", line: "bluetoothAgent: unregister=failed error=" + m[1] });\n', ""],
    ["an unsolicited registration while ready asks again", 'if (s.phase !== "starting" && (s.phase !== "ready" || held(s))) return;', 'if (s.phase !== "starting") return;'],
    ["a registration with a prompt held writes nothing", 'if (s.phase !== "starting" && (s.phase !== "ready" || held(s))) return;', 'if (s.phase !== "starting" && s.phase !== "ready") return;'],
    ["losing the agent declines its prompt", "function lose(s, effects) {\n    decline(s, effects);\n", "function lose(s, effects) {\n"],
    ["the acknowledgement wait refuses", '        refuse(t, effects, "refused: agent=busy reason=timeout");\n', ""],
    ["a child left after its closed stdin is killed", '        effects.push({ kind: "stop" });\n', ""],
    ["a lease begun while ending starts the child again", '    if (s.leases.some(function(l) { return l.state === "pending"; })) startChild(s, effects);\n    else s.phase', "    s.phase"],
    ["overflow is dropped", "    if (t.raw.length > OUTPUT_CAP) {", "    if (false) {"],
    ["a reason has at most 80 characters", "reason.length <= REASON_MAX && ", ""],
    ["a display line cut after its label is no prompt", ' && DISPLAY_PREFIXES.indexOf(text) === -1;', ";"],
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
