.pragma library

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

function hasOwn(object, key) {
    return object !== null && typeof object === "object" && Object.prototype.hasOwnProperty.call(object, key);
}

function isPlainObject(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value);
}

function clone(value) {
    return value === undefined ? undefined : JSON.parse(JSON.stringify(value));
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
        out.push({ name: row.name, old: row.old === undefined ? null : row.old, new: row.new === undefined ? null : row.new });
    }
    return out;
}

function sourceRow(source, count, packages, checkedAt, error) {
    return {
        source: source,
        label: sourceLabel(source),
        count: count,
        packages: packageRows(packages),
        checkedAt: checkedAt,
        error: error === undefined ? null : error
    };
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
            errors.push(row.id + ": " + row.error);
            continue;
        }
        var behind = Number(row.behind || 0);
        if (behind > 0) {
            count += behind;
            packages.push({ name: row.id, old: row.head === undefined ? null : row.head, new: row.upstream === undefined ? null : row.upstream });
        }
    }
    return sourceRow(source, errors.length > 0 ? null : count, packages, checkedAt, errors.length > 0 ? errors.join("; ") : null);
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

function checkState(snapshot, checking, now, intervalMs) {
    if (checking) return { tone: "info", text: "Checking" };
    if (snapshot === null) return { tone: "info", text: "Not checked" };
    if (snapshot.error !== null && snapshot.error !== "") return { tone: "danger", text: String(snapshot.error).slice(0, 200) };
    var source = firstSourceError(snapshot);
    if (source !== null) return { tone: "warning", text: (source.label || source.source) + ": " + String(source.error).slice(0, 180) };
    if (typeof now === "number" && intervalMs > 0 && now - snapshot.checkedAt > 2 * intervalMs) return { tone: "warning", text: "Check stale" };
    return { tone: "ok", text: pendingCount(snapshot) > 0 ? "Updates waiting" : "Up to date" };
}

function publishValues(snapshot, checking, now, intervalMs) {
    return {
        pending: pendingCount(snapshot),
        lastCheck: snapshot === null ? null : snapshot.checkedAt,
        checkState: checkState(snapshot, checking, now, intervalMs),
        sources: snapshot === null ? [] : clone(snapshot.sources)
    };
}

function intervalMs(settings) {
    var hours = settings !== null && settings !== undefined && typeof settings.intervalHours === "number" ? settings.intervalHours : 6;
    if (hours < 1) hours = 1;
    if (hours > 48) hours = 48;
    return hours * 60 * 60 * 1000;
}

function nextCheckDelay(snapshot, checking, now, interval) {
    if (checking) return interval;
    if (snapshot === null) return 0;
    var due = snapshot.checkedAt + interval;
    return Math.max(0, due - now);
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
