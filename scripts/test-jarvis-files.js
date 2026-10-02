#!/usr/bin/env node
// The files executor against real scratch files in the J09 world, and calls
// through a disposable daemon's real router, Policy, audit and executor.
// No live session, real HOME, credential or network is used.
"use strict";
const { assert, fs, path, tree, world, seed, mutant, fsFault, fsFaultAsync } = require("./fixtures/jarvis/policy.js");
const cp = require("node:child_process");
const { once } = require("node:events");
const plugin = path.join(tree, "shell/plugins/vgs.jarvis");
const backend = path.join(plugin, "backend");
const file = path.join(backend, "Files.js");
const Denied = require(path.join(backend, "Denied.js"));
const Tools = require(path.join(backend, "Tools.js"));
const { O_NONBLOCK } = fs.constants;

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
    // The fake clock stands still, so only the entry count ends a slice.
    const BOUNDS = { listEntries: 16, readBytes: 64, writeBytes: 64, searchDepth: 2, searchEntries: 40,
        searchBytes: 400, searchMatches: 8, lineChars: 24, searchMs: 1000, searchSliceEntries: 4, searchSliceMs: 1000,
        deleteEntries: 8, deleteDepth: 3, slackMs: 100 };
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
    // Run act once after the executor's own rejudge answers, before it opens
    // anything: the tree changes between the judge and the act.
    function afterJudge(act) {
        return () => {
            const snapshot = fresh();
            return { inspect: snapshot.inspect, inspectPaths(pairs) {
                const verdict = snapshot.inspectPaths(pairs);
                act();
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
        // Invalid UTF-8 without NUL.
        fs.writeFileSync(path.join(t, "latin.bin"), Buffer.from([0x62, 0xff]));
        fs.writeFileSync(path.join(t, "big.txt"), "beta ".repeat(20));
        fs.writeFileSync(path.join(t, "secret"), "lexical sibling\n");
        fs.symlinkSync(outside, path.join(t, "link-out"));
        fs.symlinkSync(path.join(outside, "secret"), path.join(t, "link-file"));
        fs.symlinkSync(ssh, path.join(t, "link-ssh"));
        fs.symlinkSync(path.join(t, "absent"), path.join(t, "dangling"));
    }
    const read = target => fs.readFileSync(target, "utf8");
    const SECRET = /(outside|protected|late) secret/;
    let cases = 0;
    async function expectRun(name, files, id, args, outcome, content, check) {
        const answer = await files.run(id, args);
        assert.equal(answer.outcome, outcome, name + ": " + answer.content);
        if (content instanceof RegExp) assert.match(answer.content, content, name);
        else if (content !== undefined) assert.equal(answer.content, content, name);
        assert.doesNotMatch(answer.content, SECRET, name + " shows no secret");
        if (check) await check(answer);
        cases++;
        return answer;
    }
    const files = make();

    // Happy paths with read-back.
    plant();
    await expectRun("list", files, "files.list", { path: t }, "completed",
        ["11 entries in " + t, 'file "beta-name.md" 5 bytes', 'file "big.txt" 100 bytes', 'file "binary.bin" 11 bytes',
            'link "dangling"', 'file "latin.bin" 2 bytes', 'link "link-file"', 'link "link-out"', 'link "link-ssh"',
            'file "notes.txt" 16 bytes', 'file "secret" 16 bytes', 'directory "sub"'].join("\n"));
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
    const binaryRead = async Files => expectRun("read-binary", make(Files), "files.read", { path: path.join(t, "binary.bin") }, "failed",
        /is binary or not UTF-8 text \(11 bytes\)/);
    await binaryRead(require(file));
    const latinRead = async Files => expectRun("read-invalid-utf8", make(Files), "files.read", { path: path.join(t, "latin.bin") }, "failed",
        /is binary or not UTF-8 text \(2 bytes\)/);
    await latinRead(require(file));
    const ceilingRead = async Files => expectRun("read-ceiling", make(Files), "files.read", { path: path.join(t, "big.txt") }, "failed",
        /holds 100 bytes, over the 64 byte read ceiling/);
    await ceilingRead(require(file));
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
    const sameEntry = async Files => expectRun("move-same-entry", make(Files), "files.move",
        { from: path.join(t, "notes.txt"), to: path.join(t, "notes.txt") }, "failed", /are the same entry\.$/);
    await sameEntry(require(file));
    await expectRun("absent", files, "files.read", { path: path.join(t, "absent") }, "failed", /does not exist/);
    const otherExecutor = async Files => {
        const answer = await new Promise(resolve => make(Files).files.records.files.start(Tools.refine({ id: "windows.list", args: {} }).call, resolve));
        assert.deepEqual(answer, { outcome: "failed", content: "Refused: executor for windows.list." });
        cases++;
    };
    await otherExecutor(require(file));
    const exdevMove = async Files => {
        plant();
        let pending;
        fsFault("renameSync", () => { throw Object.assign(new Error("cross-device"), { code: "EXDEV" }); }, () => {
            pending = make(Files).run("files.move", { from: path.join(t, "notes.txt"), to: path.join(t, "across") });
        });
        const across = await pending;
        assert.equal(across.outcome, "failed");
        assert.match(across.content, /are on different file systems; files\.move does not copy\./);
        assert.equal(fs.existsSync(path.join(t, "across")), false, "no copy fallback");
        cases++;
    };
    await exdevMove(require(file));
    // The read opens without blocking, so a fifo swapped in cannot hold the loop.
    const nonBlocking = async Files => {
        plant();
        let flags = null;
        let pending;
        fsFault("openSync", (original, target, ...rest) => {
            if (typeof target === "string" && target.startsWith("/proc/self/fd/") && target.endsWith("/notes.txt")) flags = rest[0];
            return original(target, ...rest);
        }, () => { pending = make(Files).run("files.read", { path: path.join(t, "notes.txt") }); });
        assert.equal((await pending).outcome, "completed");
        assert.equal((flags & O_NONBLOCK) !== 0, true, "the read opens with O_NONBLOCK");
        cases++;
    };
    await nonBlocking(require(file));

    // Denied paths for every tool, and link escapes.
    const everyTool = target => [
        ["files.list", { path: target }], ["files.read", { path: target }], ["files.search", { path: target, query: "beta" }],
        ["files.write", { path: target, text: "overwritten" }], ["files.move", { from: target, to: path.join(t, "taken") }],
        ["files.move", { from: path.join(t, "notes.txt"), to: target }], ["files.delete", { path: target }]
    ];
    const deniedRow = async (Files, [name, target], id, args) => {
        const viaFolder = id === "files.list" || id === "files.search" ? { ...args, path: path.dirname(target) } : args;
        await expectRun("denied-" + name + "-" + id, make(Files), id, viaFolder, "failed", /^Refused: protected-path for /);
    };
    for (const row of deniedPaths) {
        for (const [id, args] of everyTool(row[1])) await deniedRow(require(file), row, id, args);
        assert.equal(read(row[1]), "beta protected secret\n", row[0] + " untouched");
    }
    assert.equal(read(path.join(t, "notes.txt")), "alpha\nBeta line\n");
    // A lexical reading of the last one names t/secret; the judge resolves
    // the link first. A removal and a move judge a final link as the link,
    // so only the middle-link rows apply to them.
    const escapes = [
        ["link-outside", path.join(t, "link-file"), "outside-home", false],
        ["link-protected", path.join(t, "link-ssh", "id"), "protected-path", false],
        ["link-middle", path.join(t, "link-out", "secret"), "outside-home", true],
        ["dangling", path.join(t, "dangling"), "path-resolution", false],
        ["dot-dot-after-link", path.join(t, "link-out") + "/../secret", "outside-home", true]
    ];
    for (const [name, target, reason, middle] of escapes)
        for (const [id, args] of everyTool(target).filter(([id]) => middle || (id !== "files.move" && id !== "files.delete")))
            await expectRun("escape-" + name + "-" + id + "-" + Object.keys(args).join(","), files, id, args, "failed",
                new RegExp("^Refused: " + reason + " for "));
    assert.equal(read(path.join(outside, "secret")), "beta outside secret\n");
    assert.equal(read(path.join(t, "secret")), "lexical sibling\n");

    // A move is judged where it lands: three steps that each look harmless
    // would otherwise plant model-written content in a rule-named folder.
    const projects = path.join(home, "projects");
    const landing = async (Files, Judge = Denied) => {
        fs.rmSync(projects, { recursive: true, force: true });
        fs.rmSync(path.join(home, "repo"), { recursive: true, force: true });
        fs.mkdirSync(path.join(projects, "repo", "src"), { recursive: true });
        const executor = make(Files, () => Judge.create(options));
        await expectRun("landing-rename", executor, "files.move", { from: path.join(projects, "repo", "src"),
            to: path.join(projects, "repo", ".claude-x") }, "completed", /Read back/);
        await expectRun("landing-plant", executor, "files.write", { path: path.join(projects, "repo", ".claude-x", "settings.json"),
            text: "{}" }, "completed", /Read back/);
        await expectRun("landing-carry", executor, "files.move", { from: path.join(projects, "repo"), to: path.join(home, "repo") },
            "failed", /^Refused: protected-path for .*\/projects\/repo\.$/, () => {
                assert.equal(fs.existsSync(path.join(home, "repo")), false);
                assert.equal(read(path.join(projects, "repo", ".claude-x", "settings.json")), "{}");
            });
    };
    await landing(require(file));

    // A dotfile manager's rule-named link in HOME protects the folder it
    // points to, read by its own path.
    const dotfiles = path.join(home, "dotfiles", "codex-work");
    fs.mkdirSync(dotfiles, { recursive: true });
    fs.writeFileSync(path.join(dotfiles, "auth.json"), "beta protected secret\n");
    fs.symlinkSync(dotfiles, path.join(home, ".codex-dotfiles"));
    const dotfileTarget = async (Files, Judge = Denied) => expectRun("dotfile-link-target", make(Files, () => Judge.create(options)),
        "files.read", { path: path.join(dotfiles, "auth.json") }, "failed", /^Refused: protected-path for /);
    await dotfileTarget(require(file));

    // A component swapped for a link between the judge and the act.
    const swapFolder = path.join(t, "swap");
    const plantSwap = () => {
        fs.rmSync(swapFolder, { recursive: true, force: true });
        fs.rmSync(swapFolder + "-was", { recursive: true, force: true });
        fs.mkdirSync(swapFolder);
        fs.writeFileSync(path.join(swapFolder, "id"), "ordinary\n");
        fs.writeFileSync(path.join(swapFolder, "plain"), "plain\n");
    };
    const swap = () => {
        fs.renameSync(swapFolder, swapFolder + "-was");
        fs.symlinkSync(ssh, swapFolder);
    };
    const unswap = () => {
        if (fs.lstatSync(swapFolder).isSymbolicLink()) fs.unlinkSync(swapFolder);
        fs.rmSync(swapFolder + "-was", { recursive: true, force: true });
        fs.rmSync(swapFolder, { recursive: true, force: true });
    };
    const swappedAfterJudge = (id, args) => async Files => {
        plantSwap();
        try {
            await expectRun("swap-folder-after-judge-" + id, make(Files, afterJudge(swap)), id, args, "failed", /^Refused: path-changed for /,
                answer => assert.equal(answer.content.includes("\"id\""), false));
        } finally { unswap(); }
    };
    const readSwapped = swappedAfterJudge("files.read", { path: path.join(swapFolder, "id") });
    const listSwapped = swappedAfterJudge("files.list", { path: swapFolder });
    const searchSwapped = swappedAfterJudge("files.search", { path: swapFolder, query: "beta" });
    for (const check of [readSwapped, listSwapped, searchSwapped]) await check(require(file));
    const finalAfterJudge = async Files => {
        plantSwap();
        try {
            await expectRun("swap-file-after-judge", make(Files, afterJudge(() => {
                fs.unlinkSync(path.join(swapFolder, "id"));
                fs.symlinkSync(path.join(ssh, "id"), path.join(swapFolder, "id"));
            })), "files.read", { path: path.join(swapFolder, "id") }, "failed", /^Refused: path-changed for /);
        } finally { unswap(); }
    };
    await finalAfterJudge(require(file));
    // Swapped between an lstat and its open: only O_NOFOLLOW refuses.
    const raced = (suffix, act, id = "files.read", args = { path: path.join(swapFolder, "id") }) => async Files => {
        plantSwap();
        let armed = true;
        let answer;
        try {
            answer = await fsFaultAsync("openSync", (original, target, ...rest) => {
                if (armed && typeof target === "string" && target.startsWith("/proc/self/fd/") && target.endsWith(suffix)) {
                    armed = false;
                    act();
                }
                return original(target, ...rest);
            }, () => make(Files).run(id, args));
            assert.equal(armed, false, "the race reached its open");
            assert.equal(answer.outcome, "failed", answer.content);
            assert.match(answer.content, /^Refused: path-changed for /);
            cases++;
        } finally { unswap(); }
    };
    const walkRace = raced("/swap", swap);
    await walkRace(require(file));
    const finalRace = raced("/id", () => {
        fs.unlinkSync(path.join(swapFolder, "id"));
        fs.symlinkSync(path.join(ssh, "id"), path.join(swapFolder, "id"));
    });
    await finalRace(require(file));
    // The list reads the folder it holds, even when its name changes after that open.
    const listRace = async Files => {
        plantSwap();
        let armed = true;
        try {
            const answer = await fsFaultAsync("openSync", (original, target, ...rest) => {
                const fd = original(target, ...rest);
                if (armed && typeof target === "string" && target.startsWith("/proc/self/fd/") && target.endsWith("/swap")) {
                    armed = false;
                    swap();
                }
                return fd;
            }, () => make(Files).run("files.list", { path: swapFolder }));
            assert.equal(armed, false);
            assert.equal(answer.outcome, "completed");
            assert.match(answer.content, /"plain"/, "the held folder is listed, not the protected one");
            cases++;
        } finally { unswap(); }
    };
    await listRace(require(file));

    // list names and measures, and touches no child beyond its metadata.
    plant();
    const listOpens = async Files => {
        const touched = [];
        const record = method => (original, target, ...rest) => { touched.push([method, String(target)]); return original(target, ...rest); };
        let pending;
        fsFault("openSync", record("openSync"), () => fsFault("readFileSync", record("readFileSync"), () =>
            fsFault("opendirSync", record("opendirSync"), () => fsFault("statSync", record("statSync"), () => {
                pending = make(Files).run("files.list", { path: t });
            }))));
        const answer = await pending;
        assert.equal(answer.outcome, "completed");
        const children = fs.readdirSync(t);
        assert.deepEqual(touched.filter(([, target]) => children.includes(path.basename(target))), [], "list touches no child");
        assert.ok(touched.some(([method, target]) => method === "openSync" && target.startsWith("/proc/self/fd/") && target.endsWith("/t")),
            "list opens its folder");
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
            "Skipped: 4 links, 0 protected, 2 binary or not UTF-8, 1 over 64 bytes, 1 folders deeper than 2 levels, 0 unreadable or changed.",
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
    // A file, then a folder, swapped for a link between the search's lstat and its open.
    const searchRace = (suffix, act, skips) => async Files => {
        plant();
        let armed = true;
        const answer = await fsFaultAsync("openSync", (original, target, ...rest) => {
            if (armed && typeof target === "string" && target.startsWith("/proc/self/fd/") && target.endsWith(suffix)) {
                armed = false;
                act();
            }
            return original(target, ...rest);
        }, () => searched(Files));
        assert.equal(armed, false);
        assert.equal(answer.content.includes("outside secret"), false, "a swapped entry is never read");
        assert.match(answer.content, skips);
        cases++;
    };
    const fileRace = searchRace("/notes.txt", () => {
        fs.unlinkSync(path.join(t, "notes.txt"));
        fs.symlinkSync(path.join(outside, "secret"), path.join(t, "notes.txt"));
    }, /Skipped: 5 links, 0 protected,/);
    await fileRace(require(file));
    const folderRace = searchRace("/sub", () => {
        fs.rmSync(path.join(t, "sub"), { recursive: true });
        fs.symlinkSync(outside, path.join(t, "sub"));
    }, /^Skipped: 4 links, 0 protected, .*, 1 unreadable or changed\.$/m);
    await folderRace(require(file));
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
        time: bound("time", {}, /; stopped at the time bound\./, () => { let calls = 0; clock.now = () => (calls++ > 3 ? 5000 : 0); })
    };
    for (const check of Object.values(searchBounds)) {
        try { await check(require(file)); } finally { clock.now = () => clockNow; }
    }
    // One large folder is read in slices, so the event loop runs between them.
    const wide = path.join(project, "wide");
    fs.mkdirSync(wide);
    for (let i = 0; i < 64; i++) fs.writeFileSync(path.join(wide, "f" + i), "x\n");
    const yields = async Files => {
        let ticked = false;
        const pending = make(Files, fresh, { ...BOUNDS, searchEntries: 1000 }).run("files.search", { path: wide, query: "absent" })
            .then(answer => ({ answer, ticked }));
        setImmediate(() => { ticked = true; });
        const { answer, ticked: before } = await pending;
        assert.match(answer.content, /^0 matches for "absent" under .*wide\.\n/);
        assert.equal(before, true, "the event loop runs while one folder is searched");
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

    // write and move never replace an entry that appeared after the judge.
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
        await expectRun("move-appeared", make(Files, afterJudge(() => fs.writeFileSync(target, "theirs"))), "files.move",
            { from: path.join(t, "notes.txt"), to: target }, "failed", /appeared after the check; it was not replaced\./,
            () => { assert.equal(read(target), "theirs"); assert.equal(read(path.join(t, "notes.txt")), "alpha\nBeta line\n"); });
    };
    await moveAppeared(require(file));
    // An existing target that stops being a regular file before the rename stays.
    const writeRecheck = async Files => {
        plant();
        let armed = true;
        let pending;
        fsFault("fsyncSync", (original, ...args) => {
            if (armed) {
                armed = false;
                fs.unlinkSync(path.join(t, "notes.txt"));
                fs.mkdirSync(path.join(t, "notes.txt"));
            }
            return original(...args);
        }, () => { pending = make(Files).run("files.write", { path: path.join(t, "notes.txt"), text: "mine" }); });
        const answer = await pending;
        assert.equal(answer.outcome, "failed");
        assert.match(answer.content, /^Refused: path-changed for /);
        assert.equal(fs.statSync(path.join(t, "notes.txt")).isDirectory(), true, "the folder is kept");
        cases++;
    };
    await writeRecheck(require(file));

    // A read-back that does not see the effect answers unknown.
    const writeReadBack = async Files => {
        plant();
        let pending;
        fsFault("openSync", (original, target, flags, ...rest) => {
            if (typeof target === "string" && target.endsWith("/rb.txt") && (flags & fs.constants.O_CREAT) === 0) {
                const fd = original(target, fs.constants.O_WRONLY | fs.constants.O_TRUNC);
                fs.writeSync(fd, "other");
                fs.closeSync(fd);
            }
            return original(target, flags, ...rest);
        }, () => { pending = make(Files).run("files.write", { path: path.join(t, "rb.txt"), text: "mine" }); });
        const answer = await pending;
        assert.equal(answer.outcome, "unknown", answer.content);
        assert.match(answer.content, /reads back different content or mode/);
        cases++;
    };
    await writeReadBack(require(file));
    const moveReadBack = async Files => {
        plant();
        let renamed = false;
        let pending;
        fsFault("renameSync", (original, ...args) => { renamed = true; return original(...args); }, () =>
            fsFault("lstatSync", (original, target, ...rest) => {
                if (renamed && typeof target === "string" && target.endsWith("/moved-rb.txt"))
                    throw Object.assign(new Error("absent"), { code: "ENOENT" });
                return original(target, ...rest);
            }, () => { pending = make(Files).run("files.move", { from: path.join(t, "notes.txt"), to: path.join(t, "moved-rb.txt") }); }));
        const answer = await pending;
        assert.equal(answer.outcome, "unknown", answer.content);
        cases++;
    };
    await moveReadBack(require(file));
    const deleteReadBack = async Files => {
        plant();
        let removed = false;
        let pending;
        fsFault("unlinkSync", (original, ...args) => { removed = true; return original(...args); }, () =>
            fsFault("lstatSync", (original, target, ...rest) => {
                if (removed && typeof target === "string" && target.endsWith("/secret")) return original(path.join(t, "beta-name.md"), ...rest);
                return original(target, ...rest);
            }, () => { pending = make(Files).run("files.delete", { path: path.join(t, "secret") }); }));
        const answer = await pending;
        assert.equal(answer.outcome, "unknown", answer.content);
        assert.match(answer.content, /reads back present/);
        cases++;
    };
    await deleteReadBack(require(file));

    // delete walks the whole tree first: a protected child, the entry bound
    // or the depth bound refuses the call before anything is removed.
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
    const deleteDepth = async Files => {
        plantZone();
        fs.mkdirSync(path.join(zone, "d1", "d2", "d3", "d4", "d5"), { recursive: true });
        try {
            await expectRun("delete-depth", make(Files), "files.delete", { path: zone }, "failed",
                /is deeper than 3 levels; nothing was removed\./, zoneIntact);
        } finally { fs.rmSync(zone, { recursive: true, force: true }); }
    };
    await deleteDepth(require(file));
    // An entry replaced between the walk and its removal stops the removal.
    const deleteInode = async Files => {
        plantZone();
        let armed = true;
        let pending;
        try {
            fsFault("unlinkSync", (original, target, ...rest) => {
                if (armed) {
                    armed = false;
                    const other = path.basename(target) === "one" ? path.join(zone, "two") : path.join(zone, "a", "one");
                    original(other);
                    fs.writeFileSync(other, "replaced");
                }
                return original(target, ...rest);
            }, () => { pending = make(Files).run("files.delete", { path: zone }); });
            const answer = await pending;
            assert.equal(answer.outcome, "failed");
            assert.match(answer.content, /^Removed \d of 4 entries under .*, then stopped: Refused: path-changed for /);
            assert.equal(fs.existsSync(zone), true);
            cases++;
        } finally { fs.rmSync(zone, { recursive: true, force: true }); }
    };
    await deleteInode(require(file));

    // A call made while no snapshot builds is refused with its cause.
    const brokenSnapshot = async Files => {
        const answer = await make(Files, () => { throw new Error("jarvis: paths=home"); }).run("files.read", { path: path.join(t, "notes.txt") });
        assert.deepEqual(answer, { outcome: "failed", content: "The protected path list could not be built: jarvis: paths=home." });
        cases++;
    };
    await brokenSnapshot(require(file));

    // Registration: at once and unconditionally; a later build serves calls.
    const registered = async Files => {
        const records = [];
        const router = { register: (id, record) => records.push([id, record]) };
        let builds = true;
        Files.install({ router, denied: () => { if (!builds) throw new Error("jarvis: paths=home"); return fresh(); }, bounds: BOUNDS, clock });
        builds = false;
        const second = [];
        Files.install({ router: { register: (id, record) => second.push(id) },
            denied: () => { throw new Error("jarvis: paths=home"); }, bounds: BOUNDS, clock });
        assert.deepEqual(second, ["files"], "a failed build at install still registers");
        assert.deepEqual(records.map(([id, record]) => [id, record.commands, record.cancellable, record.timeoutMs]), [["files", [], false, 1100]]);
        const start = args => new Promise(resolve => records[0][1].start(Tools.refine({ id: "files.read", args }).call, resolve));
        assert.equal((await start({ path: path.join(t, "notes.txt") })).outcome, "failed");
        builds = true;
        assert.equal((await start({ path: path.join(t, "notes.txt") })).outcome, "completed");
        cases++;
    };
    await registered(require(file));

    let controls = 0;
    async function control(name, edits, check, target = file, consumer = "Files.js") {
        await mutant(target, name, edits, undefined, async (module, folder) => { await check(module, folder); }, consumer);
        controls++;
    }
    const credentialRead = Files => deniedRow(Files, deniedPaths[0], "files.read", { path: deniedPaths[0][1] });
    await control("rejudge", [["const judged = snapshot.inspectPaths(refined.paths.map(([field, role]) => [call.args[field], role]));",
        "const judged = { kind: \"paths\", paths: refined.paths.map(([field]) => ({ kind: \"path\", path: call.args[field], exists: true })) };"]],
        credentialRead);
    await control("snapshot-failure", [["throw failed(\"The protected path list could not be built: \"", "throw new Error(\"The protected path list could not be built: \""]],
        brokenSnapshot);
    await control("move-landing", [["if (landsNamed(source.path, destination.path))", "if (false && landsNamed(source.path, destination.path))"]],
        (Files, folder) => landing(Files, require(path.join(folder, "Denied.js"))), path.join(backend, "Denied.js"));
    await control("dotfile-link-target", [["if (accountLinkTargets().some(", "if (false && accountLinkTargets().some("]],
        (Files, folder) => dotfileTarget(Files, require(path.join(folder, "Denied.js"))), path.join(backend, "Denied.js"));
    await control("walk-nofollow", [["O_RDONLY | O_DIRECTORY | O_NOFOLLOW); }", "O_RDONLY | O_DIRECTORY); }"]], walkRace,
        path.join(backend, "Anchored.js"));
    await control("final-nofollow", [["return fs.openSync(Anchored.child(parent, name), flags | O_NOFOLLOW);", "return fs.openSync(Anchored.child(parent, name), flags);"]], finalRace);
    await control("anchored-parent", [["const opened = Anchored.directory(path.dirname(file));",
        "const opened = { kind: \"directory\", fd: fs.openSync(path.dirname(file), O_RDONLY | O_DIRECTORY) };"]], readSwapped);
    await control("final-link", [["if (stat === null || stat.isSymbolicLink()) throw changed(target.path);\n            // A device",
        "if (stat === null) throw changed(target.path);\n            // A device"]], finalAfterJudge);
    await control("list-link", [["if (stat === null || stat.isSymbolicLink()) throw changed(target.path);\n            if (!stat.isDirectory())",
        "if (stat === null) throw changed(target.path);\n            if (!stat.isDirectory())"]], listSwapped);
    await control("list-held-folder", [["folder = fs.opendirSync(Anchored.child(fd, \".\"));", "folder = fs.opendirSync(target.path);"]], listRace);
    await control("list-no-child", [["const child = entry(fd, item.name);",
        "const child = entry(fd, item.name); if (child && child.isFile()) fs.readFileSync(Anchored.child(fd, item.name), \"utf8\");"]],
        listOpens);
    await control("search-anchored-root", [["const opened = Anchored.directory(target.path);",
        "const opened = { kind: \"directory\", fd: fs.openSync(target.path, O_RDONLY | O_DIRECTORY) };"]], searchSwapped);
    await control("search-lstat", [["try { stat = fs.lstatSync(Anchored.child(handle.fd, item.name)); }",
        "try { stat = fs.statSync(Anchored.child(handle.fd, item.name)); }"]], searchHappy);
    await control("search-file-nofollow", [["try { fd = fs.openSync(Anchored.child(folder, name), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY); }",
        "try { fd = fs.openSync(Anchored.child(folder, name), O_RDONLY | O_NONBLOCK | O_NOCTTY); }"]], fileRace);
    await control("search-folder-nofollow", [["try { fd = fs.openSync(Anchored.child(item.parent.fd, item.name), O_RDONLY | O_DIRECTORY | O_NOFOLLOW); }",
        "try { fd = fs.openSync(Anchored.child(item.parent.fd, item.name), O_RDONLY | O_DIRECTORY); }"]], folderRace);
    await control("search-child-judge", [["if (snapshot.inspect(child, \"read\").kind !== \"path\")", "if (false && snapshot.inspect(child, \"read\").kind !== \"path\")"]], protectedChild);
    await control("binary", [["if (bytes.includes(0)) return null;", "if (false) return null;"]], binaryRead);
    await control("utf8", [["new TextDecoder(\"utf-8\", { fatal: true })", "new TextDecoder(\"utf-8\", { fatal: false })"]], latinRead);
    await control("read-ceiling", [["if (stat.size > bounds.readBytes)\n", "if (false)\n"]], ceilingRead);
    await control("read-nonblock", [["const fd = openIn(parent, name, target.path, O_RDONLY | O_NONBLOCK | O_NOCTTY);",
        "const fd = openIn(parent, name, target.path, O_RDONLY | O_NOCTTY);"]], nonBlocking);
    for (const [name, needle, replacement] of [
        ["entries", "if (++visited > bounds.searchEntries)", "if (false)"],
        ["bytes", "if (bytes + stat.size > bounds.searchBytes)", "if (false)"],
        ["matches", "if (matches.length === bounds.searchMatches)", "if (false)"],
        ["depth", "if (depth === bounds.searchDepth) skipped.deep++;\n                else", ""],
        ["lines", "return plain.length > bounds.lineChars ?", "return false ?"],
        ["time", "if (cut === null && clock.now() - started >= bounds.searchMs) cut = \"time\";", ""]
    ]) {
        await control("search-" + name, [[needle, replacement]], async Files => {
            try { await searchBounds[name](Files); } finally { clock.now = () => clockNow; }
        });
    }
    await control("search-slice", [["if (count === bounds.searchSliceEntries || clock.now() - slice >= bounds.searchSliceMs) break;",
        "if (false) break;"]], yields);
    await control("search-close", [["if (closed) { end(", "if (false) { end("]], closing);
    await control("start-after-close", [["if (closed) throw failed(\"The file tools are closed.\");", ""]], closing);
    await control("no-replace", [["try { fs.linkSync(Anchored.child(parent, temporary), Anchored.child(parent, name)); }",
        "try { fs.renameSync(Anchored.child(parent, temporary), Anchored.child(parent, name)); }"]], appeared);
    await control("keep-mode", [["if (mode !== null) fs.fchmodSync(fd, mode);", ""]], async Files => {
        plant();
        fs.chmodSync(path.join(t, "notes.txt"), 0o640);
        await make(Files).run("files.write", { path: path.join(t, "notes.txt"), text: "replaced" });
        keepsMode();
    });
    await control("write-recheck", [["if (now === null || !now.isFile()) throw changed(target.path);", ""]], writeRecheck);
    await control("write-read-back", [["if (seen === null || !seen.equals(bytes) ||", "if (seen === null ||"]], writeReadBack);
    await control("move-read-back", [["if (entry(source, sourceName) === null && entry(folder, name) !== null)", "if (true)"]], moveReadBack);
    await control("delete-read-back", [["if (present) return", "if (false) return"]], deleteReadBack);
    await control("move-destination", [["if (!to.exists && entry(folder, name) !== null)", "if (false)"]], moveAppeared);
    await control("move-same-entry", [["if (from.path === to.path) throw failed(", "if (false) throw failed("]], sameEntry);
    await control("other-executor", [["if (refined.kind !== \"call\" || refined.executor !== \"files\")", "if (refined.kind !== \"call\")"]], otherExecutor);
    await control("delete-walk-first", [["const tree = walk(parent, name, target.path, snapshot, 0, count);\n                    total += count.value;\n                    prune(parent, name, target.path, tree, removed);",
        "fs.rmSync(Anchored.child(parent, name), { recursive: true }); removed.value++;"]], deleteProtected);
    await control("delete-child-judge", [["if (verdict.kind !== \"path\") throw failed(\"Refused: \"", "if (false) throw failed(\"Refused: \""]], deleteProtected);
    await control("delete-bound", [["if (++count.value > bounds.deleteEntries)", "if (false)"]], deleteBound);
    await control("delete-depth", [["if (depth > bounds.deleteDepth) throw failed(", "if (false) throw failed("]], deleteDepth);
    await control("delete-inode", [["if (now === null || now.ino !== item.ino || now.isDirectory())", "if (now === null || now.isDirectory())"]], deleteInode);
    await control("registration", [["const files = create(options);\n    router.register(",
        "const files = create(options);\n    try { options.denied(); } catch { return { close: files.close }; }\n    router.register("]], registered);
    await control("exdev", [["if (error.code === \"EXDEV\") throw failed(", "if (false) throw failed("]], exdevMove);

    // End to end: the daemon's own Denied producer, for every root it reads,
    // through its real router, Policy, audit and this executor, driven by
    // the test-only tool driver.
    plant();
    const daemonExplicit = path.join(home, "explicit-acct");
    const daemonHand = path.join(home, "hand-acct");
    for (const folder of [daemonExplicit, daemonHand]) {
        fs.mkdirSync(folder);
        fs.writeFileSync(path.join(folder, "notes"), "beta protected secret\n");
    }
    // The daemon's install root is the plugin directory it runs from: a
    // disposable copy beside HOME, so a read inside it is outside HOME
    // unless the producer protects it.
    async function daemon(name, edit) {
        const folder = path.join(process.env.JARVIS_TEST_ROOT, "plugin-" + name);
        fs.mkdirSync(folder);
        fs.writeFileSync(path.join(folder, "VERSION"), "beta protected secret\n");
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
        const state = path.join(process.env.JARVIS_TEST_ROOT, name + "-state");
        fs.mkdirSync(state);
        fs.writeFileSync(path.join(state, "accounts.json"), JSON.stringify([{ provider: "codex", directory: daemonHand, label: "hand" }]));
        const env = { PATH: process.env.PATH, HOME: process.env.HOME, LANG: "C.UTF-8", CLAUDE_CONFIG_DIR: daemonExplicit };
        for (const variable of ["XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_RUNTIME_DIR"]) env[variable] = process.env[variable];
        const child = cp.spawn(process.execPath, [daemonFile, "--tree", tree], { env, stdio: ["pipe", "ignore", "pipe"] });
        let stderr = "";
        child.stderr.on("data", data => { stderr += data; });
        const closed = once(child, "close");
        // Bounds a daemon that never answers, not a latency budget.
        const timeout = setTimeout(() => child.kill("SIGKILL"), 20000);
        const outcomes = {};
        const reads = [["ordinary", path.join(t, "notes.txt")], ["account", path.join(home, ".claude-team", "notes")],
            ["explicit", path.join(daemonExplicit, "notes")], ["hand", path.join(daemonHand, "notes")],
            ["config", path.join(roots.config, "vgs", "shell.json")], ["install", path.join(folder, "VERSION")]];
        try {
            child.stdin.write(JSON.stringify({ v: 1, type: "hello", gen: 0, revision: "a".repeat(64), locked: false,
                settings: { mode: "hold", microphone: "", speaker: "", brain: "", taskTerminal: "auto", cloudVision: "ask", privateWindows: "" },
                directories: { state, data: path.join(process.env.JARVIS_TEST_ROOT, name + "-data"),
                    runtime: path.join(process.env.JARVIS_TEST_ROOT, name + "-run") },
                keys: { talk: "SUPER+code:108", mute: "SUPER+SHIFT+code:108", stop: "SUPER+ALT+PERIOD" } }) + "\n");
            for (const [id, target] of reads) {
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
    const refusal = (outcome, reason) => {
        assert.equal(outcome.outcome, "cancelled", outcome.content);
        assert.deepEqual(JSON.parse(outcome.content), { kind: "refuse", reason });
    };
    const production = await daemon("production");
    assert.deepEqual([production.ordinary.outcome, production.ordinary.content], ["completed", "alpha\nBeta line\n"]);
    for (const id of ["account", "explicit", "hand", "config", "install"]) refusal(production[id], "protected-path");
    cases++;
    // Each control breaks one root of the producer; the row that root
    // protects answers otherwise.
    const noProducer = await daemon("no-producer", ["get denied() { return deniedOrNull(); } }),", "denied: null }),"]);
    refusal(noProducer.ordinary, "path-context");
    controls++;
    const noAccountRoots = await daemon("no-account-roots",
        ["accountRoots: accountRoots(context.directories.state, process.env) });", "accountRoots: [] });"]);
    for (const id of ["explicit", "hand"]) assert.equal(noAccountRoots[id].outcome, "completed", id + " control turns red");
    controls++;
    const defaultConfig = await daemon("default-config",
        ["config: process.env.XDG_CONFIG_HOME || path.join(home, \".config\"),", "config: path.join(home, \".config\"),"]);
    refusal(defaultConfig.config, "outside-home");
    controls++;
    const noInstall = await daemon("no-install", ["install: path.dirname(__dirname),", "install: path.join(home, \"absent-install\"),"]);
    refusal(noInstall.install, "outside-home");
    controls++;

    console.log("test-jarvis-files: ok cases=" + cases + " controls=" + controls);
});
