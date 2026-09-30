#!/usr/bin/env node
// Real files and audit admission callbacks inside J09. No real executor runs.
"use strict";
const { assert, fs, path, tree, world, mutant, fsFault } = require("./fixtures/jarvis/policy.js");
const file = path.join(tree, "shell/plugins/vgs.jarvis/backend/Audit.js");
const Audit = require(file);
const RedactFile = path.join(tree, "shell/plugins/vgs.jarvis/backend/Redact.js");

world(() => {
    const base = process.env.XDG_STATE_HOME;
    const today = Date.parse("2026-09-30T12:00:00.000Z");
    let serial = 0;
    function state() { return path.join(base, "audit-" + ++serial); }
    const event = { kind: "action", gen: 2, op: 3, tool: "files.write",
        args: { path: "/synthetic", text: "planted-arbitrary-credential" },
        effect: "persistent", decision: "allow", confirmed: "none", outcome: "pending" };
    function records(root, date = "2026-09-30") {
        const content = fs.readFileSync(path.join(root, "audit", date + ".jsonl"), "utf8");
        assert.equal(content.endsWith("\n"), true);
        const lines = content.trimEnd().split("\n");
        for (const line of lines) assert.ok(Buffer.byteLength(line + "\n") <= 4096, "line including LF bounded");
        return lines.map(line => JSON.parse(line));
    }
    function withWriter(logic, options, check) {
        const writer = logic.create({ state: state(), now: () => today, ...options });
        try { check(writer); } finally { writer.close(); }
    }
    function checkOrder(logic) {
        const root = state();
        withWriter(logic, { state: root }, writer => {
            let starts = 0;
            const answer = writer.before(event, () => {
                starts++;
                assert.deepEqual(records(root), [{
                    time: "2026-09-30T12:00:00.000Z", kind: "action", gen: 2, op: 3,
                    tool: "files.write", args: { path: "[redacted]", text: "[redacted]" },
                    effect: "persistent", decision: "allow", confirmed: "none", outcome: "pending"
                }], "decision persisted before callback");
                return "executor-result-private";
            });
            assert.equal(answer.kind, "started");
            assert.equal(answer.value, "executor-result-private");
            assert.equal(starts, 1);
        });
    }
    function checkRefusal(logic) {
        const root = state();
        fs.writeFileSync(root, "stand-in for an unwritable state directory");
        withWriter(logic, { state: root }, writer => {
            let starts = 0;
            const result = writer.before(event, () => { starts++; });
            assert.equal(starts, 0, "failed write refuses the action");
            assert.deepEqual(result, { kind: "refuse", reason: "audit-write", cause: "directory-type" });
            for (const kind of ["stop", "mute", "teardown"]) {
                const shutdown = writer.cleanup(kind, () => { starts++; });
                assert.equal(shutdown.kind, "started");
                assert.equal(shutdown.audit.kind, "refuse");
            }
            assert.equal(starts, 3, "all privacy shutdown paths remain available");
        });
    }
    function checkPrivacy(logic) {
        const root = state();
        withWriter(logic, { state: root }, writer => {
            assert.deepEqual(writer.record(event), { kind: "recorded" });
            const content = fs.readFileSync(path.join(root, "audit", "2026-09-30.jsonl"), "utf8");
            assert.equal(content.includes("planted-arbitrary-credential"), false, "planted key absent on disk");
        });
    }
    function checkModes(logic) {
        const root = state();
        fs.mkdirSync(path.join(root, "audit"), { recursive: true, mode: 0o755 });
        const log = path.join(root, "audit", "2026-09-30.jsonl");
        fs.writeFileSync(log, "", { mode: 0o644 });
        fs.chmodSync(log, 0o644);
        fs.chmodSync(root, 0o755);
        fs.chmodSync(path.dirname(log), 0o755);
        withWriter(logic, { state: root }, writer => {
            assert.equal(writer.record(event).kind, "recorded");
            assert.equal(fs.statSync(log).mode & 0o777, 0o600, "owner-only existing file");
            for (const dir of [root, path.dirname(log)])
                assert.equal(fs.statSync(dir).mode & 0o777, 0o700, "owner-only directory");
        });
    }
    function old(root, date, bytes = 0) {
        fs.mkdirSync(path.join(root, "audit"), { recursive: true });
        const file = path.join(root, "audit", date + ".jsonl");
        // Sparse data exercises the actual store bound without a large buffer.
        const fd = fs.openSync(file, "w", 0o600);
        try { fs.ftruncateSync(fd, bytes); } finally { fs.closeSync(fd); }
        return file;
    }
    function checkAge(logic) {
        const root = state();
        const expired = old(root, "2026-08-31");
        const retained = old(root, "2026-09-01");
        withWriter(logic, { state: root }, writer => {
            assert.equal(writer.record(event).kind, "recorded");
            assert.equal(fs.existsSync(expired), false, "default 30 days removes cutoff date");
            assert.equal(fs.existsSync(retained), true, "day inside retention survives");
            assert.deepEqual(records(root)[0].args, { date: "2026-08-31", bytes: 0, reason: "age" });
            assert.equal(records(root)[0].outcome, "completed");
        });
    }
    function checkSize(logic) {
        const root = state();
        const oldest = old(root, "2026-09-01", 64 * 1024 * 1024 - 4096);
        const newer = old(root, "2026-09-02");
        withWriter(logic, { state: root }, writer => {
            fsFault("unlinkSync", (original, victim) => {
                assert.equal(victim, oldest, "oldest file removed first");
                return original(victim);
            }, () => assert.equal(writer.record(event).kind, "recorded"));
            assert.equal(fs.existsSync(oldest), false, "actual 64 MiB ceiling removes oldest first");
            assert.equal(fs.existsSync(newer), true);
            assert.deepEqual(records(root)[0].args, { date: "2026-09-01", bytes: 64 * 1024 * 1024 - 4096, reason: "size" });
            const bytes = fs.readdirSync(path.join(root, "audit"))
                .reduce((sum, name) => sum + fs.statSync(path.join(root, "audit", name)).size, 0);
            assert.ok(bytes <= 64 * 1024 * 1024);
        });
    }
    checkOrder(Audit); checkRefusal(Audit); checkPrivacy(Audit); checkModes(Audit); checkAge(Audit); checkSize(Audit);

    const root = state();
    let at = today;
    withWriter(Audit, { state: root, now: () => at }, writer => {
        assert.throws(() => Audit.create({ state: root }), { code: "writer-owned" });
        for (const decision of ["allow", "confirm", "refuse"])
            assert.equal(writer.record({ ...event, decision, confirmed: decision === "confirm" ? "physical" : "none" }).kind, "recorded");
        for (const decision of ["send", "ask", "withhold"]) {
            const release = { ...event, kind: "release", tool: "release", decision, effect: "external",
                args: { labels: ["file"], recipients: [{ origin: "https://user:private@example.test", key: "planted" }], audio: Buffer.from("private") } };
            assert.equal(writer.record(release).kind, "recorded");
        }
        for (const outcome of ["completed", "failed", "unknown", "cancelled"])
            assert.equal(writer.record({ ...event, outcome }).kind, "recorded");
        for (const entry of records(root).filter(row => row.kind === "release"))
            assert.deepEqual(entry.args, { labels: "[redacted]", recipients: "[redacted]" });
        at += 24 * 60 * 60 * 1000;
        assert.equal(writer.record({ ...event, tool: "secret-key-as-tool-name", args: { password: "secret" } }).kind, "recorded");
        assert.equal(records(root, "2026-10-01")[0].tool, "unknown");
        writer.close();
        assert.deepEqual(writer.record(event), { kind: "refuse", reason: "audit-write", cause: "writer-closed" });
    });
    withWriter(Audit, { state: root }, writer => assert.equal(writer.record(event).kind, "recorded"));
    for (const auditDays of [0, 366, 1.5, "30", null])
        assert.throws(() => Audit.create({ state: state(), auditDays }), { code: "audit-days" });
    for (const auditDays of [1, 365])
        withWriter(Audit, { auditDays }, writer => assert.equal(writer.record(event).kind, "recorded"));
    for (const [field, value, cause] of [
        ["kind", "unknown", "decision"], ["gen", -1, "identity"], ["op", 0, "identity"],
        ["effect", "unknown", "effect"], ["decision", "unknown", "decision"],
        ["confirmed", "model", "confirmation"], ["outcome", "private body", "outcome"]
    ]) withWriter(Audit, {}, writer => assert.deepEqual(writer.record({ ...event, [field]: value }),
        { kind: "refuse", reason: "audit-write", cause }));

    // Links, hard links, incomplete writes and unexpected entries refuse
    // rather than writing elsewhere or deleting files the audit does not own.
    function checkUnsafe(logic, setup, cause) {
        const root = state();
        const target = path.join(base, "untouched-" + ++serial);
        fs.writeFileSync(target, "private scratch content");
        setup(root, target);
        withWriter(logic, { state: root }, writer => {
            let starts = 0;
            const result = writer.before(event, () => starts++);
            assert.equal(starts, 0);
            assert.equal(result.cause, cause);
            assert.equal(fs.readFileSync(target, "utf8"), "private scratch content");
        });
    }
    const hazards = [
        ["state link", (root, target) => fs.symlinkSync(path.dirname(target), root), "directory-type"],
        ["audit link", (root, target) => { fs.mkdirSync(root); fs.symlinkSync(path.dirname(target), path.join(root, "audit")); }, "directory-type"],
        ["daily link", (root, target) => { old(root, "2026-09-29"); fs.symlinkSync(target, path.join(root, "audit", "2026-09-30.jsonl")); }, "file-type"],
        ["hard link", (root, target) => { old(root, "2026-09-29"); fs.linkSync(target, path.join(root, "audit", "2026-09-30.jsonl")); }, "file-type"],
        ["incomplete", root => { const log = old(root, "2026-09-30"); fs.writeFileSync(log, '{"partial":'); }, "partial-line"],
        ["unknown entry", root => { fs.mkdirSync(path.join(root, "audit"), { recursive: true }); fs.writeFileSync(path.join(root, "audit", "other"), ""); }, "entry-name"]
    ];
    for (const [, setup, cause] of hazards) checkUnsafe(Audit, setup, cause);

    function checkFault(logic, method, replacement, cause) {
        const root = state();
        withWriter(logic, { state: root }, writer => {
            let starts = 0;
            fsFault(method, replacement, () => {
                const result = writer.before(event, () => starts++);
                assert.equal(starts, 0, method + " failure must refuse callback");
                assert.equal(result.cause, cause);
            });
        });
    }
    const ioError = code => () => { const error = new Error("private error body"); error.code = code; throw error; };
    checkFault(Audit, "writeSync", ioError("ENOSPC"), "ENOSPC");
    checkFault(Audit, "fsyncSync", ioError("EIO"), "EIO");
    checkFault(Audit, "fchmodSync", ioError("EPERM"), "EPERM");
    function checkShort(logic) {
        const root = state();
        withWriter(logic, { state: root }, writer => {
            let starts = 0;
            fsFault("writeSync", (original, fd, buffer) => original(fd, buffer, 0, 2), () => {
                const result = writer.before(event, () => starts++);
                assert.equal(starts, 0);
                assert.equal(result.cause, "short-write");
            });
            assert.equal(fs.statSync(path.join(root, "audit", "2026-09-30.jsonl")).size, 0, "partial append rolled back");
            assert.equal(writer.record(event).kind, "recorded", "retry after short write produces valid JSON");
            assert.equal(records(root).length, 1);
        });
    }
    checkShort(Audit);
    function checkSingle(logic) {
        const root = state();
        withWriter(logic, { state: root }, () => {
            let extra;
            try { assert.throws(() => { extra = logic.create({ state: root }); }, { code: "writer-owned" }); }
            finally { if (extra) extra.close(); }
        });
    }
    function checkClosed(logic) {
        withWriter(logic, {}, writer => {
            writer.close();
            assert.equal(writer.before(event, () => assert.fail("closed owner started action")).cause, "writer-closed");
        });
    }
    function checkPruneLog(logic) {
        const root = state();
        old(root, "2026-08-31");
        withWriter(logic, { state: root }, writer => {
            assert.equal(writer.record(event).kind, "recorded");
            assert.deepEqual(records(root).map(row => row.kind), ["prune", "action"]);
        });
    }
    function checkField(logic, field, value, cause) {
        withWriter(logic, {}, writer => assert.deepEqual(writer.record({ ...event, [field]: value }),
            { kind: "refuse", reason: "audit-write", cause }));
    }
    function checkDays(logic, days) {
        let writer;
        try { assert.throws(() => { writer = logic.create({ state: state(), auditDays: days }); }, { code: "audit-days" }); }
        finally { if (writer) writer.close(); }
    }
    function checkClock(logic) {
        withWriter(logic, { now: () => -1 }, writer => assert.equal(writer.record(event).cause, "clock-value"));
    }
    function checkUnknownTool(logic) {
        const root = state();
        withWriter(logic, { state: root }, writer => {
            assert.equal(writer.record({ ...event, tool: "planted-key-as-tool" }).kind, "recorded");
            assert.equal(records(root)[0].tool, "unknown");
        });
    }
    function checkUnlinkFailure(logic) {
        const root = state();
        old(root, "2026-08-31");
        withWriter(logic, { state: root }, writer => {
            let starts = 0;
            fsFault("unlinkSync", ioError("EACCES"), () => {
                assert.equal(writer.before(event, () => starts++).cause, "EACCES");
                assert.equal(starts, 0);
            });
        });
    }
    checkUnlinkFailure(Audit); checkClock(Audit); checkUnknownTool(Audit);
    for (const invalid of ["relative", "/", base + "/x/../y", null])
        assert.throws(() => Audit.create({ state: invalid }), { code: "state-path" });
    withWriter(Audit, { now: () => NaN }, writer => assert.equal(writer.record(event).kind, "refuse"));
    const invalidDate = (root) => { old(root, "2026-02-30"); };
    checkUnsafe(Audit, invalidDate, "entry-date");
    const controls = [
        ["write refusal", 'if (audit.kind === "refuse") return audit;', 'if (audit.kind === "refuse") start();', checkRefusal],
        ["write syscall", "const written = fs.writeSync(fd, line, 0, line.length);", "const written = line.length;",
            logic => checkFault(logic, "writeSync", ioError("ENOSPC"), "ENOSPC")],
        ["file flush", "            fs.fsyncSync(fd);\n        } finally", "            /* omitted file flush */\n        } finally",
            logic => {
                // Directory flushes cannot stand in for the file flush.
                checkFault(logic, "fsyncSync", (original, fd) => {
                    if (fs.fstatSync(fd).isFile()) ioError("EIO")();
                    return original(fd);
                }, "EIO");
            }],
        ["short write refusal", 'if (written !== line.length) {', 'if (false && written !== line.length) {', checkShort],
        ["short write rollback", "fs.ftruncateSync(fd, stat.size);", "/* omitted rollback */", checkShort],
        ["file permissions", "fs.fchmodSync(fd, 0o600);", "/* omitted private file mode */", checkModes],
        ["directory permissions", "fs.chmodSync(directory, 0o700);", "/* omitted private directory mode */", checkModes],
        ["retention age", "date <= today - auditDays * DAY_MS", "false && date <= today - auditDays * DAY_MS", checkAge],
        ["retention size", "inventory.total + line.length + LINE_BYTES > STORE_BYTES", "false && inventory.total + line.length + LINE_BYTES > STORE_BYTES", checkSize],
        ["oldest first", "date < oldest.date", "date > oldest.date", checkSize],
        ["removal record", "append(stamp.file, encode({ time: stamp.time, kind: \"prune\"", "false && append(stamp.file, encode({ time: stamp.time, kind: \"prune\"", checkPruneLog],
        ["one writer", 'if (owners.has(state)) fail("writer-owned");', 'if (false && owners.has(state)) fail("writer-owned");', checkSingle],
        ["closed owner", 'if (lifetime !== "open") fail("writer-closed");', 'if (false && lifetime !== "open") fail("writer-closed");', checkClosed],
        ["partial line", 'tail[0] !== 10', 'false && tail[0] !== 10',
            logic => checkUnsafe(logic, hazards[4][1], "partial-line")],
        ["state links", 'if (!fs.lstatSync(current).isDirectory()) fail("directory-type");', 'if (!fs.statSync(current).isDirectory()) fail("directory-type");',
            logic => checkUnsafe(logic, hazards[0][1], "directory-type")],
        ["file links", 'if (!stat.isFile() || stat.nlink !== 1 || stat.uid !== process.getuid()) fail("file-type");',
            'if (!stat.isFile() || stat.uid !== process.getuid()) fail("file-type");',
            logic => checkUnsafe(logic, hazards[3][1], "file-type")],
        ["removal failure", "fs.unlinkSync(victim.file);", "/* removal omitted */",
            logic => {
                // Reject the first wrong operation before a pruning loop can
                // repeat. The filesystem stand-in is private to this case.
                const root = state();
                old(root, "2026-08-31");
                withWriter(logic, { state: root }, writer => {
                    let removals = 0;
                    fsFault("unlinkSync", () => { removals++; ioError("EACCES")(); }, () => {
                        fsFault("writeSync", (original, ...args) => {
                            assert.equal(removals, 1, "failed removal must prevent a following write");
                            return original(...args);
                        }, () => assert.equal(writer.record(event).cause, "EACCES"));
                    });
                });
            }],
        ["auditDays floor", "auditDays < 1", "false && auditDays < 1", logic => checkDays(logic, 0)],
        ["auditDays ceiling", "auditDays > 365", "false && auditDays > 365", logic => checkDays(logic, 366)],
        ["auditDays integer", "!Number.isInteger(auditDays)", "false && !Number.isInteger(auditDays)", logic => checkDays(logic, 1.5)],
        ["clock value", "ms < 0", "false && ms < 0", checkClock],
        ["identity", "if (!Number.isSafeInteger(gen) || gen < 0 || !Number.isSafeInteger(op) || op < 1)",
            "if (false && (!Number.isSafeInteger(gen) || gen < 0 || !Number.isSafeInteger(op) || op < 1))",
            logic => checkField(logic, "op", 0, "identity")],
        ["decision enum", "!decisions.includes(decision)", "false && !decisions.includes(decision)",
            logic => checkField(logic, "decision", "planted-key", "decision")],
        ["effect enum", 'if (effect !== null && !effects.includes(effect))', 'if (false && effect !== null && !effects.includes(effect))',
            logic => checkField(logic, "effect", "planted-key", "effect")],
        ["confirmation enum", 'if (!["none", "physical", "voice"].includes(confirmed))', 'if (false && !["none", "physical", "voice"].includes(confirmed))',
            logic => checkField(logic, "confirmed", "planted-key", "confirmation")],
        ["outcome enum", 'if (!["pending", "completed", "failed", "unknown", "cancelled"].includes(outcome))', 'if (false && !["pending", "completed", "failed", "unknown", "cancelled"].includes(outcome))',
            logic => checkField(logic, "outcome", "planted-key", "outcome")],
        ["tool identity", 'Object.hasOwn(Tools.TABLE, tool) ? tool : "unknown"', 'tool', checkUnknownTool],
        ["invalid stored date", 'new Date(time).toISOString().slice(0, 10) !== date', 'false && new Date(time).toISOString().slice(0, 10) !== date',
            logic => checkUnsafe(logic, invalidDate, "entry-date")]
    ];
    for (const [name, needle, replacement, check] of controls)
        mutant(file, name, needle, replacement, check);
    // Start before record, but retain both calls and the record's matched text.
    mutant(file, "decision before action", "const audit = record(event);",
        "start(); const audit = record(event);", logic => {
            const root = state();
            withWriter(logic, { state: root }, writer => {
                const persisted = [];
                writer.before(event, () => { persisted.push(fs.existsSync(path.join(root, "audit", "2026-09-30.jsonl"))); });
                assert.deepEqual(persisted, [true], "one action saw a persisted decision");
            });
        });
    mutant(file, "disk redaction", "args: Redact.argumentsFor(kind, tool, event.args)", "args: event.args", checkPrivacy);
    mutant(RedactFile, "redaction reaches writer", 'result[field] = "[redacted]";', "result[field] = args[field];", checkPrivacy, "Audit.js");
    // The fixed metadata and argument envelope fit the line bound by design.
    // Plant an enlarged emitted envelope to prove the assertion detects it.
    mutant(file, "bounded emitted line", "const line = Buffer.from(JSON.stringify(record) + \"\\n\");\n    if (line.length > LINE_BYTES)",
        "const line = Buffer.from(JSON.stringify({ ...record, padding: 'x'.repeat(4096) }) + \"\\n\");\n    if (false && line.length > LINE_BYTES)",
        checkOrder);
    for (const kind of ["stop", "mute", "teardown"])
        mutant(file, "privacy shutdown " + kind, 'return { kind: "started", audit, value: start() };\n        },\n        close()',
            'if (kind === "' + kind + '" && audit.kind === "refuse") return audit;\n            return { kind: "started", audit, value: start() };\n        },\n        close()', checkRefusal);
    console.log("jarvis-audit: acceptance=passed controls=" + (controls.length + 7)
        + " planted-keys=absent failed-write=refused");
});
