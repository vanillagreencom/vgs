"use strict";

// Each listed Slack team's custom emoji, for slack-photos.js, which runs
// this once per helper run after the photos, from the one Process in
// SlackPhotos.qml, so an emoji write never races a photo sweep.
//
// Sources, per listed team id:
//  1. Slack's own disk cache, read-only and with no token, through its one
//     reader, slack-cache.js: the entries whose URL is https://
//     emoji.slack-edge.com/<team id>/<emoji name>/<16 hex>.<png|gif|jpg>.
//     One listing per run; a body is read only for an entry the run
//     converts. A name cached twice takes the entry with the newest mtime.
//  2. emoji.list, with the token that serves the team, at most once a day:
//     a name the cache lacks, a name whose image changed since Slack cached
//     it, and aliases, `alias:<target>`, which take their target's image.
//     `missing_scope` is a steady state, retried daily with no problem
//     line; another failure is one line and keeps the previous list.
//
// A team's directory holds emoji.json, the team's index and this module's
// state, and emoji/<16 hex>.png, one normalized image per content, named by
// the first 16 hex digits of its SHA-256, so an alias and a duplicate
// share one file. The index is written by rename after every file it names
// is in place, and the emoji/ sweep keeps the files of the previous index
// too, for one run, so a card drawn from the map the shell held before
// this run never names a deleted file.
//
// ImageMagick draws each image's first frame, fitted into a transparent
// SIDE by SIDE square, as a PNG with no metadata, CHUNK images a process.
// A chunk that fails is converted again one image a process. The input's
// coder is named from its magic bytes, so ImageMagick never guesses a
// format from bytes Slack's cache holds.

const childProcess = require("node:child_process");
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const cache = require("./slack-cache.js");

const EMOJI_FILE = "emoji.json";
const EMOJI_DIR = "emoji";
// A name NotificationLogic.EMOJI_NAME admits; the card substitutes only
// these.
const NAME = /^[a-z0-9_+-]{1,100}$/;
const HEX = /^[0-9a-f]{16}$/;
const FILE_NAME = /^([0-9a-f]{16})\.png$/;
const URL_PREFIX = "https://emoji.slack-edge.com/";
const EMOJI_URL = /^https:\/\/emoji\.slack-edge\.com\/([A-Za-z0-9]{1,32})\/([^/]{1,100})\/[0-9a-f]{16}\.(?:png|gif|jpg)$/;
// Limits.
const SOURCE_MAX = 256 * 1024;
const FILE_MAX = 64 * 1024;
const TEAM_COUNT_MAX = 2048;
const TEAM_BYTES_MAX = 8 * 1024 * 1024;
const LIST_MAX = 8192;
// New conversions a run makes across every team; the rest is `pending`,
// which schedules the next run within a minute.
const WORK_MAX = 256;
const CHUNK = 32;
const SIDE = 48;
const CHUNK_TIMEOUT_MS = 60000;
const ONE_TIMEOUT_MS = 10000;
const DAY_MS = 24 * 60 * 60 * 1000;
const RETRY_MS = 15 * 60 * 1000;
const CODERS = [
    ["png", Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])],
    ["gif", Buffer.from("GIF8", "latin1")],
    ["jpeg", Buffer.from([0xff, 0xd8, 0xff])]
];

function problem(text) {
    return "notifications-slack-photos: emoji " + text;
}

function executableOnPath(command, envPath) {
    for (const dir of String(envPath || "").split(path.delimiter)) {
        if (dir === "") continue;
        const candidate = path.join(dir, command);
        try {
            fs.accessSync(candidate, fs.constants.X_OK);
            if (fs.statSync(candidate).isFile()) return candidate;
        } catch (_e) {
            // Keep looking.
        }
    }
    return "";
}

function coderOf(bytes) {
    for (const [coder, magic] of CODERS)
        if (bytes.length > magic.length && bytes.subarray(0, magic.length).equals(magic)) return coder;
    return "";
}

function hexOf(bytes) {
    return crypto.createHash("sha256").update(bytes).digest("hex").slice(0, 16);
}

// One listing of Slack's cache: team id -> Map name -> { url, mtimeMs }
// for the listed teams, the newest entry per name. `skipped` counts emoji
// of a listed team whose name the card would not substitute.
function scanCache(dir, listed) {
    const found = new Map();
    const listing = cache.list(dir, URL_PREFIX);
    const result = { found, skipped: 0, problem: listing.problem === "" ? "" : problem("cache=" + listing.problem) };
    for (const { url, mtimeMs } of listing.entries) {
        const match = EMOJI_URL.exec(url);
        if (match === null || !listed.has(match[1])) continue;
        if (!NAME.test(match[2])) {
            result.skipped += 1;
            continue;
        }
        if (!found.has(match[1])) found.set(match[1], new Map());
        const team = found.get(match[1]);
        const prior = team.get(match[2]);
        if (prior === undefined || mtimeMs > prior.mtimeMs) team.set(match[2], { url, mtimeMs });
    }
    return result;
}

// Name-keyed values read from JSON: a Map of the own properties whose name
// passes NAME and whose value passes `keep`.
function nameMap(object, keep) {
    const out = new Map();
    if (object === null || typeof object !== "object" || Array.isArray(object)) return out;
    for (const name of Object.keys(object))
        if (NAME.test(name) && keep(object[name])) out.set(name, object[name]);
    return out;
}

function isNumber(value) {
    return typeof value === "number" && isFinite(value);
}

// A team's emoji.json as this module wrote it: { map, sources, list }, the
// maps as Maps, `list` null for a team served by no token. A missing or
// foreign file reads as empty.
function readState(root, id, readJson) {
    const empty = { map: new Map(), sources: new Map(), list: null };
    const stored = readJson(path.join(root, id, EMOJI_FILE));
    if (stored === null || typeof stored !== "object" || stored.team !== id) return empty;
    const list = stored.list !== null && typeof stored.list === "object" && isNumber(stored.list.at) && isNumber(stored.list.failedAt) && typeof stored.list.error === "string"
        ? { at: stored.list.at, failedAt: stored.list.failedAt, error: stored.list.error, names: nameMap(stored.list.names, value => typeof value === "string") }
        : null;
    return {
        map: nameMap(stored.map, value => typeof value === "string" && HEX.test(value)),
        sources: nameMap(stored.sources, value => typeof value === "string"),
        list
    };
}

function writeState(root, id, state, atomicWrite) {
    const list = state.list === null ? null : { at: state.list.at, failedAt: state.list.failedAt, error: state.list.error, names: Object.fromEntries(state.list.names) };
    atomicWrite(path.join(root, id, EMOJI_FILE), JSON.stringify({
        team: id,
        map: Object.fromEntries(state.map),
        sources: Object.fromEntries(state.sources),
        list
    }) + "\n");
}

// Every file in emoji/ but the images `keep` names.
function sweepFiles(root, id, keep) {
    const dir = path.join(root, id, EMOJI_DIR);
    let names;
    try {
        names = fs.readdirSync(dir);
    } catch (e) {
        if (e.code === "ENOENT") return;
        throw e;
    }
    for (const name of names) {
        const match = FILE_NAME.exec(name);
        if (match === null || !keep.has(match[1])) fs.rmSync(path.join(dir, name), { force: true, recursive: true });
    }
}

function removeState(root, id) {
    fs.rmSync(path.join(root, id, EMOJI_FILE), { force: true });
    fs.rmSync(path.join(root, id, EMOJI_DIR), { force: true, recursive: true });
}

function fileHolds(root, id, hex) {
    try {
        const stat = fs.statSync(path.join(root, id, EMOJI_DIR, hex + ".png"));
        return stat.isFile() && stat.size > 0 && stat.size <= FILE_MAX;
    } catch (_e) {
        return false;
    }
}

// The team ids under the root with an emoji index.
function stateTeams(root) {
    let names;
    try {
        names = fs.readdirSync(root);
    } catch (e) {
        if (e.code === "ENOENT") return [];
        throw e;
    }
    return names.filter(name => /^[A-Za-z0-9]{1,32}$/.test(name) && fs.existsSync(path.join(root, name, EMOJI_FILE)));
}

// A team whose emoji the run does not build: its index is emptied and the
// previous index's files kept for one run; once both are empty, its emoji
// state goes. Answers whether the team still holds emoji state.
function retire(root, id, deps) {
    const previous = readState(root, id, deps.readJson);
    if (previous.map.size === 0) {
        removeState(root, id);
        return false;
    }
    writeState(root, id, { map: new Map(), sources: new Map(), list: null }, deps.atomicWrite);
    sweepFiles(root, id, new Set(previous.map.values()));
    return true;
}

// The team's API list for this run: the stored one while it is under a
// day old or a failure is under RETRY_MS old, else emoji.list asked again.
// A team no token serves has none.
function teamList(id, previous, token, deps, lines) {
    if (token === "") return null;
    const now = deps.now();
    const stored = previous.list;
    if (stored !== null && now - stored.at < DAY_MS) return stored;
    if (stored !== null && now - stored.failedAt < RETRY_MS) return stored;
    let raw;
    try {
        raw = deps.listEmoji(token);
    } catch (e) {
        const reason = String(e && e.message || "failed");
        if (/ error=missing_scope$/.test(reason)) return { at: now, failedAt: 0, error: "missing_scope", names: new Map() };
        lines.push(problem("team=" + id + " " + deps.redact(reason)));
        const kept = stored === null ? { at: 0, names: new Map() } : stored;
        return { at: kept.at, failedAt: now, error: "failed", names: kept.names };
    }
    const names = new Map();
    for (const [name, value] of nameMap(raw, value => typeof value === "string")) {
        if (names.size >= LIST_MAX) break;
        const alias = /^alias:(.+)$/.exec(value);
        if (alias !== null ? NAME.test(alias[1]) : deps.allowedUrl(value)) names.set(name, value);
    }
    return { at: now, failedAt: 0, error: "", names };
}

// The images a team's map may hold, in the order the caps keep them:
// cache entries newest first, then names only the API lists, by name. A
// cached name the API lists with another URL takes the API's image, since
// the emoji was updated after Slack cached it.
function candidates(cached, list) {
    const apiUrl = name => {
        if (list === null || !list.names.has(name)) return "";
        const value = list.names.get(name);
        return value.startsWith("alias:") ? "" : value;
    };
    const out = [];
    const fromCache = cached === undefined ? [] : Array.from(cached.entries())
        .sort((a, b) => b[1].mtimeMs - a[1].mtimeMs || (a[0] < b[0] ? -1 : 1));
    for (const [name, entry] of fromCache) {
        const api = apiUrl(name);
        out.push(api !== "" && api !== entry.url ? { name, url: api, entry: null } : { name, url: entry.url, entry });
    }
    if (list !== null) {
        for (const name of Array.from(list.names.keys()).sort()) {
            if (cached !== undefined && cached.has(name)) continue;
            const api = apiUrl(name);
            if (api !== "") out.push({ name, url: api, entry: null });
        }
    }
    return out;
}

// One ImageMagick run over `jobs`, [{ input, coder, output }]: answers
// whether it exited 0.
function magickRun(magick, jobs, timeout) {
    const args = ["-limit", "memory", "64MiB", "-limit", "map", "128MiB", "-limit", "time", String(Math.ceil(timeout / 1000))];
    for (const job of jobs) {
        args.push("(", job.coder + ":" + job.input + "[0]", "+repage", "-auto-orient", "-background", "none",
            "-resize", SIDE + "x" + SIDE, "-gravity", "center", "-extent", SIDE + "x" + SIDE, "-strip",
            "-write", "PNG32:" + job.output, "+delete", ")");
    }
    args.push("null:");
    const run = childProcess.spawnSync(magick, args, { stdio: ["ignore", "ignore", "pipe"], timeout, maxBuffer: 1024 * 1024 });
    return !run.error && run.status === 0;
}

function convertedBytes(file) {
    try {
        const bytes = fs.readFileSync(file);
        return bytes.length > 0 && bytes.length <= FILE_MAX && coderOf(bytes) === "png" ? bytes : null;
    } catch (_e) {
        return null;
    }
}

// Convert every job, CHUNK a process, a failed chunk again one job a
// process: job -> the normalized PNG's bytes, for the jobs that made one.
function convertAll(magick, jobs) {
    const done = new Map();
    for (let at = 0; at < jobs.length; at += CHUNK) {
        const chunk = jobs.slice(at, at + CHUNK);
        const alone = !magickRun(magick, chunk, CHUNK_TIMEOUT_MS);
        for (const job of chunk) {
            if (alone) {
                fs.rmSync(job.output, { force: true });
                if (!magickRun(magick, [job], ONE_TIMEOUT_MS)) continue;
            }
            const bytes = convertedBytes(job.output);
            if (bytes !== null) done.set(job, bytes);
        }
    }
    return done;
}

// Put `bytes` at emoji/<hex>.png unless that content is already there.
function install(root, id, bytes, atomicWrite) {
    const hex = hexOf(bytes);
    if (!fileHolds(root, id, hex)) atomicWrite(path.join(root, id, EMOJI_DIR, hex + ".png"), bytes);
    return hex;
}

// The run for one team: its new state and how many images wait for a
// later run. `work` is the run's conversion budget, shared by the teams.
function buildTeam(root, id, cacheDir, cached, list, previous, work, deps, stats) {
    const chosen = [];
    const jobs = [];
    let pending = 0;
    const previousHex = name => {
        const hex = previous.map.get(name);
        return hex !== undefined && fileHolds(root, id, hex) ? hex : "";
    };
    for (const candidate of candidates(cached, list)) {
        if (chosen.length >= TEAM_COUNT_MAX) break;
        const reused = previous.sources.get(candidate.name) === candidate.url ? previousHex(candidate.name) : "";
        if (reused !== "") {
            chosen.push({ candidate, hex: reused });
            continue;
        }
        if (work.remaining <= 0) {
            pending += 1;
            // An updated emoji keeps its older image until it is converted.
            const older = previousHex(candidate.name);
            if (older !== "") chosen.push({ candidate: { name: candidate.name, url: previous.sources.get(candidate.name) || "" }, hex: older });
            continue;
        }
        work.remaining -= 1;
        const slot = { candidate, hex: "" };
        chosen.push(slot);
        jobs.push(slot);
    }
    if (jobs.length > 0) {
        const ready = [];
        for (const slot of jobs) {
            const input = path.join(work.dir(), String(work.next++));
            let bytes = null;
            if (slot.candidate.entry !== null) {
                const body = cache.read(cacheDir, slot.candidate.entry.url, SOURCE_MAX);
                if (body.ok) bytes = body.bytes;
            } else if (deps.download(slot.candidate.url, input, SOURCE_MAX) === "saved") {
                bytes = fs.readFileSync(input);
            }
            const coder = bytes === null ? "" : coderOf(bytes);
            if (coder === "") continue;
            if (slot.candidate.entry !== null) fs.writeFileSync(input, bytes, { mode: 0o600 });
            ready.push({ slot, input, coder, output: input + ".png" });
        }
        for (const [job, bytes] of convertAll(deps.magick, ready)) job.slot.hex = install(root, id, bytes, deps.atomicWrite);
        // A failed image keeps its older one, when there is one.
        for (const slot of jobs) {
            if (slot.hex !== "") continue;
            stats.failed += 1;
            slot.hex = previousHex(slot.candidate.name);
            if (slot.hex !== "") slot.candidate = { name: slot.candidate.name, url: previous.sources.get(slot.candidate.name) || "" };
        }
    }
    // The caps, in candidate order: an image that would pass the team's
    // bytes is left out; a file shared by two names counts once.
    const map = new Map();
    const sources = new Map();
    const sized = new Map();
    let bytes = 0;
    for (const { candidate, hex } of chosen) {
        if (hex === "") continue;
        if (!sized.has(hex)) {
            const size = fs.statSync(path.join(root, id, EMOJI_DIR, hex + ".png")).size;
            if (bytes + size > TEAM_BYTES_MAX) {
                stats.capped += 1;
                continue;
            }
            bytes += size;
            sized.set(hex, size);
        }
        map.set(candidate.name, hex);
        sources.set(candidate.name, candidate.url);
    }
    if (list !== null) {
        for (const name of Array.from(list.names.keys()).sort()) {
            const value = list.names.get(name);
            if (!value.startsWith("alias:") || map.has(name)) continue;
            const target = map.get(value.slice("alias:".length));
            if (target === undefined) continue;
            if (map.size >= TEAM_COUNT_MAX) {
                stats.capped += 1;
                break;
            }
            map.set(name, target);
        }
    }
    return { state: { map, sources, list }, pending };
}

// The run over every team. `ids` are the listed team ids; `cacheDir` is
// Slack's Cache_Data. `deps` supplies what slack-photos.js owns:
// readJson, atomicWrite, download(url, file, max), listEmoji(token),
// allowedUrl(url), redact(text), tokenFor(id), now(), env PATH. Answers {
// kept, teams }: the team ids whose directory holds emoji state, and one
// { team, map, count, pending } per team with emoji or pending work, `map`
// name -> the 16 hex of its file.
function refresh(root, cacheDir, ids, deps, lines) {
    const kept = new Set();
    const teams = [];
    const listed = new Set(ids);
    for (const id of stateTeams(root))
        if (!listed.has(id) && retire(root, id, deps)) kept.add(id);
    if (ids.length === 0) return { kept, teams };
    const magick = executableOnPath("magick", deps.path) || executableOnPath("convert", deps.path);
    if (magick === "") {
        lines.push(problem("magick=missing"));
        for (const id of ids)
            if (retire(root, id, deps)) kept.add(id);
        return { kept, teams };
    }
    const scan = scanCache(cacheDir, listed);
    if (scan.problem !== "") lines.push(scan.problem);
    if (scan.skipped > 0) lines.push(problem("names=skipped count=" + scan.skipped));
    let scratch = "";
    const work = {
        remaining: WORK_MAX,
        next: 0,
        dir: () => {
            if (scratch === "") {
                fs.mkdirSync(root, { recursive: true, mode: 0o700 });
                scratch = fs.mkdtempSync(path.join(root, ".emoji-work-"));
            }
            return scratch;
        }
    };
    const stats = { failed: 0, capped: 0 };
    const runDeps = Object.assign({}, deps, { magick });
    try {
        for (const id of ids) {
            const previous = readState(root, id, deps.readJson);
            const list = teamList(id, previous, deps.tokenFor(id), deps, lines);
            const built = buildTeam(root, id, cacheDir, scan.found.get(id), list, previous, work, runDeps, stats);
            const { map } = built.state;
            if (map.size === 0 && previous.map.size === 0 && list === null && built.pending === 0) {
                removeState(root, id);
                continue;
            }
            writeState(root, id, built.state, deps.atomicWrite);
            sweepFiles(root, id, new Set(Array.from(map.values()).concat(Array.from(previous.map.values()))));
            kept.add(id);
            if (map.size > 0 || built.pending > 0) teams.push({ team: id, map: Object.fromEntries(map), count: map.size, pending: built.pending });
        }
    } finally {
        if (scratch !== "") fs.rmSync(scratch, { force: true, recursive: true });
    }
    if (stats.failed > 0) lines.push(problem("images=failed count=" + stats.failed));
    if (stats.capped > 0) lines.push(problem("images=capped count=" + stats.capped));
    return { kept, teams };
}

// Emoji off: every team's index is emptied, its files kept one run, then
// removed.
function disable(root, deps) {
    const kept = new Set();
    for (const id of stateTeams(root))
        if (retire(root, id, deps)) kept.add(id);
    return kept;
}

module.exports = { refresh, disable, SOURCE_MAX };
