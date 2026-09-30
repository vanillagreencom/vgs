.pragma library

// The launcher's decisions, with no QML object and no I/O, so
// scripts/test-launcher-model.js runs every function under node: the menu
// file and its merge, the TUI rows' resolution, routes, search and ranking,
// the summon payload, the select options, what the file search helper
// prints, and whether a hover point is a pointer motion.
//
// A menu file is `{ "schemaVersion": 1, "items": { "<id>": { ... } } }`. An
// id is dotted, and its dots name its parent unless `parent` says
// otherwise. Keys a file may set on an item are ITEM_KEYS; the shipped file
// and the user's file merge per key, the user's winning, so the user can
// change one label without restating the row. The kind is inferred after
// the merge: `unavailable` for an integration this shell does not offer,
// `tui` for a floating TUI, `run` for an action, `target` for a link to
// another menu, and a menu otherwise.
//
// A `tui` row names a TUI shell.tui.entries lists: by key with `tui`, or
// with `tuiGroup` as the first listed entry of that group, so a row can
// open another plugin's TUI without naming the plugin. resolveTuiRows
// resolves it against the list; one that resolves to nothing is hidden.

var SCHEMA_VERSION = 1;
var FILE_KEYS = ["schemaVersion", "items"];
var ITEM_KEYS = ["label", "icon", "title", "description", "aliases", "parent", "target", "run", "provider", "requires", "unavailable", "tui", "tuiGroup"];
// The keys that each give a row its kind; a merged row states one at most.
var KIND_KEYS = ["run", "target", "provider", "unavailable", "tui", "tuiGroup"];
// Menus whose rows the launcher lists itself: installed applications, and
// the theme packages the theme capability reports.
var PROVIDERS = ["apps", "themes"];
var ID_PATTERN = /^[a-z0-9][a-z0-9-]*(\.[a-z0-9][a-z0-9-]*)*$/;
var COMMAND_PATTERN = /^[A-Za-z0-9._+-]+$/;
// The shape of a key shell.tui.entries lists, `core/<name>` or
// `<plugin id>/<name>`; whether a key is listed is the list's to answer.
var TUI_KEY_PATTERN = /^[a-z0-9][a-z0-9-]*(\.[a-z0-9][a-z0-9-]*)*\/[a-z0-9][a-z0-9-]*$/;
var CONTROL_PATTERN = /[\u0000-\u001f\u007f]/;
// Every walk up the tree stops here, so a parent cycle a file states ends.
var DEPTH_LIMIT = 32;

function hasOwn(obj, key) {
    return obj !== null && typeof obj === "object" && Object.prototype.hasOwnProperty.call(obj, key);
}

function isPlainObject(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value);
}

function isStringList(value, pattern) {
    if (!Array.isArray(value)) return false;
    for (var i = 0; i < value.length; i++)
        if (typeof value[i] !== "string" || value[i].length === 0 || (pattern && !pattern.test(value[i]))) return false;
    return true;
}

// The first defect of one item's raw keys, or "".
function itemError(id, raw) {
    var at = "items." + id;
    if (!ID_PATTERN.test(id)) return at + " is not a dotted lower-case id";
    if (!isPlainObject(raw)) return at + " must be an object";
    var keys = Object.keys(raw);
    for (var i = 0; i < keys.length; i++)
        if (ITEM_KEYS.indexOf(keys[i]) === -1) return at + " has unknown key " + JSON.stringify(keys[i]);
    var strings = ["label", "icon", "title", "description", "parent", "target", "unavailable", "tui", "tuiGroup"];
    for (var s = 0; s < strings.length; s++)
        if (hasOwn(raw, strings[s]) && typeof raw[strings[s]] !== "string") return at + "." + strings[s] + " must be a string";
    if (hasOwn(raw, "label") && raw.label.length === 0) return at + ".label must not be empty";
    if (hasOwn(raw, "unavailable") && raw.unavailable.length === 0) return at + ".unavailable must name why";
    if (hasOwn(raw, "aliases") && !isStringList(raw.aliases)) return at + ".aliases must be a list of non-empty strings";
    if (hasOwn(raw, "run") && !(isStringList(raw.run) && raw.run.length > 0)) return at + ".run must be a non-empty list of non-empty strings";
    if (hasOwn(raw, "requires") && !isStringList(raw.requires, COMMAND_PATTERN)) return at + ".requires must be a list of command names";
    if (hasOwn(raw, "provider") && PROVIDERS.indexOf(raw.provider) === -1) return at + ".provider must be one of " + PROVIDERS.join(", ");
    if (hasOwn(raw, "parent") && raw.parent !== "" && !ID_PATTERN.test(raw.parent)) return at + ".parent is not an id";
    if (hasOwn(raw, "target") && !ID_PATTERN.test(raw.target)) return at + ".target is not an id";
    if (hasOwn(raw, "tui") && !TUI_KEY_PATTERN.test(raw.tui)) return at + ".tui is not a TUI key, core/<name> or <plugin id>/<name>";
    if (hasOwn(raw, "tuiGroup") && (raw.tuiGroup.trim().length === 0 || CONTROL_PATTERN.test(raw.tuiGroup))) return at + ".tuiGroup must be one printable line";
    return "";
}

// Parse one menu file's text. Answers { ok: true, entries } with each entry
// `{ id, raw }` in file order, or { ok: false, error } naming the first
// defect; nothing of a refused file is part of the answer.
function parseMenu(text) {
    var document;
    try {
        document = JSON.parse(text);
    } catch (e) {
        return { ok: false, error: "not-json: " + e.message };
    }
    if (!isPlainObject(document)) return { ok: false, error: "not-object" };
    var keys = Object.keys(document);
    for (var i = 0; i < keys.length; i++)
        if (FILE_KEYS.indexOf(keys[i]) === -1) return { ok: false, error: "unknown key " + JSON.stringify(keys[i]) };
    if (document.schemaVersion !== SCHEMA_VERSION) return { ok: false, error: "schemaVersion must be " + SCHEMA_VERSION + ", got " + JSON.stringify(document.schemaVersion) };
    if (!isPlainObject(document.items)) return { ok: false, error: "items must be an object" };
    var entries = [];
    var ids = Object.keys(document.items);
    for (var j = 0; j < ids.length; j++) {
        var defect = itemError(ids[j], document.items[ids[j]]);
        if (defect !== "") return { ok: false, error: defect };
        entries.push({ id: ids[j], raw: document.items[ids[j]] });
    }
    return { ok: true, entries: entries };
}

// One merged item in the shape every other function reads.
function normalizeItem(id, raw, order) {
    var parent = hasOwn(raw, "parent") ? raw.parent : (id.indexOf(".") >= 0 ? id.split(".").slice(0, -1).join(".") : "root");
    var kind = hasOwn(raw, "unavailable") ? "unavailable" : (hasOwn(raw, "tui") || hasOwn(raw, "tuiGroup") ? "tui" : (hasOwn(raw, "run") ? "action" : (hasOwn(raw, "target") ? "link" : "menu")));
    return {
        id: id,
        parent: id === "root" ? "" : parent,
        kind: kind,
        icon: raw.icon || "",
        label: raw.label || id,
        title: raw.title || "",
        target: raw.target || "",
        description: raw.description || "",
        run: raw.run ? raw.run.slice() : [],
        provider: raw.provider || "",
        aliases: raw.aliases ? raw.aliases.slice() : [],
        requires: raw.requires ? raw.requires.slice() : [],
        reason: raw.unavailable || "",
        tui: raw.tui || "",
        tuiGroup: raw.tuiGroup || "",
        // The listed key a `tui` row opens, "" until resolveTuiRows finds one.
        tuiKey: "",
        order: order
    };
}

// The shipped entries under the user's, merged per key by id, the user's
// winning, as { ok, items, itemOrder }. A merged row that states two of
// KIND_KEYS is refused, naming it.
function mergeMenuSources(shipped, user) {
    var merged = {};
    var order = [];
    var sources = [shipped || [], user || []];
    for (var s = 0; s < sources.length; s++) {
        for (var i = 0; i < sources[s].length; i++) {
            var entry = sources[s][i];
            if (!hasOwn(merged, entry.id)) {
                merged[entry.id] = {};
                order.push(entry.id);
            }
            for (var key in entry.raw)
                merged[entry.id][key] = entry.raw[key];
        }
    }
    if (!hasOwn(merged, "root")) {
        merged.root = { label: "Search" };
        order.unshift("root");
    }
    var items = {};
    for (var k = 0; k < order.length; k++) {
        var raw = merged[order[k]];
        var stated = KIND_KEYS.filter(function (name) { return hasOwn(raw, name); });
        if (stated.length > 1) return { ok: false, error: "items." + order[k] + " states " + stated.join(" and ") };
        items[order[k]] = normalizeItem(order[k], raw, k);
    }
    return { ok: true, items: items, itemOrder: order };
}

// The key a `tui` row opens from ENTRIES, shell.tui.entries' rows
// `{ key, group, ... }` in the core's order: its own `tui` key when listed,
// else the first listed entry of its `tuiGroup`; "" when none is.
function tuiKeyFor(entry, entries) {
    for (var i = 0; i < entries.length; i++) {
        if (entry.tui !== "" ? entries[i].key === entry.tui : entries[i].group === entry.tuiGroup) return entries[i].key;
    }
    return "";
}

// ITEMS with every `tui` row's tuiKey resolved against ENTRIES, as a fresh
// map; every other item is handed on as it is. The launcher resolves again
// whenever the list changes, as a plugin is enabled or disabled.
function resolveTuiRows(items, itemOrder, entries) {
    var next = {};
    for (var i = 0; i < itemOrder.length; i++) {
        var entry = items[itemOrder[i]];
        next[itemOrder[i]] = entry.kind === "tui" ? Object.assign({}, entry, { tuiKey: tuiKeyFor(entry, entries) }) : entry;
    }
    return next;
}

// Swap the rows one provider contributed under `menuId` for `rows`, leaving
// every other item as it was. Answers fresh maps; the ones handed in are
// never written, since they live in QML properties that must be replaced
// whole. A row whose id is taken is listed once.
function swapProviderRows(items, itemOrder, menuId, rows) {
    var nextItems = {};
    var nextOrder = [];
    for (var i = 0; i < itemOrder.length; i++) {
        var existing = items[itemOrder[i]];
        if (existing === undefined || existing.providerMenu === menuId) continue;
        nextItems[itemOrder[i]] = existing;
        nextOrder.push(itemOrder[i]);
    }
    for (var j = 0; j < rows.length; j++) {
        if (hasOwn(nextItems, rows[j].id)) continue;
        var row = Object.assign({}, rows[j], { providerMenu: menuId, order: nextOrder.length });
        nextItems[row.id] = row;
        nextOrder.push(row.id);
    }
    return { items: nextItems, itemOrder: nextOrder };
}

// One application row under `menuId`, from a desktop entry's fields. Its
// generic name and keywords are search aliases; app rows are never routes.
function appRow(menuId, entry) {
    var aliases = [];
    if (entry.genericName) aliases.push(entry.genericName);
    if (Array.isArray(entry.keywords)) aliases = aliases.concat(entry.keywords.filter(function (k) { return typeof k === "string" && k.length > 0; }));
    return {
        id: menuId + "." + slugify(entry.id),
        parent: menuId,
        kind: "app",
        icon: "",
        appIcon: entry.icon || "",
        appId: entry.id,
        label: entry.name || entry.id,
        title: "",
        target: "",
        description: entry.genericName || entry.comment || "",
        run: [],
        provider: "",
        aliases: aliases,
        requires: [],
        reason: "",
        tui: "",
        tuiGroup: "",
        tuiKey: "",
        order: 0
    };
}

// One theme package row under `menuId`, from `vgsh theme list --json`'s
// package fields. A refused package shows, and says why, instead of
// vanishing from the list.
function themeRow(menuId, pkg) {
    var refused = pkg.state !== "ok";
    return {
        id: menuId + "." + slugify(pkg.name),
        parent: menuId,
        kind: refused ? "unavailable" : "theme",
        icon: pkg.current === true ? "check" : "palette",
        label: pkg.name,
        title: "",
        target: "",
        description: refused ? "refused: " + (pkg.reason || "unknown") : pkg.source || "",
        run: [],
        provider: "",
        aliases: [],
        requires: [],
        reason: refused ? "The theme judge refused this package: " + (pkg.reason || "unknown") : "",
        tui: "",
        tuiGroup: "",
        tuiKey: "",
        theme: pkg.name,
        order: 0
    };
}

function slugify(value) {
    return String(value).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "") || "item";
}

// A route names an id or an alias a menu file declares. An exact id wins
// over any alias, and app rows are never routes: their aliases carry the
// desktop entry's keywords, so an installed application could otherwise
// shadow a menu. An unknown route is answered as given, and the caller
// opens the root in its place.
function resolveRoute(items, itemOrder, input) {
    var raw = String(input || "").toLowerCase().replace(/_/g, "-");
    if (!raw || raw === "go" || raw === "menu") return "root";
    if (hasOwn(items, raw)) return raw;
    for (var i = 0; i < itemOrder.length; i++) {
        var entry = items[itemOrder[i]];
        if (entry.kind === "app") continue;
        for (var j = 0; j < entry.aliases.length; j++)
            if (entry.aliases[j].toLowerCase().replace(/_/g, "-") === raw) return entry.id;
    }
    return raw;
}

function depthFor(items, id) {
    var depth = 0;
    var current = items[id];
    while (current && current.parent && current.parent !== "root" && depth < DEPTH_LIMIT) {
        depth += 1;
        current = items[current.parent];
    }
    return depth;
}

function pathFor(items, id) {
    var labels = [];
    var current = items[id];
    while (current && current.id !== "root" && labels.length < DEPTH_LIMIT) {
        labels.unshift(current.label);
        current = items[current.parent];
    }
    return labels.join(" \u203a ");
}

function parentPathFor(items, id) {
    var entry = items[id];
    if (!entry || !entry.parent || entry.parent === "root") return "";
    return pathFor(items, entry.parent);
}

function isDescendantOf(items, id, ancestorId) {
    if (ancestorId === "root") return id !== "root";
    var current = items[id];
    for (var guard = 0; current && current.parent && guard < DEPTH_LIMIT; guard++) {
        if (current.parent === ancestorId) return true;
        current = items[current.parent];
    }
    return false;
}

function childCount(items, itemOrder, id) {
    var count = 0;
    for (var i = 0; i < itemOrder.length; i++)
        if (items[itemOrder[i]].parent === id) count += 1;
    return count;
}

// A static menu shows while any row under it shows; a provider's menu
// always shows, since its rows load when it opens. A `tui` row shows while
// it resolves to a listed TUI, as a disabled plugin's TUIs leave the list.
// Every other row shows: an unavailable one says why rather than vanishing.
function isVisible(items, itemOrder, entry, depth) {
    if (entry.kind === "tui") return entry.tuiKey !== "";
    if (entry.kind !== "menu" && entry.kind !== "link") return true;
    if (entry.provider) return true;
    var guard = depth || 0;
    if (guard >= DEPTH_LIMIT) return false;
    var target = entry.kind === "link" ? entry.target : entry.id;
    for (var i = 0; i < itemOrder.length; i++) {
        var child = items[itemOrder[i]];
        if (child.parent === target && isVisible(items, itemOrder, child, guard + 1)) return true;
    }
    return false;
}

// The commands a row needs that `missing` lists, joined, or "".
function missingFor(entry, missing) {
    return entry.requires.filter(function (command) { return missing.indexOf(command) !== -1; }).join(", ");
}

function searchableToken(value) {
    return String(value || "").replace(/[._-]+/g, " ");
}

function nameSearchText(entry) {
    var leaf = entry.id.split(".").pop();
    var aliases = entry.aliases.map(searchableToken).join(" ");
    return [entry.label, searchableToken(leaf), aliases].join(" ").toLowerCase();
}

function termInSearchWords(term, text) {
    return String(text || "").toLowerCase().split(/\s+/).indexOf(term) !== -1;
}

function descriptionTextMatches(query, text) {
    var terms = String(query || "").toLowerCase().trim().split(/\s+/);
    for (var i = 0; i < terms.length; i++)
        if (terms[i] && !termInSearchWords(terms[i], text)) return false;
    return true;
}

// Every term of the query appears in the row's name, id leaf or aliases,
// or as a whole word of its description.
function matchesQuery(entry, query) {
    if (entry.id === "root") return false;
    var nameText = nameSearchText(entry);
    var descriptionText = entry.description.toLowerCase();
    var terms = String(query || "").toLowerCase().trim().split(/\s+/);
    for (var i = 0; i < terms.length; i++) {
        if (!terms[i]) continue;
        if (nameText.indexOf(terms[i]) >= 0) continue;
        if (termInSearchWords(terms[i], descriptionText)) continue;
        return false;
    }
    return true;
}

// Lower is better: the match tier, then depth, then file order.
function searchScore(items, entry, query) {
    var needle = String(query || "").toLowerCase().trim();
    var label = entry.label.toLowerCase();
    var score = 80;
    if (label === needle) score = entry.parent === "root" ? 2 : 0;
    // An installed app whose name holds the query as a whole word ("zen"
    // for Zen Browser) beats an exact menu label.
    else if (entry.kind === "app" && label.split(/\s+/).indexOf(needle) >= 0) score = 0;
    else if (label.indexOf(needle) === 0) score = 10;
    else if (label.indexOf(needle) >= 0) score = 30;
    else if (nameSearchText(entry).indexOf(needle) >= 0) score = 40;
    else if (descriptionTextMatches(needle, entry.description.toLowerCase())) score = 60;
    if (entry.kind === "menu" || entry.kind === "link") score -= 2;
    // App rows come last in file order, so they would lose every tie;
    // they outrank an equal match inside their tier instead.
    if (entry.kind === "app") score -= 5;
    return score * 1000 + depthFor(items, entry.id) * 25 + entry.order;
}

// The rows for a query under `active`: matches directly under it first,
// then deeper ones, each sorted by score then path. Deeper rows carry the
// `drilldown` section when both groups have rows.
function searchRows(items, itemOrder, active, query, missing) {
    var current = [];
    var deeper = [];
    for (var i = 0; i < itemOrder.length; i++) {
        var entry = items[itemOrder[i]];
        if (entry.id === "root" || !isDescendantOf(items, entry.id, active)) continue;
        if (!isVisible(items, itemOrder, entry) || !matchesQuery(entry, query)) continue;
        var row = displayRow(items, itemOrder, entry, parentPathFor(items, entry.id), searchScore(items, entry, query), "", missing);
        (entry.parent === active ? current : deeper).push(row);
    }
    var bySearch = function (a, b) { return a.score !== b.score ? a.score - b.score : a.path.localeCompare(b.path); };
    current.sort(bySearch);
    deeper.sort(bySearch);
    if (current.length > 0 && deeper.length > 0)
        for (var d = 0; d < deeper.length; d++) deeper[d].section = "drilldown";
    return current.concat(deeper);
}

// The rows directly under `active`, in file order; an apps menu sorts by
// label, since the desktop entry model reorders as applications start.
function menuRows(items, itemOrder, active, missing) {
    var rows = [];
    for (var i = 0; i < itemOrder.length; i++) {
        var child = items[itemOrder[i]];
        if (child.parent !== active || !isVisible(items, itemOrder, child)) continue;
        rows.push(displayRow(items, itemOrder, child, child.description, child.order, "", missing));
    }
    if (items[active] && items[active].provider === "apps")
        rows.sort(function (a, b) {
            var x = a.label.toLowerCase(), y = b.label.toLowerCase();
            return x < y ? -1 : x > y ? 1 : (a.itemId < b.itemId ? -1 : a.itemId > b.itemId ? 1 : 0);
        });
    return rows;
}

// One row as the list model holds it: primitives only. A row whose
// required commands are missing is unavailable, and says which.
function displayRow(items, itemOrder, entry, detail, score, section, missing) {
    var target = entry.kind === "link" ? entry.target : entry.id;
    var lacking = missingFor(entry, missing || []);
    return {
        itemId: entry.id,
        kind: lacking !== "" ? "unavailable" : entry.kind,
        icon: entry.icon,
        appIcon: entry.appIcon || "",
        label: entry.label,
        target: target,
        detail: lacking !== "" ? "needs " + lacking : (entry.kind === "unavailable" && !detail ? entry.reason : detail || ""),
        path: pathFor(items, entry.id),
        childCount: entry.kind === "menu" || entry.kind === "link" ? childCount(items, itemOrder, target) : 0,
        score: score || 0,
        section: section || ""
    };
}

// Whether a theme apply's structured result, as `vgsh theme apply --json`
// answers it, is a success: `applied`, or `unchanged` for the package
// already applied. `partial` and `failed`, and anything else, are not.
function applySucceeded(result) {
    return isPlainObject(result) && (result.state === "applied" || result.state === "unchanged");
}

// --- the summon payload

var PAYLOAD_KEYS = ["menu", "query", "mode", "prompt", "options", "selectionFile", "doneFile", "width", "maxHeight"];
var MODES = ["menu", "select", "input"];
// A select list the card holds at once; a longer list is the caller's
// defect, refused before any row is built.
var OPTIONS_MAX = 2000;

// Judge one summon payload. `runtimeDir` is the session's runtime
// directory: a select or input request writes its answer only to files
// inside it. Answers { ok: true, payload } with every key present, or
// { ok: false, error }.
function parsePayload(text, runtimeDir) {
    var raw;
    try {
        raw = text === "" || text === undefined ? {} : JSON.parse(text);
    } catch (e) {
        return { ok: false, error: "payload=not-json " + e.message };
    }
    if (!isPlainObject(raw)) return { ok: false, error: "payload=not-object" };
    var keys = Object.keys(raw);
    for (var i = 0; i < keys.length; i++)
        if (PAYLOAD_KEYS.indexOf(keys[i]) === -1) return { ok: false, error: "payload=unknown-key key=" + keys[i] };
    var mode = hasOwn(raw, "mode") ? raw.mode : "menu";
    if (MODES.indexOf(mode) === -1) return { ok: false, error: "payload=mode got=" + JSON.stringify(raw.mode) };
    var strings = ["menu", "query", "prompt", "selectionFile", "doneFile"];
    for (var s = 0; s < strings.length; s++)
        if (hasOwn(raw, strings[s]) && typeof raw[strings[s]] !== "string") return { ok: false, error: "payload=" + strings[s] + " want=string" };
    var numbers = ["width", "maxHeight"];
    for (var n = 0; n < numbers.length; n++)
        if (hasOwn(raw, numbers[n]) && !(typeof raw[numbers[n]] === "number" && isFinite(raw[numbers[n]]) && raw[numbers[n]] > 0 && raw[numbers[n]] <= 4096))
            return { ok: false, error: "payload=" + numbers[n] + " want=1..4096" };
    var request = mode === "select" || mode === "input";
    if (request) {
        if (hasOwn(raw, "menu") || hasOwn(raw, "query")) return { ok: false, error: "payload=" + mode + " takes no menu or query" };
        var files = ["selectionFile", "doneFile"];
        for (var f = 0; f < files.length; f++) {
            var file = raw[files[f]];
            if (typeof file !== "string") return { ok: false, error: "payload=" + files[f] + " missing" };
            if (!insideDirectory(file, runtimeDir)) return { ok: false, error: "payload=" + files[f] + " outside=" + runtimeDir };
        }
        if (raw.selectionFile === raw.doneFile) return { ok: false, error: "payload=doneFile same-as=selectionFile" };
    } else {
        var only = ["prompt", "options", "selectionFile", "doneFile", "width", "maxHeight"];
        for (var o = 0; o < only.length; o++)
            if (hasOwn(raw, only[o])) return { ok: false, error: "payload=" + only[o] + " needs mode=select|input" };
    }
    var options = hasOwn(raw, "options") ? raw.options : [];
    if (mode === "input" && hasOwn(raw, "options")) return { ok: false, error: "payload=options needs mode=select" };
    if (!Array.isArray(options) || options.some(function (x) { return typeof x !== "string"; })) return { ok: false, error: "payload=options want=list-of-strings" };
    if (options.length > OPTIONS_MAX) return { ok: false, error: "payload=options count=" + options.length + " max=" + OPTIONS_MAX };
    return {
        ok: true,
        payload: {
            mode: mode,
            menu: raw.menu || "root",
            query: raw.query || "",
            prompt: raw.prompt || (mode === "input" ? "Input" : "Select"),
            options: options.slice(),
            selectionFile: raw.selectionFile || "",
            doneFile: raw.doneFile || "",
            width: raw.width || 300,
            maxHeight: raw.maxHeight || 0
        }
    };
}

// An absolute path strictly inside `dir`, with no `.` or `..` component and
// no control character.
function insideDirectory(file, dir) {
    if (typeof dir !== "string" || dir.charAt(0) !== "/" || file.indexOf(dir.replace(/\/+$/, "") + "/") !== 0) return false;
    if (/[\u0000-\u001f]/.test(file)) return false;
    var parts = file.split("/").slice(1);
    for (var i = 0; i < parts.length; i++)
        if (parts[i] === "" || parts[i] === "." || parts[i] === "..") return false;
    return true;
}

// One select option: `<label>`, `<glyph>\t<label>` or
// `<glyph>\t<label>\t<detail>`. The glyph never returns with a selection;
// the detail filters with the label and returns beside it, so same-named
// rows stay apart.
function parseOption(text) {
    var parts = String(text).split("\t");
    var icon = parts.length > 1 ? parts.shift() : "";
    var label = parts.shift() || "";
    return { icon: icon, label: label, detail: parts.join("\t") };
}

// The select rows matching `query`, in the caller's order.
function optionRows(options, query) {
    var needle = String(query || "").trim().toLowerCase();
    var rows = [];
    for (var i = 0; i < options.length; i++) {
        var option = parseOption(options[i]);
        if (needle && option.label.toLowerCase().indexOf(needle) < 0 && option.detail.toLowerCase().indexOf(needle) < 0) continue;
        rows.push({ itemId: "option." + i, kind: "option", icon: option.icon, appIcon: "", label: option.label, target: "", detail: option.detail, path: "", childCount: 0, score: i, section: "" });
    }
    return rows;
}

// The search text without its last word and the spaces after it, as
// Ctrl+Backspace edits it.
function dropWord(text) {
    return String(text).replace(/\S*\s*$/, "");
}

// What a select returns for a picked row: its label, and its detail after a
// tab when it has one.
function selectionOf(row) {
    return row.detail ? row.label + "\t" + row.detail : row.label;
}

// --- file search

// The file search's prefixes: `f:` searches files and `F:` folders. Answers
// { mode, query } with mode "f", "d" or "" for no file search.
function fileMode(filter) {
    var text = String(filter || "");
    if (text.indexOf("f:") === 0) return { mode: "f", query: text.substring(2).trim() };
    if (text.indexOf("F:") === 0) return { mode: "d", query: text.substring(2).trim() };
    return { mode: "", query: "" };
}

// `~` for the home directory and a path under it.
function prettyDir(dir, home) {
    if (dir === home) return "~";
    return home && dir.indexOf(home + "/") === 0 ? "~" + dir.substring(home.length) : dir;
}

// The helper's query lines, `<mtime>\t<mime>\t<path>`, best match first, as
// rows. The helper's rank stands, but hits with one name sit together,
// newest first. A line of another shape is the helper's defect and is
// counted in `malformed`, never shown.
function parseFileResults(raw, home) {
    var groups = Object.create(null);
    var order = [];
    var malformed = 0;
    var lines = String(raw || "").split("\n");
    for (var i = 0; i < lines.length; i++) {
        if (lines[i] === "") continue;
        var parts = lines[i].split("\t");
        var mtime = Number(parts[0]);
        var path = parts.slice(2).join("\t");
        if (parts.length < 3 || !/^[0-9]+$/.test(parts[0]) || path.charAt(0) !== "/") {
            malformed += 1;
            continue;
        }
        var slash = path.lastIndexOf("/");
        var row = { path: path, name: path.substring(slash + 1), dir: prettyDir(path.substring(0, slash) || "/", home), mime: parts[1], mtime: mtime };
        if (groups[row.name] === undefined) {
            groups[row.name] = [];
            order.push(row.name);
        }
        groups[row.name].push(row);
    }
    var rows = [];
    for (var g = 0; g < order.length; g++)
        rows = rows.concat(groups[order[g]].sort(function (a, b) { return b.mtime - a.mtime; }));
    return { rows: rows, malformed: malformed };
}

// The helper's `apps` lines, `default|other\t<desktop file>`, default first.
function parseOpenWith(raw) {
    var apps = [];
    var lines = String(raw || "").split("\n");
    for (var i = 0; i < lines.length; i++) {
        var parts = lines[i].split("\t");
        if (parts.length !== 2 || (parts[0] !== "default" && parts[0] !== "other") || parts[1].charAt(0) !== "/") continue;
        var id = parts[1].substring(parts[1].lastIndexOf("/") + 1).replace(/\.desktop$/, "");
        apps.push({ desktopFile: parts[1], id: id, isDefault: parts[0] === "default" });
    }
    return apps.sort(function (a, b) { return (b.isDefault ? 1 : 0) - (a.isDefault ? 1 : 0); });
}
