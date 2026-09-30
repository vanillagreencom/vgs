#!/usr/bin/env node
// Real filesystem metadata in a synthetic HOME, including absent targets.
"use strict";
const { assert, fs, path, tree, world, seed, mutant } = require("./fixtures/jarvis/policy.js");
const file = path.join(tree, "shell/plugins/vgs.jarvis/backend/Denied.js");
const Denied = require(file);

world(() => {
    const { home, project, roots } = seed();
    const account = path.join(home, "accounts", "work");
    fs.mkdirSync(account, { recursive: true });
    const options = { ...roots, accountRoots: [account] };
    const denied = Denied.create(options);
    const refused = (judge, file, role, reason) => assert.equal(judge.inspect(file, role).reason, reason, file + " " + role);
    const allowed = (judge, file, role, canonical = file, exists = true, execution = false) =>
        assert.deepEqual(judge.inspect(file, role), { kind: "path", path: canonical, exists, execution });
    const protectedPaths = [
        ...[".ssh", ".gnupg", ".claude", ".codex", ".gemini", ".copilot", ".agent-browser", ".mozilla", ".pki", ".netrc", ".git-credentials"].map(name => path.join(home, name)),
        ...["gh", "claude", "codex", "gemini", "copilot", "opencode", "kwalletd", "chromium", "google-chrome", "BraveSoftware", "microsoft-edge", "vivaldi", "mozilla", "vgs"].map(name => path.join(roots.config, name)),
        ...["opencode", "keyrings", "kwalletd", "vgs"].map(name => path.join(roots.data, name)),
        path.join(roots.state, "vgs"), path.join(roots.runtime, "vgs"), roots.install, account
    ];
    for (const target of protectedPaths) {
        for (const role of ["read", "tree-read", "write", "move", "remove", "workspace"])
            refused(denied, path.join(target, "absent"), role, "protected-path");
        refused(denied, target, "read", "protected-path");
    }
    const ssh = path.join(home, ".ssh");
    fs.mkdirSync(ssh);
    fs.writeFileSync(path.join(ssh, "sentinel"), "synthetic credentials: never opened\n");
    const alias = path.join(project, "alias");
    fs.symlinkSync(ssh, alias);
    for (const role of ["read", "write"])
        refused(denied, path.join(alias, "sentinel"), role, "protected-path");
    refused(denied, path.join(alias, "missing", "child"), "write", "protected-path");
    // A configured account alias protects its real target, not just its label.
    const realAccount = path.join(home, "real-account");
    fs.mkdirSync(realAccount);
    const accountAlias = path.join(home, "selected-account");
    fs.symlinkSync(realAccount, accountAlias);
    const aliasJudge = Denied.create({ ...roots, accountRoots: [accountAlias] });
    refused(aliasJudge, path.join(realAccount, "absent"), "read", "protected-path");
    assert.equal(Object.isFrozen(aliasJudge.masks), true);
    assert.equal(aliasJudge.masks.includes(accountAlias), true);
    assert.equal(aliasJudge.masks.includes(realAccount), true);
    assert.equal(denied.masks.includes(path.join(roots.state, "vgs")), true);
    for (const role of ["write", "move", "remove", "workspace", "tree-read"])
        refused(denied, home, role, "protected-path");
    // One-level list names are permitted. Each opened child needs its own check.
    allowed(denied, home, "read");
    const boundary = path.join(home, ".ssh-backup");
    fs.mkdirSync(boundary);
    allowed(denied, boundary, "read");
    const ordinary = path.join(project, "new", "nested", "file");
    allowed(denied, ordinary, "write", ordinary, false);
    allowed(denied, path.join(project, "existing"), "write");
    const outside = path.join(process.env.JARVIS_TEST_ROOT, "outside");
    fs.mkdirSync(outside);
    const escape = path.join(project, "escape");
    fs.symlinkSync(outside, escape);
    refused(denied, path.join(escape, "missing"), "write", "outside-home");
    refused(denied, outside, "read", "outside-home");
    const folder = path.join(project, "child");
    fs.mkdirSync(folder);
    const link = path.join(home, "link");
    fs.symlinkSync(folder, link);
    allowed(denied, link + "/../existing", "read", path.join(project, "existing"));
    const dangling = path.join(project, "dangling");
    fs.symlinkSync(path.join(home, "absent"), dangling);
    refused(denied, dangling, "write", "path-resolution");
    refused(denied, path.join(project, "existing", "child"), "read", "path-resolution");
    refused(denied, path.join(project, "existing") + "/../existing", "read", "path-resolution");
    const loop = path.join(project, "loop");
    fs.symlinkSync(loop, loop);
    refused(denied, loop, "read", "path-resolution");
    refused(denied, path.join(project, "absent") + "/../existing", "write", "path-resolution");
    const long = path.join(project, "x".repeat(300));
    refused(denied, long, "write", "path-resolution");
    refused(denied, "relative", "read", "path-resolution");
    refused(denied, ordinary, "invalid", "path-role");
    const executionPaths = [
        ...[".profile", ".bash_profile", ".bash_login", ".bashrc", ".zprofile", ".zshrc", ".zshenv", ".xprofile", ".local/bin"].map(name => path.join(home, name)),
        ...["fish", "autostart", "systemd/user", "hypr"].map(name => path.join(roots.config, name)),
        path.join(roots.data, "applications")
    ];
    // The J09 XDG dirs live outside HOME. These synthetic dirs let tests prove
    // execution classification within the user folder without host XDG access.
    const xdg = { ...options, config: path.join(home, ".config"), data: path.join(home, ".local/share") };
    fs.mkdirSync(xdg.config, { recursive: true });
    fs.mkdirSync(xdg.data, { recursive: true });
    const xdgJudge = Denied.create(xdg);
    const localExecution = [
        ...executionPaths.filter(target => target.startsWith(home + "/")),
        ...["fish", "autostart", "systemd/user", "hypr"].map(name => path.join(xdg.config, name)),
        path.join(xdg.data, "applications")
    ];
    for (const target of localExecution) {
        allowed(xdgJudge, target, "read", target, false);
        for (const role of ["write", "move", "remove", "workspace"])
            allowed(xdgJudge, target, role, target, false, true);
    }
    const executable = path.join(home, ".bashrc");
    const realExecutable = path.join(project, "profile-target");
    fs.writeFileSync(realExecutable, "synthetic shell profile\n");
    fs.symlinkSync(realExecutable, executable);
    const refreshed = Denied.create(xdg);
    allowed(refreshed, realExecutable, "write", realExecutable, true, true);
    const homeAlias = path.join(process.env.JARVIS_TEST_ROOT, "home-alias");
    fs.symlinkSync(home, homeAlias);
    const physicalHome = Denied.create({ ...options, home: homeAlias });
    allowed(physicalHome, path.join(project, "existing"), "read");
    assert.throws(() => Denied.create({ ...options, home: path.join(home, "missing-home") }), { message: "jarvis: paths=home" });
    assert.throws(() => Denied.create({ ...options, accountRoots: null }), { message: "jarvis: paths=account-roots" });
    assert.throws(() => Denied.create({ ...options, accountRoots: [dangling] }), /ENOENT/);

    let controls = 0;
    function control(name, needle, replacement, check) {
        mutant(file, name, needle, replacement, check);
        controls++;
    }
    control("descendants", 'within(target.path, root)\n', 'false\n',
        logic => refused(logic.create(options), path.join(ssh, "sentinel"), "read", "protected-path"));
    control("ancestors", '((changes || role === "tree-read") && within(root, target.path))',
        '(false && (changes || role === "tree-read") && within(root, target.path))',
        logic => refused(logic.create(options), home, "remove", "protected-path"));
    control("recursive-read", 'changes || role === "tree-read"', 'changes',
        logic => refused(logic.create(options), home, "tree-read", "protected-path"));
    control("home", 'if (!within(target.path, realHome.path))', 'if (false && !within(target.path, realHome.path))',
        logic => refused(logic.create(options), path.join(escape, "missing"), "write", "outside-home"));
    control("component", 'file.startsWith(root === "/" ? "/" : root + "/")', 'file.startsWith(root)',
        logic => allowed(logic.create(options), boundary, "read"));
    control("link-resolution", 'stat.isSymbolicLink() ? fs.realpathSync.native(next) : next', 'next',
        logic => refused(logic.create(options), path.join(alias, "sentinel"), "read", "protected-path"));
    control("root-alias", '[file, resolve(file).path]', '[file]',
        logic => refused(logic.create({ ...roots, accountRoots: [accountAlias] }), path.join(realAccount, "absent"), "read", "protected-path"));
    control("sandbox-masks", 'masks: Object.freeze([...new Set(protectedRoots)])', 'masks: Object.freeze([])',
        logic => assert.equal(logic.create(options).masks.includes(account), true));
    control("account-roots", '}).concat(accountRoots);', '}).concat([]);',
        logic => refused(logic.create(options), account, "read", "protected-path"));
    control("execution", 'const executionPath = changes && executionRoots.some', 'const executionPath = false && changes && executionRoots.some',
        logic => allowed(logic.create(xdg), realExecutable, "write", realExecutable, true, true));
    control("role", 'if (!["read", "tree-read", "write", "move", "remove", "workspace"].includes(role))',
        'if (false && !["read", "tree-read", "write", "move", "remove", "workspace"].includes(role))',
        logic => refused(logic.create(options), ordinary, "invalid", "path-role"));
    control("absence-only", 'if (error.code !== "ENOENT") throw error;', 'if (false && error.code !== "ENOENT") throw error;',
        logic => refused(logic.create(options), long, "write", "path-resolution"));
    control("missing-parent", 'if (!exists) throw new Error("jarvis: path=absent-parent");',
        'if (false && !exists) throw new Error("jarvis: path=absent-parent");',
        logic => refused(logic.create(options), path.join(project, "absent") + "/../existing", "write", "path-resolution"));
    control("directory-parent", 'if (i < parts.length - 1 && !fs.statSync(real).isDirectory())',
        'if (false && i < parts.length - 1 && !fs.statSync(real).isDirectory())',
        logic => refused(logic.create(options), path.join(project, "existing") + "/../existing", "read", "path-resolution"));
    control("absolute-root", 'if (typeof file !== "string" || !path.isAbsolute(file) || /[\\x00-\\x1f\\x7f]/.test(file))',
        'if (false && (typeof file !== "string" || !path.isAbsolute(file) || /[\\x00-\\x1f\\x7f]/.test(file)))',
        logic => assert.throws(() => logic.create({ ...options, home: "relative" }), { message: "jarvis: path=invalid" }));
    control("account-list", 'if (!Array.isArray(accountRoots))',
        'if (false && !Array.isArray(accountRoots))',
        logic => assert.throws(() => logic.create({ ...options, accountRoots: null }), { message: "jarvis: paths=account-roots" }));
    control("exists", 'exists = false;', 'exists = true;',
        logic => allowed(logic.create(options), path.join(project, "never-created"), "write", path.join(project, "never-created"), false));
    control("home-required", 'if (!realHome.exists || !fs.statSync(realHome.path).isDirectory())',
        'if (false && (!realHome.exists || !fs.statSync(realHome.path).isDirectory()))',
        logic => assert.throws(() => logic.create({ ...options, home: path.join(home, "missing-home") }), { message: "jarvis: paths=home" }));
    // Every inventory entry has its own planted missing protection. This also
    // proves the built-in credential/VGS table, not only dynamic account roots.
    const inventory = [
        [home, ".ssh"], [home, ".gnupg"], [home, ".claude"], [home, ".codex"],
        [home, ".gemini"], [home, ".copilot"], [home, ".agent-browser"], [home, ".mozilla"],
        [home, ".pki"], [home, ".netrc"], [home, ".git-credentials"],
        ...["gh", "claude", "codex", "gemini", "copilot", "opencode", "kwalletd", "chromium", "google-chrome", "BraveSoftware", "microsoft-edge", "vivaldi", "mozilla"].map(name => [roots.config, name]),
        ...["opencode", "keyrings", "kwalletd"].map(name => [roots.data, name])
    ];
    // Place XDG roots under HOME so a lost mask cannot fail at outside-home.
    const localOptions = { ...xdg, state: path.join(home, "state"), runtime: path.join(home, "run"), install: path.join(home, "install") };
    const bases = new Map([[home, "home"], [roots.config, "config"], [roots.data, "data"]]);
    for (const [base, name] of inventory) {
        const identifier = bases.get(base);
        const needle = `[${identifier}, "${name}"]`;
        const value = identifier === "home" ? home : localOptions[identifier];
        control("credential-" + identifier + "-" + name, needle, `[${identifier}, "${name}-unprotected"]`,
            logic => refused(logic.create(localOptions), path.join(value, name), "read", "protected-path"));
    }
    for (const base of ["config", "data", "state", "runtime"]) {
        const needle = `path.join(${base}, "vgs")`;
        control("vgs-" + base, needle, `path.join(${base}, "vgs-unprotected")`,
            logic => refused(logic.create(localOptions), path.join(localOptions[base], "vgs"), "read", "protected-path"));
    }
    control("vgs-install", 'path.join(runtime, "vgs"), install', 'path.join(runtime, "vgs"), install + "-unprotected"',
        logic => refused(logic.create(localOptions), localOptions.install, "read", "protected-path"));
    const executionInventory = [
        ...[".profile", ".bash_profile", ".bash_login", ".bashrc", ".zprofile", ".zshrc", ".zshenv", ".xprofile", ".local/bin"].map(name => ["home", name]),
        ...["fish", "autostart", "systemd/user", "hypr"].map(name => ["config", name]), ["data", "applications"]
    ];
    for (const [base, name] of executionInventory) {
        const target = path.join(localOptions[base], name);
        const exists = base === "home" && name === ".bashrc";
        const canonical = exists ? realExecutable : target;
        control("execution-" + name, `[${base}, "${name}"]`, `[${base}, "${name}-unprotected"]`,
            logic => allowed(logic.create(localOptions), target, "write", canonical, exists, true));
    }
    console.log("test-jarvis-denied: ok protected=" + protectedPaths.length + " execution=" + localExecution.length + " controls=" + controls);
});
