#!/usr/bin/env node
// The target renderer, bin/lib/theme-render.js, with the shell's theme
// judge and token table. Every expected text below was written by hand from
// the colour it names, never read from the renderer.
//
// The controls at the end edit a copy of the renderer, one rule at a time,
// and require this suite to fail on each copy.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { load } = require("./qml-library.js");

const repo = path.join(__dirname, "..");
const rendererFile = path.join(repo, "bin", "lib", "theme-render.js");
const logic = load(path.join(repo, "shell", "Commons", "ThemeLogic.js"));
const TOKENS = load(path.join(repo, "shell", "Commons", "Tokens.js")).TOKENS;

// The probe package overrides palette.accent to #123456 and has no
// terminal.json; the defaults' slot N is #0000NN in hex.
const slotsJson = colour => JSON.stringify({ schemaVersion: 1, slots: Object.fromEntries(Array.from({ length: 16 }, (_, i) => [`color${i}`, colour(i)])) });
const probe = logic.acceptPackage(TOKENS, {
    directoryName: "probe",
    themeJson: JSON.stringify({ schemaVersion: 1, name: "probe", tokens: { palette: { accent: "#123456" } } }),
    terminalJson: undefined,
    shipped: false
});
const defaults = logic.acceptPackage(TOKENS, {
    directoryName: "vgs",
    themeJson: JSON.stringify({ schemaVersion: 1, name: "vgs", tokens: {} }),
    terminalJson: slotsJson(i => "#0000" + i.toString(16).padStart(2, "0")),
    shipped: true
});
const own = logic.acceptPackage(TOKENS, {
    directoryName: "own",
    themeJson: JSON.stringify({ schemaVersion: 1, name: "own", tokens: {} }),
    terminalJson: slotsJson(() => "#abcdef"),
    shipped: false
});
// A package that states it is light; every other package here is dark.
const lit = logic.acceptPackage(TOKENS, {
    directoryName: "lit",
    themeJson: JSON.stringify({ schemaVersion: 1, name: "lit", tokens: { scheme: { mode: "light" } } }),
    terminalJson: undefined,
    shipped: false
});
for (const pkg of [probe, defaults, own, lit]) assert.equal(pkg.ok, true, pkg.ok ? "" : logic.refusalLine(pkg));

const wiring = { file: "probe/probe.conf", line: "include=@{state}/probe.conf", create: true };
// An entry wiring: links in the application's own directory, never a file
// edit. Two files so a link can name either.
const entry = { base: "config", dir: "probe/themes", owned: false, links: { "vgs.conf": "probe.conf" } };
const twoFiles = [{ template: "a.conf", destination: "probe.conf" }, { template: "b.json", destination: "probe.pkg.json" }];
const entryText = (fields = {}) => targetText({ files: twoFiles, wiring: Object.assign({}, entry, fields) });
const targetText = (fields = {}) => JSON.stringify(Object.assign({
    app: "Probe",
    encoder: "hex6",
    files: [{ template: "probe.conf", destination: "probe.conf" }],
    detect: ["probe"],
    wiring,
    reload: { command: ["probe", "--reload"], timeoutMs: 2000 }
}, fields));

// Accepted targets: the name, the document text.
const ACCEPTED_TARGETS = [
    ["probe", targetText()],
    ["probe", targetText({ reload: null, detect: [], wiring: Object.assign({}, wiring, { create: false }) })],
    ["probe", targetText({ detect: [["probe", "probe-bin"]] })],
    ["probe", targetText({ detect: ["probe", ["probe-a", "probe-b"]] })],
    ["probe-2", targetText({ files: [{ template: "a.conf", destination: "probe-2.conf" }, { template: "a.conf", destination: "probe-2.extra.ini" }] })],
    ["probe", targetText({ wiring: Object.assign({}, wiring, { section: "general" }) })],
    ["probe", targetText({ wiring: Object.assign({}, wiring, { section: "Main_2-b" }) })],
    ["probe", targetText({ files: [{ template: "probe.conf", destination: "probe.conf", curatedKeys: ["colors", "tokenColors"] }] })],
    ["probe", entryText()],
    ["probe", entryText({ base: "home", dir: ".probe/extensions/vgs-theme", owned: true, links: { "package.json": "probe.pkg.json", "vgs-color-theme.json": "probe.conf" } })],
    ["probe", targetText({ wiring: null })],
    ["probe", targetText({ reload: { command: ["probe", "--file=@{state}/probe.conf", "@@{x}"], timeoutMs: 2000, always: true } })],
    ["probe", targetText({ reload: { command: ["probe"], timeoutMs: 2000, always: false } })],
    ["probe", entryText({ base: "cache", dir: "wal" })],
    ["probe", targetText({ wiring: Object.assign({}, wiring, { file: "chrome/userChrome.css", profiles: [".zen/profiles.ini", ".config/zen/profiles.ini"] }) })],
    ["probe", targetText({ wiring: Object.assign({}, wiring, { section: "general", profiles: ["profiles.ini"] }) })],
    ["probe", targetText({ wiring: Object.assign({}, wiring, { fallbacks: [".config/probe/probe.conf", ".probe.conf"] }) })],
    ["probe", targetText({ wiring: Object.assign({}, wiring, { fallbacks: [".probe.conf"] }), reload: { command: ["touch", "-c", "--", "@{wiring}", "@{state}", "@@{x}"], timeoutMs: 2000 } })],
    ["probe", entryText({ dir: ".obsidian/themes/vgs", owned: true, vaults: "obsidian/obsidian.json" })],
    ["probe", entryText({ base: "home", dir: ".probe", vaults: ".probe-vaults.json" })]
];

// Refused targets: the name, the document text, the reason, the detail.
const REFUSED_TARGETS = [
    ["Probe", targetText(), "target-name", 'got="Probe"'],
    ["pro.be", targetText(), "target-name", 'got="pro.be"'],
    ["probe", "{", "target-json", ""],
    ["probe", "[]", "target-schema", "key=document"],
    ["probe", targetText({ file: "probe.conf" }), "target-schema", "unknown=file"],
    ["probe", JSON.stringify({ app: "Probe", encoder: "hex6", files: [], detect: [], wiring }), "target-schema", "missing=reload"],
    ["probe", targetText({ app: "" }), "target-schema", "key=app"],
    ["probe", targetText({ app: "Pro\nbe" }), "target-schema", "key=app"],
    ["probe", targetText({ encoder: "hex" }), "target-schema", "key=encoder"],
    ["probe", targetText({ files: [] }), "target-schema", "key=files"],
    ["probe", targetText({ files: [{ template: "probe.conf" }] }), "target-schema", "key=files[0]"],
    ["probe", targetText({ files: [{ template: "../probe.conf", destination: "probe.conf" }] }), "target-schema", "key=files[0].template"],
    ["probe", targetText({ files: [{ template: "target.json", destination: "probe.conf" }] }), "target-schema", "key=files[0].template"],
    ["probe", targetText({ files: [{ template: "probe.conf", destination: "other.conf" }] }), "target-schema", "key=files[0].destination"],
    ["probe", targetText({ files: [{ template: "probe.conf", destination: "probe.c/f" }] }), "target-schema", "key=files[0].destination"],
    ["probe", targetText({ files: [{ template: "a", destination: "probe.conf" }, { template: "b", destination: "probe.conf" }] }), "target-schema", "key=files[1].destination"],
    ["probe", targetText({ files: [{ template: "probe.conf", destination: "probe.conf", curated: ["colors"] }] }), "target-schema", "key=files[0]"],
    ["probe", targetText({ files: [{ template: "probe.conf", destination: "probe.conf", curatedKeys: [] }] }), "target-schema", "key=files[0].curatedKeys"],
    ["probe", targetText({ files: [{ template: "probe.conf", destination: "probe.conf", curatedKeys: "colors" }] }), "target-schema", "key=files[0].curatedKeys"],
    ["probe", targetText({ files: [{ template: "probe.conf", destination: "probe.conf", curatedKeys: [""] }] }), "target-schema", "key=files[0].curatedKeys"],
    ["probe", targetText({ detect: ["probe --version"] }), "target-schema", "key=detect"],
    ["probe", targetText({ detect: "probe" }), "target-schema", "key=detect"],
    ["probe", targetText({ detect: [[]] }), "target-schema", "key=detect"],
    ["probe", targetText({ detect: [["probe", "probe --version"]] }), "target-schema", "key=detect"],
    ["probe", targetText({ detect: [["probe", ["probe-bin"]]] }), "target-schema", "key=detect"],
    ["probe", targetText({ detect: [[["probe"]]] }), "target-schema", "key=detect"],
    ["probe", targetText({ wiring: { file: "probe/probe.conf", line: "include=@{state}/probe.conf" } }), "target-schema", "key=wiring"],
    ["probe", targetText({ wiring: Object.assign({}, wiring, { file: "../probe.conf" }) }), "target-schema", "key=wiring.file"],
    ["probe", targetText({ wiring: Object.assign({}, wiring, { file: "/etc/probe.conf" }) }), "target-schema", "key=wiring.file"],
    ["probe", targetText({ wiring: Object.assign({}, wiring, { line: "include=~/.local/state/vgs/theme/probe.conf" }) }), "target-schema", "key=wiring.line"],
    ["probe", targetText({ wiring: Object.assign({}, wiring, { line: "include=@{palette.accent}" }) }), "target-schema", "key=wiring.line"],
    ["probe", targetText({ wiring: Object.assign({}, wiring, { line: "include=@{state}/a\ninclude=b" }) }), "target-schema", "key=wiring.line"],
    ["probe", targetText({ wiring: Object.assign({}, wiring, { create: "yes" }) }), "target-schema", "key=wiring.create"],
    ["probe", targetText({ wiring: Object.assign({}, wiring, { sections: "general" }) }), "target-schema", "key=wiring"],
    ["probe", targetText({ wiring: { file: "probe/probe.conf", line: "include=@{state}/probe.conf", section: "general" } }), "target-schema", "key=wiring"],
    ["probe", targetText({ wiring: Object.assign({}, wiring, { section: "" }) }), "target-schema", "key=wiring.section"],
    ["probe", targetText({ wiring: Object.assign({}, wiring, { section: "colors.primary" }) }), "target-schema", "key=wiring.section"],
    ["probe", targetText({ wiring: Object.assign({}, wiring, { section: "[general]" }) }), "target-schema", "key=wiring.section"],
    ["probe", targetText({ wiring: Object.assign({}, wiring, { section: null }) }), "target-schema", "key=wiring.section"],
    ["probe", targetText({ wiring: Object.assign({}, wiring, { profile: ".zen/profiles.ini" }) }), "target-schema", "key=wiring"],
    ["probe", targetText({ wiring: Object.assign({}, wiring, { profiles: ".zen/profiles.ini" }) }), "target-schema", "key=wiring.profiles"],
    ["probe", targetText({ wiring: Object.assign({}, wiring, { profiles: [] }) }), "target-schema", "key=wiring.profiles"],
    ["probe", targetText({ wiring: Object.assign({}, wiring, { profiles: [""] }) }), "target-schema", "key=wiring.profiles"],
    ["probe", targetText({ wiring: Object.assign({}, wiring, { profiles: ["/home/u/.zen/profiles.ini"] }) }), "target-schema", "key=wiring.profiles"],
    ["probe", targetText({ wiring: Object.assign({}, wiring, { profiles: [".zen/profiles.ini", "../.zen/profiles.ini"] }) }), "target-schema", "key=wiring.profiles"],
    ["probe", targetText({ wiring: Object.assign({}, wiring, { profiles: [".zen//profiles.ini"] }) }), "target-schema", "key=wiring.profiles"],
    ["probe", targetText({ wiring: Object.assign({}, wiring, { profiles: [[".zen/profiles.ini"]] }) }), "target-schema", "key=wiring.profiles"],
    ["probe", targetText({ wiring: Object.assign({}, wiring, { fallbacks: ".probe.conf" }) }), "target-schema", "key=wiring.fallbacks"],
    ["probe", targetText({ wiring: Object.assign({}, wiring, { fallbacks: [] }) }), "target-schema", "key=wiring.fallbacks"],
    ["probe", targetText({ wiring: Object.assign({}, wiring, { fallbacks: [""] }) }), "target-schema", "key=wiring.fallbacks"],
    ["probe", targetText({ wiring: Object.assign({}, wiring, { fallbacks: ["/home/u/.probe.conf"] }) }), "target-schema", "key=wiring.fallbacks"],
    ["probe", targetText({ wiring: Object.assign({}, wiring, { fallbacks: [".config/probe.conf", "../.probe.conf"] }) }), "target-schema", "key=wiring.fallbacks"],
    ["probe", targetText({ wiring: Object.assign({}, wiring, { fallbacks: [".config//probe.conf"] }) }), "target-schema", "key=wiring.fallbacks"],
    ["probe", targetText({ wiring: Object.assign({}, wiring, { fallbacks: [[".probe.conf"]] }) }), "target-schema", "key=wiring.fallbacks"],
    ["probe", targetText({ wiring: Object.assign({}, wiring, { profiles: ["profiles.ini"], fallbacks: [".probe.conf"] }) }), "target-schema", "key=wiring.fallbacks"],
    ["probe", entryText({ profiles: [".zen/profiles.ini"] }), "target-schema", "key=wiring"],
    ["probe", entryText({ fallbacks: [".probe.conf"] }), "target-schema", "key=wiring"],
    ["probe", entryText({ line: "include=@{state}/probe.conf" }), "target-schema", "key=wiring"],
    ["probe", entryText({ vault: "obsidian/obsidian.json" }), "target-schema", "key=wiring"],
    ["probe", targetText({ wiring: Object.assign({}, wiring, { vaults: "obsidian/obsidian.json" }) }), "target-schema", "key=wiring"],
    ["probe", entryText({ vaults: "" }), "target-schema", "key=wiring.vaults"],
    ["probe", entryText({ vaults: "/home/u/.config/obsidian/obsidian.json" }), "target-schema", "key=wiring.vaults"],
    ["probe", entryText({ vaults: "../obsidian.json" }), "target-schema", "key=wiring.vaults"],
    ["probe", entryText({ vaults: "obsidian//obsidian.json" }), "target-schema", "key=wiring.vaults"],
    ["probe", entryText({ vaults: ["obsidian/obsidian.json"] }), "target-schema", "key=wiring.vaults"],
    ["probe", targetText({ files: twoFiles, wiring: { base: "config", dir: "probe", links: { "vgs.conf": "probe.conf" } } }), "target-schema", "key=wiring"],
    ["probe", entryText({ base: "state" }), "target-schema", "key=wiring.base"],
    ["probe", entryText({ dir: "../probe" }), "target-schema", "key=wiring.dir"],
    ["probe", entryText({ dir: "probe/./themes" }), "target-schema", "key=wiring.dir"],
    ["probe", entryText({ dir: "/etc/probe" }), "target-schema", "key=wiring.dir"],
    ["probe", entryText({ dir: 3 }), "target-schema", "key=wiring.dir"],
    ["probe", entryText({ owned: "no" }), "target-schema", "key=wiring.owned"],
    ["probe", entryText({ links: {} }), "target-schema", "key=wiring.links"],
    ["probe", entryText({ links: ["probe.conf"] }), "target-schema", "key=wiring.links"],
    ["probe", entryText({ links: { "../vgs.conf": "probe.conf" } }), "target-schema", "key=wiring.links.../vgs.conf"],
    ["probe", entryText({ links: { "vgs.conf": "other.conf" } }), "target-schema", "key=wiring.links.vgs.conf"],
    ["probe", targetText({ reload: { command: ["probe"] } }), "target-schema", "key=reload"],
    ["probe", targetText({ reload: { command: [], timeoutMs: 2000 } }), "target-schema", "key=reload.command"],
    ["probe", targetText({ reload: { command: ["probe"], timeoutMs: 0 } }), "target-schema", "key=reload.timeoutMs"],
    ["probe", targetText({ reload: { command: ["probe"], timeoutMs: 1.5 } }), "target-schema", "key=reload.timeoutMs"],
    ["probe", targetText({ reload: { command: ["probe"], always: true } }), "target-schema", "key=reload"],
    ["probe", targetText({ reload: { command: ["probe"], timeoutMs: 2000, often: true } }), "target-schema", "key=reload"],
    ["probe", targetText({ reload: { command: ["probe"], timeoutMs: 2000, always: "yes" } }), "target-schema", "key=reload.always"],
    ["probe", targetText({ reload: { command: ["probe", "@{palette.accent}"], timeoutMs: 2000 } }), "target-schema", "key=reload.command"],
    ["probe", targetText({ reload: { command: ["probe", "@{state"], timeoutMs: 2000 } }), "target-schema", "key=reload.command"],
    ["probe", targetText({ wiring: Object.assign({}, wiring, { profiles: ["profiles.ini"] }), reload: { command: ["probe", "@{wiring}"], timeoutMs: 2000 } }), "target-schema", "key=reload.command"],
    ["probe", targetText({ files: twoFiles, wiring: entry, reload: { command: ["probe", "@{wiring}"], timeoutMs: 2000 } }), "target-schema", "key=reload.command"],
    ["probe", targetText({ wiring: null, reload: { command: ["probe", "@{wiring}"], timeoutMs: 2000 } }), "target-schema", "key=reload.command"],
    ["probe", targetText({ wiring: "none" }), "target-schema", "key=wiring"]
];

// One colour through each encoder: the defaults' color.selection is
// alpha(#ff5a36, 0.35), #ff5a3659; 0x59 = 89 and 89 / 255 = 0.349.
const ENCODED = [
    ["hex6", "ff5a36"],
    ["hex8", "ff5a3659"],
    ["rgba", "rgba(255, 90, 54, 0.349)"],
    ["hyprland", "rgba(ff5a3659)"]
];

// Templates under the hex6 encoder against the probe package and the
// defaults' slots: the template, the rendered text.
const RENDERED = [
    ["accent=@{palette.accent}\n", "accent=123456\n"],
    ["@@{palette.accent}", "@{palette.accent}"],
    ["@@@{palette.accent}", "@@{palette.accent}"],
    ["set -g status-left '#{pane_id} ${HOME} {palette.accent} @ @@ #@{palette.accent}'", "set -g status-left '#{pane_id} ${HOME} {palette.accent} @ @@ #123456'"],
    ["gap=@{space.sm}px font=@{font.family.mono}", "gap=6px font=JetBrains Mono"],
    ["regular1=@{terminal.color1} bright15=@{terminal.color15}", "regular1=000001 bright15=00000f"],
    ["", ""]
];

// The mode, bare and through cases, under a dark and a light package: the
// package, the template, the rendered text.
const MODES = [
    [probe, "@{scheme.mode}", "dark"],
    [lit, "@{scheme.mode}", "light"],
    [probe, "@{scheme.mode|dark=vs-dark|light=vs}", "vs-dark"],
    [lit, "@{scheme.mode|dark=vs-dark|light=vs}", "vs"],
    [lit, "@{scheme.mode|light=a=b|dark=c}", "a=b"]
];

// Templates that refuse the target: the template, the detail.
const REFUSED_TEMPLATES = [
    ["@{scheme.mode|dark=vs-dark}", 'template=probe.conf placeholder="scheme.mode|dark=vs-dark"'],
    ["@{scheme.mode|dark=a|dim=c}", 'template=probe.conf placeholder="scheme.mode|dark=a|dim=c"'],
    ["@{scheme.mode|dark=a|light=b|dark=c}", 'template=probe.conf placeholder="scheme.mode|dark=a|light=b|dark=c"'],
    ["@{scheme.mode|dark=|light=b}", 'template=probe.conf placeholder="scheme.mode|dark=|light=b"'],
    ["@{scheme.mode|dark|light=b}", 'template=probe.conf placeholder="scheme.mode|dark|light=b"'],
    ["@{palette.accent|dark=a|light=b}", 'template=probe.conf placeholder="palette.accent|dark=a|light=b"'],
    ["@{terminal.color1|dark=a|light=b}", 'template=probe.conf placeholder="terminal.color1|dark=a|light=b"'],
    ["@{palette.nope}", 'template=probe.conf placeholder="palette.nope"'],
    ["@{palette}", 'template=probe.conf placeholder="palette"'],
    ["@{}", 'template=probe.conf placeholder=""'],
    ["@{terminal.color16}", 'template=probe.conf placeholder="terminal.color16"'],
    ["@{state}", 'template=probe.conf placeholder="state"'],
    ["ok @{palette.accent} then @{palette.accent", "template=probe.conf unterminated=26"]
];

// A configuration file's text before the wiring, and after it, or null when
// the line already stands on a line of its own.
const LINE = "include=/s/foot.ini";
const WIRED = [
    [undefined, "include=/s/foot.ini\n"],
    ["", "include=/s/foot.ini\n"],
    ["[main]\nfont=x\n", "include=/s/foot.ini\n[main]\nfont=x\n"],
    ["font=x", "include=/s/foot.ini\nfont=x"],
    ["font=x\ninclude=/s/foot.ini\n[colors]\n", null],
    ["include=/s/foot.ini", null],
    ["# include=/s/foot.ini\n", "include=/s/foot.ini\n# include=/s/foot.ini\n"],
    ["include=/s/foot.ini.old\n", "include=/s/foot.ini\ninclude=/s/foot.ini.old\n"]
];

// A configuration file's text before the wiring into the `general` section,
// and after it, or null when the line already stands on a line of its own.
const TOML_LINE = 'import = ["/s/alacritty.toml"]';
const WIRED_SECTION = [
    [undefined, '[general]\nimport = ["/s/alacritty.toml"]\n'],
    ["", '[general]\nimport = ["/s/alacritty.toml"]\n'],
    ["[window]\nx = 1\n", '[window]\nx = 1\n[general]\nimport = ["/s/alacritty.toml"]\n'],
    ["[window]\nx = 1", '[window]\nx = 1\n[general]\nimport = ["/s/alacritty.toml"]\n'],
    ["[general]\nlive = true\n[window]\n", '[general]\nimport = ["/s/alacritty.toml"]\nlive = true\n[window]\n'],
    ["[window]\n  [ general ]  # mine\nlive = true", '[window]\n  [ general ]  # mine\nimport = ["/s/alacritty.toml"]\nlive = true'],
    ["[general]\n[general]\n", '[general]\nimport = ["/s/alacritty.toml"]\n[general]\n'],
    ["[general.more]\n[[general]]\n# [general]\n[generalx]\n", '[general.more]\n[[general]]\n# [general]\n[generalx]\n[general]\nimport = ["/s/alacritty.toml"]\n'],
    ["[general]\nlive = true\n[window]\nimport = [\"a\"]\n", '[general]\nimport = ["/s/alacritty.toml"]\nlive = true\n[window]\nimport = ["a"]\n'],
    ["[general]\n[[general.x]]\nimport = [\"a\"]\n", '[general]\nimport = ["/s/alacritty.toml"]\n[[general.x]]\nimport = ["a"]\n'],
    ["[window]\ngeneral.x = 1\n", '[window]\ngeneral.x = 1\n[general]\nimport = ["/s/alacritty.toml"]\n'],
    ['[window]\n[general]\nimport = ["/s/alacritty.toml"]\n', null],
    ['import = ["/s/alacritty.toml"]', null],
    // The section's own one-line import array takes the theme first, so the
    // file's own imports, read after it, override it.
    ['[general]\nimport = ["~/.config/alacritty/theme.toml"]\n', '[general]\nimport = ["/s/alacritty.toml", "~/.config/alacritty/theme.toml"]\n'],
    ['[general]\nimport = ["/old/state/alacritty.toml"]\n', '[general]\nimport = ["/s/alacritty.toml", "/old/state/alacritty.toml"]\n'],
    ['[window]\n[general]\nlive = true\n  import=["a"] # mine\n[window]\n', '[window]\n[general]\nlive = true\n  import=["/s/alacritty.toml", "a"] # mine\n[window]\n'],
    ["[general]\nimport = [ \"a\" , 'b', ]\t# ] mine\n", "[general]\nimport = [ \"/s/alacritty.toml\", \"a\" , 'b', ]\t# ] mine\n"],
    ['[general]\nimport = []\n', '[general]\nimport = ["/s/alacritty.toml"]\n'],
    ['[general]\nimport = [ ]\n', '[general]\nimport = [ "/s/alacritty.toml"]\n'],
    ['[general]\r\nimport = ["a"]\r\n', '[general]\r\nimport = ["/s/alacritty.toml", "a"]\r\n'],
    ['[general]\nimport = ["~/q\\"].toml", "b"]\n', '[general]\nimport = ["/s/alacritty.toml", "~/q\\"].toml", "b"]\n'],
    ["[general]\nimport = ['C:\\', \"b\"]\n", "[general]\nimport = [\"/s/alacritty.toml\", 'C:\\', \"b\"]\n"],
    ['[general]\nimport = ["a", "/s/alacritty.toml"]\n', null]
];

// A configuration file the wiring into `general` would give a key twice:
// its text, the refusal's detail.
const CONFLICTS = [
    ['[general]\nimport = [\n  "~/a.toml",\n]\n', "section=general key=import"],
    ['[general]\nimport = "~/a.toml"\n', "section=general key=import"],
    ["[general]\nimport = '\"a\"] #'\n", "section=general key=import"],
    ['[general]\nimport = [1, 1]\n', "section=general key=import"],
    ['[general]\nimport = ["a" "b"]\n', "section=general key=import"],
    ['[general]\nimport = ["a"] x\n', "section=general key=import"],
    ['[general]\nimport = ["a"]\nimport = ["b"]\n', "section=general key=import"],
    ['[general]\nimport = [\"\"\"a\"\"\"]\n', "section=general key=import"],
    ["general.live = true\n[window]\n", "section=general key=general"],
    ["general = { live = true }\n", "section=general key=general"]
];

// A wiring line that assigns no one-line array of one string, which a file
// whose `general` assigns its key refuses.
const CONFLICT_LINES = ['import = ["/s/x", "/s/y"]', 'import = "/s/x"'];

// A configuration file's text before the line is removed, and after it, or
// null when no line of it is the include line.
const UNWIRED = [
    [undefined, null],
    ["", null],
    ["[main]\nfont=x\n", null],
    ["# include=/s/foot.ini\ninclude=/s/foot.ini.old\n", null],
    ["include=/s/foot.ini\n[main]\nfont=x\n", "[main]\nfont=x\n"],
    ["include=/s/foot.ini\nfont=x", "font=x"],
    ["include=/s/foot.ini\n", ""],
    ["font=x\ninclude=/s/foot.ini\n[colors]\ninclude=/s/foot.ini\n", "font=x\n[colors]\n"],
    ["[window]\n[general]\ninclude=/s/foot.ini\n", "[window]\n[general]\n"]
];

// A configuration file's text before the wiring into `general` is removed,
// and after it, or null when neither the line nor its string stands there.
const UNWIRED_SECTION = [
    [undefined, null],
    ['[general]\nimport = ["/s/alacritty.toml"]\nlive = true\n', '[general]\nlive = true\n'],
    ['[general]\nimport = ["/s/alacritty.toml", "~/a.toml"]\n', '[general]\nimport = ["~/a.toml"]\n'],
    ['[general]\nimport = ["a", "/s/alacritty.toml"]\n', '[general]\nimport = ["a"]\n'],
    ['[general]\nimport = [ "/s/alacritty.toml"]\n', '[general]\nimport = [ ]\n'],
    ['[general]\nimport = ["/s/alacritty.toml",]\n', '[general]\nimport = []\n'],
    ['[general]\nimport = ["/s/alacritty.toml", "a", "/s/alacritty.toml"] # mine\n', '[general]\nimport = ["a"] # mine\n'],
    ['[general]\nx = 1\n[window]\nimport = ["/s/alacritty.toml", "a"]\n', null],
    ['[general]\nx = 1\n[general]\nimport = ["/s/alacritty.toml", "a"]\n', null],
    ['[general]\nother = ["/s/alacritty.toml", "a"]\n', null],
    ['[general]\nimport = ["/s/alacritty.toml.old", "a"]\n', null],
    ['[general]\nimport = [\n  "/s/alacritty.toml",\n]\n', null],
    ['import = ["/s/alacritty.toml", "a"]\n', null]
];

// A Mozilla profiles.ini's text, and the profile directories it lists.
const REL = path => ({ path, relative: true });
const ABS = path => ({ path, relative: false });
const PROFILES = [
    ["", []],
    ["[General]\nStartWithLastProfile=1\nVersion=2\n\n[Profile0]\nName=default\nIsRelative=1\nPath=a1b2.Default (release)\nDefault=1\n", [REL("a1b2.Default (release)")]],
    ["[Profile1]\nIsRelative=0\nPath=/srv/zen/p1\n[Profile0]\nIsRelative=1\nPath=Profiles/p0\n", [ABS("/srv/zen/p1"), REL("Profiles/p0")]],
    ["[Profile0]\r\nIsRelative=1\r\nPath=p0\r\n", [REL("p0")]],
    [" [ Profile0 ] \n IsRelative = 1 \n Path = p0 \n", [REL("p0")]],
    ["[Profile0]\nIsRelative=1\nPath=a=b\n", [REL("a=b")]],
    ["[Profile0]\nPath=/srv/p0\n", [ABS("/srv/p0")]],
    ["Path=/outside\n[Install4F96D1932A9F858E]\nDefault=p0\nPath=/install\n[General]\nPath=/general\n[ProfileX]\nPath=/x\n", []],
    ["[Profile0]\nName=no-path\nIsRelative=1\n", []],
    ["[Profile0]\nIsRelative=1\nPath=\n", []],
    ["[Profile0]\nIsRelative=0\nPath=relative/p0\n", []],
    ["[Profile0]\nIsRelative=true\nPath=relative/p0\n", []]
];

// An Obsidian vault registry's text, and the vault directories it lists;
// null for a registry no vault list can be read from.
const VAULTS = [
    ["{}", []],
    ['{"vaults":{}}', []],
    ['{"vaults":{"a1b2":{"path":"/home/u/Notes","ts":1,"open":true},"c3d4":{"path":"/srv/Work Vault"}},"updateDisabled":true}', ["/home/u/Notes", "/srv/Work Vault"]],
    ['{"vaults":{"a":{"path":"/n"},"b":{"path":"/n"},"c":{"path":"/m"}}}', ["/n", "/m"]],
    ['{"vaults":{"a":{"path":"Notes"},"b":{"path":""},"c":{"path":3},"d":"/x","e":null,"f":{"ts":1},"g":{"path":"/ok"}}}', ["/ok"]],
    ["", null],
    ["{", null],
    ["[]", null],
    ['"/n"', null],
    ["null", null],
    ['{"vaults":[{"path":"/n"}]}', null],
    ['{"vaults":"/n"}', null]
];

// Detection: an accepted detect list, the commands on PATH, whether it is met.
// A command entry is required; a list entry is met by any one of its names.
const DETECTED = [
    [[], [], true],
    [["a"], ["a"], true],
    [["a"], [], false],
    [["a", "b"], ["a"], false],
    [["a", "b"], ["a", "b"], true],
    [[["a", "b"]], ["a"], true],
    [[["a", "b"]], ["b"], true],
    [[["a", "b"]], ["a", "b"], true],
    [[["a", "b"]], [], false],
    [[["a", "b"]], ["c"], false],
    [["c", ["a", "b"]], ["b"], false],
    [["c", ["a", "b"]], ["b", "c"], true]
];

function verify(render) {
    const accepted = (name, text) => {
        const result = render.acceptTarget(logic, name, text);
        assert.equal(result.ok, true, `${name} ${text}: ${result.ok ? "" : render.refusalLine(name, result)}`);
        return result.target;
    };
    for (const [name, text] of ACCEPTED_TARGETS) {
        const target = accepted(name, text);
        assert.equal(target.name, name);
        assert.deepEqual(Object.assign({ name }, JSON.parse(text)), target);
    }
    for (const [name, text, reason, detail] of REFUSED_TARGETS) {
        const result = render.acceptTarget(logic, name, text);
        assert.deepEqual(result, { ok: false, reason, detail }, `${name} ${text}`);
    }
    for (const [detect, found, want] of DETECTED)
        assert.equal(render.detected(detect, command => found.includes(command)), want, `${JSON.stringify(detect)} with ${JSON.stringify(found)}`);
    assert.equal(render.refusalLine("probe", { ok: false, reason: "target-schema", detail: "key=app" }), "target=probe reason=target-schema key=app");
    assert.equal(render.refusalLine("probe", { ok: false, reason: "target-json", detail: "" }), "target=probe reason=target-json");

    // The terminal fallback: a package's own slots, else the defaults'.
    assert.equal(render.terminalSource(own, defaults), own);
    assert.equal(render.terminalSource(probe, defaults), defaults);
    assert.equal(render.terminalSource(probe, null), null);
    assert.equal(render.terminalSource(probe, probe), null);
    assert.throws(() => render.terminalSource({ values: {} }, defaults), /without its terminal verdict/);

    const target = (encoder, files) => accepted("probe", targetText(Object.assign({ encoder }, files === undefined ? {} : { files })));
    const one = (encoder, text, pkg = probe, curated = new Map()) => {
        const source = render.terminalSource(pkg, defaults);
        return render.renderTarget(logic, TOKENS, target(encoder), new Map([["probe.conf", text]]), { values: pkg.values, slots: source.terminal, curated });
    };
    const rendered = (encoder, text, pkg, curated) => {
        const result = one(encoder, text, pkg, curated);
        assert.equal(result.ok, true, `${encoder} ${text}: ${result.ok ? "" : render.refusalLine("probe", result)}`);
        assert.equal(result.files.length, 1);
        return result.files[0];
    };

    for (const [encoder, want] of ENCODED) {
        const file = rendered(encoder, "c=@{color.selection}", defaults);
        assert.equal(file.bytes.toString("utf8"), "c=" + want, encoder);
        assert.equal(file.destination, "probe.conf");
        assert.equal(file.curated, false);
    }
    for (const [text, want] of RENDERED)
        assert.equal(rendered("hex6", text).bytes.toString("utf8"), want, text);
    for (const [pkg, text, want] of MODES)
        assert.equal(rendered("hex6", text, pkg).bytes.toString("utf8"), want, `${pkg.values.scheme.mode} ${text}`);
    for (const [text, detail] of REFUSED_TEMPLATES)
        assert.deepEqual(one("hex6", text), { ok: false, reason: "placeholder", detail }, text);

    // A package's own terminal.json wins over the defaults'.
    assert.equal(rendered("hex6", "@{terminal.color1}", own).bytes.toString("utf8"), "abcdef");

    // A curated file is taken byte for byte in place of the rendered one;
    // its template is rendered all the same, so a bad placeholder refuses.
    const curatedBytes = Buffer.from([0x40, 0x7b, 0x6e, 0x6f, 0x7d, 0xff, 0x0a]);
    const curated = rendered("hex6", "accent=@{palette.accent}", probe, new Map([["probe.conf", curatedBytes]]));
    assert.equal(curated.curated, true);
    assert.ok(curated.bytes.equals(curatedBytes));
    assert.deepEqual(one("hex6", "@{palette.nope}", probe, new Map([["probe.conf", curatedBytes]])).reason, "placeholder");

    // With curatedKeys, a curated file is taken only as a JSON object holding
    // one of them; any other file at that name, Omarchy's vscode.json naming
    // an extension included, leaves the render in place.
    const keyed = accepted("probe", targetText({ files: [{ template: "probe.conf", destination: "probe.conf", curatedKeys: ["colors", "tokenColors"] }] }));
    const keyedFile = bytes => {
        const result = render.renderTarget(logic, TOKENS, keyed, new Map([["probe.conf", "a=@{palette.accent}"]]), { values: probe.values, slots: defaults.terminal, curated: new Map([["probe.conf", Buffer.from(bytes)]]) });
        assert.equal(result.ok, true);
        return [result.files[0].bytes.toString("utf8"), result.files[0].curated];
    };
    for (const bytes of ['{ "tokenColors": [] }', '{ "colors": {}, "name": "x" }'])
        assert.deepEqual(keyedFile(bytes), [bytes, true], bytes);
    for (const bytes of ['{ "name": "Tokyo Night", "extension": "enkia.tokyo-night" }', '[{ "colors": {} }]', '{ "colors": {} ', "null", ""])
        assert.deepEqual(keyedFile(bytes), ["a=123456", false], bytes);

    // Several files render in the target's order; a curated file stands in
    // for its own destination only.
    const two = accepted("probe", targetText({ files: [{ template: "a.conf", destination: "probe.conf" }, { template: "b.ini", destination: "probe.extra.ini" }] }));
    const both = render.renderTarget(logic, TOKENS, two, new Map([["a.conf", "a=@{palette.accent}"], ["b.ini", "b=@{palette.accent}"]]),
        { values: probe.values, slots: defaults.terminal, curated: new Map([["probe.extra.ini", Buffer.from("mine")]]) });
    assert.equal(both.ok, true);
    assert.deepEqual(both.files.map(f => [f.destination, f.bytes.toString("utf8"), f.curated]), [["probe.conf", "a=123456", false], ["probe.extra.ini", "mine", true]]);

    assert.throws(() => render.renderTarget(logic, TOKENS, target("hex6"), new Map(), { values: probe.values, slots: defaults.terminal, curated: new Map() }), /was not read/);
    assert.throws(() => render.renderTarget(logic, TOKENS, target("hex6"), new Map([["probe.conf", ""]]), { values: probe.values, slots: null, curated: new Map() }), /without terminal slots/);

    // The wiring line names the state directory; `@@{` stays a literal.
    assert.equal(render.wiringLine(target("hex6"), "/s/vgs/theme"), "include=/s/vgs/theme/probe.conf");
    const escaped = accepted("probe", targetText({ wiring: Object.assign({}, wiring, { line: "a=@@{x} source @{state}/b @{state}/c" }) }));
    assert.equal(render.wiringLine(escaped, "/s"), "a=@{x} source /s/b /s/c");
    for (const [text, want] of WIRED)
        assert.equal(render.wiredText(text, LINE), want, JSON.stringify(text));
    for (const [text, want] of WIRED_SECTION)
        assert.equal(render.wiredText(text, TOML_LINE, "general"), want, JSON.stringify(text));
    for (const [text, detail] of CONFLICTS)
        assert.deepEqual(render.wiredText(text, TOML_LINE, "general"), { ok: false, reason: "wiring-conflict", detail }, JSON.stringify(text));
    for (const line of CONFLICT_LINES)
        assert.deepEqual(render.wiredText('[general]\nimport = ["a"]\n', line, "general"), { ok: false, reason: "wiring-conflict", detail: "section=general key=import" }, line);
    for (const [text, want] of UNWIRED)
        assert.equal(render.unwiredText(text, LINE), want, JSON.stringify(text));
    for (const [text, want] of UNWIRED_SECTION)
        assert.equal(render.unwiredText(text, TOML_LINE, "general"), want, JSON.stringify(text));
    for (const [text, want] of PROFILES)
        assert.deepEqual(render.profileDirs(text), want, JSON.stringify(text));
    for (const [text, want] of VAULTS)
        assert.deepEqual(render.vaultDirs(logic, text), want, JSON.stringify(text));

    // An entry target's links point at its files in the state directory's
    // theme/, in target.json's order; each form refuses the other's helper.
    const linked = accepted("probe", entryText({ links: { "vgs.conf": "probe.conf", "package.json": "probe.pkg.json" } }));
    assert.equal(render.wiringForm(linked.wiring), "entry");
    assert.equal(render.wiringForm(target("hex6").wiring), "include");
    assert.deepEqual(render.entryLinks(linked, "/s/vgs/theme"), [{ name: "vgs.conf", to: "/s/vgs/theme/probe.conf" }, { name: "package.json", to: "/s/vgs/theme/probe.pkg.json" }]);
    assert.throws(() => render.wiringLine(linked, "/s"), /has wiring form entry/);
    assert.throws(() => render.entryLinks(target("hex6"), "/s"), /has wiring form include/);

    // A null wiring is its own form, and neither form's helper takes it.
    const unwired = accepted("probe", targetText({ wiring: null }));
    assert.equal(render.wiringForm(unwired.wiring), "none");
    assert.throws(() => render.wiringLine(unwired, "/s"), /has wiring form none/);
    assert.throws(() => render.entryLinks(unwired, "/s"), /has wiring form none/);

    // A reload argument names the state directory and, for include targets
    // without profiles, the wiring file; `@@{` stays a literal. `always`
    // alone makes a hook due on every apply.
    const hooked = accepted("probe", targetText({ reload: { command: ["probe", "--file=@{state}/probe.conf", "@@{x}"], timeoutMs: 2000, always: true } }));
    assert.deepEqual(render.reloadCommand(hooked, "/s/vgs/theme"), ["probe", "--file=/s/vgs/theme/probe.conf", "@{x}"]);
    assert.equal(render.reloadNamesWiring(hooked), false);
    const wiringHook = accepted("probe", targetText({ reload: { command: ["touch", "-c", "--", "@{wiring}", "@{state}", "@@{x}"], timeoutMs: 2000 } }));
    assert.equal(render.reloadNamesWiring(wiringHook), true);
    assert.deepEqual(render.reloadCommand(wiringHook, "/s/vgs/theme", "/home/u/.wezterm.lua"), ["touch", "-c", "--", "/home/u/.wezterm.lua", "/s/vgs/theme", "@{x}"]);
    assert.throws(() => render.reloadCommand(wiringHook, "/s/vgs/theme"), /names placeholder wiring/);
    assert.deepEqual(render.reloadCommand(target("hex6"), "/s"), ["probe", "--reload"]);
    assert.equal(render.reloadNamesWiring(target("hex6")), false);
    assert.equal(render.reloadAlways(hooked), true);
    assert.equal(render.reloadAlways(target("hex6")), false);
    assert.equal(render.reloadAlways(accepted("probe", targetText({ reload: { command: ["probe"], timeoutMs: 2000, always: false } }))), false);
    const hookless = accepted("probe", targetText({ reload: null }));
    assert.equal(render.reloadNamesWiring(hookless), false);
    assert.equal(render.reloadAlways(hookless), false);
    assert.throws(() => render.reloadCommand(hookless, "/s"), /has no reload/);
}
verify(require(rendererFile));

// Each control removes one rule's behaviour from a copy of the renderer and
// keeps the text around it. The suite must fail on every copy.
const CONTROLS = [
    ["hex6 encoder", "hex6: hex => hex.slice(1, 7)", "hex6: hex => hex.slice(0, 7)"],
    ["hex8 encoder", "hex8: hex => hex.slice(1, 9)", "hex8: hex => hex.slice(1, 7)"],
    ["rgba alpha", "String(Math.round(parseInt(hex.slice(7, 9), 16) / 255 * 1000) / 1000)", "String(parseInt(hex.slice(7, 9), 16))"],
    ["hyprland encoder", 'hyprland: hex => "rgba(" + hex.slice(1, 9) + ")"', 'hyprland: hex => "rgba(" + hex.slice(1, 7) + ")"'],
    ["escape", 'if (m[0] === "@@{") {', "if (false) {"],
    ["pass-through", "const MARKER = /@@\\{|@\\{([^}]*)\\}|@\\{/g;", "const MARKER = /@@\\{|[@#$]\\{([^}]*)\\}|@\\{/g;"],
    ["unterminated", "if (m[1] === undefined) return { ok: false, at: m.index };", "if (m[1] === undefined) continue;"],
    ["unknown placeholder", "if (value === undefined) return refused(", "if (false) return refused("],
    ["group placeholder", "if (!logic.isLeaf(leaf)) return undefined;", "if (leaf === undefined) return undefined;"],
    ["slot name", "return logic.terminalSlotNames().includes(slot) ? encode(input.slots[slot]) : undefined;", "return encode(input.slots[slot]);"],
    ["case written", "if (cases.length > 0) return caseText(leaf, cases, value);", "if (false) return caseText(leaf, cases, value);"],
    ["slot takes no case", "if (cases.length > 0) return undefined;", "if (false) return undefined;"],
    ["case on a choice only", 'if (leaf.type !== "choice") return undefined;', 'if (!Array.isArray(leaf.options)) return "x";'],
    ["case text present", "const CASE_PATTERN = /^([^=]+)=(.+)$/;", "const CASE_PATTERN = /^([^=]+)=(.*)$/;"],
    ["case has its =", "if (m === null || !leaf.options", "if (m === null && false || !leaf.options"],
    ["case option known", "!leaf.options.includes(m[1]) || texts.has(m[1])", "texts.has(m[1])"],
    ["case option once", "!leaf.options.includes(m[1]) || texts.has(m[1])", "!leaf.options.includes(m[1])"],
    ["case every option", "return texts.size === leaf.options.length ? texts.get(value) : undefined;", "return texts.get(value);"],
    ["non-colour token", 'return leaf.type === "color" ? encode(value) : String(value);', "return encode(String(value));"],
    ["curated precedence", "const curated = input.curated.has(file.destination) && curatedTaken(", "const curated = false && curatedTaken("],
    ["curated keys admitted", "k => FILE_KEYS.includes(k) || k === CURATED_KEYS_KEY)", "k => FILE_KEYS.includes(k))"],
    ["curated keys shape", "(!Array.isArray(file.curatedKeys) || file.curatedKeys.length === 0 || !file.curatedKeys.every(isLine))", "false"],
    ["curated keys judged", "if (!logic.hasOwn(file, CURATED_KEYS_KEY)) return true;", "return true;"],
    ["curated keys any key", "file.curatedKeys.some(key => logic.hasOwn(document, key))", "file.curatedKeys.every(key => logic.hasOwn(document, key))"],
    ["curated keys object", "return logic.isPlainObject(document) && file.curatedKeys", "return true && file.curatedKeys"],
    ["curated file judges its template", "for (const part of template.parts) {", "for (const part of input.curated.has(file.destination) ? [] : template.parts) {"],
    ["own terminal first", "for (const candidate of [pkg, defaults]) {", "for (const candidate of [defaults, pkg]) {"],
    ["terminal fallback", "for (const candidate of [pkg, defaults]) {", "for (const candidate of [pkg]) {"],
    ["target name", "if (typeof name !== \"string\" || !TARGET_NAME_PATTERN.test(name))", "if (false)"],
    ["unknown key", "if (!TARGET_KEYS.includes(key) && key !== SELECT_KEY) return", "if (false) return"],
    ["missing key", "if (!logic.hasOwn(document, key)) return", "if (false) return"],
    ["app", "if (!isLine(document.app)) return", "if (false) return"],
    ["encoder name", "if (!logic.hasOwn(ENCODERS, document.encoder)) return", "if (false) return"],
    ["files list", "if (!Array.isArray(document.files) || document.files.length === 0) return", "if (!Array.isArray(document.files)) return"],
    ["file keys", "!FILE_KEYS.every(k => logic.hasOwn(file, k)) ||", "false ||"],
    ["template name", "if (!logic.isPackageName(file.template) || file.template === TARGET_FILE) return", "if (false) return"],
    ["destination prefix", "!file.destination.startsWith(name + \".\")", "false"],
    ["unique destination", "if (destinations.has(document.files[at].destination)) return", "if (false) return"],
    ["detect", "if (!Array.isArray(document.detect) || !document.detect.every(entry => isDetectEntry(logic, entry))) return", "if (false) return"],
    ["detect command name", "if (!Array.isArray(entry)) return logic.isPackageName(entry);", "if (!Array.isArray(entry)) return true;"],
    ["detect list admitted", "if (!Array.isArray(entry)) return logic.isPackageName(entry);", "if (!Array.isArray(entry) || true) return logic.isPackageName(entry);"],
    ["detect list present", "return entry.length > 0 && entry.every(logic.isPackageName);", "return entry.every(logic.isPackageName);"],
    ["detect list names", "return entry.length > 0 && entry.every(logic.isPackageName);", "return entry.length > 0;"],
    ["detected any of a list", "Array.isArray(entry) ? entry.some(onPath) : onPath(entry)", "Array.isArray(entry) ? entry.every(onPath) : onPath(entry)"],
    ["detected every entry", "return detect.every(entry => Array.isArray", "return detect.some(entry => Array.isArray"],
    ["wiring required keys", "!WIRING_KEYS.every(key => logic.hasOwn(wiring, key)) ||", "false ||"],
    ["wiring unknown key", "!Object.keys(wiring).every(key => WIRING_KEYS.includes(key) || INCLUDE_OPTIONAL_KEYS.includes(key))", "false"],
    ["wiring section admitted", 'const INCLUDE_OPTIONAL_KEYS = ["section", "profiles", "fallbacks"];', 'const INCLUDE_OPTIONAL_KEYS = ["profiles", "fallbacks"];'],
    ["wiring profiles admitted", 'const INCLUDE_OPTIONAL_KEYS = ["section", "profiles", "fallbacks"];', 'const INCLUDE_OPTIONAL_KEYS = ["section", "fallbacks"];'],
    ["wiring fallbacks admitted", 'const INCLUDE_OPTIONAL_KEYS = ["section", "profiles", "fallbacks"];', 'const INCLUDE_OPTIONAL_KEYS = ["section", "profiles"];'],
    ["wiring section name", "(typeof wiring.section !== \"string\" || !SECTION_PATTERN.test(wiring.section))", "false"],
    ["wiring profiles list", "(!Array.isArray(wiring.profiles) || wiring.profiles.length === 0 ||", "(!Array.isArray(wiring.profiles) ||"],
    ["wiring profiles path", "!wiring.profiles.every(ini => typeof ini === \"string\" && ini.split(\"/\").every(segment => DIR_SEGMENT_PATTERN.test(segment)))", "!wiring.profiles.every(ini => typeof ini === \"string\")"],
    ["wiring fallbacks list", "(!Array.isArray(wiring.fallbacks) || wiring.fallbacks.length === 0 ||", "(!Array.isArray(wiring.fallbacks) ||"],
    ["wiring fallbacks path", "!wiring.fallbacks.every(file => typeof file === \"string\" && file.split(\"/\").every(segment => DIR_SEGMENT_PATTERN.test(segment)))", "!wiring.fallbacks.every(file => typeof file === \"string\")"],
    ["wiring fallbacks exclude profiles", 'if (logic.hasOwn(wiring, "fallbacks") && logic.hasOwn(wiring, "profiles")) return "key=wiring.fallbacks";', 'if (false) return "key=wiring.fallbacks";'],
    ["profile sections only", "PROFILE_SECTION.test(line.slice(1, -1).trim()) ? new Map() : null", "new Map()"],
    ["profile lines trimmed", "const line = raw.trim();", "const line = raw;"],
    ["profile value keeps its =", 'const at = line.indexOf("=");', 'const at = line.lastIndexOf("=");'],
    ["profile relative flag", 'relative: keys.get("IsRelative") === "1"', 'relative: keys.has("IsRelative")'],
    ["profile relative path present", 'dir.relative ? dir.path !== "" :', "dir.relative ? true :"],
    ["profile absolute path", ': dir.path.startsWith("/"));', ': dir.path !== "");'],
    ["wiring file", "!wiring.file.split(\"/\").every(logic.isPackageName)", "false"],
    ["wiring line placeholder", "if (names.length === 0 || names.some(placeholder => placeholder !== STATE_PLACEHOLDER)) return", "if (false) return"],
    ["wiring line is one line", "if (!isLine(wiring.line)) return", "if (typeof wiring.line !== \"string\") return"],
    ["wiring create", "if (typeof wiring.create !== \"boolean\") return", "if (false) return"],
    ["reload required keys", "!RELOAD_KEYS.every(key => logic.hasOwn(reload, key)) ||", "false ||"],
    ["reload unknown key", "!Object.keys(reload).every(key => RELOAD_KEYS.includes(key) || key === ALWAYS_KEY)", "false"],
    ["reload always admitted", "RELOAD_KEYS.includes(key) || key === ALWAYS_KEY)", "RELOAD_KEYS.includes(key))"],
    ["reload always boolean", "typeof reload.always !== \"boolean\"", "false"],
    ["reload argument placeholder", "!allowed.includes(name)", "false"],
    ["reload argument unterminated", "list === null ||", "false ||"],
    ["reload wiring placeholder gate", 'if (target.wiring !== null && wiringForm(target.wiring) === "include" && !logic.hasOwn(target.wiring, "profiles")) names.push(WIRING_PLACEHOLDER);', "names.push(WIRING_PLACEHOLDER);"],
    ["reload names wiring", "return names !== null && names.includes(WIRING_PLACEHOLDER);", "return false;"],
    ["reload argument state", "target.reload.command.map(arg => withValues(arg, values,", "target.reload.command.map(arg => String(arg,"],
    ["reload always read", "target.reload.always === true", "target.reload.always !== undefined"],
    ["wiring none form", "if (wiring === null) return \"none\";", "if (false) return \"none\";"],
    ["wiring null accepted", "document.wiring === null ? \"\"", "document.wiring === undefined ? \"\""],
    ["reload command", "if (!Array.isArray(reload.command) || reload.command.length === 0 || !reload.command.every(isLine)) return", "if (false) return"],
    ["reload timeout", "if (!Number.isInteger(reload.timeoutMs) || reload.timeoutMs <= 0) return", "if (false) return"],
    ["wiring line state", "        return values[part.name];\n", "        return part.name === STATE_PLACEHOLDER ? \"@{state}\" : values[part.name];\n"],
    ["wiring whole line", "if (lines.includes(line)) return null;", "if (text !== undefined && text.includes(line)) return null;"],
    ["wiring line first", "return line + \"\\n\" + (text === undefined ? \"\" : text);", "return (text === undefined ? \"\" : text) + line + \"\\n\";"],
    ["wiring creates", "const lines = text === undefined ? [] : text.split(\"\\n\");", "if (text === undefined) return null;\n    const lines = text.split(\"\\n\");"],
    ["wiring into its section", "if (at !== -1) {", "if (false) {"],
    ["wiring after the header", "lines.slice(0, at + 1).concat(line, lines.slice(at + 1))", "lines.slice(0, at).concat(line, lines.slice(at))"],
    ["wiring the first header", "lines.findIndex(existing => isSectionHeader(existing, section))", "lines.findLastIndex(existing => isSectionHeader(existing, section))"],
    ["section header form", "return m !== null && m[1] === section;", "return text === \"[\" + section + \"]\";"],
    ["section header whole name", "const SECTION_HEADER = /^\\s*\\[\\s*([^\\]]*?)\\s*\\]\\s*(?:#.*)?$/;", "const SECTION_HEADER = /^\\s*\\[+\\s*([^\\]]*?)\\s*\\]/;"],
    ["section header appended", "\"[\" + section + \"]\\n\" + line", "line"],
    ["section key conflict", "if (key !== null && assignedKey(lines[index]) === key) assigning.push(index);", "if (false) assigning.push(index);"],
    ["section array merged", "const array = assigning.length === 1 && element !== null ? stringArray(own) : null;", "const array = null;"],
    ["section array assigned once", "const array = assigning.length === 1 && element !== null ?", "const array = element !== null ?"],
    ["wiring line one string", "array === null || array.elements.length !== 1 ? null", "array === null || array.elements.length === 0 ? null"],
    ["wiring line an array", "&& element !== null ? stringArray(own)", "? stringArray(own)"],
    ["section array holds it already", "if (array.elements.some(held => own.slice(held.start, held.end) === element)) return null;", "if (false) return null;"],
    ["section array theme first", "const into = array.elements.length === 0 ? array.close : array.elements[0].start;", "const into = array.close;"],
    ["string array opens", 'if (text[at] !== "[") return null;', "if (false) return null;"],
    ["string array blanks", 'while (text[at] === " " || text[at] === "\\t") at++;', "while (false) at++;"],
    ["string array strings only", `if (quote !== "\\"" && quote !== "'") return null;`, "if (quote === undefined) return null;"],
    ["string array basic escape", 'at += quote === "\\"" && text[at] === "\\\\" ? 2 : 1;', "at += 1;"],
    ["string array literal no escape", 'at += quote === "\\"" && text[at] === "\\\\" ? 2 : 1;', 'at += text[at] === "\\\\" ? 2 : 1;'],
    ["string array separator", 'else if (text[at] !== "]") return null;', "else if (false) return null;"],
    ["string array comment after", "/^\\s*(?:#.*)?$/.test(text.slice(at + 1))", "/^\\s*$/.test(text.slice(at + 1))"],
    ["string array nothing else after", "/^\\s*(?:#.*)?$/.test(text.slice(at + 1))", "/.*/.test(text.slice(at + 1))"],
    ["section ends at the next header", "index > at && ANY_HEADER.test(existing)", "false"],
    ["array of tables ends a section", "const ANY_HEADER = /^\\s*\\[/;", "const ANY_HEADER = /^\\s*\\[[^\\[]/;"],
    ["assigned key trimmed", "text.slice(0, at).trim();", "text.slice(0, at);"],
    ["dotted root conflict", "if (root.some(existing =>", "if (false && root.some(existing =>"],
    ["dotted key prefix", "name === section || (name !== null && name.startsWith(section + \".\"))", "name === section"],
    ["dotted keys at the root only", "const root = lines.slice(0, first === -1 ? lines.length : first);", "const root = lines;"],
    ["section appended on its own line", "(before === \"\" || before.endsWith(\"\\n\") ? \"\" : \"\\n\")", "\"\""],
    ["entry form", 'hasOwnProperty.call(wiring, ENTRY_KEY) ? "entry" : "include"', 'hasOwnProperty.call(wiring, "nope") ? "entry" : "include"'],
    ["entry required keys", "if (!ENTRY_KEYS.every(key => logic.hasOwn(wiring, key)) ||", "if (false ||"],
    ["entry unknown key", "!Object.keys(wiring).every(key => ENTRY_KEYS.includes(key) || ENTRY_OPTIONAL_KEYS.includes(key))) return", "false) return"],
    ["entry vaults admitted", 'const ENTRY_OPTIONAL_KEYS = ["vaults"];', "const ENTRY_OPTIONAL_KEYS = [];"],
    ["entry vaults path", 'if (logic.hasOwn(wiring, "vaults") && !isRelativePath(wiring.vaults)) return', "if (false) return"],
    ["vault registry parses", "        registry = JSON.parse(text);\n    } catch (e) {\n        return null;", "        registry = JSON.parse(text);\n    } catch (e) {\n        return [];"],
    ["vault registry is an object", "if (!logic.isPlainObject(registry)) return null;", "if (registry === null) return null;"],
    ["vault registry without vaults", 'if (!logic.hasOwn(registry, "vaults")) return [];', ""],
    ["vault list is an object", "if (!logic.isPlainObject(registry.vaults)) return null;", "if (false) return null;"],
    ["vault entry is an object", "logic.isPlainObject(vault) ? vault.path : undefined", "vault.path"],
    ["vault path absolute", 'dir.startsWith("/") && !dirs.includes(dir)', "!dirs.includes(dir)"],
    ["vault listed once", "&& !dirs.includes(dir)) dirs.push(dir);", ") dirs.push(dir);"],
    ["entry base", "if (!ENTRY_BASES.includes(wiring.base)) return", "if (false) return"],
    ["entry cache base", 'const ENTRY_BASES = ["config", "home", "cache"];', 'const ENTRY_BASES = ["config", "home"];'],
    ["entry dir segment", "const DIR_SEGMENT_PATTERN = /^\\.?[A-Za-z0-9][A-Za-z0-9._-]*$/;", "const DIR_SEGMENT_PATTERN = /^[.A-Za-z0-9_-]+$/;"],
    ["entry owned", "if (typeof wiring.owned !== \"boolean\") return", "if (false) return"],
    ["entry links present", "|| Object.keys(wiring.links).length === 0) return", ") return"],
    ["entry link name", "if (!logic.isPackageName(link) || !destinations.has(destination)) return", "if (!destinations.has(destination)) return"],
    ["entry link destination", "if (!logic.isPackageName(link) || !destinations.has(destination)) return", "if (!logic.isPackageName(link)) return"],
    ["entry link target", "({ name, to: live + \"/\" + destination })", "({ name, to: destination })"],
    ["unwiring whole line", 'text.split("\\n").filter(existing => existing !== line)', 'text.split("\\n").map(existing => existing.split(line).join(""))'],
    ["unwiring every line", 'text.split("\\n").filter(existing => existing !== line)', 'text.split("\\n").filter((existing, at, all) => at !== all.indexOf(line))'],
    ["unwiring null when unchanged", "return next === text ? null : next;", "return next;"],
    ["unwiring in its section", "const at = section === undefined ? -1 : sectionAt(lines, section);", "const at = -1;"],
    ["unwiring the section's own lines", "end = at === -1 ? 0 : sectionEnd(lines, at)", "end = at === -1 ? 0 : lines.length"],
    ["unwiring its key only", "assignedKey(lines[index]) !== key) continue;", "false) continue;"],
    ["unwiring every copy", "array !== null; array = stringArray(lines[index])) {", "array !== null; array = null) {"],
    ["unwiring the separator after", "[array.elements[k].start, array.elements[k + 1].start]", "[array.elements[k].start, array.elements[k].end]"],
    ["unwiring the separator before the last", "[array.elements[k - 1].end, array.elements[k].end]", "[array.elements[k].start, array.elements[k].end]"],
    ["unwiring a sole string to the bracket", "[array.elements[0].start, array.close]", "[array.elements[0].start, array.elements[0].end]"]
];

const source = fs.readFileSync(rendererFile, "utf8");
const temp = fs.mkdtempSync(path.join(os.tmpdir(), "theme-render-control-"));
try {
    CONTROLS.forEach(([label, needle, replacement], index) => {
        assert.equal(source.split(needle).length, 2, `control "${label}": the text to replace must occur once`);
        // One file per control: require caches a module by its path.
        const mutant = path.join(temp, `theme-render-${index}.js`);
        fs.writeFileSync(mutant, source.replace(needle, () => replacement));
        let failed = false;
        try {
            verify(require(mutant));
        } catch (e) {
            failed = true;
        }
        assert.ok(failed, `control "${label}": the suite passed on a renderer without that rule`);
    });
} finally {
    fs.rmSync(temp, { recursive: true, force: true });
}
console.log(`test-theme-render: ok targets=${ACCEPTED_TARGETS.length + REFUSED_TARGETS.length} templates=${ENCODED.length + RENDERED.length + MODES.length + REFUSED_TEMPLATES.length} wiring=${WIRED.length + WIRED_SECTION.length + CONFLICTS.length + CONFLICT_LINES.length + UNWIRED.length + UNWIRED_SECTION.length + PROFILES.length + VAULTS.length} controls=${CONTROLS.length}`);
