#!/usr/bin/env node
// The optional Slack photo helper, shell/plugins/vgs.notifications/
// slack-photos.js, with a stub secret-tool and a stub HTTP server on
// 127.0.0.1. It proves the token is read from libsecret, is not passed on
// argv or logs, no network starts without a token, Slack API data is reduced
// to synthetic users and team icon fields, fresh cache data avoids another
// API call, and API failures are rate-limited.
"use strict";

const assert = require("node:assert/strict");
const childProcess = require("node:child_process");
const fs = require("node:fs");
const http = require("node:http");
const path = require("node:path");

const repo = path.join(__dirname, "..");
const helper = process.env.NOTIFICATIONS_SLACK_PHOTOS_HELPER || path.join(repo, "shell", "plugins", "vgs.notifications", "slack-photos.js");
const helperSource = path.join(repo, "shell", "plugins", "vgs.notifications", "slack-photos.js");
const scratch = path.join(repo, "tmp", "test-notifications-slack-photos-" + process.pid);
const token = "xoxp-test-token";
const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=", "base64");
const pngChanged = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==", "base64");
let secretToolPath = "";

function write(file, text) {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, text, { mode: 0o700 });
}

function resolveCommand(command, env) {
    for (const dir of String(env.PATH || "").split(path.delimiter)) {
        if (dir === "") continue;
        const candidate = path.join(dir, command);
        try {
            fs.accessSync(candidate, fs.constants.X_OK);
            if (fs.statSync(candidate).isFile()) return fs.realpathSync(candidate);
        } catch (_e) {
            // Keep looking.
        }
    }
    return "";
}

function assertSecretTool(env, mode) {
    const found = resolveCommand("secret-tool", env);
    if (mode === "absent") {
        assert.equal(found, "", "the missing-secret-tool case must not resolve a real secret-tool");
        return;
    }
    assert.equal(found, fs.realpathSync(secretToolPath), "tests must run only against the stub secret-tool");
}

function run(cache, env, secretToolMode) {
    assertSecretTool(env, secretToolMode || "stub");
    return new Promise(resolve => {
        const child = childProcess.spawn(process.execPath, [helper, "refresh", cache], { cwd: repo, env });
        let stdout = "";
        let stderr = "";
        child.stdout.setEncoding("utf8");
        child.stderr.setEncoding("utf8");
        child.stdout.on("data", chunk => { stdout += chunk; });
        child.stderr.on("data", chunk => { stderr += chunk; });
        child.on("close", status => resolve({ status, stdout, stderr }));
    });
}

async function runJson(cache, env, secretToolMode) {
    const result = await run(cache, env, secretToolMode);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stderr, "", "a successful helper prints no stderr");
    return JSON.parse(result.stdout);
}

async function withServer(handler, body) {
    const server = http.createServer(handler);
    await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
    try {
        return await body(server.address().port);
    } finally {
        await new Promise(resolve => server.close(resolve));
    }
}

fs.rmSync(scratch, { recursive: true, force: true });
fs.mkdirSync(scratch, { recursive: true });

async function main() {
    const bin = path.join(scratch, "bin");
    const emptyBin = path.join(scratch, "empty-bin");
    const secretLog = path.join(scratch, "secret-argv.log");
    secretToolPath = path.join(bin, "secret-tool");
    fs.mkdirSync(emptyBin, { recursive: true });
    write(secretToolPath, `#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >>"${secretLog}"
if [[ \${SECRET_TOOL_EMPTY:-} == 1 ]]; then exit 1; fi
printf '%s\\n' '${token}'
`);
    const baseEnv = Object.assign({}, process.env, {
        PATH: bin + path.delimiter + process.env.PATH,
        VGS_NOTIFICATIONS_SLACK_TEST: "1",
        VGS_NOTIFICATIONS_SLACK_TEST_SECRET_TOOL_DIR: bin
    });

    let touched = false;
    const absentCache = path.join(scratch, "absent-cache");
    const absent = await runJson(absentCache, Object.assign({}, baseEnv, { SECRET_TOOL_EMPTY: "1" }));
    assert.deepEqual(absent, { status: "absent" }, "no token returns no cache");
    assert.equal(touched, false, "no token starts no HTTP request");
    assert.equal(fs.existsSync(absentCache), false, "no token creates no cache directory");
    const missingSecretToolCache = path.join(scratch, "missing-secret-tool-cache");
    const missingSecretTool = await runJson(missingSecretToolCache, Object.assign({}, baseEnv, { PATH: emptyBin }), "absent");
    assert.deepEqual(missingSecretTool, { status: "absent" }, "missing secret-tool is the same as no token");
    assert.equal(fs.existsSync(missingSecretToolCache), false, "missing secret-tool creates no cache directory");

    await withServer((req, res) => {
        touched = true;
        if (req.url.startsWith("/api/team.info")) {
            assert.equal(req.headers.authorization, "Bearer " + token, "API calls carry the token in a header");
            res.setHeader("content-type", "application/json");
            res.end(JSON.stringify({ ok: true, team: { id: "T1", domain: "acme", name: "Acme Corp", icon: { image_68: `http://127.0.0.1:${req.socket.localPort}/images/team.png` } } }));
            return;
        }
        if (req.url.startsWith("/api/users.list")) {
            assert.equal(req.headers.authorization, "Bearer " + token, "API calls carry the token in a header");
            res.setHeader("content-type", "application/json");
            res.end(JSON.stringify({ ok: true, members: [
                { id: "U1", name: "ada", real_name: "Ada Lovelace", profile: { display_name: "Ada", real_name: "Ada Lovelace", image_48: `http://127.0.0.1:${req.socket.localPort}/images/ada.png` } },
                { id: "U2", name: "grace", real_name: "Grace Hopper", profile: { display_name: "Grace", real_name: "Grace Hopper", image_48: `http://127.0.0.1:${req.socket.localPort}/images/grace.png` } },
                { id: "U3", name: "mallory", real_name: "Mallory", profile: { display_name: "Mallory", image_48: "https://evil.example/mallory.png" } },
                { id: "../x", name: "bad", profile: { display_name: "Bad" } }
            ], response_metadata: { next_cursor: "" } }));
            return;
        }
        if (req.url.startsWith("/images/")) {
            res.setHeader("content-type", "image/png");
            res.end(png);
            return;
        }
        res.statusCode = 404;
        res.end("missing");
    }, async port => {
        const env = Object.assign({}, baseEnv, { VGS_NOTIFICATIONS_SLACK_API_BASE: `http://127.0.0.1:${port}/api` });
        const cache = path.join(scratch, "cache");
        const loaded = await runJson(cache, env);
        assert.equal(loaded.status, "loaded");
        assert.equal(loaded.downloadFailed, 0);
        assert.equal(loaded.teams.length, 1);
        assert.deepEqual(loaded.teams[0].names, ["acme", "Acme Corp"]);
        assert.equal(loaded.teams[0].users.length, 3, "only safe synthetic users are stored");
        assert.match(loaded.teams[0].icon, /^file:\/\/\/[^\s?#]+\.png\?v=[0-9a-f]{16}$/, "the workspace icon URL is versioned by content");
        assert.match(loaded.teams[0].users[0].photo, /^file:\/\/\/[^\s?#]+\.png\?v=[0-9a-f]{16}$/, "the photo URL is versioned by content");
        assert.equal(loaded.teams[0].users[2].photo, "", "untrusted image hosts are skipped");
        assert.equal(fs.existsSync(path.join(cache, "T1", "U1.png")), true, "a user photo is cached");
        assert.equal(fs.existsSync(path.join(cache, "T1", "workspace.png")), true, "the workspace icon is cached");
        const stored = fs.readFileSync(path.join(cache, "index.json"), "utf8");
        assert.equal(stored.includes(token), false, "the token is not stored");
        assert.equal(fs.readFileSync(secretLog, "utf8").includes(token), false, "the token is not passed to secret-tool on argv");
        const before = fs.readFileSync(secretLog, "utf8").split("\n").length;
        touched = false;
        const fresh = await runJson(cache, env);
        assert.equal(fresh.status, "loaded", "fresh cache is reused");
        assert.equal(touched, false, "fresh cache avoids another API call");
        assert.ok(fs.readFileSync(secretLog, "utf8").split("\n").length > before, "fresh cache still requires a present token");
    });

    const cache = path.join(scratch, "cache");
    const indexFile = path.join(cache, "index.json");
    const oldDaily = new Date(Date.now() - 25 * 60 * 60 * 1000);
    const oldRetry = new Date(Date.now() - 16 * 60 * 1000);
    const first = JSON.parse(fs.readFileSync(indexFile, "utf8"));
    const firstIcon = first.teams[0].icon;
    const firstPhoto = first.teams[0].users[0].photo;
    async function refreshWithImageBytes(imageBytes) {
        fs.utimesSync(indexFile, oldDaily, oldDaily);
        return withServer((req, res) => {
            if (req.url.startsWith("/api/team.info")) {
                assert.equal(req.headers.authorization, "Bearer " + token);
                res.setHeader("content-type", "application/json");
                res.end(JSON.stringify({ ok: true, team: { id: "T1", domain: "acme", name: "Acme Corp", icon: { image_68: `http://127.0.0.1:${req.socket.localPort}/images/team.png` } } }));
                return;
            }
            if (req.url.startsWith("/api/users.list")) {
                assert.equal(req.headers.authorization, "Bearer " + token);
                res.setHeader("content-type", "application/json");
                res.end(JSON.stringify({ ok: true, members: [
                    { id: "U1", name: "ada", real_name: "Ada Lovelace", profile: { display_name: "Ada", real_name: "Ada Lovelace", image_48: `http://127.0.0.1:${req.socket.localPort}/images/ada.png` } }
                ], response_metadata: { next_cursor: "" } }));
                return;
            }
            if (req.url.startsWith("/images/")) {
                res.setHeader("content-type", "image/png");
                res.end(imageBytes);
                return;
            }
            res.statusCode = 404;
            res.end("missing");
        }, async port => runJson(cache, Object.assign({}, baseEnv, { VGS_NOTIFICATIONS_SLACK_API_BASE: `http://127.0.0.1:${port}/api` })));
    }
    const sameBytes = await refreshWithImageBytes(png);
    assert.equal(sameBytes.teams[0].icon, firstIcon, "the workspace icon version stays when the bytes stay");
    assert.equal(sameBytes.teams[0].users[0].photo, firstPhoto, "the photo version stays when the bytes stay");
    const changedBytes = await refreshWithImageBytes(pngChanged);
    assert.notEqual(changedBytes.teams[0].icon, firstIcon, "the workspace icon version changes when the bytes change");
    assert.notEqual(changedBytes.teams[0].users[0].photo, firstPhoto, "the photo version changes when the bytes change");
    fs.utimesSync(indexFile, oldDaily, oldDaily);
    let downloadFailureCalls = 0;
    await withServer((req, res) => {
        downloadFailureCalls++;
        if (req.url.startsWith("/api/team.info")) {
            assert.equal(req.headers.authorization, "Bearer " + token);
            res.setHeader("content-type", "application/json");
            res.end(JSON.stringify({ ok: true, team: { id: "T1", domain: "acme", name: "Acme Corp", icon: { image_68: `http://127.0.0.1:${req.socket.localPort}/images/team.png` } } }));
            return;
        }
        if (req.url.startsWith("/api/users.list")) {
            assert.equal(req.headers.authorization, "Bearer " + token);
            res.setHeader("content-type", "application/json");
            res.end(JSON.stringify({ ok: true, members: [
                { id: "U1", name: "ada", real_name: "Ada Lovelace", profile: { display_name: "Ada", real_name: "Ada Lovelace", image_48: `http://127.0.0.1:${req.socket.localPort}/images/ada.png` } },
                { id: "U2", name: "grace", real_name: "Grace Hopper", profile: { display_name: "Grace", real_name: "Grace Hopper", image_48: `http://127.0.0.1:${req.socket.localPort}/images/grace.png` } }
            ], response_metadata: { next_cursor: "" } }));
            return;
        }
        res.statusCode = 503;
        res.end("offline");
    }, async port => {
        const env = Object.assign({}, baseEnv, { VGS_NOTIFICATIONS_SLACK_API_BASE: `http://127.0.0.1:${port}/api` });
        const failedDownloads = await run(cache, env);
        assert.equal(failedDownloads.status, 0, failedDownloads.stderr);
        assert.match(failedDownloads.stderr, /^notifications-slack-photos: downloads=failed count=3/m);
        const loaded = JSON.parse(failedDownloads.stdout);
        assert.equal(loaded.status, "loaded");
        assert.equal(loaded.downloadFailed, 3);
        assert.match(loaded.teams[0].icon, /^file:\/\//, "a failed workspace-icon refresh keeps the previous file");
        assert.match(loaded.teams[0].users[0].photo, /^file:\/\//, "a failed photo refresh keeps the previous file");
        downloadFailureCalls = 0;
        const held = await runJson(cache, env);
        assert.equal(held.downloadFailed, 3, "download failures are retried after the retry gap, not immediately");
        assert.equal(downloadFailureCalls, 0, "a download-failure cache avoids API calls during the retry gap");
    });

    fs.utimesSync(indexFile, oldRetry, oldRetry);
    let retryCalls = 0;
    await withServer((req, res) => {
        retryCalls++;
        if (req.url.startsWith("/api/team.info")) {
            assert.equal(req.headers.authorization, "Bearer " + token);
            res.setHeader("content-type", "application/json");
            res.end(JSON.stringify({ ok: true, team: { id: "T1", domain: "acme", name: "Acme Corp", icon: { image_68: `http://127.0.0.1:${req.socket.localPort}/images/team.png` } } }));
            return;
        }
        if (req.url.startsWith("/api/users.list")) {
            assert.equal(req.headers.authorization, "Bearer " + token);
            res.setHeader("content-type", "application/json");
            res.end(JSON.stringify({ ok: true, members: [
                { id: "U1", name: "ada", real_name: "Ada Lovelace", profile: { display_name: "Ada", real_name: "Ada Lovelace", image_48: `http://127.0.0.1:${req.socket.localPort}/images/ada.png` } }
            ], response_metadata: { next_cursor: "" } }));
            return;
        }
        if (req.url.startsWith("/images/")) {
            res.setHeader("content-type", "image/png");
            res.end(png);
            return;
        }
        res.statusCode = 404;
        res.end("missing");
    }, async port => {
        const env = Object.assign({}, baseEnv, { VGS_NOTIFICATIONS_SLACK_API_BASE: `http://127.0.0.1:${port}/api` });
        const retried = await runJson(cache, env);
        assert.equal(retried.downloadFailed, 0, "the helper retries downloads after the retry gap");
        assert.ok(retryCalls > 0, "the expired download-failure cache reaches the API");
    });

    fs.utimesSync(indexFile, oldDaily, oldDaily);
    let staleCalls = 0;
    await withServer((req, res) => {
        staleCalls++;
        res.setHeader("content-type", "application/json");
        res.end(JSON.stringify({ ok: false, error: "ratelimited" }));
    }, async port => {
        const env = Object.assign({}, baseEnv, { VGS_NOTIFICATIONS_SLACK_API_BASE: `http://127.0.0.1:${port}/api` });
        const stale = await run(cache, env);
        assert.equal(stale.status, 0, stale.stderr);
        assert.match(stale.stderr, /^notifications-slack-photos: api=team\.info error=ratelimited/m);
        const loaded = JSON.parse(stale.stdout);
        assert.equal(loaded.status, "loaded");
        assert.equal(loaded.stale, true, "an API failure serves the stale index when one exists");
        staleCalls = 0;
        const held = await runJson(cache, env);
        assert.equal(held.stale, true, "the API-failure backoff serves the stale index");
        assert.equal(staleCalls, 0, "the API-failure backoff avoids another API call");
    });

    let calls = 0;
    await withServer((req, res) => {
        calls++;
        res.setHeader("content-type", "application/json");
        if (req.url.startsWith("/api/team.info")) {
            assert.equal(req.headers.authorization, "Bearer " + token);
            res.end(JSON.stringify({ ok: true, team: { id: "T1", domain: "acme", name: "Acme", icon: {} } }));
        } else {
            assert.equal(req.headers.authorization, "Bearer " + token);
            res.end(JSON.stringify({ ok: false, error: "missing_scope" }));
        }
    }, async port => {
        const env = Object.assign({}, baseEnv, { VGS_NOTIFICATIONS_SLACK_API_BASE: `http://127.0.0.1:${port}/api` });
        const cache = path.join(scratch, "failure-cache");
        const failed = await run(cache, env);
        assert.notEqual(failed.status, 0, "an API error fails the refresh");
        assert.match(failed.stderr, /^notifications-slack-photos: api=users\.list error=missing_scope/m);
        assert.equal(failed.stderr.includes(token), false, "the token is not logged on failure");
        const held = await runJson(cache, env);
        assert.deepEqual(held, { status: "absent" }, "a recent failure is held");
        assert.equal(calls, 2, "the held failure avoids another API call");
    });
}

function controls() {
    const source = fs.readFileSync(helperSource, "utf8");
    const dir = path.join(scratch, "controls");
    fs.mkdirSync(dir, { recursive: true });
    const controls = [
        ["Authorization header", '"header = \\"Authorization: Bearer " + token.replace(/"/g, "") + "\\""', '"header = \\"Authorization: Bearer wrong\\""', /API calls carry the token in a header/],
        ["fresh cache", "if (fresh !== null) {", "if (false && fresh !== null) {", /fresh cache avoids another API call/],
        ["failure backoff", "if (failureHeld(failureFile)) {", "if (false && failureHeld(failureFile)) {", /a recent failure is held|api=users\.list error=missing_scope|api=team\.info error=ratelimited/],
        ["safe user id", "const id = safeSegment(user && user.id);", "const id = user && user.id || \"\";", /only safe synthetic users are stored/]
    ];
    let passed = 0;
    for (let index = 0; index < controls.length; index++) {
        const [label, needle, replacement, failure] = controls[index];
        assert.equal(source.split(needle).length, 2, `control "${label}": the text to replace must occur once`);
        const copy = path.join(dir, String(index), "slack-photos.js");
        fs.mkdirSync(path.dirname(copy), { recursive: true });
        fs.writeFileSync(copy, source.replace(needle, replacement), { mode: 0o700 });
        const syntax = childProcess.spawnSync(process.execPath, ["--check", copy], { cwd: repo, encoding: "utf8" });
        assert.equal(syntax.status, 0, `control "${label}": the mutated helper must remain valid JavaScript`);
        const result = childProcess.spawnSync(process.execPath, [__filename], {
            cwd: repo,
            env: Object.assign({}, process.env, {
                NOTIFICATIONS_SLACK_PHOTOS_HELPER: copy,
                NOTIFICATIONS_SLACK_PHOTOS_SKIP_CONTROLS: "1"
            }),
            encoding: "utf8",
            maxBuffer: 8 * 1024 * 1024
        });
        assert.notEqual(result.status, 0, `control "${label}": the suite passed on a helper without that rule`);
        assert.match(result.stdout + result.stderr, failure, `control "${label}": failed for the intended reason`);
        passed++;
    }
    assert.equal(passed, controls.length);
    return passed;
}

main()
    .then(() => {
        const controlCount = process.env.NOTIFICATIONS_SLACK_PHOTOS_SKIP_CONTROLS === "1" ? 0 : controls();
        fs.rmSync(scratch, { recursive: true, force: true });
        console.log("test-notifications-slack-photos: ok controls=" + controlCount);
    })
    .catch(error => {
        fs.rmSync(scratch, { recursive: true, force: true });
        throw error;
    });
