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
const path = require("node:path");
const { load } = require("../bin/lib/qml-library.js");

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
    // The list motion: slow for travel and resize, normal for the fade, and
    // mul(250, 1.2) = 300 for a row's entrance; the rise is space.sm.
    ["motion.list.travel.duration", 250],
    ["motion.list.travel.easing", "outQuint"],
    ["motion.list.resize.duration", 250],
    ["motion.list.fade.duration", 150],
    ["motion.list.enter.duration", 300],
    ["motion.list.enter.easing", "outQuint"],
    ["motion.list.stagger", 18],
    ["motion.list.staggerRows", 8],
    ["motion.list.rise", 6],
    ["hyprland.border.size", 2],
    ["hyprland.window.radius", 0],
    ["hyprland.window.roundingPower", 2],
    ["hyprland.motion.preset", "smooth"],
    ["hyprland.shadow.color", "#0000008c"],
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
    ["text.code.lineHeight", 1.5],
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
    ["row.height", 36],
    ["row.labelWidth", 130],
    ["row.lineGap", 4],
    ["stack.row", 4],
    ["stack.group", 12],
    ["stack.section", 24],
    ["button.paddingX", 9],
    ["textField.paddingX", 9],
    ["textField.height", 30],
    ["segmented.height", 30],
    ["segmented.paddingX", 9],
    ["listItem.paddingX", 12],
    ["menu.item.paddingX", 12],
    ["field.paddingX", 0],
    ["field.labelWidth", 130],
    ["field.labelGap", 12],
    ["toggle.size.sm.width", 28],
    ["toggle.size.sm.height", 16],
    ["toggle.size.md.width", 36],
    ["toggle.size.md.height", 20],
    ["badge.size.sm.height", 20],
    ["badge.size.sm.paddingX", 6],
    ["badge.size.md.height", 24],
    ["badge.size.md.paddingX", 8],
    ["codeLine.padding", 8],
    ["kbd.paddingX", 4],
    ["kbd.paddingY", 2],
    ["iconButton.restOpacity", 0.6],
    ["voiceOrb.size", 96],
    ["voiceOrb.radius", 0.28],
    ["voiceOrb.gap", 0.045],
    ["voiceOrb.stroke", 1.5],
    ["voiceOrb.arcStroke", 0.75],
    ["voiceOrb.amplitude", 0.018],
    ["voiceOrb.waveCount", 3],
    ["voiceOrb.arcSpan", 2.4],
    ["voiceOrb.arcOpacity", 0.6],
    ["voiceOrb.attack", 70],
    ["voiceOrb.release", 250],
    ["voiceOrb.period", 6000],
    ["voiceOrb.tone.accent", "#ff5a36ff"],
    ["voiceOrb.tone.info", "#74a7f7ff"],
    ["voiceOrb.tone.success", "#b4c96fff"],
    ["voiceOrb.tone.warning", "#ffb000ff"],
    ["voiceOrb.tone.danger", "#f43f5eff"],
    ["voiceOrb.tone.muted", "#aaaaabff"],
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
    // The dialog: 360 px wide, mul(4, 3) = 12 padding and 12 from the
    // free area's edges, mul(4, 2) = 8 between its blocks and mul(4, 1.5) =
    // 6 between its actions; its card is the raised surface,
    // mix(#000000, #d7d7d9, 0.075): 215 * 0.075 = 16.125, 217 * 0.075 =
    // 16.275.
    ["dialog.width", 360],
    ["dialog.margin", 12],
    ["dialog.padding", 12],
    ["dialog.gap", 8],
    ["dialog.actionGap", 6],
    ["dialog.background", "#101010ff"],
    ["dialog.titleRole", "h3"],
    ["dialog.bodyRole", "body"],
    // The angled card: Omarchy's 28 pixel lean and 3 pixel selected
    // outline; its outline is borderStrong, mix(#000000, #d7d7d9, 0.27):
    // 215 * 0.27 = 58.05, 217 * 0.27 = 58.59; its wash the background at
    // 0.42: 255 * 0.42 = 107.1.
    ["angledCard.skew", 28],
    ["angledCard.border", "#3a3a3bff"],
    ["angledCard.borderWidth", 1],
    ["angledCard.selectedBorder", "#ff5a36ff"],
    ["angledCard.selectedBorderWidth", 3],
    ["angledCard.dim", "#0000006b"],
    // The carousel: Omarchy's 768 by 475 card and 108 by 432 slices, 30
    // over each other; v1's reference rail, 768 + 13 * (108 - 30) + 2 * 20
    // = 1822, its unit held from 0.35 to 2, two cards built past the shown
    // ones and a decode of at most 2560; the rail moves over
    // motion.duration.normal, 150 ms at motion.scale 1.
    ["carousel.expandedWidth", 768],
    ["carousel.expandedHeight", 475],
    ["carousel.sliceWidth", 108],
    ["carousel.sliceHeight", 432],
    ["carousel.overlap", 30],
    ["carousel.referenceSteps", 13],
    ["carousel.referenceMargin", 20],
    ["carousel.minScale", 0.35],
    ["carousel.maxScale", 2],
    ["carousel.band", 2],
    ["carousel.decodeCap", 4096],
    ["carousel.previewDwell", 250],
    ["carousel.duration", 150],
    ["desktopPreview.referenceWidth", 1600],
    ["desktopPreview.referenceHeight", 900],
    ["desktopPreview.barHeight", 42],
    ["desktopPreview.terminalWidthShare", 0.56],
    ["desktopPreview.barOpacity", 0.86]
];

// A document that is accepted, and the values it must resolve to.
const ACCEPTED = [
    { tokens: { palette: { accent: "#123456", info: "#234567", success: "#345678", warning: "#456789", danger: "#56789a" }, color: { textMuted: "#6789ab" } }, want: [["voiceOrb.tone.accent", "#123456ff"], ["voiceOrb.tone.info", "#234567ff"], ["voiceOrb.tone.success", "#345678ff"], ["voiceOrb.tone.warning", "#456789ff"], ["voiceOrb.tone.danger", "#56789aff"], ["voiceOrb.tone.muted", "#6789abff"]] },
    { tokens: { motion: { scale: 0 }, voiceOrb: { attack: 90, release: 300, period: 4000 } }, want: [["voiceOrb.attack", 0], ["voiceOrb.release", 0], ["voiceOrb.period", 0]] },
    { tokens: { motion: { scale: 2 } }, want: [["voiceOrb.attack", 140], ["voiceOrb.release", 500], ["voiceOrb.period", 12000]] },
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
    { tokens: { space: { unit: 5 } }, want: [["space.xs", 5], ["space.sm", 8], ["space.xl", 20], ["bar.gap", 10], ["row.paddingX", 15], ["listItem.paddingX", 15], ["field.paddingX", 0], ["stack.row", 5], ["badge.size.sm.paddingX", 8], ["codeLine.padding", 10], ["kbd.paddingX", 5], ["kbd.paddingY", 3]] },
    // One shared token moves every control that follows the rhythm.
    { tokens: { control: { paddingX: 12, gap: 5 } }, want: [["button.paddingX", 12], ["textField.paddingX", 12], ["segmented.paddingX", 12], ["button.gap", 5], ["textField.gap", 5], ["listItem.gap", 5], ["menu.item.gap", 5], ["toast.contentGap", 5], ["bar.item.iconGap", 5], ["bar.item.paddingX", 6]] },
    { tokens: { size: { control: { md: 34, lg: 44 } } }, want: [["textField.height", 34], ["segmented.height", 34], ["menu.item.height", 34], ["row.height", 44], ["listItem.height", 44], ["listItem.twoLineHeight", 66]] },
    { tokens: { row: { paddingX: 16 } }, want: [["listItem.paddingX", 16], ["menu.item.paddingX", 16], ["field.paddingX", 0], ["button.paddingX", 9]] },
    { tokens: { field: { paddingX: 6 } }, want: [["field.paddingX", 6], ["listItem.paddingX", 12]] },
    { tokens: { font: { size: 16 } }, want: [["text.body.size", 16], ["text.hint.size", 14]] },
    { tokens: { motion: { scale: 0 } }, want: [["motion.duration.fast", 0], ["motion.duration.slow", 0], ["motion.list.travel.duration", 0], ["motion.list.enter.duration", 0], ["motion.list.stagger", 0], ["motion.list.rise", 6]] },
    // The list motion follows the scale steps it names: slow at 400 travels
    // 400 and enters mul(400, 1.2) = 480.
    { tokens: { motion: { duration: { slow: 400 } } }, want: [["motion.list.travel.duration", 400], ["motion.list.resize.duration", 400], ["motion.list.enter.duration", 480]] },
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
    { tokens: { radius: { md: "{radius.full}" }, hyprland: { window: { radius: 32 } } }, want: [["radius.md", 4096], ["hyprland.window.radius", 32]] },
    { tokens: { radius: { md: "mul({space.unit}, 1.5)" } }, want: [["radius.md", 6]] },
    { tokens: { hyprland: { border: { size: 4 }, window: { radius: 8, roundingPower: 3 }, motion: { preset: "snappy" }, shadow: { color: "#11223344" } } }, want: [["hyprland.border.size", 4], ["hyprland.window.radius", 8], ["hyprland.window.roundingPower", 3], ["hyprland.motion.preset", "snappy"], ["hyprland.shadow.color", "#11223344"]] },
    { tokens: { scheme: { mode: "light" }, palette: { background: "#f7f7f7" } }, want: [["hyprland.shadow.color", "#4545458c"]] },
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
    { tokens: { radius: { md: 33 } }, reason: "range", token: "hyprland.window.radius" },
    { tokens: { hyprland: { border: { size: 21 } } }, reason: "range", token: "hyprland.border.size" },
    { tokens: { hyprland: { window: { radius: 33 } } }, reason: "range", token: "hyprland.window.radius" },
    { tokens: { hyprland: { window: { roundingPower: 11 } } }, reason: "range", token: "hyprland.window.roundingPower" },
    { tokens: { hyprland: { motion: { preset: "bouncy" } } }, reason: "option", token: "hyprland.motion.preset" },
    { tokens: { hyprland: { gaps: 8 } }, reason: "unknown-token", token: "hyprland.gaps" },
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
    [{ motion: { scale: { type: "number", value: 1, min: 0, max: 4 } }, size: { panel: { sm: { type: "length", value: 1, min: "0" } } } }, "size.panel.sm.min must be a finite number"],
    [{ motion: { scale: { type: "number", value: 1, min: 0, max: 4 } }, size: { panel: { sm: { type: "length", value: 1, min: 4, max: 2 } } } }, "size.panel.sm.min must not be greater than max"],
    [{ toast: { corner: { type: "choice", value: "top" } } }, "toast.corner is a choice without options"],
    [{ palette: { "on-accent": { type: "color", value: "#fff" } } }, "palette.on-accent is not a token name"],
    [{ palette: {} }, "group palette is empty"],
    [{ palette: { accent: "#fff" } }, "palette.accent is neither a group nor a token"],
    [{ palette: { accent: { type: "color", value: "#fff" } } }, "motion.scale must be a number token"],
    [{ motion: { scale: { type: "length", value: 1 } } }, "motion.scale must be a number token"]
];

// The catalog index. CATALOG_ENTRY is valid; each refused row plants one
// defect in a copy of it, by the key path it names. The palette names are
// the table's palette group, written out here, not read from the table.
const CATALOG_PALETTE = { background: "#000000", foreground: "#ffffff", accent: "#fff", success: "#00ff00", warning: "#ffff00", danger: "#ff0000", info: "#0000ff" };
const CATALOG_IMAGERY = { repo: "https://github.com/vanillagreencom/vgs-themes", release: "themes-v1", archive: "vgs-theme-probe-r1.tar.gz", size: 1, sha256: "0123456789abcdef".repeat(4) };
const CATALOG_ENTRY = { name: "probe", mode: "dark", thumbnail: "probe/thumbnail.jpg", palette: CATALOG_PALETTE, imagery: CATALOG_IMAGERY };
const catalog = entries => JSON.stringify({ schemaVersion: 1, entries });
// CATALOG_ENTRY with the value at dotted KEY set to VALUE, or removed when
// VALUE is REMOVED.
const REMOVED = Symbol("removed");
function entryWith(key, value) {
    const entry = JSON.parse(JSON.stringify(CATALOG_ENTRY));
    const parts = key.split(".");
    const parent = parts.slice(0, -1).reduce((node, part) => node[part], entry);
    if (value === REMOVED) delete parent[parts[parts.length - 1]];
    else parent[parts[parts.length - 1]] = value;
    return entry;
}
// [label, index text, reason, token, detail or undefined]
const CATALOG_REFUSED = [
    ["not JSON", "{", "catalog-json", ""],
    ["null document", "null", "catalog-document", "", "got=null"],
    ["array document", "[]", "catalog-document", "", "got=[]"],
    ["unknown document key", JSON.stringify({ schemaVersion: 1, entries: [], themes: [] }), "catalog-document", "", "key=themes"],
    ["missing schema version", JSON.stringify({ entries: [] }), "catalog-document", "", "key=schemaVersion"],
    ["schema version", JSON.stringify({ schemaVersion: 2, entries: [] }), "catalog-schema-version", ""],
    ["entries not a list", JSON.stringify({ schemaVersion: 1, entries: { probe: CATALOG_ENTRY } }), "catalog-entries", ""],
    ["entry not an object", catalog(["probe"]), "catalog-entry", "entries.0", 'got="probe"'],
    ["unknown entry key", catalog([entryWith("pair", "")]), "catalog-entry", "entries.0", "key=pair"],
    ["missing entry key", catalog([entryWith("imagery", REMOVED)]), "catalog-entry", "entries.0", "key=imagery"],
    ["name with a space", catalog([entryWith("name", "my theme")]), "package-name", "entries.0.name"],
    ["name leaving the directory", catalog([entryWith("name", "../probe")]), "package-name", "entries.0.name"],
    ["reserved vgs", catalog([entryWith("name", "vgs")]), "reserved-name", "entries.0.name", "name=vgs"],
    ["reserved targets", catalog([entryWith("name", "targets")]), "reserved-name", "entries.0.name", "name=targets"],
    ["reserved catalog", catalog([entryWith("name", "catalog")]), "reserved-name", "entries.0.name", "name=catalog"],
    ["reserved thumbnails", catalog([entryWith("name", "thumbnails")]), "reserved-name", "entries.0.name", "name=thumbnails"],
    ["duplicate name", catalog([CATALOG_ENTRY, entryWith("mode", "light")]), "duplicate-name", "entries.1.name", "name=probe"],
    ["unknown mode", catalog([entryWith("mode", "dim")]), "catalog-mode", "entries.0.mode"],
    ["thumbnail leaving the catalog", catalog([entryWith("thumbnail", "../probe.jpg")]), "catalog-thumbnail", "entries.0.thumbnail"],
    ["absolute thumbnail", catalog([entryWith("thumbnail", "/probe.jpg")]), "catalog-thumbnail", "entries.0.thumbnail"],
    ["empty thumbnail segment", catalog([entryWith("thumbnail", "probe//thumbnail.jpg")]), "catalog-thumbnail", "entries.0.thumbnail"],
    ["thumbnail not a string", catalog([entryWith("thumbnail", 7)]), "catalog-thumbnail", "entries.0.thumbnail"],
    ["palette not an object", catalog([entryWith("palette", null)]), "catalog-palette", "entries.0.palette", "got=null"],
    ["missing palette colour", catalog([entryWith("palette.info", REMOVED)]), "catalog-palette", "entries.0.palette", "key=info"],
    ["unknown palette colour", catalog([entryWith("palette.accent2", "#000000")]), "catalog-palette", "entries.0.palette", "key=accent2"],
    ["palette colour syntax", catalog([entryWith("palette.accent", "red")]), "catalog-palette", "entries.0.palette.accent"],
    ["palette colour type", catalog([entryWith("palette.accent", 7)]), "catalog-palette", "entries.0.palette.accent"],
    ["imagery not an object", catalog([entryWith("imagery", "themes-v1")]), "catalog-imagery", "entries.0.imagery", 'got="themes-v1"'],
    ["missing imagery key", catalog([entryWith("imagery.sha256", REMOVED)]), "catalog-imagery", "entries.0.imagery", "key=sha256"],
    ["unknown imagery key", catalog([entryWith("imagery.rev", 1)]), "catalog-imagery", "entries.0.imagery", "key=rev"],
    ["http repo", catalog([entryWith("imagery.repo", "http://github.com/vanillagreencom/vgs-themes")]), "catalog-repo", "entries.0.imagery.repo"],
    ["file repo", catalog([entryWith("imagery.repo", "file:///srv/vgs-themes")]), "catalog-repo", "entries.0.imagery.repo"],
    ["owner/name repo", catalog([entryWith("imagery.repo", "vanillagreencom/vgs-themes")]), "catalog-repo", "entries.0.imagery.repo"],
    ["repo without a path", catalog([entryWith("imagery.repo", "https://github.com")]), "catalog-repo", "entries.0.imagery.repo"],
    ["repo with credentials", catalog([entryWith("imagery.repo", "https://user@github.com/vanillagreencom/vgs-themes")]), "catalog-repo", "entries.0.imagery.repo"],
    ["repo with a port", catalog([entryWith("imagery.repo", "https://github.com:8443/vanillagreencom/vgs-themes")]), "catalog-repo", "entries.0.imagery.repo"],
    ["repo with a trailing slash", catalog([entryWith("imagery.repo", "https://github.com/vanillagreencom/vgs-themes/")]), "catalog-repo", "entries.0.imagery.repo"],
    ["repo with a query", catalog([entryWith("imagery.repo", "https://github.com/vanillagreencom/vgs-themes?x=1")]), "catalog-repo", "entries.0.imagery.repo"],
    ["repo not a string", catalog([entryWith("imagery.repo", null)]), "catalog-repo", "entries.0.imagery.repo"],
    ["repo a list that reads as a URL", catalog([entryWith("imagery.repo", ["https://github.com/vanillagreencom/vgs-themes"])]), "catalog-repo", "entries.0.imagery.repo"],
    ["release leaving the path", catalog([entryWith("imagery.release", "../themes-v1")]), "catalog-imagery", "entries.0.imagery.release"],
    ["archive with a separator", catalog([entryWith("imagery.archive", "a/vgs-theme-probe-r1.tar.gz")]), "catalog-imagery", "entries.0.imagery.archive"],
    ["zero size", catalog([entryWith("imagery.size", 0)]), "catalog-size", "entries.0.imagery.size"],
    ["negative size", catalog([entryWith("imagery.size", -1)]), "catalog-size", "entries.0.imagery.size"],
    ["fractional size", catalog([entryWith("imagery.size", 1.5)]), "catalog-size", "entries.0.imagery.size"],
    ["size as text", catalog([entryWith("imagery.size", "1")]), "catalog-size", "entries.0.imagery.size"],
    ["upper-case sha256", catalog([entryWith("imagery.sha256", "0123456789ABCDEF".repeat(4))]), "catalog-sha256", "entries.0.imagery.sha256"],
    ["short sha256", catalog([entryWith("imagery.sha256", "0".repeat(63))]), "catalog-sha256", "entries.0.imagery.sha256"],
    ["sha256 not a string", catalog([entryWith("imagery.sha256", 1)]), "catalog-sha256", "entries.0.imagery.sha256"]
];
// A package a catalog entry names: theme.json with MODE and ACCENT over
// CATALOG_PALETTE, under NAME.
const catalogTheme = (name, mode, accent) => JSON.stringify({ schemaVersion: 1, name, tokens: { scheme: { mode }, palette: Object.assign({}, CATALOG_PALETTE, { accent }) } });
const READABILITY_ROLES = ["color.text", "color.textHeading", "color.textMuted", "color.textFaint", "color.accent", "color.success", "color.warning", "color.danger", "color.info"];
const READABILITY_SURFACES = ["color.background", "color.surface", "color.surfaceRaised", "color.surfaceSunken"];
const truncateRatio = value => Math.floor(value * 100) / 100;
const plain = value => JSON.parse(JSON.stringify(value));

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
    assert.deepEqual(plain(judge.READABILITY_TEXT_ROLES), READABILITY_ROLES);
    assert.deepEqual(plain(judge.READABILITY_SURFACES), READABILITY_SURFACES);
    assert.equal(judge.READABILITY_FLOOR, 4.5);
    assert.equal(judge.contrastRatio(judge.parseColor("#000000"), judge.parseColor("#ffffff")), 21);
    assert.deepEqual(plain(judge.readabilityShortfalls(defaults.values)), [], "default vgs readability");
    const lightText = fs.readFileSync(path.join(repo, "themes", "light", "theme.json"), "utf8");
    const light = judge.accept(TOKENS, lightText);
    assert.equal(light.ok, true, light.ok ? "" : judge.refusalLine(light));
    assert.deepEqual(plain(judge.readabilityShortfalls(light.values)), [], "default light readability");
    const faintFailure = judge.accept(TOKENS, document({ color: { textFaint: "#111111" } }));
    assert.equal(faintFailure.ok, true, faintFailure.ok ? "" : judge.refusalLine(faintFailure));
    const faintShortfalls = judge.readabilityShortfalls(faintFailure.values);
    assert.deepEqual(
        Object.assign({}, faintShortfalls[0], { ratio: truncateRatio(faintShortfalls[0].ratio) }),
        { text: "color.textFaint", surface: "color.background", ratio: 1.11, floor: 4.5 }
    );
    const accentFailure = judge.accept(TOKENS, document({ palette: { accent: "#111111" } }));
    assert.equal(accentFailure.ok, true, accentFailure.ok ? "" : judge.refusalLine(accentFailure));
    assert.equal(judge.readabilityShortfalls(accentFailure.values).some(row => row.text === "color.accent" && row.surface === "color.background"), true);
    const statusFailure = judge.accept(TOKENS, document({ color: { success: "#111111" } }));
    assert.equal(statusFailure.ok, true, statusFailure.ok ? "" : judge.refusalLine(statusFailure));
    assert.equal(judge.readabilityShortfalls(statusFailure.values).some(row => row.text === "color.success" && row.surface === "color.background"), true);
    const translucentFailure = judge.accept(TOKENS, document({ color: { textFaint: "alpha({palette.foreground}, 0.5)" } }));
    assert.equal(translucentFailure.ok, true, translucentFailure.ok ? "" : judge.refusalLine(translucentFailure));
    assert.deepEqual(plain(judge.readabilityShortfalls(translucentFailure.values)[0]), { text: "color.textFaint", surface: "color.background", ratio: null, floor: 4.5 });

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

    for (const name of ["targets", "catalog", "thumbnails"]) {
        const result = judge.acceptPackage(TOKENS, { directoryName: name, themeJson: JSON.stringify({ schemaVersion: 1, name, tokens: {} }), shipped: true });
        assert.equal(result.ok, false, name);
        assert.equal(result.reason, "reserved-name", name);
        assert.equal(result.detail, "name=" + name, name);
    }

    const index = judge.acceptCatalogIndex(TOKENS, catalog([CATALOG_ENTRY, entryWith("name", "bare")].map((entry, i) => i === 0 ? entry : Object.assign(entry, { mode: "light", thumbnail: null, imagery: null }))));
    assert.equal(index.ok, true, index.ok ? "" : judge.refusalLine(index));
    // The judge runs in its own context, so its objects compare as JSON.
    assert.deepEqual(plain(index.entries), [
        { name: "probe", mode: "dark", thumbnail: "probe/thumbnail.jpg", palette: { background: "#000000ff", foreground: "#ffffffff", accent: "#ffffffff", success: "#00ff00ff", warning: "#ffff00ff", danger: "#ff0000ff", info: "#0000ffff" }, imagery: CATALOG_IMAGERY },
        { name: "bare", mode: "light", thumbnail: null, palette: { background: "#000000ff", foreground: "#ffffffff", accent: "#ffffffff", success: "#00ff00ff", warning: "#ffff00ff", danger: "#ff0000ff", info: "#0000ffff" }, imagery: null }
    ]);
    assert.deepEqual(plain(judge.acceptCatalogIndex(TOKENS, catalog([]))), { ok: true, entries: [] });
    for (const [label, text, reason, token, detail] of CATALOG_REFUSED) {
        let result;
        assert.doesNotThrow(() => { result = judge.acceptCatalogIndex(TOKENS, text); }, label);
        assert.equal(result.ok, false, label);
        assert.equal(result.reason, reason, label);
        assert.equal(result.token, token, label);
        if (detail !== undefined) assert.equal(result.detail, detail, label);
    }

    // A catalogued package is judged as the installed package it becomes,
    // and the index states its own mode and palette.
    const probe = index.entries[0];
    const accepted = judge.acceptCatalogEntry(TOKENS, probe, { themeJson: catalogTheme("probe", "dark", "#ffffff") });
    assert.equal(accepted.ok, true, accepted.ok ? "" : judge.refusalLine(accepted));
    assert.equal(accepted.name, "probe");
    const entryRefusals = [
        ["name mismatch", probe, { themeJson: catalogTheme("other", "dark", "#ffffff") }, "name-mismatch", ""],
        ["mode mismatch", probe, { themeJson: catalogTheme("probe", "light", "#ffffff") }, "catalog-mode-mismatch", "scheme.mode"],
        ["palette mismatch", probe, { themeJson: catalogTheme("probe", "dark", "#fffffe") }, "catalog-palette-mismatch", "palette.accent"],
        ["bad terminal", probe, { themeJson: catalogTheme("probe", "dark", "#ffffff"), terminalJson: JSON.stringify({ schemaVersion: 1, slots: Object.assign({}, TERMINAL_SLOTS, { color3: "red" }) }) }, "terminal-colour", "terminal.color3"],
        ["installed vgs", Object.assign({}, probe, { name: "vgs" }), { themeJson: catalogTheme("vgs", "dark", "#ffffff") }, "reserved-name", ""],
        ["files not an object", probe, null, "package", ""]
    ];
    for (const [label, entry, files, reason, token] of entryRefusals) {
        const result = judge.acceptCatalogEntry(TOKENS, entry, files);
        assert.equal(result.ok, false, label);
        assert.equal(result.reason, reason, label);
        assert.equal(result.token, token, label);
    }

    // The shipped catalog: its index and every package it names pass.
    const catalogDir = path.join(repo, "themes", "catalog");
    const shipped = judge.acceptCatalogIndex(TOKENS, fs.readFileSync(path.join(catalogDir, "index.json"), "utf8"));
    assert.equal(shipped.ok, true, shipped.ok ? "" : judge.refusalLine(shipped));
    assert.ok(shipped.entries.some(entry => entry.name === "nord"), "the shipped catalog lists nord");
    for (const entry of shipped.entries) {
        const terminal = path.join(catalogDir, entry.name, "terminal.json");
        const result = judge.acceptCatalogEntry(TOKENS, entry, {
            themeJson: fs.readFileSync(path.join(catalogDir, entry.name, "theme.json"), "utf8"),
            terminalJson: fs.existsSync(terminal) ? fs.readFileSync(terminal, "utf8") : undefined
        });
        assert.equal(result.ok, true, `${entry.name}: ${result.ok ? "" : judge.refusalLine(result)}`);
    }

    for (const name of ["vgs", "tokyo-night", "Nord2", "a.b_c"])
        assert.equal(judge.isPackageName(name), true, name);
    for (const name of ["", ".", "..", "../x", "a/b", "a b", "-x", ".x", "x\n", 7, undefined])
        assert.equal(judge.isPackageName(name), false, JSON.stringify(name));

    for (const name of ["DP-1", "HDMI-A-1", "eDP-1", "HEADLESS-2", "SMOKE_HIDPI"])
        assert.equal(judge.isOutputName(name), true, name);
    for (const name of ["", "-DP", "_DP", "DP 1", "DP.1", "DP/1", "DP-1\n", null, 1])
        assert.equal(judge.isOutputName(name), false, JSON.stringify(name));

    // The theme capability's set screen and download options, as argv.
    for (const [screen, want] of [
        [null, []],
        [undefined, []],
        ["*", ["--every-screen"]],
        ["DP-1", ["--screen", "DP-1"]],
        ["../x", null],
        ["", null],
        ["**", null],
        [1, null]
    ]) assert.deepEqual(JSON.parse(JSON.stringify(judge.setScreenArguments(screen))), want, "set screen " + JSON.stringify(screen));
    for (const [options, want] of [
        [undefined, []],
        [{}, []],
        [{ update: false }, []],
        [{ update: true }, ["--update"]],
        [null, null],
        [true, null],
        [[], null],
        [{ update: "yes" }, null],
        [{ update: true, force: true }, null]
    ]) assert.deepEqual(JSON.parse(JSON.stringify(judge.wallpaperArguments(options))), want, "wallpapers options " + JSON.stringify(options));

    for (const text of ["/a", "/home/u/.config/vgs/themes/x/backgrounds/a.png", "/a b/.c"])
        assert.equal(judge.isAbsolutePath(text), true, text);
    for (const text of ["", "/", "a.png", "./a.png", "~/a.png", "//a", "/a//b", "/a/", "/a/./b", "/a/../b", "/..", "/a\u0000b", null, ["/a"]])
        assert.equal(judge.isAbsolutePath(text), false, JSON.stringify(text));

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
    ["table length finite min", 'if (child.min !== undefined && (typeof child.min !== "number" || !isFinite(child.min)))', "if (false)"],
    ["table length max order", 'if (child.min !== undefined && child.max !== undefined && child.min > child.max)', "if (false)"],
    ["length token range", ': leaf.type === "length" ? [\n                leaf.min === undefined ? RANGES.length[0] : leaf.min,\n                leaf.max === undefined ? RANGES.length[1] : leaf.max\n            ] : RANGES[leaf.type];', ': RANGES[leaf.type];'],
    ["table choice options", 'if (child.type === "choice" && ', 'if (false && child.type === "choice" && '],
    ["table name", "if (!NAME_PATTERN.test(keys[i]))", "if (false)"],
    ["table empty group", "if (keys.length === 0)", "if (false)"],
    ["table defect throws", "if (defect !== \"\")\n        throw new Error(\"theme: token table: \"", "if (false)\n        throw new Error(\"theme: token table: \""],
    ["package name", "if (!isPackageName(files.directoryName))", "if (false)"],
    ["package name pattern", "PACKAGE_NAME_PATTERN.test(name)", "true"],
    ["output name pattern", "OUTPUT_NAME_PATTERN.test(name)", "true"],
    ["set every screen", 'return ["--every-screen"];', 'return ["--screen", screen];'],
    ["set output name", 'return isOutputName(screen) ? ["--screen", screen] : null;', 'return ["--screen", screen];'],
    ["wallpapers options object", "if (!isPlainObject(options))\n        return null;", "if (false)\n        return null;"],
    ["wallpapers options keys", 'if (keys[i] !== "update")', "if (false)"],
    ["wallpapers update boolean", 'if (typeof options.update !== "boolean")', "if (false)"],
    ["wallpapers update flag", 'return options.update ? ["--update"] : [];', "return [];"],
    ["absolute path leading slash", 'text.charAt(0) !== "/" || ', ""],
    ["absolute path NUL", ' || text.indexOf("\\u0000") !== -1', ""],
    ["absolute path segments", 'if (segments[i] === "" || segments[i] === "." || segments[i] === "..")', "if (false)"],
    ["package reserved name", "if (files.directoryName === DEFAULT_NAME && files.shipped !== true)", "if (false)"],
    ["package reserved directory", "if (RESERVED_DIRECTORIES.indexOf(files.directoryName) !== -1)", "if (false)"],
    ["catalog document", "if (!isPlainObject(document))\n        return refusal(\"catalog-document\"", "if (false)\n        return refusal(\"catalog-document\""],
    ["catalog document keys", "if (defect !== \"\")\n        return refusal(\"catalog-document\"", "if (false)\n        return refusal(\"catalog-document\""],
    ["catalog unknown key", "if (keys.indexOf(own[i]) === -1)", "if (false)"],
    ["catalog missing key", "if (!hasOwn(value, keys[i]))", "if (false)"],
    ["catalog schema version", "if (document.schemaVersion !== CATALOG_SCHEMA_VERSION)", "if (false)"],
    ["catalog entries list", "if (!Array.isArray(document.entries))", "if (false)"],
    ["catalog entry object", "if (!isPlainObject(entry))", "if (false)"],
    ["catalog entry keys", "if (defect !== \"\")\n        return refusal(\"catalog-entry\"", "if (false)\n        return refusal(\"catalog-entry\""],
    ["catalog name", "if (!isPackageName(entry.name))", "if (false)"],
    ["catalog reserved vgs", "entry.name === DEFAULT_NAME || ", ""],
    ["catalog reserved directory", " || RESERVED_DIRECTORIES.indexOf(entry.name) !== -1", ""],
    ["catalog duplicate name", "if (hasOwn(seen, judged.entry.name))", "if (false)"],
    ["catalog mode", "if (nodeAt(tokens, SCHEME_MODE).options.indexOf(entry.mode) === -1)", "if (false)"],
    ["catalog thumbnail", "if (entry.thumbnail !== null && !isCatalogPath(entry.thumbnail))", "if (false)"],
    ["catalog thumbnail segments", "text.split(\"/\").every(isPackageName)", "true"],
    ["catalog palette object", "if (!isPlainObject(entry.palette))", "if (false)"],
    ["catalog palette keys", "if (defect !== \"\")\n        return refusal(\"catalog-palette\"", "if (false)\n        return refusal(\"catalog-palette\""],
    ["catalog palette colour", "if (colour === null)\n            return refusal(\"catalog-palette\"", "if (false)\n            return refusal(\"catalog-palette\""],
    ["catalog palette resolved form", "palette[names[j]] = formatColor(colour);", "palette[names[j]] = entry.palette[names[j]];"],
    ["catalog imagery object", "if (!isPlainObject(imagery))", "if (false)"],
    ["catalog imagery keys", "if (defect !== \"\")\n        return refusal(\"catalog-imagery\"", "if (false)\n        return refusal(\"catalog-imagery\""],
    ["catalog repo type", "if (typeof imagery.repo !== \"string\" || ", "if ("],
    ["catalog repo pattern", "!CATALOG_REPO_PATTERN.test(imagery.repo)", "false"],
    ["catalog release", "if (!isPackageName(imagery.release))", "if (false)"],
    ["catalog archive", "if (!isPackageName(imagery.archive))", "if (false)"],
    ["catalog size integer", "!Number.isSafeInteger(imagery.size) || ", ""],
    ["catalog size positive", " || imagery.size <= 0", ""],
    ["catalog sha256", "if (typeof imagery.sha256 !== \"string\" || !SHA256_PATTERN.test(imagery.sha256))", "if (false)"],
    ["catalog entry files", "if (!isPlainObject(files))\n        return refusal(\"package\", \"\", \"got=\" + JSON.stringify(files));\n    var accepted", "if (false)\n        return refusal(\"package\", \"\", \"got=\" + JSON.stringify(files));\n    var accepted"],
    ["catalog entry installed", "terminalJson: files.terminalJson, shipped: false });", "terminalJson: files.terminalJson, shipped: true });"],
    ["catalog entry package verdict", "if (!accepted.ok)\n        return accepted;", "if (false)\n        return accepted;"],
    ["catalog mode mismatch", "if (accepted.values.scheme.mode !== entry.mode)", "if (false)"],
    ["catalog palette mismatch", "if (accepted.values.palette[names[i]] !== entry.palette[names[i]])", "if (false)"],
    ["package name mismatch", "if (shell.name !== files.directoryName)", "if (false)"],
    ["terminal slot name", "if (!hasOwn(expected, keys[i]))", "if (false)"],
    ["terminal colour syntax", "if (colour === null)\n            return refusal(\"terminal-colour\"", "if (false)\n            return refusal(\"terminal-colour\""],
    ["appearance table", "if (defect !== \"\")\n        return refusal(\"appearance-table\"", "if (false)\n        return refusal(\"appearance-table\""],
    ["appearance palette", 'if (!isLeaf(accent) || accent.type !== "color" || Object.keys(palette).length !== 1)', "if (!isLeaf(accent))"],
    ["appearance light tree", "if (!isPlainObject(light))", "if (false)"],
    ["appearance light judged", "if (!stated.ok)\n        return stated;\n    for", "if (false)\n        return stated;\n    for"],
    ["appearance input", "if (hasOwn(stated.overrides, APPEARANCE_INPUTS[i]))", "if (false)"],
    ["appearance mode", 'var overrides = mode === "light" ? stated.overrides : {};', "var overrides = stated.overrides;"],
    ["appearance theme mode", 'if (typeof mode !== "string")', "if (false)"],
    ["appearance theme input", "if (value === undefined)\n            return refusal(\"appearance-theme\"", "if (false)\n            return refusal(\"appearance-theme\""],
    ["appearance inputs applied", "overrides[APPEARANCE_INPUTS[j]] = value;", ""],
    ["readability contrast ratio", "return (light + 0.05) / (dark + 0.05);", "return 1;"],
    ["readability accent role", "    \"color.accent\",\n", ""],
    ["readability text roles", "    \"color.success\",\n", ""],
    ["readability surfaces", "    \"color.surfaceRaised\",\n", ""],
    ["readability floor", "var READABILITY_FLOOR = 4.5;", "var READABILITY_FLOOR = 1;"],
    ["readability translucency", "var ratio = text === null || surface === null || text.a < 1 || surface.a < 1\n                ? null\n                : contrastRatio(text, surface);", "var ratio = contrastRatio(text, surface);"]
];

const source = fs.readFileSync(judgeFile, "utf8");
fs.mkdirSync(path.join(repo, "tmp"), { recursive: true });
const temp = fs.mkdtempSync(path.join(repo, "tmp", "theme-logic-control-"));
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
