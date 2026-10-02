#!/usr/bin/env node
// Runs the real setup flow in J09 on a private pseudo-terminal. No browser runs.
"use strict";
const { assert, fs, path, tree, world, mutant } = require("./fixtures/jarvis/policy.js");
const { standins, mode, calls } = require("./fixtures/jarvis/browser.js");
const cp = require("node:child_process");
world(async () => {
    const root = process.argv[3] || tree;
    const plugin = path.join(root, "shell/plugins/vgs.jarvis");
    const setup = folder => cp.spawnSync("python3", [path.join(tree, "scripts/fixtures/jarvis/accounts-tui.py"),
        path.join(folder, "tui/setup-browser.sh"), path.join(tree, "bin/lib/tui.sh"), folder], {
        env: { PATH: process.env.PATH, HOME: process.env.HOME, XDG_CONFIG_HOME: process.env.XDG_CONFIG_HOME,
            XDG_STATE_HOME: process.env.XDG_STATE_HOME, XDG_DATA_HOME: process.env.XDG_DATA_HOME,
            XDG_RUNTIME_DIR: process.env.XDG_RUNTIME_DIR, DBUS_SESSION_BUS_ADDRESS: process.env.DBUS_SESSION_BUS_ADDRESS },
        encoding: "utf8", timeout: 15000 });
    const marker = path.join(process.env.XDG_DATA_HOME, "vgs/jarvis/browser-ready.json");
    function check(folder, name, fixture, expected, installs) {
        mode(fixture);
        fs.rmSync(marker, { force: true });
        const result = setup(folder);
        assert.equal(result.error, undefined);
        assert.equal(result.status, expected, name + ": " + result.stdout + result.stderr);
        assert.equal(calls().filter(row => row.args[0] === "install").length, installs, name);
        assert.equal(fs.existsSync(marker), expected === 0, name + " verifies before ready");
        for (const row of calls()) {
            assert.equal(row.env.OPENAI_API_KEY, undefined);
            assert.equal(row.env.VGSH_RUNNER_PID, undefined);
            assert.equal(row.args.includes("--with-deps"), false);
            if (row.args.includes("open")) assert.equal(row.args.at(-1), "about:blank");
        }
    }
    const cases = [
        ["installed", {}, 0, 0],
        ["download", { missing: true }, 0, 1],
        ["declined", { missing: true, confirmExit: 1 }, 130, 0],
        ["install-failed", { missing: true, installExit: 1 }, 1, 1],
        ["verify-failed", { verifyUrl: "https://unexpected.test/" }, 1, 0],
        ["unrelated-failure", { fail: true }, 1, 0],
        ["old-version", { version: "0.37.9" }, 1, 0]
    ];
    for (const row of cases) check(plugin, ...row);
    // The installed stub is consumed by the real module, not merely inventoried.
    mode({});
    const Browser = require(path.join(plugin, "backend/Browser.js"));
    const owner = Browser.create({ environment: process.env });
    assert.match(owner.guidance(), /fixture installed core guide/);
    owner.close();
    let controls = 0;
    function scriptControl(name, needle, replacement, row) {
        const copy = fs.mkdtempSync(path.join(process.env.JARVIS_TEST_ROOT, "browser-tui-mutant-"));
        try {
            fs.cpSync(plugin, copy, { recursive: true });
            const script = path.join(copy, "tui/setup-browser.sh");
            const source = fs.readFileSync(script, "utf8");
            assert.equal(source.split(needle).length - 1, 1, name + " matches");
            const changed = source.replace(needle, replacement);
            assert.notEqual(source, changed); fs.writeFileSync(script, changed);
            assert.throws(() => check(copy, ...row), assert.AssertionError, name + " must turn red");
            controls++;
        } finally { fs.rmSync(copy, { recursive: true, force: true }); }
    }
    scriptControl("download-consent", 'vgs_tui_confirm "Download a private Chrome browser for Jarvis?" || exit 130',
        'true "Download a private Chrome browser for Jarvis?" || exit 130', cases.find(row => row[0] === "declined"));
    scriptControl("verify-after-download", '    node "$program" verify', '    true "$program" verify', cases.find(row => row[0] === "download"));
    scriptControl("download-error", '    node "$program" download', '    node "$program" download || true', cases.find(row => row[0] === "install-failed"));
    scriptControl("only-missing-browser", '  69)', '  1|69)', cases.find(row => row[0] === "unrelated-failure"));
    await mutant(path.join(plugin, "backend/Browser.js"), "skill-cache", 'if (skill === null) {', 'if (true) {', (implementation, folder) => {
        fs.cpSync(path.join(plugin, "backend/skills"), path.join(folder, "skills"), { recursive: true });
        mode({}); const candidate = implementation.create({ environment: process.env });
        try {
            candidate.guidance(); candidate.guidance();
            assert.equal(calls().filter(row => row.args[0] === "skills").length, 1);
        } finally { candidate.close(); }
    }); controls++;
    console.log("test-jarvis-browser-setup: ok cases=" + cases.length + " controls=" + controls);
}, standins);
