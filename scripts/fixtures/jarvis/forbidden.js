// Synthetic forbidden operations from the Jarvis plan § Policy, 2026-09-30.
// Reserved calls exercise Policy only. This list offers no future executor.
"use strict";

function cases({ home, project, roots }) {
    return [
        { name: "elevation", reason: "privilege-elevation",
            calls: [{ id: "shell.argv", args: { argv: ["sudo", "fixture-only"], cwd: project, network: false } }] },
        ...[
            ["credentials", home + "/.ssh/sentinel"],
            ["policy", roots.config + "/vgs/policy"],
            ["audit", roots.state + "/vgs/jarvis/audit/sentinel"],
            ["settings", roots.config + "/vgs/shell.json"]
        ].map(([name, file]) => ({ name, file, reason: "protected-path", calls: [
            { id: "files.read", args: { path: file } },
            { id: "files.write", args: { path: file, text: "fixture" } },
            { id: "files.delete", args: { path: file } },
            { id: "files.move", args: { from: file, to: project + "/moved" } },
            { id: "files.search", args: { path: file, query: "fixture" } },
            { id: "apps.open", args: { path: file } },
            { id: "shell.argv", args: { argv: ["pwd"], cwd: file, network: false } },
            { id: "task.start", args: { goal: "fixture", cwd: file } }
        ] })),
        { name: "locked", reason: "session-locked", locked: true,
            calls: [{ id: "shell.argv", args: { argv: ["pwd"], cwd: project, network: false } }] },
        ...["lock", "polkit", "vgs"].map(kind => ({ name: "target-" + kind, reason: "protected-target",
            input: { target: { kind, id: "fixture" } }, calls: [
                { id: "input.text", args: { text: "fixture" } },
                { id: "input.key", args: { chord: "SUPER+Y" } },
                { id: "input.click", args: { x: 1, y: 1, button: "left" } },
                { id: "input.scroll", args: { x: 1, y: 1, direction: "down", steps: 1 } },
                { id: "browser", args: { command: "fill", args: { ref: "@e1", text: "fixture" } } }
            ] })),
        { name: "terminal", reason: "terminal-text", profiles: ["cautious", "standard"],
            input: { target: { kind: "terminal", id: "fixture" } },
            calls: [{ id: "input.text", args: { text: "fixture" } }] }
    ];
}

module.exports = { cases };
