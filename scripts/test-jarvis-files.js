#!/usr/bin/env node
// The files executor against real scratch files in the J09 world, and one
// call each way through a disposable daemon's real router, Policy, audit
// and executor. No live session, real HOME, credential or network is used.
"use strict";
const { assert, fs, path, tree, world, seed, mutant, fsFault } = require("./fixtures/jarvis/policy.js");
const cp = require("node:child_process");
const { once } = require("node:events");
const plugin = path.join(tree, "shell/plugins/vgs.jarvis");
const backend = path.join(plugin, "backend");
const file = path.join(backend, "Files.js");
const Denied = require(path.join(backend, "Denied.js"));
const Tools = require(path.join(backend, "Tools.js"));

world(async () => {
    const { home, project, roots } = seed();
    const outside = path.join(process.env.JARVIS_TEST_ROOT, "outside");
    fs.mkdirSync(outside);
    fs.writeFileSync(path.join(outside, "secret"), "beta outside secret\n");
    const ssh = path.join(home, ".ssh");
    fs.mkdirSync(ssh);
    fs.writeFileSync(path.join(ssh, "id"), "beta protected secret\n");
    // An explicit CLAUDE_CONFIG_DIR and a hand-added root, through the
    // daemon's own roots entry.
    const explicitRoot = path.join(home, "explicit-claude");
    const handRoot = path.join(home, "hand-added");
    fs.mkdirSync(handRoot);
    const accountState = path.join(roots.state, "vgs", "jarvis");
    fs.mkdirSync(accountState, { recursive: true });
    fs.writeFileSync(path.join(accountState, "accounts.json"), JSON.stringify([{ provider: "claude", directory: handRoot, label: "hand" }]));
    const { accountRoots } = require(path.join(backend, "Accounts.js"));
    const options = { ...roots, accountRoots: accountRoots(accountState, { CLAUDE_CONFIG_DIR: explicitRoot }) };
    assert.deepEqual(options.accountRoots, [explicitRoot, handRoot]);
    const deniedPaths = [
        ["credential", path.join(ssh, "id")],
        ["vgs-config", path.join(roots.config, "vgs", "shell.json")],
        ["vgs-state", path.join(roots.state, "vgs", "jarvis", "audit")],
        ["install", path.join(roots.install, "VERSION")],
        ["home-depth-1", path.join(home, ".claude-team", "notes")],
        ["home-depth-2", path.join(home, "accounts", ".codex-work", "notes")],
        ["config-depth-1", path.join(roots.config, ".claude-cfg", "notes")],
        ["config-depth-2", path.join(roots.config, "group", ".codex-cfg", "notes")],
        ["data-depth-1", path.join(roots.data, ".codex-data", "notes")],
        ["data-depth-2", path.join(roots.data, "group", ".claude-data", "notes")],
        ["explicit", path.join(explicitRoot, "notes")],
        ["hand-added", path.join(handRoot, "notes")]
    ];
    for (const [, target] of deniedPaths) {
        fs.mkdirSync(path.dirname(target), { recursive: true });
        fs.writeFileSync(target, "beta protected secret\n");
    }
    let clockNow = 0;
    const clock = { now: () => clockNow };
    const BOUNDS = { listEntries: 16, readBytes: 64, writeBytes: 64, searchDepth: 2, searchEntries: 40,
        searchBytes: 400, searchMatches: 8, lineChars: 24, searchMs: 1000, deleteEntries: 8, deleteDepth: 3, slackMs: 100 };
    const fresh = () => Denied.create(options);

    // denied may wrap a snapshot to change the tree after its judge answers.
    function make(Files = require(file), denied = fresh, bounds = BOUNDS) {
        const files = Files.create({ denied, bounds, clock });
        const run = (id, args) => new Promise(resolve => {
            const refined = Tools.refine({ id, args });
            assert.equal(refined.kind, "call", id + " refines");
            files.records.files.start(refined.call, resolve);
        });
        return { files, run };
    }
    // Run act once after the executor's nth path judge answers, before it
    // opens anything: the tree changes between the judge and the act.
    function afterJudge(act, nth = 1) {
        let judged = 0;
        return () => {
            const snapshot = fresh();
            return { masks: snapshot.masks, inspect(target, role) {
                const verdict = snapshot.inspect(target, role);
                if (++judged === nth) act();
                return verdict;
            } };
        };
    }

    const t = path.join(project, "t");
    function plant() {
        fs.rmSync(t, { recursive: true, force: true });
        fs.mkdirSync(path.join(t, "sub", "inner", "deeper"), { recursive: true });
        fs.writeFileSync(path.join(t, "notes.txt"), "alpha\nBeta line\n");
        fs.writeFileSync(path.join(t, "beta-name.md"), "none\n");
        fs.writeFileSync(path.join(t, "sub", "deep.txt"), "beta deep\n");
        fs.writeFileSync(path.join(t, "sub", "inner", "deeper", "far.txt"), "beta far\n");
        fs.writeFileSync(path.join(t, "binary.bin"), Buffer.from("beta\0binary"));
        fs.writeFileSync(path.join(t, "big.txt"), "beta ".repeat(20));
        fs.writeFileSync(path.join(t, "secret"), "lexical sibling\n");
        fs.symlinkSync(outside, path.join(t, "link-out"));
        fs.symlinkSync(path.join(outside, "secret"), path.join(t, "link-file"));
        fs.symlinkSync(ssh, path.join(t, "link-ssh"));
        fs.symlinkSync(path.join(t, "absent"), path.join(t, "dangling"));
    }
    const read = target => fs.readFileSync(target, "utf8");
    const SECRET = /(outside|protected|late) secret/;
    const results = [];
    let cases = 0;
    async function expectRun(name, files, id, args, outcome, content, check) {
        const answer = await files.run(id, args);
        assert.equal(answer.outcome, outcome, name + ": " + answer.content);
        if (content instanceof RegExp) assert.match(answer.content, content, name);
        else if (content !== undefined) assert.equal(answer.content, content, name);
        assert.doesNotMatch(answer.content, SECRET, name + " shows no secret");
        if (check) await check(answer);
        results.push(name);
        cases++;
        return answer;
    }
    const files = make();

    // Happy paths with read-back.
    plant();
    await expectRun("list", files, "files.list", { path: t }, "completed",
        ["10 entries in " + t, 'file "beta-name.md" 5 bytes', 'file "big.txt" 100 bytes', 'file "binary.bin" 11 bytes',
            'link "dangling"', 'link "link-file"', 'link "link-out"', 'link "link-ssh"', 'file "notes.txt" 16 bytes',
            'file "secret" 16 bytes', 'directory "sub"'].join("\n"));
    await expectRun("read", files, "files.read", { path: path.join(t, "notes.txt") }, "completed", "alpha\nBeta line\n");
    await expectRun("write-new", files, "files.write", { path: path.join(t, "new.txt"), text: "fresh text" }, "completed",
        /^Wrote .*new\.txt\. Read back: 10 bytes, sha256 [0-9a-f]{16}, mode/,
        () => {
            assert.equal(read(path.join(t, "new.txt")), "fresh text");
            assert.deepEqual(fs.readdirSync(t).filter(name => name.startsWith(".jarvis-write-")), [], "no temporary file stays");
        });
    fs.chmodSync(path.join(t, "notes.txt"), 0o640);
    const keepsMode = () => {
        assert.equal(read(path.join(t, "notes.txt")), "replaced");
        assert.equal(fs.statSync(path.join(t, "notes.txt")).mode & 0o777, 0o640, "an existing target keeps its mode");
    };
    await expectRun("write-existing", files, "files.write", { path: path.join(t, "notes.txt"), text: "replaced" }, "completed",
        /Read back: 8 bytes, sha256 [0-9a-f]{16}, mode 640\.$/, keepsMode);
    await expectRun("move", files, "files.move", { from: path.join(t, "new.txt"), to: path.join(t, "sub", "moved.txt") }, "completed",
        /Read back: the source is absent and the destination is present\.$/, () => {
            assert.equal(fs.existsSync(path.join(t, "new.txt")), false);
            assert.equal(read(path.join(t, "sub", "moved.txt")), "fresh text");
        });
    await expectRun("move-link", files, "files.move", { from: path.join(t, "link-ssh"), to: path.join(t, "link-moved") }, "completed",
        /Read back/, () => {
            assert.equal(fs.readlinkSync(path.join(t, "link-moved")), ssh, "the link itself moves");
            assert.equal(read(path.join(ssh, "id")), "beta protected secret\n");
        });
    await expectRun("delete-file", files, "files.delete", { path: path.join(t, "sub", "moved.txt") }, "completed",
        /Read back: the path is absent\.$/, () => assert.equal(fs.existsSync(path.join(t, "sub", "moved.txt")), false));
    await expectRun("delete-link", files, "files.delete", { path: path.join(t, "link-moved") }, "completed", /Read back/, () => {
        assert.equal(fs.existsSync(path.join(t, "link-moved")), false);
        assert.equal(read(path.join(ssh, "id")), "beta protected secret\n", "a link's target stays");
    });
    await expectRun("delete-dangling", files, "files.delete", { path: path.join(t, "dangling") }, "completed", /Read back/);
    const tree3 = path.join(t, "tree");
    fs.mkdirSync(path.join(tree3, "a", "b"), { recursive: true });
    fs.writeFileSync(path.join(tree3, "a", "b", "leaf"), "x");
    fs.writeFileSync(path.join(tree3, "top"), "x");
    fs.symlinkSync(ssh, path.join(tree3, "a", "to-ssh"));
    await expectRun("delete-tree", files, "files.delete", { path: tree3 }, "completed", /\(6 entries\)\. Read back: the path is absent\.$/, () => {
        assert.equal(fs.existsSync(tree3), false);
        assert.equal(read(path.join(ssh, "id")), "beta protected secret\n");
    });

    // Refusals and failures that answer a sentence.
    plant();
    await expectRun("read-binary", files, "files.read", { path: path.join(t, "binary.bin") }, "failed", /is binary or not UTF-8 text \(11 bytes\)/);
    await expectRun("read-ceiling", files, "files.read", { path: path.join(t, "big.txt") }, "failed", /holds 100 bytes, over the 64 byte read ceiling/);
    await expectRun("read-folder", files, "files.read", { path: path.join(t, "sub") }, "failed", /is a folder; files\.read reads regular files only/);
    cp.execFileSync("/usr/bin/mkfifo", [path.join(t, "fifo")]);
    await expectRun("read-fifo", files, "files.read", { path: path.join(t, "fifo") }, "failed", /is a fifo; files\.read reads regular files only/);
    await expectRun("list-file", files, "files.list", { path: path.join(t, "notes.txt") }, "failed", /is a file, not a folder/);
    await expectRun("write-no-parent", files, "files.write", { path: path.join(t, "absent", "x"), text: "x" }, "failed",
        /does not exist; files\.write creates no folders/);
    await expectRun("write-ceiling", files, "files.write", { path: path.join(t, "x"), text: "x".repeat(65) }, "failed", /65 bytes, over the 64 byte write ceiling/);
    await expectRun("write-folder", files, "files.write", { path: path.join(t, "sub"), text: "x" }, "failed", /replaces regular files only/);
    await expectRun("move-no-parent", files, "files.move", { from: path.join(t, "notes.txt"), to: path.join(t, "absent", "x") }, "failed",
        /files\.move creates no folders/);
    await expectRun("absent", files, "files.read", { path: path.join(t, "absent") }, "failed", /does not exist/);
    const exdev = make(require(file));
    let movedAcross;
    fsFault("renameSync", () => { throw Object.assign(new Error("cross-device"), { code: "EXDEV" }); }, () => {
        movedAcross = exdev.run("files.move", { from: path.join(t, "notes.txt"), to: path.join(t, "across") });
    });
    const across = await movedAcross;
    assert.equal(across.outcome, "failed");
    assert.match(across.content, /are on different file systems; files\.move does not copy\./);
    assert.equal(fs.existsSync(path.join(t, "across")), false, "no copy fallback");
    cases++;

    // Denied paths for every tool, and link escapes.
    const everyTool = target => [
        ["files.list", { path: target }], ["files.read", { path: target }], ["files.search", { path: target, query: "beta" }],
        ["files.write", { path: target, text: "overwritten" }], ["files.move", { from: target, to: path.join(t, "taken") }],
        ["files.move", { from: path.join(t, "notes.txt"), to: target }], ["files.delete", { path: target }]
    ];
    for (const [name, target] of deniedPaths) {
        for (const [id, args] of everyTool(target)) {
            const viaFolder = id === "files.list" || id === "files.search" ? { ...args, path: path.dirname(target) } : args;
            await expectRun("denied-" + name + "-" + id, files, id, viaFolder, "failed", /^Refused: protected-path for /);
        }
        assert.equal(read(target), "beta protected secret\n", name + " untouched");
    }
    assert.equal(read(path.join(t, "notes.txt")), "alpha\nBeta line\n");
    // A lexical reading of the last one names t/secret; the judge resolves
    // the link first.
    const escapes = [
        ["link-outside", path.join(t, "link-file"), "outside-home"],
        ["link-protected", path.join(t, "link-ssh", "id"), "protected-path"],
        ["link-middle", path.join(t, "link-out", "secret"), "outside-home"],
        ["dangling", path.join(t, "dangling"), "path-resolution"],
        ["dot-dot-after-link", path.join(t, "link-out") + "/../secret", "outside-home"]
    ];
    for (const [name, target, reason] of escapes)
        for (const [id, args] of everyTool(target).filter(([id]) => id !== "files.move" && id !== "files.delete"))
            await expectRun("escape-" + name + "-" + id, files, id, args, "failed", new RegExp("^Refused: " + reason + " for "));
    assert.equal(read(path.join(outside, "secret")), "beta outside secret\n");

    // A component swapped for a link between the judge and the act.
    const swapFolder = path.join(t, "swap");
    const plantSwap = () => {
        fs.rmSync(swapFolder, { recursive: true, force: true });
        fs.mkdirSync(swapFolder);
        fs.writeFileSync(path.join(swapFolder, "id"), "ordinary\n");
    };
    const swap = () => {
        fs.renameSync(swapFolder, swapFolder + "-was");
        fs.symlinkSync(ssh, swapFolder);
    };
    const unswap = () => {
        fs.unlinkSync(swapFolder);
        fs.rmSync(swapFolder + "-was", { recursive: true });
    };
    const swappedAfterJudge = async Files => {
        plantSwap();
        try {
            await expectRun("swap-folder-after-judge", make(Files, afterJudge(swap)), "files.read", { path: path.join(swapFolder, "id") }, "failed",
                /^Refused: path-changed for /);
        } finally { unswap(); }
    };
    await swappedAfterJudge(require(file));
    const finalAfterJudge = async Files => {
        plantSwap();
        await expectRun("swap-file-after-judge", make(Files, afterJudge(() => {
            fs.unlinkSync(path.join(swapFolder, "id"));
            fs.symlinkSync(path.join(ssh, "id"), path.join(swapFolder, "id"));
        })), "files.read", { path: path.join(swapFolder, "id") }, "failed", /^Refused: path-changed for /);
    };
    await finalAfterJudge(require(file));
    // Swapped between the walk's lstat and its open: only O_NOFOLLOW refuses.
    const raced = (method, suffix, act) => async Files => {
        plantSwap();
        const executor = make(Files);
        let pending;
        let armed = true;
        fsFault(method, (original, target, ...rest) => {
            if (armed && typeof target === "string" && target.startsWith("/proc/self/fd/") && target.endsWith(suffix)) {
                armed = false;
                act();
            }
            return original(target, ...rest);
        }, () => executor.files.records.files.start(Tools.refine({ id: "files.read", args: { path: path.join(swapFolder, "id") } }).call,
            value => { pending = value; }));
        try {
            assert.equal(armed, false, "the race reached its open");
            assert.equal(pending.outcome, "failed", pending.content);
            assert.match(pending.content, /^Refused: path-changed for /);
            cases++;
        } finally {
            if (fs.lstatSync(swapFolder).isSymbolicLink()) unswap();
            else if (fs.lstatSync(path.join(swapFolder, "id")).isSymbolicLink()) fs.rmSync(swapFolder, { recursive: true });
        }
    };
    const walkRace = raced("openSync", "/swap", swap);
    await walkRace(require(file));
    const finalRace = raced("openSync", "/id", () => {
        fs.unlinkSync(path.join(swapFolder, "id"));
        fs.symlinkSync(path.join(ssh, "id"), path.join(swapFolder, "id"));
    });
    await finalRace(require(file));

    // list names and measures, and opens no child.
    plant();
    const listOpens = async Files => {
        const opened = [];
        let pending;
        fsFault("openSync", (original, target, ...rest) => { opened.push(String(target)); return original(target, ...rest); }, () => {
            pending = make(Files).run("files.list", { path: t });
        });
        const answer = await pending;
        assert.equal(answer.outcome, "completed");
        const children = fs.readdirSync(t);
        assert.deepEqual(opened.filter(target => children.includes(path.basename(target))), [], "list opens no child");
        assert.ok(opened.some(target => target.startsWith("/proc/self/fd/") && target.endsWith("/t")), "list opens its folder");
        cases++;
    };
    await listOpens(require(file));
    await expectRun("list-cut", make(require(file), fresh, { ...BOUNDS, listEntries: 3 }), "files.list", { path: t }, "completed",
        /^3 entries in .* \(list cut at 3 entries; the rest are unnamed\)\n/);

    // search: case-insensitive names and lines, every skip counted.
    const searched = async (Files, bounds = BOUNDS, denied = fresh) => (await make(Files, denied, bounds).run("files.search", { path: t, query: "BETA" }));
    const searchHappy = async Files => {
        plant();
        const answer = await searched(Files);
        assert.equal(answer.outcome, "completed");
        assert.equal(answer.content, [
            "3 matches for \"BETA\" under " + t + ".",
            "Skipped: 4 links, 0 protected, 1 binary or not UTF-8, 1 over 64 bytes, 1 folders deeper than 2 levels, 0 unreadable or changed.",
            path.join(t, "beta-name.md"),
            path.join(t, "notes.txt") + ":2: Beta line",
            path.join(t, "sub", "deep.txt") + ":1: beta deep"
        ].join("\n"));
        cases++;
    };
    await searchHappy(require(file));
    const protectedChild = async Files => {
        plant();
        const late = path.join(project, ".codex-late");
        try {
            const answer = await make(Files, afterJudge(() => {
                fs.mkdirSync(late);
                fs.writeFileSync(path.join(late, "notes"), "beta late secret\n");
            })).run("files.search", { path: project, query: "beta" });
            assert.equal(answer.outcome, "completed");
            assert.match(answer.content, /Skipped: \d+ links, 1 protected,/);
            assert.equal(answer.content.includes("late"), false, "a protected child is never named or read");
            cases++;
        } finally { fs.rmSync(late, { recursive: true, force: true }); }
    };
    await protectedChild(require(file));
    const searchRace = async Files => {
        plant();
        let armed = true;
        let pending;
        fsFault("openSync", (original, target, ...rest) => {
            if (armed && typeof target === "string" && target.endsWith("/notes.txt")) {
                armed = false;
                fs.unlinkSync(path.join(t, "notes.txt"));
                fs.symlinkSync(path.join(outside, "secret"), path.join(t, "notes.txt"));
            }
            return original(target, ...rest);
        }, () => { pending = searched(Files); });
        const answer = await pending;
        assert.equal(armed, false);
        assert.equal(answer.content.includes("outside secret"), false, "a file swapped for a link is never read");
        assert.match(answer.content, /Skipped: 5 links,/);
        cases++;
    };
    await searchRace(require(file));
    const bound = (name, bounds, pattern, setup) => async Files => {
        plant();
        if (setup) setup();
        const answer = await searched(Files, { ...BOUNDS, ...bounds });
        assert.equal(answer.outcome, "completed");
        assert.match(answer.content, pattern, name);
        cases++;
    };
    const searchBounds = {
        entries: bound("entries", { searchEntries: 3 }, /; stopped at the entries bound\./),
        bytes: bound("bytes", { searchBytes: 20 }, /; stopped at the bytes bound\./),
        matches: bound("matches", { searchMatches: 2 }, /^2 matches .*; stopped at the matches bound\./),
        depth: bound("depth", { searchDepth: 0 }, /1 folders deeper than 0 levels/),
        lines: bound("lines", { lineChars: 4 }, /notes\.txt:2: Beta\.\.\./),
        time: bound("time", {}, /; stopped at the time bound\./, () => { clockNow = 0; let calls = 0; clock.now = () => (calls++ > 3 ? 5000 : 0); })
    };
    for (const check of Object.values(searchBounds)) await check(require(file));
    clock.now = () => clockNow;
    // The search yields between folders, and close stops it there.
    const yields = async Files => {
        plant();
        let ticked = false;
        const pending = searched(Files).then(answer => ({ answer, ticked }));
        setImmediate(() => { ticked = true; });
        const { answer, ticked: before } = await pending;
        assert.equal(answer.outcome, "completed");
        assert.equal(before, true, "the event loop runs while a search walks its folders");
        cases++;
    };
    await yields(require(file));
    const closing = async Files => {
        plant();
        const executor = make(Files);
        const pending = executor.run("files.search", { path: t, query: "beta" });
        executor.files.close();
        const answer = await pending;
        assert.deepEqual(answer, { outcome: "failed", content: "The search stopped: Jarvis is closing." });
        assert.deepEqual(await executor.run("files.read", { path: path.join(t, "notes.txt") }),
            { outcome: "failed", content: "The file tools are closed." });
        cases++;
    };
    await closing(require(file));

    // write never replaces a target that appeared after the judge.
    const appeared = async Files => {
        plant();
        const target = path.join(t, "appeared.txt");
        await expectRun("write-appeared", make(Files, afterJudge(() => fs.writeFileSync(target, "theirs"))), "files.write",
            { path: target, text: "mine" }, "failed", /appeared after the check; it was not replaced\./,
            () => assert.equal(read(target), "theirs"));
    };
    await appeared(require(file));
    const moveAppeared = async Files => {
        plant();
        const target = path.join(t, "landing.txt");
        await expectRun("move-appeared", make(Files, afterJudge(() => fs.writeFileSync(target, "theirs"), 2)), "files.move",
            { from: path.join(t, "notes.txt"), to: target }, "failed", /appeared after the check; it was not replaced\./,
            () => { assert.equal(read(target), "theirs"); assert.equal(read(path.join(t, "notes.txt")), "alpha\nBeta line\n"); });
    };
    await moveAppeared(require(file));

    // delete walks the whole tree first: a protected child or the entry
    // bound refuses the call before anything is removed.
    const zone = path.join(home, "zone");
    const plantZone = () => {
        fs.rmSync(zone, { recursive: true, force: true });
        fs.mkdirSync(path.join(zone, "a"), { recursive: true });
        fs.writeFileSync(path.join(zone, "a", "one"), "x");
        fs.writeFileSync(path.join(zone, "two"), "x");
    };
    const zoneIntact = () => {
        assert.equal(read(path.join(zone, "a", "one")), "x");
        assert.equal(read(path.join(zone, "two")), "x");
    };
    const deleteProtected = async Files => {
        plantZone();
        try {
            await expectRun("delete-protected-child", make(Files, afterJudge(() => {
                fs.mkdirSync(path.join(zone, ".claude-late"));
                fs.writeFileSync(path.join(zone, ".claude-late", "token"), "x");
            })), "files.delete", { path: zone }, "failed", /^Refused: protected-path for .*\.claude-late; nothing was removed\.$/, () => {
                zoneIntact();
                assert.equal(read(path.join(zone, ".claude-late", "token")), "x");
            });
        } finally { fs.rmSync(zone, { recursive: true, force: true }); }
    };
    await deleteProtected(require(file));
    const deleteBound = async Files => {
        plantZone();
        for (let i = 0; i < 8; i++) fs.writeFileSync(path.join(zone, "f" + i), "x");
        try {
            await expectRun("delete-bound", make(Files), "files.delete", { path: zone }, "failed",
                /holds more than 8 entries; nothing was removed\./, zoneIntact);
        } finally { fs.rmSync(zone, { recursive: true, force: true }); }
    };
    await deleteBound(require(file));

    // The executor's own rejudge: a call reaching start is judged again.
    const rejudged = async Files => {
        const answer = await make(Files).run("files.read", { path: path.join(ssh, "id") });
        assert.equal(answer.outcome, "failed");
        assert.equal(answer.content.includes("secret"), false);
        cases++;
    };
    await rejudged(require(file));
    const brokenSnapshot = async Files => {
        const answer = await make(Files, () => { throw new Error("jarvis: paths=home"); }).run("files.read", { path: path.join(t, "notes.txt") });
        assert.deepEqual(answer, { outcome: "failed", content: "The protected path list could not be built: jarvis: paths=home." });
        cases++;
    };
    await brokenSnapshot(require(file));

    // Registration: at once, and only when a snapshot builds.
    const registered = Files => {
        const ids = [];
        const router = { register: (id, record) => ids.push([id, record.commands, record.cancellable, record.timeoutMs]) };
        Files.install({ router, denied: fresh, bounds: BOUNDS, clock });
        assert.deepEqual(ids, [["files", [], false, 1100]]);
        ids.length = 0;
        Files.install({ router, denied: () => { throw new Error("jarvis: paths=home"); }, bounds: BOUNDS, clock });
        assert.deepEqual(ids, []);
        cases++;
    };
    registered(require(file));

    let controls = 0;
    async function control(name, edits, check, target = file, consumer = "Files.js") {
        await mutant(target, name, edits, undefined, async module => { await check(module); }, consumer);
        controls++;
    }
    const red = check => async Files => check(Files);
    await control("rejudge", [["const verdict = snapshot.inspect(call.args[field], role);",
        "const verdict = { kind: \"path\", path: call.args[field], exists: true };"]], rejudged);
    await control("snapshot-failure", [["try { snapshot = denied(); }", "try { snapshot = { inspect: (file, role) => ({ kind: \"path\", path: file, exists: true }) }; }"]],
        brokenSnapshot);
    await control("walk-nofollow", [["O_RDONLY | O_DIRECTORY | O_NOFOLLOW); }", "O_RDONLY | O_DIRECTORY); }"]], walkRace,
        path.join(backend, "Anchored.js"));
    await control("final-nofollow", [["return fs.openSync(Anchored.child(parent, name), flags | O_NOFOLLOW);", "return fs.openSync(Anchored.child(parent, name), flags);"]], finalRace);
    await control("anchored-parent", [["const opened = Anchored.directory(path.dirname(file));",
        "const opened = { kind: \"directory\", fd: fs.openSync(path.dirname(file), O_RDONLY | O_DIRECTORY) };"]], swappedAfterJudge);
    await control("final-link", [["if (stat === null || stat.isSymbolicLink()) throw changed(target.path);\n            // A device",
        "if (stat === null) throw changed(target.path);\n            // A device"]], finalAfterJudge);
    await control("list-no-child", [["const child = entry(fd, item.name);",
        "const child = entry(fd, item.name); if (child && !child.isSymbolicLink()) fs.closeSync(fs.openSync(Anchored.child(fd, item.name), O_RDONLY | O_NONBLOCK));"]],
        listOpens);
    await control("search-follow", [["try { stat = fs.lstatSync(Anchored.child(handle.fd, item.name)); }", "try { stat = fs.statSync(Anchored.child(handle.fd, item.name)); }"],
        ["try { fd = fs.openSync(Anchored.child(folder, name), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY); }", "try { fd = fs.openSync(Anchored.child(folder, name), O_RDONLY | O_NONBLOCK | O_NOCTTY); }"],
        ["try { fd = fs.openSync(Anchored.child(next.parent.fd, next.name), O_RDONLY | O_DIRECTORY | O_NOFOLLOW); }", "try { fd = fs.openSync(Anchored.child(next.parent.fd, next.name), O_RDONLY | O_DIRECTORY); }"]],
        searchHappy);
    await control("search-nofollow", [["try { fd = fs.openSync(Anchored.child(folder, name), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY); }",
        "try { fd = fs.openSync(Anchored.child(folder, name), O_RDONLY | O_NONBLOCK | O_NOCTTY); }"]], searchRace);
    await control("search-child-judge", [["if (snapshot.inspect(child, \"read\").kind !== \"path\")", "if (false && snapshot.inspect(child, \"read\").kind !== \"path\")"]], protectedChild);
    await control("binary", [["if (bytes.includes(0)) return null;", "if (false) return null;"]], red(async Files =>
        assert.equal((await make(Files).run("files.read", { path: path.join(t, "binary.bin") })).outcome, "failed")));
    await control("read-ceiling", [["if (stat.size > bounds.readBytes)\n", "if (false)\n"]],
        red(async Files => assert.match((await make(Files).run("files.read", { path: path.join(t, "big.txt") })).content, /over the 64 byte read ceiling/)));
    for (const [name, needle, replacement] of [
        ["entries", "if (++visited > bounds.searchEntries)", "if (false)"],
        ["bytes", "if (bytes + stat.size > bounds.searchBytes)", "if (false)"],
        ["matches", "if (matches.length === bounds.searchMatches)", "if (false)"],
        ["depth", "if (depth === bounds.searchDepth) skipped.deep++;\n                    else", ""],
        ["lines", "return plain.length > bounds.lineChars ?", "return false ?"],
        ["time", "if (clock.now() - started >= bounds.searchMs) { cut = \"time\"; break; }", ""]
    ]) {
        const edits = [[needle, replacement]];
        if (name === "time") edits.push(["if (cut === null && clock.now() - started >= bounds.searchMs) cut = \"time\";", ""]);
        await control("search-" + name, edits, async Files => {
            try { await searchBounds[name](Files); } finally { clock.now = () => clockNow; }
        });
    }
    await control("search-yield", [["setImmediate(step);\n                } catch", "step();\n                } catch"],
        ["visit({ fd: opened.fd, refs: 1 }, target.path, 0);\n                setImmediate(step);", "visit({ fd: opened.fd, refs: 1 }, target.path, 0);\n                step();"]], yields);
    await control("search-close", [["if (closed) { end(", "if (false) { end("]], closing);
    await control("start-after-close", [["if (closed) throw failed(\"The file tools are closed.\");", ""]], closing);
    await control("no-replace", [["try { fs.linkSync(Anchored.child(parent, temporary), Anchored.child(parent, name)); }",
        "try { fs.renameSync(Anchored.child(parent, temporary), Anchored.child(parent, name)); }"]], appeared);
    await control("keep-mode", [["if (mode !== null) fs.fchmodSync(fd, mode);", ""]], red(async Files => {
        plant();
        fs.chmodSync(path.join(t, "notes.txt"), 0o640);
        await make(Files).run("files.write", { path: path.join(t, "notes.txt"), text: "replaced" });
        keepsMode();
    }));
    await control("move-destination", [["if (!to.exists && entry(folder, name) !== null)", "if (false)"]], moveAppeared);
    await control("delete-walk-first", [["const tree = walk(parent, name, target.path, snapshot, 0, count);\n                    total += count.value;\n                    prune(parent, name, target.path, tree, removed);",
        "fs.rmSync(Anchored.child(parent, name), { recursive: true }); removed.value++;"]], deleteProtected);
    await control("delete-child-judge", [["if (verdict.kind !== \"path\") throw failed(\"Refused: \"", "if (false) throw failed(\"Refused: \""]], deleteProtected);
    await control("delete-bound", [["if (++count.value > bounds.deleteEntries)", "if (false)"]], deleteBound);
    await control("registration", [["try { options.denied(); }", "try { void options.denied; }"]], red(registered));
    await control("exdev", [["if (error.code === \"EXDEV\") throw failed(", "if (false) throw failed("]], red(async Files => {
        plant();
        let pending;
        fsFault("renameSync", () => { throw Object.assign(new Error("cross-device"), { code: "EXDEV" }); }, () => {
            pending = make(Files).run("files.move", { from: path.join(t, "notes.txt"), to: path.join(t, "across") });
        });
        assert.match((await pending).content, /are on different file systems; files\.move does not copy\./);
    }));

    // End to end: the daemon's own Denied producer through its real router,
    // Policy, audit and this executor, driven by the test-only tool driver.
    const ordinary = path.join(t, "notes.txt");
    plant();
    const daemonDenied = path.join(home, ".claude-team", "notes");
    // The scratch HOME lies inside this checkout, the daemon's install root,
    // so the daemon runs from a minimal VGS tree copy beside HOME.
    async function daemon(name, edit) {
        const install = path.join(process.env.JARVIS_TEST_ROOT, "tree-" + name);
        for (const entry of ["bin/lib/qml-library.js", "bin/lib/judge-files.js", "shell/Core/Dispatch.js", "shell/Commons/DesktopLaunch.js"]) {
            fs.mkdirSync(path.dirname(path.join(install, entry)), { recursive: true });
            fs.copyFileSync(path.join(tree, entry), path.join(install, entry));
        }
        const folder = path.join(install, "shell/plugins/vgs.jarvis");
        fs.mkdirSync(folder, { recursive: true });
        for (const entry of ["JarvisProtocol.js", "Session.js", "AccountProviders.js"])
            fs.copyFileSync(path.join(plugin, entry), path.join(folder, entry));
        fs.cpSync(backend, path.join(folder, "backend"), { recursive: true });
        const daemonFile = path.join(folder, "backend/jarvisd.js");
        if (edit !== undefined) {
            const source = fs.readFileSync(daemonFile, "utf8");
            assert.equal(source.split(edit[0]).length - 1, 1, name + " daemon edit match");
            fs.writeFileSync(daemonFile, source.replace(edit[0], edit[1]));
        }
        const gates = path.join(folder, "gates");
        const driver = path.join(folder, "driver");
        for (const fixture of ["scripted.js", "desktop-driver.js"]) {
            const result = cp.spawnSync(process.execPath, [path.join(tree, "scripts/fixtures/jarvis", fixture), daemonFile,
                fixture === "scripted.js" ? gates : driver], { encoding: "utf8" });
            assert.equal(result.status, 0, fixture + ": " + result.stderr);
        }
        const env = { PATH: process.env.PATH, HOME: process.env.HOME, LANG: "C.UTF-8" };
        for (const variable of ["XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_RUNTIME_DIR"]) env[variable] = process.env[variable];
        const child = cp.spawn(process.execPath, [daemonFile, "--tree", install], { env, stdio: ["pipe", "ignore", "pipe"] });
        let stderr = "";
        child.stderr.on("data", data => { stderr += data; });
        const closed = once(child, "close");
        // Bounds a daemon that never answers, not a latency budget.
        const timeout = setTimeout(() => child.kill("SIGKILL"), 20000);
        const outcomes = {};
        try {
            child.stdin.write(JSON.stringify({ v: 1, type: "hello", gen: 0, revision: "a".repeat(64), locked: false,
                settings: { mode: "hold", microphone: "", speaker: "", brain: "", taskTerminal: "auto" },
                directories: { state: path.join(process.env.JARVIS_TEST_ROOT, name + "-state"),
                    data: path.join(process.env.JARVIS_TEST_ROOT, name + "-data"), runtime: path.join(process.env.JARVIS_TEST_ROOT, name + "-run") },
                keys: { talk: "SUPER+code:108", mute: "SUPER+SHIFT+code:108", stop: "SUPER+ALT+PERIOD" } }) + "\n");
            for (const [id, target] of [["ordinary", ordinary], ["account", daemonDenied]]) {
                fs.mkdirSync(driver, { recursive: true });
                fs.writeFileSync(path.join(driver, "call.next"), JSON.stringify({ id, tool: "files.read", arguments: { path: target } }));
                fs.renameSync(path.join(driver, "call.next"), path.join(driver, "call.json"));
                for (let wait = 0; outcomes[id] === undefined; wait++) {
                    assert.ok(wait < 1000 && child.exitCode === null, name + " " + id + " answers: " + stderr);
                    // Polls the driver's result file; the driver polls every 10 ms.
                    await new Promise(resolve => setTimeout(resolve, 10));
                    const rows = fs.existsSync(path.join(driver, "results.jsonl"))
                        ? fs.readFileSync(path.join(driver, "results.jsonl"), "utf8").trim().split("\n").map(line => JSON.parse(line)) : [];
                    outcomes[id] = rows.find(row => row.id === id && row.outcome !== undefined);
                }
            }
            child.stdin.end();
            const [code] = await closed;
            assert.equal(code, 0, stderr);
            assert.equal(stderr, "");
        } finally {
            clearTimeout(timeout);
            if (child.exitCode === null) { child.kill("SIGKILL"); await closed; }
        }
        return outcomes;
    }
    const endToEnd = async outcomes => {
        assert.deepEqual([outcomes.ordinary.outcome, outcomes.ordinary.content], ["completed", "alpha\nBeta line\n"]);
        assert.equal(outcomes.account.outcome, "cancelled");
        assert.deepEqual(JSON.parse(outcomes.account.content), { kind: "refuse", reason: "protected-path" });
    };
    await endToEnd(await daemon("production"));
    cases++;
    await assert.rejects(async () => endToEnd(await daemon("no-producer", ["denied: deniedOrNull() }),", "denied: null }),"])),
        assert.AssertionError, "a daemon without the producer must turn red");
    controls++;

    console.log("test-jarvis-files: ok cases=" + cases + " controls=" + controls);
});
