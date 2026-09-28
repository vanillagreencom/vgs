#!/usr/bin/env node
// The launcher's decisions, shell/plugins/vgs.launcher/MenuModel.js, under
// node: the menu file judge and its merge, routes, ranking, the summon
// payload, select options and the file search helper's output. Every
// expected value is written out by hand. The shipped menu.json is judged
// too, so a defect in it fails here before the launcher logs it.
//
// The controls at the end edit a copy of the model, one rule at a time,
// and require this suite to fail on each copy.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { load } = require("./qml-library.js");

const dir = path.join(__dirname, "..", "shell", "plugins", "vgs.launcher");
const file = path.join(dir, "MenuModel.js");
const shippedMenu = fs.readFileSync(path.join(dir, "menu.json"), "utf8");
const RUNTIME = "/run/user/1000";
const menuText = items => JSON.stringify({ schemaVersion: 1, items: items });
// The model runs in its own context, whose arrays and objects are not this
// one's; values are compared as JSON.
const same = (got, want, message) => assert.deepEqual(JSON.parse(JSON.stringify(got)), want, message === undefined ? JSON.stringify(want) : message);

// Menu files the judge refuses: [label, text, the start of the error].
const MENU_REFUSED = [
    ["not JSON", "{ nope", "not-json"],
    ["not an object", "[]", "not-object"],
    ["an unknown file key", JSON.stringify({ schemaVersion: 1, items: {}, extra: 1 }), "unknown key \"extra\""],
    ["a missing schema version", JSON.stringify({ items: {} }), "schemaVersion must be 1"],
    ["items that are no object", JSON.stringify({ schemaVersion: 1, items: [] }), "items must be an object"],
    ["an id with capitals", menuText({ Apps: {} }), "items.Apps is not a dotted lower-case id"],
    ["an item that is no object", menuText({ apps: "x" }), "items.apps must be an object"],
    ["an Omarchy action string", menuText({ apps: { action: "omarchy-launch" } }), "items.apps has unknown key \"action\""],
    ["a label that is no string", menuText({ apps: { label: 3 } }), "items.apps.label must be a string"],
    ["an empty label", menuText({ apps: { label: "" } }), "items.apps.label must not be empty"],
    ["an empty unavailable reason", menuText({ apps: { unavailable: "" } }), "items.apps.unavailable must name why"],
    ["aliases that are no list", menuText({ apps: { aliases: "app" } }), "items.apps.aliases must be a list"],
    ["a run that is a shell string", menuText({ apps: { run: "systemctl suspend" } }), "items.apps.run must be a non-empty list"],
    ["an empty run", menuText({ apps: { run: [] } }), "items.apps.run must be a non-empty list"],
    ["a run with an empty argument", menuText({ apps: { run: ["a", ""] } }), "items.apps.run must be a non-empty list"],
    ["a required command with a space", menuText({ apps: { requires: ["a b"] } }), "items.apps.requires must be a list of command names"],
    ["an unknown provider", menuText({ apps: { provider: "fonts" } }), "items.apps.provider must be one of apps, themes"],
    ["a parent that is no id", menuText({ "a.b": { parent: "A" } }), "items.a.b.parent is not an id"],
    ["a target that is no id", menuText({ apps: { target: "../x" } }), "items.apps.target is not an id"]
];

// Payloads the judge refuses: [label, text, the start of the error].
const PAYLOAD_REFUSED = [
    ["not JSON", "nope", "payload=not-json"],
    ["a list", "[1]", "payload=not-object"],
    ["an Omarchy key", JSON.stringify({ fontFamily: "x" }), "payload=unknown-key key=fontFamily"],
    ["an unknown mode", JSON.stringify({ mode: "dmenu" }), "payload=mode got=\"dmenu\""],
    ["a menu that is no string", JSON.stringify({ menu: 3 }), "payload=menu want=string"],
    ["a width out of range", JSON.stringify({ mode: "select", width: 0, selectionFile: RUNTIME + "/a", doneFile: RUNTIME + "/b" }), "payload=width want=1..4096"],
    ["a picker without a done file", JSON.stringify({ mode: "select", selectionFile: RUNTIME + "/a" }), "payload=doneFile missing"],
    ["a picker writing outside the runtime directory", JSON.stringify({ mode: "select", selectionFile: "/tmp/a", doneFile: RUNTIME + "/b" }), "payload=selectionFile outside=" + RUNTIME],
    ["a picker path climbing out", JSON.stringify({ mode: "select", selectionFile: RUNTIME + "/../etc/a", doneFile: RUNTIME + "/b" }), "payload=selectionFile outside="],
    ["a picker path with a newline", JSON.stringify({ mode: "select", selectionFile: RUNTIME + "/a\nb", doneFile: RUNTIME + "/b" }), "payload=selectionFile outside="],
    ["one file for both answers", JSON.stringify({ mode: "select", selectionFile: RUNTIME + "/a", doneFile: RUNTIME + "/a" }), "payload=doneFile same-as=selectionFile"],
    ["a picker with a route", JSON.stringify({ mode: "select", menu: "apps", selectionFile: RUNTIME + "/a", doneFile: RUNTIME + "/b" }), "payload=select takes no menu or query"],
    ["picker keys on a menu", JSON.stringify({ prompt: "x" }), "payload=prompt needs mode=select|input"],
    ["options on an input", JSON.stringify({ mode: "input", options: ["a"], selectionFile: RUNTIME + "/a", doneFile: RUNTIME + "/b" }), "payload=options needs mode=select"],
    ["options that are no strings", JSON.stringify({ mode: "select", options: [1], selectionFile: RUNTIME + "/a", doneFile: RUNTIME + "/b" }), "payload=options want=list-of-strings"],
    ["more options than the card holds", JSON.stringify({ mode: "select", options: Array(2001).fill("x"), selectionFile: RUNTIME + "/a", doneFile: RUNTIME + "/b" }), "payload=options count=2001 max=2000"]
];

function verify(model) {
    // The shipped menu is accepted and merges alone.
    const shipped = model.parseMenu(shippedMenu);
    assert.equal(shipped.ok, true, shipped.error);
    const alone = model.mergeMenuSources(shipped.entries, []);
    assert.equal(alone.ok, true, alone.error);
    assert.equal(alone.itemOrder[0], "root", "a menu without a root gets one first");
    assert.equal(alone.items.apps.provider, "apps");
    assert.equal(alone.items["system.reboot"].kind, "action");
    assert.equal(alone.items["system.reboot"].parent, "system");
    assert.equal(alone.items.install.kind, "unavailable");
    // Lock runs a real locker: loginctl only asks a logind listener the
    // shell does not provide. Without hyprlock the row says so.
    same(alone.items["system.lock"].run, ["hyprlock"]);
    same(alone.items["system.lock"].requires, ["hyprlock"]);
    same(model.menuRows(alone.items, alone.itemOrder, "system", ["hyprlock"]).filter(r => r.label === "Lock").map(r => [r.kind, r.detail]), [["unavailable", "needs hyprlock"]]);

    for (const [label, text, start] of MENU_REFUSED) {
        const result = model.parseMenu(text);
        assert.equal(result.ok, false, label);
        assert.ok(result.error.startsWith(start), `${label}: ${result.error}`);
    }

    // The user file merges per key: one label changes, the row keeps the
    // shipped keys; a new row is appended; a row stating two kinds refuses.
    const user = model.parseMenu(menuText({ system: { label: "Power" }, "tools.mine": { label: "Mine", run: ["true"] } }));
    const merged = model.mergeMenuSources(shipped.entries, user.entries);
    assert.equal(merged.ok, true);
    assert.equal(merged.items.system.label, "Power");
    same(merged.items.system.aliases, ["power-menu", "power"]);
    assert.equal(merged.items["tools.mine"].parent, "tools");
    assert.equal(merged.itemOrder[merged.itemOrder.length - 1], "tools.mine");
    const both = model.mergeMenuSources(shipped.entries, model.parseMenu(menuText({ "system.reboot": { target: "apps" } })).entries);
    assert.equal(both.ok, false);
    assert.equal(both.error, "items.system.reboot states run and target");
    assert.equal(model.mergeMenuSources([], model.parseMenu(menuText({ x: { parent: "" } })).entries).items.x.parent, "");

    // Routes: an id, an alias, a link's id, and an app's keyword that must
    // not shadow a menu.
    const items = merged.items;
    const order = merged.itemOrder;
    assert.equal(model.resolveRoute(items, order, ""), "root");
    assert.equal(model.resolveRoute(items, order, "Menu"), "root");
    assert.equal(model.resolveRoute(items, order, "system"), "system");
    assert.equal(model.resolveRoute(items, order, "power_menu"), "system");
    assert.equal(model.resolveRoute(items, order, "nowhere"), "nowhere");
    const shadow = model.mergeMenuSources([], model.parseMenu(menuText({ a: { aliases: ["b"], run: ["true"] }, b: { run: ["true"] } })).entries);
    assert.equal(model.resolveRoute(shadow.items, shadow.itemOrder, "b"), "b", "an exact id wins over an alias");
    const withApps = model.swapProviderRows(items, order, "apps", [model.appRow("apps", { id: "htop", name: "Htop", keywords: ["system", "monitor"], icon: "htop" })]);
    assert.equal(model.resolveRoute(withApps.items, withApps.itemOrder, "monitor"), "monitor", "an app keyword is never a route");
    assert.equal(withApps.items["apps.htop"].appId, "htop");
    assert.equal(items["apps.htop"], undefined, "the maps handed in are never written");

    // A provider's rows are swapped whole, and a taken id is listed once.
    const again = model.swapProviderRows(withApps.items, withApps.itemOrder, "apps", [model.appRow("apps", { id: "zen", name: "Zen Browser" }), model.appRow("apps", { id: "zen", name: "Zen Twice" })]);
    assert.equal(again.items["apps.htop"], undefined);
    assert.equal(again.itemOrder.filter(id => id === "apps.zen").length, 1);
    assert.equal(again.items["apps.zen"].label, "Zen Browser");

    // Theme packages: the current one is checked; a refused one shows why.
    const themes = model.swapProviderRows(again.items, again.itemOrder, "style.theme", [
        model.themeRow("style.theme", { name: "vgs", source: "shipped", state: "ok", reason: null, current: true }),
        model.themeRow("style.theme", { name: "broken", source: "installed", state: "refused", reason: "name-mismatch", current: false })
    ]);
    assert.equal(themes.items["style.theme.vgs"].kind, "theme");
    assert.equal(themes.items["style.theme.vgs"].icon, "check");
    assert.equal(themes.items["style.theme.broken"].kind, "unavailable");
    assert.equal(themes.items["style.theme.broken"].description, "refused: name-mismatch");

    // Search and rank: an app named with the whole word wins over an exact
    // menu label; deeper matches sit after direct ones in the drilldown.
    const found = model.searchRows(again.items, again.itemOrder, "root", "zen", []);
    same(found.map(r => [r.kind, r.label]), [["app", "Zen Browser"]]);
    const zen = model.mergeMenuSources([], model.parseMenu(menuText({ install: { label: "Install" }, "install.zen": { label: "Zen", run: ["true"] }, apps: { provider: "apps" } })).entries);
    const zenApps = model.swapProviderRows(zen.items, zen.itemOrder, "apps", [model.appRow("apps", { id: "zen", name: "Zen Browser" })]);
    same(model.searchRows(zenApps.items, zenApps.itemOrder, "root", "zen", []).map(r => [r.kind, r.label]), [["app", "Zen Browser"], ["action", "Zen"]], "an app named with the whole word beats an exact menu label");
    const reboot = model.searchRows(again.items, again.itemOrder, "root", "reb", []);
    same(reboot.map(r => [r.label, r.detail, r.section]), [["Reboot", "Power", ""]]);
    const re = model.searchRows(again.items, again.itemOrder, "root", "re", []);
    same(re.map(r => [r.label, r.section]), [["Remove", ""], ["Reboot", "drilldown"], ["Screenshot", "drilldown"]]);
    same(model.searchRows(again.items, again.itemOrder, "system", "lock", []).map(r => r.label), ["Lock"]);
    assert.equal(model.matchesQuery(alone.items.system, "power"), true, "an alias matches");
    assert.equal(model.matchesQuery(again.items["tools.screenshot"], "region"), true, "a whole description word matches");
    assert.equal(model.matchesQuery(again.items["tools.screenshot"], "regi"), false, "a part of a description word does not");

    // Menu rows: in file order, a menu with no visible row hidden, apps by
    // label, a missing command named.
    const roots = model.menuRows(again.items, again.itemOrder, "root", []);
    same(roots.map(r => r.label), ["Apps", "Style", "Power", "Tools", "Install", "Remove", "Update"]);
    const lacking = model.menuRows(again.items, again.itemOrder, "tools", ["grim"]);
    same(lacking.filter(r => r.kind === "unavailable").map(r => [r.label, r.detail]), [["Screenshot", "needs grim"]]);
    const empty = model.mergeMenuSources([], model.parseMenu(menuText({ bare: {} })).entries);
    same(model.menuRows(empty.items, empty.itemOrder, "root", []), [], "a static menu with no row is hidden");
    const sorted = model.swapProviderRows(again.items, again.itemOrder, "apps", [model.appRow("apps", { id: "b", name: "beta" }), model.appRow("apps", { id: "a", name: "Alpha" })]);
    same(model.menuRows(sorted.items, sorted.itemOrder, "apps", []).map(r => r.label), ["Alpha", "beta"]);
    assert.equal(model.pathFor(again.items, "system.reboot"), "Power \u203a Reboot");
    assert.equal(model.depthFor(again.items, "system.reboot"), 1);
    const cycle = model.mergeMenuSources([], model.parseMenu(menuText({ a: { parent: "b" }, b: { parent: "a" } })).entries);
    assert.equal(model.depthFor(cycle.items, "a"), 32, "a parent cycle stops at the depth limit");
    assert.equal(model.isDescendantOf(cycle.items, "a", "root"), true);
    assert.equal(model.isDescendantOf(cycle.items, "a", "c"), false);

    // Theme apply results.
    for (const [state, want] of [["applied", true], ["unchanged", true], ["partial", false], ["failed", false], ["", false]])
        assert.equal(model.applySucceeded({ state: state, shell: "unchanged", targets: [], theme: "vgs", reason: null }), want, "apply state " + state);
    assert.equal(model.applySucceeded(null), false, "no result is no success");

    // Payloads.
    const bare = model.parsePayload("", RUNTIME);
    assert.equal(bare.ok, true);
    same([bare.payload.mode, bare.payload.menu, bare.payload.query], ["menu", "root", ""]);
    const pick = model.parsePayload(JSON.stringify({ mode: "select", options: ["a", "b"], selectionFile: RUNTIME + "/s", doneFile: RUNTIME + "/d", width: 420 }), RUNTIME);
    assert.equal(pick.ok, true, pick.error);
    same([pick.payload.prompt, pick.payload.width, pick.payload.options], ["Select", 420, ["a", "b"]]);
    const input = model.parsePayload(JSON.stringify({ mode: "input", selectionFile: RUNTIME + "/s", doneFile: RUNTIME + "/d" }), RUNTIME + "/");
    assert.equal(input.ok, true, input.error);
    assert.equal(input.payload.prompt, "Input");
    for (const [label, text, start] of PAYLOAD_REFUSED) {
        const result = model.parsePayload(text, RUNTIME);
        assert.equal(result.ok, false, label);
        assert.ok(result.error.startsWith(start), `${label}: ${result.error}`);
    }
    assert.equal(model.parsePayload(JSON.stringify({ mode: "select", selectionFile: RUNTIME + "/s", doneFile: RUNTIME + "/d" }), "").ok, false, "no runtime directory admits no file");

    // Options and selections.
    same(model.parseOption("plain"), { icon: "", label: "plain", detail: "" });
    same(model.parseOption("g\tlabel\tdetail\tmore"), { icon: "g", label: "label", detail: "detail\tmore" });
    const options = model.optionRows(["alpha", "g\tbeta\tsecond", "gamma"], "SEC");
    same(options.map(r => [r.itemId, r.label, r.detail]), [["option.1", "beta", "second"]]);
    assert.equal(model.selectionOf(options[0]), "beta\tsecond");
    assert.equal(model.selectionOf({ label: "alpha", detail: "" }), "alpha");
    assert.equal(model.dropWord("open the file "), "open the ");
    assert.equal(model.dropWord("one"), "");

    // File search.
    same(model.fileMode("f: report "), { mode: "f", query: "report" });
    same(model.fileMode("F:docs"), { mode: "d", query: "docs" });
    same(model.fileMode("ff"), { mode: "", query: "" });
    const hits = model.parseFileResults([
        "100\ttext/plain\t/home/u/a/notes.txt",
        "300\ttext/plain\t/home/u/b/notes.txt",
        "200\tinode/directory\t/home/u/docs",
        "junk line",
        "x\ttext/plain\t/home/u/c",
        "1\ttext/plain\trelative/path",
        "50\ttext/plain\t/top.txt",
        ""
    ].join("\n"), "/home/u");
    same(hits.rows.map(r => [r.name, r.dir, r.mtime]), [["notes.txt", "~/b", 300], ["notes.txt", "~/a", 100], ["docs", "~", 200], ["top.txt", "/", 50]]);
    assert.equal(hits.malformed, 3);
    const constructor = model.parseFileResults("1\ttext/plain\t/x/constructor", "/home/u");
    same(constructor.rows.map(r => r.name), ["constructor"], "a file named like an object key is a name");
    const apps = model.parseOpenWith("other\t/usr/share/applications/b.desktop\ndefault\t/usr/share/applications/a.desktop\nnoise\n");
    same(apps.map(a => [a.id, a.isDefault]), [["a", true], ["b", false]]);
}
verify(load(file));

// Each control removes one rule from a copy of the model and keeps the
// text around it. The suite must fail on every copy.
const CONTROLS = [
    ["unknown item key", "if (ITEM_KEYS.indexOf(keys[i]) === -1) return at", "if (false) return at"],
    ["run list", 'if (hasOwn(raw, "run") && !(isStringList(raw.run) && raw.run.length > 0))', 'if (false)'],
    ["requires names", 'if (hasOwn(raw, "requires") && !isStringList(raw.requires, COMMAND_PATTERN))', "if (false)"],
    ["schema version", "if (document.schemaVersion !== SCHEMA_VERSION)", "if (false)"],
    ["merge per key", "merged[entry.id][key] = entry.raw[key];", "merged[entry.id] = entry.raw;"],
    ["one kind per row", "if (stated.length > 1)", "if (false)"],
    ["exact id first", "if (hasOwn(items, raw)) return raw;", ""],
    ["apps are no route", 'if (entry.kind === "app") continue;\n        for', "for"],
    ["handed maps unwritten", "var row = Object.assign({}, rows[j], { providerMenu: menuId, order: nextOrder.length });", "var row = rows[j]; row.providerMenu = menuId; row.order = nextOrder.length; items[row.id] = row;"],
    ["taken id once", "if (hasOwn(nextItems, rows[j].id)) continue;", ""],
    ["whole app word", 'else if (entry.kind === "app" && label.split(/\\s+/).indexOf(needle) >= 0) score = 0;', ""],
    ["drilldown section", 'for (var d = 0; d < deeper.length; d++) deeper[d].section = "drilldown";', ""],
    ["missing command", 'kind: lacking !== "" ? "unavailable" : entry.kind,', "kind: entry.kind,"],
    ["hidden empty menu", "if (child.parent === target && isVisible(items, itemOrder, child, guard + 1)) return true;", "return true;"],
    ["depth limit", "while (current && current.parent && current.parent !== \"root\" && depth < DEPTH_LIMIT)", "while (current && current.parent && current.parent !== \"root\" && depth < 1000)"],
    ["payload unknown key", "if (PAYLOAD_KEYS.indexOf(keys[i]) === -1) return", "if (false) return"],
    ["payload inside runtime", "if (!insideDirectory(file, runtimeDir))", "if (false)"],
    ["payload no climbing", 'if (parts[i] === "" || parts[i] === "." || parts[i] === "..") return false;', ""],
    ["payload distinct files", "if (raw.selectionFile === raw.doneFile)", "if (false)"],
    ["payload options ceiling", "if (options.length > OPTIONS_MAX)", "if (false)"],
    ["option glyph", 'var icon = parts.length > 1 ? parts.shift() : "";', 'var icon = "";'],
    ["newest first", "return b.mtime - a.mtime;", "return 0;"],
    ["malformed counted", 'if (parts.length < 3 || !/^[0-9]+$/.test(parts[0]) || path.charAt(0) !== "/") {', "if (parts.length < 3) {"],
    ["default first", "return (b.isDefault ? 1 : 0) - (a.isDefault ? 1 : 0);", "return 0;"],
    ["unchanged apply succeeds", '(result.state === "applied" || result.state === "unchanged")', '(result.state === "applied")'],
    ["only success succeeds", '(result.state === "applied" || result.state === "unchanged")', '(result.state !== "failed")']
];

const source = fs.readFileSync(file, "utf8");
const temp = fs.mkdtempSync(path.join(os.tmpdir(), "launcher-model-control-"));
try {
    for (const [label, needle, replacement] of CONTROLS) {
        assert.equal(source.split(needle).length, 2, `control "${label}": the text to replace must occur once`);
        const mutant = path.join(temp, "MenuModel.js");
        fs.writeFileSync(mutant, source.replace(needle, () => replacement));
        let failed = false;
        try {
            verify(load(mutant));
        } catch (e) {
            failed = true;
        }
        assert.ok(failed, `control "${label}": the suite passed on a model without that rule`);
    }
} finally {
    fs.rmSync(temp, { recursive: true, force: true });
}
console.log(`test-launcher-model: ok menus=${MENU_REFUSED.length} payloads=${PAYLOAD_REFUSED.length} controls=${CONTROLS.length}`);
