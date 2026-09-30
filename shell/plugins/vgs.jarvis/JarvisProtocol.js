.pragma library
.import "Session.js" as Session

// Service produces hello snapshots and intent(talk-down, talk-up, mute, stop).
// Daemon produces status/state/devices/level/audio-fault. A line excludes its LF.
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
        keys(message.settings, ["mode", "microphone", "speaker", "brain"], "settings");
        if (typeof message.settings.brain !== "string") fail("shape-settings");
        if (message.settings.mode !== "hold" && message.settings.mode !== "toggle") fail("mode");
        for (var setting of ["microphone", "speaker"])
            if (typeof message.settings[setting] !== "string"
                    || !/^[^\x00-\x1f\x7f]{0,200}$/.test(message.settings[setting])) fail("device-setting");
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
    case "devices":
        if (direction !== "daemon") fail("direction-devices");
        keys(message, ["v", "type", "gen", "revision", "microphones", "speakers"], "devices");
        for (var group of ["microphones", "speakers"]) {
            var values = message[group];
            if (!Array.isArray(values) || values.length > 32) fail("choices");
            var seen = {};
            for (var choice of values) {
                keys(choice, ["label", "value"], "choice");
                if (typeof choice.label !== "string" || !/^[^\x00-\x1f\x7f]{1,60}$/.test(choice.label)
                        || typeof choice.value !== "string" || !/^[^\x00-\x1f\x7f]{1,200}$/.test(choice.value))
                    fail("choice");
                if (Object.prototype.hasOwnProperty.call(seen, choice.value)) fail("choice-duplicate");
                Object.defineProperty(seen, choice.value, { value: true });
            }
        }
        break;
    case "level":
        if (direction !== "daemon") fail("direction-level");
        keys(message, ["v", "type", "gen", "revision", "level"], "level");
        keys(message.level, ["capture", "playback"], "levels");
        for (var channel of ["capture", "playback"])
            if (!Number.isFinite(message.level[channel]) || message.level[channel] < 0 || message.level[channel] > 1) fail("level");
        break;
    case "audio-fault":
        if (direction !== "daemon") fail("direction-audio-fault");
        keys(message, ["v", "type", "gen", "revision", "reason"], "audio-fault");
        if (typeof message.reason !== "string" || !/^[^\x00-\x1f\x7f]{1,180}$/.test(message.reason))
            fail("audio-fault");
        break;
    default:
        fail("type");
    }
    if (typeof message.revision !== "string" || !/^[0-9a-f]{64}$/.test(message.revision)) fail("revision");
    return message;
}
