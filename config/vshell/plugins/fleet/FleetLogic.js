.pragma library
//
// Every decision the fleet plugin makes: what a status read means, what the
// pill says and in which colour, what the fleet costs, and which command an
// action runs. Rendering lives in FleetWidget.qml and FleetPopout.qml.
//
// Kept outside the QML so scripts/test-fleet-logic.js runs this exact source
// in Node, the same pattern as the mercury plugin. Nothing between the markers
// may reference the widget, a Theme token or a Qt global.

// BEGIN FLEET LOGIC

// The fleet repository's client install links these into ~/.local/bin. Every
// read and every action runs one of them, never the Daytona API directly.
var STATUS_COMMAND = "lane-host-daytona";
var ATTACH_COMMAND = "fleet-attach";
var CODE_COMMAND = "fleet-code";
var BIN_DIR_LABEL = "~/.local/bin";

// The Daytona sandbox state of a running sandbox, and the states a lane rests
// in after a stop. A resting lane is present, so it was never closed.
var RUNNING_STATE = "started";
var RESTING_STATES = ["stopped", "archived"];

var DEFAULTS = {
    pollSeconds: 30,
    pillMode: "cost",
    staleHours: 24,
    showCost: true,
    useFixture: false
};

function pillModeOptions() {
    return [
        { value: "icon", label: "Icon only" },
        { value: "count", label: "Lane count" },
        { value: "cost", label: "Lane count and running rate" },
        { value: "control", label: "Control VM state" }
    ];
}

function fleetCommands() {
    return [STATUS_COMMAND, ATTACH_COMMAND, CODE_COMMAND];
}

// A saved choice outside the offered set falls back, so a hand-edited settings
// file cannot leave the pill in a mode nothing renders.
function optionValue(options, value, fallback) {
    for (var i = 0; i < options.length; i++) {
        if (options[i].value === value)
            return value;
    }
    return fallback;
}

function settingNumber(value, fallback, minimum) {
    if (value === undefined || value === null || value === "")
        return fallback;
    var n = Number(value);
    if (!isFinite(n))
        return fallback;
    return Math.max(minimum, n);
}

function settingBool(value, fallback) {
    return typeof value === "boolean" ? value : fallback;
}

// ---- reading ----

function statusArgv(useFixture, fixturePath, binDir) {
    if (useFixture)
        return ["cat", "--", fixturePath];
    return [binDir + "/" + STATUS_COMMAND, "status", "--json"];
}

// The probe prints one line per fleet command it found executable.
function availableCommands(probeOut) {
    var found = {};
    var known = fleetCommands();
    var lines = String(probeOut || "").split("\n");
    for (var i = 0; i < lines.length; i++) {
        var name = lines[i].trim();
        if (known.indexOf(name) !== -1)
            found[name] = true;
    }
    return found;
}

// Why a command cannot run, or "" when it can. `available` is null until the
// first probe answers.
function commandProblem(command, available) {
    if (available === null || available === undefined)
        return "checking for " + command + " in " + BIN_DIR_LABEL;
    if (available[command] === true)
        return "";
    return command + " not found in " + BIN_DIR_LABEL;
}

function failure(reason) {
    return { ok: false, error: reason };
}

function firstLine(text) {
    var lines = String(text || "").split("\n");
    for (var i = 0; i < lines.length; i++) {
        if (lines[i].trim() !== "")
            return lines[i].trim();
    }
    return "";
}

function sandboxProblem(sandbox, index) {
    if (sandbox === null || typeof sandbox !== "object")
        return "sandbox " + index + " is not an object";
    if (typeof sandbox.role !== "string" || typeof sandbox.state !== "string")
        return "sandbox " + index + " has no role or state";
    if (typeof sandbox.rate_per_hour !== "number" || !isFinite(sandbox.rate_per_hour))
        return "sandbox " + index + " has no rate_per_hour";
    return "";
}

// One settled read of the status command. A failed, killed or unparsable read
// is a failure the pill reports, never an empty fleet.
function decodeStatus(exitCode, exitStatus, out, err) {
    if (exitStatus !== 0)
        return failure(STATUS_COMMAND + " status was killed");
    if (exitCode !== 0) {
        var reason = firstLine(err);
        return failure(STATUS_COMMAND + " status exited " + exitCode + (reason !== "" ? ": " + reason : ""));
    }
    var data;
    try {
        data = JSON.parse(String(out || ""));
    } catch (e) {
        return failure("status output is not JSON");
    }
    if (data === null || typeof data !== "object" || !Array.isArray(data.sandboxes))
        return failure("status output has no sandboxes list");
    if (typeof data.total_rate_per_hour !== "number" || !isFinite(data.total_rate_per_hour))
        return failure("status output has no total_rate_per_hour");
    for (var i = 0; i < data.sandboxes.length; i++) {
        var problem = sandboxProblem(data.sandboxes[i], i);
        if (problem !== "")
            return failure("status output: " + problem);
    }
    return { ok: true, status: data };
}

function laneRows(status) {
    return status.sandboxes.filter(function (sandbox) { return sandbox.role === "lane"; });
}

function controlRow(status) {
    var rows = status.sandboxes.filter(function (sandbox) { return sandbox.role === "control"; });
    return rows.length > 0 ? rows[0] : null;
}

// Minutes since `created`, or -1 when the sandbox reports no parsable time.
function ageMinutes(created, nowMs) {
    var at = Date.parse(String(created || ""));
    if (!isFinite(at))
        return -1;
    return Math.max(0, Math.floor((nowMs - at) / 60000));
}

function laneNeedsAttention(lane, nowMs, staleHours) {
    if (RESTING_STATES.indexOf(lane.state) !== -1)
        return true;
    var age = ageMinutes(lane.created, nowMs);
    return age >= 0 && age >= staleHours * 60;
}

// ---- the pill ----

// loading | error | warning | accent | neutral. `result` is null until the
// first read settles. Precedence: a failed read, then a lane that needs
// attention, then a running control VM with lanes; anything else is neutral.
function pillState(result, nowMs, staleHours) {
    if (result === null || result === undefined)
        return "loading";
    if (!result.ok)
        return "error";
    var lanes = laneRows(result.status);
    for (var i = 0; i < lanes.length; i++) {
        if (laneNeedsAttention(lanes[i], nowMs, staleHours))
            return "warning";
    }
    if (result.status.control_state === RUNNING_STATE && lanes.length > 0)
        return "accent";
    return "neutral";
}

function laneCountLabel(count) {
    return count === 1 ? "1 lane" : count + " lanes";
}

function rateLabel(rate, digits) {
    return "$" + Number(rate).toFixed(digits) + "/h";
}

function moneyLabel(amount) {
    return "$" + Number(amount).toFixed(2);
}

function controlStateLabel(status) {
    var state = status.control_state;
    return typeof state === "string" && state !== "" ? state : "absent";
}

function pillText(mode, result, showCost) {
    if (result === null || result === undefined)
        return "…";
    if (!result.ok)
        return "fleet: unreachable";
    var lanes = laneCountLabel(laneRows(result.status).length);
    switch (mode) {
    case "icon":
        return "";
    case "count":
        return lanes;
    case "cost":
        return showCost ? lanes + " · " + rateLabel(result.status.total_rate_per_hour, 1) : lanes;
    case "control":
        return "control " + controlStateLabel(result.status);
    }
    throw new Error("fleet: pillText got unvalidated pill mode " + mode);
}

function ageLabel(minutes) {
    if (minutes < 0)
        return "age unknown";
    if (minutes < 60)
        return minutes + "m";
    if (minutes < 48 * 60)
        return Math.floor(minutes / 60) + "h";
    return Math.floor(minutes / (24 * 60)) + "d";
}

// ---- cost ----

// Rate times running hours since the first of the month (UTC) for every
// sandbox running now. A sandbox's earlier stops and the lanes closed this
// month are not in the status report, so this is an estimate.
function monthToDateSpend(sandboxes, nowMs) {
    var now = new Date(nowMs);
    var monthStart = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1);
    var spend = 0;
    for (var i = 0; i < sandboxes.length; i++) {
        var sandbox = sandboxes[i];
        if (sandbox.state !== RUNNING_STATE)
            continue;
        var created = Date.parse(String(sandbox.created || ""));
        if (!isFinite(created))
            continue;
        var hours = Math.max(0, nowMs - Math.max(created, monthStart)) / 3600000;
        spend += sandbox.rate_per_hour * hours;
    }
    return spend;
}

// ---- actions ----

// fleet-control-boot names each control-VM tmux session after its clone's
// directory: the repository name without its owner.
function repositorySession(repository) {
    var parts = String(repository || "").split("/");
    return parts[parts.length - 1];
}

function actionCommand(action) {
    switch (action) {
    case "attachControl":
    case "attachLane":
        return ATTACH_COMMAND;
    case "openCode":
        return CODE_COMMAND;
    case "closeLane":
        return STATUS_COMMAND;
    }
    throw new Error("fleet: unknown action " + action);
}

// The argv one action runs. Attach and close open a terminal through
// `vshell terminal exec`; close holds it open so a refusal stays readable.
function actionArgv(action, row, vshell, binDir) {
    var command = binDir + "/" + actionCommand(action);
    switch (action) {
    case "attachControl":
        return [vshell, "terminal", "exec", "--tui", "--", command];
    case "attachLane":
        return [vshell, "terminal", "exec", "--tui", "--", command, repositorySession(row.repository)];
    case "openCode":
        return [command, "--all"];
    case "closeLane":
        return [vshell, "terminal", "exec", "--tui", "--hold", "--", command, "close", "--item", row.item];
    }
    throw new Error("fleet: unknown action " + action);
}

// END FLEET LOGIC
