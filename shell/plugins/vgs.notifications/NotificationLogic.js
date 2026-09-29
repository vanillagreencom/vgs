.pragma library

// The notifications' decisions, with no QML objects and no I/O, so
// scripts/test-notifications-logic.js runs every function under node: what a
// notification body may render, which notifications Silence lets through,
// how long a toast lives, the state file's shape and its judge, the image
// copies an entry owns, what a restart restores, what the history keeps and
// the Inbox shows, which toast a full stack lets go, which actions a card
// offers, the paused and running clocks of the toasts on screen, and the
// per-application rules that read a sender's workspace and people.

// The history keeps the newest HISTORY_MAX notifications; the Inbox and the
// History panel show at most PANEL_ROWS_MAX of them. LIVE_MAX toasts show at
// once: a newer one lets the oldest non-critical toast go into the history.
var HISTORY_MAX = 100;
var PANEL_ROWS_MAX = 40;
var LIVE_MAX = 20;
// Text a sender supplies is stored up to these lengths, so the state file
// holds at most (HISTORY_MAX + LIVE_MAX) entries of bounded size.
var SUMMARY_MAX = 512;
var BODY_MAX = 4096;
// On-screen lifetimes, in milliseconds: the low urgency's floor and one
// ceiling for what a sender asks; a normal toast's floor is the `duration`
// setting, and a critical notification stays until closed.
var LOW_LIFETIME = 5000;
var MAX_LIFETIME = 30000;
// The state file's format.
var STATE_VERSION = 1;
// The entry roles an image can sit in, each owned as a copy by a stored
// entry, named <key>-<role> in the images directory.
var IMAGE_ROLES = ["appIcon", "image"];
// Every role of a toast row, the model's and the state file's, in order.
var ENTRY_ROLES = ["key", "originalId", "app", "appIcon", "summary", "body", "image", "desktopEntry", "urgency", "expireTimeout", "timestamp"];

// The urgency values Quickshell's NotificationUrgency enum takes, which the
// state file stores as numbers.
var URGENCY = { low: 0, normal: 1, critical: 2 };

function hasOwn(object, key) {
    return Object.prototype.hasOwnProperty.call(object, key);
}

function isPlainObject(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value);
}

// ------------------------------------------------------------------ body

function isChromiumDerived(app, appIcon) {
    var source = (String(app || "") + "\n" + String(appIcon || "")).toLowerCase();
    return source.indexOf("chrom") >= 0 || source.indexOf("brave") >= 0 || source.indexOf("vivaldi") >= 0
        || source.indexOf("microsoft-edge") >= 0 || source.indexOf("opera") >= 0;
}

// True when a `<...>` run is an image tag, read the way Qt's parser reads
// it: after the `<`, the leading run of letters and digits. Everything up to
// that run is skipped rather than matched as whitespace, because Qt's
// QChar::isSpace set is not `\s` (Qt counts U+0085, `\s` counts U+FEFF);
// over-skipping only classifies more runs as images, and dropping a run
// never makes a tag. Measured against Qt 6.11.2 in the reference.
function isImageTag(tag) {
    var name = /^<[^A-Za-z0-9]*([A-Za-z0-9]+)/.exec(tag);
    return !!name && name[1].toLowerCase() === "img";
}

// The body renders as StyledText, which honours <img src>: a remote src
// would make the shell fetch it unasked, so image tags go before the
// renderer sees them. Every `<` opens a tag that runs to the next `>`, and
// only a tag named `img` is dropped. That is shorter than Qt's tag, which
// lets a quoted `>` pass; the shorter run can only split one of Qt's tags
// and expose an `<img` to be dropped, never hide one. Text between tags
// holds no `<`, so dropping a tag cannot join its neighbours into a new one,
// and one pass is enough.
function stripImageTags(text) {
    var out = "";
    var i = 0;
    while (i < text.length) {
        var open = text.indexOf("<", i);
        if (open === -1) {
            out += text.slice(i);
            break;
        }
        out += text.slice(i, open);
        // An unterminated tag reaches the renderer, which closes it itself.
        var close = text.indexOf(">", open);
        var tag = close === -1 ? text.slice(open) : text.slice(open, close + 1);
        if (!isImageTag(tag)) out += tag;
        i = close === -1 ? text.length : close + 1;
    }
    return out;
}

// The body without image tags, and for a Chromium-family sender without the
// leading site address those browsers put before every web notification.
function sanitizeBody(body, app, appIcon) {
    var text = stripImageTags(String(body || ""));
    if (!isChromiumDerived(app, appIcon)) return text;
    return text
        .replace(/^\s*<a\b[^>]*>\s*(?:https?:\/\/|www\.)?(?:[a-z0-9-]+\.)+[a-z]{2,}(?::\d+)?(?:\/[^<\s]*)?\s*<\/a>\s*/i, "")
        .replace(/^\s*(?:https?:\/\/|www\.)?(?:[a-z0-9-]+\.)+[a-z]{2,}(?::\d+)?(?:\/\S*)?\s+/i, "");
}

// What the card renders, stripped once more after the newline rewrite: a
// kept tag may hold a `<` of its own, and inserting `<br/>` can split it
// into a live image tag the input never held.
function styledBody(body, app, appIcon) {
    return stripImageTags(sanitizeBody(body, app, appIcon).replace(/\r\n|\r|\n/g, "<br/>"));
}

// A summary that opens with one glyph and two spaces already carries its
// icon, so a card without an image draws no icon slot beside it.
function summaryStartsWithGlyph(summary) {
    var text = String(summary || "").replace(/^\s+/, "");
    if (!text) return false;
    var offset = 1;
    var first = text.charCodeAt(0);
    if (first >= 0xd800 && first <= 0xdbff && text.length > 1) offset = 2;
    var spaces = 0;
    while (offset < text.length && text.charAt(offset) === " ") {
        spaces++;
        offset++;
    }
    return spaces >= 2;
}

// -------------------------------------------------------- enrichment

// A card stacks at most FACES_MAX faces; the people past them are one
// "+N" chip.
var FACES_MAX = 3;
// A sender's workspace list is read up to WORKSPACES_MAX workspaces, so the
// icon copies taken from it stay bounded.
var WORKSPACES_MAX = 16;
// A workspace the list does not name, or names with no icon, is looked up
// again on a later notification at most this often, in milliseconds.
var WORKSPACE_RELOAD_GAP = 60000;
// The per-application rules that read who wrote and where from a sender's
// own text. A rule matches a notification whose desktop entry or
// application name, case folded, is one of its `names`. `read(summary,
// body)` answers { workspace, title, people }, or null for text in no shape
// it knows, which the card draws as it came. `workspaces`, when set, is
// where the sender's own client keeps its workspace list and the icons it
// downloaded, under XDG_CONFIG_HOME, and the reader of that list.
var ENRICHERS = [
    {
        id: "slack",
        names: ["slack", "com.slack.slack"],
        read: readSlack,
        workspaces: { index: "Slack/storage/root-state.json", cache: "Slack/Cache/Cache_Data", read: slackWorkspaces }
    }
];

function enricherFor(app, desktopEntry) {
    var wanted = [String(desktopEntry || "").toLowerCase(), String(app || "").toLowerCase()];
    for (var r = 0; r < ENRICHERS.length; r++)
        for (var n = 0; n < ENRICHERS[r].names.length; n++)
            if (wanted.indexOf(ENRICHERS[r].names[n]) !== -1) return ENRICHERS[r];
    return null;
}

function enricherById(id) {
    for (var r = 0; r < ENRICHERS.length; r++)
        if (ENRICHERS[r].id === id) return ENRICHERS[r];
    return null;
}

// The ids of the rules that keep a workspace list.
function workspaceRuleIds() {
    return ENRICHERS.filter(function (r) { return !!r.workspaces; }).map(function (r) { return r.id; });
}

// What a card draws for a notification a rule reads: the rule, the
// workspace the summary names or "", the summary without that workspace,
// the first FACES_MAX people it names and how many more there are. Null
// when no rule matches or the rule does not know the text.
function enrich(app, desktopEntry, summary, body) {
    var rule = enricherFor(app, desktopEntry);
    if (rule === null) return null;
    var read = rule.read(String(summary || ""), String(body || ""));
    if (read === null) return null;
    return {
        rule: rule.id,
        workspace: read.workspace,
        title: read.title,
        faces: read.people.slice(0, FACES_MAX),
        more: Math.max(0, read.people.length - FACES_MAX)
    };
}

function fold(name) {
    return String(name).trim().toLowerCase();
}

// The sender a message body opens with, as "Name: text", or "".
function bodySender(body) {
    var match = /^([^:\n<>]{1,80}): \S/.exec(body);
    return match ? match[1].trim() : "";
}

// Slack's titles, as its web client (Slack 4.52.162, read on 2026-09-28)
// builds them: with more than one workspace signed in, "[<domain>] from
// <name>" for a direct message and "[<domain>] in <conversation>" for
// anything else; with one, "New message from <name>", "New message in
// <conversation>" and "New thread message in <conversation>"; and "<name>
// is trying to reach you" for a direct message past Do Not Disturb. A group
// direct message's conversation is its members' names, comma separated,
// which no channel name holds. The body of anything but a direct message
// opens with its sender, "Name: text". Slack on Linux sends no image.
function readSlack(summary, body) {
    var workspace = "";
    var rest = summary;
    var bracket = /^\[([^\]\n]{1,80})\] (.+)$/.exec(summary);
    if (bracket) {
        workspace = bracket[1];
        rest = bracket[2];
    }
    var direct = /^(?:New message )?from (.+)$/.exec(rest) || /^(.+) is trying to reach you$/.exec(rest);
    if (direct) return { workspace: workspace, title: rest, people: [direct[1]] };
    var within = /^(?:New (?:thread )?message )?in (.+)$/.exec(rest);
    if (!within) return workspace === "" ? null : { workspace: workspace, title: rest, people: [] };
    var sender = bodySender(body);
    var members = within[1].indexOf(",") === -1 ? [] : within[1].split(",").map(function (n) { return n.trim(); }).filter(function (n) { return n !== ""; });
    var people = sender === "" ? [] : [sender];
    for (var i = 0; i < members.length; i++)
        if (sender === "" || fold(members[i]) !== fold(sender)) people.push(members[i]);
    return { workspace: workspace, title: rest, people: people };
}

// The tints a face takes, the names of the Appearance face.tint group.
var FACE_TINTS = ["coral", "amber", "green", "blue", "indigo", "magenta", "teal", "rose"];

// The tint of a person's face: the same name, case folded, always takes
// the same one. The hash is 31 times the running value plus each UTF-16
// code unit, modulo 65521.
function faceTint(name) {
    var key = fold(name || "");
    var hash = 0;
    for (var i = 0; i < key.length; i++) hash = (hash * 31 + key.charCodeAt(i)) % 65521;
    return FACE_TINTS[hash % FACE_TINTS.length];
}

// The one or two letters a face without an image shows: the first of the
// first and the last word, a parenthesised part such as a pronoun or an
// organisation left out.
function initialsOf(name) {
    var words = String(name || "").replace(/\([^)]*\)/g, " ").replace(/^[\s@#]+/, "").trim().split(/\s+/).filter(function (w) { return w !== ""; });
    if (words.length === 0) return "?";
    var first = Array.from(words[0])[0];
    var last = words.length > 1 ? Array.from(words[words.length - 1])[0] : "";
    return (first + last).toUpperCase();
}

// Slack's workspace list, storage/root-state.json: `workspaces` maps a team
// id to { domain, name, icon: { image_68, image_88 } }, each icon an https
// URL. Answers { ok: true, workspaces: [{ id, names, urls }], skipped } in
// team-id order, at most WORKSPACES_MAX, the larger icon first; an entry
// with no safe id or no name is skipped and counted. { ok: false, error }
// names why the file is not a list.
function slackWorkspaces(text) {
    var parsed;
    try {
        parsed = JSON.parse(String(text));
    } catch (e) {
        return { ok: false, error: "not-json" };
    }
    if (!isPlainObject(parsed) || !isPlainObject(parsed.workspaces)) return { ok: false, error: "workspaces want=object" };
    var out = [];
    var skipped = 0;
    var ids = Object.keys(parsed.workspaces).sort();
    for (var i = 0; i < ids.length && out.length < WORKSPACES_MAX; i++) {
        var w = parsed.workspaces[ids[i]];
        var names = isPlainObject(w) ? [w.domain, w.name].filter(function (n) { return typeof n === "string" && n.trim() !== ""; }) : [];
        if (!/^[A-Za-z0-9]{1,32}$/.test(ids[i]) || names.length === 0) {
            skipped++;
            continue;
        }
        var icon = isPlainObject(w.icon) ? w.icon : {};
        var urls = [icon.image_88, icon.image_68].filter(function (u) { return typeof u === "string" && /^https:\/\/[^\s]+$/.test(u); });
        out.push({ id: ids[i], names: names, urls: urls });
    }
    return { ok: true, workspaces: out, skipped: skipped };
}

// The helper's copy pairs for a workspace list: each icon URL to
// <dir>/<team id>-<n>, n its place among the workspace's URLs.
function workspaceCopies(workspaces, dir) {
    var pairs = [];
    for (var i = 0; i < workspaces.length; i++)
        for (var n = 0; n < workspaces[i].urls.length; n++)
            pairs.push({ to: dir + "/" + workspaces[i].id + "-" + n, url: workspaces[i].urls[n] });
    return pairs;
}

// Workspace name, case folded -> the file URL of its first icon the helper
// copied, or "" when it copied none. Each workspace answers to its domain
// and its name; a name two workspaces share keeps the first.
function workspaceIconMap(workspaces, dir, copied) {
    var map = {};
    for (var i = 0; i < workspaces.length; i++) {
        var file = "";
        for (var n = 0; n < workspaces[i].urls.length && file === ""; n++) {
            var to = dir + "/" + workspaces[i].id + "-" + n;
            if (copied.indexOf(to) !== -1) file = "file://" + to;
        }
        for (var k = 0; k < workspaces[i].names.length; k++) {
            var key = fold(workspaces[i].names[k]);
            if (!hasOwn(map, key)) map[key] = file;
        }
    }
    return map;
}

// Whether a notification naming `workspace` should read the list again: the
// list does not name it or names it with no icon, and the last read began
// WORKSPACE_RELOAD_GAP or longer ago.
function workspaceReload(map, workspace, loadedAt, now) {
    var key = fold(workspace);
    if (key === "" || (hasOwn(map, key) && map[key] !== "")) return false;
    return now - loadedAt >= WORKSPACE_RELOAD_GAP;
}

// Slack photos cache data, as slack-photos.js prints and stores it, reduced
// to the fields the card needs. Names are matched case-folded the same way
// initials and Slack sender parsing key them.
function slackPhotos(text) {
    var parsed;
    try {
        parsed = JSON.parse(String(text));
    } catch (e) {
        return { ok: false, error: "not-json" };
    }
    if (!isPlainObject(parsed)) return { ok: false, error: "not-object" };
    if (parsed.status === "absent") return { ok: true, status: "absent", teams: [], generatedAt: 0, downloadFailed: 0, stale: false };
    if (parsed.status !== "loaded") return { ok: false, error: "status want=loaded|absent" };
    if (!Array.isArray(parsed.teams)) return { ok: false, error: "teams want=list" };
    var teams = [];
    for (var t = 0; t < parsed.teams.length; t++) {
        var team = parsed.teams[t];
        if (!isPlainObject(team)) return { ok: false, error: "teams." + t + " want=object" };
        if (typeof team.id !== "string" || !/^[A-Za-z0-9]{1,32}$/.test(team.id)) return { ok: false, error: "teams." + t + ".id want=safe" };
        if (!Array.isArray(team.names)) return { ok: false, error: "teams." + t + ".names want=list" };
        if (!Array.isArray(team.users)) return { ok: false, error: "teams." + t + ".users want=list" };
        var names = uniqueNames(team.names);
        if (names.length === 0) return { ok: false, error: "teams." + t + ".names want=non-empty" };
        var users = [];
        for (var u = 0; u < team.users.length; u++) {
            var user = team.users[u];
            if (!isPlainObject(user)) return { ok: false, error: "teams." + t + ".users." + u + " want=object" };
            if (typeof user.id !== "string" || !/^[A-Za-z0-9]{1,32}$/.test(user.id)) return { ok: false, error: "teams." + t + ".users." + u + ".id want=safe" };
            var userNames = uniqueNames(user.names);
            if (userNames.length === 0) continue;
            var photo = typeof user.photo === "string" && /^file:\/\/\/[^\s]+$/.test(user.photo) ? user.photo : "";
            users.push({ id: user.id, names: userNames, photo: photo });
        }
        var icon = typeof team.icon === "string" && /^file:\/\/\/[^\s]+$/.test(team.icon) ? team.icon : "";
        teams.push({ id: team.id, names: names, icon: icon, users: users });
    }
    return {
        ok: true,
        status: "loaded",
        generatedAt: typeof parsed.generatedAt === "number" && isFinite(parsed.generatedAt) ? parsed.generatedAt : 0,
        downloadFailed: typeof parsed.downloadFailed === "number" && isFinite(parsed.downloadFailed) && parsed.downloadFailed > 0 ? Math.floor(parsed.downloadFailed) : 0,
        stale: parsed.stale === true,
        teams: teams
    };
}

function uniqueNames(names) {
    var out = [];
    var seen = {};
    if (!Array.isArray(names)) return out;
    for (var i = 0; i < names.length; i++) {
        if (typeof names[i] !== "string") continue;
        var name = names[i].trim();
        var key = fold(name);
        if (key === "" || hasOwn(seen, key)) continue;
        seen[key] = true;
        out.push(name);
    }
    return out;
}

function slackTeamFor(teams, workspace) {
    var wanted = fold(workspace);
    if (wanted === "") return teams.length === 1 ? teams[0] : null;
    for (var t = 0; t < teams.length; t++)
        for (var n = 0; n < teams[t].names.length; n++)
            if (fold(teams[t].names[n]) === wanted) return teams[t];
    return null;
}

function slackUserPhotoMap(team) {
    var map = {};
    if (team === null) return map;
    for (var u = 0; u < team.users.length; u++) {
        var photo = team.users[u].photo;
        if (photo === "") continue;
        for (var n = 0; n < team.users[u].names.length; n++) {
            var key = fold(team.users[u].names[n]);
            if (!hasOwn(map, key)) map[key] = photo;
        }
    }
    return map;
}

function slackFaceImages(enrichment, teams, carriedImage) {
    var images = [];
    if (enrichment === null || enrichment.rule !== "slack") return images;
    var map = slackUserPhotoMap(slackTeamFor(teams, enrichment.workspace));
    for (var i = 0; i < enrichment.faces.length; i++) {
        var key = fold(enrichment.faces[i]);
        images.push(hasOwn(map, key) ? map[key] : (i === 0 ? String(carriedImage || "") : ""));
    }
    return images;
}

function slackWorkspaceIcon(teams, workspace) {
    var team = slackTeamFor(teams, workspace);
    return team === null ? "" : team.icon;
}

// ----------------------------------------------------------- Silence

// Silence lets one kind through: a critical notification from the bare
// command line, whose sender named no application of its own. A chat
// application marks everything critical to force it through, and it names
// itself, so critical alone is not enough.
function bypassesSilence(appName, urgency) {
    return String(appName || "") === "notify-send" && urgency === URGENCY.critical;
}

// A notification nobody looks back at: marked transient, or sent from the
// bare command line. A silenced one is not recorded at all.
function isEphemeral(appName, transient) {
    return !!transient || String(appName || "") === "notify-send";
}

// ---------------------------------------------------------- lifetime

// How long a toast shows, in milliseconds; 0 is until it is closed.
// `normal` is a normal toast's floor, the `duration` setting in
// milliseconds; a low one's is the shorter of LOW_LIFETIME and `normal`. A
// sender's timeout, in milliseconds, is held between the urgency's floor
// and the ceiling.
function lifetimeFor(urgency, expireTimeout, normal) {
    if (urgency === URGENCY.critical) return 0;
    var asked = Number(expireTimeout || 0);
    if (!isFinite(asked) || asked <= 0) asked = 0;
    var floor = urgency === URGENCY.low ? Math.min(LOW_LIFETIME, normal) : normal;
    return Math.min(MAX_LIFETIME, Math.max(floor, Math.round(asked)));
}

// ------------------------------------------------------------ entries

function clip(text, max) {
    var s = String(text === undefined || text === null ? "" : text);
    return s.length > max ? s.slice(0, max) : s;
}

function keyOf(timestamp, originalId) {
    return String(timestamp) + "-" + String(originalId);
}

// The row a notification becomes, from the plain values read off it. The
// key is its identity for its whole life, on screen, in the state file and
// in history, and names its image copies: a replacement keeps the key of the
// toast it takes over. `taken` answers whether a key is in use; a clash
// moves the timestamp on by a millisecond.
function entryOf(fields, timestamp, taken) {
    var f = fields || {};
    var id = Number(f.id) || 0;
    var at = Number(timestamp) || 0;
    while (taken && taken(keyOf(at, id))) at += 1;
    var expire = Number(f.expireTimeout || 0);
    if (!isFinite(expire) || expire < 0) expire = 0;
    var urgency = Number(f.urgency);
    if (urgency !== URGENCY.low && urgency !== URGENCY.critical) urgency = URGENCY.normal;
    return {
        key: keyOf(at, id),
        originalId: id,
        app: clip(f.appName, SUMMARY_MAX),
        appIcon: drawnImage(f.appIcon),
        summary: clip(f.summary, SUMMARY_MAX),
        body: clip(f.body, BODY_MAX),
        image: drawnImage(f.image),
        desktopEntry: String(f.desktopEntry || ""),
        urgency: urgency,
        expireTimeout: expire,
        timestamp: at
    };
}

// An entry updated in place by its sender: the new content under the old
// identity.
function updatedEntry(entry, fields) {
    var next = entryOf(fields, entry.timestamp, null);
    next.key = entry.key;
    next.originalId = entry.originalId;
    next.timestamp = entry.timestamp;
    return next;
}

// Whether an update changes anything a card draws.
function entryChanged(a, b) {
    for (var i = 0; i < ENTRY_ROLES.length; i++)
        if (a[ENTRY_ROLES[i]] !== b[ENTRY_ROLES[i]]) return true;
    return false;
}

// Quickshell hands an image-path hint through its icon provider, so a
// sender's file arrives as image://icon/ and the path (read in the sandbox
// with Quickshell 0.3.1 on 2026-09-28).
var ICON_PROVIDER = "image://icon/";

// The filesystem path behind a file-backed image value, or "" for what a
// copy cannot capture: a themed icon name, an in-process image:// URL.
function localImageFile(value) {
    var s = String(value || "");
    if (s.indexOf(ICON_PROVIDER) === 0 && s.charAt(ICON_PROVIDER.length) === "/") return s.slice(ICON_PROVIDER.length);
    if (s.indexOf("file://") === 0) {
        s = s.slice(7);
        try { s = decodeURIComponent(s); } catch (e) { return ""; }
    }
    return s.charAt(0) === "/" ? s : "";
}

// An image value as the card draws it: a sender's file as a file URL, so a
// file that is gone fails to load and the card draws no image, and anything
// else as it came.
function drawnImage(value) {
    var path = localImageFile(value);
    return path ? "file://" + path : String(value || "");
}

// The entry as the state file stores it, with the copies that make it true.
// A sender's image files and its in-process images go when the notification
// closes, so a stored entry points at its own copy under `imagesDir`; an
// image:// URL cannot be copied and is dropped, and the card then falls back
// to the application icon. A value already pointing at its copy maps onto
// itself and needs no copy.
function persistable(entry, imagesDir) {
    var out = {};
    for (var i = 0; i < ENTRY_ROLES.length; i++) out[ENTRY_ROLES[i]] = entry[ENTRY_ROLES[i]];
    var copies = [];
    for (var r = 0; r < IMAGE_ROLES.length; r++) {
        var role = IMAGE_ROLES[r];
        var value = String(out[role] || "");
        if (!value) continue;
        var source = localImageFile(value);
        if (source) {
            var copy = imagesDir + "/" + entry.key + "-" + role;
            if (source !== copy) copies.push({ from: source, to: copy });
            out[role] = "file://" + copy;
        } else if (value.indexOf("image://") === 0) {
            out[role] = "";
        }
    }
    return { entry: out, copies: copies };
}

// Every image copy name the stored entries own, the rest of the images
// directory being orphans.
function ownedImages(entries) {
    var names = [];
    for (var i = 0; i < entries.length; i++)
        for (var r = 0; r < IMAGE_ROLES.length; r++) {
            var value = String(entries[i][IMAGE_ROLES[r]] || "");
            var name = entries[i].key + "-" + IMAGE_ROLES[r];
            if (value.indexOf("file://") === 0 && value.slice(value.lastIndexOf("/") + 1) === name) names.push(name);
        }
    return names.sort();
}

// ------------------------------------------------------------- state

// The state file's content for this state.
function serializeState(state) {
    return JSON.stringify({
        version: STATE_VERSION,
        dnd: state.dnd,
        readBefore: state.readBefore,
        live: state.live,
        history: state.history
    }, null, 1) + "\n";
}

function entryError(value, where) {
    if (!isPlainObject(value)) return where + " want=object";
    var keys = Object.keys(value);
    for (var k = 0; k < keys.length; k++)
        if (ENTRY_ROLES.indexOf(keys[k]) === -1 && CLOCK_FIELDS.indexOf(keys[k]) === -1) return where + "." + keys[k] + " unknown";
    var strings = ["key", "app", "appIcon", "summary", "body", "image", "desktopEntry"];
    for (var s = 0; s < strings.length; s++)
        if (typeof value[strings[s]] !== "string") return where + "." + strings[s] + " want=string";
    var numbers = ["originalId", "expireTimeout", "timestamp"];
    for (var n = 0; n < numbers.length; n++)
        if (typeof value[numbers[n]] !== "number" || !isFinite(value[numbers[n]])) return where + "." + numbers[n] + " want=number";
    if ([URGENCY.low, URGENCY.normal, URGENCY.critical].indexOf(value.urgency) === -1) return where + ".urgency want=0|1|2";
    if (value.key !== keyOf(value.timestamp, value.originalId)) return where + ".key want=" + keyOf(value.timestamp, value.originalId);
    for (var c = 0; c < CLOCK_FIELDS.length; c++)
        if (value[CLOCK_FIELDS[c]] !== undefined && (typeof value[CLOCK_FIELDS[c]] !== "number" || !isFinite(value[CLOCK_FIELDS[c]]))) return where + "." + CLOCK_FIELDS[c] + " want=number";
    if (value.deadline !== undefined && value.remaining !== undefined) return where + " deadline and remaining both set";
    return "";
}

// Judge the state file's text: { ok: true, state } or { ok: false, error }
// naming the first defect. An empty file is refused like any other defect:
// the service writes the whole document at once, so a file with nothing in
// it was cut short.
function parseState(text) {
    var parsed;
    try {
        parsed = JSON.parse(String(text));
    } catch (e) {
        return { ok: false, error: "not-json" };
    }
    if (!isPlainObject(parsed)) return { ok: false, error: "not-object" };
    var keys = Object.keys(parsed);
    for (var k = 0; k < keys.length; k++)
        if (["version", "dnd", "readBefore", "live", "history"].indexOf(keys[k]) === -1) return { ok: false, error: keys[k] + " unknown" };
    if (parsed.version !== STATE_VERSION) return { ok: false, error: "version want=" + STATE_VERSION };
    if (typeof parsed.dnd !== "boolean") return { ok: false, error: "dnd want=boolean" };
    if (typeof parsed.readBefore !== "number" || !isFinite(parsed.readBefore)) return { ok: false, error: "readBefore want=number" };
    var lists = ["live", "history"];
    var limits = { live: LIVE_MAX, history: HISTORY_MAX };
    var seen = {};
    for (var l = 0; l < lists.length; l++) {
        var list = parsed[lists[l]];
        if (!Array.isArray(list)) return { ok: false, error: lists[l] + " want=list" };
        if (list.length > limits[lists[l]]) return { ok: false, error: lists[l] + " length=" + list.length + " want<=" + limits[lists[l]] };
        for (var i = 0; i < list.length; i++) {
            var error = entryError(list[i], lists[l] + "." + i);
            if (error !== "") return { ok: false, error: error };
            if (seen[list[i].key]) return { ok: false, error: lists[l] + "." + i + ".key duplicate" };
            seen[list[i].key] = true;
        }
    }
    return { ok: true, state: { dnd: parsed.dnd, readBefore: parsed.readBefore, live: parsed.live, history: parsed.history } };
}

function emptyState() {
    return { dnd: false, readBefore: 0, live: [], history: [] };
}

// ------------------------------------------------------------ restart

// A stored toast on screen carries its clock as the service last settled
// it: `deadline`, when it runs out while running, or `remaining`, what was
// left when the pointer or a panel paused it.
var CLOCK_FIELDS = ["deadline", "remaining"];

// The clock fields a toast's clock (NotificationLogic's clocks) stores.
function clockFields(clock) {
    return clock.since === null ? { remaining: clock.remaining } : { deadline: clock.since + clock.remaining };
}

// The stored toasts a start shows again and the ones whose time ran out
// while the shell was down, which go into the history. A running clock is
// judged by its deadline and a paused one has not run out; a toast with no
// clock stored is judged by when it arrived. A toast shown again restarts
// with a whole lifetime, recorded as a deadline so a second restart judges
// it by that clock and not by when it arrived. `normal` is lifetimeFor's.
function restorePlan(live, now, normal) {
    var show = [];
    var expired = [];
    for (var i = 0; i < live.length; i++) {
        var entry = live[i];
        var lifetime = lifetimeFor(entry.urgency, entry.expireTimeout, normal);
        var over = entry.remaining !== undefined ? false
            : entry.deadline !== undefined ? now >= entry.deadline
            : lifetime > 0 && now - entry.timestamp >= lifetime;
        if (over) {
            expired.push(withoutDeadline(entry));
            continue;
        }
        var kept = withoutDeadline(entry);
        if (lifetime > 0) kept.deadline = now + lifetime;
        show.push(kept);
    }
    return { show: show, expired: expired };
}

function withoutDeadline(entry) {
    var out = {};
    for (var i = 0; i < ENTRY_ROLES.length; i++) out[ENTRY_ROLES[i]] = entry[ENTRY_ROLES[i]];
    return out;
}

// ------------------------------------------------------------ history

// The history with `entries` added at its head, newest first, each key once,
// cut to HISTORY_MAX. Answers the history and the entries it let go.
function pushHistory(history, entries) {
    var incoming = entries.map(withoutDeadline);
    var keys = {};
    for (var i = 0; i < incoming.length; i++) keys[incoming[i].key] = true;
    var merged = incoming.concat(history.filter(function (e) { return !keys[e.key]; }));
    merged.sort(function (a, b) { return b.timestamp - a.timestamp; });
    return { history: merged.slice(0, HISTORY_MAX), dropped: merged.slice(HISTORY_MAX) };
}

// The rows a panel shows: the Inbox what arrived after the last Mark read,
// the History everything kept, at most PANEL_ROWS_MAX, newest first.
function panelRows(history, mode, readBefore) {
    var rows = mode === "inbox" ? history.filter(function (e) { return e.timestamp > readBefore; }) : history.slice();
    return rows.slice(0, PANEL_ROWS_MAX);
}

// The panel's subtitle under its title.
function panelSubtitle(mode, count, storeState) {
    if (storeState !== "loaded" && storeState !== "absent") return "History unavailable: " + storeState;
    if (count === 0) return mode === "history" ? "Nothing kept yet" : "All caught up";
    return count + (count === 1 ? " notification" : " notifications");
}

// The key of the toast a full stack lets go for a new one: the oldest that is
// not critical, or the oldest of all when every one is. `rows` are the live
// toasts on screen, oldest last, as { key, urgency }.
function evictionKey(rows) {
    for (var i = rows.length - 1; i >= 0; i--)
        if (rows[i].urgency !== URGENCY.critical) return rows[i].key;
    return rows.length > 0 ? rows[rows.length - 1].key : "";
}

// ------------------------------------------------------------ actions

// The hover actions of a card: the sender's own while it is live, a Show
// that focuses the sender's window when it offers none and one is open, and
// Dismiss. `actions` are { identifier, text } read off the notification.
function actionsFor(actions, canFocus) {
    var list = [];
    for (var i = 0; i < actions.length; i++) {
        var id = String(actions[i].identifier || "");
        if (!id) continue;
        var text = String(actions[i].text || "");
        list.push({ id: "action:" + id, label: text || (id === "default" ? "Open" : id) });
    }
    if (list.length === 0 && canFocus) list.push({ id: "focus", label: "Show" });
    list.push({ id: "dismiss", label: "Dismiss" });
    return list;
}

// The address of the window a notification's sender owns, matched by its
// desktop entry or its application name against each window's class, case
// folded; "" when none matches. `windows` are { address, appClass }.
function focusAddress(windows, desktopEntry, app) {
    var wanted = [String(desktopEntry || "").toLowerCase(), String(app || "").toLowerCase()].filter(function (w) { return w !== "" && w !== "notify-send"; });
    for (var w = 0; w < wanted.length; w++)
        for (var i = 0; i < windows.length; i++) {
            var address = String(windows[i].address || "");
            if (String(windows[i].appClass || "").toLowerCase() !== wanted[w] || address === "") continue;
            return address.indexOf("0x") === 0 ? address : "0x" + address;
        }
    return "";
}

// ------------------------------------------------------------- clocks

// The toasts' lifetimes, as key -> { remaining, since }: `since` is when a
// running clock last started, null while it is paused. `running` answers
// whether a key's clock should run now. Answers the clocks with every one
// that stops charged for the time it ran and every one that starts stamped.
function settleClocks(clocks, running, now) {
    var next = {};
    var keys = Object.keys(clocks);
    for (var i = 0; i < keys.length; i++) {
        var c = clocks[keys[i]];
        var run = running(keys[i]);
        if (c.since !== null && !run) next[keys[i]] = { remaining: Math.max(0, c.remaining - (now - c.since)), since: null };
        else if (c.since === null && run) next[keys[i]] = { remaining: c.remaining, since: now };
        else next[keys[i]] = c;
    }
    return next;
}

// The running clock that runs out first: { key, wait } in milliseconds, or
// null when none runs.
function nextExpiry(clocks, now) {
    var best = null;
    var keys = Object.keys(clocks);
    for (var i = 0; i < keys.length; i++) {
        var c = clocks[keys[i]];
        if (c.since === null) continue;
        var wait = Math.max(0, c.remaining - (now - c.since));
        if (best === null || wait < best.wait) best = { key: keys[i], wait: wait };
    }
    return best;
}

// ---------------------------------------------------------------- IPC

// The Silence an IPC argument asks for, given the current one: `on`, `off`,
// `toggle`, or empty for no change. Answers { ok, dnd } or { ok: false }.
function silenceArgument(arg, current) {
    var v = String(arg || "").trim().toLowerCase();
    if (v === "") return { ok: true, dnd: current };
    if (v === "on") return { ok: true, dnd: true };
    if (v === "off") return { ok: true, dnd: false };
    if (v === "toggle") return { ok: true, dnd: !current };
    return { ok: false };
}
