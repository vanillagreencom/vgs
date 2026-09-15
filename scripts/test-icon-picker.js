#!/usr/bin/env node

// Execute the Icons tab's picker model: the region between the ICON PICKER MODEL markers in
// quickshell/vshell/Modules/Settings/IconsTab.qml. It turns `vshell theme icons --json`'s
// `sets` list into the tiles the tab draws, and decides when the tab draws a line of copy
// instead of the tiles. This models the helper's payload; it does not run the helper.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const { evaluateMarked, guardChild } = require("./lib/qml-region.js");

guardChild();

const TAB_QML = path.join(__dirname, "..", "quickshell", "vshell", "Modules", "Settings", "IconsTab.qml");

const M = evaluateMarked(fs.readFileSync(TAB_QML, "utf8"), "ICON PICKER MODEL",
    ["iconSetTiles", "iconPickerState"], "IconsTab.qml");

// One `sets` payload as the helper prints it: two installed sets, the first with a sample
// its own directory supplies and one its parent supplies, the second with none resolved.
const SETS = [
    { name: "Yaru-purple", samples: ["/u/Yaru-purple/folder.png", "/u/Yaru/utilities-terminal.png"] },
    { name: "Adwaita", samples: [] },
];

test("every installed set becomes a tile carrying its own sample icons", () => {
    const tiles = M.iconSetTiles(SETS, "Yaru-purple");
    assert.deepEqual(tiles.map(tile => tile.name), ["Yaru-purple", "Adwaita"],
        "the tiles follow the helper's list, in its order");
    assert.deepEqual(tiles[0].samples, SETS[0].samples,
        "a tile draws the sample paths the helper resolved for that set");
    assert.deepEqual(tiles[1].samples, [],
        "a set whose samples did not resolve still gets a tile, so it stays pickable");
});

test("the applied set is the one tile marked", () => {
    for (const [applied, marked] of [
        ["Yaru-purple", ["Yaru-purple"]],
        ["Adwaita", ["Adwaita"]],
        // The set the shell draws can be one this machine no longer has installed.
        ["Papirus", []],
    ]) {
        const tiles = M.iconSetTiles(SETS, applied);
        assert.deepEqual(tiles.filter(tile => tile.applied).map(tile => tile.name), marked,
            `with ${applied} applied, exactly the tiles ${JSON.stringify(marked)} are marked`);
    }
});

test("an entry the helper could not name, and an unresolved sample, are dropped", () => {
    const tiles = M.iconSetTiles([{ name: "", samples: ["/u/x.png"] }, { name: "Yaru", samples: ["", "/u/y.png"] }], "Yaru");
    assert.deepEqual(tiles.map(tile => tile.name), ["Yaru"], "a nameless entry is not a pickable tile");
    assert.deepEqual(tiles[0].samples, ["/u/y.png"], "an empty sample path is not drawn as an icon");
});

test("the tab draws copy instead of tiles whenever a tile would do nothing", () => {
    // [why, follow theme, tile count, state]
    for (const [why, followTheme, tileCount, state] of [
        ["the theme owns the icon set, so no tile would apply", true, 2, "follow-theme"],
        ["the theme owns the icon set and none is installed", true, 0, "follow-theme"],
        ["nothing is installed, so there is nothing to pick", false, 0, "empty"],
        ["sets are installed and the user owns the choice", false, 2, ""],
    ])
        assert.equal(M.iconPickerState(followTheme, tileCount), state, why);
});

test("the extracted region assigns on the component, not the global scope", () => {
    M.iconSetTiles(SETS, "Yaru-purple");
    M.iconPickerState(false, 2);
    for (const name of ["sets", "applied", "followTheme", "tileCount"])
        assert.ok(!(name in globalThis), `${name} must not leak to the global scope`);
});
