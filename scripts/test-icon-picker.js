#!/usr/bin/env node

// Execute the Icons tab's picker model: the region between the ICON PICKER MODEL markers in
// quickshell/vshell/Modules/Settings/IconsTab.qml. It turns `vshell theme icons --json`'s
// `sets` list into the tiles the tab draws, decides when the tab draws a line of copy instead
// of the tiles, and decides what the tab may say about the applied set. This models the
// helper's payload; it does not run the helper.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const { evaluateMarked, guardChild } = require("./lib/qml-region.js");

guardChild();

const TAB_QML = path.join(__dirname, "..", "quickshell", "vshell", "Modules", "Settings", "IconsTab.qml");

const M = evaluateMarked(fs.readFileSync(TAB_QML, "utf8"), "ICON PICKER MODEL",
    ["iconSetTiles", "iconPickerState", "appliedSetState"], "IconsTab.qml");

// One `sets` payload as the helper prints it: two installed sets, the first with a sample
// its own directory supplies and one its parent supplies, the second with none resolved.
const SETS = [
    { name: "Yaru-purple", samples: ["/u/Yaru-purple/folder.png", "/u/Yaru/utilities-terminal.png"] },
    { name: "Adwaita", samples: [] },
];
const TILES = M.iconSetTiles(SETS);

test("every installed set becomes a tile carrying its own sample icons", () => {
    assert.deepEqual(TILES.map(tile => tile.name), ["Yaru-purple", "Adwaita"],
        "the tiles follow the helper's list, in its order");
    assert.deepEqual(TILES[0].samples, SETS[0].samples,
        "a tile draws the sample paths the helper resolved for that set");
    assert.deepEqual(TILES[1].samples, [],
        "a set whose samples did not resolve still gets a tile, so it stays pickable");
});

test("a tile carries no applied flag, so picking a set does not rebuild the grid", () => {
    for (const tile of TILES)
        assert.deepEqual(Object.keys(tile).sort(), ["name", "samples"],
            "the delegate marks the applied set; the model must not carry it");
});

test("an entry the helper could not name, and an unresolved sample, are dropped", () => {
    const tiles = M.iconSetTiles([{ name: "", samples: ["/u/x.png"] }, { name: "Yaru", samples: ["", "/u/y.png"] }]);
    assert.deepEqual(tiles.map(tile => tile.name), ["Yaru"], "a nameless entry is not a pickable tile");
    assert.deepEqual(tiles[0].samples, ["/u/y.png"], "an empty sample path is not drawn as an icon");
});

test("the tab draws copy instead of tiles whenever a tile would do nothing", () => {
    // [why, read state, follow theme, tile count, state]
    for (const [why, readState, followTheme, tileCount, state] of [
        ["the first list has not arrived, so nothing is known yet", "pending", false, 0, "loading"],
        ["a pending read outranks the theme owning the choice", "pending", true, 0, "loading"],
        ["the helper call failed, so no claim about installed sets holds", "failed", false, 0, "error"],
        ["a failed read outranks the theme owning the choice", "failed", true, 2, "error"],
        ["nothing is installed, so there is nothing to pick", "ok", false, 0, "empty"],
        // The old tab showed the install advice whichever source was selected, and the
        // Icon source row refuses a pick with no tile to apply.
        ["nothing is installed while the theme owns the choice", "ok", true, 0, "empty"],
        ["the theme owns the icon set, so no tile would apply", "ok", true, 2, "follow-theme"],
        ["sets are installed and the user owns the choice", "ok", false, 2, ""],
    ])
        assert.equal(M.iconPickerState(readState, followTheme, tileCount), state, why);
});

test("the tab claims a set is not installed only from a list it has", () => {
    // [why, read state, applied set, state]
    for (const [why, readState, applied, state] of [
        ["a set the list carries is applied", "ok", "Yaru-purple", "applied"],
        // scripts/check-vshell-helper.py leaves over-inclusion from a Flatpak export root
        // open, but a configured set can also simply have been uninstalled.
        ["a configured set the list does not carry is named as missing", "ok", "Papirus", "missing"],
        ["a failed read claims nothing about the applied set", "failed", "Papirus", "unknown"],
        ["a pending read claims nothing about the applied set", "pending", "Yaru-purple", "unknown"],
    ])
        assert.equal(M.appliedSetState(readState, TILES, applied), state, why);
});

test("the extracted region assigns on the component, not the global scope", () => {
    M.iconSetTiles(SETS);
    M.iconPickerState("ok", false, 2);
    M.appliedSetState("ok", TILES, "Yaru-purple");
    for (const name of ["sets", "applied", "followTheme", "tileCount", "readState", "tiles"])
        assert.ok(!(name in globalThis), `${name} must not leak to the global scope`);
});
