// Test-only tool driver for a disposable Jarvis daemon, 2026-10-01. It
// stands in for a brain: it reads one call file, opens a scripted turn and
// routes the call through the daemon's real router, Policy, audit and
// executors, then records the router's result. The installed daemon has no
// fixture option, import or environment switch; scripted.js supplies the
// turn's capture and brain ports.
//   desktop-driver.js DAEMON ROOT          install the driver in DAEMON
//   desktop-driver.js --readback-defect DESKTOP_JS
//                                          plant a read-back that never waits
"use strict";
const fs = require("node:fs");
const path = require("node:path");

/**
 * ROOT/call.json holds {id, tool, arguments, kind?}; the driver consumes it.
 * kind "approval" routes a harness program's request, which no brain is
 * offered; the default is a brain's "tool-call". ROOT/results.jsonl gets
 * {id, route, reason?} when the router answers the call, reason naming a
 * refusal, and {id, outcome, content} when its result reaches the brain port.
 */
function drive(root, runner, router) {
    fs.mkdirSync(root, { recursive: true });
    const record = value => fs.appendFileSync(path.join(root, "results.jsonl"), JSON.stringify(value) + "\n");
    runner.ports.brain.outcome = value => {
        for (const result of value.results) record({ id: result.id, outcome: value.outcome, content: result.item.content });
    };
    let busy = false;
    const timer = setInterval(() => {
        const file = path.join(root, "call.json");
        if (busy || !fs.existsSync(file)) return;
        const call = JSON.parse(fs.readFileSync(file, "utf8"));
        fs.unlinkSync(file);
        busy = true;
        const started = Date.now();
        let turnRequest = "new";
        const attempt = () => {
            // Executors register after their own Hyprland probe.
            const kind = call.kind ?? "tool-call";
            if (kind === "tool-call" && !router.offer().some(tool => tool.id === call.tool)) {
                if (Date.now() - started < 5000) { setTimeout(attempt, 20); return; }
                record({ id: call.id, outcome: "not-offered", content: "" });
                busy = false;
                return;
            }
            if (runner.state.turn.kind !== "thinking") {
                if (turnRequest === "new") {
                    turnRequest = "held";
                    runner.dispatch({ type: "talk-down" });
                }
                if (turnRequest === "held" && runner.state.capture.kind === "open") {
                    turnRequest = "released";
                    runner.dispatch({ type: "talk-up" });
                }
                if (runner.state.turn.kind !== "thinking" && Date.now() - started < 5000) {
                    setTimeout(attempt, 20);
                    return;
                }
            }
            const turn = runner.state.turn;
            if (turn.kind !== "thinking") record({ id: call.id, outcome: "no-turn", content: JSON.stringify(turn) });
            else {
                const answer = router.route({ kind, id: call.id, tool: call.tool, arguments: call.arguments },
                    { gen: turn.gen, op: turn.op });
                record({ id: call.id, route: answer.kind, ...(answer.kind === "refuse" ? { reason: answer.reason } : {}) });
            }
            busy = false;
        };
        attempt();
    }, 10); // Polls the row's call file, not a simulated latency.
    timer.unref();
    process.stdin.once("end", () => clearInterval(timer));
}

function edit(file, needle, replacement) {
    const source = fs.readFileSync(file, "utf8");
    if (source.split(needle).length !== 2) throw new Error("desktop-driver: instrumentation-match=" + needle);
    fs.writeFileSync(file, source.replace(needle, replacement));
}

function instrument(daemon, root) {
    const ports = "Object.assign(runner.ports, { capture: scripted.capture, brain: scripted.brain, playback: scripted.playback });";
    edit(daemon, ports, ports + "\n                    require(\"./desktop-driver-fixture.js\").drive("
        + JSON.stringify(root) + ", runner, router);");
    fs.copyFileSync(__filename, path.join(path.dirname(daemon), "desktop-driver-fixture.js"));
}

module.exports = { drive, instrument };
if (require.main === module) {
    if (process.argv[2] === "--readback-defect" && process.argv.length === 4)
        edit(process.argv[3], "if (verdict.met) return { kind: \"met\", seen: verdict.seen };", "return { kind: \"met\", seen: verdict.seen };");
    else if (process.argv.length === 4) instrument(process.argv[2], process.argv[3]);
    else throw new Error("desktop-driver: arguments=expected-daemon-root");
}
