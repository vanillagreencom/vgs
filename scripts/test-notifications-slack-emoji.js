#!/usr/bin/env node
// The custom emoji of the Slack photo helper, shell/plugins/
// vgs.notifications/slack-emoji.js, run through slack-photos.js with a
// synthetic Slack disk cache, a stub secret-tool, a stub Slack API on
// 127.0.0.1 and the real ImageMagick behind a wrapper that logs each run.
// It proves a cached emoji becomes a normalized image in the team's map,
// the newest cache entry of a name wins, a name outside the rule is
// skipped, a GIF gives its first frame, an alias and an API-only emoji
// resolve with a token, an updated emoji takes the API's image,
// `missing_scope` is quiet and asked daily, the previous index's files
// survive one run, a second run converts nothing, a run converts at most
// its budget and reports the rest as pending, a failed chunk is converted
// one image at a time, no ImageMagick is one line and no emoji, turning
// emoji off empties the index before removing it, and with the Slack photos
// extra off a stored token stays unread, so Slack's list is not asked. Exit 77 when ImageMagick
// is not installed, since a conversion nothing runs proves nothing.
"use strict";

const assert = require("node:assert/strict");
const childProcess = require("node:child_process");
const crypto = require("node:crypto");
const fs = require("node:fs");
const http = require("node:http");
const path = require("node:path");

const repo = path.join(__dirname, "..");
const pluginDir = path.join(repo, "shell", "plugins", "vgs.notifications");
const helper = process.env.NOTIFICATIONS_SLACK_EMOJI_HELPER || path.join(pluginDir, "slack-photos.js");
const emojiSource = path.join(pluginDir, "slack-emoji.js");
const scratch = path.join(repo, "tmp", "test-notifications-slack-emoji-" + process.pid);
const TOKENS = { "xoxp-acme-4f2a": "T1", "xoxp-globex-7c1d": "T2" };

function write(file, bytes, mode) {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, bytes, { mode: mode || 0o600 });
}

function realMagick() {
    for (const dir of String(process.env.PATH || "").split(path.delimiter)) {
        const candidate = path.join(dir, "magick");
        try {
            fs.accessSync(candidate, fs.constants.X_OK);
            return fs.realpathSync(candidate);
        } catch (_e) {
            // Keep looking.
        }
    }
    return "";
}
const magick = realMagick();
// The fixtures below are drawn by ImageMagick, so its absence is decided
// before any of them.
if (magick === "") {
    console.log("test-notifications-slack-emoji: status=not-measured missing=magick");
    process.exit(77);
}

// An image ImageMagick draws: `spec` is its argv before the output.
function image(spec, coder) {
    const made = childProcess.spawnSync(magick, spec.concat([coder + ":-"]), { maxBuffer: 16 * 1024 * 1024 });
    assert.equal(made.status, 0, "the fixture image is drawn: " + String(made.stderr));
    return made.stdout;
}

// The colour at the centre of a PNG, as ImageMagick names it, and its size.
function describe(file) {
    const got = childProcess.spawnSync(magick, [file, "-format", "%wx%h %[pixel:p{24,24}]", "info:"], { encoding: "utf8" });
    assert.equal(got.status, 0, got.stderr);
    return got.stdout.trim();
}

const RED = image(["-size", "64x64", "xc:red"], "png");
const BLUE = image(["-size", "64x64", "xc:blue"], "png");
const GREEN = image(["-size", "40x80", "xc:lime"], "jpg");
const YELLOW = image(["-size", "64x64", "xc:yellow"], "png");
const CYAN = image(["-size", "64x64", "xc:cyan"], "png");
const WAVE = image(["-delay", "10", "-size", "64x64", "xc:red", "xc:blue"], "gif");
// Past the 256 KiB a source may hold.
const NOISE = image(["-size", "400x400", "plasma:", "-attenuate", "1", "+noise", "Random"], "png");

// One simple-cache entry: the header, the key, the body, the end record,
// then a headers stream and its end record, as Slack's cache writes them.
function entry(dir, url, body, mtimeSeconds) {
    const key = "1/0/" + url;
    const header = Buffer.alloc(24);
    header.writeUInt32LE(0xa7725c30, 0);
    header.writeUInt32LE(0xfcfb6d1b, 4);
    header.writeUInt32LE(5, 8);
    header.writeUInt32LE(Buffer.byteLength(key), 12);
    const end = Buffer.from([0xd8, 0x41, 0x0d, 0x97, 0x45, 0x6f, 0xfa, 0xf4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
    const sum = crypto.createHash("sha1").update(key).digest();
    const name = Buffer.from(sum.subarray(0, 8)).reverse().toString("hex") + "_0";
    const file = path.join(dir, name);
    write(file, Buffer.concat([header, Buffer.from(key), body, end, Buffer.from("HTTP/1.1 200\0"), end]));
    fs.utimesSync(file, mtimeSeconds, mtimeSeconds);
    return file;
}

const emojiUrl = (team, name, hash, ext) => `https://emoji.slack-edge.com/${team}/${name}/${hash}.${ext}`;

// The stub API: emoji.list by the bearer token. `world.list` is T1's
// answer, `world.down` fails every call as Slack's rate limit does.
const world = { list: {}, down: false, calls: [] };
function serve(req, res) {
    const bearer = String(req.headers.authorization || "").replace(/^Bearer /, "");
    if (req.url.startsWith("/api/")) {
        const method = req.url.slice(5).split("?")[0];
        world.calls.push([TOKENS[bearer], method]);
        res.setHeader("content-type", "application/json");
        if (world.down) { res.end(JSON.stringify({ ok: false, error: "ratelimited" })); return; }
        const port = req.socket.localPort;
        if (method === "team.info") { res.end(JSON.stringify({ ok: true, team: { id: TOKENS[bearer], domain: TOKENS[bearer].toLowerCase(), name: TOKENS[bearer], icon: { image_68: `http://127.0.0.1:${port}/emoji/apionly.png` } } })); return; }
        if (method === "users.list") { res.end(JSON.stringify({ ok: true, members: [{ id: "U" + TOKENS[bearer] + "A", name: "ada", profile: { display_name: "Ada", image_48: `http://127.0.0.1:${port}/emoji/apionly.png` } }], response_metadata: { next_cursor: "" } })); return; }
        if (method === "emoji.list" && TOKENS[bearer] === "T1") { res.end(JSON.stringify({ ok: true, emoji: world.list })); return; }
        if (method === "emoji.list" && TOKENS[bearer] === "T2") { res.end(JSON.stringify({ ok: false, error: "missing_scope", needed: "emoji:read" })); return; }
        res.end(JSON.stringify({ ok: false, error: "unknown_method" }));
        return;
    }
    const images = { "/emoji/apionly.png": YELLOW, "/emoji/changed.png": CYAN };
    if (images[req.url] !== undefined) { res.end(images[req.url]); return; }
    res.statusCode = 404;
    res.end("missing");
}

const secretLog = path.join(scratch, "secret-argv.log");
const tokenFile = path.join(scratch, "tokens");
const magickLog = path.join(scratch, "magick.log");
const failChunks = path.join(scratch, "fail-chunks");
function store(pairs) {
    write(tokenFile, Object.entries(pairs).map(([account, token]) => account + " " + token + "\n").join(""));
}

let env = null;
// One helper run over ROOT with ARGV, with the Slack photos extra on, so
// a stored token reaches emoji.list, unless PHOTOS is false.
function run(root, argv, runEnv, photos = true) {
    return new Promise(resolve => {
        const child = childProcess.spawn(process.execPath, [helper, "refresh", root].concat(photos ? ["--photos"] : [], argv), { cwd: repo, env: runEnv || env });
        let stdout = "";
        let stderr = "";
        child.stdout.setEncoding("utf8");
        child.stderr.setEncoding("utf8");
        child.stdout.on("data", chunk => { stdout += chunk; });
        child.stderr.on("data", chunk => { stderr += chunk; });
        child.on("close", status => resolve({ status, stdout, stderr }));
    });
}

async function runJson(root, argv, runEnv, photos = true) {
    const result = await run(root, argv, runEnv, photos);
    assert.equal(result.status, 0, result.stderr);
    return Object.assign(JSON.parse(result.stdout), { stderr: result.stderr });
}

function magickRuns() {
    return fs.existsSync(magickLog) ? fs.readFileSync(magickLog, "utf8").split("\n").filter(Boolean).length : 0;
}

function teamOf(output, id) {
    return (output.emoji || []).find(team => team.team === id) || null;
}

function file(root, id, hex) {
    return path.join(root, id, "emoji", hex + ".png");
}

async function main(port) {
    const bin = path.join(scratch, "bin");
    write(path.join(bin, "secret-tool"), `#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >>"${secretLog}"
[[ \${1:-} == lookup ]] || exit 2
account="\${5:-}"
while read -r name token; do
  if [[ $name == "$account" ]]; then printf '%s\\n' "$token"; exit 0; fi
done <"${tokenFile}"
exit 1
`, 0o700);
    // The wrapper logs one line per run, and with fail-chunks present
    // fails every run given more than one image.
    write(path.join(bin, "magick"), `#!/usr/bin/env bash
count=0
for arg in "$@"; do [[ $arg == "(" ]] && count=$((count + 1)); done
printf '%s\\n' "$count" >>"${magickLog}"
if [[ -e "${failChunks}" && $count -gt 1 ]]; then exit 1; fi
exec "${magick}" "$@"
`, 0o700);
    // A PATH with bash for the stubs and no ImageMagick.
    const bare = path.join(scratch, "bare-bin");
    fs.mkdirSync(bare, { recursive: true });
    fs.symlinkSync(path.join(bin, "secret-tool"), path.join(bare, "secret-tool"));
    fs.symlinkSync(fs.realpathSync(childProcess.spawnSync("sh", ["-c", "command -v bash"], { encoding: "utf8" }).stdout.trim()), path.join(bare, "bash"));
    env = {
        PATH: bin + path.delimiter + path.dirname(process.execPath) + path.delimiter + "/usr/bin:/bin",
        HOME: scratch,
        VGS_NOTIFICATIONS_SLACK_TEST: "1",
        VGS_NOTIFICATIONS_SLACK_TEST_SECRET_TOOL_DIR: bin,
        VGS_NOTIFICATIONS_SLACK_API_BASE: `http://127.0.0.1:${port}/api`
    };
    const api = `http://127.0.0.1:${port}/emoji`;

    // The synthetic cache: T1's emoji, one name cached twice, a name the
    // card would not substitute, T3's emoji no run lists, a key of another
    // host, a FIFO and a source past the size cap.
    const cache = path.join(scratch, "Slack", "Cache", "Cache_Data");
    const now = Math.floor(Date.now() / 1000);
    entry(cache, emojiUrl("T1", "party", "0000000000000001", "png"), BLUE, now - 3600);
    entry(cache, emojiUrl("T1", "party", "0000000000000002", "png"), RED, now - 60);
    entry(cache, emojiUrl("T1", "party-copy", "0000000000000003", "png"), RED, now - 50);
    entry(cache, emojiUrl("T1", "wave", "0000000000000004", "gif"), WAVE, now - 40);
    entry(cache, emojiUrl("T1", "photo", "0000000000000005", "jpg"), GREEN, now - 30);
    entry(cache, emojiUrl("T1", "changed", "0000000000000006", "png"), BLUE, now - 20);
    for (const [i, name] of ["__proto__", "constructor", "hasownproperty"].entries())
        entry(cache, emojiUrl("T1", name, "000000000000001" + i, "png"), YELLOW, now - 10);
    entry(cache, emojiUrl("T1", "Bad.Name", "0000000000000020", "png"), RED, now - 10);
    entry(cache, emojiUrl("T1", "huge", "0000000000000021", "png"), NOISE, now - 10);
    entry(cache, emojiUrl("T3", "other", "0000000000000022", "png"), RED, now - 10);
    entry(cache, "https://ca.slack-edge.com/T1-U1-abc-48", RED, now - 10);
    assert.equal(childProcess.spawnSync("mkfifo", [path.join(cache, "ffffffffffffffff_0")]).status, 0, "the FIFO fixture is made");
    assert.ok(NOISE.length > 256 * 1024, "the oversized fixture passes the source cap");

    // Refusals: --emoji takes an absolute directory.
    const refused = await run(path.join(scratch, "refused"), ["--emoji", "relative", "T1"]);
    assert.equal(refused.status, 2);
    assert.equal(refused.stderr.trim(), "notifications-slack-photos: refused: emoji want=<absolute cache dir>");

    // No token: the cache route alone.
    store({});
    const root = path.join(scratch, "root");
    const first = await runJson(root, ["--emoji", cache, "T1", "T2"]);
    assert.equal(first.status, "absent", "emoji leave the photos' absent status as it is");
    assert.equal(first.stderr, "notifications-slack-photos: emoji names=skipped count=1\nnotifications-slack-photos: emoji images=failed count=1\n", "a name outside the rule is skipped and the oversized source fails, each one line");
    const t1 = teamOf(first, "T1");
    assert.notEqual(t1, null, "a listed team with cached emoji has a map");
    assert.equal(teamOf(first, "T2"), null, "a team with no emoji has none");
    assert.equal(teamOf(first, "T3"), null, "an unlisted team's cached emoji are not read");
    assert.deepEqual(Object.keys(t1.map).sort(), ["__proto__", "constructor", "party", "party-copy", "photo", "hasownproperty", "wave", "changed"].sort(), "a known custom emoji is in the map, names like Object's members included");
    assert.equal(t1.count, 8);
    assert.equal(t1.pending, 0);
    for (const hex of Object.values(t1.map)) {
        assert.match(hex, /^[0-9a-f]{16}$/);
        assert.equal(crypto.createHash("sha256").update(fs.readFileSync(file(root, "T1", hex))).digest("hex").slice(0, 16), hex, "a file is named by its content");
    }
    assert.equal(describe(file(root, "T1", t1.map.party)), "48x48 srgba(255,0,0,1)", "the newest cache entry of a name wins, normalized to 48 by 48");
    assert.equal(t1.map["party-copy"], t1.map.party, "the same content shares one file");
    assert.equal(describe(file(root, "T1", t1.map.wave)), "48x48 srgba(255,0,0,1)", "a GIF gives its first frame");
    assert.match(describe(file(root, "T1", t1.map.photo)), /^48x48 srgba\(0,25[0-5],[0-9],1\)$/, "a JPEG is fitted into the square");
    const padded = childProcess.spawnSync(magick, [file(root, "T1", t1.map.photo), "-format", "%[pixel:p{1,24}]", "info:"], { encoding: "utf8" }).stdout;
    assert.equal(padded, "srgba(0,0,0,0)", "the square pads with transparency, keeping the aspect");
    assert.deepEqual(fs.readdirSync(root).sort(), ["T1"], "only the team with emoji keeps a directory, and no accounts file without a token");
    assert.deepEqual(fs.readdirSync(path.join(root, "T1")).sort(), ["emoji", "emoji.json"]);
    assert.equal(fs.readdirSync(path.join(root, "T1", "emoji")).length, new Set(Object.values(t1.map)).size, "emoji/ holds one file per image");

    // A second run converts nothing.
    let before = magickRuns();
    const again = await runJson(root, ["--emoji", cache, "T1", "T2"]);
    assert.deepEqual(teamOf(again, "T1").map, t1.map, "a second run answers the same map");
    assert.equal(magickRuns(), before, "a second run converts nothing");

    // With the Slack photos extra off, a stored token stays unread: the
    // emoji come from the cache alone and Slack's list is not asked.
    store({ "slack:T1": "xoxp-acme-4f2a", "slack:T2": "xoxp-globex-7c1d" });
    fs.writeFileSync(secretLog, "");
    const offSince = world.calls.length;
    const photosOff = await runJson(root, ["--emoji", cache, "T1", "T2"], undefined, false);
    assert.equal(photosOff.status, "off", "the photos extra off looks no token up");
    assert.deepEqual(Object.keys(teamOf(photosOff, "T1").map).sort(), Object.keys(t1.map).sort(), "the photos extra off keeps the cached emoji");
    assert.equal(fs.readFileSync(secretLog, "utf8"), "", "the photos extra off runs no secret-tool");
    assert.deepEqual(world.calls.slice(offSince), [], "the photos extra off asks Slack nothing");

    // A token for T1: emoji.list adds an alias and an API-only emoji, and a
    // cached name the API lists at another URL takes the API's image.
    world.list = {
        party: emojiUrl("T1", "party", "0000000000000002", "png"),
        yay: "alias:party",
        ghost: "alias:missing",
        apionly: api + "/apionly.png",
        changed: api + "/changed.png",
        elsewhere: "https://evil.example/x.png"
    };
    let since = world.calls.length;
    const listed = await runJson(root, ["--emoji", cache, "T1", "T2"]);
    const withApi = teamOf(listed, "T1");
    assert.equal(withApi.map.yay, withApi.map.party, "an alias resolves to its target's image");
    assert.equal(Object.prototype.hasOwnProperty.call(withApi.map, "ghost"), false, "an alias of no emoji is dropped");
    assert.equal(Object.prototype.hasOwnProperty.call(withApi.map, "elsewhere"), false, "an image outside Slack's hosts is dropped");
    assert.equal(describe(file(root, "T1", withApi.map.apionly)), "48x48 srgba(255,255,0,1)", "an emoji only the API lists is downloaded");
    assert.match(describe(file(root, "T1", withApi.map.changed)), /srgba\(0,255,255,1\)$/, "an updated emoji takes the API's image");
    assert.equal(listed.stderr.includes("team=T2"), false, "missing_scope prints no problem line");
    assert.equal(listed.stale, false, "missing_scope does not mark the output stale");
    assert.deepEqual(world.calls.slice(since).filter(c => c[1] === "emoji.list"), [["T1", "emoji.list"], ["T2", "emoji.list"]], "each team's token asks emoji.list once");
    since = world.calls.length;
    await runJson(root, ["--emoji", cache, "T1", "T2"]);
    assert.deepEqual(world.calls.slice(since).filter(c => c[1] === "emoji.list"), [], "emoji.list is asked at most once a day, missing_scope too");

    // An API failure keeps the previous list and is one line.
    const stateFile = path.join(root, "T1", "emoji.json");
    const state = JSON.parse(fs.readFileSync(stateFile, "utf8"));
    state.list.at -= 25 * 60 * 60 * 1000;
    write(stateFile, JSON.stringify(state));
    world.down = true;
    const down = await runJson(root, ["--emoji", cache, "T1"]);
    world.down = false;
    assert.match(down.stderr, /^notifications-slack-photos: emoji team=T1 api=emoji\.list error=ratelimited$/m, "an API failure is one line");
    assert.equal(teamOf(down, "T1").map.yay, withApi.map.yay, "an API failure keeps the previous list");

    // Swap grace: an emoji gone from the cache leaves the map, its file
    // stays one run for the cards the previous map drew, then goes.
    const photoHex = teamOf(down, "T1").map.photo;
    for (const name of fs.readdirSync(cache)) {
        const bytes = name.endsWith("_0") && fs.statSync(path.join(cache, name)).isFile() ? fs.readFileSync(path.join(cache, name)) : null;
        if (bytes !== null && bytes.includes(Buffer.from("/T1/photo/"))) fs.rmSync(path.join(cache, name));
    }
    const swapped = await runJson(root, ["--emoji", cache, "T1"]);
    assert.equal(Object.prototype.hasOwnProperty.call(teamOf(swapped, "T1").map, "photo"), false, "an emoji gone from the cache leaves the map");
    assert.equal(fs.existsSync(file(root, "T1", photoHex)), true, "the previous index's file survives one run");
    await runJson(root, ["--emoji", cache, "T1"]);
    assert.equal(fs.existsSync(file(root, "T1", photoHex)), false, "the file goes the run after");

    // A token that goes: its team keeps its emoji and loses its photos, and
    // a token stored again fetches the team afresh.
    const tokenRoot = path.join(scratch, "token-root");
    store({ "slack:T1": "xoxp-acme-4f2a" });
    const served = await runJson(tokenRoot, ["--emoji", cache, "T1"]);
    assert.deepEqual(served.teams.map(team => team.id), ["T1"], "the token serves its team's photos");
    assert.deepEqual(fs.readdirSync(path.join(tokenRoot, "T1")).sort(), ["emoji", "emoji.json", "team.json", "users", "users.json", "workspace.png"], "a served team holds its photos beside its emoji");
    store({});
    const unserved = await runJson(tokenRoot, ["--emoji", cache, "T1"]);
    assert.equal(unserved.status, "absent");
    assert.deepEqual(fs.readdirSync(path.join(tokenRoot, "T1")).sort(), ["emoji", "emoji.json"], "a team whose token is gone keeps its emoji and loses its photos");
    assert.ok(teamOf(unserved, "T1").count > 0, "the team's emoji stay in its map");
    store({ "slack:T1": "xoxp-acme-4f2a" });
    since = world.calls.length;
    await runJson(tokenRoot, ["--emoji", cache, "T1"]);
    assert.deepEqual(world.calls.slice(since).filter(c => c[1] === "team.info"), [["T1", "team.info"]], "a token stored again fetches the team afresh");
    store({});

    // A failed chunk is converted again one image a process.
    const chunkRoot = path.join(scratch, "chunk-root");
    write(failChunks, "");
    before = magickRuns();
    store({});
    const chunked = await runJson(chunkRoot, ["--emoji", cache, "T1"]);
    fs.rmSync(failChunks);
    assert.equal((teamOf(chunked, "T1") || { count: 0 }).count, 7, "every image converts after its chunk failed");
    assert.ok(magickRuns() - before >= 8, "the failed chunk ran again one image a process");

    // Budget: a run converts at most 256 images; the rest is pending, and
    // the next run finishes it.
    const bulk = path.join(scratch, "bulk", "Cache_Data");
    for (let i = 0; i < 260; i++) entry(bulk, emojiUrl("T2", "bulk" + i, String(i).padStart(16, "0"), "png"), image(["-size", "8x8", `xc:rgb(${i % 256},${Math.floor(i / 256)},7)`], "png"), now - i);
    const bulkRoot = path.join(scratch, "bulk-root");
    const partial = teamOf(await runJson(bulkRoot, ["--emoji", bulk, "T2"]), "T2");
    assert.deepEqual([partial.count, partial.pending], [256, 4], "a run converts at most its budget and reports the rest pending");
    const finished = teamOf(await runJson(bulkRoot, ["--emoji", bulk, "T2"]), "T2");
    assert.deepEqual([finished.count, finished.pending], [260, 0], "the next run converts what was pending");

    // No ImageMagick: one line, no emoji, and the cache is not read.
    const bareRun = await runJson(path.join(scratch, "bare-root"), ["--emoji", cache, "T1"], Object.assign({}, env, { PATH: bare }));
    assert.equal(bareRun.stderr, "notifications-slack-photos: emoji magick=missing\n");
    assert.deepEqual(bareRun.emoji, [], "no ImageMagick is no emoji");

    // Emoji off: the index empties and its files stay one run, then the
    // emoji state and the token-less team's directory go.
    const offHex = teamOf(swapped, "T1").map.party;
    const off = await runJson(root, ["T1"]);
    assert.equal(Object.prototype.hasOwnProperty.call(off, "emoji"), false, "with emoji off the output has no emoji list");
    assert.deepEqual(fs.existsSync(stateFile) ? JSON.parse(fs.readFileSync(stateFile, "utf8")).map : null, {}, "emoji off empties the index");
    assert.equal(fs.existsSync(file(root, "T1", offHex)), true, "the previous index's files survive the first run with emoji off");
    await runJson(root, ["T1"]);
    assert.equal(fs.existsSync(path.join(root, "T1")), false, "the second run with emoji off removes the emoji and the token-less team's directory");
}

function controls() {
    const source = fs.readFileSync(emojiSource, "utf8");
    const photos = fs.readFileSync(path.join(pluginDir, "slack-photos.js"), "utf8");
    const reader = fs.readFileSync(path.join(pluginDir, "slack-cache.js"), "utf8");
    const dir = path.join(scratch, "controls");
    const table = [
        ["a team with no token keeps its photos", "slack-photos.js", "if (emojiTeams.has(name)) sweepTeam(path.join(root, name), new Set(), null);", "if (emojiTeams.has(name)) continue;", /keeps its emoji and loses its photos/],
        ["newest entry wins", "slack-emoji.js", "mtimeMs > prior.mtimeMs", "mtimeMs < prior.mtimeMs", /the newest cache entry of a name wins/],
        ["name rule", "slack-emoji.js", "if (!NAME.test(match[2])) {", "if (false) {", /a name outside the rule is skipped/],
        ["first frame", "slack-emoji.js", "job.coder + \":\" + job.input + \"[0]\"", "job.coder + \":\" + job.input", /a GIF gives its first frame|a name outside the rule is skipped/],
        ["reuse", "slack-emoji.js", "previous.sources.get(candidate.name) === candidate.url ? previousHex(candidate.name) : \"\"", "\"\"", /a second run converts nothing/],
        ["alias resolution", "slack-emoji.js", "const target = map.get(value.slice(\"alias:\".length));", "const target = undefined;", /an alias resolves/],
        ["missing_scope is steady", "slack-emoji.js", "if (/ error=missing_scope$/.test(reason))", "if (false)", /missing_scope prints no problem line/],
        ["the list is asked daily", "slack-emoji.js", "if (stored !== null && now - stored.at < DAY_MS) return stored;", "", /emoji.list is asked at most once a day/],
        ["swap grace", "slack-emoji.js", "new Set(Array.from(map.values()).concat(Array.from(previous.map.values())))", "new Set(Array.from(map.values()))", /the previous index's file survives one run/],
        ["chunk fallback", "slack-emoji.js", "const alone = !magickRun(magick, chunk, CHUNK_TIMEOUT_MS);", "const alone = !magickRun(magick, chunk, CHUNK_TIMEOUT_MS) && false;", /every image converts after its chunk failed/],
        ["work budget", "slack-emoji.js", "if (work.remaining <= 0) {", "if (false) {", /a run converts at most its budget/],
        ["the photos extra off reads no token for the list", "slack-photos.js", "const tokens = photos ? storedTokens(ids, lines) : [];", "const tokens = storedTokens(ids, lines);", /the photos extra off runs no secret-tool/],
        ["disabled grace", "slack-emoji.js", "writeState(root, id, { map: new Map(), sources: new Map(), list: null }, deps.atomicWrite);\n    sweepFiles(root, id, new Set(previous.map.values()));\n    return true;", "removeState(root, id);\n    return false;", /emoji off empties the index|survive the first run with emoji off/]
    ];
    let passed = 0;
    for (let index = 0; index < table.length; index++) {
        const [label, target, needle, replacement, failure] = table[index];
        const sources = { "slack-emoji.js": source, "slack-photos.js": photos, "slack-cache.js": reader };
        assert.equal(sources[target].split(needle).length, 2, `control "${label}": the text to replace must occur once`);
        const copyDir = path.join(dir, String(index));
        fs.mkdirSync(copyDir, { recursive: true });
        for (const name of Object.keys(sources))
            fs.writeFileSync(path.join(copyDir, name), name === target ? sources[name].replace(needle, () => replacement) : sources[name], { mode: 0o700 });
        const result = childProcess.spawnSync(process.execPath, [__filename], {
            cwd: repo,
            env: { PATH: process.env.PATH, NOTIFICATIONS_SLACK_EMOJI_HELPER: path.join(copyDir, "slack-photos.js"), NOTIFICATIONS_SLACK_EMOJI_SKIP_CONTROLS: "1" },
            encoding: "utf8",
            maxBuffer: 8 * 1024 * 1024,
            timeout: 180000
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
        const controlCount = process.env.NOTIFICATIONS_SLACK_EMOJI_SKIP_CONTROLS === "1" ? 0 : controls();
        fs.rmSync(scratch, { recursive: true, force: true });
        console.log("test-notifications-slack-emoji: ok controls=" + controlCount);
    })
    .catch(error => {
        fs.rmSync(scratch, { recursive: true, force: true });
        console.error(error && error.stack ? error.stack : String(error));
        process.exit(1);
    });
