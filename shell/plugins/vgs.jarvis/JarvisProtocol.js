.pragma library
.import "Session.js" as Session

// Service produces hello snapshots and intent(talk-down, talk-up, mute, stop).
// Daemon consumes those and produces status/state. A line excludes its LF.
var MAX_LINE_BYTES = 256 * 1024;

function fail(reason) {
    throw new Error("jarvis: protocol=" + reason);
}

function object(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value);
}

function keys(value, wanted, name) {
    if (!object(value) || Object.keys(value).sort().join(",") !== wanted.slice().sort().join(","))
        fail("shape-" + name);
}

// Count UTF-8 bytes in QML too, where Buffer and TextEncoder are absent.
function bytes(text) {
    var count = 0;
    for (var i = 0; i < text.length; i++) {
        var code = text.charCodeAt(i);
        if (code < 0x80) count++;
        else if (code < 0x800) count += 2;
        else if (code >= 0xd800 && code <= 0xdbff && i + 1 < text.length
                 && text.charCodeAt(i + 1) >= 0xdc00 && text.charCodeAt(i + 1) <= 0xdfff) {
            count += 4;
            i++;
        } else count += 3;
    }
    return count;
}

function bounded(line) {
    if (bytes(line) > MAX_LINE_BYTES) fail("line-too-long");
}

// Both streaming endpoints call this before retaining an unfinished line.
function feed(tail, chunk) {
    var parts = (tail + chunk).split("\n");
    for (var i = 0; i < parts.length; i++) bounded(parts[i]);
    return { lines: parts.slice(0, -1), tail: parts[parts.length - 1] };
}

function directory(value) {
    return typeof value === "string" && value.length > 1 && value[0] === "/" && !/[\x00-\x1f\x7f]/.test(value);
}

// Return the judged message, or throw a keyed protocol error.
function accept(line, direction) {
    if (typeof line !== "string") fail("line-not-string");
    bounded(line);
    var message;
    try { message = JSON.parse(line); } catch (error) { fail("json"); }
    if (!object(message)) fail("object");
    if (message.v !== 1) fail("version");
    if (typeof message.gen !== "number" || !Number.isSafeInteger(message.gen) || message.gen < 0)
        fail("generation");
    if (direction !== "shell" && direction !== "daemon") fail("direction");
    switch (message.type) {
    case "hello":
        if (direction !== "shell") fail("direction-hello");
        keys(message, ["v", "type", "gen", "settings", "directories", "revision", "locked", "keys"], "hello");
        keys(message.settings, ["mode"], "settings");
        if (message.settings.mode !== "hold" && message.settings.mode !== "toggle") fail("mode");
        keys(message.keys, ["talk", "mute", "stop"], "keys");
        for (var shortcut of Object.keys(message.keys)) {
            var key = message.keys[shortcut];
            // The core shortcut provider owns normalization and conflicts.
            if (key !== null && (typeof key !== "string" || key.length === 0))
                fail("key-" + shortcut);
        }
        keys(message.directories, ["state", "data", "runtime"], "directories");
        for (var name of Object.keys(message.directories))
            if (!directory(message.directories[name])) fail("directory-" + name);
        if (typeof message.locked !== "boolean") fail("lock");
        break;
    case "intent":
        if (direction !== "shell") fail("direction-intent");
        keys(message, ["v", "type", "gen", "revision", "intent"], "intent");
        if (["talk-down", "talk-up", "mute", "stop"].indexOf(message.intent) === -1) fail("intent");
        break;
    case "status":
        if (direction !== "daemon") fail("direction-status");
        keys(message, ["v", "type", "gen", "revision", "daemon"], "status");
        if (message.daemon !== "ready" && message.daemon !== "locked") fail("daemon");
        break;
    case "state":
        if (direction !== "daemon") fail("direction-state");
        keys(message, ["v", "type", "gen", "revision", "seq", "state", "phase"], "state");
        if (!Number.isSafeInteger(message.seq) || message.seq < 1) fail("sequence");
        if (!Session.validate(message.state)) fail("state");
        if (message.state.gen !== message.gen) fail("state-generation");
        if (message.phase !== Session.phaseOf(message.state)) fail("phase");
        break;
    default:
        fail("type");
    }
    if (typeof message.revision !== "string" || !/^[0-9a-f]{64}$/.test(message.revision)) fail("revision");
    return message;
}
