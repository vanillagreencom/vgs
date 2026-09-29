.pragma library

// Pure decisions for vgs.updates: probe normalization, snapshot judging,
// status derivation, publish diffs, check cadence, failure retry and TUI run
// end detection for the service, and what the bar widget and the flyout draw
// from the published status. QML owns I/O and timers; bin/check owns
// processes and disk.

// Every source a status row can name, with the label the service publishes
// and the Lucide icon the flyout draws it with. `packages` is the one row a
// failed `vgsh pkg check` leaves. A source outside the table is labelled by
// its own name and drawn with the `package` icon.
var SOURCES = {
    pacman: { label: "System", icon: "package" },
    apt: { label: "System", icon: "package" },
    dnf: { label: "System", icon: "package" },
    xbps: { label: "System", icon: "package" },
    emerge: { label: "System", icon: "package" },
    nix: { label: "System", icon: "package" },
    aur: { label: "AUR", icon: "package-open" },
    flatpak: { label: "Flatpak", icon: "boxes" },
    mise: { label: "mise", icon: "wrench" },
    vgs: { label: "VGS", icon: "monitor" },
    plugins: { label: "Plugins", icon: "puzzle" },
    themes: { label: "Themes", icon: "palette" },
    packages: { label: "Packages", icon: "package" }
};
var UNLISTED_SOURCE_ICON = "package";
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
    return hasOwn(SOURCES, source) ? SOURCES[source].label : source;
}

function sourceIcon(source) {
    return hasOwn(SOURCES, source) ? SOURCES[source].icon : UNLISTED_SOURCE_ICON;
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

// `checking` is whether a check process runs: the widget's spinner reads
// it, since the `info` tone of `checkState` also means "not checked".
function publishValues(snapshot, checking, now, intervalMs, checkFailure) {
    return { pending: pendingCount(snapshot), lastCheck: snapshot === null ? null : snapshot.checkedAt, checkState: checkState(snapshot, checking, now, intervalMs, checkFailure), checking: checking === true, sources: snapshot === null ? [] : publishedSources(snapshot.sources) };
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
    var keys = ["pending", "lastCheck", "checkState", "checking", "sources"];
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

// The cadence timer's delay, or null for no timer while the cache read
// has not answered: a null snapshot then means "not read yet", not "never
// checked".
function nextTimerDelay(snapshot, checking, now, interval, failedAt, cacheRead) {
    if (cacheRead !== true) return null;
    var checkDelay = nextCheckDelay(snapshot, checking, now, interval, failedAt);
    var stale = staleDelay(snapshot, now, interval);
    if (stale === null) return checkDelay;
    return Math.min(checkDelay, stale);
}

function shouldRunCheck(snapshot, checking, now, interval, failedAt) {
    return !checking && nextCheckDelay(snapshot, false, now, interval, failedAt) === 0;
}

// Whether a run of one of the plugin's TUIs ended between PREVIOUS and
// CURRENT, two reads of `shell.tui.state`. PREVIOUS null is no read yet:
// the first read carries the runs that ended before it, which it does not
// count.
function tuiRunEnded(previous, current) {
    if (previous === null) return false;
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

// ---- What the bar widget and the flyout draw --------------------------------
// Both read the published status values alone; nothing here runs a check.

// The widget's look in each state of the published status: the icon, its
// tone (`calm` the bar's own colour, `accent` or `warning`), whether a
// spinner stands in for the icon, and the tone of the count badge.
//   current    the last check succeeded and nothing waits
//   pending    the last check succeeded and updates wait
//   attention  the check failed, a source failed, or the snapshot is older
//              than twice the interval: checkState `warning` or `danger`
//   checking   a check process runs
//   unchecked  no check has published a state yet
// Only `current` may hide, and only under the `hideWhenCurrent` setting, so
// a failed, stale or missing check always shows.
var WIDGET_STATES = {
    current: { icon: "refresh-cw", tone: "calm", spinning: false, badgeTone: "neutral" },
    pending: { icon: "refresh-cw", tone: "accent", spinning: false, badgeTone: "accent" },
    attention: { icon: "triangle-alert", tone: "warning", spinning: false, badgeTone: "warning" },
    checking: { icon: "refresh-cw", tone: "calm", spinning: true, badgeTone: "accent" },
    unchecked: { icon: "circle-dashed", tone: "calm", spinning: false, badgeTone: "neutral" }
};

// A count badge shows at most this number, then `99+`.
var BADGE_COUNT_MAX = 99;

function valuesOf(values) {
    return isPlainObject(values) ? values : {};
}

function pendingOf(values) {
    var pending = valuesOf(values).pending;
    return typeof pending === "number" && isFinite(pending) && pending > 0 ? pending : 0;
}

function sourcesOf(values) {
    var sources = valuesOf(values).sources;
    return Array.isArray(sources) ? sources : [];
}

function badgeText(count) {
    return count > BADGE_COUNT_MAX ? BADGE_COUNT_MAX + "+" : String(count);
}

function countText(count, noun) {
    return count + " " + noun + (count === 1 ? "" : "s");
}

// One key of WIDGET_STATES for the published values. The core admits only
// the four tones of a `state` value, so another tone is a broken contract.
function widgetState(values) {
    var v = valuesOf(values);
    if (v.checking === true) return "checking";
    if (!isPlainObject(v.checkState)) return "unchecked";
    switch (v.checkState.tone) {
    case "ok": return pendingOf(v) > 0 ? "pending" : "current";
    case "warning":
    case "danger": return "attention";
    case "info": return "unchecked";
    default: throw new Error("updates: checkState tone " + JSON.stringify(v.checkState.tone) + " is not one of ok, info, warning, danger");
    }
}

// What the widget draws: { state, icon, tone, spinning, badge, badgeTone,
// hidden }. `badge` is the pending count, "" when nothing waits.
function widgetView(values, hideWhenCurrent) {
    var state = widgetState(values);
    var look = WIDGET_STATES[state];
    var pending = pendingOf(values);
    return { state: state, icon: look.icon, tone: look.tone, spinning: look.spinning, badge: pending > 0 ? badgeText(pending) : "", badgeTone: look.badgeTone, hidden: hideWhenCurrent === true && state === "current" };
}

// The one line that says where updates stand, as the tooltip and the
// flyout's heading show it.
function summaryText(values) {
    var state = widgetState(values);
    switch (state) {
    case "current": return "Up to date";
    case "pending": return countText(pendingOf(values), "update") + " waiting";
    case "attention": return String(valuesOf(values).checkState.text);
    case "checking": return "Checking for updates";
    case "unchecked": return "Not checked yet";
    default: throw new Error("updates: widget state " + JSON.stringify(state) + " has no summary");
    }
}

function sameLocalDay(a, b) {
    var x = new Date(a);
    var y = new Date(b);
    return x.getFullYear() === y.getFullYear() && x.getMonth() === y.getMonth() && x.getDate() === y.getDate();
}

// `Checked <time>` for `lastCheck`, with the date when the check was not on
// NOW's local day, or `Never checked`. `formatWhen(ms, withDate)` is the
// caller's locale formatting.
function checkedText(lastCheck, now, formatWhen) {
    if (typeof lastCheck !== "number") return "Never checked";
    return "Checked " + formatWhen(lastCheck, !sameLocalDay(lastCheck, now));
}

// The widget's tooltip: the summary, one `<label>: <count>` line per source
// in the service's order, `check failed` for a source with no count, and
// the checked line.
function widgetTooltip(values, now, formatWhen) {
    var lines = [summaryText(values)];
    var sources = sourcesOf(values);
    for (var i = 0; i < sources.length; i++)
        lines.push(sources[i].label + ": " + (sources[i].count === null ? "check failed" : sources[i].count));
    lines.push(checkedText(valuesOf(values).lastCheck, now, formatWhen));
    return lines.join("\n");
}

// One package of a source as the flyout lists it: `name old → new`, or
// `name: N commits behind` for a plugin or theme checkout, whose old and
// new are commit ids.
function packageLine(pkg) {
    if (typeof pkg.behind === "number") return pkg.name + ": " + countText(pkg.behind, "commit") + " behind";
    if (pkg.old !== null && pkg.new !== null) return pkg.name + " " + pkg.old + " → " + pkg.new;
    if (pkg.new !== null) return pkg.name + " → " + pkg.new;
    return pkg.name;
}

// The flyout's rows, one per published source in the service's order:
// { key, source, label, icon, secondary, badge, badgeTone, updatable,
// lines, more }. `lines` are the packages the shared status lists, `more`
// the `+N more` it omitted, "" for none. A source with an error keeps its
// row and names the error; only a source with a count above zero offers
// its own Update.
function panelRows(values) {
    var sources = sourcesOf(values);
    var rows = [];
    for (var i = 0; i < sources.length; i++) {
        var row = sources[i];
        var failed = row.count === null;
        var error = row.error === null || row.error === undefined ? "" : String(row.error);
        var packages = Array.isArray(row.packages) ? row.packages : [];
        rows.push({
            key: row.source,
            source: row.source,
            label: row.label,
            icon: sourceIcon(row.source),
            secondary: error !== "" ? error : failed ? "No count" : row.count === 0 ? "Up to date" : countText(row.count, "update"),
            badge: failed ? "Failed" : badgeText(row.count),
            badgeTone: error !== "" ? "warning" : !failed && row.count > 0 ? "accent" : "neutral",
            updatable: !failed && row.count > 0,
            lines: packages.map(packageLine),
            more: typeof row.more === "number" && row.more > 0 ? "+" + row.more + " more" : ""
        });
    }
    return rows;
}

// The argv `shell.tui.run` takes for a flyout action: `update` for every
// source, `update-source` with the row's source for one, `log` for the
// last run's log.
function tuiRequest(action, source) {
    switch (action) {
    case "all": return { name: "update", args: [] };
    case "source":
        if (typeof source !== "string" || source === "") throw new Error("updates: action source needs a source");
        return { name: "update-source", args: [source] };
    case "log": return { name: "log", args: [] };
    default: throw new Error("updates: action " + JSON.stringify(action) + " is not one of all, source, log");
    }
}

// The line a refused request leaves in the flyout, "" for `ok` and for the
// answers `check` gives, `started` and `queued`.
function replyLine(reply) {
    return reply === "ok" || reply === "started" || reply === "queued" ? "" : String(reply);
}
