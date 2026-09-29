#!/usr/bin/env node
"use strict";

const childProcess = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const ATTRS = ["service", "vgs-notifications", "account", "slack"];
const DAILY_MS = 24 * 60 * 60 * 1000;
const RETRY_MS = 15 * 60 * 1000;
const MAX_USERS = 512;
const MAX_IMAGE_BYTES = 512 * 1024;
const MAX_CACHE_BYTES = 10 * 1024 * 1024;
const API_DEFAULT = "https://slack.com/api";

function usage() {
    console.error("notifications-slack-photos: refused: usage");
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

function lookupToken() {
    const secret = childProcess.spawnSync("secret-tool", ["lookup"].concat(ATTRS), {
        encoding: "utf8",
        maxBuffer: 1024 * 1024
    });
    if (secret.error && secret.error.code === "ENOENT") {
        fail(5, "notifications-slack-photos: secret-tool=missing");
    }
    if (secret.error) {
        fail(5, "notifications-slack-photos: secret-tool=failed");
    }
    if (secret.status !== 0) return "";
    return String(secret.stdout || "").replace(/\r?\n$/, "");
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

function downloadImage(url, file) {
    if (!allowedImageUrl(url)) return false;
    const dir = path.dirname(file);
    mkdir(dir);
    if (!inside(dir, file)) return false;
    const tmp = path.join(dir, "." + path.basename(file) + "." + process.pid + ".download");
    const curl = childProcess.spawnSync("curl", [
        "--silent", "--show-error", "--fail", "--location",
        "--max-time", "10", "--connect-timeout", "5",
        "--max-filesize", String(MAX_IMAGE_BYTES),
        "--output", tmp,
        url
    ], { encoding: "utf8", maxBuffer: 1024 * 1024 });
    if (curl.error || curl.status !== 0) {
        fs.rmSync(tmp, { force: true });
        return false;
    }
    const size = fs.statSync(tmp).size;
    if (size <= 0 || size > MAX_IMAGE_BYTES) {
        fs.rmSync(tmp, { force: true });
        return false;
    }
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
            return true;
        }
        fs.rmSync(resized, { force: true });
    }
    fs.renameSync(tmp, file);
    return true;
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

function userRecord(user, teamDir, budget) {
    const id = safeSegment(user && user.id);
    if (id === "") return null;
    const profile = user && user.profile && typeof user.profile === "object" ? user.profile : {};
    const names = uniqueNames([profile.display_name, profile.real_name, user.real_name, user.name]);
    if (names.length === 0) return null;
    let photo = "";
    const wanted = path.join(teamDir, id + ".png");
    if (budget.remaining > 0 && typeof profile.image_48 === "string" && downloadImage(profile.image_48, wanted)) {
        const size = fs.statSync(wanted).size;
        if (size <= budget.remaining) {
            budget.remaining -= size;
            photo = "file://" + wanted;
            budget.keep.add(path.basename(wanted));
        } else {
            fs.rmSync(wanted, { force: true });
        }
    }
    return { id, names, photo };
}

function sweep(dir, keep) {
    if (!fs.existsSync(dir)) return;
    for (const name of fs.readdirSync(dir)) {
        if (keep.has(name)) continue;
        fs.rmSync(path.join(dir, name), { force: true, recursive: true });
    }
}

function loadFresh(indexFile) {
    try {
        const stat = fs.statSync(indexFile);
        if (Date.now() - stat.mtimeMs > DAILY_MS) return null;
        const cached = readJson(indexFile);
        if (cached && cached.status === "loaded" && Array.isArray(cached.teams)) return cached;
    } catch (_e) {
        return null;
    }
    return null;
}

function failureHeld(failureFile) {
    const failure = readJson(failureFile);
    return failure && typeof failure.at === "number" && Date.now() - failure.at < RETRY_MS;
}

function refresh(root) {
    mkdir(root);
    const indexFile = path.join(root, "index.json");
    const failureFile = path.join(root, "failure.json");
    const token = lookupToken();
    if (token === "") {
        output({ status: "absent" });
        return;
    }
    if (/[\r\n"]/.test(token)) {
        fail(5, "notifications-slack-photos: token=invalid");
    }
    const fresh = loadFresh(indexFile);
    if (fresh !== null) {
        output(fresh);
        return;
    }
    if (failureHeld(failureFile)) {
        output({ status: "absent" });
        return;
    }
    let teamInfo;
    let members = [];
    try {
        const base = apiBase();
        teamInfo = apiCall(base, token, "team.info", {}).team;
        let cursor = "";
        while (members.length < MAX_USERS) {
            const page = apiCall(base, token, "users.list", { limit: "200", cursor });
            if (Array.isArray(page.members)) members = members.concat(page.members);
            cursor = page.response_metadata && typeof page.response_metadata.next_cursor === "string" ? page.response_metadata.next_cursor : "";
            if (cursor === "") break;
        }
    } catch (e) {
        const reason = String(e.message || "failed").replace(/xox[pboa]-[A-Za-z0-9-]+/g, "xoxp-redacted");
        writeJson(failureFile, { at: Date.now(), reason });
        fail(6, "notifications-slack-photos: " + reason);
    }
    const teamId = safeSegment(teamInfo && teamInfo.id);
    if (teamId === "") fail(6, "notifications-slack-photos: api=team.info team-id=invalid");
    const teamDir = path.join(root, teamId);
    mkdir(teamDir);
    const budget = { remaining: MAX_CACHE_BYTES, keep: new Set(["team.json", "users.json"]) };
    const teamNames = uniqueNames([teamInfo.domain, teamInfo.name]);
    let icon = "";
    const iconUrl = teamInfo && teamInfo.icon && typeof teamInfo.icon === "object"
        ? (teamInfo.icon.image_88 || teamInfo.icon.image_68 || "")
        : "";
    const iconFile = path.join(teamDir, "workspace.png");
    if (typeof iconUrl === "string" && downloadImage(iconUrl, iconFile)) {
        const size = fs.statSync(iconFile).size;
        if (size <= budget.remaining) {
            budget.remaining -= size;
            budget.keep.add("workspace.png");
            icon = "file://" + iconFile;
        } else {
            fs.rmSync(iconFile, { force: true });
        }
    }
    const users = [];
    for (const member of members.slice(0, MAX_USERS)) {
        if (member && member.deleted === true) continue;
        const user = userRecord(member, teamDir, budget);
        if (user !== null) users.push(user);
    }
    users.sort((a, b) => a.id.localeCompare(b.id));
    const team = { id: teamId, names: teamNames, icon, users };
    writeJson(path.join(teamDir, "team.json"), { id: team.id, names: team.names, icon: team.icon });
    writeJson(path.join(teamDir, "users.json"), { users: team.users });
    sweep(teamDir, budget.keep);
    const index = { status: "loaded", generatedAt: Date.now(), teams: [team] };
    writeJson(indexFile, index);
    fs.rmSync(failureFile, { force: true });
    output(index);
}

if (process.argv.length !== 4 || process.argv[2] !== "refresh") usage();
try {
    refresh(process.argv[3]);
} catch (e) {
    fail(4, "notifications-slack-photos: error=io");
}
