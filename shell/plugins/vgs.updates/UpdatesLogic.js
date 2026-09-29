.pragma library

// Pure decisions for vgs.updates: probe normalization, snapshot judging,
// status derivation, publish diffs, check cadence, failure retry and TUI run
// end detection. QML owns I/O and timers; bin/check owns processes and disk.
var SOURCE_LABELS = {
    pacman: "System",
    apt: "System",
    dnf: "System",
    xbps: "System",
    emerge: "System",
    nix: "System",
    aur: "AUR",
    flatpak: "Flatpak",
    mise: "mise",
    vgs: "VGS",
    plugins: "Plugins",
    themes: "Themes",
    packages: "Packages"
};
var RETRY_AFTER_FAILURE_MS = 5 * 60 * 1000;
var STATUS_MAX_BYTES = 65536;
var PUBLISHED_PACKAGES_PER_SOURCE_MAX = 12;
var PUBLISHED_PACKAGE_TEXT_MAX = 80;

function hasOwn(object, key) {
    return object !== null && typeof object === "object" && Object.prototype.hasOwnProperty.call(object, key);
}

function isPlainObject(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value);
}

function clone(value) {
    return value === undefined ? undefined : JSON.parse(JSON.stringify(value));
}

function sameJson(a, b) {
    return JSON.stringify(a) === JSON.stringify(b);
}

function toMs(value) {
    if (typeof value === "number" && isFinite(value) && Math.floor(value) === value && value >= 0) return value;
    if (typeof value === "string" && value !== "") {
        var parsed = Date.parse(value);
        if (isFinite(parsed)) return parsed;
    }
    return null;
}

function sourceLabel(source) {
    return hasOwn(SOURCE_LABELS, source) ? SOURCE_LABELS[source] : source;
}

function packageRows(rows) {
    if (!Array.isArray(rows)) return [];
    var out = [];
    for (var i = 0; i < rows.length; i++) {
        var row = rows[i];
        if (!isPlainObject(row) || typeof row.name !== "string") continue;
        var made = { name: row.name, old: row.old === undefined ? null : row.old, new: row.new === undefined ? null : row.new };
        if (typeof row.behind === "number" && isFinite(row.behind) && row.behind > 0) made.behind = row.behind;
        out.push(made);
    }

    return out;
}

function truncatedText(value) {
    if (value === null || value === undefined) return null;
    var text = String(value);
    return text.length > PUBLISHED_PACKAGE_TEXT_MAX ? text.slice(0, PUBLISHED_PACKAGE_TEXT_MAX) : text;
}

function publishedPackage(row) {
    var made = { name: truncatedText(row.name), old: truncatedText(row.old), new: truncatedText(row.new) };
    if (typeof row.behind === "number" && isFinite(row.behind) && row.behind > 0) made.behind = row.behind;
    return made;
}

function sourceRow(source, count, packages, checkedAt, error) {
    return { source: source, label: sourceLabel(source), count: count, packages: packageRows(packages), checkedAt: checkedAt, error: error === undefined ? null : error };
}

function commandError(name, probe) {
    var reason = probe.status === null ? "spawn=failed" : "exit=" + probe.status;
    var stderr = String(probe.stderr || "").split("\n").filter(function (line) { return line !== ""; })[0] || "";
    return reason + (stderr !== "" ? " " + stderr.replace(/^vgsh: refused: /, "") : "");
}

function parseProbeJson(name, probe) {
    if (!probe || probe.status !== 0) return { ok: false, error: commandError(name, probe || { status: null, stderr: "" }) };
    try {
        return { ok: true, value: JSON.parse(String(probe.stdout || "")) };
    } catch (e) {
        return { ok: false, error: "unparseable " + name };
    }
}

// `vgsh pkg check --json` rows, primary first. With no manager detected it
// prints `[]`, so the snapshot holds only the VGS rows; a probe that failed
// as a whole is one `packages` row carrying the failure.
function normalizePkg(probe) {
    var parsed = parseProbeJson("pkg", probe);
    if (!parsed.ok) return [sourceRow("packages", null, [], null, parsed.error)];
    if (!Array.isArray(parsed.value)) return [sourceRow("packages", null, [], null, "unparseable pkg")];
    var out = [];
    for (var i = 0; i < parsed.value.length; i++) {
        var row = parsed.value[i];
        if (!isPlainObject(row) || typeof row.source !== "string") continue;
        out.push(sourceRow(row.source, row.count === null ? null : Number(row.count), row.packages, toMs(row.checkedAt), row.error === undefined ? null : row.error));
    }
    return out;
}

function normalizeSelf(probe, checkedAt) {
    var parsed = parseProbeJson("self", probe);
    if (!parsed.ok) return sourceRow("vgs", null, [], checkedAt, parsed.error);
    var row = parsed.value;
    if (!isPlainObject(row)) return sourceRow("vgs", null, [], checkedAt, "unparseable self");
    var error = row.error === undefined ? null : row.error;
    var behind = row.behind === true;
    var packages = behind ? [{ name: row.package || "vgs", old: row.current === undefined ? null : row.current, new: row.latest === undefined ? null : row.latest }] : [];
    return sourceRow("vgs", error ? null : (behind ? 1 : 0), packages, checkedAt, error);
}

// An installed directory that is not its own git checkout (a copied or
// hand-made plugin) has no upstream, and `vgsh plugin update` refuses it
// the same way: it is not an update source, so its row is left out rather
// than failing the whole source.
var UNTRACKED_REFUSAL = /^not-a-checkout=/;

// Plugins or themes from `vgsh plugin|theme outdated --json`: one update per
// checkout that is behind, its commit count kept as `behind`. A checkout
// whose own probe failed names itself in the source's error; the others
// still count, so one unreachable remote does not hide the rest.
function normalizeOutdated(source, probe, checkedAt) {
    var parsed = parseProbeJson(source, probe);
    if (!parsed.ok) return sourceRow(source, null, [], checkedAt, parsed.error);
    if (!Array.isArray(parsed.value)) return sourceRow(source, null, [], checkedAt, "unparseable " + source);
    var count = 0;
    var packages = [];
    var errors = [];
    for (var i = 0; i < parsed.value.length; i++) {
        var row = parsed.value[i];
        if (!isPlainObject(row) || typeof row.id !== "string") continue;
        if (row.error) {
            if (!UNTRACKED_REFUSAL.test(String(row.error))) errors.push(row.id + ": " + row.error);
            continue;
        }
        var behind = Number(row.behind || 0);
        if (behind > 0) {
            count += 1;
            packages.push({ name: row.id, old: row.head === undefined ? null : row.head, new: row.upstream === undefined ? null : row.upstream, behind: behind });
        }
    }
    return sourceRow(source, count, packages, checkedAt, errors.length > 0 ? errors.join("; ") : null);
}

function normalizeSnapshot(probes, now) {
    var checkedAt = typeof now === "number" ? now : Date.now();
    var sources = [];
    sources = sources.concat(normalizePkg(probes.pkg));
    sources.push(normalizeSelf(probes.self, checkedAt));
    sources.push(normalizeOutdated("plugins", probes.plugins, checkedAt));
    sources.push(normalizeOutdated("themes", probes.themes, checkedAt));
    return { checkedAt: checkedAt, sources: sources, error: null };
}

function parseSnapshotText(text) {
    var parsed;
    try {
        parsed = JSON.parse(String(text || ""));
    } catch (e) {
        return { ok: false, error: "not-json" };
    }
    return snapshotFromObject(parsed);
}

function snapshotFromObject(value) {
    if (!isPlainObject(value)) return { ok: false, error: "not-object" };
    var checkedAt = toMs(value.checkedAt);
    if (checkedAt === null) return { ok: false, error: "checkedAt" };
    if (!Array.isArray(value.sources)) return { ok: false, error: "sources" };
    var sources = [];
    for (var i = 0; i < value.sources.length; i++) {
        var row = value.sources[i];
        if (!isPlainObject(row) || typeof row.source !== "string") return { ok: false, error: "sources." + i };
        var count = row.count === null ? null : Number(row.count);
        if (count !== null && (!isFinite(count) || Math.floor(count) !== count || count < 0)) return { ok: false, error: "sources." + i + ".count" };
        sources.push(sourceRow(row.source, count, row.packages, toMs(row.checkedAt), row.error === undefined ? null : row.error));
    }
    return { ok: true, snapshot: { checkedAt: checkedAt, sources: sources, error: value.error === undefined ? null : value.error } };
}

function pendingCount(snapshot) {
    if (snapshot === null) return 0;
    var total = 0;
    for (var i = 0; i < snapshot.sources.length; i++)
        if (typeof snapshot.sources[i].count === "number") total += snapshot.sources[i].count;
    return total;
}

function firstSourceError(snapshot) {
    if (snapshot === null) return null;
    for (var i = 0; i < snapshot.sources.length; i++) {
        var row = snapshot.sources[i];
        if (row.error !== null && row.error !== "") return row;
    }
    return null;
}

function checkState(snapshot, checking, now, intervalMs, checkFailure) {
    if (checking) return { tone: "info", text: "Checking" };
    if (checkFailure !== null && checkFailure !== undefined && checkFailure !== "") return { tone: "danger", text: String(checkFailure).slice(0, 200) };
    if (snapshot === null) return { tone: "info", text: "Not checked" };
    if (snapshot.error !== null && snapshot.error !== "") return { tone: "danger", text: String(snapshot.error).slice(0, 200) };
    var source = firstSourceError(snapshot);
    if (source !== null) return { tone: "warning", text: (source.label || source.source) + ": " + String(source.error).slice(0, 180) };
    if (typeof now === "number" && intervalMs > 0 && now - snapshot.checkedAt >= 2 * intervalMs) return { tone: "warning", text: "Check stale" };
    return { tone: "ok", text: pendingCount(snapshot) > 0 ? "Updates waiting" : "Up to date" };
}

function publishValues(snapshot, checking, now, intervalMs, checkFailure) {
    return { pending: pendingCount(snapshot), lastCheck: snapshot === null ? null : snapshot.checkedAt, checkState: checkState(snapshot, checking, now, intervalMs, checkFailure), sources: snapshot === null ? [] : publishedSources(snapshot.sources) };
}

function publishedSources(sources) {
    var out = [];
    for (var i = 0; i < sources.length; i++) {
        var row = sources[i];
        var packages = [];
        var limit = Math.min(row.packages.length, PUBLISHED_PACKAGES_PER_SOURCE_MAX);
        for (var p = 0; p < limit; p++) packages.push(publishedPackage(row.packages[p]));
        var made = sourceRow(row.source, row.count, packages, row.checkedAt, row.error);
        made.more = Math.max(0, row.packages.length - packages.length);
        out.push(made);
    }
    return out;
}

function statusRecordBytes(values) {
    return JSON.stringify(values).length;
}

function statusWrites(previous, next) {
    var before = previous || {};
    var out = [];
    var keys = ["pending", "lastCheck", "checkState", "sources"];
    for (var i = 0; i < keys.length; i++) {
        var key = keys[i];
        if (next[key] === null || next[key] === undefined) continue;
        if (!hasOwn(before, key) || !sameJson(before[key], next[key])) out.push({ key: key, value: clone(next[key]) });
    }
    return out;
}

function intervalMs(settings) {
    var hours = settings !== null && settings !== undefined && typeof settings.intervalHours === "number" ? settings.intervalHours : 6;
    if (hours < 1) hours = 1;
    if (hours > 48) hours = 48;
    return hours * 60 * 60 * 1000;
}

function nextCheckDelay(snapshot, checking, now, interval, failedAt) {
    if (checking) return interval;
    if (failedAt !== null && failedAt !== undefined) return Math.max(0, failedAt + RETRY_AFTER_FAILURE_MS - now);
    if (snapshot === null) return 0;
    var due = snapshot.checkedAt + interval;
    return Math.max(0, due - now);
}

function staleDelay(snapshot, now, interval) {
    if (snapshot === null || interval <= 0) return null;
    return Math.max(0, snapshot.checkedAt + 2 * interval - now);
}

function nextTimerDelay(snapshot, checking, now, interval, failedAt) {
    var checkDelay = nextCheckDelay(snapshot, checking, now, interval, failedAt);
    var stale = staleDelay(snapshot, now, interval);
    if (stale === null) return checkDelay;
    return Math.min(checkDelay, stale);
}

function shouldRunCheck(snapshot, checking, now, interval, failedAt) {
    return !checking && nextCheckDelay(snapshot, false, now, interval, failedAt) === 0;
}

function tuiRunEnded(previous, current) {
    var before = previous || {};
    var after = current || {};
    var keys = Object.keys(after);
    for (var i = 0; i < keys.length; i++) {
        var key = keys[i];
        var next = after[key] || {};
        var prior = before[key] || {};
        if (next.endedAt !== null && next.endedAt !== undefined) {
            if (prior.endedAt === null || prior.endedAt === undefined) return true;
            if (Number(next.endedAt) > Number(prior.endedAt)) return true;
        }
        if (prior.running === true && next.running === false && next.endedAt !== null && next.endedAt !== undefined) return true;
    }
    return false;
}
