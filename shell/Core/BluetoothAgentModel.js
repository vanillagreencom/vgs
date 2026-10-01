.pragma library

// The Bluetooth pairing agent's decisions (D085). shell/Core/BluetoothAgent.qml
// drives them over one `bluetoothctl --agent KeyboardDisplay` child, and
// scripts/test-bluetooth-agent.js replays bluetoothctl transcripts through
// them. Every event function takes the model and returns { model, effects },
// a new model and the effects for the owner to run in order:
//   { kind: "start" }           launch the child
//   { kind: "write", line }     one stdin line; the owner adds the newline
//   { kind: "close-stdin" }     close the child's stdin
//   { kind: "stop" }            kill the child
//   { kind: "timer", ms }       arm the one timer for MS, or stop it at 0
//   { kind: "resolve", lease }  call resolve(lease) after the caller returns
//   { kind: "log", line }       one warning line
// The BlueZ 5.87 facts each rule rests on are cited in
// docs/architecture/bluetooth-agent.md.

// How long the child has for each acknowledgement, for `agent off`'s, and
// for its exit once its stdin is closed.
var ACK_TIMEOUT_MS = 5000;
var UNREGISTER_GRACE_MS = 2000;
var EXIT_GRACE_MS = 2000;
// Output with no line end past this many characters is dropped.
var OUTPUT_CAP = 8192;
// bluetoothctl sends any line as the PIN, `no` included, and ignores an
// empty one. BlueZ refuses a PIN longer than 16 characters with
// org.bluez.Error.InvalidArgs and fails the request (src/agent.c:491-499,
// pincode_reply), so this line declines a PIN prompt.
var PIN_DECLINE = "00000000000000000";
var REASON_MAX = 80;
var LOG_TEXT_MAX = 80;

// A request line bluetoothctl prints once per request (client/agent.c), the
// kind its entry takes, and the prompt that follows it, whose group, when
// it has one, is the entry's `code` or `service`.
var REQUESTS = {
    "Request confirmation": { kind: "confirm", prompt: /^\[agent\] Confirm passkey (\d{6}) \(yes\/no\): $/, field: "code" },
    "Request PIN code": { kind: "pin", prompt: /^\[agent\] Enter PIN code: $/, field: null },
    "Request passkey": { kind: "passkey-entry", prompt: /^\[agent\] Enter passkey \(number in 0-999999\): $/, field: null },
    "Request authorization": { kind: "authorize", prompt: /^\[agent\] Accept pairing \(yes\/no\): $/, field: null },
    "Authorize service": { kind: "authorize", prompt: /^\[agent\] Authorize service (\S+) \(yes\/no\): $/, field: "service" }
};

// Every other line the agent reads, first match wins.
var LINES = [
    [/^Agent registered$/, "registered"],
    [/^Failed to register agent: (\S+)$/, "register-failed"],
    [/^Failed to register agent object$/, "register-failed"],
    [/^Agent is already registered$/, "register-failed"],
    [/^Default agent request successful$/, "defaulted"],
    [/^Failed to request default agent: (\S+)$/, "default-failed"],
    [/^No agent is registered$/, "no-agent"],
    [/^Agent unregistered$/, "unregistered"],
    [/^Failed to unregister agent: (\S+)$/, "unregister-failed"],
    [/^Agent released$/, "released"],
    [/^Request canceled$/, "canceled"],
    [/^\[agent\] Passkey: (\d{6})$/, "display-passkey"],
    [/^\[agent\] PIN code: (.+)$/, "display-pin"],
    [/^(?:Request|Authorize) /, "request-unknown"]
];

// The start of a display line, which a chunk can end on before its digits.
var DISPLAY_PREFIXES = ["[agent] Passkey: ", "[agent] PIN code: "];
var ESCAPES = /\x1b\[[0-?]*[ -\/]*[@-~]|\x1b[@-Z\\-_]/g;
var CONTROLS = /[\x00-\x1f\x7f]/g;
// DisplayPasskey prints the typed digits in bold gray before the rest.
var ENTERED = /\x1b\[1;30m(\d*)\x1b\[1;37m/;
// 1 to 16 printable ASCII characters, no leading `#` (a comment line to
// bluetoothctl), no leading or trailing space.
var PIN_PATTERN = /^[!-"$-~](?:[ -~]{0,14}[!-~])?$/;
// The phases in which bluetoothctl's agent prompts are read and answered.
var ANSWERING = ["starting", "defaulting", "ready"];

function initial() {
    return {
        phase: "off", refusal: "", leases: [], requests: [], prompt: { kind: "none" },
        nextLease: 1, nextRequest: 1, raw: "", overflowed: false
    };
}

function clone(s) { return JSON.parse(JSON.stringify(s)); }

function ready(s) { return s.phase === "ready"; }

// A lease's { state, refusal }: `released` once it is gone.
function leaseOf(s, id) {
    for (var i = 0; i < s.leases.length; i++)
        if (s.leases[i].id === id) return { state: s.leases[i].state, refusal: s.leases[i].refusal };
    return { state: "released", refusal: "" };
}

// The lending record: no pid, no code, no answer.
function record(s) {
    return {
        state: s.phase,
        running: s.phase !== "off" && s.phase !== "failed",
        leases: s.leases.map(function(l) { return { id: l.id, reason: l.reason, state: l.state }; }),
        requests: s.requests.length,
        refusal: s.refusal
    };
}

// "" for a lease reason a holder may give, else the refusal begin throws.
function reasonRefusal(reason) {
    var ok = typeof reason === "string" && reason.length <= REASON_MAX && reason.trim() !== "" && !/[\x00-\x1f\x7f]/.test(reason);
    return ok ? "" : "refused: bluetoothAgent reason=" + JSON.stringify(reason);
}

function live(s) {
    return s.leases.filter(function(l) { return l.state === "pending" || l.state === "ready"; });
}

function setLeases(s, from, to) {
    for (var i = 0; i < s.leases.length; i++)
        if (s.leases[i].state === from) s.leases[i].state = to;
}

function startChild(s, effects) {
    s.phase = "starting";
    s.refusal = "";
    s.raw = "";
    s.overflowed = false;
    s.prompt = { kind: "none" };
    s.requests = [];
    effects.push({ kind: "start" }, { kind: "timer", ms: ACK_TIMEOUT_MS });
}

function closeChild(s, effects) {
    s.phase = "closing";
    effects.push({ kind: "close-stdin" }, { kind: "timer", ms: EXIT_GRACE_MS });
}

function refuse(s, effects, refusal) {
    s.refusal = refusal;
    for (var i = 0; i < s.leases.length; i++) {
        var lease = s.leases[i];
        if (lease.state !== "pending" && lease.state !== "ready") continue;
        lease.state = "refused";
        lease.refusal = refusal;
    }
    s.requests = [];
    s.prompt = { kind: "none" };
    effects.push({ kind: "log", line: "bluetoothAgent: " + refusal });
}

// The child is gone: start it again for a lease begun meanwhile, else wait
// for the refused leases to be released, else stop.
function settle(s, effects) {
    s.requests = [];
    s.prompt = { kind: "none" };
    s.raw = "";
    effects.push({ kind: "timer", ms: 0 });
    if (s.leases.some(function(l) { return l.state === "pending"; })) startChild(s, effects);
    else s.phase = s.leases.length > 0 ? "failed" : "off";
}

function entryIndex(s, id) {
    for (var i = 0; i < s.requests.length; i++)
        if (s.requests[i].id === id) return i;
    return -1;
}

function declineLine(kind) { return kind === "pin" ? PIN_DECLINE : "no"; }

// Answers the prompt bluetoothctl holds open, if any, with its rejection:
// while one is open the next line written is its answer, whatever it says.
// Returns the open entry's index, or -1.
function decline(s, effects) {
    var p = s.prompt;
    if (p.kind === "awaiting") {
        effects.push({ kind: "write", line: declineLine(REQUESTS[p.request].kind) });
        s.prompt = { kind: "answered", text: null };
        return -1;
    }
    if (p.kind !== "open") return -1;
    var index = entryIndex(s, p.id);
    if (index === -1) throw new Error("bluetoothAgent: open prompt " + p.id + " has no entry");
    effects.push({ kind: "write", line: declineLine(s.requests[index].kind) });
    s.prompt = { kind: "answered", text: p.text };
    return index;
}

// BlueZ released the agent or went away: bluetoothctl keeps an open prompt
// after BlueZ released the agent (client/agent.c agent_release drops the
// request before agent_release_prompt looks for it), so it is declined
// before any later command, and its entry is cancelled for the holder.
function lose(s, effects) {
    var index = decline(s, effects);
    if (index !== -1) s.requests[index].kind = "cancel";
    setLeases(s, "ready", "pending");
    s.phase = "starting";
    effects.push({ kind: "timer", ms: 0 });
}

function unknownPrompt(s, effects, text, answeredText) {
    effects.push({ kind: "write", line: "no" });
    effects.push({ kind: "log", line: "bluetoothAgent: refused: prompt=unknown text=" + JSON.stringify(text.slice(0, LOG_TEXT_MAX)) });
    s.prompt = { kind: "answered", text: answeredText };
}

function requestLine(s, effects, key, text) {
    if (s.prompt.kind === "open")
        throw new Error("bluetoothAgent: request " + JSON.stringify(text) + " while prompt " + s.prompt.id + " is open; BlueZ sends one request per agent at a time");
    if (key === null) unknownPrompt(s, effects, text, null);
    else s.prompt = { kind: "awaiting", request: key };
}

function display(s, code, entered) {
    for (var i = 0; i < s.requests.length; i++) {
        if (s.requests[i].kind === "passkey-display" && s.requests[i].code === code) {
            s.requests[i].entered = entered;
            return;
        }
    }
    s.requests.push({ id: s.nextRequest++, kind: "passkey-display", code: code, service: "", entered: entered });
}

function strip(raw) { return raw.replace(ESCAPES, "").replace(CONTROLS, ""); }

// One newline-terminated line, RAW with its colours.
function line(s, effects, raw) {
    var text = strip(raw).trim();
    if (Object.prototype.hasOwnProperty.call(REQUESTS, text)) {
        if (ANSWERING.indexOf(s.phase) !== -1) requestLine(s, effects, text, text);
        return;
    }
    var kind = null, m = null;
    for (var i = 0; i < LINES.length && kind === null; i++) {
        m = LINES[i][0].exec(text);
        if (m !== null) kind = LINES[i][1];
    }
    switch (kind) {
    case "registered":
        if (s.phase !== "starting" && s.phase !== "ready") return;
        setLeases(s, "ready", "pending");
        s.phase = "defaulting";
        effects.push({ kind: "write", line: "default-agent" }, { kind: "timer", ms: ACK_TIMEOUT_MS });
        return;
    case "register-failed":
        if (s.phase !== "starting") return;
        refuse(s, effects, "refused: agent=busy reason=register-failed error=" + (m[1] || "none"));
        closeChild(s, effects);
        return;
    case "defaulted":
        if (s.phase !== "defaulting") return;
        s.phase = "ready";
        setLeases(s, "pending", "ready");
        effects.push({ kind: "timer", ms: 0 });
        return;
    case "default-failed":
    case "no-agent":
        if (s.phase === "defaulting") {
            refuse(s, effects, "refused: agent=busy reason=default-failed error=" + (m[1] || "none"));
            closeChild(s, effects);
        } else if (kind === "no-agent" && s.phase === "releasing") closeChild(s, effects);
        return;
    case "unregistered":
    case "released":
        if (s.phase === "releasing") closeChild(s, effects);
        else if (s.phase === "ready" || s.phase === "defaulting") lose(s, effects);
        return;
    case "unregister-failed":
        if (s.phase !== "releasing") return;
        effects.push({ kind: "log", line: "bluetoothAgent: unregister=failed error=" + m[1] });
        closeChild(s, effects);
        return;
    case "canceled":
        if (ANSWERING.indexOf(s.phase) === -1) return;
        if (s.prompt.kind === "open") s.requests[entryIndex(s, s.prompt.id)].kind = "cancel";
        s.prompt = { kind: "none" };
        return;
    case "display-passkey":
        if (ANSWERING.indexOf(s.phase) === -1) return;
        var typed = ENTERED.exec(raw);
        display(s, m[1], typed === null ? 0 : typed[1].length);
        return;
    case "display-pin":
        if (ANSWERING.indexOf(s.phase) === -1) return;
        display(s, m[1], 0);
        return;
    case "request-unknown":
        if (ANSWERING.indexOf(s.phase) !== -1) requestLine(s, effects, null, text);
        return;
    case null:
        return;
    }
    throw new Error("bluetoothAgent: line kind " + kind + " has no rule");
}

// Text shown and not ended by a newline: a prompt bluetoothctl drew, or a
// redraw of it after another message.
function shown(s, effects, text) {
    if (ANSWERING.indexOf(s.phase) === -1) return;
    if (text.indexOf("[agent] ") !== 0 || text.slice(-2) !== ": " || DISPLAY_PREFIXES.indexOf(text) !== -1) return;
    var p = s.prompt;
    switch (p.kind) {
    case "awaiting":
        var request = REQUESTS[p.request];
        var m = request.prompt.exec(text);
        if (m === null) {
            unknownPrompt(s, effects, text, text);
            return;
        }
        var entry = { id: s.nextRequest++, kind: request.kind, code: "", service: "", entered: 0 };
        if (request.field !== null) entry[request.field] = m[1];
        s.requests.push(entry);
        s.prompt = { kind: "open", id: entry.id, text: text };
        return;
    case "open":
        if (text === p.text) return;
        throw new Error("bluetoothAgent: prompt " + JSON.stringify(text) + " while prompt " + p.id + " is open; BlueZ sends one request per agent at a time");
    case "answered":
        if (p.text === null) p.text = text;
        else if (text !== p.text) unknownPrompt(s, effects, text, text);
        return;
    case "none":
        unknownPrompt(s, effects, text, text);
        return;
    }
    throw new Error("bluetoothAgent: prompt state " + p.kind + " is unknown");
}

function begin(s, reason) {
    var refusal = reasonRefusal(reason);
    if (refusal !== "") throw new Error(refusal);
    var t = clone(s), effects = [];
    var id = t.nextLease++;
    t.leases.push({ id: id, reason: reason, state: "pending", refusal: "" });
    if (t.phase === "off" || t.phase === "failed") startChild(t, effects);
    else if (t.phase === "ready") effects.push({ kind: "resolve", lease: id });
    return { model: t, effects: effects, lease: id };
}

// A lease begun while ready reads ready only from here, after begin returned.
function resolve(s, id) {
    var t = clone(s);
    for (var i = 0; i < t.leases.length; i++)
        if (t.leases[i].id === id && t.leases[i].state === "pending" && t.phase === "ready") t.leases[i].state = "ready";
    return { model: t, effects: [] };
}

function release(s, id) {
    var t = clone(s), effects = [];
    var before = t.leases.length;
    t.leases = t.leases.filter(function(l) { return l.id !== id; });
    if (t.leases.length === before) throw new Error("bluetoothAgent: release of lease " + id + " which is not held");
    if (live(t).length > 0) return { model: t, effects: effects };
    switch (t.phase) {
    case "starting":
    case "defaulting":
        closeChild(t, effects);
        break;
    case "ready":
        decline(t, effects);
        t.requests = [];
        t.phase = "releasing";
        effects.push({ kind: "write", line: "agent off" }, { kind: "timer", ms: UNREGISTER_GRACE_MS });
        break;
    case "failed":
        if (t.leases.length === 0) t.phase = "off";
        break;
    }
    return { model: t, effects: effects };
}

// CHUNK is stdout as it arrived: colours, carriage returns, line clears and
// prompts without a newline, split anywhere.
function output(s, chunk) {
    if (s.phase === "off" || s.phase === "failed") throw new Error("bluetoothAgent: output with no child");
    var t = clone(s), effects = [];
    t.raw += chunk;
    for (var m = /[\r\n]/.exec(t.raw); m !== null; m = /[\r\n]/.exec(t.raw)) {
        var segment = t.raw.slice(0, m.index), end = m[0];
        t.raw = t.raw.slice(m.index + 1);
        if (end === "\n") line(t, effects, segment);
        else shown(t, effects, strip(segment));
    }
    if (t.raw.length > OUTPUT_CAP) {
        t.raw = "";
        if (!t.overflowed) effects.push({ kind: "log", line: "bluetoothAgent: output=dropped chars=" + OUTPUT_CAP + "; no line end" });
        t.overflowed = true;
    } else shown(t, effects, strip(t.raw));
    return { model: t, effects: effects };
}

// CODE is the exit code, null for a child that never started; STDERR its
// first stderr line, logged with an unexpected end.
function exited(s, code, stderr) {
    var t = clone(s), effects = [];
    switch (t.phase) {
    case "starting":
    case "defaulting":
    case "ready":
        refuse(t, effects, "refused: agent=busy reason=ended code=" + (code === null ? "none" : code));
        if (stderr !== "") effects.push({ kind: "log", line: "bluetoothAgent: stderr=" + JSON.stringify(stderr.slice(0, LOG_TEXT_MAX)) });
        break;
    case "releasing":
    case "closing":
    case "stopping":
        break;
    default:
        throw new Error("bluetoothAgent: exit in phase " + t.phase + " with no child");
    }
    settle(t, effects);
    return { model: t, effects: effects };
}

function timeout(s) {
    var t = clone(s), effects = [];
    switch (t.phase) {
    case "starting":
    case "defaulting":
        refuse(t, effects, "refused: agent=busy reason=timeout");
        closeChild(t, effects);
        break;
    case "releasing":
        closeChild(t, effects);
        break;
    case "closing":
        t.phase = "stopping";
        effects.push({ kind: "stop" });
        break;
    default:
        throw new Error("bluetoothAgent: timer fired in phase " + t.phase);
    }
    return { model: t, effects: effects };
}

// Answers request ID with VALUE: true or false for confirm and authorize,
// a PIN string or false for pin, 0-999999 or false for passkey-entry, and
// anything for passkey-display and cancel, which it dismisses. `answer` is
// `ok` or the refusal.
function answer(s, id, value) {
    var t = clone(s), effects = [];
    var index = entryIndex(t, id);
    if (index === -1) return { model: t, effects: effects, answer: "refused: request=" + JSON.stringify(id) + " reason=unknown" };
    var entry = t.requests[index], reply = null, want = null;
    switch (entry.kind) {
    case "passkey-display":
    case "cancel":
        t.requests.splice(index, 1);
        return { model: t, effects: effects, answer: "ok" };
    case "confirm":
    case "authorize":
        want = "boolean";
        if (typeof value === "boolean") reply = value ? "yes" : "no";
        break;
    case "pin":
        want = "pin";
        if (value === false) reply = PIN_DECLINE;
        else if (typeof value === "string" && PIN_PATTERN.test(value)) reply = value;
        break;
    case "passkey-entry":
        want = "passkey";
        if (value === false) reply = "no";
        else if (typeof value === "number" && Number.isInteger(value) && value >= 0 && value <= 999999) reply = String(value);
        break;
    default:
        throw new Error("bluetoothAgent: request kind " + entry.kind + " has no answer");
    }
    if (reply === null) return { model: t, effects: effects, answer: "refused: request=" + JSON.stringify(id) + " reason=value want=" + want };
    if (t.prompt.kind !== "open" || t.prompt.id !== id)
        throw new Error("bluetoothAgent: request " + id + " is listed but its prompt is not open");
    effects.push({ kind: "write", line: reply });
    t.requests.splice(index, 1);
    t.prompt = { kind: "answered", text: t.prompt.text };
    return { model: t, effects: effects, answer: "ok" };
}
