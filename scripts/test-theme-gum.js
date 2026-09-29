#!/usr/bin/env node
// The shipped gum target, themes/targets/gum, against the one reader of the
// file it writes: bin/vgsh-tui present, which parses gum.env and never
// sources it. The target renders under the shipped vgs and light packages;
// present must export every line of each render and warn nothing. The
// expected colours were written by hand from each package's theme.json.
//
// The control renders a copy of the template whose last value is a `$(...)`
// command and requires the same check to fail on it, with nothing run.
"use strict";
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { load } = require("../bin/lib/qml-library.js");
const render = require("../bin/lib/theme-render.js");

const repo = path.join(__dirname, "..");
const logic = load(path.join(repo, "shell", "Commons", "ThemeLogic.js"));
const TOKENS = load(path.join(repo, "shell", "Commons", "Tokens.js")).TOKENS;
const targetDir = path.join(repo, "themes", "targets", "gum");
const presenter = path.join(repo, "bin", "vgsh-tui");

const shippedPackage = name => {
    const dir = path.join(repo, "themes", name);
    const pkg = logic.acceptPackage(TOKENS, {
        directoryName: name,
        themeJson: fs.readFileSync(path.join(dir, "theme.json"), "utf8"),
        terminalJson: fs.readFileSync(path.join(dir, "terminal.json"), "utf8"),
        shipped: true
    });
    assert.equal(pkg.ok, true, pkg.ok ? "" : logic.refusalLine(pkg));
    return pkg;
};
const defaults = shippedPackage("vgs");

const judged = render.acceptTarget(logic, "gum", fs.readFileSync(path.join(targetDir, "target.json"), "utf8"));
assert.equal(judged.ok, true, judged.ok ? "" : render.refusalLine("gum", judged));
const target = judged.target;
assert.deepEqual(target.files.map(f => f.destination), ["gum.env"]);
const template = fs.readFileSync(path.join(targetDir, "gum.env"), "utf8");

const rendered = (pkg, text) => {
    const result = render.renderTarget(logic, TOKENS, target, new Map([["gum.env", text]]),
        { values: pkg.values, slots: render.terminalSource(pkg, defaults).terminal, curated: new Map(), installed: false });
    assert.equal(result.ok, true, result.ok ? "" : render.refusalLine("gum", result));
    return result.files[0].bytes.toString("utf8");
};

// Runs present on TEXT as the state directory's gum.env and returns what the
// command it ran saw. Throws unless present exported every line of TEXT
// whole and printed nothing on stderr. The child gets its own HOME, state
// and runtime directories, never the developer's.
const presented = (root, text) => {
    const state = path.join(root, "state");
    fs.mkdirSync(path.join(state, "vgs", "theme"), { recursive: true });
    fs.writeFileSync(path.join(state, "vgs", "theme", "gum.env"), text);
    const run = spawnSync(presenter, ["present", "--presentation", "plain", "--", "env"], {
        encoding: "utf8",
        env: { PATH: process.env.PATH, HOME: root, XDG_STATE_HOME: state, XDG_RUNTIME_DIR: root }
    });
    assert.equal(run.error, undefined, String(run.error));
    assert.equal(run.status, 0, run.stderr);
    assert.equal(run.stderr, "", `present warned: ${run.stderr}`);
    const seen = new Set(run.stdout.split("\n"));
    const lines = text.split("\n");
    assert.equal(lines.pop(), "", "gum.env ends in a newline");
    for (const line of lines) assert.ok(seen.has(line), `present did not export ${line}`);
    return seen;
};

// Hand-written from themes/<name>/theme.json: a line each for the base
// colours, and the library's four.
const EXPECTED = [
    ["vgs", ["FOREGROUND=#d7d7d9", "BACKGROUND=#000000", "GUM_CHOOSE_CURSOR_FOREGROUND=#ff5a36",
        "VGS_TUI_ACCENT=#ff5a36", "VGS_TUI_SUCCESS=#b4c96f", "VGS_TUI_WARNING=#ffb000", "VGS_TUI_DANGER=#f43f5e"]],
    ["light", ["FOREGROUND=#18181b", "BACKGROUND=#fafaf9", "GUM_CHOOSE_CURSOR_FOREGROUND=#a8330a",
        "VGS_TUI_ACCENT=#a8330a", "VGS_TUI_SUCCESS=#3f6212", "VGS_TUI_WARNING=#854d0e", "VGS_TUI_DANGER=#9f1239"]]
];

const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "theme-gum-")));
try {
    let lines = 0;
    for (const [name, expected] of EXPECTED) {
        const text = rendered(shippedPackage(name), template);
        const seen = presented(path.join(root, name), text);
        for (const line of expected) assert.ok(seen.has(line), `${name}: present did not export ${line}`);
        lines = text.split("\n").length - 1;
    }

    // Control: a `$(...)` value fails the check and runs nothing.
    const planted = path.join(root, "planted");
    const bad = rendered(defaults, template + `GUM_SPIN_TITLE_FOREGROUND=$(touch ${planted})\n`);
    assert.throws(() => presented(path.join(root, "control"), bad), new RegExp(`gum-env=rejected line=${template.split("\n").length} `),
        "control: the check passed a gum.env line holding $(...)");
    assert.equal(fs.existsSync(planted), false, "control: present ran the planted line");

    console.log(`test-theme-gum: ok packages=${EXPECTED.length} lines=${lines} controls=1`);
} finally {
    fs.rmSync(root, { recursive: true, force: true });
}
