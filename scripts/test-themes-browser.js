#!/usr/bin/env node
// The browsers' decisions, shell/plugins/vgs.themes/BrowserLogic.js, and
// the plugin's file URLs, Files.js, under node: the payload and its views;
// the theme view's cards merged from the list, the catalog and the images,
// the filter, the selection and the download offer; the wallpaper view's
// sources, scopes, cards, download or update card, keys and selection; and
// the lines the browsers show. Every expected value is written out by
// hand, Qt's key codes from qnamespace.h.
//
// The controls at the end edit a copy of the logic, one rule at a time,
// and require this suite to fail on each copy.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { load } = require("../bin/lib/qml-library.js");

const dir = path.join(__dirname, "..", "shell", "plugins", "vgs.themes");
const file = path.join(dir, "BrowserLogic.js");
// The logic runs in its own context, whose arrays and objects are not this
// one's; values are compared as JSON.
const same = (got, want, message) => assert.deepEqual(JSON.parse(JSON.stringify(got)), want, message === undefined ? JSON.stringify(want) : message);

const PALETTE = { background: "#101010ff", foreground: "#eeeeeeff", accent: "#3366ffff" };
const pkg = (name, source, state) => ({ name, source, state, reason: state === "refused" ? "unknown-token" : null, palette: state === "refused" ? null : PALETTE });
const pin = size => ({ repo: "https://github.com/vanillagreencom/vgs-themes", release: "themes-v1", archive: "a.tar.gz", size, sha256: "a".repeat(64) });
const TERMINAL = Object.fromEntries(Array.from({ length: 16 }, (_, index) => ["color" + index, "#000000ff"]));
const entry = (name, installed, imagery, imageryInstalled) => ({ name, mode: "dark", thumbnail: "thumbnails/" + name + ".jpg", thumbnailPath: "/c/thumbnails/" + name + ".jpg", previewPath: name === "akane" ? "/c/akane/preview.png" : null, palette: PALETTE, tokens: { palette: PALETTE }, terminal: TERMINAL, imagery, installed, imageryInstalled, imageryUpdate: false, definitionUpdate: false });

// Payloads refused: [label, text, error].
const PAYLOAD_REFUSED = [
    ["not JSON", "nope", "payload=not-json"],
    ["a list", "[]", "payload=not-object"],
    ["null", "null", "payload=not-object"],
    ["an unknown key", JSON.stringify({ view: "themes", source: "x" }), "payload=unknown-key key=source"],
    ["an unknown view", JSON.stringify({ view: "fonts" }), "payload=view got=\"fonts\""],
    ["a view that is no string", JSON.stringify({ view: 1 }), "payload=view got=1"]
];

// Filter edits: [label, text, edit, result].
const EDITS = [
    ["a character appends", "no", { kind: "type", text: "r" }, "nor"],
    ["a space appends", "arc", { kind: "type", text: " " }, "arc "],
    ["erase drops one character", "nord", { kind: "erase" }, "nor"],
    ["erase on nothing is nothing", "", { kind: "erase" }, ""],
    ["a word erase drops the last word and its spaces", "arc blue  ", { kind: "eraseWord" }, "arc "],
    ["clear drops everything", "arc blue", { kind: "clear" }, ""]
];

function verify(logic, files) {
    // Views and payloads.
    same(logic.VIEWS.map(v => [v.name, v.label, v.source]), [["themes", "Themes", "ThemeView.qml"], ["wallpapers", "Wallpapers", "WallpaperView.qml"]]);
    assert.equal(logic.viewSource("themes"), "ThemeView.qml");
    assert.equal(logic.viewSource("wallpapers"), "WallpaperView.qml");
    same(logic.parsePayload(JSON.stringify({ view: "wallpapers" })), { view: "wallpapers" });
    assert.throws(() => logic.viewSource("fonts"), /view="fonts" unknown/);
    for (const view of logic.VIEWS) assert.ok(fs.existsSync(path.join(dir, view.source)), "view " + view.name + " names a file beside Browser.qml");
    for (const qml of ["ThemeView.qml", "WallpaperView.qml"]) {
        const text = fs.readFileSync(path.join(dir, qml), "utf8");
        assert.equal(/view\.(listReason|catalogReason|imagesReason)/.test(text), false, qml + " reads status fields from root, not the captured refresh view");
    }
    const themeQml = fs.readFileSync(path.join(dir, "ThemeView.qml"), "utf8");
    assert.ok(themeQml.includes("currentIndex = Qt.binding(() => root.scopeIndex);"), "ThemeView restores the scope control index binding after activation");
    assert.ok(themeQml.includes("onActiveFocusChanged: if (activeFocus) Qt.callLater(root.focusRail)"), "ThemeView tab clicks return focus to the carousel");
    const wallpaperQml = fs.readFileSync(path.join(dir, "WallpaperView.qml"), "utf8");
    assert.ok(wallpaperQml.includes("onActiveFocusChanged: if (activeFocus) Qt.callLater(root.takeKeys)"), "WallpaperView tab clicks return focus to the keyboard owner");
    same(logic.parsePayload("{}"), { view: "themes" }, "an empty payload opens the first view");
    same(logic.parsePayload(""), { view: "themes" }, "no payload opens the first view");
    same(logic.parsePayload(JSON.stringify({ view: "themes" })), { view: "themes" });
    for (const [label, text, error] of PAYLOAD_REFUSED)
        assert.throws(() => logic.parsePayload(text), e => e.message === error, label);

    assert.equal(logic.label("arc-blueberry"), "Arc Blueberry");
    assert.equal(logic.label("tokyo_night"), "Tokyo Night");

    // Cards: every source, one per name, in name order.
    const packages = [
        Object.assign(pkg("vgs", "shipped", "ok"), { previewPath: "/themes/vgs/preview.png", tokens: { palette: PALETTE }, terminal: TERMINAL }),
        pkg("light", "shipped", "shadowed"),
        pkg("light", "installed", "ok"),
        pkg("nord", "installed", "ok"),
        pkg("broken", "installed", "refused"),
        pkg("mine", "installed", "ok")
    ];
    const entries = [
        entry("nord", true, pin(41617647), false),
        entry("akane", false, pin(2000000), false),
        entry("plain", false, null, false),
        entry("mine", false, pin(5), false)
    ];
    const images = [
        { background: "a.jpg", theme: "nord", path: "/t/nord/backgrounds/a.jpg" },
        { background: "b.jpg", theme: "nord", path: "/t/nord/backgrounds/b.jpg" },
        { background: "u.jpg", theme: null, path: "/u/u.jpg" }
    ];
    const built = logic.cards(packages, entries, images, "nord");
    same(built.map(c => [c.name, c.source, c.state, c.installed, c.image, c.imagery, c.displayed]), [
        ["akane", "catalog", "ok", false, "/c/thumbnails/akane.jpg", { size: 2000000, installed: false }, false],
        ["broken", "installed", "refused", true, null, null, false],
        ["light", "installed", "ok", true, null, null, false],
        ["mine", "installed", "ok", true, null, null, false],
        ["nord", "installed", "ok", true, "/t/nord/backgrounds/a.jpg", { size: 41617647, installed: false }, true],
        ["plain", "catalog", "ok", false, "/c/thumbnails/plain.jpg", null, false],
        ["vgs", "shipped", "ok", true, null, null, false]
    ]);
    same(built.find(c => c.name === "akane").palette, PALETTE, "a catalog card carries the index palette");
    assert.equal(built.find(c => c.name === "akane").previewImage, "/c/akane/preview.png", "a catalog card carries its package preview");
    assert.equal(built.find(c => c.name === "vgs").previewImage, "/themes/vgs/preview.png", "an installed or shipped package preview wins");
    same(built.find(c => c.name === "akane").tokens, { palette: PALETTE }, "a catalog card carries the package tokens");
    same(built.find(c => c.name === "akane").terminal, TERMINAL, "a catalog card carries the terminal palette");
    same(built.find(c => c.name === "broken").reason, "unknown-token");
    // A catalog install with no image shows its thumbnail.
    same(logic.cards([pkg("nord", "installed", "ok")], [entry("nord", true, pin(9), true)], [], "vgs")[0].image, "/c/thumbnails/nord.jpg");
    // The catalog or the image list failing leaves the listed packages.
    same(logic.cards(packages, null, null, "vgs").map(c => [c.name, c.image]), [["broken", null], ["light", null], ["mine", null], ["nord", null], ["vgs", null]]);
    same(logic.cards([], [], [], "vgs"), []);

    // Filter and scope.
    assert.equal(logic.matches(built[0], ""), true);
    assert.equal(logic.matches({ name: "arc-blueberry", label: "Arc Blueberry" }, "c b"), true, "the label matches with a space");
    assert.equal(logic.matches({ name: "arc-blueberry", label: "Arc Blueberry" }, "C-B"), true, "the name matches in any case");
    assert.equal(logic.matches({ name: "arc-blueberry", label: "Arc Blueberry" }, "nord"), false);
    same(logic.shown(built, "", "installed").map(c => c.name), ["broken", "light", "mine", "nord", "vgs"]);
    same(logic.shown(built, "n", "all").map(c => c.name), ["akane", "broken", "mine", "nord", "plain"], "the filter keeps the order");
    same(logic.shown(built, "No", "installed").map(c => c.name), ["nord"]);
    assert.throws(() => logic.shown(built, "", "starred"), /scope="starred" want=all\|installed/);
    const nordCard = built.find(c => c.name === "nord");
    assert.equal(logic.cardKey(nordCard), logic.cardKey(Object.assign({}, nordCard, { displayed: false, imagery: null })), "state the card does not draw keeps its key");
    for (const [label, change] of [
        ["a palette", { palette: Object.assign({}, PALETTE, { accent: "#ff0000ff" }) }],
        ["a package preview", { previewImage: "/t/nord/preview.png" }],
        ["tokens", { tokens: { palette: Object.assign({}, PALETTE, { accent: "#ff0000ff" }) } }],
        ["terminal slots", { terminal: Object.assign({}, TERMINAL, { color1: "#ff0000ff" }) }],
        ["a label", { label: "Nord Two" }],
        ["a name", { name: "nord-two" }]
    ]) assert.notEqual(logic.cardKey(Object.assign({}, nordCard, change)), logic.cardKey(nordCard), label + " changes the key");
    assert.equal(logic.railKey("/t/a.jpg", 7), logic.railKey("/t/a.jpg", 7), "one key in one generation is one card");
    assert.notEqual(logic.railKey("/t/a.jpg", 8), logic.railKey("/t/a.jpg", 7), "a new generation rebuilds the card");
    assert.notEqual(logic.railKey("/t/b.jpg", 7), logic.railKey("/t/a.jpg", 7), "another key is another card");
    assert.equal(logic.selection(built, "nord"), 4);
    assert.equal(logic.selection(built, "gone"), 0);
    assert.equal(logic.selection([], "nord"), 0);

    for (const [label, text, edit, result] of EDITS) assert.equal(logic.editFilter(text, edit), result, label);
    assert.throws(() => logic.editFilter("a", { kind: "type", text: "\n" }), /filter-edit=type/);
    assert.throws(() => logic.editFilter("a", { kind: "yank" }), /filter-edit="yank"/);
    for (const [text, want] of [["a", true], [" ", true], ["é", true], ["", false], ["ab", false], ["\t", false], ["\u007f", false], [undefined, false]])
        assert.equal(logic.typable(text), want, "typable " + JSON.stringify(text));

    // The offer: installed, displayed, pinned with bytes, not unpacked.
    const nord = built.find(c => c.name === "nord");
    assert.equal(logic.downloadOffer(nord), true);
    for (const [label, change] of [
        ["not displayed", { displayed: false }],
        ["not installed", { installed: false }],
        ["no pin", { imagery: null }],
        ["unpacked", { imagery: { size: 41617647, installed: true } }],
        ["an empty archive", { imagery: { size: 0, installed: false } }]
    ]) assert.equal(logic.downloadOffer(Object.assign({}, nord, change)), false, label);
    assert.equal(logic.downloadOffer(null), false);

    // Sizes and progress.
    assert.equal(logic.sizeText(41617647), "42 MB");
    assert.equal(logic.sizeText(1), "1 MB");
    assert.equal(logic.progressText(null), "");
    assert.equal(logic.progressText({ name: "nord", state: null, bytes: 0, total: null }), "Starting the download");
    assert.equal(logic.progressText({ name: "nord", state: "downloading", bytes: 12000000, total: 41617647 }), "Downloading 12 of 42 MB");
    assert.equal(logic.progressText({ name: "nord", state: "downloading", bytes: 3000000, total: null }), "Downloading 3 MB");
    assert.equal(logic.progressText({ name: "nord", state: "verifying", bytes: 0, total: 41617647 }), "Verifying the archive");
    assert.equal(logic.progressText({ name: "nord", state: "unpacking", bytes: 0, total: 9 }), "Unpacking the wallpapers");
    assert.equal(logic.progressText({ name: "nord", state: "resuming", bytes: 0, total: 9 }), "resuming");
    assert.equal(logic.progressValue(null), null);
    assert.equal(logic.progressValue({ state: "downloading", bytes: 1000, total: 2000 }), 0.5);
    assert.equal(logic.progressValue({ state: "downloading", bytes: 3000, total: 2000 }), 1);
    assert.equal(logic.progressValue({ state: null, bytes: 0, total: null }), null);

    // Results.
    for (const [state, want] of [["applied", true], ["unchanged", true], ["partial", true], ["failed", false]])
        assert.equal(logic.applied({ state }), want, "applied " + state);
    assert.equal(logic.problem("install", "nord", { state: "ok", reason: null }), "");
    assert.equal(logic.problem("install", "nord", { state: "failed", reason: "exists" }), "Installing Nord failed: exists");
    assert.equal(logic.problem("apply", "nord", { state: "applied", reason: null }), "");
    assert.equal(logic.problem("apply", "nord", { state: "unchanged", reason: null }), "");
    assert.equal(logic.problem("apply", "nord", { state: "partial", reason: null }), "Nord is applied, but some applications did not take it: the Themes panel lists them");
    assert.equal(logic.problem("apply", "nord", { state: "failed", reason: "busy" }), "Applying Nord failed: busy");
    assert.equal(logic.problem("download", "nord", { state: "ok", reason: null }), "");
    assert.equal(logic.problem("download", "nord", { state: "failed", reason: "sha256" }), "Downloading the wallpapers for Nord failed: sha256");
    assert.equal(logic.problem("update", "nord", { state: "ok", reason: null }), "");
    assert.equal(logic.problem("update", "nord", { state: "failed", reason: "changed" }), "Updating the wallpapers for Nord failed: changed");
    assert.equal(logic.problem("set", "a.jpg", { state: "ok", reason: null }), "");
    assert.equal(logic.problem("set", "a.jpg", { state: "failed", reason: "outside" }), "Setting a.jpg failed: outside");
    assert.throws(() => logic.problem("remove", "nord", { state: "ok" }), /step="remove"/);

    verifyWallpapers(logic);

    // File URLs encode each segment.
    assert.equal(files.fileUrl("/home/u/a b/#1?.jpg"), "file:///home/u/a%20b/%231%3F.jpg");
    assert.equal(files.stampedUrl("/home/u/a b.jpg", "12:34.5"), "file:///home/u/a%20b.jpg?12%3A34.5");
    assert.equal(files.stampedUrl("/t/a.jpg", 1790679199706), "file:///t/a.jpg?1790679199706");
}

// Qt::Key codes, from qnamespace.h.
const K = { Escape: 0x01000000, Tab: 0x01000001, Backtab: 0x01000002, Return: 0x01000004, Enter: 0x01000005, Home: 0x01000010, End: 0x01000011, Left: 0x01000012, Up: 0x01000013, Right: 0x01000014, Down: 0x01000015, PageUp: 0x01000016, PageDown: 0x01000017, A: 0x41, D: 0x44, I: 0x49, M: 0x4d, S: 0x53, W: 0x57, Q: 0x51, Space: 0x20 };

// Theme keys: [label, key, shift, control, alt, meta, action].
const THEME_KEYS = [
    ["Up steps back", K.Up, false, false, false, false, "back"],
    ["Down steps forward", K.Down, false, false, false, false, "forward"],
    ["Return activates", K.Return, false, false, false, false, "activate"],
    ["Escape closes or clears", K.Escape, false, false, false, false, "close"],
    ["Tab switches to the next top tab", K.Tab, false, false, false, false, "tab-next"],
    ["Shift+Tab switches to the previous top tab", K.Tab, true, false, false, false, "tab-previous"],
    ["Backtab switches to the previous top tab", K.Backtab, false, false, false, false, "tab-previous"],
    ["Ctrl+Tab switches to the next top tab", K.Tab, false, true, false, false, "tab-next"],
    ["Ctrl+Shift+Tab switches to the previous top tab", K.Tab, true, true, false, false, "tab-previous"],
    ["Ctrl+PageDown switches to the next top tab", K.PageDown, false, true, false, false, "tab-next"],
    ["Ctrl+PageUp switches to the previous top tab", K.PageUp, false, true, false, false, "tab-previous"],
    ["Alt+I flips All and Installed", K.I, false, false, true, false, "scope"],
    ["plain I passes to the filter", K.I, false, false, false, false, ""],
    ["a Meta chord passes on", K.I, false, false, true, true, ""]
];

// Wallpaper keys: [label, key, shift, control, alt, meta, scoped, action].
const WALLPAPER_KEYS = [
    ["Left steps back", K.Left, false, false, false, false, false, "back"],
    ["Up steps back", K.Up, false, false, false, false, false, "back"],
    ["Right steps forward", K.Right, false, false, false, false, false, "forward"],
    ["Down steps forward", K.Down, false, false, false, false, false, "forward"],
    ["Home goes first", K.Home, false, false, false, false, false, "first"],
    ["End goes last", K.End, false, false, false, false, false, "last"],
    ["Return activates", K.Return, false, false, false, false, false, "activate"],
    ["Enter activates", K.Enter, false, false, false, false, false, "activate"],
    ["Escape closes", K.Escape, false, false, false, false, false, "close"],
    ["Alt+S flips the source", K.S, false, false, true, false, false, "source"],
    ["Alt+S flips the source beside the scope", K.S, false, false, true, false, true, "source"],
    ["plain S passes on", K.S, false, false, false, false, false, ""],
    ["plain A passes on", K.A, false, false, false, false, false, ""],
    ["plain D passes on", K.D, false, false, false, false, false, ""],
    ["Alt+M does nothing without the scope", K.M, false, false, true, false, false, ""],
    ["Alt+M flips the scope", K.M, false, false, true, false, true, "scope"],
    ["plain W passes on beside the scope", K.W, false, false, false, false, true, ""],
    ["Tab switches to the next top tab", K.Tab, false, false, false, false, false, "tab-next"],
    ["Shift+Tab switches to the previous top tab", K.Tab, true, false, false, false, false, "tab-previous"],
    ["Backtab switches to the previous top tab", K.Backtab, false, false, false, false, true, "tab-previous"],
    ["Ctrl+Tab switches to the next top tab", K.Tab, false, true, false, false, false, "tab-next"],
    ["Ctrl+Shift+Tab switches to the previous top tab", K.Tab, true, true, false, false, false, "tab-previous"],
    ["Ctrl+PageDown switches to the next top tab", K.PageDown, false, true, false, false, false, "tab-next"],
    ["Ctrl+PageUp switches to the previous top tab", K.PageUp, false, true, false, false, true, "tab-previous"],
    ["Left steps back beside the scope", K.Left, false, false, false, false, true, "back"],
    ["a control chord passes on", K.S, false, true, true, false, true, ""],
    ["a meta chord passes on", K.Return, false, false, false, true, false, ""],
    ["Q passes on", K.Q, false, false, false, false, true, ""],
    ["Space activates", K.Space, false, false, false, false, false, "activate"]
];

// The wallpaper view: sources, scopes, cards, the offer card, the keys
// and the selection.
function verifyWallpapers(logic) {
    same(logic.WALLPAPER_SOURCES.map(s => [s.source, s.label]), [["theme", "Theme"], ["all", "All"]]);
    same(logic.SCREEN_SCOPES.map(s => [s.scope, s.label]), [["every", "All monitors"], ["this", "This monitor"]]);

    for (const [label, key, shift, control, alt, meta, action] of THEME_KEYS)
        assert.equal(logic.themeAction(key, shift, control, alt, meta), action, label);
    for (const [label, key, shift, control, alt, meta, scoped, action] of WALLPAPER_KEYS)
        assert.equal(logic.wallpaperAction(key, shift, control, alt, meta, scoped), action, label);

    for (const [count, want] of [[0, false], [1, false], [2, true], [3, true]])
        assert.equal(logic.scopeShown(count), want, "scope shown with " + count + " screens");
    assert.equal(logic.screenScope(1, 2), "this");
    assert.equal(logic.screenScope(0, 2), "every");
    assert.equal(logic.screenScope(1, 1), "every", "one screen leaves every screen");
    assert.equal(logic.setScreen("every", "DP-1"), "*");
    assert.equal(logic.setScreen("this", "DP-1"), "DP-1");
    assert.throws(() => logic.setScreen("this", ""), /screen="" none/);
    assert.throws(() => logic.setScreen("some", "DP-1"), /scope="some" want=every\|this/);
    const own = { "DP-1": "/u/own.png" };
    assert.equal(logic.shownPath("every", "/t/a.png", own, "DP-1"), "/t/a.png", "every screen shows the current image");
    assert.equal(logic.shownPath("this", "/t/a.png", own, "DP-1"), "/u/own.png", "this screen shows its own image");
    assert.equal(logic.shownPath("this", "/t/a.png", own, "HDMI-A-1"), "/t/a.png", "a screen without its own shows the current image");
    assert.throws(() => logic.shownPath("some", "", {}, "DP-1"), /scope="some"/);

    // The card rule: installed, pinned with bytes; not unpacked, or
    // unpacked from another archive.
    const catalog = (installed, imagery, imageryInstalled, imageryUpdate) => [Object.assign(entry("nord", installed, imagery, imageryInstalled), { imageryUpdate })];
    for (const [label, entries, want] of [
        ["missing wallpapers download", catalog(true, pin(4000000), false, false), "download"],
        ["a newer archive updates", catalog(true, pin(4000000), true, true), "update"],
        ["current wallpapers offer nothing", catalog(true, pin(4000000), true, false), null],
        ["not installed offers nothing", catalog(false, pin(4000000), false, false), null],
        ["no pin offers nothing", catalog(true, null, false, false), null],
        ["an empty archive offers nothing", catalog(true, pin(0), false, false), null],
        ["another package's entry offers nothing", [entry("akane", true, pin(9), false)], null],
        ["a failed catalog offers nothing", null, null]
    ]) assert.equal(logic.wallpaperOffer(entries, "nord"), want, label);

    const images = [
        { background: "a.jpg", theme: "akane", path: "/t/akane/backgrounds/a.jpg" },
        { background: "u.jpg", theme: null, path: "/u/u.jpg" },
        { background: "a.jpg", theme: "nord", path: "/t/nord/backgrounds/a.jpg" },
        { background: "b.jpg", theme: "nord", path: "/t/nord/backgrounds/b.jpg" }
    ];
    const cardRow = c => [c.kind, c.key, c.path, c.label, c.sourceLabel];
    same(logic.wallpaperCards(images, catalog(true, pin(4000000), true, false), "nord", "theme").map(cardRow), [
        ["image", "/t/nord/backgrounds/a.jpg", "/t/nord/backgrounds/a.jpg", "a.jpg", "Nord"],
        ["image", "/t/nord/backgrounds/b.jpg", "/t/nord/backgrounds/b.jpg", "b.jpg", "Nord"]
    ], "theme lists the applied package's images");
    const updating = logic.wallpaperCards(images, catalog(true, pin(4000000), true, true), "nord", "theme");
    same(updating.map(cardRow).slice(2), [["update", "update", null, "Update the wallpapers", "Nord"]], "the update card comes last");
    assert.equal(updating[2].size, 4000000);
    same(logic.wallpaperCards([], catalog(true, pin(4000000), false, false), "nord", "theme").map(cardRow), [["download", "download", null, "Download the wallpapers", "Nord"]]);
    same(logic.wallpaperCards(images, catalog(true, pin(4000000), true, true), "nord", "all").map(cardRow), [
        ["image", "/t/akane/backgrounds/a.jpg", "/t/akane/backgrounds/a.jpg", "a.jpg", "Akane"],
        ["image", "/t/nord/backgrounds/a.jpg", "/t/nord/backgrounds/a.jpg", "a.jpg", "Nord"],
        ["image", "/t/nord/backgrounds/b.jpg", "/t/nord/backgrounds/b.jpg", "b.jpg", "Nord"],
        ["image", "/u/u.jpg", "/u/u.jpg", "u.jpg", "User folder"]
    ], "all lists every package's images, the user folder last, and no card");
    same(logic.wallpaperCards(images, null, "vgs", "theme"), [], "a package with no images and no catalog has no card");
    assert.throws(() => logic.wallpaperCards(images, null, "nord", "some"), /source="some" want=theme\|all/);

    const list = logic.wallpaperCards(images, catalog(true, pin(4000000), true, true), "nord", "theme");
    assert.equal(logic.wallpaperSelection(list, "/t/nord/backgrounds/b.jpg"), 1);
    assert.equal(logic.wallpaperSelection(list, "update"), 2);
    assert.equal(logic.wallpaperSelection(list, "/u/u.jpg"), 0, "an image the source lacks selects the first");
    assert.equal(logic.wallpaperSelection([], ""), 0);

    assert.equal(logic.wallpaperEmpty(false, "theme", "nord"), "Loading wallpapers");
    assert.equal(logic.wallpaperEmpty(true, "theme", "tokyo-night"), "Tokyo Night has no wallpapers");
    assert.equal(logic.wallpaperEmpty(true, "all", "nord"), "No wallpaper is installed");
}

const files = load(path.join(dir, "Files.js"));
const source = fs.readFileSync(file, "utf8");
const scratchRoot = path.join(__dirname, "..", "tmp");
fs.mkdirSync(scratchRoot, { recursive: true });
const temp = fs.mkdtempSync(path.join(scratchRoot, "themes-browser-control-"));
const keyNavLogic = path.join(__dirname, "..", "shell", "Ui", "foundation", "KeyNavLogic.js");
function writeLogicCopy(text, name) {
    const out = path.join(temp, name);
    fs.writeFileSync(out, text
        .replace('.import qs.Ui 1.0 as Ui', `.import "${keyNavLogic}" as KeyNavLogic`)
        .replace(/Ui\.KeyNavLogic/g, "KeyNavLogic"));
    return out;
}
const logicCopy = writeLogicCopy(source, "BrowserLogic.js");
verify(load(logicCopy), files);

// Each control removes one rule from a copy of the logic and keeps the
// text around it. The suite must fail on every copy.
const CONTROLS = [
    ["payload unknown key", "if (PAYLOAD_KEYS.indexOf(keys[i]) === -1) throw", "if (false) throw"],
    ["payload view", 'if (viewNames().indexOf(raw.view) === -1) throw', "if (false) throw"],
    ["shadowed skipped", 'if (p.state === "shadowed") continue;', ""],
    ["listed name wins", "if (hasOwn(listed, e.name)) continue;", ""],
    ["catalog install only", "hasOwn(catalog, p.name) && catalog[p.name].installed ? catalog[p.name] : null", "hasOwn(catalog, p.name) ? catalog[p.name] : null"],
    ["first image", "if (image.theme !== null && !hasOwn(first, image.theme)) first[image.theme] = image.path;", "if (image.theme !== null) first[image.theme] = image.path;"],
    ["name order", "out.sort(", "[].sort("],
    ["label matches", "|| card.label.toLowerCase().indexOf(needle) !== -1", ""],
    ["installed scope", '(scope === "all" || card.installed)', "true"],
    ["printable only", "return code >= 32 && code !== 127;", "return true;"],
    ["offer only when displayed", "card.installed && card.displayed && card.imagery", "card.installed && card.imagery"],
    ["offer only with bytes", "&& card.imagery.size > 0", ""],
    ["rail key holds the generation", "return JSON.stringify([generation, key]);", "return JSON.stringify([key]);"],
    ["key holds the preview inputs", "return JSON.stringify([card.name, card.label, card.previewImage, card.palette, card.tokens, card.terminal]);", "return JSON.stringify([card.name, card.label]);"],
    ["partial names the panel", 'if (result.state === "partial") return', 'if (false) return'],
    ["shared Ctrl+Tab switches top tabs", "if (key === K.Tab || key === K.PageDown) return shift ? TAB_ACTIONS.previous : TAB_ACTIONS.next;", "if (false) return shift ? TAB_ACTIONS.previous : TAB_ACTIONS.next;"],
    ["plain Tab switches top tabs", "if (key === K.Tab || key === K.Backtab) return (shift || key === K.Backtab) ? TAB_ACTIONS.previous : TAB_ACTIONS.next;", "if (false) return (shift || key === K.Backtab) ? TAB_ACTIONS.previous : TAB_ACTIONS.next;"],
    ["theme toggle uses Alt", "if (alt) return key === KEY.I ? \"scope\" : \"\";", "if (true) return key === KEY.I ? \"scope\" : \"\";"],
    ["wallpaper meta chords pass on", 'function wallpaperAction(key, shift, control, alt, meta, scoped) {\n    if (meta) return "";', 'function wallpaperAction(key, shift, control, alt, meta, scoped) {'],
    ["wallpaper source uses Alt", "if (key === KEY.S) return \"source\";", "if (false) return \"source\";"],
    ["wallpaper scope uses Alt+M", "if (key === KEY.M) return scoped ? \"scope\" : \"\";", "if (false) return scoped ? \"scope\" : \"\";"],
    ["scope needs two screens", "return screenCount >= 2;", "return screenCount >= 1;"],
    ["hidden scope is every screen", "return scopeShown(screenCount) ? SCREEN_SCOPES[index].scope : SCREEN_SCOPES[0].scope;", "return SCREEN_SCOPES[index].scope;"],
    ["this screen shows its own", "return hasOwn(screenPaths, name) ? screenPaths[name] : current;", "return current;"],
    ["offer needs an install", "if (!e.installed || e.imagery === null", "if (e.imagery === null"],
    ["offer needs bytes", " || !(e.imagery.size > 0)", ""],
    ["update card", 'return e.imageryUpdate ? "update" : null;', "return null;"],
    ["theme source is the applied package", "return i.theme === applied; }).map(card);", "return true; }).map(card);"],
    ["user folder last", "return packaged.concat(user).map(card);", "return images.map(card);"],
    ["user folder label", "image.theme === null ? USER_FOLDER_LABEL : label(image.theme)", "label(image.theme)"]
];

try {
    for (const [label, needle, replacement] of CONTROLS) {
        assert.equal(source.split(needle).length, 2, `control "${label}": the text to replace must occur once`);
        const mutant = writeLogicCopy(source.replace(needle, () => replacement), "BrowserLogic-" + label.replace(/[^A-Za-z0-9]+/g, "-") + ".js");
        let failed = false;
        try {
            verify(load(mutant), files);
        } catch (e) {
            failed = true;
        }
        assert.ok(failed, `control "${label}": the suite passed on logic without that rule`);
    }
    // Files.js's control: a stamped URL that drops its stamp.
    const filesSource = fs.readFileSync(path.join(dir, "Files.js"), "utf8");
    const stampNeedle = 'return fileUrl(path) + "?" + encodeURIComponent(String(stamp));';
    assert.equal(filesSource.split(stampNeedle).length, 2, "control \"stamp in the URL\": the text to replace must occur once");
    const filesMutant = path.join(temp, "Files.js");
    fs.writeFileSync(filesMutant, filesSource.replace(stampNeedle, () => "return fileUrl(path);"));
    let stampFailed = false;
    try {
        verify(load(logicCopy), load(filesMutant));
    } catch (e) {
        stampFailed = true;
    }
    assert.ok(stampFailed, "control \"stamp in the URL\": the suite passed on files without the stamp");
} finally {
    fs.rmSync(temp, { recursive: true, force: true });
}
console.log(`test-themes-browser: ok payloads=${PAYLOAD_REFUSED.length} edits=${EDITS.length} keys=${WALLPAPER_KEYS.length} controls=${CONTROLS.length + 1}`);
