#!/usr/bin/env node
// The theme browser's decisions, shell/plugins/vgs.themes/BrowserLogic.js,
// and the plugin's file URLs, Files.js, under node: the payload and its
// views, the cards merged from the list, the catalog and the images, the
// filter, the selection, the download offer and the lines the browser
// shows. Every expected value is written out by hand.
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
const entry = (name, installed, imagery, imageryInstalled) => ({ name, mode: "dark", thumbnail: "thumbnails/" + name + ".jpg", thumbnailPath: "/c/thumbnails/" + name + ".jpg", palette: PALETTE, imagery, installed, imageryInstalled, imageryUpdate: false, definitionUpdate: false });

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
    same(logic.VIEWS.map(v => v.name), ["themes"]);
    same(logic.parsePayload("{}"), { view: "themes" }, "an empty payload opens the first view");
    same(logic.parsePayload(""), { view: "themes" }, "no payload opens the first view");
    same(logic.parsePayload(JSON.stringify({ view: "themes" })), { view: "themes" });
    for (const [label, text, error] of PAYLOAD_REFUSED)
        assert.throws(() => logic.parsePayload(text), e => e.message === error, label);

    assert.equal(logic.label("arc-blueberry"), "Arc Blueberry");
    assert.equal(logic.label("tokyo_night"), "Tokyo Night");

    // Cards: every source, one per name, in name order.
    const packages = [
        pkg("vgs", "shipped", "ok"),
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
    assert.throws(() => logic.problem("remove", "nord", { state: "ok" }), /step="remove"/);

    // File URLs encode each segment.
    assert.equal(files.fileUrl("/home/u/a b/#1?.jpg"), "file:///home/u/a%20b/%231%3F.jpg");
}

const files = load(path.join(dir, "Files.js"));
verify(load(file), files);

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
    ["partial names the panel", 'if (result.state === "partial") return', 'if (false) return']
];

const source = fs.readFileSync(file, "utf8");
const scratchRoot = path.join(__dirname, "..", "tmp");
fs.mkdirSync(scratchRoot, { recursive: true });
const temp = fs.mkdtempSync(path.join(scratchRoot, "themes-browser-control-"));
try {
    for (const [label, needle, replacement] of CONTROLS) {
        assert.equal(source.split(needle).length, 2, `control "${label}": the text to replace must occur once`);
        const mutant = path.join(temp, "BrowserLogic.js");
        fs.writeFileSync(mutant, source.replace(needle, () => replacement));
        let failed = false;
        try {
            verify(load(mutant), files);
        } catch (e) {
            failed = true;
        }
        assert.ok(failed, `control "${label}": the suite passed on logic without that rule`);
    }
} finally {
    fs.rmSync(temp, { recursive: true, force: true });
}
console.log(`test-themes-browser: ok payloads=${PAYLOAD_REFUSED.length} edits=${EDITS.length} controls=${CONTROLS.length}`);
