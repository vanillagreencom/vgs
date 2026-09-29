.pragma library

// The theme browser's decisions, with no QML object and no I/O, so
// scripts/test-themes-browser.js runs every function under node: the
// overlay's views and their payload, the cards merged from the theme list,
// the catalog and the image list, the typed filter, the selection kept
// across a filter or a refresh, the wallpaper download offer, and the text
// the browser shows for a download's progress and a failed step.

// The overlay's views, one row each: the payload's `view` and the global
// shortcut, `vgs.themes:<name>`, that Service.qml registers to open or close
// it, with the shortcut's description, and `source`, the file beside
// Browser.qml that draws it. The first view is the one a payload without
// `view` opens. A view is one row here and its file.
var VIEWS = [
    { name: "themes", description: "Open or close the theme browser", source: "ThemeView.qml" }
];
var PAYLOAD_KEYS = ["view"];

// The two choices of the scope control, in its order.
var SCOPES = [
    { scope: "all", label: "All" },
    { scope: "installed", label: "Installed" }
];

// How often the browser reads `last.downloading` while a download it
// started runs: the capability's `last` is a getter no binding follows.
var PROGRESS_POLL_MS = 250;

// A wallpaper size is shown in decimal megabytes, as a release page shows
// its assets.
var MEGABYTE = 1000000;

// The apply result states in which the package is the applied one:
// docs/architecture/theme-apply.md § Result.
var APPLIED_STATES = ["applied", "unchanged", "partial"];

function hasOwn(obj, key) {
    return obj !== null && typeof obj === "object" && Object.prototype.hasOwnProperty.call(obj, key);
}

function viewNames() {
    return VIEWS.map(function (v) { return v.name; });
}

// The file that draws view NAME, one of VIEWS.
function viewSource(name) {
    for (var i = 0; i < VIEWS.length; i++)
        if (VIEWS[i].name === name) return VIEWS[i].source;
    throw new Error("view=" + JSON.stringify(name) + " unknown");
}

// The view a summon's payload TEXT names. A payload is a JSON object whose
// only key is `view`, one of VIEWS; `{}` names the first. Anything else
// throws, so the host refuses the summon with `open-failed`.
function parsePayload(text) {
    var raw;
    try {
        raw = JSON.parse(text === undefined || text === null || text === "" ? "{}" : text);
    } catch (e) {
        throw new Error("payload=not-json");
    }
    if (raw === null || typeof raw !== "object" || Array.isArray(raw)) throw new Error("payload=not-object");
    var keys = Object.keys(raw);
    for (var i = 0; i < keys.length; i++)
        if (PAYLOAD_KEYS.indexOf(keys[i]) === -1) throw new Error("payload=unknown-key key=" + keys[i]);
    if (!hasOwn(raw, "view")) return { view: VIEWS[0].name };
    if (viewNames().indexOf(raw.view) === -1) throw new Error("payload=view got=" + JSON.stringify(raw.view));
    return { view: raw.view };
}

// A package name as the browser titles it: dashes and underscores become
// spaces and each word starts in upper case.
function label(name) {
    return String(name).replace(/[-_]+/g, " ").replace(/\b\w/g, function (c) { return c.toUpperCase(); });
}

// One card per theme, in name order, from the last list's PACKAGES, the
// catalog's ENTRIES (null when the catalog failed) and the image list's
// IMAGES (null when it failed); CURRENT is the displayed package's name.
// A listed package is the card for its name, since it is what an apply
// applies: a shadowed row is skipped, a catalog install carries its
// entry's wallpaper pin and thumbnail, and a catalog entry of a listed name
// adds no card. Every other catalog entry is a card that is not installed.
// A card's image is its package's first image, else the entry's thumbnail,
// else null for a card drawn from its palette.
//
// A card is { name, label, source, state, reason, installed, palette,
// image, imagery, displayed }: `source` the list's (`shipped`,
// `installed`) or `catalog`; `state` `ok` or `refused`; `palette` the
// `#rrggbbaa` palette group or null; `imagery` null, or the wallpaper
// archive's { size, installed }.
function cards(packages, entries, images, current) {
    var catalog = {};
    var first = {};
    var listed = {};
    var out = [];
    var i;
    for (i = 0; entries !== null && i < entries.length; i++) catalog[entries[i].name] = entries[i];
    for (i = 0; images !== null && i < images.length; i++) {
        var image = images[i];
        if (image.theme !== null && !hasOwn(first, image.theme)) first[image.theme] = image.path;
    }
    for (i = 0; i < packages.length; i++) {
        var p = packages[i];
        if (p.state === "shadowed") continue;
        listed[p.name] = true;
        var entry = hasOwn(catalog, p.name) && catalog[p.name].installed ? catalog[p.name] : null;
        out.push({
            name: p.name,
            label: label(p.name),
            source: p.source,
            state: p.state,
            reason: p.reason,
            installed: true,
            palette: p.palette,
            image: hasOwn(first, p.name) ? first[p.name] : entry !== null ? entry.thumbnailPath : null,
            imagery: entry === null || entry.imagery === null ? null : { size: entry.imagery.size, installed: entry.imageryInstalled },
            displayed: p.state === "ok" && p.name === current
        });
    }
    for (i = 0; entries !== null && i < entries.length; i++) {
        var e = entries[i];
        if (hasOwn(listed, e.name)) continue;
        out.push({
            name: e.name,
            label: label(e.name),
            source: "catalog",
            state: "ok",
            reason: null,
            installed: false,
            palette: e.palette,
            image: e.thumbnailPath,
            imagery: e.imagery === null ? null : { size: e.imagery.size, installed: false },
            displayed: false
        });
    }
    out.sort(function (a, b) { return a.name < b.name ? -1 : a.name > b.name ? 1 : 0; });
    return out;
}

// Whether CARD matches the typed filter TEXT: its name or its label holds
// the text, in any case. An empty filter matches every card.
function matches(card, text) {
    var needle = String(text).toLowerCase();
    return needle === "" || card.name.toLowerCase().indexOf(needle) !== -1 || card.label.toLowerCase().indexOf(needle) !== -1;
}

// The cards the rail shows: those in SCOPE, `all` or `installed`, that
// match the filter TEXT.
function shown(list, text, scope) {
    if (scope !== "all" && scope !== "installed") throw new Error("scope=" + JSON.stringify(scope) + " want=all|installed");
    return list.filter(function (card) { return (scope === "all" || card.installed) && matches(card, text); });
}

// The identity of CARD on the rail: everything its content draws. The
// carousel hands a card's content its entry once, so a card whose label,
// image or palette changed is rebuilt under a new key, and one whose drawn
// inputs stayed is kept.
function cardKey(card) {
    return JSON.stringify([card.name, card.label, card.image, card.palette]);
}

// The index to select in LIST: the card named NAME, else the first.
function selection(list, name) {
    for (var i = 0; i < list.length; i++)
        if (list[i].name === name) return i;
    return 0;
}

// Whether a typed TEXT is one printable character the filter takes.
function typable(text) {
    if (typeof text !== "string" || text.length !== 1) return false;
    var code = text.charCodeAt(0);
    return code >= 32 && code !== 127;
}

// The filter TEXT after EDIT: { kind: "type", text } appends a typable
// character, `erase` removes the last character, `eraseWord` the last word
// and the spaces after it, `clear` everything.
function editFilter(text, edit) {
    switch (edit.kind) {
    case "type":
        if (!typable(edit.text)) throw new Error("filter-edit=type text=" + JSON.stringify(edit.text));
        return text + edit.text;
    case "erase":
        return text.slice(0, -1);
    case "eraseWord":
        return text.replace(/\s+$/, "").replace(/\S+$/, "");
    case "clear":
        return "";
    default:
        throw new Error("filter-edit=" + JSON.stringify(edit.kind));
    }
}

// Whether the browser offers to download CARD's wallpapers: the package is
// installed and displayed, and its catalog pin names an archive with bytes
// that is not unpacked.
function downloadOffer(card) {
    return card !== null && card.installed && card.displayed && card.imagery !== null && !card.imagery.installed && card.imagery.size > 0;
}

function sizeText(bytes) {
    return Math.max(1, Math.round(bytes / MEGABYTE)) + " MB";
}

// The line a running download shows, from `last.downloading`: its step
// and, while it downloads, the bytes so far of the total. A step the
// runner adds is shown by its own name.
function progressText(downloading) {
    if (downloading === null) return "";
    switch (downloading.state) {
    case null:
        return "Starting the download";
    case "downloading":
        return "Downloading " + (downloading.total === null ? sizeText(downloading.bytes) : Math.round(downloading.bytes / MEGABYTE) + " of " + sizeText(downloading.total));
    case "verifying":
        return "Verifying the archive";
    case "unpacking":
        return "Unpacking the wallpapers";
    default:
        return String(downloading.state);
    }
}

// The share of the step done, for a determinate bar, or null while the
// runner names no total.
function progressValue(downloading) {
    if (downloading === null || downloading.total === null || downloading.total <= 0) return null;
    return Math.min(1, downloading.bytes / downloading.total);
}

// Whether an apply RESULT left its package applied, every target or not.
function applied(result) {
    return APPLIED_STATES.indexOf(result.state) !== -1;
}

// The line the browser shows after STEP, `install`, `apply` or `download`,
// of package NAME answered RESULT: "" for a step that did what it was
// asked, else what failed and why. A partial apply names the Themes
// panel, whose row for the package lists each application that did not
// take the theme.
function problem(step, name, result) {
    switch (step) {
    case "install":
        return result.state === "ok" ? "" : "Installing " + label(name) + " failed: " + result.reason;
    case "apply":
        if (result.state === "partial") return label(name) + " is applied, but some applications did not take it: the Themes panel lists them";
        return applied(result) ? "" : "Applying " + label(name) + " failed: " + result.reason;
    case "download":
        return result.state === "ok" ? "" : "Downloading the wallpapers for " + label(name) + " failed: " + result.reason;
    default:
        throw new Error("step=" + JSON.stringify(step));
    }
}
