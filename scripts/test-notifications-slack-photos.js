#!/usr/bin/env node
// The optional Slack photo helper, shell/plugins/vgs.notifications/
// slack-photos.js, with a stub secret-tool holding one token per account
// and a stub Slack API on 127.0.0.1 that answers each token as its own
// team. It proves each workspace's token fills its own team's cache, a
// workspace without a token keeps none, the single-workspace token still
// serves the team team.info names unless that team's own token does, a
// token for another team is refused, each team keeps its own freshness and
// failure hold, the cache layout keeps users/ apart and sweeps an older
// flat layout while leaving names it does not own, and no token reaches
// argv, a file or a log line.
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
const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=", "base64");
const pngChanged = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==", "base64");
const VERSIONED = /^file:\/\/\/[^\s?#]+\.png\?v=[0-9a-f]{16}$/;
// The tokens the stub store can hold, each answered by the stub API as the
// team it names.
const TOKENS = {
    "xoxp-acme-4f2a": "T1",
    "xoxp-globex-7c1d": "T2",
    "xoxp-legacy-9e3b": "T1",
    "xoxp-initech-2b8c": "T9"
};
const TEAMS = {
    T1: { domain: "acme", name: "Acme Corp" },
    T2: { domain: "globex", name: "Globex Inc" },
    T9: { domain: "initech", name: "Initech" }
};
let secretToolPath = "";

function write(file, text, mode) {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, text, { mode: mode || 0o600 });
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

// The stub API: team.info and users.list answer by the bearer token, and
// every call is logged as [team of the token, method]. `world.down` makes
// every API call fail as Slack's rate limit does; `world.images` is what
// an image URL serves, or null for a failed download.
const world = { down: false, images: png, calls: [] };
function serve(req, res) {
    const port = req.socket.localPort;
    const bearer = String(req.headers.authorization || "").replace(/^Bearer /, "");
    if (req.url.startsWith("/api/")) {
        const method = req.url.slice(5).split("?")[0];
        world.calls.push([bearer, method]);
        res.setHeader("content-type", "application/json");
        const team = TOKENS[bearer];
        if (team === undefined) { res.end(JSON.stringify({ ok: false, error: "invalid_auth" })); return; }
        if (world.down) { res.end(JSON.stringify({ ok: false, error: "ratelimited" })); return; }
        if (method === "team.info") {
            res.end(JSON.stringify({ ok: true, team: Object.assign({ id: team, icon: { image_68: `http://127.0.0.1:${port}/images/${team}/team.png` } }, TEAMS[team]) }));
            return;
        }
        if (method === "users.list") {
            res.end(JSON.stringify({ ok: true, members: [
                { id: "U" + team + "A", name: "ada", real_name: "Ada Lovelace", profile: { display_name: "Ada", real_name: "Ada Lovelace", image_48: `http://127.0.0.1:${port}/images/${team}/ada.png` } },
                { id: "U" + team + "G", name: "grace", real_name: "Grace Hopper", profile: { display_name: "Grace", real_name: "Grace Hopper", image_48: `http://127.0.0.1:${port}/images/${team}/grace.png` } },
                { id: "U" + team + "M", name: "mallory", real_name: "Mallory", profile: { display_name: "Mallory", image_48: "https://evil.example/mallory.png" } },
                { id: "../x", name: "bad", profile: { display_name: "Bad" } }
            ], response_metadata: { next_cursor: "" } }));
            return;
        }
        res.end(JSON.stringify({ ok: false, error: "unknown_method" }));
        return;
    }
    if (req.url.startsWith("/images/") && world.images !== null) {
        res.setHeader("content-type", "image/png");
        res.end(world.images);
        return;
    }
    res.statusCode = 503;
    res.end("offline");
}

const secretLog = path.join(scratch, "secret-argv.log");
const tokenFile = path.join(scratch, "tokens");
// The stub store: `account token` lines.
function store(pairs) {
    write(tokenFile, Object.entries(pairs).map(([account, token]) => account + " " + token + "\n").join(""));
}

let env = null;
function run(cache, ids, secretToolMode) {
    const runEnv = secretToolMode === "absent" ? Object.assign({}, env, { PATH: path.join(scratch, "empty-bin") }) : env;
    const found = resolveCommand("secret-tool", runEnv);
    if (secretToolMode === "absent") assert.equal(found, "", "the missing-secret-tool case must not resolve a real secret-tool");
    else assert.equal(found, fs.realpathSync(secretToolPath), "tests must run only against the stub secret-tool");
    return new Promise(resolve => {
        const child = childProcess.spawn(process.execPath, [helper, "refresh", cache].concat(ids), { cwd: repo, env: runEnv });
        let stdout = "";
        let stderr = "";
        child.stdout.setEncoding("utf8");
        child.stderr.setEncoding("utf8");
        child.stdout.on("data", chunk => { stdout += chunk; });
        child.stderr.on("data", chunk => { stderr += chunk; });
        child.on("close", status => resolve({ status, stdout, stderr }));
    });
}

async function runJson(cache, ids, secretToolMode) {
    const result = await run(cache, ids, secretToolMode);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stderr, "", "a clean refresh prints no stderr");
    return JSON.parse(result.stdout);
}

function teamIds(index) {
    return index.teams.map(team => [team.id, team.account]);
}

// The API calls made since `since`, as [team of the token, method].
function callsSince(since) {
    return world.calls.slice(since).map(([token, method]) => [TOKENS[token] + (token === "xoxp-legacy-9e3b" ? "(legacy)" : ""), method]);
}

// Moves a team's refresh time back, as a day passing does.
function backdate(cache, id, ms) {
    const file = path.join(cache, id, "team.json");
    const team = JSON.parse(fs.readFileSync(file, "utf8"));
    team.generatedAt -= ms;
    write(file, JSON.stringify(team));
}

function backdateAccount(cache, account, field, ms) {
    const file = path.join(cache, "accounts.json");
    const accounts = JSON.parse(fs.readFileSync(file, "utf8"));
    accounts[account][field] -= ms;
    write(file, JSON.stringify(accounts));
}

const DAY = 25 * 60 * 60 * 1000;
const RETRY = 16 * 60 * 1000;

async function main(port) {
    const bin = path.join(scratch, "bin");
    fs.mkdirSync(path.join(scratch, "empty-bin"), { recursive: true });
    secretToolPath = path.join(bin, "secret-tool");
    write(secretToolPath, `#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >>"${secretLog}"
[[ \${1:-} == lookup ]] || exit 2
account="\${5:-}"
while read -r name token; do
  if [[ $name == "$account" ]]; then printf '%s\\n' "$token"; exit 0; fi
done <"${tokenFile}"
exit 1
`, 0o700);
    env = {
        PATH: bin + path.delimiter + path.dirname(process.execPath) + path.delimiter + "/usr/bin:/bin",
        HOME: scratch,
        VGS_NOTIFICATIONS_SLACK_TEST: "1",
        VGS_NOTIFICATIONS_SLACK_TEST_SECRET_TOOL_DIR: bin,
        VGS_NOTIFICATIONS_SLACK_API_BASE: `http://127.0.0.1:${port}/api`
    };

    // The arguments: team ids are letters and digits, at most sixteen.
    for (const [label, ids, line] of [
        ["a team id with a slash", ["T1", "../T2"], "notifications-slack-photos: refused: team-id want=[A-Za-z0-9]{1,32}"],
        ["seventeen team ids", Array.from({ length: 17 }, (_, i) => "T" + i), "notifications-slack-photos: refused: teams count=17 want<=16"]
    ]) {
        const refused = await run(path.join(scratch, "refused"), ids);
        assert.equal(refused.status, 2, "refused argv exits 2: " + label);
        assert.equal(refused.stderr.trim(), line, "the refusal names the argument: " + label);
        assert.equal(fs.existsSync(path.join(scratch, "refused")), false, "a refused run creates nothing: " + label);
    }

    // No token for any account, or no secret-tool: no cache and no call.
    store({});
    const absentCache = path.join(scratch, "absent-cache");
    assert.deepEqual(await runJson(absentCache, ["T1", "T2"]), { status: "absent" }, "no token returns no cache");
    assert.equal(world.calls.length, 0, "no token starts no HTTP request");
    assert.equal(fs.existsSync(absentCache), false, "no token creates no cache directory");
    assert.deepEqual(fs.readFileSync(secretLog, "utf8").trim().split("\n"), [
        "lookup service vgs-notifications account slack:T1",
        "lookup service vgs-notifications account slack:T2",
        "lookup service vgs-notifications account slack"
    ], "each workspace's account is looked up, then the single-workspace one");
    store({ "slack:T1": "xoxp-acme-4f2a" });
    const missingTool = path.join(scratch, "missing-secret-tool-cache");
    assert.deepEqual(await runJson(missingTool, ["T1"], "absent"), { status: "absent" }, "missing secret-tool is the same as no token");
    assert.equal(fs.existsSync(missingTool), false, "missing secret-tool creates no cache directory");

    // Two workspaces with two tokens: photos for both, each from its own
    // token, in its own directory.
    const cache = path.join(scratch, "cache");
    store({ "slack:T1": "xoxp-acme-4f2a", "slack:T2": "xoxp-globex-7c1d" });
    let since = world.calls.length;
    const both = await runJson(cache, ["T1", "T2"]);
    assert.equal(both.status, "loaded");
    assert.equal(both.stale, false);
    assert.equal(both.downloadFailed, 0);
    assert.deepEqual(teamIds(both), [["T1", "slack:T1"], ["T2", "slack:T2"]], "two workspaces with two tokens produce photos for both");
    assert.deepEqual(callsSince(since), [["T1", "team.info"], ["T1", "users.list"], ["T2", "team.info"], ["T2", "users.list"]], "each token asks for its own team");
    assert.deepEqual(both.teams[1].names, ["globex", "Globex Inc"]);
    assert.equal(both.teams[0].users.length, 3, "only safe synthetic users are stored");
    assert.match(both.teams[0].icon, VERSIONED, "the workspace icon URL is versioned by content");
    for (const team of both.teams) {
        assert.match(team.users[0].photo, VERSIONED, "each team's photo URL is versioned by content");
        assert.equal(team.users[0].photo.indexOf("file://" + path.join(cache, team.id, "users") + "/"), 0, "a team's photos live in its users/ directory");
    }
    assert.equal(both.teams[0].users.find(u => u.names[0] === "Mallory").photo, "", "untrusted image hosts are skipped");
    assert.equal(fs.existsSync(path.join(cache, "T1", "users", "UT1A.png")), true, "a user photo is cached under users/");
    assert.equal(fs.existsSync(path.join(cache, "T2", "workspace.png")), true, "each workspace icon is cached");
    assert.deepEqual(fs.readdirSync(cache).sort(), ["T1", "T2", "accounts.json"], "the root holds the account states and one directory per team");
    assert.deepEqual(fs.readdirSync(path.join(cache, "T1")).sort(), ["team.json", "users", "users.json", "workspace.png"], "a team directory holds its own names");
    const onDisk = childProcess.spawnSync("grep", ["-r", "-l", "-F", "-e", "xoxp-", cache], { encoding: "utf8" });
    assert.equal(onDisk.status, 1, "no token is stored in the cache: " + onDisk.stdout);
    assert.equal(/xoxp-/.test(fs.readFileSync(secretLog, "utf8")), false, "no token is passed to secret-tool on argv");

    // Fresh teams are served from the cache with no call.
    since = world.calls.length;
    assert.deepEqual(teamIds(await runJson(cache, ["T1", "T2"])), [["T1", "slack:T1"], ["T2", "slack:T2"]], "fresh caches are reused");
    assert.deepEqual(callsSince(since), [], "fresh caches avoid another API call");

    // A missing token for one workspace drops that workspace alone.
    store({ "slack:T1": "xoxp-acme-4f2a" });
    since = world.calls.length;
    const one = await runJson(cache, ["T1", "T2"]);
    assert.deepEqual(teamIds(one), [["T1", "slack:T1"]], "a missing token for one workspace keeps initials there only");
    assert.equal(fs.existsSync(path.join(cache, "T2")), false, "a workspace with no token keeps no cache");
    assert.deepEqual(callsSince(since), [], "the other workspace stays fresh");

    // A token stored for the second workspace loads at the next run, while
    // the first is still inside its day.
    store({ "slack:T1": "xoxp-acme-4f2a", "slack:T2": "xoxp-globex-7c1d" });
    since = world.calls.length;
    const added = await runJson(cache, ["T1", "T2"]);
    assert.deepEqual(teamIds(added), [["T1", "slack:T1"], ["T2", "slack:T2"]], "a newly stored token loads without waiting for another team's day");
    assert.deepEqual(callsSince(since), [["T2", "team.info"], ["T2", "users.list"]], "only the new team is asked");
    assert.equal(added.generatedAt, JSON.parse(fs.readFileSync(path.join(cache, "T1", "team.json"), "utf8")).generatedAt, "the output's time is the oldest team's");

    // Image bytes decide the version: the same bytes keep it, new bytes
    // change it.
    const firstIcon = added.teams[0].icon;
    const firstPhoto = added.teams[0].users[0].photo;
    backdate(cache, "T1", DAY);
    const sameBytes = await runJson(cache, ["T1", "T2"]);
    assert.equal(sameBytes.teams[0].icon, firstIcon, "the workspace icon version stays when the bytes stay");
    assert.equal(sameBytes.teams[0].users[0].photo, firstPhoto, "the photo version stays when the bytes stay");
    backdate(cache, "T1", DAY);
    world.images = pngChanged;
    const changedBytes = await runJson(cache, ["T1", "T2"]);
    world.images = png;
    assert.notEqual(changedBytes.teams[0].icon, firstIcon, "the workspace icon version changes when the bytes change");
    assert.notEqual(changedBytes.teams[0].users[0].photo, firstPhoto, "the photo version changes when the bytes change");

    // A failed download keeps the older file and holds the team for the
    // retry gap alone.
    backdate(cache, "T1", DAY);
    world.images = null;
    const failedDownloads = await run(cache, ["T1", "T2"]);
    world.images = png;
    assert.equal(failedDownloads.status, 0, failedDownloads.stderr);
    assert.match(failedDownloads.stderr, /^notifications-slack-photos: downloads=failed count=3$/m);
    const partial = JSON.parse(failedDownloads.stdout);
    assert.equal(partial.downloadFailed, 3);
    assert.match(partial.teams[0].icon, /^file:\/\//, "a failed workspace-icon refresh keeps the previous file");
    assert.match(partial.teams[0].users[0].photo, /^file:\/\//, "a failed photo refresh keeps the previous file");
    since = world.calls.length;
    assert.equal((await run(cache, ["T1", "T2"])).status, 0);
    assert.deepEqual(callsSince(since), [], "a download-failure cache avoids API calls during the retry gap");
    backdate(cache, "T1", RETRY);
    since = world.calls.length;
    assert.equal((await runJson(cache, ["T1", "T2"])).downloadFailed, 0, "the helper retries downloads after the retry gap");
    assert.deepEqual(callsSince(since), [["T1", "team.info"], ["T1", "users.list"]], "the expired download-failure cache reaches the API");

    // An API failure serves the team's stale cache and holds that account
    // alone for the retry gap.
    backdate(cache, "T1", DAY);
    world.down = true;
    const stale = await run(cache, ["T1", "T2"]);
    assert.equal(stale.status, 0, stale.stderr);
    assert.equal(stale.stderr, "notifications-slack-photos: account=slack:T1 api=team.info error=ratelimited\n");
    const staleIndex = JSON.parse(stale.stdout);
    assert.equal(staleIndex.stale, true, "an API failure marks the output stale");
    assert.deepEqual(teamIds(staleIndex), [["T1", "slack:T1"], ["T2", "slack:T2"]], "an API failure serves the stale cache when one exists");
    since = world.calls.length;
    const heldIndex = await run(cache, ["T1", "T2"]);
    assert.equal(heldIndex.status, 0);
    assert.equal(JSON.parse(heldIndex.stdout).stale, true, "the API-failure backoff serves the stale cache");
    assert.deepEqual(callsSince(since), [], "the API-failure backoff avoids another API call");
    world.down = false;
    backdateAccount(cache, "slack:T1", "failedAt", RETRY);
    assert.equal((await runJson(cache, ["T1", "T2"])).stale, false, "the account is asked again after the retry gap");

    // A failure with nothing cached is held too, and names no token.
    const failureCache = path.join(scratch, "failure-cache");
    world.down = true;
    const failed = await run(failureCache, ["T1", "T2"]);
    assert.equal(failed.status, 0, failed.stderr);
    assert.match(failed.stderr, /^notifications-slack-photos: account=slack:T1 api=team\.info error=ratelimited$/m);
    assert.equal(/xoxp-/.test(failed.stderr), false, "the token is not logged on failure");
    assert.deepEqual(JSON.parse(failed.stdout), { status: "loaded", generatedAt: 0, downloadFailed: 0, stale: true, teams: [] }, "a failure with no cache serves no team");
    since = world.calls.length;
    await run(failureCache, ["T1", "T2"]);
    assert.deepEqual(callsSince(since), [], "a recent failure is held");
    world.down = false;

    // A token for another team is refused for the team its account names,
    // and caches nothing for it.
    const mismatchCache = path.join(scratch, "mismatch-cache");
    store({ "slack:T1": "xoxp-acme-4f2a", "slack:T2": "xoxp-acme-4f2a" });
    const mismatch = await run(mismatchCache, ["T1", "T2"]);
    assert.equal(mismatch.status, 0, mismatch.stderr);
    assert.equal(mismatch.stderr, "notifications-slack-photos: account=slack:T2 team=mismatch\n");
    assert.deepEqual(teamIds(JSON.parse(mismatch.stdout)), [["T1", "slack:T1"]], "the mismatched team is refused");
    assert.equal(fs.existsSync(path.join(mismatchCache, "T2")), false, "nothing is cached for the mismatched team");

    // The single-workspace token still serves the team team.info names,
    // with no Slack workspace list at all.
    const legacyCache = path.join(scratch, "legacy-cache");
    store({ slack: "xoxp-initech-2b8c" });
    const legacyOnly = await runJson(legacyCache, []);
    assert.deepEqual(teamIds(legacyOnly), [["T9", "slack"]], "the legacy single token still works");
    assert.equal(legacyOnly.teams[0].users.length, 3);
    since = world.calls.length;
    await runJson(legacyCache, []);
    assert.deepEqual(callsSince(since), [], "the legacy team's fresh cache avoids another API call");

    // Beside a workspace's own token for the same team, the workspace's
    // token serves it and the single-workspace one is not fetched twice.
    const sharedCache = path.join(scratch, "shared-cache");
    store({ "slack:T1": "xoxp-acme-4f2a", slack: "xoxp-legacy-9e3b" });
    since = world.calls.length;
    const shared = await runJson(sharedCache, ["T1"]);
    assert.deepEqual(teamIds(shared), [["T1", "slack:T1"]], "the workspace's own token wins");
    assert.deepEqual(callsSince(since), [["T1", "team.info"], ["T1", "users.list"], ["T1(legacy)", "team.info"]], "the legacy token asks only which team it serves");
    since = world.calls.length;
    await runJson(sharedCache, ["T1"]);
    assert.deepEqual(callsSince(since), [], "a served legacy team is not asked again within the day");
    // The legacy token served the team first; a token stored for it later
    // takes it over.
    const takeoverCache = path.join(scratch, "takeover-cache");
    store({ slack: "xoxp-legacy-9e3b" });
    assert.deepEqual(teamIds(await runJson(takeoverCache, ["T1"])), [["T1", "slack"]], "the legacy token serves a workspace without its own");
    store({ "slack:T1": "xoxp-acme-4f2a", slack: "xoxp-legacy-9e3b" });
    since = world.calls.length;
    assert.deepEqual(teamIds(await runJson(takeoverCache, ["T1"])), [["T1", "slack:T1"]], "a workspace's own token takes over from the legacy one");
    assert.deepEqual(callsSince(since), [["T1", "team.info"], ["T1", "users.list"]], "the takeover asks the workspace's token alone");

    // An older flat layout is swept on the next refresh: its photos beside
    // team.json and the old root index go, names the helper does not own
    // stay.
    const layoutCache = path.join(scratch, "layout-cache");
    store({ "slack:T1": "xoxp-acme-4f2a" });
    write(path.join(layoutCache, "index.json"), "{}");
    write(path.join(layoutCache, "failure.json"), "{}");
    write(path.join(layoutCache, "T1", "team.json"), JSON.stringify({ id: "T1", names: ["acme"], icon: "" }));
    write(path.join(layoutCache, "T1", "UT1A.png"), png);
    write(path.join(layoutCache, "T1", ".users.json.123.tmp"), "{");
    write(path.join(layoutCache, "T1", "emoji.json"), "{}");
    write(path.join(layoutCache, "T1", "emoji", "party.png"), png);
    await runJson(layoutCache, ["T1"]);
    assert.deepEqual(fs.readdirSync(layoutCache).sort(), ["T1", "accounts.json"], "the old root index and failure file are gone");
    assert.deepEqual(fs.readdirSync(path.join(layoutCache, "T1")).sort(), ["emoji", "emoji.json", "team.json", "users", "users.json", "workspace.png"], "the old flat photos go and names the helper does not own stay");
    assert.deepEqual(fs.readdirSync(path.join(layoutCache, "T1", "emoji")), ["party.png"]);
}

function controls() {
    const source = fs.readFileSync(helperSource, "utf8");
    const dir = path.join(scratch, "controls");
    fs.mkdirSync(dir, { recursive: true });
    const table = [
        ["Authorization header", '"header = \\"Authorization: Bearer " + token.replace(/"/g, "") + "\\""', '"header = \\"Authorization: ******\\""', /error=invalid_auth/],
        ["fresh cache", "if (fresh(record, entry.account)) {", "if (false && fresh(record, entry.account)) {", /fresh caches avoid another API call/],
        ["failure backoff", "if (held(accounts[entry.account])) {", "if (false && held(accounts[entry.account])) {", /the API-failure backoff avoids another API call|a recent failure is held/],
        ["safe user id", "const id = safeSegment(user && user.id);", "const id = user && user.id || \"\";", /only safe synthetic users are stored/],
        ["team id argv", "if (safeSegment(id) === \"\") usage(", "if (false) usage(", /refused argv exits 2: a team id with a slash/],
        ["team mismatch", "if (safeSegment(info && info.id) !== id) {", "if (false) {", /the mismatched team is refused|team=mismatch/],
        ["a team without a token is swept", "if (name === ACCOUNTS_FILE || kept.has(name)) continue;", "if (name === ACCOUNTS_FILE || /^T/.test(name)) continue;", /a workspace with no token keeps no cache/],
        ["the workspace's own token wins", "if (known !== \"\" && served.has(known)) {", "if (false) {", /the legacy token asks only which team it serves|a served legacy team is not asked again/],
        ["the legacy token is not fetched twice", "if (!served.has(id)) settle(LEGACY,", "if (true) settle(LEGACY,", /the workspace's own token wins|the legacy token asks only which team it serves/],
        ["the legacy token serves its team", "if (!served.has(id)) settle(LEGACY,", "if (false) settle(LEGACY,", /the legacy single token still works/],
        ["the old flat photos go", "(/\\.png$/.test(name) || TEMP_NAME.test(name))", "TEMP_NAME.test(name)", /the old flat photos go/],
        ["foreign names stay", "TEAM_FILES.indexOf(name) !== -1 ? !keep.has(name) : (", "TEAM_FILES.indexOf(name) !== -1 ? !keep.has(name) : true || (", /names the helper does not own stay/]
    ];
    let passed = 0;
    for (let index = 0; index < table.length; index++) {
        const [label, needle, replacement, failure] = table[index];
        assert.equal(source.split(needle).length, 2, `control "${label}": the text to replace must occur once`);
        const copy = path.join(dir, String(index), "slack-photos.js");
        fs.mkdirSync(path.dirname(copy), { recursive: true });
        fs.writeFileSync(copy, source.replace(needle, () => replacement), { mode: 0o700 });
        const syntax = childProcess.spawnSync(process.execPath, ["--check", copy], { cwd: repo, encoding: "utf8" });
        assert.equal(syntax.status, 0, `control "${label}": the mutated helper must remain valid JavaScript`);
        const result = childProcess.spawnSync(process.execPath, [__filename], {
            cwd: repo,
            env: { PATH: process.env.PATH, NOTIFICATIONS_SLACK_PHOTOS_HELPER: copy, NOTIFICATIONS_SLACK_PHOTOS_SKIP_CONTROLS: "1" },
            encoding: "utf8",
            maxBuffer: 8 * 1024 * 1024
        });
        assert.notEqual(result.status, 0, `control "${label}": the suite passed on a helper without that rule`);
        assert.match(result.stdout + result.stderr, failure, `control "${label}": failed for the intended reason`);
        passed++;
    }
    return passed;
}

async function withServer(body) {
    const server = http.createServer(serve);
    await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
    try {
        return await body(server.address().port);
    } finally {
        await new Promise(resolve => server.close(resolve));
    }
}

fs.rmSync(scratch, { recursive: true, force: true });
fs.mkdirSync(scratch, { recursive: true });
withServer(main)
    .then(() => {
        const controlCount = process.env.NOTIFICATIONS_SLACK_PHOTOS_SKIP_CONTROLS === "1" ? 0 : controls();
        fs.rmSync(scratch, { recursive: true, force: true });
        console.log("test-notifications-slack-photos: ok controls=" + controlCount);
    })
    .catch(error => {
        fs.rmSync(scratch, { recursive: true, force: true });
        console.error(error && error.stack ? error.stack : String(error));
        process.exit(1);
    });
