.pragma library

// The notifications' decisions, with no QML objects and no I/O, so
// scripts/test-notifications-logic.js runs every function under node: what a
// notification body may render, which notifications Silence lets through,
// how long a toast lives, the state file's shape and its judge, the image
// copies an entry owns, what a restart restores, what the history keeps and
// the Inbox shows, which toast a full stack lets go, which actions a card
// offers, the paused and running clocks of the toasts on screen, the
// per-application rules that read a sender's workspace and people, the
// Slack token rows, photo and custom emoji lookups, and which two
// notifications are one message sent twice.

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

// A web notification's leading site address, as Chromium-family browsers
// write it before its text: a link to the site, or the address alone. The
// first group is the host.
var ORIGIN_LINK = /^\s*<a\b[^>]*>\s*(?:https?:\/\/)?((?:[a-z0-9-]+\.)+[a-z]{2,})(?::\d+)?(?:\/[^<\s]*)?\s*<\/a>/i;
var ORIGIN_ADDRESS = /^\s*(?:https?:\/\/)?((?:[a-z0-9-]+\.)+[a-z]{2,})(?::\d+)?(?:\/\S*)?/i;

// A body's leading site address and the text after it: { host, rest },
// host "" and rest the text as it came when there is none. A
// Chromium-family sender's address is followed by white space. Chromium
// as it runs on this system names no application, icon or desktop entry
// at all, and writes the host on a line of its own and a blank line
// after it (`app.slack.com\n\nAda: hi`, read from the owner's history on
// 2026-09-29); for a sender that names no application the blank line is
// required, so its first word is never read as an address.
function splitOrigin(app, appIcon, text) {
    var none = { host: "", rest: text };
    var chromium = isChromiumDerived(app, appIcon);
    if (!chromium && String(app || "") !== "") return none;
    var link = ORIGIN_LINK.exec(text);
    var found = link !== null ? link : ORIGIN_ADDRESS.exec(text);
    if (found === null) return none;
    var after = text.slice(found[0].length);
    var gap = (chromium ? (link !== null ? /^\s*/ : /^\s+/) : /^[ \t]*\r?\n[ \t]*\r?\n\s*/).exec(after);
    if (gap === null) return none;
    return { host: found[1].toLowerCase(), rest: after.slice(gap[0].length) };
}

// The host of the site a web notification came from, or "".
function webOrigin(app, appIcon, body) {
    return splitOrigin(app, appIcon, String(body || "")).host;
}

// The body without image tags, and without the leading site address a
// browser puts before every web notification (splitOrigin).
function sanitizeBody(body, app, appIcon) {
    return splitOrigin(app, appIcon, stripImageTags(String(body || ""))).rest;
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
// application name, case folded, is one of its `names`, the sender's own
// client, or whose body opens with the address of one of its `origins`
// (webOrigin), the same service in a browser. `read(summary, body)`
// answers { workspace, title, people }, or null for text in no shape it
// knows, which the card draws as it came. `workspaces`, when set, is where
// the sender's own client keeps its workspace list and the icons it
// downloaded, under XDG_CONFIG_HOME, and the reader of that list.
var ENRICHERS = [
    {
        id: "slack",
        names: ["slack", "com.slack.slack"],
        origins: ["app.slack.com"],
        read: readSlack,
        workspaces: { index: "Slack/storage/root-state.json", cache: "Slack/Cache/Cache_Data", read: slackWorkspaces }
    }
];

// The rule a notification matches: { rule, source, body }, `source`
// `desktop` for the sender's own client and `browser` for a web origin,
// and `body` the text the rule reads, without the browser's site address.
// Null when no rule matches.
function enricherFor(app, desktopEntry, appIcon, body) {
    var text = String(body || "");
    var wanted = [String(desktopEntry || "").toLowerCase(), String(app || "").toLowerCase()];
    for (var r = 0; r < ENRICHERS.length; r++)
        for (var n = 0; n < ENRICHERS[r].names.length; n++)
            if (wanted.indexOf(ENRICHERS[r].names[n]) !== -1) return { rule: ENRICHERS[r], source: "desktop", body: text };
    var origin = splitOrigin(app, appIcon, text);
    if (origin.host === "") return null;
    for (var o = 0; o < ENRICHERS.length; o++)
        if ((ENRICHERS[o].origins || []).indexOf(origin.host) !== -1) return { rule: ENRICHERS[o], source: "browser", body: origin.rest };
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

// What a card draws for a notification a rule reads: the rule, which
// client sent it (enricherFor), the workspace the summary names or "", the
// summary without that workspace, the first FACES_MAX people it names and
// how many more there are. Null when no rule matches or the rule does not
// know the text.
function enrich(app, desktopEntry, appIcon, summary, body) {
    var matched = enricherFor(app, desktopEntry, appIcon, body);
    if (matched === null) return null;
    var read = matched.rule.read(String(summary || ""), matched.body);
    if (read === null) return null;
    return {
        rule: matched.rule.id,
        source: matched.source,
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
// anything else; with one, and always in a browser, "New message from
// <name>", "New message in <conversation>" and "New thread message in
// <conversation>"; and "<name> is trying to reach you" for a direct message
// past Do Not Disturb. The title the card draws is the multi-workspace
// form, "from <name>" or "in <conversation>", whichever client sent it. A
// group direct message's conversation is its members' names, comma
// separated, which no channel name holds. The body of anything but a
// direct message opens with its sender, "Name: text". Slack on Linux sends
// no image.
function readSlack(summary, body) {
    var workspace = "";
    var rest = summary;
    var bracket = /^\[([^\]\n]{1,80})\] (.+)$/.exec(summary);
    if (bracket) {
        workspace = bracket[1];
        rest = bracket[2];
    }
    var from = /^(?:New message )?from (.+)$/.exec(rest);
    if (from) return { workspace: workspace, title: "from " + from[1], people: [from[1]] };
    var reach = /^(.+) is trying to reach you$/.exec(rest);
    if (reach) return { workspace: workspace, title: rest, people: [reach[1]] };
    var within = /^(?:New (?:thread )?message )?in (.+)$/.exec(rest);
    if (!within) return workspace === "" ? null : { workspace: workspace, title: rest, people: [] };
    var sender = bodySender(body);
    var members = within[1].indexOf(",") === -1 ? [] : within[1].split(",").map(function (n) { return n.trim(); }).filter(function (n) { return n !== ""; });
    var people = sender === "" ? [] : [sender];
    for (var i = 0; i < members.length; i++)
        if (sender === "" || fold(members[i]) !== fold(sender)) people.push(members[i]);
    return { workspace: workspace, title: "in " + within[1], people: people };
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
// URL. Answers { ok: true, workspaces: [{ id, domain, name, names, urls }],
// skipped } in team-id order, at most WORKSPACES_MAX, the larger icon
// first, `domain` and `name` "" when the entry has none and `names` the
// ones it has; an entry with no safe id or no name is skipped and counted.
// { ok: false, error } names why the file is not a list.
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
        var domain = names.indexOf(w.domain) !== -1 ? w.domain : "";
        var name = names.indexOf(w.name) !== -1 ? w.name : "";
        out.push({ id: ids[i], domain: domain, name: name, names: names, urls: urls });
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
            var copiedUrl = copiedVersion(copied, to);
            if (copiedUrl !== "") file = "file://" + copiedUrl;
        }
        for (var k = 0; k < workspaces[i].names.length; k++) {
            var key = fold(workspaces[i].names[k]);
            if (!hasOwn(map, key)) map[key] = file;
        }
    }
    return map;
}

function copiedVersion(copied, to) {
    var prefix = to + "?v=";
    for (var i = 0; i < copied.length; i++) {
        if (typeof copied[i] === "string" && copied[i].indexOf(prefix) === 0 && /^[0-9a-f]{16}$/.test(copied[i].slice(prefix.length))) return copied[i];
    }
    return "";
}

// Whether a notification naming `workspace` should read the list again: the
// list does not name it or names it with no icon, and the last read began
// WORKSPACE_RELOAD_GAP or longer ago.
function workspaceReload(map, workspace, loadedAt, now) {
    var key = fold(workspace);
    if (key === "" || (hasOwn(map, key) && map[key] !== "")) return false;
    return now - loadedAt >= WORKSPACE_RELOAD_GAP;
}

// The states token-status.sh reports for each Slack account, each a value
// of the core's `presence` status type.
var SLACK_TOKEN_STATES = ["present", "absent", "locked", "unavailable"];
// The single-workspace account, and a workspace's own: slack:<team id>.
var SLACK_LEGACY_ACCOUNT = "slack";
var SLACK_ACCOUNT = /^slack(?::[A-Za-z0-9]{1,32})?$/;

// Each Slack account's token state from token-status.sh's stdout, one
// `slack-token: account=<account> <state>` line per account, the
// single-workspace account's among them: { ok: true, states } with
// account -> state, or { ok: false, error } for output the probe does not
// print.
function slackTokenStates(text) {
    var lines = String(text).replace(/\n$/, "").split("\n");
    var states = {};
    for (var i = 0; i < lines.length; i++) {
        var match = /^slack-token: account=(\S+) ([a-z]+)(?: [^\n]*)?$/.exec(lines[i]);
        if (match === null) return { ok: false, error: "line." + i + " unknown" };
        if (!SLACK_ACCOUNT.test(match[1])) return { ok: false, error: "line." + i + ".account unknown" };
        if (SLACK_TOKEN_STATES.indexOf(match[2]) === -1) return { ok: false, error: "line." + i + ".state unknown" };
        if (hasOwn(states, match[1])) return { ok: false, error: "line." + i + ".account duplicate" };
        states[match[1]] = match[2];
    }
    if (!hasOwn(states, SLACK_LEGACY_ACCOUNT)) return { ok: false, error: "account=" + SLACK_LEGACY_ACCOUNT + " missing" };
    return { ok: true, states: states };
}

// The command that stores a Slack token in libsecret, as the Settings
// page shows it: for workspace `id`'s own account, or with id "" the
// single-workspace one. The id is one slackWorkspaces admitted, letters and
// digits alone; no workspace name enters the command.
function slackStoreCommand(id) {
    return id === ""
        ? "secret-tool store --label='VGS notifications Slack token' service vgs-notifications account slack"
        : "secret-tool store --label='VGS notifications Slack token " + id + "' service vgs-notifications account slack:" + id;
}

// A status item's label is one printable line of at most this many
// characters (docs/architecture/status.md § Declared), counted as the
// judge counts them, in UTF-16 code units.
var SLACK_LABEL_MAX = 60;

// A workspace as the Settings page names it: its name, then its domain in
// parentheses, one line, cut to SLACK_LABEL_MAX UTF-16 code units with an
// ellipsis and never between the two halves of a surrogate pair; its team
// id when neither is printable.
function slackWorkspaceLabel(workspace) {
    var clean = function (s) { return String(s).replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g, " ").replace(/\s+/g, " ").trim(); };
    var name = clean(workspace.name);
    var domain = clean(workspace.domain);
    var label = name !== "" && domain !== "" && fold(name) !== fold(domain) ? name + " (" + domain + ")" : name !== "" ? name : domain !== "" ? domain : workspace.id;
    if (label.length <= SLACK_LABEL_MAX) return label;
    var cut = label.slice(0, SLACK_LABEL_MAX - 1);
    var last = cut.charCodeAt(cut.length - 1);
    if (last >= 0xd800 && last <= 0xdbff) cut = cut.slice(0, -1);
    return cut + "\u2026";
}

// The Settings page's Slack token rows, a `presenceList`: one item per
// workspace Slack's list names, in its order, carrying that workspace's own
// account's state and the command that stores it; a workspace whose own
// token is absent while the photo cache says the single-workspace token
// serves it carries that token's state and says so. Then the
// single-workspace token's own item, when no workspace is listed or it is
// stored. `states` is slackTokenStates'; `teams` slackPhotos'. { ok: true,
// items }, or { ok: false, missing } naming an account the states lack,
// while the probe has not yet answered for the list as it now stands.
function slackTokenRows(workspaces, states, teams) {
    if (!hasOwn(states, SLACK_LEGACY_ACCOUNT)) return { ok: false, missing: SLACK_LEGACY_ACCOUNT };
    var legacy = states[SLACK_LEGACY_ACCOUNT];
    var items = [];
    for (var i = 0; i < workspaces.length; i++) {
        var account = "slack:" + workspaces[i].id;
        if (!hasOwn(states, account)) return { ok: false, missing: account };
        var item = { label: slackWorkspaceLabel(workspaces[i]), value: states[account] };
        var served = teams.some(function (t) { return t.id === workspaces[i].id && t.account === SLACK_LEGACY_ACCOUNT; });
        if (states[account] === "absent" && served) {
            item.value = legacy;
            item.hint = "Served by the single-workspace token";
        }
        item.command = slackStoreCommand(workspaces[i].id);
        items.push(item);
    }
    if (workspaces.length === 0 || legacy !== "absent")
        items.push({ label: "Single-workspace token", value: legacy, command: slackStoreCommand("") });
    return { ok: true, items: items };
}

// How long the photo helper waits before its next run, in milliseconds:
// SLACK_PHOTO_RETRY while a token is missing, an account failed, a download
// failed, or a listed workspace has no photos, so a token stored for it is
// read within that; otherwise until the oldest team's day is over. With
// custom emoji on, SLACK_EMOJI_PENDING while a team's emoji wait to be
// converted, and at most SLACK_EMOJI_RESCAN, which reads Slack's cache again
// for the emoji it has shown since; the photos of a run in between are
// served from their cache while fresh.
var SLACK_PHOTO_RETRY = 15 * 60 * 1000;
var SLACK_PHOTO_DAY = 24 * 60 * 60 * 1000;
var SLACK_EMOJI_PENDING = 60 * 1000;
var SLACK_EMOJI_RESCAN = 60 * 60 * 1000;
function slackPhotoDelay(read, workspaces, now, emojiOn) {
    var photos = slackPhotoOnlyDelay(read, workspaces, now);
    if (!emojiOn) return photos;
    var pending = read.ok && read.emoji !== null && read.emoji.some(function (t) { return t.pending > 0; });
    return Math.min(photos, pending ? SLACK_EMOJI_PENDING : SLACK_EMOJI_RESCAN);
}

function slackPhotoOnlyDelay(read, workspaces, now) {
    if (!read.ok || read.status !== "loaded" || read.stale || read.downloadFailed > 0) return SLACK_PHOTO_RETRY;
    for (var i = 0; i < workspaces.length; i++)
        if (!read.teams.some(function (t) { return t.id === workspaces[i].id; })) return SLACK_PHOTO_RETRY;
    var due = (read.generatedAt > 0 ? read.generatedAt : now) + SLACK_PHOTO_DAY;
    return Math.max(1000, due - now);
}

// Slack photos cache data, as slack-photos.js prints and stores it, reduced
// to the fields the card needs. Names are matched case-folded the same way
// initials and Slack sender parsing key them. `emoji` is slackEmojiTeams'
// reading of the run's custom emoji, or null for a run with emoji off.
function slackPhotos(text) {
    var parsed;
    try {
        parsed = JSON.parse(String(text));
    } catch (e) {
        return { ok: false, error: "not-json" };
    }
    if (!isPlainObject(parsed)) return { ok: false, error: "not-object" };
    var emoji = null;
    if (hasOwn(parsed, "emoji")) {
        var read = slackEmojiTeams(parsed.emoji);
        if (!read.ok) return { ok: false, error: read.error };
        emoji = read.teams;
    }
    if (parsed.status === "absent") return { ok: true, status: "absent", teams: [], generatedAt: 0, downloadFailed: 0, stale: false, emoji: emoji };
    if (parsed.status !== "loaded") return { ok: false, error: "status want=loaded|absent" };
    if (!Array.isArray(parsed.teams)) return { ok: false, error: "teams want=list" };
    var teams = [];
    for (var t = 0; t < parsed.teams.length; t++) {
        var team = parsed.teams[t];
        if (!isPlainObject(team)) return { ok: false, error: "teams." + t + " want=object" };
        if (typeof team.id !== "string" || !/^[A-Za-z0-9]{1,32}$/.test(team.id)) return { ok: false, error: "teams." + t + ".id want=safe" };
        if (!Array.isArray(team.names)) return { ok: false, error: "teams." + t + ".names want=list" };
        if (!Array.isArray(team.users)) return { ok: false, error: "teams." + t + ".users want=list" };
        if (typeof team.account !== "string" || !SLACK_ACCOUNT.test(team.account)) return { ok: false, error: "teams." + t + ".account want=slack|slack:<team id>" };
        var names = uniqueNames(team.names);
        if (names.length === 0) return { ok: false, error: "teams." + t + ".names want=non-empty" };
        var users = [];
        for (var u = 0; u < team.users.length; u++) {
            var user = team.users[u];
            if (!isPlainObject(user)) return { ok: false, error: "teams." + t + ".users." + u + " want=object" };
            if (typeof user.id !== "string" || !/^[A-Za-z0-9]{1,32}$/.test(user.id)) return { ok: false, error: "teams." + t + ".users." + u + ".id want=safe" };
            var userNames = uniqueNames(user.names);
            if (userNames.length === 0) continue;
            var photo = slackPhotoFileUrl(user.photo);
            users.push({ id: user.id, names: userNames, photo: photo });
        }
        var icon = slackPhotoFileUrl(team.icon);
        teams.push({ id: team.id, names: names, icon: icon, users: users, account: team.account });
    }
    return {
        ok: true,
        status: "loaded",
        generatedAt: typeof parsed.generatedAt === "number" && isFinite(parsed.generatedAt) ? parsed.generatedAt : 0,
        downloadFailed: typeof parsed.downloadFailed === "number" && isFinite(parsed.downloadFailed) && parsed.downloadFailed > 0 ? Math.floor(parsed.downloadFailed) : 0,
        stale: parsed.stale === true,
        teams: teams,
        emoji: emoji
    };
}

// ------------------------------------------------------- custom emoji

// A custom emoji name the card substitutes, `:name:` in a Slack body, as
// slack-emoji.js admits it; and the most one body substitutes, so a body
// cannot ask for thousands of images.
var EMOJI_NAME = /^[a-z0-9_+-]{1,100}$/;
var EMOJI_PER_BODY = 64;

// The helper's `emoji` list, [{ team, map, count, pending }] with `map`
// name -> the 16 hex digits of the image's file: { ok: true, teams:
// [{ team, map, pending }] }, each map an object with no prototype, or
// { ok: false, error } naming the first entry the helper never prints.
function slackEmojiTeams(value) {
    if (!Array.isArray(value)) return { ok: false, error: "emoji want=list" };
    var teams = [];
    for (var t = 0; t < value.length; t++) {
        var entry = value[t];
        var at = "emoji." + t;
        if (!isPlainObject(entry)) return { ok: false, error: at + " want=object" };
        if (typeof entry.team !== "string" || !/^[A-Za-z0-9]{1,32}$/.test(entry.team)) return { ok: false, error: at + ".team want=safe" };
        if (!isPlainObject(entry.map)) return { ok: false, error: at + ".map want=object" };
        if (typeof entry.pending !== "number" || !isFinite(entry.pending) || entry.pending < 0) return { ok: false, error: at + ".pending want=count" };
        var map = Object.create(null);
        var names = Object.keys(entry.map);
        for (var n = 0; n < names.length; n++) {
            var hex = entry.map[names[n]];
            if (!EMOJI_NAME.test(names[n])) return { ok: false, error: at + ".map name want=" + EMOJI_NAME.source };
            if (typeof hex !== "string" || !/^[0-9a-f]{16}$/.test(hex)) return { ok: false, error: at + ".map." + names[n] + " want=hex16" };
            map[names[n]] = hex;
        }
        teams.push({ team: entry.team, map: map, pending: entry.pending });
    }
    return { ok: true, teams: teams };
}

// Team id -> a frozen lookup, name -> the file URL of its image under the
// helper's root `dir`, built once when the shell takes a run's emoji, so a
// card's lookup is one own-property read.
function slackEmojiLookups(teams, dir) {
    var out = Object.create(null);
    for (var t = 0; t < teams.length; t++) {
        var lookup = Object.create(null);
        var names = Object.keys(teams[t].map);
        for (var n = 0; n < names.length; n++) {
            var hex = teams[t].map[names[n]];
            lookup[names[n]] = "file://" + dir + "/" + teams[t].team + "/emoji/" + hex + ".png?v=" + hex;
        }
        out[teams[t].team] = Object.freeze(lookup);
    }
    return Object.freeze(out);
}

// The team id of the workspace a Slack card belongs to (slackWorkspaceFor),
// from Slack's list and the photo teams, or "".
function slackTeamIdFor(workspaces, teams, workspace) {
    var wanted = fold(workspace);
    if (wanted === "") return "";
    var known = workspaces.concat(teams);
    for (var i = 0; i < known.length; i++)
        for (var n = 0; n < known[i].names.length; n++)
            if (fold(known[i].names[n]) === wanted) return known[i].id;
    return "";
}

// The emoji lookup of a card (enrich's reading) in `workspace`: that team's
// alone, from slackEmojiLookups' `lookups`, or null for a card of another
// rule or a workspace with no emoji, which draws its body as text.
function slackEmojiFor(lookups, enrichment, workspaces, teams, workspace) {
    if (enrichment === null || enrichment.rule !== "slack") return null;
    var id = slackTeamIdFor(workspaces, teams, workspace);
    return id !== "" && hasOwn(lookups, id) ? lookups[id] : null;
}

// A body as ImageText segments (shell/Ui/foundation/ImageTextLogic.js):
// `styled`, styledBody's markup, with each `:name:` that `lookup`, one
// team's emoji, holds drawn as that image, its alt text the shortcode. A
// name is read only in the text between tags, never inside a tag or its
// attributes and never across one; a name the lookup lacks, another team's
// among them, stays text; at most EMOJI_PER_BODY are substituted. A null
// lookup is a body with no emoji.
function emojiSegments(styled, lookup) {
    var text = String(styled);
    if (lookup === null) return [{ markup: text }];
    var segments = [];
    var markup = "";
    var count = 0;
    var i = 0;
    while (i < text.length) {
        var open = text.indexOf("<", i);
        var run = open === -1 ? text.slice(i) : text.slice(i, open);
        var shortcode = /:([a-z0-9_+-]{1,100}):/g;
        var from = 0;
        var found;
        while ((found = shortcode.exec(run)) !== null) {
            if (count >= EMOJI_PER_BODY || !hasOwn(lookup, found[1])) {
                // The closing colon may open the next shortcode.
                shortcode.lastIndex = found.index + found[0].length - 1;
                continue;
            }
            markup += run.slice(from, found.index);
            if (markup !== "") segments.push({ markup: markup });
            markup = "";
            segments.push({ image: lookup[found[1]], alt: found[0] });
            from = found.index + found[0].length;
            count++;
        }
        markup += run.slice(from);
        if (open === -1) break;
        var close = text.indexOf(">", open);
        markup += close === -1 ? text.slice(open) : text.slice(open, close + 1);
        i = close === -1 ? text.length : close + 1;
    }
    if (markup !== "" || segments.length === 0) segments.push({ markup: markup });
    return segments;
}

function slackPhotoFileUrl(value) {
    return typeof value === "string" && /^file:\/\/\/[^\s?#]+\.png\?v=[0-9a-f]{16}$/.test(value) ? value : "";
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

// The photo team a workspace name, case folded, names, or null.
function slackTeamFor(teams, workspace) {
    var wanted = fold(workspace);
    if (wanted === "") return null;
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

// The workspace a Slack card belongs to (enrich's reading): the one its
// summary names; else the only workspace known, from Slack's list
// (slackWorkspaces) and the photo cache (slackPhotos) together; else the
// one photo team whose users hold its sender's name; else "". A browser
// names no workspace, nor does Slack with one signed in. Another rule's
// card keeps the workspace its summary names.
function slackWorkspaceFor(enrichment, workspaces, teams) {
    if (enrichment === null) return "";
    if (enrichment.rule !== "slack" || enrichment.workspace !== "") return enrichment.workspace;
    var known = {};
    for (var w = 0; w < workspaces.length; w++) if (!hasOwn(known, workspaces[w].id)) known[workspaces[w].id] = workspaces[w].names[0];
    for (var t = 0; t < teams.length; t++) if (!hasOwn(known, teams[t].id)) known[teams[t].id] = teams[t].names[0];
    var ids = Object.keys(known);
    if (ids.length === 1) return known[ids[0]];
    if (enrichment.faces.length === 0) return "";
    var holders = slackTeamsHolding(teams, enrichment.faces[0]);
    return holders.length === 1 ? holders[0].names[0] : "";
}

// The photo teams one of whose users goes by `name`, case folded.
function slackTeamsHolding(teams, name) {
    var key = fold(name);
    return teams.filter(function (team) {
        return team.users.some(function (u) { return u.names.some(function (n) { return fold(n) === key; }); });
    });
}

// One photo per face of a Slack card in `workspace` (slackWorkspaceFor):
// that team's photo of the name, none for a workspace the photo cache does
// not hold; with no workspace, the photo of the one team that holds the
// name, and none when several or none do. A face with no photo takes,
// when it is the first, the image the notification carries, else "".
function slackFaceImages(enrichment, teams, carriedImage, workspace) {
    var images = [];
    if (enrichment === null || enrichment.rule !== "slack") return images;
    var team = slackTeamFor(teams, workspace);
    var map = slackUserPhotoMap(team);
    for (var i = 0; i < enrichment.faces.length; i++) {
        var key = fold(enrichment.faces[i]);
        var photo = "";
        if (fold(workspace) !== "") photo = hasOwn(map, key) ? map[key] : "";
        else {
            var holders = slackTeamsHolding(teams, enrichment.faces[i]);
            var only = holders.length === 1 ? slackUserPhotoMap(holders[0]) : {};
            photo = hasOwn(only, key) ? only[key] : "";
        }
        images.push(photo !== "" ? photo : (i === 0 ? String(carriedImage || "") : ""));
    }
    return images;
}

function slackWorkspaceIcon(teams, workspace) {
    var team = slackTeamFor(teams, workspace);
    return team === null ? "" : team.icon;
}

// -------------------------------------------------------- duplicates

// Two copies of one message, one from the sender's own client and one from
// its web client in a browser, arrive within DUPLICATE_WINDOW milliseconds
// of each other; the last DUPLICATES_MAX messages a rule read within the
// window are remembered to find them.
var DUPLICATE_WINDOW = 10000;
var DUPLICATES_MAX = 32;

// A notification a rule reads, as the message it carries: { key, rule,
// source, conversation, sender, text, workspace, at }, the conversation
// the title names, the first person, the body as plain text with its
// markup and white space runs gone, and the workspace the summary names,
// each case folded but the text. Null for a notification no rule reads.
function messageOf(entry) {
    var read = enrich(entry.app, entry.desktopEntry, entry.appIcon, entry.summary, entry.body);
    if (read === null) return null;
    return {
        key: entry.key,
        rule: read.rule,
        source: read.source,
        conversation: fold(read.title),
        sender: read.faces.length > 0 ? fold(read.faces[0]) : "",
        text: sanitizeBody(entry.body, entry.app, entry.appIcon).replace(/<[^>]*>/g, " ").replace(/\s+/g, " ").trim(),
        workspace: fold(read.workspace),
        at: entry.timestamp
    };
}

// The remembered message `message` is another copy of, or null: the same
// rule from the other client, the same conversation, sender and text, the
// same workspace or one of the two naming none, within DUPLICATE_WINDOW.
// Two copies from the same client are two messages.
function duplicateOf(recent, message) {
    for (var i = recent.length - 1; i >= 0; i--) {
        var r = recent[i];
        if (r.rule === message.rule && r.source !== message.source && r.conversation === message.conversation
            && r.sender === message.sender && r.text === message.text
            && (r.workspace === message.workspace || r.workspace === "" || message.workspace === "")
            && Math.abs(message.at - r.at) <= DUPLICATE_WINDOW) return r;
    }
    return null;
}

// Which copy stays when `message` repeats `prior`: `message` when it is the
// sender's own client's, which names the workspace, and prior's card is
// still on screen to give way; `prior`, the first recorded, otherwise.
function duplicateKept(prior, message, priorOnScreen) {
    return message.source === "desktop" && priorOnScreen ? "message" : "prior";
}

// The remembered messages with `message` added, those older than
// DUPLICATE_WINDOW before it let go, at most DUPLICATES_MAX.
function rememberMessage(recent, message) {
    return recent.filter(function (r) { return message.at - r.at <= DUPLICATE_WINDOW; }).concat([message]).slice(-DUPLICATES_MAX);
}

// The remembered messages without `key`'s.
function forgetMessage(recent, key) {
    return recent.filter(function (r) { return r.key !== key; });
}

// What a new `message` does to the remembered messages `recent`: { recent,
// prior, kept }. With no copy remembered, `message` is remembered and
// `prior` is null. With a copy, the pair is settled: `prior` leaves the
// remembered messages and `message` is not remembered, so neither copy
// matches a later message, however alike; `kept` is duplicateKept's answer,
// `onScreen(key)` whether the prior copy's card is still on screen.
function receiveMessage(recent, message, onScreen) {
    var prior = duplicateOf(recent, message);
    if (prior === null) return { recent: rememberMessage(recent, message), prior: null, kept: "message" };
    return { recent: forgetMessage(recent, prior.key), prior: prior, kept: duplicateKept(prior, message, onScreen(prior.key)) };
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
