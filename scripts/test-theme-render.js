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
for (const pkg of [probe, defaults, own]) assert.equal(pkg.ok, true, pkg.ok ? "" : logic.refusalLine(pkg));

const wiring = { file: "probe/probe.conf", line: "include=@{state}/probe.conf", create: true };
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
    ["probe-2", targetText({ files: [{ template: "a.conf", destination: "probe-2.conf" }, { template: "a.conf", destination: "probe-2.extra.ini" }] })],
    ["probe", targetText({ wiring: Object.assign({}, wiring, { section: "general" }) })],
    ["probe", targetText({ wiring: Object.assign({}, wiring, { section: "Main_2-b" }) })]
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
    ["probe", targetText({ detect: ["probe --version"] }), "target-schema", "key=detect"],
    ["probe", targetText({ detect: "probe" }), "target-schema", "key=detect"],
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
    ["probe", targetText({ reload: { command: ["probe"] } }), "target-schema", "key=reload"],
    ["probe", targetText({ reload: { command: [], timeoutMs: 2000 } }), "target-schema", "key=reload.command"],
    ["probe", targetText({ reload: { command: ["probe"], timeoutMs: 0 } }), "target-schema", "key=reload.timeoutMs"],
    ["probe", targetText({ reload: { command: ["probe"], timeoutMs: 1.5 } }), "target-schema", "key=reload.timeoutMs"]
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

// Templates that refuse the target: the template, the detail.
const REFUSED_TEMPLATES = [
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
    ['[window]\n[general]\nimport = ["/s/alacritty.toml"]\n', null],
    ['import = ["/s/alacritty.toml"]', null]
];

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
    for (const [text, want] of UNWIRED)
        assert.equal(render.unwiredText(text, LINE), want, JSON.stringify(text));
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
    ["non-colour token", 'return leaf.type === "color" ? encode(value) : String(value);', "return encode(String(value));"],
    ["curated precedence", "const curated = input.curated.has(file.destination);", "const curated = false;"],
    ["curated file judges its template", "for (const part of template.parts) {", "for (const part of input.curated.has(file.destination) ? [] : template.parts) {"],
    ["own terminal first", "for (const candidate of [pkg, defaults]) {", "for (const candidate of [defaults, pkg]) {"],
    ["terminal fallback", "for (const candidate of [pkg, defaults]) {", "for (const candidate of [pkg]) {"],
    ["target name", "if (typeof name !== \"string\" || !TARGET_NAME_PATTERN.test(name))", "if (false)"],
    ["unknown key", "if (!TARGET_KEYS.includes(key)) return", "if (false) return"],
    ["missing key", "if (!logic.hasOwn(document, key)) return", "if (false) return"],
    ["app", "if (!isLine(document.app)) return", "if (false) return"],
    ["encoder name", "if (!logic.hasOwn(ENCODERS, document.encoder)) return", "if (false) return"],
    ["files list", "if (!Array.isArray(document.files) || document.files.length === 0) return", "if (!Array.isArray(document.files)) return"],
    ["file keys", "if (!hasExactKeys(logic, file, FILE_KEYS)) return", "if (false) return"],
    ["template name", "if (!logic.isPackageName(file.template) || file.template === TARGET_FILE) return", "if (false) return"],
    ["destination prefix", "!file.destination.startsWith(name + \".\")", "false"],
    ["unique destination", "if (destinations.has(document.files[at].destination)) return", "if (false) return"],
    ["detect", "if (!Array.isArray(document.detect) || !document.detect.every(logic.isPackageName)) return", "if (false) return"],
    ["wiring required keys", "!WIRING_KEYS.every(key => logic.hasOwn(wiring, key)) ||", "false ||"],
    ["wiring unknown key", "!Object.keys(wiring).every(key => WIRING_KEYS.includes(key) || key === SECTION_KEY)", "false"],
    ["wiring section admitted", "WIRING_KEYS.includes(key) || key === SECTION_KEY)", "WIRING_KEYS.includes(key))"],
    ["wiring section name", "(typeof wiring.section !== \"string\" || !SECTION_PATTERN.test(wiring.section))", "false"],
    ["wiring file", "!wiring.file.split(\"/\").every(logic.isPackageName)", "false"],
    ["wiring line placeholder", "if (names.length === 0 || names.some(placeholder => placeholder !== STATE_PLACEHOLDER)) return", "if (false) return"],
    ["wiring line is one line", "if (!isLine(wiring.line)) return", "if (typeof wiring.line !== \"string\") return"],
    ["wiring create", "if (typeof wiring.create !== \"boolean\") return", "if (false) return"],
    ["reload keys", "if (!hasExactKeys(logic, reload, RELOAD_KEYS)) return", "if (!logic.isPlainObject(reload)) return"],
    ["reload command", "if (!Array.isArray(reload.command) || reload.command.length === 0 || !reload.command.every(isLine)) return", "if (false) return"],
    ["reload timeout", "if (!Number.isInteger(reload.timeoutMs) || reload.timeoutMs <= 0) return", "if (false) return"],
    ["wiring line state", "        return state;\n", "        return \"@{state}\";\n"],
    ["wiring whole line", "if (lines.includes(line)) return null;", "if (text !== undefined && text.includes(line)) return null;"],
    ["wiring line first", "return line + \"\\n\" + (text === undefined ? \"\" : text);", "return (text === undefined ? \"\" : text) + line + \"\\n\";"],
    ["wiring creates", "const lines = text === undefined ? [] : text.split(\"\\n\");", "if (text === undefined) return null;\n    const lines = text.split(\"\\n\");"],
    ["wiring into its section", "if (at !== -1) return", "if (false) return"],
    ["wiring after the header", "lines.slice(0, at + 1).concat(line, lines.slice(at + 1))", "lines.slice(0, at).concat(line, lines.slice(at))"],
    ["wiring the first header", "lines.findIndex(existing =>", "lines.findLastIndex(existing =>"],
    ["section header form", "return m !== null && m[1] === section;", "return text === \"[\" + section + \"]\";"],
    ["section header whole name", "const SECTION_HEADER = /^\\s*\\[\\s*([^\\]]*?)\\s*\\]\\s*(?:#.*)?$/;", "const SECTION_HEADER = /^\\s*\\[+\\s*([^\\]]*?)\\s*\\]/;"],
    ["section header appended", "\"[\" + section + \"]\\n\" + line", "line"],
    ["section appended on its own line", "(before === \"\" || before.endsWith(\"\\n\") ? \"\" : \"\\n\")", "\"\""],
    ["unwiring whole line", "if (!lines.includes(line)) return null;", "if (!text.includes(line)) return null;"],
    ["unwiring every line", "return lines.filter(existing => existing !== line).join(\"\\n\");", "return lines.filter((existing, at) => at !== lines.indexOf(line)).join(\"\\n\");"]
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
console.log(`test-theme-render: ok targets=${ACCEPTED_TARGETS.length + REFUSED_TARGETS.length} templates=${ENCODED.length + RENDERED.length + REFUSED_TEMPLATES.length} wiring=${WIRED.length + WIRED_SECTION.length + UNWIRED.length} controls=${CONTROLS.length}`);
