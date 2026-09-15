#!/usr/bin/env node

// Pins the fleet plugin's decisions: the pill's state and text for a status read, the cost
// arithmetic, and the command each action runs. It runs the shipped source, the region between
// the FLEET LOGIC markers in config/vshell/plugins/fleet/FleetLogic.js, against the fixture the
// plugin ships beside it.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.join(__dirname, "..");
const PLUGIN = path.join(repoRoot, "config", "vshell", "plugins", "fleet");

const { evaluateMarked, guardChild } = require("./lib/qml-region.js");

guardChild();

const F = evaluateMarked(fs.readFileSync(path.join(PLUGIN, "FleetLogic.js"), "utf8"), "FLEET LOGIC", [
    "decodeStatus", "failure", "commandProblem", "availableCommands", "statusArgv", "pillState",
    "pillText", "laneRows", "controlRow", "monthToDateSpend", "moneyLabel", "rateLabel", "ageLabel",
    "actionArgv"
], "FleetLogic.js");

const FIXTURE_TEXT = fs.readFileSync(path.join(PLUGIN, "fleet-status.fixture.json"), "utf8");
const fixture = () => JSON.parse(FIXTURE_TEXT);
const read = status => F.decodeStatus(0, 0, JSON.stringify(status), "");
// The fixture's youngest lane started 50 minutes before this and its oldest 210 minutes before.
const NOW = Date.parse("2026-09-15T12:00:00Z");
const MODES = ["icon", "count", "cost", "control"];
const UNREACHABLE = MODES.map(() => "fleet: unreachable");

function withLane(index, fields) {
    const status = fixture();
    Object.assign(F.laneRows(status)[index], fields);
    return status;
}

test("the shipped fixture decodes as a status report", () => {
    const result = F.decodeStatus(0, 0, FIXTURE_TEXT, "");
    assert.equal(result.ok, true, result.error);
});

test("the pill's colour state and its text in every mode follow the status read", () => {
    // [why, result, stale hours, state, texts for icon, count, cost, control]
    for (const [why, result, staleHours, state, texts] of [
        ["a running control VM with young lanes is the accent",
            read(fixture()), 24, "accent", ["", "3 lanes", "3 lanes · $2.0/h", "control started"]],
        ["a stopped control VM is neutral",
            read(Object.assign(fixture(), { control_state: "stopped" })), 24, "neutral",
            ["", "3 lanes", "3 lanes · $2.0/h", "control stopped"]],
        ["an absent control VM is neutral and says so",
            read({ total_rate_per_hour: 0, sandboxes: [] }), 24, "neutral",
            ["", "0 lanes", "0 lanes · $0.0/h", "control absent"]],
        ["a running control VM with no lanes is neutral",
            read(Object.assign(fixture(), { total_rate_per_hour: 0.72, sandboxes: [fixture().sandboxes[0]] })), 24,
            "neutral", ["", "0 lanes", "0 lanes · $0.7/h", "control started"]],
        ["a stopped lane is the warning, even with the control VM stopped",
            read(Object.assign(withLane(1, { state: "stopped" }), { control_state: "stopped" })), 24, "warning",
            ["", "3 lanes", "3 lanes · $2.0/h", "control stopped"]],
        ["an archived lane is the warning",
            read(withLane(2, { state: "archived" })), 24, "warning", ["", "3 lanes", "3 lanes · $2.0/h", "control started"]],
        ["a lane at the stale age is the warning",
            read(fixture()), 3.5, "warning", ["", "3 lanes", "3 lanes · $2.0/h", "control started"]],
        ["a lane a minute under the stale age is not",
            read(withLane(0, { created: "2026-09-15T08:31:00Z" })), 3.5, "accent",
            ["", "3 lanes", "3 lanes · $2.0/h", "control started"]],
        ["a status command that exited nonzero is the error, in every mode",
            F.decodeStatus(1, 0, "", "no DAYTONA_API_KEY\n"), 24, "error", UNREACHABLE],
        ["a killed status command is the error", F.decodeStatus(0, 1, FIXTURE_TEXT, ""), 24, "error", UNREACHABLE],
        ["output that is not JSON is the error", F.decodeStatus(0, 0, "Traceback", ""), 24, "error", UNREACHABLE],
        ["output with no sandboxes list is the error", read({ total_rate_per_hour: 0 }), 24, "error", UNREACHABLE],
        ["output with no total rate is the error", read({ sandboxes: [] }), 24, "error", UNREACHABLE],
        ["a sandbox with no rate is the error",
            read(withLane(0, { rate_per_hour: null })), 24, "error", UNREACHABLE],
        ["a missing status command is the error",
            F.failure(F.commandProblem("lane-host-daytona", {})), 24, "error", UNREACHABLE],
        ["no read yet is loading, never zero lanes", null, 24, "loading", ["…", "…", "…", "…"]]
    ]) {
        assert.equal(F.pillState(result, NOW, staleHours), state, why);
        assert.deepEqual(MODES.map(mode => F.pillText(mode, result, true)), texts, why);
    }
    assert.equal(F.pillText("cost", read(fixture()), false), "3 lanes", "hiding cost drops the rate from the cost mode");
    assert.throws(() => F.pillText("tailnet", read(fixture()), true), /unvalidated pill mode tailnet/,
        "a mode outside the offered set is a caller error, not an empty pill");
});

test("month-to-date spend is rate times running hours since the first of the month in UTC", () => {
    const at = (created, state, rate) => ({ role: "lane", created, state, rate_per_hour: rate });
    // [why, sandboxes, now, expected dollars]
    for (const [why, sandboxes, now, expected] of [
        ["a sandbox created last month counts from the first",
            [at("2026-08-20T00:00:00Z", "started", 1)], Date.parse("2026-09-02T00:00:00Z"), 24],
        ["a sandbox created this month counts from its creation",
            [at("2026-09-15T10:00:00Z", "started", 0.5)], NOW, 1],
        ["a stopped sandbox adds nothing", [at("2026-09-15T10:00:00Z", "stopped", 0.5)], NOW, 0],
        ["a sandbox with no parsable creation time adds nothing", [at("", "started", 0.5)], NOW, 0],
        // Control 348 h at 0.72, then lanes of 3.5 h, 115 min and 50 min at 0.44.
        ["every running sandbox in the fixture is summed", fixture().sandboxes, NOW, 253.31]
    ])
        assert.ok(Math.abs(F.monthToDateSpend(sandboxes, now) - expected) < 1e-9,
            `${why}: got ${F.monthToDateSpend(sandboxes, now)}, want ${expected}`);
    assert.deepEqual([F.moneyLabel(253.31), F.rateLabel(2.04, 2), F.rateLabel(2.04, 1)], ["$253.31", "$2.04/h", "$2.0/h"]);
    // [minutes, label]
    for (const [minutes, label] of [[-1, "age unknown"], [0, "0m"], [59, "59m"], [60, "1h"], [2879, "47h"], [2880, "2d"]])
        assert.equal(F.ageLabel(minutes), label, `${minutes} minutes`);
});

test("each action runs its fleet command, assembled from the row", () => {
    const status = fixture();
    const control = F.controlRow(status);
    const lane = F.laneRows(status)[0];
    const V = "/usr/bin/vshell";
    const B = "/home/u/.local/bin";
    // [why, action, row, argv]
    for (const [why, action, row, argv] of [
        ["attaching to the control VM opens a terminal on fleet-attach and its default session",
            "attachControl", control, [V, "terminal", "exec", "--tui", "--", `${B}/fleet-attach`]],
        ["attaching to a lane opens its repository's session, named without the owner",
            "attachLane", lane, [V, "terminal", "exec", "--tui", "--", `${B}/fleet-attach`, "vgs"]],
        ["opening in VSCodium runs fleet-code over every clone", "openCode", control, [`${B}/fleet-code`, "--all"]],
        ["closing runs lane-host-daytona close for the row's item in a terminal held open for a refusal",
            "closeLane", lane, [V, "terminal", "exec", "--tui", "--hold", "--", `${B}/lane-host-daytona`, "close", "--item", "VGS-376"]]
    ])
        assert.deepEqual(F.actionArgv(action, row, V, B), argv, why);
    assert.throws(() => F.actionArgv("park", lane, V, B), /unknown action park/);

    assert.deepEqual(F.statusArgv(false, "/p/fixture.json", B), [`${B}/lane-host-daytona`, "status", "--json"]);
    assert.deepEqual(F.statusArgv(true, "/p/fixture.json", B), ["cat", "--", "/p/fixture.json"]);
});

test("a command the probe did not find disables its action and names the command", () => {
    const available = F.availableCommands("fleet-attach\nunrelated-tool\n\n");
    assert.deepEqual(available, { "fleet-attach": true }, "only the fleet's own commands are recorded");
    // [command, available, whether it can run]
    for (const [command, avail, runs] of [
        ["fleet-attach", available, true],
        ["fleet-code", available, false],
        ["lane-host-daytona", available, false],
        ["fleet-attach", null, false]
    ]) {
        const problem = F.commandProblem(command, avail);
        assert.equal(problem === "", runs, `${command} with ${JSON.stringify(avail)}`);
        if (!runs)
            assert.ok(problem.includes(command), `the reason names ${command}: ${problem}`);
    }
});
