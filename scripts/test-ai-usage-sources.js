#!/usr/bin/env node

// Drive `vshell ai-usage` source administration against an isolated HOME: the credential and
// config-directory store, and the AI Gateway provider that reads it. These cases run the real
// helper, so the file they assert about is the file the widget's setup page writes.
//
// An API key must never reach argv, where every process on the machine can read it out of
// /proc, and must never come back out of the helper. Both are checked here.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const repoRoot = path.join(__dirname, "..");
const VSHELL = path.join(repoRoot, "bin", "vshell");
const LOGIC = path.join(repoRoot, "config", "vshell", "plugins", "aiUsage", "AiUsageLogic.qml");
const MODULE = path.join(repoRoot, "bin", "vshell_ai_usage.py");

const home = fs.mkdtempSync(path.join(os.tmpdir(), "vgs-ai-sources-"));
const storePath = path.join(home, ".local", "state", "vshell", "ai-usage", "sources.json");

test.after(() => fs.rmSync(home, { recursive: true, force: true }));

// Every call runs against the temporary HOME, never the developer's own store. The gateway
// key is deliberately absent from the environment so no case can reach the network.
function run(args, stdin) {
    const env = Object.assign({}, process.env, { HOME: home });
    delete env.AI_GATEWAY_API_KEY;
    delete env.VERCEL_OIDC_TOKEN;
    const r = spawnSync(VSHELL, ["ai-usage"].concat(args), { encoding: "utf8", env: env, input: stdin });
    assert.equal(r.status, 0, `vshell ai-usage ${args.join(" ")} exited ${r.status}: ${r.stderr}`);
    try {
        return JSON.parse((r.stdout || "").trim());
    } catch (e) {
        return assert.fail(`vshell ai-usage ${args.join(" ")} did not emit JSON: ${JSON.stringify(r.stdout)}`);
    }
}

test("the helper's provider list and the widget's catalog are the same set", () => {
    const logic = fs.readFileSync(LOGIC, "utf8");
    const order = logic.match(/function providerOrder\(\)\s*\{\s*return \[([^\]]*)\]/);
    assert.ok(order, "AiUsageLogic must declare its provider order as a literal list");
    const widget = order[1].split(",").map(s => s.trim().replace(/^"|"$/g, "")).filter(Boolean);

    const module = fs.readFileSync(MODULE, "utf8");
    const declared = module.match(/^PROVIDERS = \(([^)]*)\)/m);
    assert.ok(declared, "the helper module must declare PROVIDERS as a literal tuple");
    const backend = declared[1].split(",").map(s => s.trim().replace(/^"|"$/g, "")).filter(Boolean);

    assert.deepEqual(backend.slice().sort(), widget.slice().sort(),
        "a provider the widget lists but the helper does not know answers 'unknown provider' on " +
        "every poll, and one the helper knows but the widget does not is unreachable — the two " +
        "lists are one contract");
});

test("a key is read from stdin, never from argv", () => {
    const helper = fs.readFileSync(path.join(repoRoot, "bin", "vshell-helper"), "utf8");
    const admin = helper.slice(helper.indexOf("def _ai_usage_admin("), helper.indexOf("def cmd_ai_usage("));
    assert.ok(admin.includes("sys.stdin.readline()"),
        "set-key must read the key from stdin: an argv key is readable from /proc by every " +
        "process on the machine for as long as the helper runs");
    assert.ok(!/add_argument\(\s*"--key"/.test(admin),
        "and there must be no --key argument for anything to pass one on");

    const module = fs.readFileSync(MODULE, "utf8");
    assert.ok(module.includes('"Authorization": "Bearer " + key'),
        "the key reaches exactly one place: the Authorization header");
    const uses = (module.match(/entry\["key"\]/g) || []).length;
    const requests = (module.match(/_request\([^)]*entry\["key"\]/g) || []).length;
    const resolved = (module.match(/"key": entry\["key"\]/g) || []).length;
    assert.equal(uses, requests + resolved,
        "and a stored key is read only to build the resolved credential or to make a request " +
        "with it — every other use is a way for it to reach a payload");
});

test("a stored key round-trips as a source label and never as a value", () => {
    const saved = run(["set-key", "vercel", "--label", "Test Team", "--key-id", "abc123"], "vck_secret_value\n");
    assert.equal(saved.ok, true, `saving a key must succeed: ${JSON.stringify(saved)}`);
    assert.equal(saved.id, "test-team", "whose id is derived from the label, never from the key");
    assert.ok(!JSON.stringify(saved).includes("vck_secret_value"), "and the reply carries no key");

    const sources = run(["sources", "vercel"]);
    assert.equal(sources.takesKey, true, "AI Gateway is configured with a key, not a login");
    assert.deepEqual(sources.accounts,
        [{ id: "test-team", label: "Test Team", source: "stored", hasKeyId: true }],
        "the setup page is told the source and the label, and nothing else about the key");
    assert.ok(!JSON.stringify(sources).includes("vck_secret_value"),
        "a key must never come back out of the helper — the page has no use for one and no way " +
        "to hold it safely");

    assert.equal(fs.statSync(storePath).mode & 0o777, 0o600,
        "the store holds a secret, so it is written 0600 — it is under ~/.local/state and not " +
        "under ~/.config for the same reason: operators symlink that into dotfiles repositories");
    assert.ok(fs.readFileSync(storePath, "utf8").includes("vck_secret_value"),
        "and the key really is what was saved, or the account would fail on every poll");
});

test("two keys with the same name are two accounts", () => {
    const second = run(["set-key", "vercel", "--label", "Test Team"], "vck_second\n");
    assert.equal(second.id, "test-team-2",
        "a reused label must not overwrite the entry that already has it: a person running two " +
        "teams names both of them after the same thing");
    const sources = run(["sources", "vercel"]);
    assert.equal(sources.accounts.length, 2, "so both are stored, and both become account cards");
});

test("only a key VGS stores can be removed through VGS", () => {
    assert.equal(run(["clear-key", "vercel", "test-team-2"]).ok, true, "a stored key is removable");
    const gone = run(["clear-key", "vercel", "test-team-2"]);
    assert.equal(gone.ok, false,
        "removing it twice must not report a second removal: the page would say the key is gone " +
        "while the helper went on reading whatever else answers for it");
    assert.equal(run(["clear-key", "vercel", "env"]).ok, false,
        "and a key provisioned outside VGS is not VGS's to delete either");
    assert.equal(run(["clear-key", "claude", "anything"]).ok, false,
        "nor is a key claimed for a provider that is found by its login instead");
});

test("an extra config directory is validated before it is stored", () => {
    assert.equal(run(["add-dir", "claude", path.join(home, "nope")]).ok, false,
        "a path that is not a directory is refused where the user can still see the field they " +
        "typed it into, rather than silently producing no account");
    assert.equal(run(["add-dir", "vercel", home]).ok, false,
        "and a provider with no config directories does not take one");

    const alt = path.join(home, ".claude-work");
    fs.mkdirSync(alt);
    assert.equal(run(["add-dir", "claude", alt]).ok, true);
    const listed = run(["sources", "claude"]).dirs.filter(d => d.managed === "extra");
    assert.deepEqual(listed.map(d => d.path), [alt], "and it is reported as the user's, so it can be removed");
    assert.equal(listed[0].usable, false,
        "a directory holding no login says so rather than being dropped: 'I added it and nothing " +
        "happened' is the only other thing the page could show");

    assert.equal(run(["remove-dir", "claude", alt]).ok, true);
    assert.deepEqual(run(["sources", "claude"]).dirs.filter(d => d.managed === "extra"), []);
    assert.equal(run(["remove-dir", "claude", alt]).ok, false,
        "and removing what is not there is not a removal");
});

test("a provider with no key answers configured:false, stamped, rather than as a fault", () => {
    // Every stored key was removed by the cases above; the environment ones are unset per call.
    assert.equal(run(["clear-key", "vercel", "test-team"]).ok, true);
    const payload = run(["vercel"]);
    assert.equal(payload.ok, false, "there is no usage to report");
    assert.equal(payload.configured, false,
        "but the reason is that nobody set it up, which is what keeps it off the bar instead of " +
        "showing a permanent error mark for a provider the user never asked for");
    assert.equal(payload.provider, "vercel", "and it is stamped, or the widget discards it");
    assert.deepEqual(payload.accounts, [], "with no account to render as broken");
});

test("an unknown provider and a malformed subcommand are answered, not crashed", () => {
    const unknown = run(["sources", "gemini"]);
    assert.equal(unknown.ok, false, "an unknown provider is reported");
    assert.ok(unknown.error.includes("gemini"), "by name");
    for (const args of [["clear-key", "vercel"], ["add-dir", "claude"], ["remove-dir", "claude"]]) {
        assert.equal(run(args).ok, false, `${args.join(" ")} without its argument is answered, not crashed`);
    }
});
