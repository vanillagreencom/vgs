.pragma library

// What the Jarvis bar widget shows, pure so scripts/test-jarvis-widget.js
// runs it under node: the one judge from the status the service publishes
// (`daemon`, `detail`, `audio`) to the widget's state, icon, tone and
// tooltip. The first matching rule wins:
//   live     capture is not closed: an open microphone always shows
//   problem  the daemon or audio report danger, or Session reads `error`
//   off      no Session state yet: the daemon's own text
//   muted    privacy mute is on, or turning on
//   off      the Session gate is down: one sentence per reason
//   working  Jarvis thinks, speaks, waits for a confirmation or acts
//   ready    Session is idle
// A tone is `calm` (the bar's foreground) or a group of Theme.badge.tone,
// whose foreground the widget draws in. A value outside the shapes the
// service and Session.js produce throws a keyed error; nothing falls back.

var LOOKS = {
    "live": { icon: "audio-lines", tone: "accent" },
    "problem": { icon: "circle-alert", tone: "danger" },
    "off": { icon: "power-off", tone: "neutral" },
    "muted": { icon: "mic-off", tone: "neutral" },
    "working": { icon: "loader", tone: "info" },
    "ready": { icon: "mic", tone: "calm" }
};
// Session's gate-down reasons (Session.js validate).
var GATE_TEXT = {
    "starting": "Jarvis is starting",
    "unconfigured": "Jarvis is not set up",
    "node": "Jarvis needs Node 22 or later",
    "lock-unknown": "Jarvis is off until the screen lock is known",
    "locked": "Jarvis is off while the screen is locked"
};
// The Session phases (Session.js phaseOf) in which Jarvis is working with
// its microphone closed. A coding task's own count is not in the status
// yet; `acting` is a running tool.
var WORK_TEXT = {
    "thinking": "Jarvis is thinking",
    "speaking": "Jarvis is speaking",
    "confirming": "Jarvis is waiting for your confirmation",
    "acting": "Jarvis is running a task"
};
// The tones Service.qml publishes for `daemon` and for `audio`.
var DAEMON_TONES = ["info", "warning", "danger"];
var AUDIO_TONES = ["info", "ok", "danger"];

function refuse(key, value) {
    throw new Error("jarvis widget: " + key + "=" + JSON.stringify(value) + " unexpected");
}

// A `daemon` or `audio` report, or null before the service published one.
function report(name, value, tones) {
    if (value === undefined) return null;
    if (value === null || typeof value !== "object" || typeof value.text !== "string"
            || tones.indexOf(value.tone) === -1)
        refuse(name, value);
    return value;
}

// Whether CAPTURE, Session's capture region, holds the microphone.
function microphoneOpen(capture) {
    switch (capture === null || typeof capture !== "object" ? undefined : capture.kind) {
    case "closed": return false;
    case "opening": case "open": case "closing": return true;
    default: refuse("capture", capture);
    }
}

// Whether MUTE, Session's mute region, is on or turning on.
function muted(mute) {
    switch (mute === null || typeof mute !== "object" ? undefined : mute.kind) {
    case "off": return false;
    case "muting": case "on": return true;
    default: refuse("mute", mute);
    }
}

// Whether GATE, Session's gate region, is down.
function gateDown(gate) {
    switch (gate === null || typeof gate !== "object" ? undefined : gate.kind) {
    case "up": return false;
    case "down":
        if (!Object.prototype.hasOwnProperty.call(GATE_TEXT, gate.reason)) refuse("gate", gate);
        return true;
    default: refuse("gate", gate);
    }
}

function look(state, line) {
    var out = LOOKS[state];
    return { state: state, icon: out.icon, tone: out.tone,
        tooltip: line + "\n" + (state === "muted" ? "Click to unmute" : "Click to mute") };
}

// The widget's { state, icon, tone, tooltip } for VALUES, the plugin's
// status values. A key the service has not published yet is undefined.
function view(values) {
    var daemon = report("daemon", values.daemon, DAEMON_TONES);
    var audio = report("audio", values.audio, AUDIO_TONES);
    var detail = values.detail === undefined ? null : values.detail;
    if (detail !== null && (typeof detail !== "object" || typeof detail.phase !== "string"
            || detail.state === null || typeof detail.state !== "object"))
        refuse("detail", detail);
    var state = detail === null ? null : detail.state;
    if (state !== null && microphoneOpen(state.capture)) return look("live", "Jarvis is using the microphone");
    if (daemon !== null && daemon.tone === "danger") return look("problem", daemon.text);
    if (detail !== null && detail.phase === "error") {
        if (state.fault === null || typeof state.fault !== "object" || typeof state.fault.reason !== "string")
            refuse("fault", state.fault);
        return look("problem", "Problem: " + state.fault.reason);
    }
    if (audio !== null && audio.tone === "danger") return look("problem", "Audio problem: " + audio.text);
    if (state === null) return look("off", daemon === null ? GATE_TEXT.starting : "Jarvis: " + daemon.text);
    if (muted(state.mute)) return look("muted", "Jarvis is muted");
    if (gateDown(state.gate)) return look("off", GATE_TEXT[state.gate.reason]);
    switch (detail.phase) {
    case "thinking": case "speaking": case "confirming": case "acting":
        return look("working", WORK_TEXT[detail.phase]);
    case "idle":
        return look("ready", "Jarvis is ready");
    default:
        // Listening and armed hold capture open, which reads live above;
        // down holds the gate down.
        refuse("phase", detail.phase);
    }
}
