#!/usr/bin/env node

// Pins the fleet plugin's decisions: the pill's state and text for a status read, the cost
// arithmetic, the saved settings, and the command each action runs. It runs the shipped source,
// the region between the FLEET LOGIC markers in config/vshell/plugins/fleet/FleetLogic.js,
// against the fixture the plugin ships beside it.

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
    "decodeStatus", "decodeProbe", "statusRead", "commandProblem", "pillState", "pillText", "laneRows",
    "controlRow", "monthToDateSpend", "moneyLabel", "rateLabel", "ageLabel", "actionArgv", "actionCommand",
    "optionValue", "settingNumber", "settingBool", "pillModeOptions"
], "FleetLogic.js");

const FIXTURE_TEXT = fs.readFileSync(path.join(PLUGIN, "fleet-status.fixture.json"), "utf8");
const fixture = () => JSON.parse(FIXTURE_TEXT);
const read = status => F.decodeStatus(0, JSON.stringify(status), "");
// The fixture's youngest lane started 50 minutes before this and its oldest 210 minutes before.
const NOW = Date.parse("2026-09-15T12:00:00Z");
const MODES = ["icon", "count", "cost", "control"];
const UNREACHABLE = MODES.map(() => "fleet: unreachable");
const B = "/home/u/.local/bin";

function withLane(index, fields) {
    const status = fixture();
    Object.assign(F.laneRows(status)[index], fields);
    return status;
}

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
        ["a lane in error is the warning",
            read(withLane(2, { state: "error" })), 24, "warning", ["", "3 lanes", "3 lanes · $2.0/h", "control started"]],
        ["a lane whose build failed is the warning",
            read(withLane(2, { state: "build_failed" })), 24, "warning", ["", "3 lanes", "3 lanes · $2.0/h", "control started"]],
        ["a paused lane is the warning",
            read(withLane(2, { state: "paused" })), 24, "warning", ["", "3 lanes", "3 lanes · $2.0/h", "control started"]],
        ["a lane at the stale age is the warning",
            read(fixture()), 3.5, "warning", ["", "3 lanes", "3 lanes · $2.0/h", "control started"]],
        ["a lane a minute under the stale age is not",
            read(withLane(0, { created: "2026-09-15T08:31:00Z" })), 3.5, "accent",
            ["", "3 lanes", "3 lanes · $2.0/h", "control started"]],
        ["a status command that exited nonzero is the error, in every mode",
            F.decodeStatus(1, "", "no DAYTONA_API_KEY\n"), 24, "error", UNREACHABLE],
        ["output that is not JSON is the error", F.decodeStatus(0, "Traceback", ""), 24, "error", UNREACHABLE],
        ["output with no sandboxes list is the error", read({ total_rate_per_hour: 0 }), 24, "error", UNREACHABLE],
        ["output with no total rate is the error", read({ sandboxes: [] }), 24, "error", UNREACHABLE],
        ["a sandbox with no rate is the error",
            read(withLane(0, { rate_per_hour: null })), 24, "error", UNREACHABLE],
        ["a missing status command is the error", F.statusRead({}, B), 24, "error", UNREACHABLE],
        ["no read yet is loading, never zero lanes", null, 24, "loading", ["…", "…", "…", "…"]]
    ]) {
        const detail = result && !result.ok ? `${why} (read failed: ${result.error})` : why;
        assert.equal(F.pillState(result, NOW, staleHours), state, detail);
        assert.deepEqual(MODES.map(mode => F.pillText(mode, result, true)), texts, detail);
    }
    assert.equal(F.pillText("cost", read(fixture()), false), "3 lanes", "hiding cost drops the rate from the cost mode");
    assert.throws(() => F.pillText("tailnet", read(fixture()), true), /unvalidated pill mode tailnet/,
        "a mode outside the offered set is a caller error, not an empty pill");
});

test("a failed status read names its exit code and the reason on the last stderr line", () => {
    const usage = "usage: lane-host-daytona [-h]\n                         {create,cat,put,close,list} ...\n";
    const invalid = "lane-host-daytona: error: argument cmd: invalid choice: 'status' (choose from 'create', 'close')";
    // [why, exit code, stdout, stderr, the failure the pill and popout report]
    for (const [why, exitCode, out, err, error] of [
        ["a nonzero exit quotes its reason", 1, "", "lane-host-daytona: no-api-key\n",
            "lane-host-daytona status exited 1: lane-host-daytona: no-api-key"],
        ["a nonzero exit is the error even after a valid report on stdout", 1, FIXTURE_TEXT, "",
            "lane-host-daytona status exited 1"],
        ["argparse writes its usage banner first and its error last, and the error is quoted", 2, "",
            usage + invalid + "\n\n", "lane-host-daytona status exited 2: " + invalid],
        ["a timed-out read arrives as exit 124", 124, "", "", "lane-host-daytona status exited 124"]
    ])
        assert.deepEqual(F.decodeStatus(exitCode, out, err), { ok: false, error }, why);
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

test("a hand-edited setting falls back to its default, or to its minimum when below it", () => {
    const modes = F.pillModeOptions();
    // [why, value read, expected]
    for (const [why, got, expected] of [
        ["an offered pill mode is kept", F.optionValue(modes, "count", "cost"), "count"],
        ["a pill mode outside the offered set falls back to the default", F.optionValue(modes, "tailnet", "cost"), "cost"],
        ["an unset pill mode is the default", F.optionValue(modes, undefined, "cost"), "cost"],
        ["a poll interval in range is kept", F.settingNumber(45, 30, 10), 45],
        ["a poll interval below the minimum is the minimum", F.settingNumber(0, 30, 10), 10],
        ["a non-numeric poll interval is the default", F.settingNumber("soon", 30, 10), 30],
        ["an empty poll interval is the default", F.settingNumber("", 30, 10), 30],
        ["a saved false is kept", F.settingBool(false, true), false],
        ["a non-boolean show-cost is the default", F.settingBool("false", true), true]
    ])
        assert.equal(got, expected, why);
});

test("each action runs its fleet command, assembled from the row", () => {
    const status = fixture();
    const control = F.controlRow(status);
    const lane = F.laneRows(status)[0];
    const V = "/usr/bin/vshell";
    const terminal = argv => [V, "terminal", "exec", "--tui", "--hold", "--", ...argv];
    // [why, action, row, the command the probe checks, argv]
    for (const [why, action, row, command, argv] of [
        ["attaching to the control VM opens a held terminal on fleet-attach and its default session",
            "attachControl", control, "fleet-attach", terminal([`${B}/fleet-attach`])],
        ["attaching to a lane opens its repository's session, named without the owner",
            "attachLane", lane, "fleet-attach", terminal([`${B}/fleet-attach`, "vgs"])],
        ["opening in VSCodium runs fleet-code over every clone", "openCode", control, "fleet-code", [`${B}/fleet-code`, "--all"]],
        ["closing runs lane-host-daytona close for the row's item in a held terminal",
            "closeLane", lane, "lane-host-daytona", terminal([`${B}/lane-host-daytona`, "close", "--item", "VGS-376"])]
    ]) {
        assert.deepEqual(F.actionArgv(action, row, V, B), argv, why);
        assert.equal(F.actionCommand(action), command, `${why}: the probe checks the command it runs`);
    }
    assert.throws(() => F.actionArgv("park", lane, V, B), /unknown action park/);
    assert.throws(() => F.actionCommand("park"), /unknown action park/);
});

test("the probe records the fleet's own commands, and a command it did not find is named as the reason it cannot run", () => {
    assert.deepEqual(F.decodeProbe(0, "fleet-attach\nunrelated-tool\n\n"), { ok: true, available: { "fleet-attach": true } },
        "only the fleet's own commands are recorded");
    assert.deepEqual(F.decodeProbe(124, "fleet-attach\n"), { ok: false, error: "the fleet command probe exited 124" },
        "a probe that timed out is a failure, never a fleet with commands missing");
    const available = { "fleet-attach": true };
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
    // [why, available, the status read]
    for (const [why, avail, expected] of [
        ["a found status command is read as JSON", { "lane-host-daytona": true },
            { ok: true, argv: [`${B}/lane-host-daytona`, "status", "--json"] }],
        ["a missing status command is a failure that names it", { "fleet-attach": true },
            { ok: false, error: "lane-host-daytona not found in ~/.local/bin" }]
    ])
        assert.deepEqual(F.statusRead(avail, B), expected, why);
});
