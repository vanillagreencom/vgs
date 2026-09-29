#!/usr/bin/env node
"use strict";

const childProcess = require("node:child_process");
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const emoji = require("./slack-emoji.js");

// The libsecret item of an account: service vgs-notifications, account
// `slack:<team id>` for one workspace's token and `slack` for the
// single-workspace token, whose workspace team.info names.
const SERVICE = ["service", "vgs-notifications", "account"];
const LEGACY = "slack";
// The most team ids one run takes, NotificationLogic.WORKSPACES_MAX.
const TEAMS_MAX = 16;
const DAILY_MS = 24 * 60 * 60 * 1000;
const RETRY_MS = 15 * 60 * 1000;
const MAX_USERS = 512;
const MAX_IMAGE_BYTES = 512 * 1024;
const MAX_CACHE_BYTES = 10 * 1024 * 1024;
const API_DEFAULT = "https://slack.com/api";
// A team's directory, <root>/<team id>/, holds these names, each the
// helper's: team.json, the team's names, icon, the account that served it
// and when; workspace.png; users.json, each cached user's id, names and
// photo; and users/, one <user id>.png per photo. The team sweep deletes
// only these names, its own temporary files and the flat <user id>.png
// photos an older layout kept beside team.json, so another artifact of the
// team, its custom emoji (slack-emoji.js), sits in the directory beside
// them.
const TEAM_FILES = ["team.json", "users.json", "workspace.png"];
const USERS_DIR = "users";
// The root holds accounts.json, each account's resolved team and its last
// failure, and one directory per team a stored token serves or whose custom
// emoji are cached; the root sweep removes anything else.
const ACCOUNTS_FILE = "accounts.json";
const TEMP_NAME = /^\..+\.[0-9]+\.(?:tmp|download|resized)$/;

function usage(reason) {
    console.error("notifications-slack-photos: refused: " + reason);
    process.exit(2);
}

function fail(code, line) {
    console.error(line);
    process.exit(code);
}

function safeSegment(value) {
    return typeof value === "string" && /^[A-Za-z0-9]{1,32}$/.test(value) ? value : "";
}

function mkdir(dir) {
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
}

function inside(root, file) {
    const resolvedRoot = path.resolve(root);
    const resolvedFile = path.resolve(file);
    return resolvedFile === resolvedRoot || resolvedFile.startsWith(resolvedRoot + path.sep);
}

function atomicWrite(file, text) {
    const dir = path.dirname(file);
    mkdir(dir);
    if (!inside(dir, file)) throw new Error("outside");
    const tmp = path.join(dir, "." + path.basename(file) + "." + process.pid + ".tmp");
    fs.writeFileSync(tmp, text, { mode: 0o600 });
    fs.renameSync(tmp, file);
}

function readJson(file) {
    try {
        return JSON.parse(fs.readFileSync(file, "utf8"));
    } catch (_e) {
        return null;
    }
}

function writeJson(file, value) {
    atomicWrite(file, JSON.stringify(value, null, 2) + "\n");
}

function output(value) {
    process.stdout.write(JSON.stringify(value) + "\n");
}

function commandPath(command) {
    const found = childProcess.spawnSync("sh", ["-c", "command -v -- \"$1\"", "sh", command], { encoding: "utf8" });
    if (found.status !== 0) return "";
    return found.stdout.trim().split(/\n/)[0] || "";
}

function executableOnPath(command) {
    const dirs = String(process.env.PATH || "").split(path.delimiter);
    for (const dir of dirs) {
        if (dir === "") continue;
        const candidate = path.join(dir, command);
        try {
            const stat = fs.statSync(candidate);
            fs.accessSync(candidate, fs.constants.X_OK);
            if (stat.isFile()) return candidate;
        } catch (_e) {
            // Keep looking.
        }
    }
    return "";
}

function assertTestSecretToolPath() {
    const dir = process.env.VGS_NOTIFICATIONS_SLACK_TEST_SECRET_TOOL_DIR;
    if (!dir) return;
    const found = executableOnPath("secret-tool");
    const testDir = fs.realpathSync(dir);
    const realFound = found === "" ? "" : fs.realpathSync(found);
    if (realFound !== "" && !inside(testDir, realFound)) {
        fail(5, "notifications-slack-photos: secret-tool=test-stub-required");
    }
}

// One account's token: { state: "token", token }, { state: "none" } for no
// stored token, { state: "no-tool" } with no secret-tool installed, or
// { state: "failed", line } naming the failure, never the token.
function lookupToken(account) {
    const secret = childProcess.spawnSync("secret-tool", ["lookup"].concat(SERVICE, [account]), {
        encoding: "utf8",
        maxBuffer: 1024 * 1024
    });
    if (secret.error && secret.error.code === "ENOENT") return { state: "no-tool" };
    const failed = detail => ({ state: "failed", line: "notifications-slack-photos: account=" + account + " secret-tool=failed" + detail });
    if (secret.error) return failed("");
    if (secret.status === 1) return { state: "none" };
    if (secret.status !== 0) return failed(" status=" + secret.status);
    const token = String(secret.stdout || "").replace(/\r?\n$/, "");
    if (token === "") return { state: "none" };
    if (/[\r\n"]/.test(token)) return { state: "failed", line: "notifications-slack-photos: account=" + account + " token=invalid" };
    return { state: "token", token };
}

function apiBase() {
    if (process.env.VGS_NOTIFICATIONS_SLACK_TEST === "1" && process.env.VGS_NOTIFICATIONS_SLACK_API_BASE) {
        const url = new URL(process.env.VGS_NOTIFICATIONS_SLACK_API_BASE);
        if (url.protocol !== "http:" || (url.hostname !== "127.0.0.1" && url.hostname !== "localhost")) {
            fail(2, "notifications-slack-photos: refused: api-base=test-localhost");
        }
        return url.toString().replace(/\/$/, "");
    }
    return API_DEFAULT;
}

function curlConfig(url, token) {
    return [
        "silent",
        "show-error",
        "fail",
        "max-time = 10",
        "connect-timeout = 5",
        "header = \"Authorization: Bearer " + token.replace(/"/g, "") + "\"",
        "url = \"" + url.replace(/"/g, "%22") + "\"",
        ""
    ].join("\n");
}

function apiCall(base, token, method, params) {
    const url = new URL(base + "/" + method);
    for (const key of Object.keys(params || {})) {
        if (params[key] !== "") url.searchParams.set(key, params[key]);
    }
    const curl = childProcess.spawnSync("curl", ["--config", "-"], {
        input: curlConfig(url.toString(), token),
        encoding: "utf8",
        maxBuffer: 8 * 1024 * 1024
    });
    if (curl.error && curl.error.code === "ENOENT") {
        throw new Error("curl=missing");
    }
    if (curl.error || curl.status !== 0) {
        throw new Error("api=" + method + " curl=failed status=" + (curl.error ? "spawn" : curl.status));
    }
    let parsed;
    try {
        parsed = JSON.parse(curl.stdout);
    } catch (_e) {
        throw new Error("api=" + method + " json=invalid");
    }
    if (!parsed || parsed.ok !== true) {
        const code = parsed && typeof parsed.error === "string" ? parsed.error.replace(/[^A-Za-z0-9_.-]/g, "_") : "unknown";
        throw new Error("api=" + method + " error=" + code);
    }
    return parsed;
}

function allowedImageUrl(value) {
    let url;
    try {
        url = new URL(String(value || ""));
    } catch (_e) {
        return false;
    }
    if (process.env.VGS_NOTIFICATIONS_SLACK_TEST === "1") {
        return url.protocol === "http:" && (url.hostname === "127.0.0.1" || url.hostname === "localhost");
    }
    if (url.protocol !== "https:") return false;
    return url.hostname === "avatars.slack-edge.com"
        || url.hostname.endsWith(".slack-edge.com")
        || url.hostname === "secure.gravatar.com";
}

function downloadProtocolArgs() {
    return process.env.VGS_NOTIFICATIONS_SLACK_TEST === "1"
        ? ["--proto", "=http,https", "--proto-redir", "=http,https"]
        : ["--proto", "=https", "--proto-redir", "=https"];
}

// Download an image URL on Slack's image hosts to `file`, at most `max`
// bytes: "saved", "skipped" for a URL outside those hosts, or "failed",
// which leaves no file.
function fetchImage(url, file, max) {
    if (!allowedImageUrl(url)) return "skipped";
    const curl = childProcess.spawnSync("curl", [
        "--silent", "--show-error", "--fail", "--location",
        "--max-redirs", "3",
        ...downloadProtocolArgs(),
        "--max-time", "10", "--connect-timeout", "5",
        "--max-filesize", String(max),
        "--output", file,
        url
    ], { encoding: "utf8", maxBuffer: 1024 * 1024 });
    const size = !curl.error && curl.status === 0 && fs.existsSync(file) ? fs.statSync(file).size : 0;
    if (size <= 0 || size > max) {
        fs.rmSync(file, { force: true });
        return "failed";
    }
    return "saved";
}

function downloadImage(url, file) {
    if (!allowedImageUrl(url)) return "skipped";
    const dir = path.dirname(file);
    mkdir(dir);
    if (!inside(dir, file)) return "skipped";
    const tmp = path.join(dir, "." + path.basename(file) + "." + process.pid + ".download");
    if (fetchImage(url, tmp, MAX_IMAGE_BYTES) !== "saved") return "failed";
    const magick = commandPath("magick") || commandPath("convert");
    if (magick !== "") {
        const resized = path.join(dir, "." + path.basename(file) + "." + process.pid + ".resized");
        const args = magick.endsWith("magick")
            ? [tmp, "-resize", "48x48^", "-gravity", "center", "-extent", "48x48", resized]
            : [tmp, "-resize", "48x48^", "-gravity", "center", "-extent", "48x48", resized];
        const resize = childProcess.spawnSync(magick, args, { encoding: "utf8", maxBuffer: 1024 * 1024 });
        if (!resize.error && resize.status === 0 && fs.existsSync(resized) && fs.statSync(resized).size > 0) {
            fs.rmSync(tmp, { force: true });
            fs.renameSync(resized, file);
            return "saved";
        }
        fs.rmSync(resized, { force: true });
    }
    fs.renameSync(tmp, file);
    return "saved";
}

function uniqueNames(values) {
    const out = [];
    const seen = new Set();
    for (const value of values) {
        if (typeof value !== "string") continue;
        const name = value.trim();
        const key = name.toLowerCase();
        if (key === "" || seen.has(key)) continue;
        seen.add(key);
        out.push(name);
    }
    return out;
}

function keepExistingImage(file, budget, keepName) {
    if (!fs.existsSync(file)) return "";
    const size = fs.statSync(file).size;
    if (size <= 0 || size > MAX_IMAGE_BYTES || size > budget.remaining) return "";
    budget.remaining -= size;
    budget.keep.add(keepName);
    return versionedFileUrl(file);
}

function fileVersion(file) {
    return crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex").slice(0, 16);
}

function versionedFileUrl(file) {
    return "file://" + file + "?v=" + fileVersion(file);
}

function userRecord(user, usersDir, budget, stats) {
    const id = safeSegment(user && user.id);
    if (id === "") return null;
    const profile = user && user.profile && typeof user.profile === "object" ? user.profile : {};
    const names = uniqueNames([profile.display_name, profile.real_name, user.real_name, user.name]);
    if (names.length === 0) return null;
    let photo = "";
    const wanted = path.join(usersDir, id + ".png");
    if (budget.remaining > 0 && typeof profile.image_48 === "string") {
        const downloaded = downloadImage(profile.image_48, wanted);
        if (downloaded === "failed") stats.downloadFailed += 1;
        if (downloaded === "failed") photo = keepExistingImage(wanted, budget, path.basename(wanted));
        if (downloaded !== "saved") return { id, names, photo };
        const size = fs.statSync(wanted).size;
        if (size <= budget.remaining) {
            budget.remaining -= size;
            photo = versionedFileUrl(wanted);
            budget.keep.add(path.basename(wanted));
        } else {
            fs.rmSync(wanted, { force: true });
        }
    }
    return { id, names, photo };
}

function remove(file) {
    fs.rmSync(file, { force: true, recursive: true });
}

// A team directory's own names that this run did not keep: its files and
// photos, its temporary files and an older layout's flat photos. Any other
// name stays. `keepUsers` null drops users/ whole.
function sweepTeam(dir, keep, keepUsers) {
    for (const name of fs.readdirSync(dir)) {
        if (name === USERS_DIR) {
            const usersDir = path.join(dir, USERS_DIR);
            if (keepUsers === null) {
                remove(usersDir);
                continue;
            }
            for (const user of fs.readdirSync(usersDir))
                if (!keepUsers.has(user)) remove(path.join(usersDir, user));
        } else if (TEAM_FILES.indexOf(name) !== -1 ? !keep.has(name) : (/\.png$/.test(name) || TEMP_NAME.test(name))) {
            remove(path.join(dir, name));
        }
    }
}

// Everything under the root but accounts.json and the directories of the
// teams in `photoTeams` or `emojiTeams`. A team only `emojiTeams` holds, one
// no token serves, loses its photos and keeps its emoji, so no photo
// outlives the token and a token stored again fetches the team afresh.
function sweepRoot(root, photoTeams, emojiTeams) {
    if (!fs.existsSync(root)) return;
    for (const name of fs.readdirSync(root)) {
        if (name === ACCOUNTS_FILE || photoTeams.has(name)) continue;
        if (emojiTeams.has(name)) sweepTeam(path.join(root, name), new Set(), null);
        else remove(path.join(root, name));
    }
}

function isNumber(value) {
    return typeof value === "number" && isFinite(value);
}

// A team's cached record, or null for none or one the helper did not
// write: { id, names, icon, users, account, generatedAt, downloadFailed }.
function readTeam(root, id) {
    const dir = path.join(root, id);
    const team = readJson(path.join(dir, "team.json"));
    const users = readJson(path.join(dir, "users.json"));
    if (!team || team.id !== id || typeof team.account !== "string" || !Array.isArray(team.names) || typeof team.icon !== "string") return null;
    if (!isNumber(team.generatedAt) || !isNumber(team.downloadFailed) || !users || !Array.isArray(users.users)) return null;
    return { id, names: team.names, icon: team.icon, users: users.users, account: team.account, generatedAt: team.generatedAt, downloadFailed: team.downloadFailed };
}

// A record still current for `account`: written from that account's token
// within the day, or within the retry gap when a download failed.
function fresh(record, account) {
    if (record === null || record.account !== account) return false;
    return Date.now() - record.generatedAt <= (record.downloadFailed > 0 ? RETRY_MS : DAILY_MS);
}

function held(state) {
    return !!state && isNumber(state.failedAt) && Date.now() - state.failedAt < RETRY_MS;
}

function redact(text) {
    return String(text || "failed").replace(/xox[pboa]-[A-Za-z0-9-]+/g, "xoxp-redacted");
}

// team.info and users.list with one token: { info, members }. Throws with
// the failure named.
function teamInfo(base, token) {
    return apiCall(base, token, "team.info", {}).team;
}

function teamMembers(base, token) {
    let members = [];
    let cursor = "";
    while (members.length < MAX_USERS) {
        const page = apiCall(base, token, "users.list", { limit: "200", cursor });
        if (Array.isArray(page.members)) members = members.concat(page.members);
        cursor = page.response_metadata && typeof page.response_metadata.next_cursor === "string" ? page.response_metadata.next_cursor : "";
        if (cursor === "") break;
    }
    return members;
}

// Download and write team `id`'s directory from `info`, team.info's team,
// and `members`, users.list's, served by `account`. Answers the record.
function buildTeam(root, id, account, info, members) {
    const teamDir = path.join(root, id);
    const usersDir = path.join(teamDir, USERS_DIR);
    mkdir(usersDir);
    const budget = { remaining: MAX_CACHE_BYTES, keep: new Set(["team.json", "users.json"]) };
    const userBudget = { remaining: 0, keep: new Set() };
    const stats = { downloadFailed: 0 };
    let icon = "";
    const iconUrl = info && info.icon && typeof info.icon === "object"
        ? (info.icon.image_88 || info.icon.image_68 || "")
        : "";
    const iconFile = path.join(teamDir, "workspace.png");
    if (typeof iconUrl === "string" && iconUrl !== "") {
        const downloaded = downloadImage(iconUrl, iconFile);
        if (downloaded === "failed") {
            stats.downloadFailed += 1;
            icon = keepExistingImage(iconFile, budget, "workspace.png");
        }
        if (downloaded === "saved") {
            const size = fs.statSync(iconFile).size;
            if (size <= budget.remaining) {
                budget.remaining -= size;
                budget.keep.add("workspace.png");
                icon = versionedFileUrl(iconFile);
            } else {
                fs.rmSync(iconFile, { force: true });
            }
        }
    }
    // The users' photos share the team's budget; their names are kept apart,
    // since they live in users/.
    userBudget.remaining = budget.remaining;
    const users = [];
    for (const member of members.slice(0, MAX_USERS)) {
        if (member && member.deleted === true) continue;
        const user = userRecord(member, usersDir, userBudget, stats);
        if (user !== null) users.push(user);
    }
    users.sort((a, b) => a.id.localeCompare(b.id));
    const record = {
        id,
        names: uniqueNames([info.domain, info.name]),
        icon,
        users,
        account,
        generatedAt: Date.now(),
        downloadFailed: stats.downloadFailed
    };
    writeJson(path.join(teamDir, "team.json"), { id, names: record.names, icon, account, generatedAt: record.generatedAt, downloadFailed: record.downloadFailed });
    writeJson(path.join(teamDir, "users.json"), { users });
    sweepTeam(teamDir, budget.keep, userBudget.keep);
    return record;
}

// The photos of the teams `tokens` serve: { value, kept, accounts }, the
// output's photo fields, the team ids whose directories hold photos, and
// the account states to store.
function refreshPhotos(root, tokens, lines) {
    const accountsFile = path.join(root, ACCOUNTS_FILE);
    const stored = readJson(accountsFile);
    const previous = stored !== null && typeof stored === "object" && !Array.isArray(stored) ? stored : {};
    const accounts = {};
    for (const entry of tokens) accounts[entry.account] = previous[entry.account] || {};
    const teams = [];
    let stale = false;
    const refuse = (account, reason) => {
        accounts[account] = Object.assign({}, accounts[account], { failedAt: Date.now(), reason: redact(reason) });
        lines.push("notifications-slack-photos: account=" + account + " " + redact(reason));
        stale = true;
    };
    const keepStale = record => {
        stale = true;
        if (record !== null) teams.push(record);
    };
    // A refresh the API answered clears the account's failure; the record's
    // own downloadFailed sets when it is refreshed again.
    const settle = (account, record) => {
        teams.push(record);
        delete accounts[account].failedAt;
        delete accounts[account].reason;
    };
    let base = "";
    const api = () => base !== "" ? base : (base = apiBase());
    // Each workspace's own token first: the team it serves is the one its
    // account names, and a token for another team is refused.
    const served = new Set();
    for (const entry of tokens.filter(e => e.account !== LEGACY)) {
        const id = entry.account.slice("slack:".length);
        const record = readTeam(root, id);
        if (fresh(record, entry.account)) {
            served.add(id);
            teams.push(record);
            continue;
        }
        if (held(accounts[entry.account])) {
            // A token for another team caches nothing for this one, and
            // leaves it to the single-workspace token.
            if (accounts[entry.account].reason === "team=mismatch") {
                stale = true;
                continue;
            }
            served.add(id);
            keepStale(record);
            continue;
        }
        let info;
        let members;
        try {
            info = teamInfo(api(), entry.token);
            if (safeSegment(info && info.id) !== id) {
                refuse(entry.account, "team=mismatch");
                continue;
            }
            served.add(id);
            members = teamMembers(api(), entry.token);
        } catch (e) {
            served.add(id);
            refuse(entry.account, e.message);
            keepStale(record);
            continue;
        }
        settle(entry.account, buildTeam(root, id, entry.account, info, members));
    }
    // The single-workspace token serves the team team.info names, unless
    // that team's own token serves it.
    const legacy = tokens.find(e => e.account === LEGACY);
    if (legacy !== undefined) {
        const state = accounts[LEGACY];
        // The team team.info last named, which a day later is asked again,
        // since the token may since serve another team.
        const last = safeSegment(state.team);
        const known = last !== "" && isNumber(state.resolvedAt) && Date.now() - state.resolvedAt <= DAILY_MS ? last : "";
        const record = last === "" ? null : readTeam(root, last);
        const own = record !== null && record.account === LEGACY ? record : null;
        if (known !== "" && served.has(known)) {
            // Its own token serves it.
        } else if (fresh(own, LEGACY)) {
            teams.push(own);
        } else if (held(state)) {
            keepStale(own);
        } else {
            try {
                const info = teamInfo(api(), legacy.token);
                const id = safeSegment(info && info.id);
                if (id === "") throw new Error("api=team.info team-id=invalid");
                accounts[LEGACY] = Object.assign({}, accounts[LEGACY], { team: id, resolvedAt: Date.now() });
                if (!served.has(id)) settle(LEGACY, buildTeam(root, id, LEGACY, info, teamMembers(api(), legacy.token)));
            } catch (e) {
                refuse(LEGACY, e.message);
                keepStale(own);
            }
        }
    }
    const downloadFailed = teams.reduce((sum, team) => sum + team.downloadFailed, 0);
    if (downloadFailed > 0) lines.push("notifications-slack-photos: downloads=failed count=" + downloadFailed);
    return {
        value: {
            status: "loaded",
            generatedAt: teams.length === 0 ? 0 : Math.min(...teams.map(team => team.generatedAt)),
            downloadFailed,
            stale,
            teams: teams.map(team => ({ id: team.id, names: team.names, icon: team.icon, users: team.users, account: team.account }))
        },
        kept: new Set(teams.map(team => team.id)),
        accounts
    };
}

// The token that serves team `id`: its own, unless that token was refused
// as another team's, else the single-workspace token when team.info last
// named `id`; "" for none.
function tokenFor(tokens, accounts, id) {
    const own = tokens.find(e => e.account === "slack:" + id);
    if (own !== undefined && (accounts[own.account] || {}).reason !== "team=mismatch") return own.token;
    const legacy = tokens.find(e => e.account === LEGACY);
    return legacy !== undefined && (accounts[LEGACY] || {}).team === id ? legacy.token : "";
}

// One run: the photos, then the custom emoji when `emojiCache`, Slack's
// Cache_Data, is given, or their removal when it is null; then the root
// sweep and the one output line, with an `emoji` list when emoji are on.
function refresh(root, ids, emojiCache) {
    assertTestSecretToolPath();
    const lines = [];
    const tokens = [];
    for (const account of ids.map(id => "slack:" + id).concat([LEGACY])) {
        const found = lookupToken(account);
        if (found.state === "no-tool") break;
        if (found.state === "failed") lines.push(found.line);
        if (found.state === "token") tokens.push({ account, token: found.token });
    }
    const photos = tokens.length === 0 ? { value: { status: "absent" }, kept: new Set(), accounts: null } : refreshPhotos(root, tokens, lines);
    let base = "";
    const deps = {
        readJson,
        atomicWrite,
        download: fetchImage,
        listEmoji: token => apiCall(base !== "" ? base : (base = apiBase()), token, "emoji.list", {}).emoji,
        allowedUrl: allowedImageUrl,
        redact,
        tokenFor: id => tokenFor(tokens, photos.accounts || {}, id),
        now: Date.now,
        path: process.env.PATH
    };
    const emojiRun = emojiCache === null ? { kept: emoji.disable(root, deps), teams: null } : emoji.refresh(root, emojiCache, ids, deps, lines);
    sweepRoot(root, photos.kept, emojiRun.kept);
    const accountsFile = path.join(root, ACCOUNTS_FILE);
    if (photos.accounts === null) {
        remove(accountsFile);
    } else {
        mkdir(root);
        writeJson(accountsFile, photos.accounts);
    }
    for (const line of lines) console.error(line);
    output(emojiRun.teams === null ? photos.value : Object.assign({}, photos.value, { emoji: emojiRun.teams }));
}

// refresh <root> [--emoji <Slack Cache_Data>] [<team id>...]
function main(argv) {
    if (argv.length < 4 || argv[2] !== "refresh") usage("usage");
    let rest = argv.slice(4);
    let emojiCache = null;
    if (rest[0] === "--emoji") {
        if (rest.length < 2 || !path.isAbsolute(rest[1])) usage("emoji want=<absolute cache dir>");
        emojiCache = rest[1];
        rest = rest.slice(2);
    }
    const ids = rest;
    if (ids.length > TEAMS_MAX) usage("teams count=" + ids.length + " want<=" + TEAMS_MAX);
    for (const id of ids)
        if (safeSegment(id) === "") usage("team-id want=[A-Za-z0-9]{1,32}");
    return { root: argv[3], ids: Array.from(new Set(ids)), emojiCache };
}

const args = main(process.argv);
try {
    refresh(args.root, args.ids, args.emojiCache);
} catch (e) {
    fail(4, "notifications-slack-photos: error=io");
}
