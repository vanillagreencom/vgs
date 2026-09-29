#!/usr/bin/env node
// The theme judge, shell/Commons/ThemeLogic.js, against the shipped token
// table, shell/Commons/Tokens.js. Every expected value below was computed by
// hand from the expression it names, never read from the judge.
//
// The controls at the end edit a copy of the judge, one rule at a time, and
// require this suite to fail on each copy.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { load } = require("./qml-library.js");

const repo = path.join(__dirname, "..");
const judgeFile = path.join(__dirname, "..", "shell", "Commons", "ThemeLogic.js");
const TOKENS = load(path.join(__dirname, "..", "shell", "Commons", "Tokens.js")).TOKENS;

const at = (tree, dotted) => dotted.split(".").reduce((node, key) => node[key], tree);
const document = tokens => JSON.stringify({ schemaVersion: 1, name: "probe", tokens: tokens });
const TERMINAL_SLOTS = Object.fromEntries(Array.from({ length: 16 }, (_, index) => [`color${index}`, "#000000"]));

// Resolved defaults, by token: the expression and the arithmetic.
const DEFAULTS = [
    ["scheme.mode", "dark"],
    ["palette.accent", "#ff5a36ff"],
    // mix(#000000, #d7d7d9, 0.05): 215 * 0.05 = 10.75, 217 * 0.05 = 10.85
    ["color.surface", "#0b0b0bff"],
    // mix(#000000, #d7d7d9, 0.19): 215 * 0.19 = 40.85, 217 * 0.19 = 41.23
    ["color.border", "#292929ff"],
    // mix(#d7d7d9, #000000, 0.21): 215 * 0.79 = 169.85, 217 * 0.79 = 171.43
    ["color.textMuted", "#aaaaabff"],
    // mix(#d7d7d9, contrast(#000000) = #ffffff, 0.55): 215 + 40 * 0.55 = 237, 217 + 38 * 0.55 = 237.9
    ["color.textHeading", "#ededeeff"],
    // mix(#ff5a36, #d7d7d9, 0.18): 255 - 40 * 0.18 = 247.8, 90 + 125 * 0.18 = 112.5, 54 + 163 * 0.18 = 83.34
    ["color.accentHover", "#f87153ff"],
    // The luminance of #ff5a36 is 0.29, nearer white than black in contrast.
    ["color.onAccent", "#000000ff"],
    // alpha(#ff5a36, 0.35): 255 * 0.35 = 89.25
    ["color.selection", "#ff5a3659"],
    ["color.dangerSubtle", "#f43f5e24"],
    ["space.xxs", 2],
    ["space.sm", 6],
    ["space.xxxl", 32],
    ["radius.md", 0],
    ["motion.duration.normal", 150],
    ["motion.easing.standard", "outCubic"],
    // mul(15, 2.27) = 34.05, mul(15, 1.33) = 19.95, mul(15, 1.07) = 16.05,
    // mul(15, 0.87) = 13.05, mul(15, 0.8) = 12, mul(15, 0.73) = 10.95
    ["text.display.size", 34],
    ["text.h1.size", 24],
    ["text.h2.size", 20],
    ["text.h3.size", 16],
    ["text.body.size", 15],
    ["text.body.lineHeight", 1.55],
    ["text.hint.size", 13],
    ["text.code.size", 13],
    ["text.bar.size", 12],
    ["text.bar.lineHeight", 1],
    ["text.label.size", 11],
    ["text.kbd.size", 11],
    ["text.eyebrow.uppercase", true],
    ["text.eyebrow.color", "#ff5a36ff"],
    ["text.body.family", "Inter Variable"],
    ["text.display.family", "Inter Variable"],
    ["text.label.family", "JetBrains Mono"],
    ["text.bar.family", "JetBrains Mono"],
    ["font.family.sans", "Inter Variable"],
    ["bar.height", 26],
    ["bar.onActive", "#000000ff"],
    ["bar.item.paddingX", 6],
    ["bar.item.gap", 4],
    // The control and row rhythm: the reference's 30 px control with 9 px
    // a side and a 7 px icon gap; mul(4, 3) = 12 for a row's padding and
    // its label gap, 130 px labels, mul(4, 1) = 4 between lines.
    ["control.paddingX", 9],
    ["control.gap", 7],
    ["row.paddingX", 12],
    ["row.gap", 12],
    ["row.labelWidth", 130],
    ["row.lineGap", 4],
    ["button.paddingX", 9],
    ["textField.paddingX", 9],
    ["textField.height", 30],
    ["segmented.height", 30],
    ["segmented.paddingX", 9],
    ["listItem.paddingX", 12],
    ["menu.item.paddingX", 12],
    ["field.paddingX", 12],
    ["field.labelWidth", 130],
    ["field.labelGap", 12],
    ["bar.item.iconGap", 7],
    // A window-like panel: 600 px wide, half its monitor tall, mul(4, 3) =
    // 12 from a narrower monitor's sides.
    ["size.window.width", 600],
    ["size.window.heightShare", 0.5],
    ["size.window.gutter", 12],
    // Nine 30 px entries before a menu scrolls: mul(30, 9) = 270.
    ["menu.maxHeight", 270],
    ["menu.typeahead", 1000],
    ["menu.item.check", "#ff5a36ff"],
    // The scroll bar: 4 px thick, 2 px in, inside an 8 px gutter, a thumb
    // of at least 24 px, faded out 800 ms after the last scroll.
    ["scrollArea.barWidth", 4],
    ["scrollArea.barInset", 2],
    ["scrollArea.gutter", 8],
    ["scrollArea.minThumb", 24],
    ["scrollArea.idleOpacity", 0],
    ["scrollArea.fadeDelay", 800],
    ["scrollArea.fade", 250],
    // A list row with a secondary line: mul(36, 1.5) = 54.
    ["listItem.twoLineHeight", 54],
    ["titleButton.gap", 4],
    ["titleButton.underline", 1],
    ["titleButton.underlineGap", 2],
    ["titleButton.hover", "#ff5a36ff"],
    // The dialog: 360 px wide, mul(4, 3) = 12 padding, mul(4, 2) = 8
    // between its blocks and mul(4, 1.5) = 6 between its actions; its card
    // is the raised surface, mix(#000000, #d7d7d9, 0.075): 215 * 0.075 =
    // 16.125, 217 * 0.075 = 16.275.
    ["dialog.width", 360],
    ["dialog.padding", 12],
    ["dialog.gap", 8],
    ["dialog.actionGap", 6],
    ["dialog.background", "#101010ff"],
    ["dialog.titleRole", "h3"],
    ["dialog.bodyRole", "body"]
];

// A document that is accepted, and the values it must resolve to.
const ACCEPTED = [
    { tokens: {}, want: [["palette.accent", "#ff5a36ff"]] },
    { tokens: { scheme: { mode: "light" } }, want: [["scheme.mode", "light"], ["palette.background", "#000000ff"]] },
    // A palette colour reaches every role derived from it; #7aa2f7 has
    // luminance 0.36, so the text on it is black.
    { tokens: { palette: { accent: "#7aa2f7" } }, want: [["color.accent", "#7aa2f7ff"], ["color.focus", "#7aa2f7ff"], ["bar.active", "#7aa2f7ff"], ["color.onAccent", "#000000ff"]] },
    // #1a1b26 has luminance 0.01, so the text on it is white.
    { tokens: { palette: { accent: "#1a1b26" } }, want: [["color.onAccent", "#ffffffff"]] },
    { tokens: { palette: { accent: "#abc" } }, want: [["color.accent", "#aabbccff"]] },
    { tokens: { color: { scrim: "#11223344" } }, want: [["color.scrim", "#11223344"]] },
    // A translucent fill is accepted where the text on it is stated too.
    { tokens: { bar: { active: "#ff5a3680", onActive: "#ffffff" } }, want: [["bar.active", "#ff5a3680"], ["bar.onActive", "#ffffffff"]] },
    // One component value changes, and the values derived from it.
    { tokens: { bar: { active: "#ffffff" } }, want: [["bar.active", "#ffffffff"], ["bar.onActive", "#000000ff"], ["color.accent", "#ff5a36ff"]] },
    { tokens: { space: { unit: 5 } }, want: [["space.xs", 5], ["space.sm", 8], ["space.xl", 20], ["bar.gap", 10], ["row.paddingX", 15], ["listItem.paddingX", 15], ["field.paddingX", 15]] },
    // One shared token moves every control that follows the rhythm.
    { tokens: { control: { paddingX: 12, gap: 5 } }, want: [["button.paddingX", 12], ["textField.paddingX", 12], ["segmented.paddingX", 12], ["button.gap", 5], ["textField.gap", 5], ["listItem.gap", 5], ["menu.item.gap", 5], ["toast.contentGap", 5], ["bar.item.iconGap", 5], ["bar.item.paddingX", 6]] },
    { tokens: { size: { control: { md: 34 } } }, want: [["textField.height", 34], ["segmented.height", 34], ["menu.item.height", 34]] },
    { tokens: { row: { paddingX: 16 } }, want: [["listItem.paddingX", 16], ["menu.item.paddingX", 16], ["field.paddingX", 16], ["button.paddingX", 9]] },
    { tokens: { font: { size: 16 } }, want: [["text.body.size", 16], ["text.hint.size", 14]] },
    { tokens: { motion: { scale: 0 } }, want: [["motion.duration.fast", 0], ["motion.duration.slow", 0]] },
    // The scale applies after a duration's own expression, so a theme that
    // states its own timing still goes still at 0 and doubles at 2.
    { tokens: { motion: { scale: 0, duration: { normal: 200 } } }, want: [["motion.duration.normal", 0]] },
    { tokens: { motion: { scale: 2, duration: { normal: 200 } } }, want: [["motion.duration.normal", 400], ["motion.duration.fast", 200]] },
    { tokens: { motion: { scale: 0.5 } }, want: [["motion.duration.fast", 50], ["motion.duration.slow", 125]] },
    // A duration that references another is scaled once: 100 * 2, not 100 * 2 * 2.
    { tokens: { motion: { scale: 2, duration: { normal: "{motion.duration.fast}" } } }, want: [["motion.duration.fast", 200], ["motion.duration.normal", 200]] },
    { tokens: { motion: { scale: 0.5, duration: { normal: "mul({motion.duration.fast}, 3)" } } }, want: [["motion.duration.fast", 50], ["motion.duration.normal", 150]] },
    // The range applies before the scale: 3000 * 4 publishes as 12000.
    { tokens: { motion: { scale: 4, duration: { slow: 3000 } } }, want: [["motion.duration.slow", 12000], ["motion.duration.fast", 400]] },
    { tokens: { radius: { md: 6.4 } }, want: [["radius.md", 6]] },
    { tokens: { radius: { md: "{radius.full}" } }, want: [["radius.md", 4096]] },
    { tokens: { radius: { md: "mul({space.unit}, 1.5)" } }, want: [["radius.md", 6]] },
    { tokens: { text: { body: { uppercase: true, family: "Inter", weight: 500 } } }, want: [["text.body.uppercase", true], ["text.body.family", "Inter"], ["text.body.weight", 500]] },
    { tokens: { text: { body: { uppercase: "{text.eyebrow.uppercase}" } } }, want: [["text.body.uppercase", true]] },
    // A dialog's roles name any role of `text`.
    { tokens: { dialog: { titleRole: "h2", bodyRole: "itemHint" } }, want: [["dialog.titleRole", "h2"], ["dialog.bodyRole", "itemHint"]] },
    { tokens: { motion: { easing: { standard: "linear" } } }, want: [["motion.easing.standard", "linear"]] },
    { tokens: { color: { surface: "mix( {palette.background} , alpha(#ffffff, 0.5), 0.5 )" } }, want: [["color.surface", "#808080bf"]] },
    { tokens: { color: { surface: "mix(#000, mix(#000, mix(#000, mix(#000, mix(#000, mix(#000, #fff, 1), 1), 1), 1), 1), 1)" } }, want: [["color.surface", "#ffffffff"]] }
];

// A document that is refused: the raw text or the `tokens` tree, and the
// reason and token the refusal names.
const REFUSED = [
    { text: "{ nope", reason: "not-json", token: "" },
    { text: "[1]", reason: "not-object", token: "" },
    { text: "null", reason: "not-object", token: "" },
    { text: JSON.stringify({ foreground: "#123456" }), reason: "unknown-key", token: "", detail: "key=foreground" },
    { text: JSON.stringify({ name: "x", tokens: {} }), reason: "schema-version", token: "" },
    { text: JSON.stringify({ schemaVersion: 2, name: "x" }), reason: "schema-version", token: "" },
    { text: JSON.stringify({ schemaVersion: 1 }), reason: "name", token: "" },
    { text: JSON.stringify({ schemaVersion: 1, name: " " }), reason: "name", token: "" },
    { text: JSON.stringify({ schemaVersion: 1, name: "x", tokens: [] }), reason: "tokens", token: "" },
    { tokens: { palette: { acent: "#fff" } }, reason: "unknown-token", token: "palette.acent" },
    { tokens: { palette: { accent: { hover: "#fff" } } }, reason: "not-expression", token: "palette.accent" },
    { tokens: { palette: "#fff" }, reason: "group-expected", token: "palette" },
    { tokens: { palette: { accent: null } }, reason: "not-expression", token: "palette.accent" },
    { tokens: { palette: { accent: ["#fff"] } }, reason: "not-expression", token: "palette.accent" },
    { tokens: { text: { body: { uppercase: "true" } } }, reason: "not-expression", token: "text.body.uppercase" },
    { tokens: { palette: { accent: "#12345" } }, reason: "syntax", token: "palette.accent" },
    { tokens: { palette: { accent: "red" } }, reason: "syntax", token: "palette.accent" },
    { tokens: { palette: { accent: "mix(#000, #fff, 0.5" } }, reason: "syntax", token: "palette.accent" },
    { tokens: { palette: { accent: "#fff trailing" } }, reason: "syntax", token: "palette.accent" },
    { tokens: { palette: { accent: "mix(#000, #fff, " + "0".repeat(260) + ")" } }, reason: "too-long", token: "palette.accent" },
    { tokens: { palette: { accent: "mix(#000, mix(#000, mix(#000, mix(#000, mix(#000, mix(#000, mix(#000, mix(#000, #fff, 1), 1), 1), 1), 1), 1), 1), 1)" } }, reason: "too-deep", token: "palette.accent" },
    { tokens: { palette: { accent: "darken(#fff, 0.5)" } }, reason: "unknown-function", token: "palette.accent" },
    { tokens: { palette: { accent: "mix(#000, #fff)" } }, reason: "arity", token: "palette.accent" },
    { tokens: { palette: { accent: "{palette.acent}" } }, reason: "unknown-reference", token: "palette.accent" },
    { tokens: { palette: { accent: "{palette}" } }, reason: "unknown-reference", token: "palette.accent" },
    { tokens: { palette: { accent: "{color.accent}" } }, reason: "cycle", token: "palette.accent" },
    { tokens: { palette: { accent: "{palette.accent}" } }, reason: "cycle", token: "palette.accent" },
    { tokens: { radius: { md: "{palette.accent}" } }, reason: "type", token: "radius.md" },
    { tokens: { radius: { md: "#ffffff" } }, reason: "type", token: "radius.md" },
    { tokens: { radius: { md: true } }, reason: "type", token: "radius.md" },
    { tokens: { radius: { md: "{motion.scale}" } }, reason: "type", token: "radius.md" },
    { tokens: { palette: { accent: 4 } }, reason: "type", token: "palette.accent" },
    { tokens: { palette: { accent: "mul(#fff, 2)" } }, reason: "type", token: "palette.accent" },
    { tokens: { radius: { md: "mix(#000, #fff, 0.5)" } }, reason: "type", token: "radius.md" },
    { tokens: { radius: { md: "mul({space.unit}, {space.unit})" } }, reason: "type", token: "radius.md" },
    { tokens: { text: { body: { family: 4 } } }, reason: "type", token: "text.body.family" },
    { tokens: { text: { body: { family: " " } } }, reason: "type", token: "text.body.family" },
    { tokens: { radius: { md: -1 } }, reason: "range", token: "radius.md" },
    { tokens: { radius: { md: 5000 } }, reason: "range", token: "radius.md" },
    { tokens: { motion: { scale: 5 } }, reason: "range", token: "motion.scale" },
    { tokens: { text: { body: { weight: 50 } } }, reason: "range", token: "text.body.weight" },
    { tokens: { motion: { duration: { fast: 20000 } } }, reason: "range", token: "motion.duration.fast" },
    { tokens: { palette: { accent: "mix(#000, #fff, 1.5)" } }, reason: "range", token: "palette.accent" },
    { tokens: { palette: { accent: "alpha(#000, -0.5)" } }, reason: "range", token: "palette.accent" },
    { tokens: { color: { onAccent: "contrast(alpha({palette.accent}, 0.5))" } }, reason: "contrast-translucent", token: "color.onAccent" },
    // The default text on a fill derives from the fill, so a translucent
    // fill alone is refused where that default is evaluated.
    { tokens: { bar: { active: "#ff5a3680" } }, reason: "contrast-translucent", token: "bar.onActive" },
    { tokens: { motion: { easing: { standard: "bouncy" } } }, reason: "option", token: "motion.easing.standard" },
    { tokens: { scheme: { mode: "dim" } }, reason: "option", token: "scheme.mode" },
    { tokens: { dialog: { titleRole: "shout" } }, reason: "option", token: "dialog.titleRole" }
];

// A plugin's own table and its light overrides, the shape a plugin's
// appearance file exports. Every expected value is computed by hand.
const LOOK = {
    palette: { accent: { type: "color", value: "#000000" } },
    motion: { scale: { type: "number", value: 1, min: 0, max: 4 }, open: { type: "duration", value: 200 } },
    card: {
        fill: { type: "color", value: "#151515c7" },
        text: { type: "color", value: "#e8e8e8" },
        edge: { type: "color", value: "alpha({palette.accent}, 0.5)" },
        radius: { type: "length", value: 18 }
    }
};
const LOOK_LIGHT = { card: { fill: "#efefefcc", text: "#2a2a2a" } };
const shellTheme = tokens => {
    const result = load(judgeFile).accept(TOKENS, document(tokens));
    assert.equal(result.ok, true, "shell document for an appearance row");
    return result.values;
};
const DARK_THEME = shellTheme({ palette: { accent: "#7aa2f7" } });
const LIGHT_THEME = shellTheme({ scheme: { mode: "light" }, palette: { accent: "#a8330a" } });
// Every shell token but the three inputs moves; the plugin's values stay.
const UNRELATED_THEME = shellTheme({ palette: { accent: "#7aa2f7", foreground: "#ff00ff", background: "#00ff00" }, font: { size: 22, family: { mono: "Courier", sans: "Serif" } }, space: { unit: 7 }, radius: { md: 9 } });

// Accepted appearance rows: [label, table, light, theme, want].
const APPEARANCE_ACCEPTED = [
    ["dark mode keeps the table's own values and takes the accent", LOOK, LOOK_LIGHT, DARK_THEME, [["card.fill", "#151515c7"], ["card.text", "#e8e8e8ff"], ["palette.accent", "#7aa2f7ff"], ["card.edge", "#7aa2f780"], ["card.radius", 18], ["motion.open", 200]]],
    ["light mode applies the light overrides and the light accent", LOOK, LOOK_LIGHT, LIGHT_THEME, [["card.fill", "#efefefcc"], ["card.text", "#2a2a2aff"], ["card.edge", "#a8330a80"], ["card.radius", 18]]],
    ["unrelated shell tokens reach no plugin value", LOOK, LOOK_LIGHT, UNRELATED_THEME, [["card.fill", "#151515c7"], ["card.text", "#e8e8e8ff"], ["card.edge", "#7aa2f780"], ["card.radius", 18], ["motion.open", 200]]],
    ["the theme's motion scale reaches the plugin's durations", LOOK, LOOK_LIGHT, shellTheme({ motion: { scale: 0 } }), [["motion.open", 0], ["motion.scale", 0]]],
    ["the scale doubles the plugin's durations", LOOK, LOOK_LIGHT, shellTheme({ motion: { scale: 2 } }), [["motion.open", 400]]]
];

// Refused appearance rows: [label, table, light, theme, reason, token].
const APPEARANCE_REFUSED = [
    ["a table defect", { palette: { accent: { type: "colour", value: "#000" } }, motion: LOOK.motion }, {}, DARK_THEME, "appearance-table", ""],
    ["a palette with a second colour", Object.assign({}, LOOK, { palette: { accent: LOOK.palette.accent, foreground: { type: "color", value: "#fff" } } }), {}, DARK_THEME, "appearance-palette", "palette"],
    ["no palette", { motion: LOOK.motion, card: LOOK.card }, {}, DARK_THEME, "appearance-palette", "palette"],
    ["an accent that is no colour", Object.assign({}, LOOK, { palette: { accent: { type: "length", value: 1 } } }), {}, DARK_THEME, "appearance-palette", "palette"],
    ["light overrides that are no tree", LOOK, [], DARK_THEME, "appearance-light", ""],
    ["light overrides naming no token of the table", LOOK, { card: { glow: "#fff" } }, DARK_THEME, "unknown-token", "card.glow"],
    ["light overrides setting the accent", LOOK, { palette: { accent: "#fff" } }, DARK_THEME, "appearance-input", "palette.accent"],
    ["light overrides setting the scale", LOOK, { motion: { scale: 0 } }, DARK_THEME, "appearance-input", "motion.scale"],
    ["a theme without a mode", LOOK, LOOK_LIGHT, {}, "appearance-theme", "scheme.mode"],
    ["a theme without an accent", LOOK, LOOK_LIGHT, { scheme: { mode: "dark" }, motion: { scale: 1 } }, "appearance-theme", "palette.accent"],
    ["a theme without a scale", LOOK, LOOK_LIGHT, { scheme: { mode: "dark" }, palette: { accent: "#000000ff" } }, "appearance-theme", "motion.scale"],
    // A light value is judged only where it applies, but its path is
    // judged in both modes.
    ["a light value of the wrong type in light mode", LOOK, { card: { radius: "#fff" } }, LIGHT_THEME, "type", "card.radius"]
];

// A table with one defect, and the text its report starts with.
const BAD_TABLES = [
    [{ palette: { accent: { type: "colour", value: "#fff" } } }, "palette.accent has unknown type"],
    [{ opacity: { disabled: { type: "number", value: 0.5 } } }, "opacity.disabled is a number without a range"],
    [{ toast: { corner: { type: "choice", value: "top" } } }, "toast.corner is a choice without options"],
    [{ palette: { "on-accent": { type: "color", value: "#fff" } } }, "palette.on-accent is not a token name"],
    [{ palette: {} }, "group palette is empty"],
    [{ palette: { accent: "#fff" } }, "palette.accent is neither a group nor a token"],
    [{ palette: { accent: { type: "color", value: "#fff" } } }, "motion.scale must be a number token"],
    [{ motion: { scale: { type: "length", value: 1 } } }, "motion.scale must be a number token"]
];

function verify(judge) {
    assert.equal(judge.tableError(TOKENS), "");
    for (const [table, start] of BAD_TABLES)
        assert.ok(judge.tableError(table).startsWith(start), `${start}: got ${JSON.stringify(judge.tableError(table))}`);
    assert.throws(() => judge.defaults({ palette: {}, motion: { scale: { type: "number", value: 1, min: 0, max: 4 } } }), /theme: token table: group palette is empty/);
    assert.throws(() => judge.defaults({ palette: { accent: { type: "color", value: "{palette.accent}" } }, motion: { scale: { type: "number", value: 1, min: 0, max: 4 } } }), /theme: refused: token=palette\.accent reason=cycle/);

    const defaults = judge.defaults(TOKENS);
    assert.equal(defaults.name, "vgs");
    for (const [token, want] of DEFAULTS)
        assert.deepEqual(at(defaults.values, token), want, token);

    // The resolved tree holds exactly the table's tokens, each with a value
    // of its type's portable form.
    const all = judge.leaves(TOKENS);
    assert.ok(all.length >= 150, `the table walk found ${all.length} tokens; the walk is broken`);
    for (const { path: token, leaf } of all) {
        const value = at(defaults.values, token);
        if (leaf.type === "color") assert.match(value, /^#[0-9a-f]{8}$/, token);
        else if (leaf.type === "flag") assert.equal(typeof value, "boolean", token);
        else if (["family", "easing", "choice"].includes(leaf.type)) assert.equal(typeof value, "string", token);
        else assert.equal(typeof value, "number", token);
        if (["length", "duration", "weight"].includes(leaf.type)) assert.ok(Number.isInteger(value), token);
    }
    const listed = judge.paths(TOKENS);
    for (const token of ["palette", "palette.accent", "text.body", "text.body.size", "motion.duration.fast"])
        assert.ok(listed.includes(token), token);
    assert.ok(!listed.includes("palette.accent.value"));

    for (const row of ACCEPTED) {
        const result = judge.accept(TOKENS, document(row.tokens));
        assert.equal(result.ok, true, `${JSON.stringify(row.tokens)}: ${result.ok ? "" : judge.refusalLine(result)}`);
        assert.equal(result.name, "probe");
        for (const [token, want] of row.want)
            assert.deepEqual(at(result.values, token), want, `${JSON.stringify(row.tokens)} ${token}`);
    }

    for (const row of REFUSED) {
        const text = row.text !== undefined ? row.text : document(row.tokens);
        const label = text.slice(0, 120);
        let result;
        assert.doesNotThrow(() => { result = judge.accept(TOKENS, text); }, label);
        assert.equal(result.ok, false, label);
        assert.equal(result.reason, row.reason, label);
        assert.equal(result.token, row.token, label);
        if (row.detail !== undefined) assert.equal(result.detail, row.detail, label);
        assert.deepEqual(Object.keys(result).sort(), ["detail", "ok", "reason", "token"], label);
    }

    const shippedVgs = judge.acceptPackage(TOKENS, {
        directoryName: "vgs",
        themeJson: fs.readFileSync(path.join(repo, "themes", "vgs", "theme.json"), "utf8"),
        terminalJson: fs.readFileSync(path.join(repo, "themes", "vgs", "terminal.json"), "utf8"),
        shipped: true
    });
    assert.equal(shippedVgs.ok, true, shippedVgs.ok ? "" : judge.refusalLine(shippedVgs));
    assert.equal(shippedVgs.name, "vgs");
    assert.equal(shippedVgs.terminal.color0, "#0b0b0bff");
    assert.equal(shippedVgs.terminal.color15, "#ffffffff");
    assert.equal(Object.keys(shippedVgs.terminal).length, 16);

    const packageWithoutTerminal = judge.acceptPackage(TOKENS, {
        directoryName: "probe",
        themeJson: document({ palette: { accent: "#abcdef" } }),
        shipped: false
    });
    assert.equal(packageWithoutTerminal.ok, true, packageWithoutTerminal.ok ? "" : judge.refusalLine(packageWithoutTerminal));
    assert.equal(packageWithoutTerminal.terminal, null);
    assert.equal(at(packageWithoutTerminal.values, "palette.accent"), "#abcdefff");

    const packageRefusals = [
        [{ directoryName: "vgs", themeJson: JSON.stringify({ schemaVersion: 1, name: "vgs", tokens: {} }), shipped: false }, "reserved-name", ""],
        [{ directoryName: "other", themeJson: document({}), shipped: false }, "name-mismatch", ""],
        [{ directoryName: "my theme", themeJson: JSON.stringify({ schemaVersion: 1, name: "my theme", tokens: {} }), shipped: false }, "package-name", ""],
        [{ directoryName: ".probe", themeJson: JSON.stringify({ schemaVersion: 1, name: ".probe", tokens: {} }), shipped: false }, "package-name", ""],
        [{ directoryName: "probe", themeJson: document({}), terminalJson: JSON.stringify({ schemaVersion: 1, slots: Object.assign({ colour0: "#000000" }, TERMINAL_SLOTS) }), shipped: false }, "terminal-slot", "terminal"],
        [{ directoryName: "probe", themeJson: document({}), terminalJson: JSON.stringify({ schemaVersion: 1, slots: Object.assign({}, TERMINAL_SLOTS, { color3: "red" }) }), shipped: false }, "terminal-colour", "terminal.color3"]
    ];
    for (const [files, reason, token] of packageRefusals) {
        const result = judge.acceptPackage(TOKENS, files);
        assert.equal(result.ok, false, JSON.stringify(files));
        assert.equal(result.reason, reason, JSON.stringify(files));
        assert.equal(result.token, token, JSON.stringify(files));
    }

    for (const name of ["vgs", "tokyo-night", "Nord2", "a.b_c"])
        assert.equal(judge.isPackageName(name), true, name);
    for (const name of ["", ".", "..", "../x", "a/b", "a b", "-x", ".x", "x\n", 7, undefined])
        assert.equal(judge.isPackageName(name), false, JSON.stringify(name));

    for (const [label, table, light, theme, want] of APPEARANCE_ACCEPTED) {
        const result = judge.acceptAppearance(table, light, theme);
        assert.equal(result.ok, true, `${label}: ${result.ok ? "" : judge.refusalLine(result)}`);
        for (const [token, value] of want)
            assert.deepEqual(at(result.values, token), value, `${label} ${token}`);
    }
    assert.deepEqual(judge.acceptAppearance(LOOK, LOOK_LIGHT, UNRELATED_THEME).values, judge.acceptAppearance(LOOK, LOOK_LIGHT, DARK_THEME).values, "unrelated shell tokens moved a plugin value");
    for (const [label, table, light, theme, reason, token] of APPEARANCE_REFUSED) {
        const result = judge.acceptAppearance(table, light, theme);
        assert.equal(result.ok, false, label);
        assert.equal(result.reason, reason, label);
        assert.equal(result.token, token, label);
    }
    assert.equal(judge.acceptAppearance(LOOK, { card: { radius: "#fff" } }, DARK_THEME).ok, true, "a light value applies only in light mode");

    assert.equal(judge.refusalLine(judge.accept(TOKENS, document({ palette: { acent: "#fff" } }))), "theme: refused: token=palette.acent reason=unknown-token");
    assert.equal(judge.refusalLine(judge.accept(TOKENS, JSON.stringify({ foreground: "#123456" }))), "theme: refused: document reason=unknown-key key=foreground");
}
verify(load(judgeFile));

// Each control removes one rule's behaviour from a copy of the judge and
// keeps the text around it. The suite must fail on every copy.
const CONTROLS = [
    ["unknown top-level key", "if (DOCUMENT_KEYS.indexOf(keys[i]) === -1)", "if (false)"],
    ["schema version", "if (document.schemaVersion !== SCHEMA_VERSION)", "if (false)"],
    ["document name", 'if (typeof document.name !== "string" || document.name.trim() === "")', "if (false)"],
    ["tokens shape", "if (!isPlainObject(tree))\n        return refusal(\"tokens\"", "if (false)\n        return refusal(\"tokens\""],
    ["unknown token", "if (known === undefined)", "if (false)"],
    ["value on a group", "else if (!isPlainObject(node[keys[i]]))", "else if (false)"],
    ["expression length", "if (text.length > MAX_EXPRESSION_LENGTH)", "if (false)"],
    ["expression depth", "if (depth > MAX_EXPRESSION_DEPTH)", "if (false)"],
    ["trailing text", "if (at !== text.length)", "if (false)"],
    ["unknown function", "if (!hasOwn(FUNCTIONS, tree.name))", "if (false)"],
    ["arity", "if (tree.args.length !== signature.args.length)", "if (false)"],
    ["unknown reference", "if (!isLeaf(target))", "if (false)"],
    ["reference type", "if (target.type !== want)", "if (false)"],
    ["colour literal type", 'if (want !== "color")', "if (false)"],
    ["number literal type", "if (NUMERIC_TYPES.indexOf(want) === -1)\n                return fail", "if (false)\n                return fail"],
    ["flag literal type", 'if (want !== "flag")', "if (false)"],
    ["function result type", 'if (result !== want || (signature.result === "same" && NUMERIC_TYPES.indexOf(want) === -1))', "if (false)"],
    ["cycle", "if (visiting.indexOf(path) !== -1)", "if (false)"],
    ["mix amount", "if (args[2] < 0 || args[2] > 1)", "if (false)"],
    ["alpha amount", "if (args[1] < 0 || args[1] > 1)", "if (false)"],
    ["translucent contrast", "if (args[0].a < 1)", "if (false)"],
    ["contrast choice", "1.05 / (light + 0.05) > (light + 0.05) / 0.05", "true"],
    ["family", 'if (typeof value !== "string" || value.trim() === "")', "if (false)"],
    ["option", "if (options.indexOf(value) === -1)", "if (false)"],
    ["whole rounding", "value = Math.round(value);", ""],
    ["duration scaling", "value = Math.round(value * scale);", ""],
    ["table motion scale", 'if (!isLeaf(scale) || scale.type !== "number")', "if (false)"],
    ["range", "if (value < range[0] || value > range[1])", "if (false)"],
    ["override wins", "hasOwn(overrides, path) ? overrides[path] : leaf.value", "leaf.value"],
    ["table type", "if (TYPES.indexOf(child.type) === -1)", "if (false)"],
    ["table number range", 'if (child.type === "number" && ', 'if (false && child.type === "number" && '],
    ["table choice options", 'if (child.type === "choice" && ', 'if (false && child.type === "choice" && '],
    ["table name", "if (!NAME_PATTERN.test(keys[i]))", "if (false)"],
    ["table empty group", "if (keys.length === 0)", "if (false)"],
    ["table defect throws", "if (defect !== \"\")\n        throw new Error(\"theme: token table: \"", "if (false)\n        throw new Error(\"theme: token table: \""],
    ["package name", "if (!isPackageName(files.directoryName))", "if (false)"],
    ["package name pattern", "PACKAGE_NAME_PATTERN.test(name)", "true"],
    ["package reserved name", "if (files.directoryName === DEFAULT_NAME && files.shipped !== true)", "if (false)"],
    ["package name mismatch", "if (shell.name !== files.directoryName)", "if (false)"],
    ["terminal slot name", "if (!hasOwn(expected, keys[i]))", "if (false)"],
    ["terminal colour syntax", "if (colour === null)", "if (false)"],
    ["appearance table", "if (defect !== \"\")\n        return refusal(\"appearance-table\"", "if (false)\n        return refusal(\"appearance-table\""],
    ["appearance palette", 'if (!isLeaf(accent) || accent.type !== "color" || Object.keys(palette).length !== 1)', "if (!isLeaf(accent))"],
    ["appearance light tree", "if (!isPlainObject(light))", "if (false)"],
    ["appearance light judged", "if (!stated.ok)\n        return stated;\n    for", "if (false)\n        return stated;\n    for"],
    ["appearance input", "if (hasOwn(stated.overrides, APPEARANCE_INPUTS[i]))", "if (false)"],
    ["appearance mode", 'var overrides = mode === "light" ? stated.overrides : {};', "var overrides = stated.overrides;"],
    ["appearance theme mode", 'if (typeof mode !== "string")', "if (false)"],
    ["appearance theme input", "if (value === undefined)\n            return refusal(\"appearance-theme\"", "if (false)\n            return refusal(\"appearance-theme\""],
    ["appearance inputs applied", "overrides[APPEARANCE_INPUTS[j]] = value;", ""]
];

const source = fs.readFileSync(judgeFile, "utf8");
const temp = fs.mkdtempSync(path.join(os.tmpdir(), "theme-logic-control-"));
try {
    for (const [label, needle, replacement] of CONTROLS) {
        assert.equal(source.split(needle).length, 2, `control "${label}": the text to replace must occur once`);
        const mutant = path.join(temp, "ThemeLogic.js");
        fs.writeFileSync(mutant, source.replace(needle, () => replacement));
        let failed = false;
        try {
            verify(load(mutant));
        } catch (e) {
            failed = true;
        }
        assert.ok(failed, `control "${label}": the suite passed on a judge without that rule`);
    }
} finally {
    fs.rmSync(temp, { recursive: true, force: true });
}
console.log(`test-theme-logic: ok documents=${ACCEPTED.length + REFUSED.length} controls=${CONTROLS.length}`);
