#!/usr/bin/env node
// Real filesystem metadata in a synthetic HOME, including absent targets.
"use strict";
const { assert, fs, path, tree, world, seed, mutant, fsFault } = require("./fixtures/jarvis/policy.js");
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
        ...[".ssh", ".gnupg", ".claude", ".codex", ".gemini", ".copilot", ".agent-browser", ".mozilla", ".pki", ".netrc", ".git-credentials",
            ".aws", ".azure", ".kube", ".docker/config.json", ".npmrc", ".pypirc", ".cargo/credentials.toml", ".cargo/credentials"].map(name => path.join(home, name)),
        ...["gh", "git/credentials", "claude", "codex", "gemini", "copilot", "opencode", "kwalletd", "chromium", "google-chrome", "BraveSoftware", "microsoft-edge", "vivaldi", "mozilla", "vgs",
            "gcloud", "rclone"].map(name => path.join(roots.config, name)),
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
    const gitCredentials = path.join(xdg.config, "git/credentials");
    fs.mkdirSync(path.dirname(gitCredentials));
    fs.writeFileSync(gitCredentials, "synthetic git credentials: never opened\n");
    const gitAlias = path.join(project, "git-credentials");
    fs.symlinkSync(gitCredentials, gitAlias);
    const xdgJudge = Denied.create(xdg);
    for (const target of [gitCredentials, gitAlias])
        for (const role of ["read", "write"])
            refused(xdgJudge, target, role, "protected-path");
    assert.equal(xdgJudge.masks.includes(gitCredentials), true);
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

    // The account name rule: a .claude* or .codex* entry one or two levels
    // below HOME, the config home or the data home, judged by name alone.
    // J09's config and data homes lie outside HOME, where the rule still
    // answers protected-path before outside-home.
    const ruleBases = { home, config: roots.config, data: roots.data };
    const ruleCases = Object.entries(ruleBases).flatMap(([base, root]) => [
        [base + "-depth-1", path.join(root, ".claude-" + base, "file"), "protected-path"],
        [base + "-depth-2", path.join(root, "group-" + base, ".codex-" + base, "file"), "protected-path"],
        [base + "-depth-3", path.join(root, "deep-" + base, "inner", ".claude-" + base, "file"),
            base === "home" ? null : "outside-home"]
    ]);
    const ruleJudge = Denied.create(options);
    // Masks are taken when first read; judgments never read them.
    void ruleJudge.masks;
    for (const [, target, reason] of ruleCases) {
        if (reason === null) allowed(ruleJudge, target, "read", target, false);
        else refused(ruleJudge, target, "read", reason);
    }
    // Created after the snapshot, and so absent from its masks, still refused.
    const late = path.join(home, "late", ".claude-late");
    fs.mkdirSync(late, { recursive: true });
    refused(ruleJudge, path.join(late, "file"), "read", "protected-path");
    assert.equal(ruleJudge.masks.includes(late), false);
    // So is a path through a rule-named link created after it.
    const lateTarget = path.join(project, "late-target");
    fs.mkdirSync(lateTarget);
    const lateLink = path.join(home, ".claude-late-link");
    fs.symlinkSync(lateTarget, lateLink);
    refused(ruleJudge, path.join(lateLink, "file"), "read", "protected-path");
    // A configured alias of a rule-named directory, and a rule-named link.
    const namedAccount = path.join(home, ".claude-work");
    fs.mkdirSync(namedAccount);
    const namedAlias = path.join(project, "work-alias");
    fs.symlinkSync(namedAccount, namedAlias);
    const linkTarget = path.join(project, "link-target");
    fs.mkdirSync(linkTarget);
    const namedLink = path.join(home, ".codex-linked");
    fs.symlinkSync(linkTarget, namedLink);
    const nestedNamed = path.join(home, "holder", ".codex-nested");
    fs.mkdirSync(nestedNamed, { recursive: true });
    const linkJudge = Denied.create(options);
    refused(linkJudge, path.join(namedAlias, "file"), "read", "protected-path");
    refused(linkJudge, path.join(namedLink, "file"), "read", "protected-path");
    // Masks hold the present matches, configured and resolved, never deeper.
    for (const present of [namedAccount, namedLink, linkTarget, nestedNamed, late])
        assert.equal(linkJudge.masks.includes(present), true, present + " masked");
    // The scan for masks reads names only and never enters a link.
    const outsideNamed = path.join(process.env.JARVIS_TEST_ROOT, "outside-accounts", ".claude-outside");
    fs.mkdirSync(outsideNamed, { recursive: true });
    const scanLink = path.join(home, "scan-link");
    fs.symlinkSync(path.dirname(outsideNamed), scanLink);
    assert.equal(linkJudge.masks.some(root => root.startsWith(scanLink + "/")), false);
    const tooDeep = path.join(home, "deep-home", "inner", ".claude-home");
    fs.mkdirSync(tooDeep, { recursive: true });
    assert.equal(Denied.create(options).masks.includes(tooDeep), false);
    // A changing or recursive role refuses a folder one level below a base
    // that holds a rule-named entry; a plain read may still list it.
    const holder = path.join(home, "holder");
    for (const role of ["tree-read", "write", "move", "remove", "workspace"])
        refused(linkJudge, holder, role, "protected-path");
    allowed(linkJudge, holder, "read");
    // That read happens at judgment, so a match made after the snapshot counts.
    const laterHolder = path.join(home, "later-holder");
    fs.mkdirSync(path.join(laterHolder, ".claude-later"), { recursive: true });
    refused(linkJudge, laterHolder, "remove", "protected-path");
    assert.equal(linkJudge.masks.includes(path.join(laterHolder, ".claude-later")), false);
    const plain = path.join(home, "plain");
    fs.mkdirSync(path.join(plain, "inner"), { recursive: true });
    allowed(linkJudge, plain, "remove");
    // A judgment reads at most the one folder its target is; the mask
    // inventory's two-level scan runs only when masks are read.
    const readdirs = check => {
        let count = 0;
        fsFault("readdirSync", (original, ...args) => { count++; return original(...args); }, check);
        return count;
    };
    const lazyMasks = logic => {
        let judge;
        assert.equal(readdirs(() => { judge = logic.create(options); }), 0, "a build lists no folder");
        assert.equal(readdirs(() => allowed(judge, path.join(project, "existing"), "read")), 3,
            "the first judgment lists the three bases' own entries alone");
        assert.equal(readdirs(() => allowed(judge, path.join(project, "existing"), "read")), 0, "later judgments reuse them");
        assert.equal(readdirs(() => allowed(judge, plain, "remove")), 1, "a one-level target lists itself alone");
        assert.ok(readdirs(() => void judge.masks) > 1, "the masks scan the bases");
    };
    lazyMasks(Denied);
    // An ordinary home builds a snapshot: a folder one level down that
    // cannot be listed is left to the name rule, and a dangling or looping
    // rule-named link is masked by its own path.
    const unlisted = path.join(home, "unlisted");
    fs.mkdirSync(unlisted);
    const unlistable = logic => fsFault("readdirSync", (original, target, ...args) => {
        if (target === unlisted) throw Object.assign(new Error("denied"), { code: "EACCES" });
        return original(target, ...args);
    }, () => {
        const judge = logic.create(options);
        assert.doesNotThrow(() => judge.masks, "an unlistable folder leaves the masks buildable");
        assert.equal(judge.masks.includes(namedAccount), true);
        refused(judge, path.join(unlisted, ".claude-hidden", "x"), "read", "protected-path");
        refused(judge, unlisted, "remove", "path-resolution");
    });
    unlistable(Denied);
    const goneLink = path.join(home, ".claude-gone");
    fs.symlinkSync(path.join(home, "never-there"), goneLink);
    const loopLink = path.join(home, "holder", ".codex-loop");
    fs.symlinkSync(loopLink, loopLink);
    const brokenLinks = logic => {
        const judge = logic.create(options);
        let masks;
        assert.doesNotThrow(() => { masks = judge.masks; }, "a broken rule-named link leaves the masks buildable");
        for (const link of [goneLink, loopLink]) {
            assert.equal(masks.includes(link), true, link + " masked by its own path");
            refused(judge, path.join(link, "x"), "read", "path-resolution");
            refused(judge, link, "remove", "protected-path");
        }
    };
    brokenLinks(Denied);
    // A rule-named link directly in a base protects its resolved target, as
    // a dotfile manager's ~/.claude-work link to ~/dotfiles/claude-work.
    const dotfiles = path.join(home, "dotfiles", "claude-work");
    fs.mkdirSync(dotfiles, { recursive: true });
    fs.writeFileSync(path.join(dotfiles, ".credentials.json"), "synthetic credentials: never opened\n");
    fs.symlinkSync(dotfiles, path.join(home, ".claude-dotfiles"));
    const linkedTarget = logic => {
        const judge = logic.create(options);
        refused(judge, path.join(dotfiles, ".credentials.json"), "read", "protected-path");
        refused(judge, path.dirname(dotfiles), "remove", "protected-path");
    };
    linkedTarget(Denied);
    // A base that cannot be listed refuses every judgment rather than guess.
    fsFault("readdirSync", (original, target, ...args) => {
        if (target === home) throw Object.assign(new Error("denied"), { code: "EACCES" });
        return original(target, ...args);
    }, () => refused(Denied.create(options), path.join(project, "existing"), "read", "path-resolution"));
    // A middle link is resolved for a removal; only a final one is not.
    refused(linkJudge, path.join(alias, "x"), "remove", "protected-path");
    // A move is judged where it lands, against each write destination.
    const carrier = path.join(project, "carrier");
    fs.mkdirSync(path.join(carrier, ".claude-carried"), { recursive: true });
    const lands = logic => {
        const judge = logic.create(options);
        assert.equal(judge.inspectPaths([[carrier, "move"], [path.join(home, "carried"), "write"]]).reason, "protected-path",
            "its account entry would land two levels below HOME");
        assert.deepEqual(judge.inspectPaths([[carrier, "move"], [path.join(home, "carried"), "write"]]).file, carrier);
        assert.equal(judge.inspectPaths([[carrier, "move"], [path.join(project, "carried"), "write"]]).kind, "paths",
            "three levels down the entry stays outside the rule");
    };
    lands(Denied);
    // A removal or a move source is the named entry: a link to a protected
    // root is removed as the link, and a dangling link exists as one.
    const credentialLink = path.join(project, "ssh-link");
    fs.symlinkSync(ssh, credentialLink);
    for (const role of ["remove", "move"]) {
        allowed(linkJudge, credentialLink, role);
        allowed(linkJudge, dangling, role);
    }
    refused(linkJudge, credentialLink, "read", "protected-path");

    let controls = 0;
    function control(name, needle, replacement, check) {
        mutant(file, name, needle, replacement, check);
        controls++;
    }
    control("descendants", 'within(target.path, root)\n', 'false\n',
        logic => refused(logic.create(options), path.join(ssh, "sentinel"), "read", "protected-path"));
    control("ancestors", '(ancestor && within(root, target.path))',
        '(false && ancestor && within(root, target.path))',
        logic => refused(logic.create(options), roots.config, "remove", "protected-path"));
    control("recursive-read", 'changes || role === "tree-read"', 'changes',
        logic => refused(logic.create(options), home, "tree-read", "protected-path"));
    control("home", 'if (!within(target.path, realHome.path))', 'if (false && !within(target.path, realHome.path))',
        logic => refused(logic.create(options), path.join(escape, "missing"), "write", "outside-home"));
    control("component", 'file.startsWith(root === "/" ? "/" : root + "/")', 'file.startsWith(root)',
        logic => allowed(logic.create(options), boundary, "read"));
    control("link-resolution", 'stat.isSymbolicLink() && (follow || !last) ? fs.realpathSync.native(next) : next', 'next',
        logic => refused(logic.create(options), path.join(alias, "sentinel"), "read", "protected-path"));
    control("root-alias", 'files.flatMap(file => [file, resolve(file).path])', 'files.flatMap(file => [file])',
        logic => refused(logic.create({ ...roots, accountRoots: [accountAlias] }), path.join(realAccount, "absent"), "read", "protected-path"));
    control("sandbox-masks", "masks = Object.freeze([...new Set(protectedRoots.concat(accounts))]);", "masks = Object.freeze(accounts);",
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
    control("directory-parent", 'if (!last && !fs.statSync(real).isDirectory())',
        'if (false && !last && !fs.statSync(real).isDirectory())',
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
    const ruleCase = name => ruleCases.find(row => row[0] === name);
    const ruleRefused = (logic, name) => refused(logic.create(options), ruleCase(name)[1], "read", "protected-path");
    control("account-rule", "if (target.trail.concat(target.path).some(named) || protectedRoots",
        "if (false || protectedRoots", logic => ruleRefused(logic, "home-depth-1"));
    control("account-trail", "target.trail.concat(target.path).some(named)", "[target.path].some(named)", logic => {
        const judge = logic.create(options);
        // Its first judgment reads the bases before the link exists.
        allowed(judge, path.join(project, "existing"), "read");
        const after = path.join(home, ".claude-after");
        fs.symlinkSync(plain, after);
        try { refused(judge, path.join(after, "file"), "read", "protected-path"); }
        finally { fs.unlinkSync(after); }
    });
    // The shared rule's depth, read by this judge.
    const providers = path.join(tree, "shell/plugins/vgs.jarvis/AccountProviders.js");
    for (const [name, replacement, check] of [
        ["account-depth", "if (depth < 1 || depth > 1) return null;", logic => ruleRefused(logic, "home-depth-2")],
        ["account-depth-limit", "if (depth < 1) return null;",
            logic => allowed(logic.create(options), ruleCase("home-depth-3")[1], "read", ruleCase("home-depth-3")[1], false)]
    ]) {
        mutant(providers, name, "if (depth < 1 || depth > ACCOUNT_DEPTH) return null;", replacement, check, "Denied.js");
        controls++;
    }
    for (const base of ["config", "data"])
        control("account-base-" + base, `resolve(${base}).path`, "realHome.path", logic => ruleRefused(logic, base + "-depth-2"));
    control("account-ancestor", "if (ancestor && target.exists && holdsNamed(target.path))",
        "if (false && ancestor && target.exists && holdsNamed(target.path))", logic => {
            const judge = logic.create(options);
            const fresh = path.join(home, "fresh-holder");
            fs.mkdirSync(path.join(fresh, ".codex-fresh"), { recursive: true });
            try { refused(judge, fresh, "remove", "protected-path"); }
            finally { fs.rmSync(fresh, { recursive: true }); }
        });
    control("account-masks", "masks = Object.freeze([...new Set(protectedRoots.concat(accounts))]);",
        "masks = Object.freeze([...new Set(protectedRoots)]);",
        logic => assert.equal(logic.create(options).masks.includes(namedAccount), true));
    control("account-mask-links", "else if (depth < ACCOUNT_DEPTH && entry.isDirectory())",
        "else if (depth < ACCOUNT_DEPTH && (entry.isDirectory() || (entry.isSymbolicLink() && fs.statSync(file).isDirectory())))",
        logic => assert.equal(logic.create(options).masks.some(root => root.startsWith(scanLink + "/")), false));
    control("account-link-target", "if (accountLinkTargets().some(", "if (false && accountLinkTargets().some(", linkedTarget);
    control("lazy-masks", "let masks = null;", "let masks = null; void bases.flatMap(base => present(base, 1, [], true));", lazyMasks);
    control("unlisted-skip", 'if (error.code === "ENOENT" || skipUnlisted) return found;', 'if (error.code === "ENOENT") return found;', unlistable);
    control("broken-link-mask", "try { return [file, resolve(file).path]; } catch { return [file]; }", "return [file, resolve(file).path];", brokenLinks);
    control("middle-link-removal", "stat.isSymbolicLink() && (follow || !last)", "stat.isSymbolicLink() && follow",
        logic => refused(logic.create(options), path.join(alias, "x"), "remove", "protected-path"));
    control("move-landing", "if (landsNamed(source.path, destination.path))", "if (false && landsNamed(source.path, destination.path))", lands);
    control("entry", 'resolve(file, role !== "move" && role !== "remove")', "resolve(file)",
        logic => allowed(logic.create(options), credentialLink, "remove"));
    // Every inventory entry has its own planted missing protection. This also
    // proves the built-in credential/VGS table, not only dynamic account roots.
    const inventory = [
        [home, ".ssh"], [home, ".gnupg"], [home, ".claude"], [home, ".codex"],
        [home, ".gemini"], [home, ".copilot"], [home, ".agent-browser"], [home, ".mozilla"],
        [home, ".pki"], [home, ".netrc"], [home, ".git-credentials"],
        ...[".aws", ".azure", ".kube", ".docker/config.json", ".npmrc", ".pypirc", ".cargo/credentials.toml", ".cargo/credentials"].map(name => [home, name]),
        ...["gh", "git/credentials", "claude", "codex", "gemini", "copilot", "opencode", "kwalletd", "chromium", "google-chrome", "BraveSoftware", "microsoft-edge", "vivaldi", "mozilla",
            "gcloud", "rclone"].map(name => [roots.config, name]),
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
            logic => {
                const judge = logic.create(localOptions);
                for (const role of ["read", "write"])
                    refused(judge, path.join(value, name), role, "protected-path");
                assert.equal(judge.masks.includes(path.join(value, name)), true);
            });
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
