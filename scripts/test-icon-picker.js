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
const { extractBlock, callInScope } = require("./lib/qml-block.js");
const qmlSource = require("./lib/qml-source.js");

guardChild();

const TAB_QML = path.join(__dirname, "..", "quickshell", "vshell", "Modules", "Settings", "IconsTab.qml");
const SOURCE = fs.readFileSync(TAB_QML, "utf8");
const Q = qmlSource(SOURCE, "IconsTab.qml");

const M = evaluateMarked(SOURCE, "ICON PICKER MODEL",
    ["iconPickerState", "appliedSetName", "iconSetClaim", "setLine", "canPickFixed"], "IconsTab.qml");

const TILE_QML = path.join(__dirname, "..", "quickshell", "vshell", "Modules", "Settings", "Widgets", "IconSetTile.qml");
const TILE = qmlSource(fs.readFileSync(TILE_QML, "utf8"), "IconSetTile.qml");

// The body of the `vshell theme icons --json` callback, run against the tab's own
// properties. Proc hands it captured stdout, the exit status and captured stderr.
const CALLBACK = extractBlock(SOURCE, 'Proc.runCommand("vgs-icons-list"');

// The tab as it stands before any reply.
const tab = () => ({ iconSets: [], themeIcon: "", readState: "pending", loadError: "" });

function answer(root, output, exitCode, errorOutput) {
    const warned = [];
    const scope = {
        I18n: { tr: text => ({ arg: value => text.replace("%1", value) }) },
        Log: { scoped: () => ({ warn: (...parts) => warned.push(parts.join(" ")) }) },
    };
    // The harness wraps the body in `with (scope) { with (root) {`, so no scope key may be
    // named root: one would shadow the component the body writes to.
    callInScope(CALLBACK, root, scope, ["output", "exitCode", "errorOutput"], [output, exitCode, errorOutput]);
    return warned;
}

const PAYLOAD = JSON.stringify({ sets: [{ name: "Yaru", samples: ["/u/Yaru/folder.png"] }], themeIcon: "Yaru" });

// One `sets` payload as the helper prints it, which the tab's Repeater takes as its model:
// two installed sets, the second one the helper could not sample.
const SETS = [
    { name: "Yaru-purple", samples: ["/u/Yaru-purple/folder.png", "/u/Yaru/utilities-terminal.png"] },
    { name: "Adwaita", samples: [] },
];

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

test("the set the shell draws is named only where the tab can establish it", () => {
    // [why, read state, follow theme, theme's set, the user's own setting, applied set]
    for (const [why, readState, followTheme, themeIcon, fixed, applied] of [
        ["the user's own setting names the set whatever the read did", "failed", false, "", "Papirus", "Papirus"],
        ["the user's own setting names the set before the first read", "pending", false, "", "Papirus", "Papirus"],
        ["under Follow theme the theme names the set", "ok", true, "Yaru-purple", "System Default", "Yaru-purple"],
        // themes/targets/icons-vgs/config.json skips its target where gsettings is not on
        // PATH, and applying a theme that ships no apps/icons.theme deletes the pointer.
        ["a theme that names no set leaves the desktop's own", "ok", true, "", "System Default", "System Default"],
        ["the theme's name arrives with the list, so a failed read leaves it unestablished",
            "failed", true, "", "System Default", ""],
        ["a pending read leaves it unestablished too", "pending", true, "", "System Default", ""],
    ])
        assert.equal(M.appliedSetName(readState, followTheme, themeIcon, fixed), applied, why);
});

test("one predicate owns every claim a card line makes about an icon set", () => {
    // [why, read state, set name, claim]
    for (const [why, readState, name, claim] of [
        ["no name, so the line states nothing and is not drawn", "ok", "", "absent"],
        // Follow theme is the default state and a theme need not name an icon set, so a
        // healthy install reaches this every day: the desktop default is not a set.
        ["the desktop's own icon set is not a set that can be missing", "ok", "System Default", "default"],
        ["a failed read leaves a named set unchecked, never missing", "failed", "Papirus", "unchecked"],
        ["a pending read leaves a named set unchecked too", "pending", "Yaru-purple", "unchecked"],
        ["a name the list carries is installed", "ok", "Yaru-purple", "installed"],
        // The theme's own set is checked against the same list as the applied set.
        ["the theme's set is checked against that one list", "ok", "Adwaita", "installed"],
        ["a name the list was read and does not carry is missing", "ok", "Papirus", "missing"],
    ])
        assert.equal(M.iconSetClaim(readState, SETS, name), claim, why);
});

test("the extracted region assigns on the component, not the global scope", () => {
    M.iconPickerState("ok", false, 2);
    M.appliedSetName("ok", true, "Yaru-purple", "System Default");
    M.iconSetClaim("ok", SETS, "Yaru-purple");
    for (const name of ["sets", "followTheme", "tileCount", "readState", "themeIcon", "fixedIcon"])
        assert.ok(!(name in globalThis), `${name} must not leak to the global scope`);
});

test("a helper call that produced no list is recorded as failed, with its reason", () => {
    // [why, stdout, exit code, stderr, the reason the tab shows]
    for (const [why, output, exitCode, errorOutput, reason] of [
        ["the helper's own diagnostic is the reason", "", 1, "vshell-helper error: boom\n", "vshell-helper error: boom"],
        ["with no stderr the reason falls back to stdout", "usage: vshell theme\n", 2, "", "usage: vshell theme"],
        // Proc reports 124 when the process fails to start or outruns defaultTimeoutMs,
        // and neither stream carries anything to quote.
        ["with neither stream the reason names the exit code", "", 124, "", "Helper exited with code 124"],
    ]) {
        const root = tab();
        const warned = answer(root, output, exitCode, errorOutput);
        assert.equal(root.readState, "failed", why);
        assert.equal(root.loadError, reason, why);
        assert.equal(warned.length, 1, `${why}: the failure is logged once`);
        assert.deepEqual(root.iconSets, [], `${why}: no list is invented`);
    }
});

test("stdout the tab cannot read is a failed read, not an empty list", () => {
    const root = tab();
    const warned = answer(root, "{ not json", 0, "");
    assert.equal(root.readState, "failed", "unparsable output leaves the read failed");
    assert.ok(root.loadError.includes("Error"), "the reason carries the parse error");
    assert.equal(warned.length, 1, "the parse failure is logged once");
    assert.deepEqual(root.iconSets, [], "no list is invented");
});

test("a payload the tab can read clears the failure and fills the list", () => {
    const root = tab();
    root.readState = "failed";
    root.loadError = "vshell-helper error: boom";
    const warned = answer(root, PAYLOAD, 0, "");
    assert.equal(root.readState, "ok", "a good read clears the earlier failure");
    assert.equal(root.loadError, "", "and clears its reason with it");
    assert.deepEqual(root.iconSets.map(set => set.name), ["Yaru"], "the list is the payload's sets");
    assert.equal(root.themeIcon, "Yaru", "the theme's set comes from the same payload");
    assert.deepEqual(warned, [], "a good read logs nothing");
});

test("a reply that outlives the tab returns before its writes", () => {
    // Settings destroys a tab when the user leaves its page and Proc answers afterwards;
    // a destroyed root reads as null there. `with (null)` throws in this harness, so the
    // guard is pinned here as source text and its behaviour is not asserted. Position is
    // the whole point: a write moved above the guard raises on the destroyed component.
    const body = qmlSource.stripComments(CALLBACK);
    const guard = body.indexOf("if (!root)");
    const firstTouch = body.indexOf("root.");
    assert.notEqual(guard, -1, "the callback must guard on a destroyed root");
    assert.notEqual(firstTouch, -1, "the callback must reach the component at all");
    assert.match(body.slice(guard), /^if \(!root\)\s*return;/,
        "the guard must return, not fall through");
    assert.ok(guard < firstTouch,
        "the guard must stand before the callback first touches root, or a write reaches a destroyed component");
});

test("picking a set does not re-read the list", () => {
    Q.requires(Q.body("useFixed"), "IconsTab.qml useFixed()",
        [["refresh()", "a pick moves the mark through the delegate; re-reading rebuilds every tile with identical data", 0]]);
});

test("a claim becomes words in exactly one way", () => {
    // The sentences the card hands in, as the component builds them for a set named
    // "Papirus" and for the desktop's own set.
    const NAMED = "Currently applied: Papirus";
    const UNNAMED = "Currently applied: the desktop's own icon set";
    const SUFFIX = "not installed on this system.";
    const COPY = { named: NAMED, unnamed: UNNAMED, notInstalled: SUFFIX };
    // [why, claim, sentence, warns]
    for (const [why, claim, text, warn] of [
        ["no name draws no line at all", "absent", "", false],
        ["the desktop's own set is named as such", "default", UNNAMED, false],
        ["a set no list has checked is stated and nothing more", "unchecked", NAMED, false],
        ["a set the list carries is stated and nothing more", "installed", NAMED, false],
        ["only a set the read checked and did not find carries the suffix", "missing", NAMED + " — " + SUFFIX, true],
    ])
        assert.deepEqual(M.setLine(claim, COPY), { text, warn }, why);

    // appliedSetName returns the "System Default" sentinel for a theme that names no
    // set, so that is the name the component's `named` sentence carries there.
    assert.equal(M.setLine("default", { named: "Currently applied: System Default", unnamed: UNNAMED, notInstalled: SUFFIX }).text,
        UNNAMED, "the settings sentinel never reaches the card as a set name");
});

test("a card line draws what the region decided and nothing of its own", () => {
    const component = qmlSource(Q.blockFrom(Q.indexOf("component SetLine:"), "the SetLine component"),
        "IconsTab.qml SetLine");
    // [binding, value]
    for (const [name, value] of [
        ["line", 'root.setLine(root.iconSetClaim(root.readState, root.iconSets, setName), { named: label.arg(setName), unnamed: label.arg(I18n.tr("the desktop\'s own icon set")), notInstalled: I18n.tr("not installed on this system.") })'],
        ["text", "line.text"],
        ["visible", 'line.text !== ""'],
        ["color", "line.warn ? Theme.warning : Theme.surfaceVariantText"],
    ])
        assert.equal(component.binding(name).value, value,
            `SetLine.${name} must read the region's answer, so no line can word or colour itself`);

    const flow = Q.objectBlocks("Flow", 1)[0];
    assert.equal(flow.q.binding("visible").value, 'root.pickerState === ""',
        "the tile grid is drawn only where iconPickerState says tiles are drawn");

    // Each line's relevance is the name it hands in, so the component keeps deciding
    // when a line is drawn. The component declaration carries a type, so only the two
    // instances match here.
    const source = Q.objectBlocks("SettingsChoiceRow", 1)[0];
    assert.equal(source.q.binding("visible").value, "root.canPickFixed(root.pickerState)",
        "the Icon source row is drawn only where canPickFixed says a set can be applied");

    const lines = Q.objectBlocks("SetLine", 2);
    assert.equal(lines[0].q.binding("setName").value, "root.appliedIcon",
        "the first line is about the set the shell draws");
    assert.equal(lines[1].q.binding("setName").value, 'root.followTheme ? "" : root.themeIcon',
        "under Follow theme the theme's set is the applied set, which the line above names; a second line would state it twice");
});

test("the Icon source row is offered only where a set can be applied", () => {
    // [why, picker state, offered]
    for (const [why, pickerState, offered] of [
        ["before the first list arrives there is no set to apply", "loading", false],
        ["a failed read leaves no set to apply", "error", false],
        ["nothing installed leaves no set to apply", "empty", false],
        ["the theme owns the choice, and the user can take it", "follow-theme", true],
        ["the user owns the choice already", "", true],
    ])
        assert.equal(M.canPickFixed(pickerState), offered, why);
});

test("every way of activating a tile raises the same signal", () => {
    // The picker is the only way to choose a set, so a keyboard or screen-reader user
    // reaches it through these three alongside the click.
    for (const handler of ["Keys.onSpacePressed", "Keys.onReturnPressed", "Accessible.onPressAction", "onClicked"])
        assert.deepEqual(TILE.handlers(handler).map(line => line.trim()), [`${handler}: root.activated()`],
            `IconSetTile ${handler} must raise the one activation signal, so no path is left behind`);
    assert.equal(TILE.binding("activeFocusOnTab").value, "true", "a tile must be reachable in tab order");
    assert.equal(TILE.binding("Accessible.role").value, "Accessible.Button", "a tile announces itself as a button");
});

test("a focused tile is not read as the applied tile", () => {
    const ring = TILE.objectBlocks("Rectangle", 1)[0].q;
    const body = TILE.objectBlocks("StyledRect", 1)[0].q;
    assert.equal(ring.binding("visible").value, "root.activeFocus", "the focus ring follows focus and nothing else");
    assert.notEqual(ring.binding("border.color").value, body.binding("border.color").value,
        "the focus ring takes its own colour, so focus and applied are two states on screen");
});
