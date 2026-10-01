#!/usr/bin/env node
"use strict";
const { assert, fs, path, cp, tree, environment, world, mutant } = require("./fixtures/jarvis/accounts-world.js");
const plugin = path.join(tree, "shell/plugins/vgs.jarvis");

world(async () => {
    const env = environment();
    const hand = path.join(env.HOME, "manual-account");
    fs.mkdirSync(hand);
    const queue = choices => fs.writeFileSync(path.join(env.XDG_STATE_HOME, "gum-queue"), JSON.stringify(choices));
    const run = folder => cp.spawnSync("python3", [path.join(tree, "scripts/fixtures/jarvis/accounts-tui.py"),
        path.join(folder, "tui/accounts.sh"), path.join(tree, "bin/lib/tui.sh"), folder], {
        env, encoding: "utf8", timeout: 20000 });
    const check = folder => {
        queue(["Add directory", "claude", hand, "my-account", "Use keyring item", "first", "openai", "my-key",
            "Show accounts", "Verify", "first", "", "yes", "Close"]);
        const result = run(folder);
        assert.equal(result.error, undefined);
        assert.equal(result.status, 0, result.stdout + result.stderr);
        const accountFile = path.join(env.XDG_STATE_HOME, "vgs/jarvis/accounts.json");
        const keyFile = path.join(env.XDG_STATE_HOME, "vgs/jarvis/keys.json");
        assert.deepEqual(JSON.parse(fs.readFileSync(accountFile)), [{ provider: "claude", directory: hand, label: "my-account" }]);
        assert.deepEqual(JSON.parse(fs.readFileSync(keyFile)), [{ provider: "openai", account: "my-key", origin: "https://api.openai.com",
            attributes: { application: "other-tool", id: "api-key" } }]);
        assert.match(result.stdout, /"reason":"subscription-handoff-unavailable"/);
        assert.match(result.stdout, /my-account/);
        assert.equal((result.stdout + result.stderr).includes("fixture-secret-private"), false);
        for (const file of ["cli-calls", "port-calls", "bus-calls", "gum-calls"]) {
            const records = fs.readFileSync(path.join(env.XDG_STATE_HOME, file), "utf8").trim().split("\n").map(JSON.parse);
            for (const record of records) {
                assert.equal(record.env.OPENAI_API_KEY, undefined);
                assert.equal(record.env.VGSH_RUNNER_PID, undefined);
                assert.ok(record.args.every(arg => arg !== "-p" && arg !== "exec"), "no inference during discovery or unavailable Verify");
            }
        }
        assert.equal(fs.existsSync(path.join(env.XDG_STATE_HOME, "secret-calls")), false);
    };
    check(plugin);
    await mutant("tui/accounts.sh", "tui-wrong-directory", 'accounts add "$selected" "$dir" "$label"',
        'accounts add "$selected" "$HOME" "$label"', folder => check(folder));
    await mutant("tui/accounts.sh", "tui-no-explicit-verify", 'accounts verify "${selected%% | *}" user',
        'accounts verify "${selected%% | *}" automatic', folder => check(folder));
    queue(["Verify", "first", "", "no", "Close"]);
    const cancelled = run(plugin);
    assert.equal(cancelled.status, 0);
    assert.doesNotMatch(cancelled.stdout, /subscription-handoff-unavailable/);
    console.log("test-jarvis-accounts-tui: ok controls=2");
});
