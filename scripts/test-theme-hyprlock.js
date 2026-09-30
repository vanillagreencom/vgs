#!/usr/bin/env node
// The shipped hyprlock target, themes/targets/hyprlock, as bin/vgsh-lock
// runs it: hyprlock reads the rendered file with VGS_LOCK_BACKGROUND in its
// environment. The target keeps nothing outside the state directory and
// reloads nothing, is marked as a file its application runs code from, and
// writes rgba() colours; under the shipped vgs and light packages the
// render's background image is the variable and its colours are the
// package's own. The expected colours were written by hand from each
// package's theme.json.
//
// Each rule has a must-fail control: a copy of target.json or of the
// template with that rule's value changed must make the same check fail.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { load } = require("../bin/lib/qml-library.js");
const render = require("../bin/lib/theme-render.js");

const repo = path.join(__dirname, "..");
const logic = load(path.join(repo, "shell", "Commons", "ThemeLogic.js"));
const TOKENS = load(path.join(repo, "shell", "Commons", "Tokens.js")).TOKENS;
const targetDir = path.join(repo, "themes", "targets", "hyprlock");
const shippedJson = fs.readFileSync(path.join(targetDir, "target.json"), "utf8");
const shippedTemplate = fs.readFileSync(path.join(targetDir, "hyprlock.conf"), "utf8");

const shippedPackage = name => {
    const dir = path.join(repo, "themes", name);
    const pkg = logic.acceptPackage(TOKENS, {
        directoryName: name,
        themeJson: fs.readFileSync(path.join(dir, "theme.json"), "utf8"),
        terminalJson: fs.readFileSync(path.join(dir, "terminal.json"), "utf8"),
        shipped: true
    });
    assert.equal(pkg.ok, true, pkg.ok ? "" : logic.refusalLine(pkg));
    return pkg;
};
const defaults = shippedPackage("vgs");

// Each widget block of a hyprlock file as { name, keys }, in file order.
// hyprlock's blocks hold `key = value` lines and no nested block.
const blocks = text => {
    const out = [];
    let open = null;
    for (const raw of text.split("\n")) {
        const line = raw.replace(/#.*$/, "").trim();
        if (line === "") continue;
        const start = /^([a-z-]+)\s*\{$/.exec(line);
        if (start) { open = { name: start[1], keys: {} }; out.push(open); continue; }
        if (line === "}") { open = null; continue; }
        const pair = /^([a-z_]+)\s*=\s*(.*)$/.exec(line);
        assert.ok(open !== null && pair, `hyprlock.conf: a line outside a block or no key: ${raw}`);
        open.keys[pair[1]] = pair[2];
    }
    return out;
};
const block = (parsed, name) => {
    const found = parsed.filter(b => b.name === name);
    assert.equal(found.length, 1, `hyprlock.conf holds ${found.length} ${name} blocks, want 1`);
    return found[0].keys;
};

// Hand-written from themes/<name>/theme.json: palette.background,
// palette.foreground, palette.accent, palette.danger and palette.warning.
const EXPECTED = {
    vgs: { background: "rgba(0, 0, 0, 1)", text: "rgba(215, 215, 217, 1)", accent: "rgba(255, 90, 54, 1)", danger: "rgba(244, 63, 94, 1)", warning: "rgba(255, 176, 0, 1)" },
    light: { background: "rgba(250, 250, 249, 1)", text: "rgba(24, 24, 27, 1)", accent: "rgba(168, 51, 10, 1)", danger: "rgba(159, 18, 57, 1)", warning: "rgba(133, 77, 14, 1)" }
};

// Throws on the first rule TARGET_JSON and TEMPLATE break under the two
// shipped packages.
const check = (targetJson, template) => {
    const judged = render.acceptTarget(logic, "hyprlock", targetJson);
    assert.equal(judged.ok, true, judged.ok ? "" : render.refusalLine("hyprlock", judged));
    const target = judged.target;
    assert.equal(target.runsCode, true, "runsCode: hyprlock runs commands from its configuration");
    assert.equal(target.wiring, null, "wiring: vgsh lock names the file; no configuration of the user's is edited");
    assert.equal(target.reload, null, "reload: hyprlock reads the file when it starts");
    assert.equal(target.encoder, "rgba", "encoder: hyprlock's rgba(r, g, b, a)");
    assert.deepEqual(target.files.map(f => f.destination), ["hyprlock.conf"], "destination: the file vgsh lock reads");
    for (const [name, want] of Object.entries(EXPECTED)) {
        const pkg = shippedPackage(name);
        const result = render.renderTarget(logic, TOKENS, target, new Map([["hyprlock.conf", template]]),
            { values: pkg.values, slots: render.terminalSource(pkg, defaults).terminal, curated: new Map(), installed: false });
        assert.equal(result.ok, true, result.ok ? "" : render.refusalLine("hyprlock", result));
        const parsed = blocks(result.files[0].bytes.toString("utf8"));
        const background = block(parsed, "background");
        assert.equal(background.path, "$VGS_LOCK_BACKGROUND", `${name}: background path`);
        assert.equal(background.color, want.background, `${name}: background colour`);
        const field = block(parsed, "input-field");
        assert.equal(field.font_color, want.text, `${name}: input field text`);
        assert.equal(field.check_color, want.accent, `${name}: input field check`);
        assert.equal(field.fail_color, want.danger, `${name}: input field fail`);
        assert.equal(field.capslock_color, want.warning, `${name}: input field caps lock`);
        assert.equal(block(parsed, "label").text, "$TIME", `${name}: the clock is hyprlock's own $TIME, no command`);
    }
};

check(shippedJson, shippedTemplate);

// replaced TEXT NEEDLE REPLACEMENT: TEXT with NEEDLE, which must occur
// once, replaced.
const replaced = (text, needle, replacement) => {
    assert.equal(text.split(needle).length - 1, 1, `control needle ${JSON.stringify(needle)} occurs once`);
    return text.replace(needle, replacement);
};
const CONTROLS = [
    ["runsCode false", replaced(shippedJson, '"runsCode": true', '"runsCode": false'), shippedTemplate, /runsCode/],
    ["a wired include", replaced(shippedJson, '"wiring": null', '"wiring": { "file": "hypr/hyprlock.conf", "line": "source = @{state}/hyprlock.conf", "create": false }'), shippedTemplate, /wiring/],
    ["a reload hook", replaced(shippedJson, '"reload": null', '"reload": { "command": ["true"], "timeoutMs": 1000 }'), shippedTemplate, /reload/],
    ["the hex8 encoder", replaced(shippedJson, '"encoder": "rgba"', '"encoder": "hex8"'), shippedTemplate, /encoder/],
    ["a fixed background path", shippedJson, replaced(shippedTemplate, "path = $VGS_LOCK_BACKGROUND", "path = screenshot"), /background path/],
    ["a colour from another token", shippedJson, replaced(shippedTemplate, "check_color = @{color.accent}", "check_color = @{color.text}"), /input field check/],
    ["a clock from a command", shippedJson, replaced(shippedTemplate, "text = $TIME", "text = cmd[update:1000] date +%H:%M"), /\$TIME/]
];
for (const [name, targetJson, template, pattern] of CONTROLS)
    assert.throws(() => check(targetJson, template), pattern, `control: ${name} passed the check`);

console.log(`test-theme-hyprlock: ok packages=${Object.keys(EXPECTED).length} controls=${CONTROLS.length}`);
