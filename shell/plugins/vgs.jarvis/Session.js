.pragma library

// The daemon owns this value. Time enters only through event.at (monotonic
// milliseconds). Adapter callbacks carry the gen/op returned in their effect.
// Cleanup acknowledgments and a running tool's outcome retain their original
// identity across stop; content callbacks do not.
var SESSION_SETTINGS = ["mode", "voiceProvider", "voice", "language", "brain", "model", "customBaseUrl", "policy", "account"];
var RESPONSE_TIMEOUT_MS = 60000;
var APPROVAL_TIMEOUT_MS = 60000;
var APPROVAL_DRAW_MS = 700;
var EVENTS = [
    "snapshot", "indicator", "talk-down", "talk-up", "toggle", "mute", "unmute", "mute-toggle",
    "stop", "cancel", "interrupt", "capture-opened", "capture-closed", "capture-failed", "playback-failed", "partial",
    "final", "brain-done", "brain-failed", "cancelled", "play", "played",
    "flushed", "tool", "tool-done", "approval", "shown", "confirm", "approval-cancel", "deadline", "lease-ended"
];

function initial() {
    return {
        gen: 0, nextOp: 1, stale: 0, settings: {},
        gate: { kind: "down", reason: "starting" },
        mute: { kind: "off" }, capture: { kind: "closed" },
        turn: { kind: "none" }, brain: { kind: "closed" }, playback: { kind: "idle" },
        action: { kind: "none" }, approval: { kind: "none" }, fault: { kind: "none" },
        conversation: { kind: "ended" }, input: { kind: "released" },
        indicator: { kind: "gone" }, duplex: { kind: "half" }, toggleAt: null
    };
}

// One phase judge for the wire and the shell. Closing/flushing do not claim
// listening/speaking; mute completion waits for capture's close acknowledgment.
function phaseOf(s) {
    if (s.gate.kind === "down") return "down";
    if (s.fault.kind !== "none") return "error";
    if (s.approval.kind === "held") return "confirming";
    if (s.action.kind === "running") return "acting";
    if (s.playback.kind === "playing") return "speaking";
    if (s.turn.kind === "thinking" || s.turn.kind === "cancelling") return "thinking";
    if (s.capture.kind === "open" && s.capture.mode !== "armed") return "listening";
    if (s.capture.kind === "open") return "armed";
    return "idle";
}

function operation(s) { return s.nextOp++; }

function effect(s, effects, kind, values) {
    var e = { kind: kind, gen: s.gen, op: operation(s) };
    for (var key of Object.keys(values || {})) e[key] = values[key];
    effects.push(e);
    return e;
}

function closeCapture(s, effects) {
    if (s.capture.kind !== "open" && s.capture.kind !== "opening") return;
    var e = effect(s, effects, "capture-close", { target: s.capture.op });
    s.capture = { kind: "closing", gen: e.gen, op: e.op };
}

function cancelTurn(s, effects, at) {
    if (s.turn.kind === "thinking") {
        var old = s.turn;
        s.turn = { kind: "cancelling", gen: old.gen, op: old.op, deadline: at + 2000 };
        effect(s, effects, "brain-cancel", { gen: old.gen, target: old.op });
    } else if (s.turn.kind === "collecting") s.turn = { kind: "none" };
}

function closeBrain(s, effects) {
    if (s.brain.kind === "closed") return;
    effect(s, effects, "brain-close", { gen: s.brain.gen, target: s.brain.op });
    s.brain = { kind: "closed" };
}

function flushPlayback(s, effects) {
    if (s.playback.kind !== "playing") return;
    var old = s.playback;
    var e = effect(s, effects, "playback-flush", { gen: old.gen, target: old.op });
    s.playback = { kind: "flushing", gen: e.gen, op: e.op };
}

function dropApproval(s, effects, reason) {
    if (s.approval.kind !== "held") return;
    effect(s, effects, "approval-ended", { gen: s.approval.gen, target: s.approval.op,
        id: s.approval.id, reason: reason });
    s.approval = { kind: "none" };
}

function requestToolCancel(s, effects) {
    if (s.action.kind !== "running" || s.action.cancellation.kind !== "available") return;
    effect(s, effects, "tool-cancel", { gen: s.action.gen, target: s.action.op, tool: s.action.tool });
    s.action.cancellation = { kind: "requested" };
}

function end(s, effects, at, reason, stopTool) {
    if (s.conversation.kind !== "ended") {
        s.gen++;
        s.conversation = { kind: "ended" };
    }
    s.input = { kind: "released" };
    closeCapture(s, effects);
    dropApproval(s, effects, "thinking-timeout");
    cancelTurn(s, effects, at);
    if (s.turn.kind === "none") closeBrain(s, effects);
    flushPlayback(s, effects);
    dropApproval(s, effects, reason);
    if (stopTool) requestToolCancel(s, effects);
}

function canEngage(s) {
    return s.gate.kind === "up" && s.mute.kind === "off" && s.fault.kind !== "error";
}

function canCapture(s) {
    return canEngage(s) && s.indicator.kind === "shown"
        && s.playback.kind === "idle"
        && s.turn.kind !== "cancelling" && s.conversation.kind !== "ended" && s.input.kind !== "released";
}

function canPlayback(s) {
    return s.gate.kind === "up" && s.fault.kind !== "error" && s.playback.kind === "playing"
        && s.capture.kind === "closed";
}

function reconcile(s, effects) {
    if (!canCapture(s)) closeCapture(s, effects);
    else if (s.capture.kind === "closed") {
        var mode = s.input.kind === "held" ? "hold" : s.input.kind;
        var e = effect(s, effects, "capture-open", { mode: mode });
        s.capture = { kind: "opening", gen: e.gen, op: e.op, mode: mode };
    }
    if (canCapture(s) && (s.capture.kind === "opening" || s.capture.kind === "open") && s.turn.kind === "none") {
        var collect = effect(s, effects, "collect", {});
        s.turn = { kind: "collecting", gen: collect.gen, op: collect.op, partial: "" };
    }
    if (s.playback.kind === "playing" && s.playback.admission.kind === "waiting" && canPlayback(s)) {
        effect(s, effects, "playback-start", { gen: s.playback.gen, op: s.playback.op, source: s.playback.source });
        s.playback.admission = { kind: "started" };
    }
    if (s.mute.kind === "muting" && s.capture.kind === "closed") s.mute = { kind: "on" };
}

function start(s, effects, mode) {
    if (!canEngage(s)) return;
    if (s.conversation.kind === "ended") {
        s.gen++;
        s.conversation = { kind: "active" };
    } else if (s.conversation.kind === "interrupted") s.conversation = { kind: "active" };
    s.input = { kind: mode };
    reconcile(s, effects);
}

// A callback must match its owner, not merely the newest allocated number.
// Draining operations remain live only for their cleanup/outcome event.
function live(s, e, region, kinds) {
    var owner = s[region];
    return kinds.indexOf(owner.kind) !== -1 && e.gen === owner.gen && e.op === owner.op;
}

function stale(s) { s.stale++; }

function changedSettings(a, b) {
    for (var key of SESSION_SETTINGS) if (a[key] !== b[key]) return true;
    return false;
}

function canPropose(s) {
    return s.conversation.kind === "active" && s.action.kind === "none" && s.approval.kind === "none";
}

function toolDuration(e) {
    if (!Number.isFinite(e.timeoutMs) || e.timeoutMs <= 0)
        throw new Error("jarvis: session=tool-deadline tool=" + e.tool);
}

function interrupt(s, effects, at) {
    if (s.conversation.kind === "ended") return;
    s.conversation = { kind: "interrupted" };
    cancelTurn(s, effects, at);
    flushPlayback(s, effects);
    dropApproval(s, effects, "interrupt");
}

function toggle(s, effects, at) {
    if (!canEngage(s) || (s.toggleAt !== null && at - s.toggleAt < 250)) return;
    s.toggleAt = at;
    if (s.conversation.kind === "ended") start(s, effects, "conversation");
    else end(s, effects, at, "toggle", false);
}

function expire(s, effects, at) {
    if (s.turn.kind === "thinking" && at >= s.turn.deadline) {
        cancelTurn(s, effects, at);
        s.fault = { kind: "error", reason: "thinking-timeout", retry: 0 };
        s.input = { kind: "released" };
        closeCapture(s, effects);
    } else if (s.turn.kind === "cancelling" && at >= s.turn.deadline) {
        closeBrain(s, effects);
        s.turn = { kind: "none" };
    }
    if (s.approval.kind === "held" && at >= s.approval.deadline) dropApproval(s, effects, "timeout");
    if (s.action.kind === "running" && s.action.limit.kind === "pending" && at >= s.action.limit.deadline) {
        requestToolCancel(s, effects);
        effect(s, effects, "tool-outcome", { gen: s.action.gen, target: s.action.brain,
            source: s.action.op, tool: s.action.tool, outcome: "unknown" });
        // Expiry does not prove that the tool's external effects have ended.
        s.action.limit = { kind: "expired" };
    }
}

// Return a new state and ordered effects. The input state/event are untouched.
// The router supplies authorized proposals. Session owns confirmation identity
// and timing, not the typed call or the policy decision.
function reduce(state, e) {
    if (EVENTS.indexOf(e.type) === -1) throw new Error("jarvis: session=event type=" + e.type);
    if (!Number.isFinite(e.at) || e.at < 0) throw new Error("jarvis: session=clock");
    var s = JSON.parse(JSON.stringify(state));
    var effects = [];
    var expiredApproval = s.approval.kind === "held" && e.at >= s.approval.deadline
        ? s.approval : null;
    // A late callback cannot outrun a delayed event-loop timer.
    if (e.type !== "deadline") expire(s, effects, e.at);
    switch (e.type) {
    case "snapshot": {
        var settingsChanged = changedSettings(s.settings, e.settings);
        var devicesChanged = s.settings.microphone !== e.settings.microphone || s.settings.speaker !== e.settings.speaker;
        if (devicesChanged && s.fault.kind === "error" && s.fault.reason === "device-lost")
            s.fault = { kind: "none" };
        if (settingsChanged) {
            var before = s.gen;
            end(s, effects, e.at, "settings", false);
            if (s.gen === before) s.gen++;
            s.fault = { kind: "none" };
        }
        s.settings = JSON.parse(JSON.stringify(e.settings));
        if (e.locked !== false || !e.configured) {
            end(s, effects, e.at, "gate", false);
            s.gate = { kind: "down", reason: e.locked === null ? "lock-unknown"
                : e.locked ? "locked" : "unconfigured" };
        } else s.gate = { kind: "up" };
        break;
    }
    case "indicator":
        s.indicator = { kind: e.shown ? "shown" : "gone" };
        break;
    case "talk-down":
        if (s.settings.mode === "toggle") { toggle(s, effects, e.at); break; }
        if (s.input.kind === "held") break;
        interrupt(s, effects, e.at);
        start(s, effects, "held");
        break;
    case "talk-up":
        if (s.settings.mode === "toggle") break;
        if (s.input.kind !== "held") break;
        s.input = { kind: "released" };
        closeCapture(s, effects);
        break;
    case "toggle":
        toggle(s, effects, e.at);
        break;
    case "mute-toggle":
        if (s.mute.kind === "on") {
            s.mute = { kind: "off" };
            effect(s, effects, "mute-store", { muted: false });
        } else if (s.mute.kind === "off") {
            end(s, effects, e.at, "mute", false);
            s.mute = { kind: "muting" };
            effect(s, effects, "mute-store", { muted: true });
        }
        break;
    case "mute":
        end(s, effects, e.at, "mute", false);
        if (s.mute.kind === "off") s.mute = { kind: "muting" };
        break;
    case "unmute":
        // An in-flight close must finish before a new capture can open.
        if (s.mute.kind === "on") s.mute = { kind: "off" };
        break;
    case "stop":
        end(s, effects, e.at, "stop", true);
        break;
    case "lease-ended":
        end(s, effects, e.at, "lease", true);
        // EOF is teardown, not an interactive cancellation. No adapter may
        // retain the daemon while waiting for an acknowledgment.
        closeBrain(s, effects);
        if (s.turn.kind === "cancelling") s.turn = { kind: "none" };
        break;
    case "cancel":
        s.input = { kind: "released" };
        closeCapture(s, effects);
        cancelTurn(s, effects, e.at);
        dropApproval(s, effects, "cancel");
        break;
    case "interrupt":
        interrupt(s, effects, e.at);
        break;
    case "capture-opened":
        if (!live(s, e, "capture", ["opening"])) { stale(s); break; }
        s.capture.kind = "open";
        if (s.fault.kind === "retrying") s.fault = { kind: "none" };
        break;
    case "capture-failed": {
        if (!live(s, e, "capture", ["opening", "open"])) { stale(s); break; }
        var retry = s.fault.kind === "retrying" ? s.fault.retry : 0;
        s.fault = e.reason === "device-lost" && retry < 3
            ? { kind: "retrying", reason: e.reason, retry: retry + 1 }
            : { kind: "error", reason: e.reason, retry: retry };
        closeCapture(s, effects);
        if (s.turn.kind === "collecting") s.turn = { kind: "none" };
        break;
    }
    case "capture-closed":
        if (!live(s, e, "capture", ["closing"])) { stale(s); break; }
        s.capture = { kind: "closed" };
        break;
    case "partial":
        if (!live(s, e, "turn", ["collecting"])) { stale(s); break; }
        s.turn.partial = e.text;
        break;
    case "final":
        if (!live(s, e, "turn", ["collecting"])) { stale(s); break; }
        if (s.conversation.kind === "interrupted") s.conversation = { kind: "active" };
        if (s.input.kind === "held") s.input = { kind: "released" };
        closeCapture(s, effects);
        var brain = effect(s, effects, "brain-send", { text: e.text });
        if (s.brain.kind === "closed") s.brain = { kind: "acquired", gen: brain.gen, op: brain.op };
        brain.owner = s.brain.op;
        s.turn = { kind: "thinking", gen: brain.gen, op: brain.op, deadline: e.at + RESPONSE_TIMEOUT_MS };
        break;
    case "brain-done":
    case "brain-failed":
        if (!live(s, e, "turn", ["thinking"])) { stale(s); break; }
        s.turn = { kind: "none" };
        if (e.type === "brain-failed") {
            s.fault = { kind: "error", reason: e.reason, retry: 0 };
            end(s, effects, e.at, "brain-failed", false);
        }
        break;
    case "cancelled":
        if (!live(s, e, "turn", ["cancelling"])) { stale(s); break; }
        closeBrain(s, effects);
        s.turn = { kind: "none" };
        break;
    case "play":
        if (!live(s, e, "turn", ["thinking"])) { stale(s); break; }
        if (s.playback.kind !== "idle" || s.conversation.kind === "interrupted") break;
        s.playback = { kind: "playing", gen: s.gen, op: operation(s), source: e.op,
            interruptible: e.interruptible, admission: { kind: "waiting" } };
        break;
    case "played":
        if (!live(s, e, "playback", ["playing"])) { stale(s); break; }
        s.playback = { kind: "idle" };
        break;
    case "flushed":
        if (!live(s, e, "playback", ["flushing"])) { stale(s); break; }
        s.playback = { kind: "idle" };
        break;
    case "playback-failed":
        if (!live(s, e, "playback", ["playing"])) { stale(s); break; }
        s.fault = { kind: "error", reason: e.reason, retry: 0 };
        end(s, effects, e.at, "playback-failed", false);
        break;
    case "tool":
        if (!live(s, e, "turn", ["thinking"])) { stale(s); break; }
        if (!canPropose(s)) break;
        toolDuration(e);
        var tool = effect(s, effects, "tool-start", { tool: e.tool, id: e.id });
        s.action = { kind: "running", gen: tool.gen, op: tool.op, tool: e.tool,
            brain: e.op, limit: { kind: "pending", deadline: e.at + e.timeoutMs },
            cancellation: { kind: e.cancellable ? "available" : "unavailable" } };
        break;
    case "tool-done":
        if (!live(s, e, "action", ["running"])) { stale(s); break; }
        if (["completed", "failed", "unknown"].indexOf(e.outcome) === -1)
            throw new Error("jarvis: session=tool-outcome");
        effect(s, effects, "tool-outcome", { gen: s.action.gen, target: s.action.brain,
            source: s.action.op, tool: s.action.tool, outcome: e.outcome });
        s.action = { kind: "none" };
        break;
    case "approval":
        if (!live(s, e, "turn", ["thinking"])) { stale(s); break; }
        if (!canPropose(s)) break;
        toolDuration(e);
        var hold = effect(s, effects, "approval-show", { id: e.id, digest: e.digest });
        s.approval = { kind: "held", gen: hold.gen, op: hold.op, id: e.id, digest: e.digest,
            deadline: e.at + APPROVAL_TIMEOUT_MS, shownAt: null, physical: e.physical,
            text: e.text, tool: e.tool, timeoutMs: e.timeoutMs, cancellable: e.cancellable,
            brain: e.op };
        break;
    case "shown":
        if (!live(s, e, "approval", ["held"])) { stale(s); break; }
        if (e.id !== s.approval.id) { stale(s); break; }
        if (s.approval.shownAt === null) s.approval.shownAt = e.at;
        break;
    case "confirm": {
        var approval = s.approval;
        var reason = approval.kind !== "held" ? (expiredApproval !== null ? "expired" : "no-hold")
            : e.gen !== approval.gen || e.id !== approval.id || e.digest !== approval.digest ? "identity"
            : ["key", "button", "voice"].indexOf(e.source) === -1 ? "source"
            : approval.shownAt === null || e.at - approval.shownAt < APPROVAL_DRAW_MS ? "early"
            : e.source === "voice" && approval.physical ? "voice-physical" : null;
        if (reason !== null) {
            effect(s, effects, "confirm-refused", { reason: reason, id: e.id,
                gen: approval.kind === "held" ? approval.gen : s.gen,
                target: approval.kind === "held" ? approval.brain : null });
            break;
        }
        s.approval = { kind: "none" };
        var accepted = effect(s, effects, "tool-start", { tool: approval.tool,
            id: approval.id, confirmed: e.source });
        s.action = { kind: "running", gen: accepted.gen, op: accepted.op, tool: approval.tool,
            brain: approval.brain, limit: { kind: "pending", deadline: e.at + approval.timeoutMs },
            cancellation: { kind: approval.cancellable ? "available" : "unavailable" } };
        break;
    }
    case "approval-cancel":
        if (e.id !== s.approval.id || e.gen !== s.approval.gen) { stale(s); break; }
        dropApproval(s, effects, "cancel");
        break;
    case "deadline":
        if (live(s, e, "turn", ["thinking", "cancelling"])
                || live(s, e, "approval", ["held"]) || live(s, e, "action", ["running"]))
            expire(s, effects, e.at);
        else stale(s);
        break;
    }
    reconcile(s, effects);
    return { state: s, effects: effects };
}

// The state wire contains this exact record. This table is its sole region
// shape definition; both endpoints use it through JarvisProtocol.
var REGIONS = {
    gate: { down: "reason", up: "" }, mute: { off: "", muting: "", on: "" },
    capture: { closed: "", opening: "gen op mode", open: "gen op mode", closing: "gen op" },
    turn: { none: "", collecting: "gen op partial", thinking: "gen op deadline", cancelling: "gen op deadline" },
    brain: { closed: "", acquired: "gen op" },
    playback: { idle: "", playing: "gen op source interruptible admission", flushing: "gen op" },
    action: { none: "", running: "gen op tool brain limit cancellation" },
    approval: { none: "", held: "gen op id digest deadline shownAt physical text tool timeoutMs cancellable brain" },
    fault: { none: "", error: "reason retry", retrying: "reason retry" }, conversation: { ended: "", active: "", interrupted: "" },
    input: { released: "", held: "", conversation: "", "follow-up": "", armed: "" },
    indicator: { gone: "", shown: "" }, duplex: { half: "" }
};

function exact(value, names) {
    return value !== null && typeof value === "object" && !Array.isArray(value)
        && Object.keys(value).sort().join(",") === names.slice().sort().join(",");
}

function validate(s) {
    if (!exact(s, Object.keys(REGIONS).concat(["gen", "nextOp", "stale", "settings", "toggleAt"]))) return false;
    for (var name of ["gen", "nextOp", "stale"])
        if (!Number.isSafeInteger(s[name]) || s[name] < (name === "nextOp" ? 1 : 0)) return false;
    if (s.settings === null || typeof s.settings !== "object" || Array.isArray(s.settings)) return false;
    if (s.toggleAt !== null && (!Number.isFinite(s.toggleAt) || s.toggleAt < 0)) return false;
    for (var region of Object.keys(REGIONS)) {
        var r = s[region];
        if (r === null || !Object.prototype.hasOwnProperty.call(REGIONS[region], r.kind)) return false;
        var fields = REGIONS[region][r.kind] === "" ? [] : REGIONS[region][r.kind].split(" ");
        if (!exact(r, ["kind"].concat(fields))) return false;
        for (var f of fields) {
            if (["gen", "op", "brain", "source", "retry"].indexOf(f) !== -1) {
                if (!Number.isSafeInteger(r[f]) || r[f] < (["op", "brain", "source"].indexOf(f) !== -1 ? 1 : 0)) return false;
            } else if (f === "deadline" || f === "shownAt") {
                if (!(f === "shownAt" && r[f] === null) && (!Number.isFinite(r[f]) || r[f] < 0)) return false;
            } else if (f === "timeoutMs") {
                if (!Number.isFinite(r[f]) || r[f] <= 0) return false;
            } else if (["interruptible", "physical", "cancellable"].indexOf(f) !== -1) {
                if (typeof r[f] !== "boolean") return false;
            } else if (f === "cancellation") {
                if (!exact(r[f], ["kind"]) || ["available", "unavailable", "requested"].indexOf(r[f].kind) === -1) return false;
            } else if (f === "admission") {
                if (!exact(r[f], ["kind"]) || ["waiting", "started"].indexOf(r[f].kind) === -1) return false;
            } else if (f === "limit") {
                if (r[f] === null || typeof r[f] !== "object") return false;
                if (!exact(r[f], r[f].kind === "pending" ? ["kind", "deadline"] : ["kind"])) return false;
                if (["pending", "expired"].indexOf(r[f].kind) === -1) return false;
                if (r[f].kind === "pending" && (!Number.isFinite(r[f].deadline) || r[f].deadline < 0)) return false;
            } else if (typeof r[f] !== "string") return false;
        }
        if (region === "capture" && fields.indexOf("mode") !== -1
                && ["hold", "conversation", "follow-up", "armed"].indexOf(r.mode) === -1) return false;
        if (region === "gate" && r.kind === "down"
                && ["starting", "unconfigured", "node", "lock-unknown", "locked"].indexOf(r.reason) === -1) return false;
    }
    return true;
}
