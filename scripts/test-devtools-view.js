#!/usr/bin/env node
// The Dev Tools plugin's decisions, shell/plugins/vgs.devtools/ViewLogic.js,
// under node: which queries each trigger runs and their argv, how an answer
// is read, the status values the service publishes, the TUI arguments an
// action passes, and the sections and rows the window draws. Every expected
// value is written out by hand.
//
// The controls at the end edit a copy of the logic, one rule at a time,
// and require this suite to fail on each copy.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { load } = require("../bin/lib/qml-library.js");

const dir = path.join(__dirname, "..", "shell", "plugins", "vgs.devtools");
const file = path.join(dir, "ViewLogic.js");
const Catalog = load(path.join(dir, "CatalogLogic.js"));
const manifest = JSON.parse(fs.readFileSync(path.join(dir, "manifest.json"), "utf8"));
// The logic runs in its own context, whose arrays and objects are not this
// one's; values are compared as JSON.
const same = (got, want, message) => assert.deepEqual(JSON.parse(JSON.stringify(got)), want, message === undefined ? JSON.stringify(want) : message);

// A list row as `devtools list --json` prints it, with FIELDS over an
// absent agent's defaults.
const row = fields => Object.assign({ id: "claude", name: "Claude Code", section: "agents", icon: "bot", brand: "claude", kind: null, installed: false, version: null,
    origin: null, manager: null, package: null, runtime: null, path: null, launcher: "absent", channels: null, actions: ["install"], error: null }, fields);
const list = (sections, other, mise) => ({ machine: "x86_64", mise: mise || { present: true, version: "2026.9.9" }, manager: "pacman",
    sections: Object.assign({ agents: [], apps: [], tools: [], envs: [], editors: [], terminals: [], databases: [] }, sections), other: other || [] });
const requirement = fields => Object.assign({ command: "gum", packages: { pacman: "gum" }, optional: false, purpose: "Draws the dialogs", state: "missing", package: { manager: "pacman", name: "gum" } }, fields);
const self = fields => Object.assign({ version: "0.1.0", method: "checkout", package: null, current: "0.1.0.r3.gabc1234", latest: "0.1.1", behind: false, error: null }, fields);
const ok = value => ({ value: value, error: null });

// Failures read from a command: [label, code, stderr, error].
const FAILURES = [
    ["a command that did not start", null, "", "start=failed"],
    ["a refusal line", 1, "fatal: noise\nvgsh: refused: manager=mise reason=absent binaries=mise\n", "manager=mise reason=absent binaries=mise"],
    ["the engine's refusal", 1, "devtools: refused: mise=failed args=ls,--json exit=2\n", "mise=failed args=ls,--json exit=2"],
    ["the first line without a refusal", 3, "\nboom\nmore\n", "boom"],
    ["no stderr", 4, "", "exit=4"],
    ["a long line is clipped", 1, "x".repeat(300), "x".repeat(199) + "…"]
];

// Answers read from stdout: [label, name, stdout, answer].
const ANSWERS = [
    ["a list", "catalog", JSON.stringify(list({})), ok(list({}))],
    ["a list without other", "catalog", JSON.stringify({ mise: { present: true }, sections: {} }), { value: null, error: "unparseable" }],
    ["a list missing a section", "catalog", JSON.stringify(Object.assign(list({}), { sections: { agents: [] } })), { value: null, error: "unparseable" }],
    ["not JSON", "catalog", "nope", { value: null, error: "unparseable" }],
    ["a doctor report", "requirements", JSON.stringify({ core: [], plugins: { "acme.x": [] } }), ok({ core: [], plugins: { "acme.x": [] } })],
    ["a doctor report whose plugin holds no list", "requirements", JSON.stringify({ core: [], plugins: { "acme.x": {} } }), { value: null, error: "unparseable" }],
    ["a self status", "vgs", JSON.stringify(self({})), ok(self({}))],
    ["a self status without behind", "vgs", JSON.stringify({ version: "0.1.0", method: "curl", error: null }), { value: null, error: "unparseable" }],
    ["a mise count", "updates", JSON.stringify([{ source: "mise", count: 2, packages: [{ name: "claude", old: "1", new: "2" }], checkedAt: 1, error: null }]),
        ok({ count: 2, packages: [{ name: "claude", old: "1", new: "2" }] })],
    ["a mise source that failed", "updates", JSON.stringify([{ source: "mise", count: null, packages: [], checkedAt: null, error: "timeout=120" }]), { value: null, error: "timeout=120" }],
    ["another source", "updates", JSON.stringify([{ source: "pacman", count: 0, packages: [], checkedAt: 1, error: null }]), { value: null, error: "unparseable" }],
    ["launcher lines", "launchers", "launcher=written command=claude path=/h/.local/bin/claude\n", ok(["launcher=written command=claude path=/h/.local/bin/claude"])]
];

function verify(logic) {
    // Sections: the catalog's own and `other`, each once, with an icon.
    same(logic.TOOL_SECTIONS.map(s => s.key).filter(k => k !== "other").sort(), JSON.parse(JSON.stringify(Catalog.SECTION_NAMES)).sort(), "the window draws every catalog section");
    same(logic.TOOL_SECTIONS.map(s => s.title), ["Agents", "Apps", "CLI tools", "Languages", "Editors", "Databases", "Terminals", "Other mise tools"]);
    // The TUI names the window runs are the manifest's.
    same(JSON.parse(JSON.stringify(logic.VERBS)).sort(), Object.keys(manifest.tui).sort(), "every TUI the window runs is declared");

    // Triggers.
    same(logic.queriesFor("start", {}, 0), ["launchers", "requirements", "vgs", "updates"]);
    same(logic.queriesFor("refresh", { vgs: 0, updates: 0 }, 1), ["launchers", "requirements", "vgs", "updates"]);
    same(logic.queriesFor("tui", {}, 0), ["launchers", "requirements", "updates"]);
    same(logic.queriesFor("setting", {}, 0), ["launchers"]);
    same(logic.queriesFor("scan", {}, 0), ["launchers", "requirements", "updates"], "a scan that found another set lists again, since it can bring mise");
    const fresh = logic.NETWORK_FRESH_MS;
    same(logic.queriesFor("open", { vgs: 1000, updates: 1000 }, 1000 + fresh - 1), ["launchers", "requirements"], "an open inside the window asks no remote");
    same(logic.queriesFor("open", { vgs: 1000, updates: 2000 }, 1000 + fresh), ["launchers", "requirements", "vgs"], "an open asks each remote whose answer is stale");
    same(logic.queriesFor("open", {}, 0), ["launchers", "requirements", "vgs", "updates"], "an open asks a remote never asked");
    assert.throws(() => logic.queriesFor("boot", {}, 0), /trigger "boot" is not one of/);
    assert.equal(logic.next("launchers"), "catalog");
    for (const name of ["catalog", "requirements", "vgs", "updates"]) assert.equal(logic.next(name), "");

    // Argv.
    same(logic.queryArgv("launchers", "/t", "/p", true), ["/p/bin/devtools", "--tree", "/t", "launchers", "refresh"]);
    same(logic.queryArgv("launchers", "/t", "/p", false), ["/p/bin/devtools", "--tree", "/t", "launchers", "remove"]);
    same(logic.queryArgv("catalog", "/t", "/p", false), ["/p/bin/devtools", "--tree", "/t", "list", "--json"]);
    same(logic.queryArgv("requirements", "/t", "/p", false), ["/t/bin/vgsh", "doctor", "--json"]);
    same(logic.queryArgv("vgs", "/t", "/p", false), ["/t/bin/vgsh", "self", "status", "--json"]);
    same(logic.queryArgv("updates", "/t", "/p", false), ["/t/bin/vgsh", "pkg", "check", "--json", "--source", "mise"]);
    assert.throws(() => logic.queryArgv("nope", "/t", "/p", false), /query "nope" is not one of/);

    // Answers.
    for (const [label, code, stderr, error] of FAILURES)
        same(logic.readAnswer("catalog", code, "", stderr), { value: null, error: error }, label);
    for (const [label, name, stdout, answer] of ANSWERS)
        same(logic.readAnswer(name, 0, stdout, ""), answer, label);

    // Missing requirements: the core's first, then each plugin's by id.
    same(logic.missingRequirements({ core: [requirement({ command: "node", state: "present" }), requirement({ optional: true })],
        plugins: { "zeta.x": [requirement({ command: "z", package: null })], "acme.y": [requirement({ command: "a" })] } }), [
        { owner: "core", command: "gum", purpose: "Draws the dialogs", optional: true, package: { manager: "pacman", name: "gum" } },
        { owner: "acme.y", command: "a", purpose: "Draws the dialogs", optional: false, package: { manager: "pacman", name: "gum" } },
        { owner: "zeta.x", command: "z", purpose: "Draws the dialogs", optional: false, package: null }
    ]);

    // Status values.
    same(logic.statusValues({}), { catalog: { tools: null, requirements: null, vgs: null, updates: null } }, "nothing answered publishes the empty catalog alone");
    same(logic.statusValues({ vgs: ok(self({})) }).checks, { tone: "ok", text: "Every check answered" });
    same(logic.statusValues({ vgs: ok(self({ error: "latest=timeout" })) }).checks, { tone: "warning", text: "vgsh self status failed: latest=timeout; a count a failed check feeds keeps its last answer" },
        "a self status that exited 0 with an error is a failed check");
    const listed = list({ agents: [row({ installed: true, origin: "mise", version: "2", actions: ["update", "remove"] }), row({ id: "codex" })], apps: [row({ id: "cmux", installed: null, error: "e" })] },
        [{ id: "github:o/x", installed: true, version: "1", actions: ["update", "remove"] }]);
    const values = logic.statusValues({ catalog: ok(listed), updates: ok({ count: 3, packages: [] }), requirements: ok({ core: [requirement({})], plugins: { "acme.y": [requirement({ state: "present" })] } }) });
    same([values.mise, values.installed, values.outdated, values.missingRequirements], [{ tone: "ok", text: "2026.9.9" }, 2, 3, 1]);
    same(values.catalog.requirements, ok([{ owner: "core", command: "gum", purpose: "Draws the dialogs", optional: false, package: { manager: "pacman", name: "gum" } }]), "the catalog holds the missing requirements alone");
    same(logic.statusValues({ catalog: ok(list({}, [], { present: false, version: null })) }).mise, { tone: "warning", text: "Not installed", action: true }, "a missing mise offers Install mise");
    const failed = logic.statusValues({ catalog: { value: null, error: "mise=absent" }, updates: { value: null, error: "timeout=120" }, requirements: { value: null, error: "exit=1" } });
    same(failed.mise, { tone: "danger", text: "Unknown: the tool list failed: mise=absent" });
    same(["installed", "outdated", "missingRequirements"].filter(k => k in failed), [], "a failed query publishes no count");
    same(failed.checks, { tone: "warning", text: "The tool list failed: mise=absent; vgsh doctor failed: exit=1; The update check failed: timeout=120; a count a failed check feeds keeps its last answer" },
        "a failure after a count was published names the count as older than the check");

    // TUI ends.
    same(logic.endedSince(null, { install: { running: false, code: 0, endedAt: 5 } }), [], "the first reading reports no end");
    same(logic.endedSince({ install: 5, update: null }, { install: { endedAt: 5 }, update: { endedAt: 7 }, remove: { endedAt: null } }), ["update"]);
    same(logic.endedSince({ install: 5 }, { install: { endedAt: 9 } }), ["install"], "a later run of the same TUI ended");
    same(logic.endings({ install: { endedAt: 5 }, remove: { endedAt: null } }), { install: 5, remove: null });

    // Action arguments.
    const herdr = { section: "apps", id: "herdr", channels: ["stable", "preview"] };
    same(logic.verbArgs("install", herdr, "preview"), ["herdr", "--channel", "preview"]);
    same(logic.verbArgs("install", herdr, "stable"), ["herdr"], "the default channel passes no flag");
    same(logic.verbArgs("install", herdr, ""), ["herdr"]);
    same(logic.verbArgs("update", herdr, "preview"), ["herdr"], "only install takes a channel");
    same(logic.verbArgs("remove", { section: "other", id: "github:o/x", channels: [] }, ""), ["--mise", "github:o/x"]);
    assert.throws(() => logic.verbArgs("launch", herdr, ""), /verb "launch" is not one of/);
    assert.equal(logic.updateEntry([{ key: "a/x", group: "Dev Tools" }, { key: "b/update", group: "Update" }, { key: "c/update", group: "Update" }]), "b/update");
    assert.equal(logic.updateEntry([{ key: "a/x", group: "Dev Tools" }]), "");

    // Rows.
    const drawn = r => { const v = logic.toolRow(r.section, r, false); return [v.name, v.icon, v.tile, v.secondary, v.chips, v.channels, v.actions.map(a => a.label), v.lines]; };
    same(drawn(row({ installed: true, origin: "mise", version: "2.1", actions: ["update", "remove"] })),
        ["Claude Code", "bot", "brand", "2.1", [{ text: "mise", tone: "neutral" }], [], ["Update", "Remove"], []]);
    same(drawn(row({ installed: true, origin: "foreign", path: "/h/.local/bin/claude", actions: [] })),
        ["Claude Code", "bot", "brand", "Installed · Managed outside VGS", [{ text: "Foreign", tone: "warning" }], [], [], []]);
    same(drawn(row({ section: "tools", id: "gh", name: "GitHub CLI", icon: null, brand: null, installed: true, origin: "package", manager: "pacman", package: "github-cli", version: "2.1", actions: [] })),
        ["GitHub CLI", "terminal", "neutral", "2.1", [{ text: "pacman", tone: "neutral" }], [], [], []]);
    same(drawn(row({ section: "envs", id: "rust", installed: true, origin: "managedBy", manager: "pacman", package: "rustup", actions: [] })),
        ["Claude Code", "bot", "brand", "Installed · Managed by the rustup package", [{ text: "pacman", tone: "neutral" }], [], [], []]);
    same(drawn(row({ section: "databases", installed: true, origin: "container", runtime: "podman", actions: ["remove"] })),
        ["Claude Code", "bot", "brand", "Installed", [{ text: "podman", tone: "neutral" }], [], ["Remove"], []]);
    same(drawn(row({ installed: null, error: "pkg=failed verb=owner exit=3", actions: [] })),
        ["Claude Code", "bot", "brand", "State unknown", [{ text: "Unknown", tone: "danger" }], [], [], ["pkg=failed verb=owner exit=3"]]);
    same(drawn(row({ section: "apps", channels: ["stable", "preview"] })),
        ["Claude Code", "bot", "brand", "Not installed", [], ["stable", "preview"], ["Install"], []]);
    same(drawn(row({ section: "apps", channels: ["stable", "preview"], installed: true, origin: "mise", version: "1", actions: ["update"] }))[5], [], "an installed row offers no channel");
    same(drawn(row({ section: "databases", actions: [] }))[3], "Not installed · Not offered on this system");
    same(drawn({ section: "other", id: "github:o/x", installed: true, version: "1", actions: ["update", "remove"] }),
        ["github:o/x", "package", "neutral", "1", [], [], ["Update", "Remove"], []]);
    same(logic.toolRow("agents", row({ launcher: "foreign" }), true).lines, ["Its launcher in ~/.local/bin is managed outside VGS"]);
    same(logic.toolRow("agents", row({ launcher: "foreign" }), false).lines, [], "a foreign launcher is named only while VGS writes launchers");
    same(logic.toolRow("agents", row({}), false).actions, [{ kind: "verb", verb: "install", label: "Install", variant: "primary" }]);

    // The VGS row.
    const vgs = (answer, entry) => { const v = logic.vgsRow(answer, entry); return [v.secondary, v.chips, v.actions, v.lines]; };
    same(vgs(null, ""), ["Checking", [], [], []]);
    same(vgs({ value: null, error: "exit=1" }, "x"), ["State unknown", [{ text: "Unknown", tone: "danger" }], [], ["vgsh self status failed: exit=1"]]);
    same(vgs(ok(self({ behind: true })), "acme.updates/update"),
        ["0.1.0.r3.gabc1234 · Git checkout", [{ text: "Update to 0.1.1", tone: "warning" }], [{ kind: "entry", verb: "acme.updates/update", label: "Update", variant: "primary" }], []]);
    same(vgs(ok(self({ behind: true })), "")[3], ["Enable a plugin with an Update entry, such as Updates, to update VGS from here"]);
    same(vgs(ok(self({ method: "package", package: "vgs-git" })), ""), ["0.1.0.r3.gabc1234 · Package vgs-git", [{ text: "Up to date", tone: "success" }], [], []]);
    same(vgs(ok(self({ method: null, current: null, latest: null, behind: null, error: "method=unknown path=/t" })), ""),
        ["0.1.0 · Unknown install", [{ text: "Unknown", tone: "neutral" }], [], ["method=unknown path=/t"]]);

    // A requirement row.
    const req = r => { const v = logic.requirementRow(r, 0); return [v.name, v.secondary, v.chips, v.actions, v.lines]; };
    same(req({ owner: "core", command: "gum", purpose: "Draws", optional: true, package: { manager: "pacman", name: "gum" } }),
        ["gum", "VGS · Draws", [{ text: "Missing", tone: "neutral" }, { text: "Optional", tone: "neutral" }], [{ kind: "doctor", verb: "", label: "Install", variant: "primary" }], []]);
    same(req({ owner: "acme.y", command: "z", purpose: "Draws", optional: false, package: null }),
        ["z", "acme.y · Draws", [{ text: "Missing", tone: "warning" }], [], ["No package on this system provides it; install z by hand"]]);

    // Sections.
    same(logic.sections(null, "", false), []);
    const catalog = values.catalog;
    same(logic.sections(catalog, "", false).map(s => [s.title, s.rows.map(r => r.name), s.lines]), [
        ["VGS", ["VGS", "gum"], []],
        ["Agents", ["Claude Code", "Claude Code"], []],
        ["Apps", ["Claude Code"], []],
        ["Other mise tools", ["github:o/x"], []]
    ], "VGS first, then each tool section that holds a row, in order");
    same(logic.sections(Object.assign({}, catalog, { requirements: ok([]) }), "", false)[0].lines, ["Every requirement is met"]);
    same(logic.sections(Object.assign({}, catalog, { requirements: { value: null, error: "exit=1" } }), "", false)[0].lines, ["vgsh doctor failed: exit=1"]);
    same(logic.sections({ tools: { value: null, error: "mise=absent" }, requirements: null, vgs: null, updates: null }, "", false).map(s => [s.title, s.lines]),
        [["VGS", []]].concat(logic.TOOL_SECTIONS.map(s => [s.title, ["The tool list failed: mise=absent"]])), "a failed list names its error in every section");
    assert.equal(logic.summary(catalog), "mise 2026.9.9 · 2 installed · 3 updates");
    assert.equal(logic.summary(null), "Listing tools");
    assert.equal(logic.summary({ tools: { value: null, error: "x" }, updates: null }), "The tool list failed");
    assert.equal(logic.summary(Object.assign({}, catalog, { updates: { value: null, error: "timeout=120" } })), "mise 2026.9.9 · 2 installed · the update check failed: timeout=120");

    // The window's lines.
    same(logic.runningLines({ remove: { running: true }, install: { running: true }, update: { running: false } }),
        ["An install runs in its window; the list refreshes when it ends", "A removal runs in its window; the list refreshes when it ends"]);
    assert.equal(logic.replyLine("ok"), "");
    assert.equal(logic.replyLine("refused: tui=install reason=busy"), "", "a busy answer raised the live window");
    assert.equal(logic.replyLine("refused: tui=install reason=launcher-missing"), "refused: tui=install reason=launcher-missing");
    assert.equal(logic.replyLine("refused: owner=acme.x reason=disabled"), "refused: owner=acme.x reason=disabled");
    assert.equal(logic.missingKey({ "acme.b": ["x"], core: [] }), logic.missingKey({ core: [], "acme.b": ["x"] }), "the owners' order is no change");
    assert.notEqual(logic.missingKey({ core: [] }), logic.missingKey({ core: ["gum"] }), "another missing command is a change");
}

verify(load(file));

// Each control removes one rule from a copy of the logic and keeps the
// text around it. The suite must fail on every copy.
const CONTROLS = [
    ["a missing mise offers no action", 'text: "Not installed", action: true }', 'text: "Not installed" }'],
    ["open skips a fresh remote", 'if (trigger !== "open" || !QUERIES[name].network) return true;', "return true;"],
    ["the list follows the launchers", 'return name === "launchers" ? "catalog" : "";', 'return "";'],
    ["a refusal line wins", 'if (at !== -1) return clip(lines[i].slice(at + "refused: ".length));', ""],
    ["a list is judged", 'if (!shaped(name, value)) return { value: null, error: "unparseable" };', ""],
    ["a mise source error", 'if (source.error !== null) return { value: null, error: clip(source.error) };', ""],
    ["missing only", 'if (row.state !== "missing") return;', ""],
    ["plugins in id order", "Object.keys(report.plugins).sort()", "Object.keys(report.plugins)"],
    ["installed counts true only", "return row.installed === true; }).length;\n        }", "return row.installed !== false; }).length;\n        }"],
    ["first reading reports none", "if (seen === null) return [];", "if (seen === null) seen = {};"],
    ["default channel passes no flag", "&& channel !== row.channels[0]", ""],
    ["foreign launcher only while writing", 'if (write && row.launcher === "foreign")', 'if (row.launcher === "foreign")'],
    ["channels only for an install", '&& row.actions.indexOf("install") !== -1) out.channels', ") out.channels"],
    ["update only with an entry", 'if (entry !== "") out.actions.push', "out.actions.push"],
    ["install only with a package", 'if (requirement.package === null) out.lines.push("No package on this system provides it; install " + requirement.command + " by hand");\n    else out.actions', "out.actions"],
    ["empty sections are left out", "if (drawn.rows.length > 0 || drawn.lines.length > 0) out.push(drawn);", "out.push(drawn);"],
    ["checks name a failure", "if (failed.length === 0) return", "if (true) return"],
    ["a self status's own error fails its check", '    if (name === "vgs" && answer.value.error !== null) return answer.value.error;\n', ""],
    ["summary names a failed update check", '    else if (updates !== null) parts.push("the update check failed: " + updates.error);\n', ""],
    ["the missing key sorts its owners", "Object.keys(missing).sort().map(", "Object.keys(missing).map("],
    ["busy says nothing", ' || /^refused: tui=\\S+ reason=busy$/.test(reply)', ""]
];

const source = fs.readFileSync(file, "utf8");
const scratchRoot = path.join(__dirname, "..", "tmp");
fs.mkdirSync(scratchRoot, { recursive: true });
const temp = fs.mkdtempSync(path.join(scratchRoot, "devtools-view-control-"));
try {
    for (const [label, needle, replacement] of CONTROLS) {
        assert.equal(source.split(needle).length, 2, `control "${label}": the text to replace must occur once`);
        const mutant = path.join(temp, "ViewLogic.js");
        fs.writeFileSync(mutant, source.replace(needle, () => replacement));
        let failed = false;
        try {
            verify(load(mutant));
        } catch (e) {
            failed = true;
        }
        assert.ok(failed, `control "${label}": the suite passed on logic without that rule`);
    }
} finally {
    fs.rmSync(temp, { recursive: true, force: true });
}
console.log(`test-devtools-view: ok failures=${FAILURES.length} answers=${ANSWERS.length} controls=${CONTROLS.length}`);
