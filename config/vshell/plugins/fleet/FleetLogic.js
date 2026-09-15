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

// The Daytona sandbox state of a running sandbox, and the states of a lane
// that needs the owner: one resting after a stop or an archive is present, so
// it was never closed, and one in error, a failed build or a pause is not
// working.
var RUNNING_STATE = "started";
var ATTENTION_STATES = ["stopped", "archived", "error", "build_failed", "paused"];

var DEFAULTS = {
    pollSeconds: 30,
    pillMode: "cost",
    staleHours: 24,
    showCost: true
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

// One settled run of the probe: command name to true for each fleet command it
// printed as executable. A probe that did not exit 0 (a timeout arrives as 124)
// is a failure, never a fleet with every command missing.
function decodeProbe(exitCode, probeOut) {
    if (exitCode !== 0)
        return failure("the fleet command probe exited " + exitCode);
    var found = {};
    var known = fleetCommands();
    var lines = String(probeOut || "").split("\n");
    for (var i = 0; i < lines.length; i++) {
        var name = lines[i].trim();
        if (known.indexOf(name) !== -1)
            found[name] = true;
    }
    return { ok: true, available: found };
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

// The argv of the status read once the probe has answered, or the failure that
// names the missing status command.
function statusRead(available, binDir) {
    var problem = commandProblem(STATUS_COMMAND, available);
    if (problem !== "")
        return failure(problem);
    return { ok: true, argv: [binDir + "/" + STATUS_COMMAND, "status", "--json"] };
}

// The status command, argparse and a Python traceback all write the reason on
// the last stderr line, after any usage banner or stack.
function lastLine(text) {
    var lines = String(text || "").split("\n");
    for (var i = lines.length - 1; i >= 0; i--) {
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

// One settled read of the status command. A failed, timed-out (exit 124) or
// unparsable read is a failure the pill reports, never an empty fleet.
function decodeStatus(exitCode, out, err) {
    if (exitCode !== 0) {
        var reason = lastLine(err);
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
    if (ATTENTION_STATES.indexOf(lane.state) !== -1)
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

// Keeps a terminal open only when its command exits nonzero, so a refusal stays
// readable and a clean exit closes the window. `vshell terminal exec --hold`
// holds after every exit.
var HOLD_ON_FAILURE = 'code=0; "$@" || code=$?; if [ "$code" -ne 0 ]; then echo; ' +
    'echo "$0 exited $code. Press Enter to close."; read _; fi; exit "$code"';

// Each action, keyed by name: the fleet command the probe checks and the argv
// that runs it, so a button is enabled only for the command it runs. Attach and
// close open a terminal through `vshell terminal exec`; close holds it open
// after any exit, so its result stays readable.
var ACTIONS = {
    attachControl: {
        command: ATTACH_COMMAND,
        argv: function (path, row, vshell) {
            return [vshell, "terminal", "exec", "--tui", "--", "sh", "-c", HOLD_ON_FAILURE, ATTACH_COMMAND, path];
        }
    },
    attachLane: {
        command: ATTACH_COMMAND,
        argv: function (path, row, vshell) {
            return [vshell, "terminal", "exec", "--tui", "--", "sh", "-c", HOLD_ON_FAILURE, ATTACH_COMMAND, path,
                repositorySession(row.repository)];
        }
    },
    openCode: {
        command: CODE_COMMAND,
        argv: function (path) {
            return [path, "--all"];
        }
    },
    closeLane: {
        command: STATUS_COMMAND,
        argv: function (path, row, vshell) {
            return [vshell, "terminal", "exec", "--tui", "--hold", "--", path, "close", "--item", row.item];
        }
    }
};

function actionEntry(action) {
    if (!Object.prototype.hasOwnProperty.call(ACTIONS, action))
        throw new Error("fleet: unknown action " + action);
    return ACTIONS[action];
}

function actionCommand(action) {
    return actionEntry(action).command;
}

// The argv one action runs.
function actionArgv(action, row, vshell, binDir) {
    var entry = actionEntry(action);
    return entry.argv(binDir + "/" + entry.command, row, vshell);
}

// END FLEET LOGIC
