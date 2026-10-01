#!/usr/bin/env node
// Table-driven checks for shell/Core/PluginLogic.js, loaded under node through
// bin/lib/qml-library.js. The controls at the end edit a copy of the judge,
// one rule at a time, and the suite must fail on every copy. Exit 1 when any
// row or control fails.
"use strict";
const fs = require("fs");
const path = require("path");
const { load } = require("../bin/lib/qml-library.js");

const LOGIC = path.join(__dirname, "..", "shell", "Core", "PluginLogic.js");
const LUCIDE = path.join(__dirname, "..", "shell", "Ui", "icons", "Lucide.js");
const MANAGERS = path.join(__dirname, "..", "shell", "Core", "PackageManagers.js");
const LAYER = path.join(__dirname, "..", "shell", "Core", "HyprlandLayer.js");
const SETTING_VALUES = path.join(__dirname, "..", "shell", "Commons", "SettingValues.js");
// The core's own requirements, judged by the function a manifest's are.
const CORE_REQUIREMENTS = path.join(__dirname, "..", "config", "requirements.json");

let failures = 0;
function report(name, got, want) {
    const g = JSON.stringify(got), w = JSON.stringify(want);
    if (g === w) { console.log("  ok    " + name); return; }
    failures += 1;
    console.log("  FAIL  " + name + "\n        got  " + g + "\n        want " + w);
}

// Every row against one loaded judge, `ctx`, each result handed to `check`.
function suite(ctx, check) {
    const bar = { schemaVersion: 1, id: "vgs.bar", name: "Bar", version: "0.1.0", author: "VGS", description: "d", kinds: ["bar"], entryPoints: { bar: "Bar.qml" } };
    const clock = { schemaVersion: 1, id: "vgs.clock", name: "Clock", version: "0.1.0", author: "VGS", description: "d", kinds: ["bar-widget"], entryPoints: { "bar-widget": "Widget.qml" }, defaultSection: "center" };
    const svc = { schemaVersion: 1, id: "acme.svc", name: "S", version: "1", author: "a", description: "d", kinds: ["service"], entryPoints: { service: "S.qml" } };

    // validateManifest: one row per rule, defect planted in `patch`. A refusal
    // row pins the start of the error text, so a neighbouring rule catching the
    // same fixture does not pass for it.
    const manifestRows = [
        ["valid bar manifest", {}, null],
        ["valid pane manifest", { kinds: ["pane"], entryPoints: { pane: "Pane.qml" }, pane: { group: "System", order: 10 } }, null],
        ["kind pane without pane key", { kinds: ["pane"], entryPoints: { pane: "Pane.qml" } }, "kind pane needs a pane declaration"],
        ["pane key without pane kind", { pane: { group: "System", order: 10 } }, "pane needs kind pane"],
        ["pane key with unknown key", { kinds: ["pane"], entryPoints: { pane: "Pane.qml" }, pane: { group: "System", order: 10, x: 1 } }, "pane has unknown key"],
        ["pane group is one printable line", { kinds: ["pane"], entryPoints: { pane: "Pane.qml" }, pane: { group: "", order: 10 } }, "pane.group must be a printable line"],
        ["pane order is finite", { kinds: ["pane"], entryPoints: { pane: "Pane.qml" }, pane: { group: "System", order: null } }, "pane.order must be a finite number"],
        ["session is a shared capability", { capabilities: ["session"] }, null],
        ["unknown top-level key", { keepLoaded: true }, "unknown key"],
        ["schemaVersion 2", { schemaVersion: 2 }, "schemaVersion must be 1"],
        ["id without namespace", { id: "bar" }, "id must be dotted"],
        ["id with uppercase", { id: "vgs.Bar" }, "id must be dotted"],
        ["missing description", { description: "" }, "description must be"],
        ["empty kinds", { kinds: [] }, "kinds must be a non-empty array"],
        ["unknown kind", { kinds: ["widget"] }, "unknown kind"],
        ["kind declared twice", { kinds: ["bar", "bar"] }, "kind \"bar\" is declared twice"],
        ["license empty", { license: "" }, "license must be a non-empty string"],
        ["entryPoints not an object", { entryPoints: "Bar.qml" }, "entryPoints must be an object"],
        ["entry point missing for kind", { entryPoints: {} }, "entryPoints.bar is required"],
        ["entry point for an undeclared kind", { entryPoints: { bar: "Bar.qml", service: "S.qml" } }, "entryPoints.service names a kind"],
        ["entry point escapes directory", { entryPoints: { bar: "../x.qml" } }, "entryPoints.bar must stay inside"],
        ["entry point absolute", { entryPoints: { bar: "/etc/x.qml" } }, "entryPoints.bar must stay inside"],
        ["requires is refused by name", { requires: ["vgs.bar"] }, "requires is refused: a plugin names no other plugin (D005)"],
        ["requirements declaring a command", { requirements: [{ command: "gum", packages: { pacman: "gum", aur: "gum-bin", emerge: "app-misc/gum" }, optional: true, purpose: "Draws the update dialogs" }] }, null],
        ["requirements with only a command and a purpose", { requirements: [{ command: "notify-send", purpose: "Sends notices" }] }, null],
        ["requirements not a list", { requirements: { command: "gum" } }, "requirements must be a list"],
        ["a requirement that is a plugin id string", { requirements: ["vgs.settings"] }, "requirements.0 must be an object"],
        ["a requirement with an unknown key", { requirements: [{ command: "gum", purpose: "p", plugin: "vgs.settings" }] }, "requirements.0 has unknown key \"plugin\""],
        ["a requirement command that is a path", { requirements: [{ command: "/usr/bin/gum", purpose: "p" }] }, "requirements.0.command must be a bare command name looked up on PATH, got \"/usr/bin/gum\""],
        ["a requirement without a command", { requirements: [{ purpose: "p" }] }, "requirements.0.command must be a bare command name looked up on PATH, got undefined"],
        ["a requirement command spelt as a plugin id", { requirements: [{ command: "vgs.settings", purpose: "p" }] }, "requirements.0.command \"vgs.settings\" is spelt as a plugin id: a requirement names a command, never a plugin (D005)"],
        ["a requirement command declared twice", { requirements: [{ command: "gum", purpose: "p" }, { command: "gum", purpose: "q" }] }, "requirements.1.command \"gum\" is declared twice"],
        ["requirement packages not an object", { requirements: [{ command: "gum", packages: ["gum"], purpose: "p" }] }, "requirements.0.packages must be an object of manager ids to package names"],
        ["requirement packages naming an unknown manager", { requirements: [{ command: "gum", packages: { zypper: "gum" }, purpose: "p" }] }, "requirements.0.packages names the unknown manager \"zypper\""],
        ["a requirement package starting with a dash", { requirements: [{ command: "gum", packages: { pacman: "-Sy" }, purpose: "p" }] }, "requirements.0.packages.pacman must be a package name"],
        ["a requirement package with a space", { requirements: [{ command: "gum", packages: { apt: "gum fzf" }, purpose: "p" }] }, "requirements.0.packages.apt must be a package name"],
        ["requirement optional not a boolean", { requirements: [{ command: "gum", optional: "yes", purpose: "p" }] }, "requirements.0.optional must be a boolean when present"],
        ["a requirement without a purpose", { requirements: [{ command: "gum" }] }, "requirements.0.purpose must be one printable line of 1 to 120 characters"],
        ["a blank requirement purpose", { requirements: [{ command: "gum", purpose: "  " }] }, "requirements.0.purpose must be one printable line"],
        ["a requirement purpose with a newline", { requirements: [{ command: "gum", purpose: "one\ntwo" }] }, "requirements.0.purpose must be one printable line"],
        ["a requirement purpose of 121 characters", { requirements: [{ command: "gum", purpose: "p".repeat(121) }] }, "requirements.0.purpose must be one printable line"],
        ["a requirement purpose of 120 characters", { requirements: [{ command: "gum", purpose: "p".repeat(120) }] }, null],
        ["appearance naming a .js file", { appearance: "Appearance.js" }, null],
        ["appearance naming a nested .js file", { appearance: "look/Appearance.js" }, null],
        ["appearance not a string", { appearance: { tokens: {} } }, "appearance must name a .js file"],
        ["appearance naming a QML file", { appearance: "Appearance.qml" }, "appearance must name a .js file"],
        ["appearance escaping the directory", { appearance: "../Appearance.js" }, "appearance must stay inside"],
        ["appearance absolute", { appearance: "/etc/Appearance.js" }, "appearance must stay inside"],
        ["capabilities not an array", { capabilities: "compositor" }, "capabilities must be an array"],
        ["unknown capability", { capabilities: ["network"] }, "unknown capability"],
        ["settings not an object", { settings: [] }, "settings must be an object"],
        ["settings carrying an id", { settings: { id: "x" } }, "settings must not carry an id key"],
        ["settings placement outside PLACEMENTS", { settings: { placement: "middle" } }, "settings.placement must be one of"],
        ["settings placement in PLACEMENTS", { settings: { placement: "top-right" } }, null],
        ["defaultSection without the widget kind", { defaultSection: "left" }, "defaultSection needs kind bar-widget"],
        ["defaultSection unknown", { kinds: ["bar-widget"], entryPoints: { "bar-widget": "W.qml" }, defaultSection: "top" }, "defaultSection must be one of"],
        ["known capability", { capabilities: ["compositor"] }, null],
        ["schema not an object", { schema: [] }, "schema must be an object"],
        ["schema entry carrying the id key", { schema: { id: { type: "string", label: "x" } } }, "schema must not carry an id key"],
        ["schema entry not an object", { settings: { a: "x" }, schema: { a: "string" } }, "schema.a must be an object"],
        ["schema entry with an unknown key", { settings: { a: "x" }, schema: { a: { type: "string", label: "A", bogus: 1 } } }, "schema.a has unknown key"],
        ["icon naming a shipped icon", { icon: "settings" }, null],
        ["icon naming no shipped icon", { icon: "not-an-icon" }, "icon must name an icon of the shipped set"],
        ["icon that is not a string", { icon: 3 }, "icon must name an icon of the shipped set"],
        ["icon naming a prototype member", { icon: "constructor" }, "icon must name an icon of the shipped set"],
        ["a bounded, grouped number entry", { settings: { a: 8 }, schema: { a: { type: "number", label: "A", min: 2, max: 30, step: 1, group: "Timing" } } }, null],
        ["a number bounded on one side", { settings: { a: 8 }, schema: { a: { type: "number", label: "A", min: 0 } } }, null],
        ["a grouped string entry", { settings: { a: "x" }, schema: { a: { type: "string", label: "A", presets: [{ value: "x" }], group: "Look" } } }, null],
        ["min on a string entry", { settings: { a: "x" }, schema: { a: { type: "string", label: "A", presets: [{ value: "x" }], min: 1 } } }, "schema.a.min needs type number"],
        ["step on a boolean entry", { settings: { a: true }, schema: { a: { type: "boolean", label: "A", step: 1 } } }, "schema.a.step needs type number"],
        ["max on an enum entry", { settings: { a: "x" }, schema: { a: { type: "enum", label: "A", options: ["x"], max: 1 } } }, "schema.a.max needs type number"],
        ["a min that is not a number", { settings: { a: 8 }, schema: { a: { type: "number", label: "A", min: "1" } } }, "schema.a.min must be a finite number"],
        ["a max that is not finite", { settings: { a: 8 }, schema: { a: { type: "number", label: "A", max: null } } }, "schema.a.max must be a finite number"],
        ["min equal to max", { settings: { a: 8 }, schema: { a: { type: "number", label: "A", min: 8, max: 8 } } }, "schema.a.min must be less than max"],
        ["min above max", { settings: { a: 8 }, schema: { a: { type: "number", label: "A", min: 30, max: 2 } } }, "schema.a.min must be less than max"],
        ["a zero step", { settings: { a: 8 }, schema: { a: { type: "number", label: "A", step: 0 } } }, "schema.a.step must be positive"],
        ["a negative step", { settings: { a: 8 }, schema: { a: { type: "number", label: "A", step: -1 } } }, "schema.a.step must be positive"],
        ["an empty group", { settings: { a: "x" }, schema: { a: { type: "string", label: "A", presets: [{ value: "x" }], group: "" } } }, "schema.a.group must be a non-empty string"],
        ["a group that is not a string", { settings: { a: "x" }, schema: { a: { type: "string", label: "A", presets: [{ value: "x" }], group: 2 } } }, "schema.a.group must be a non-empty string"],
        ["a default under its min", { settings: { a: 1 }, schema: { a: { type: "number", label: "A", min: 2, max: 30 } } }, "settings.a does not fit its schema: want=at-least:2"],
        ["a default over its max", { settings: { a: 31 }, schema: { a: { type: "number", label: "A", min: 2, max: 30 } } }, "settings.a does not fit its schema: want=at-most:30"],
        ["a default off its step fits", { settings: { a: 2.5 }, schema: { a: { type: "number", label: "A", min: 2, max: 30, step: 1 } } }, null],
        ["schema entry with an unknown type", { settings: { a: "x" }, schema: { a: { type: "color", label: "A" } } }, "schema.a.type must be one of"],
        ["schema entry without a label", { settings: { a: "x" }, schema: { a: { type: "string", presets: [{ value: "x" }] } } }, "schema.a.label must be a non-empty string"],
        ["schema entry with a non-string description", { settings: { a: "x" }, schema: { a: { type: "string", label: "A", presets: [{ value: "x" }], description: 1 } } }, "schema.a.description must be a string"],
        ["enum entry without options", { settings: { a: "x" }, schema: { a: { type: "enum", label: "A" } } }, "schema.a.options must be a non-empty array"],
        ["enum entry with a repeated option", { settings: { a: "x" }, schema: { a: { type: "enum", label: "A", options: ["x", "x"] } } }, "schema.a.options must hold distinct"],
        ["options on a non-enum entry", { settings: { a: "x" }, schema: { a: { type: "string", label: "A", options: ["x"] } } }, "schema.a.options needs type enum"],
        ["a string takes choices from status", { capabilities: ["status"], status: { devices: { type: "choices", label: "Devices" } }, settings: { a: "" }, schema: { a: { type: "string", label: "A", optionsFrom: "devices" } } }, null],
        ["a configured choice need not be offered", { capabilities: ["status"], status: { devices: { type: "choices", label: "Devices", hidden: true } }, settings: { a: "removed" }, schema: { a: { type: "string", label: "A", optionsFrom: "devices" } } }, null],
        ["optionsFrom on a number", { settings: { a: 1 }, schema: { a: { type: "number", label: "A", optionsFrom: "devices" } } }, "schema.a.optionsFrom needs type string"],
        ["optionsFrom on an enum", { settings: { a: "x" }, schema: { a: { type: "enum", label: "A", options: ["x"], optionsFrom: "devices" } } }, "schema.a.optionsFrom needs type string"],
        ["optionsFrom on a boolean", { settings: { a: true }, schema: { a: { type: "boolean", label: "A", optionsFrom: "devices" } } }, "schema.a.optionsFrom needs type string"],
        ["optionsFrom not a string", { settings: { a: "" }, schema: { a: { type: "string", label: "A", optionsFrom: 3 } } }, "schema.a.optionsFrom must name a status key"],
        ["optionsFrom empty", { settings: { a: "" }, schema: { a: { type: "string", label: "A", optionsFrom: "" } } }, "schema.a.optionsFrom must name a status key"],
        ["optionsFrom with a malformed key", { settings: { a: "" }, schema: { a: { type: "string", label: "A", optionsFrom: "a b" } } }, "schema.a.optionsFrom must name a status key"],
        ["optionsFrom undeclared", { settings: { a: "" }, schema: { a: { type: "string", label: "A", optionsFrom: "devices" } } }, "schema.a.optionsFrom must name a choices status entry"],
        ["optionsFrom inherited", { settings: { a: "" }, schema: { a: { type: "string", label: "A", optionsFrom: "constructor" } } }, "schema.a.optionsFrom must name a choices status entry"],
        ["optionsFrom names text", { capabilities: ["status"], status: { devices: { type: "text", label: "Devices" } }, settings: { a: "" }, schema: { a: { type: "string", label: "A", optionsFrom: "devices" } } }, "schema.a.optionsFrom must name a choices status entry"],
        ["options and optionsFrom cannot coexist", { capabilities: ["status"], status: { devices: { type: "choices", label: "Devices" } }, settings: { a: "" }, schema: { a: { type: "string", label: "A", options: ["x"], optionsFrom: "devices" } } }, "schema.a.options needs type enum"],
        ["a string entry needs presets or optionsFrom", { settings: { a: "x" }, schema: { a: { type: "string", label: "A" } } }, "schema.a with type string must declare presets or optionsFrom"],
        ["presets and optionsFrom cannot coexist", { capabilities: ["status"], status: { devices: { type: "choices", label: "Devices" } }, settings: { a: "x" }, schema: { a: { type: "string", label: "A", presets: [{ value: "x" }], optionsFrom: "devices" } } }, "schema.a must not declare both presets and optionsFrom"],
        ["presets need string or number", { settings: { a: true }, schema: { a: { type: "boolean", label: "A", presets: [{ value: true }] } } }, "schema.a.presets needs type string or number"],
        ["presets must be non-empty", { settings: { a: "x" }, schema: { a: { type: "string", label: "A", presets: [] } } }, "schema.a.presets must be a non-empty array"],
        ["preset rows are objects", { settings: { a: "x" }, schema: { a: { type: "string", label: "A", presets: ["x"] } } }, "schema.a.presets.0 must be an object"],
        ["preset rows have known keys", { settings: { a: "x" }, schema: { a: { type: "string", label: "A", presets: [{ value: "x", name: "X" }] } } }, "schema.a.presets.0 has unknown key \"name\""],
        ["preset value is required", { settings: { a: "x" }, schema: { a: { type: "string", label: "A", presets: [{ label: "X" }] } } }, "schema.a.presets.0.value is required"],
        ["preset label is printable", { settings: { a: "x" }, schema: { a: { type: "string", label: "A", presets: [{ value: "x", label: "A\nB" }] } } }, "schema.a.presets.0.label must be a printable line"],
        ["empty preset needs a label", { settings: { a: "" }, schema: { a: { type: "string", label: "A", presets: [{ value: "" }] } } }, "schema.a.presets.0.label is required when value is empty"],
        ["preset values are distinct", { settings: { a: "x" }, schema: { a: { type: "string", label: "A", presets: [{ value: "x" }, { value: "x" }] } } }, "schema.a.presets must hold distinct values"],
        ["preset value fits schema", { settings: { a: 2 }, schema: { a: { type: "number", label: "A", min: 2, max: 4, presets: [{ value: 1 }] } } }, "schema.a.presets.0.value does not fit its schema: want=at-least:2"],
        ["allowCustom needs presets", { settings: { a: 2 }, schema: { a: { type: "number", label: "A", allowCustom: true } } }, "schema.a.allowCustom needs presets"],
        ["allowCustom is boolean", { settings: { a: 2 }, schema: { a: { type: "number", label: "A", presets: [{ value: 2 }], allowCustom: "yes" } } }, "schema.a.allowCustom must be a boolean"],
        ["format needs string", { settings: { a: 2 }, schema: { a: { type: "number", label: "A", presets: [{ value: 2 }], format: "datetime" } } }, "schema.a.format needs type string"],
        ["format needs presets", { settings: { a: "HH:mm" }, schema: { a: { type: "string", label: "A", format: "datetime" } } }, "schema.a.format needs presets"],
        ["format names datetime", { settings: { a: "HH:mm" }, schema: { a: { type: "string", label: "A", presets: [{ value: "HH:mm" }], format: "strftime" } } }, "schema.a.format must be one of datetime"],
        ["datetime presets are judged", { settings: { a: "HH:mm" }, schema: { a: { type: "string", label: "A", presets: [{ value: "'abc" }], format: "datetime" } } }, "schema.a.presets.0.value does not fit its schema: want=datetime-format reason=unclosed-quote"],
        ["unit needs number", { settings: { a: "x" }, schema: { a: { type: "string", label: "A", presets: [{ value: "x" }], unit: "seconds" } } }, "schema.a.unit needs type number"],
        ["unit is known", { settings: { a: 2 }, schema: { a: { type: "number", label: "A", unit: "weeks" } } }, "schema.a.unit must be one of seconds, minutes, hours, days"],
        ["schema entry without a default", { schema: { a: { type: "string", label: "A", presets: [{ value: "x" }] } } }, "schema.a has no default in settings"],
        ["default of the wrong type", { settings: { a: 3 }, schema: { a: { type: "string", label: "A", presets: [{ value: "x" }] } } }, "settings.a does not fit its schema: want=string"],
        ["enum default outside its options", { settings: { a: "z" }, schema: { a: { type: "enum", label: "A", options: ["x", "y"] } } }, "settings.a does not fit its schema: want=one-of:x|y"],
        ["configure without a schema", { capabilities: ["configure"] }, "capability configure needs a schema"],
        ["configure with a schema", { capabilities: ["configure"], settings: { a: true }, schema: { a: { type: "boolean", label: "A" } } }, null],
        ["status with every entry key", { capabilities: ["status"], requirements: [{ command: "secret-tool", purpose: "p" }], status: { slackToken: { type: "presence", label: "Slack token", group: "Slack", hint: "h", action: { label: "Install", install: ["secret-tool"] }, command: "secret-tool store x", hidden: false }, detail: { type: "data", label: "Detail" } } }, null],
        ["status not an object", { capabilities: ["status"], status: [] }, "status must be an object"],
        ["status with no entry", { capabilities: ["status"], status: {} }, "status must declare at least one entry"],
        ["status without capability status", { status: { a: { type: "text", label: "A" } } }, "status needs capability status"],
        ["capability status without a status", { capabilities: ["status"] }, "capability status needs a status declaration"],
        ["a status key with a dash", { capabilities: ["status"], status: { "slack-token": { type: "text", label: "A" } } }, "status key \"slack-token\" must match"],
        ["a status key starting upper case", { capabilities: ["status"], status: { Token: { type: "text", label: "A" } } }, "status key \"Token\" must match"],
        ["a status entry not an object", { capabilities: ["status"], status: { a: "text" } }, "status.a must be an object"],
        ["a status entry with an unknown key", { capabilities: ["status"], status: { a: { type: "text", label: "A", run: true } } }, "status.a has unknown key \"run\""],
        ["a status entry with an unknown type", { capabilities: ["status"], status: { a: { type: "secret", label: "A" } } }, "status.a.type must be one of presence, presenceList, state, text, count, time, data, choices"],
        ["a presenceList entry with its group and hint", { capabilities: ["status"], status: { tokens: { type: "presenceList", label: "Tokens", group: "Slack", hint: "h" } } }, null],
        ["a presenceList entry with a command", { capabilities: ["status"], status: { tokens: { type: "presenceList", label: "Tokens", command: "secret-tool store x" } } }, "status.tokens.command needs an action: a command is only the Show command disclosure beside a one-click action (D061)"],
        ["a status entry without a label", { capabilities: ["status"], status: { a: { type: "text" } } }, "status.a.label must be a printable line of 1 to 60"],
        ["a status label of 61 characters", { capabilities: ["status"], status: { a: { type: "text", label: "x".repeat(61) } } }, "status.a.label must be a printable line of 1 to 60"],
        ["a status label of 60 characters", { capabilities: ["status"], status: { a: { type: "text", label: "x".repeat(60) } } }, null],
        ["a status label with a newline", { capabilities: ["status"], status: { a: { type: "text", label: "A\nB" } } }, "status.a.label must be a printable line"],
        ["an empty status group", { capabilities: ["status"], status: { a: { type: "text", label: "A", group: "" } } }, "status.a.group must be a printable line of 1 to 60"],
        ["a status hint of 201 characters", { capabilities: ["status"], status: { a: { type: "text", label: "A", hint: "x".repeat(201) } } }, "status.a.hint must be a printable line of 1 to 200"],
        ["a status hint of 200 characters", { capabilities: ["status"], status: { a: { type: "text", label: "A", hint: "x".repeat(200) } } }, null],
        ["a status command of 301 characters", { capabilities: ["status"], status: { a: { type: "text", label: "A", command: "x".repeat(301) } } }, "status.a.command must be a printable line of 1 to 300"],
        ["a status command of 300 characters beside an action", { capabilities: ["status", "tui"], tui: { setup: { script: "tui/setup.sh", title: "Set up" } }, status: { a: { type: "state", label: "A", action: { label: "Set up", tui: "setup" }, command: "x".repeat(300) } } }, null],
        ["a status command without an action", { capabilities: ["status"], status: { a: { type: "state", label: "A", command: "loginctl enable-linger" } } }, "status.a.command needs an action: a command is only the Show command disclosure beside a one-click action (D061)"],
        ["a state action opening the plugin's own TUI", { capabilities: ["status", "tui"], tui: { setup: { script: "tui/setup.sh", title: "Set up" } }, status: { a: { type: "state", label: "A", action: { label: "Set up", tui: "setup" } } } }, null],
        ["a presence action installing the plugin's own commands", { capabilities: ["status"], requirements: [{ command: "vsys", purpose: "p" }, { command: "gum", purpose: "q" }], status: { a: { type: "presence", label: "A", action: { label: "Install", install: ["vsys", "gum"] } } } }, null],
        ["an action on a count", { capabilities: ["status"], requirements: [{ command: "gum", purpose: "q" }], status: { a: { type: "count", label: "A", action: { label: "Install", install: ["gum"] } } } }, "status.a.action needs a type whose value says when it applies, one of presence, state"],
        ["an action on a presence list", { capabilities: ["status"], requirements: [{ command: "gum", purpose: "q" }], status: { a: { type: "presenceList", label: "A", action: { label: "Install", install: ["gum"] } } } }, "status.a.action needs a type whose value says when it applies"],
        ["an action that is a string", { capabilities: ["status"], status: { a: { type: "state", label: "A", action: "setup" } } }, "status.a.action must be an object"],
        ["an action with an unknown key", { capabilities: ["status"], status: { a: { type: "state", label: "A", action: { label: "Run", run: ["sh"] } } } }, "status.a.action has unknown key \"run\""],
        ["an action without a label", { capabilities: ["status", "tui"], tui: { setup: { script: "tui/setup.sh", title: "Set up" } }, status: { a: { type: "state", label: "A", action: { tui: "setup" } } } }, "status.a.action.label must be a printable line of 1 to 60"],
        ["an action label of 61 characters", { capabilities: ["status", "tui"], tui: { setup: { script: "tui/setup.sh", title: "Set up" } }, status: { a: { type: "state", label: "A", action: { label: "x".repeat(61), tui: "setup" } } } }, "status.a.action.label must be a printable line"],
        ["an action naming both a TUI and an install", { capabilities: ["status", "tui"], tui: { setup: { script: "tui/setup.sh", title: "Set up" } }, requirements: [{ command: "gum", purpose: "q" }], status: { a: { type: "state", label: "A", action: { label: "Go", tui: "setup", install: ["gum"] } } } }, "status.a.action must name exactly one of tui, install, system"],
        ["an action naming neither", { capabilities: ["status"], status: { a: { type: "state", label: "A", action: { label: "Go" } } } }, "status.a.action must name exactly one of tui, install, system"],
        ["an action naming an undeclared TUI", { capabilities: ["status", "tui"], tui: { setup: { script: "tui/setup.sh", title: "Set up" } }, status: { a: { type: "state", label: "A", action: { label: "Go", tui: "other" } } } }, "status.a.action.tui must name a script of the manifest's tui key, got \"other\""],
        ["an action naming a TUI with no tui key", { capabilities: ["status"], status: { a: { type: "state", label: "A", action: { label: "Go", tui: "setup" } } } }, "status.a.action.tui must name a script of the manifest's tui key"],
        ["an action naming an inherited TUI name", { capabilities: ["status", "tui"], tui: { setup: { script: "tui/setup.sh", title: "Set up" } }, status: { a: { type: "state", label: "A", action: { label: "Go", tui: "constructor" } } } }, "status.a.action.tui must name a script of the manifest's tui key"],
        ["an empty install", { capabilities: ["status"], status: { a: { type: "state", label: "A", action: { label: "Go", install: [] } } } }, "status.a.action.install must be a non-empty list of the manifest's requirement commands"],
        ["an install of an undeclared command", { capabilities: ["status"], requirements: [{ command: "gum", purpose: "q" }], status: { a: { type: "state", label: "A", action: { label: "Go", install: ["sudo"] } } } }, "status.a.action.install.0 must name a command of the manifest's requirements, got \"sudo\""],
        ["an install naming a command twice", { capabilities: ["status"], requirements: [{ command: "gum", purpose: "q" }], status: { a: { type: "state", label: "A", action: { label: "Go", install: ["gum", "gum"] } } } }, "status.a.action.install.1 repeats \"gum\""],
        ["a data entry with an action", { capabilities: ["status"], requirements: [{ command: "gum", purpose: "q" }], status: { a: { type: "data", label: "A", action: { label: "Go", install: ["gum"] } } } }, "status.a.action needs a type whose value says when it applies"],
        // systemSteps (D081): steps of the core's closed table, read through capability system.
        ["systemSteps naming two steps", { capabilities: ["system"], systemSteps: ["apple-displays", "i2c-dev"] }, null],
        ["every step of the table", { capabilities: ["system"], systemSteps: ["apple-displays", "i2c-dev", "service-bluetooth", "service-tailscaled", "tailscale-operator"] }, null],
        ["systemSteps that is not a list", { capabilities: ["system"], systemSteps: "i2c-dev" }, "systemSteps must be a non-empty list of steps of the core's table"],
        ["an empty systemSteps", { capabilities: ["system"], systemSteps: [] }, "systemSteps must be a non-empty list"],
        ["a step outside the table", { capabilities: ["system"], systemSteps: ["etc-shadow"] }, "systemSteps.0 must be one of apple-displays, i2c-dev, service-bluetooth, service-tailscaled, tailscale-operator, got \"etc-shadow\""],
        ["a step that is not a string", { capabilities: ["system"], systemSteps: ["i2c-dev", 3] }, "systemSteps.1 must be one of"],
        ["a step named twice", { capabilities: ["system"], systemSteps: ["i2c-dev", "i2c-dev"] }, "systemSteps.1 repeats \"i2c-dev\""],
        ["systemSteps without capability system", { systemSteps: ["i2c-dev"] }, "systemSteps needs capability system"],
        ["capability system without systemSteps", { capabilities: ["system"] }, "capability system needs a systemSteps declaration"],
        ["a state action applying a declared step", { capabilities: ["status", "system"], systemSteps: ["apple-displays"], status: { apple: { type: "state", label: "Apple displays", action: { label: "Allow", system: "apple-displays" }, command: "vgsh system apply apple-displays" } } }, null],
        ["a presence action applying a declared step", { capabilities: ["status", "system"], systemSteps: ["i2c-dev"], status: { ddc: { type: "presence", label: "DDC", action: { label: "Allow", system: "i2c-dev" } } } }, null],
        ["an action applying a step the manifest does not declare", { capabilities: ["status", "system"], systemSteps: ["i2c-dev"], status: { apple: { type: "state", label: "A", action: { label: "Allow", system: "apple-displays" } } } }, "status.apple.action.system must name a step of the manifest's systemSteps, got \"apple-displays\""],
        ["an action applying a step with no systemSteps", { capabilities: ["status"], status: { apple: { type: "state", label: "A", action: { label: "Allow", system: "apple-displays" } } } }, "status.apple.action.system must name a step of the manifest's systemSteps"],
        ["an action applying a step outside the table", { capabilities: ["status", "system"], systemSteps: ["i2c-dev"], status: { a: { type: "state", label: "A", action: { label: "Allow", system: "etc-shadow" } } } }, "status.a.action.system must name a step of the manifest's systemSteps, got \"etc-shadow\""],
        ["an action naming a system step and a TUI", { capabilities: ["status", "system", "tui"], systemSteps: ["i2c-dev"], tui: { setup: { script: "tui/setup.sh", title: "Set up" } }, status: { a: { type: "state", label: "A", action: { label: "Go", tui: "setup", system: "i2c-dev" } } } }, "status.a.action must name exactly one of tui, install, system"],
        ["an action naming a system step that is a list", { capabilities: ["status", "system"], systemSteps: ["i2c-dev"], status: { a: { type: "state", label: "A", action: { label: "Go", system: ["i2c-dev"] } } } }, "status.a.action.system must name a step of the manifest's systemSteps"],
        ["secrets beside a presence list", { capabilities: ["status", "secrets"], secrets: { service: "acme-sync", label: "Acme token" }, status: { tokens: { type: "presenceList", label: "Tokens" } } }, null],
        ["secrets not an object", { capabilities: ["status", "secrets"], secrets: "acme", status: { tokens: { type: "presenceList", label: "Tokens" } } }, "secrets must be an object"],
        ["secrets with an unknown key", { capabilities: ["status", "secrets"], secrets: { service: "acme", label: "L", schema: "x" }, status: { tokens: { type: "presenceList", label: "Tokens" } } }, "secrets has unknown key \"schema\""],
        ["a secrets service with a dot", { capabilities: ["status", "secrets"], secrets: { service: "acme.sync", label: "L" }, status: { tokens: { type: "presenceList", label: "Tokens" } } }, "secrets.service must match"],
        ["a secrets service of 65 characters", { capabilities: ["status", "secrets"], secrets: { service: "a".repeat(65), label: "L" }, status: { tokens: { type: "presenceList", label: "Tokens" } } }, "secrets.service must match"],
        ["a secrets service of 64 characters", { capabilities: ["status", "secrets"], secrets: { service: "a".repeat(64), label: "L" }, status: { tokens: { type: "presenceList", label: "Tokens" } } }, null],
        ["a secrets label with a newline", { capabilities: ["status", "secrets"], secrets: { service: "acme", label: "A\nB" }, status: { tokens: { type: "presenceList", label: "Tokens" } } }, "secrets.label must be a printable line of 1 to 60"],
        ["secrets without capability secrets", { capabilities: ["status"], secrets: { service: "acme", label: "L" }, status: { tokens: { type: "presenceList", label: "Tokens" } } }, "secrets needs capability secrets"],
        ["capability secrets without secrets", { capabilities: ["secrets"] }, "capability secrets needs a secrets declaration"],
        ["secrets with no presence list to list them", { capabilities: ["status", "secrets"], secrets: { service: "acme", label: "L" }, status: { token: { type: "presence", label: "Token" } } }, "secrets needs a presenceList status entry to list its items"],
        ["secrets with no status", { capabilities: ["secrets"], secrets: { service: "acme", label: "L" } }, "secrets needs a presenceList status entry to list its items"],
        ["a status command with a control character", { capabilities: ["status"], status: { a: { type: "text", label: "A", command: "a\u001b[2Jb" } } }, "status.a.command must be a printable line"],
        ["a status hidden that is not a boolean", { capabilities: ["status"], status: { a: { type: "text", label: "A", hidden: "yes" } } }, "status.a.hidden must be a boolean"],
        ["a data entry with a hint", { capabilities: ["status"], status: { a: { type: "data", label: "A", hint: "h" } } }, "status.a.hint needs a type Settings draws"],
        ["a data entry with a command", { capabilities: ["status"], status: { a: { type: "data", label: "A", command: "c" } } }, "status.a.command needs a type Settings draws"],
        ["a data entry that is hidden", { capabilities: ["status"], status: { a: { type: "data", label: "A", hidden: true } } }, "status.a.hidden needs a type Settings draws"],
    ];
    for (const [name, patch, want] of manifestRows) {
        const raw = Object.assign(JSON.parse(JSON.stringify(bar)), patch);
        const r = ctx.validateManifest(raw, "/p");
        check("validateManifest: " + name, r.ok ? null : r.error.slice(0, want === null ? 0 : want.length), want === null ? null : want);
    }
    // hyprland.options rows over a service whose schema holds one entry of
    // each kind an option path takes: [name, options, schema patch, want].
    const optionSettings = { sensitivity: 0, rate: 25, tap: true, natural: false, layouts: "us", profile: "flat" };
    const optionSchema = {
        sensitivity: { type: "number", label: "S", min: -1, max: 1, step: 0.05 },
        rate: { type: "number", label: "R", min: 1, max: 100, step: 1 },
        tap: { type: "boolean", label: "T" },
        natural: { type: "boolean", label: "N" },
        layouts: { type: "string", label: "L", presets: [{ value: "us" }, { value: "us,de" }], allowCustom: true },
        profile: { type: "enum", label: "P", options: ["flat", "adaptive"] }
    };
    const optionRows = [
        ["an option of each type", { sensitivity: "input.sensitivity", rate: "input.repeat_rate", tap: "input.touchpad.tap_to_click", layouts: "input.kb_layout", profile: "input.accel_profile" }, {}, null],
        ["the touchpad's enabled through its device", { tap: "device.touchpad.enabled" }, {}, null],
        ["an enum for a free string", { profile: "input.kb_options" }, {}, null],
        ["options not an object", ["input.sensitivity"], {}, "hyprland.options must be a non-empty object"],
        ["options empty", {}, {}, "hyprland.options must be a non-empty object"],
        ["a path outside the table", { tap: "input.touchpad.drag_lock" }, {}, "hyprland.options.tap must be one of input.kb_layout, "],
        ["the hyphenated option name, which Lua refuses", { tap: "input.touchpad.tap-to-click" }, {}, "hyprland.options.tap must be one of"],
        ["a path that is no string", { tap: true }, {}, "hyprland.options.tap must be one of"],
        ["an inherited path", { tap: "constructor" }, {}, "hyprland.options.tap must be one of"],
        ["one path for two settings", { tap: "input.natural_scroll", natural: "input.natural_scroll" }, {}, "hyprland.options.natural sets input.natural_scroll, which another setting sets already"],
        ["a setting with no schema entry", { lefty: "input.left_handed" }, {}, "hyprland.options.lefty names no schema entry \"lefty\""],
        ["a boolean path for a number", { rate: "input.left_handed" }, {}, "hyprland.options.rate needs a boolean schema entry, got number"],
        ["a number path for a boolean", { tap: "input.scroll_factor" }, {}, "hyprland.options.tap needs a number schema entry, got boolean"],
        ["a float without a max", { sensitivity: "input.sensitivity" }, { sensitivity: { type: "number", label: "S", min: -1 } }, "hyprland.options.sensitivity needs min and max within -1 to 1"],
        ["a float below Hyprland's range", { sensitivity: "input.sensitivity" }, { sensitivity: { type: "number", label: "S", min: -2, max: 1 } }, "hyprland.options.sensitivity needs min and max within -1 to 1"],
        ["a float above Hyprland's range", { sensitivity: "input.scroll_factor" }, { sensitivity: { type: "number", label: "S", min: 0, max: 3 } }, "hyprland.options.sensitivity needs min and max within 0 to 2"],
        ["an int with a fractional step", { rate: "input.repeat_rate" }, { rate: { type: "number", label: "R", min: 1, max: 100, step: 0.5 } }, "hyprland.options.rate needs a whole min, max and step"],
        ["an int with a fractional bound", { rate: "input.repeat_delay" }, { rate: { type: "number", label: "R", min: 1.5, max: 100 } }, "hyprland.options.rate needs a whole min, max and step"],
        ["a string for a path with choices", { layouts: "input.accel_profile" }, {}, "hyprland.options.layouts needs an enum schema entry, got string"],
        ["an enum offering a value outside the choices", { profile: "input.accel_profile" }, { profile: { type: "enum", label: "P", options: ["flat", "custom"] } }, "hyprland.options.profile offers \"custom\", not one of adaptive, flat"],
        ["a boolean for a free string", { tap: "input.kb_layout" }, {}, "hyprland.options.tap needs a string or enum schema entry, got boolean"]
    ];
    for (const [name, options, schemaPatch, want] of optionRows) {
        const raw = Object.assign(JSON.parse(JSON.stringify(svc)), { capabilities: ["hyprland"], settings: optionSettings, schema: Object.assign({}, optionSchema, schemaPatch), hyprland: { options: options } });
        const r = ctx.validateManifest(raw, "/p");
        check("hyprland.options: " + name, r.ok ? null : r.error.slice(0, want === null ? 0 : want.length), want);
    }
    check("hyprland.options needs the hyprland capability", ctx.validateManifest(Object.assign({}, svc, { settings: optionSettings, schema: optionSchema, hyprland: { options: { sensitivity: "input.sensitivity" } } }), "/p").error, "hyprland.options needs capability hyprland");
    check("hyprland.options setting names are schema setting names", ctx.validateManifest(Object.assign({}, svc, { capabilities: ["hyprland"], settings: Object.assign({}, optionSettings, { "bad\nos.exit()": "us" }), schema: Object.assign({}, optionSchema, { "bad\nos.exit()": { type: "string", label: "Bad", presets: [{ value: "us" }] } }), hyprland: { options: { "bad\nos.exit()": "input.kb_layout" } } }), "/p").error, "hyprland.options.bad\nos.exit() must be a setting name");
    check("hyprland is a known capability", ctx.validateManifest(Object.assign({}, svc, { capabilities: ["hyprland"] }), "/p").ok, true);
    check("monitors is a known capability", ctx.validateManifest(Object.assign({}, svc, { capabilities: ["monitors"] }), "/p").ok, true);
    check("panes is a known capability", ctx.validateManifest(Object.assign({}, svc, { capabilities: ["panes"] }), "/p").ok, true);
    check("a normalised manifest carries its options", (() => {
        const m = ctx.validateManifest(Object.assign({}, svc, { capabilities: ["hyprland"], settings: optionSettings, schema: optionSchema, hyprland: { options: { sensitivity: "input.sensitivity" } } }), "/p").manifest;
        return m.hyprland.options;
    })(), { sensitivity: "input.sensitivity" });
    check("validateManifest does not alias its input", (() => { const raw = JSON.parse(JSON.stringify(bar)); const m = ctx.validateManifest(raw, "/p").manifest; m.kinds.push("x"); return raw.kinds; })(), ["bar"]);
    check("validateManifest normalizes capabilities and settings", (() => { const m = ctx.validateManifest(bar, "/p").manifest; return [m.capabilities, m.settings, m.defaultSection]; })(), [[], {}, undefined]);
    check("validateManifest normalizes an absent schema to an object", ctx.validateManifest(bar, "/p").manifest.schema, {});
    check("validateManifest normalizes an absent status to an object", ctx.validateManifest(bar, "/p").manifest.status, {});
    check("validateManifest records sourceDir", ctx.validateManifest(bar, "/p").manifest.__sourceDir, "/p");
    check("validateManifest normalizes absent requirements to a list", ctx.validateManifest(bar, "/p").manifest.requirements, []);
    check("validateManifest normalizes an absent systemSteps to a list", ctx.validateManifest(bar, "/p").manifest.systemSteps, []);
    check("validateManifest keeps the declared systemSteps", ctx.validateManifest(Object.assign({}, bar, { capabilities: ["system"], systemSteps: ["i2c-dev", "apple-displays"] }), "/p").manifest.systemSteps, ["i2c-dev", "apple-displays"]);
    check("the system step table is bin/vgsh-system's", ctx.SYSTEM_STEPS, ["apple-displays", "i2c-dev", "service-bluetooth", "service-tailscaled", "tailscale-operator"]);
    const required = ctx.validateManifest(Object.assign({}, bar, { requirements: [{ command: "gum", purpose: "Dialogs" }, { command: "checkupdates", packages: { pacman: "pacman-contrib" }, optional: true, purpose: "Counts updates" }] }), "/p").manifest;
    check("validateManifest gives every requirement its packages and optional", required.requirements,
        [{ command: "gum", packages: {}, optional: false, purpose: "Dialogs" }, { command: "checkupdates", packages: { pacman: "pacman-contrib" }, optional: true, purpose: "Counts updates" }]);
    check("requirementRows: a command the scan did not find is missing, every other present", ctx.requirementRows(required, ["checkupdates", "vsys"]).map(r => [r.command, r.state]), [["gum", "present"], ["checkupdates", "missing"]]);
    check("requirementRows: every command is present when the scan missed none", ctx.requirementRows(required, []).map(r => r.state), ["present", "present"]);
    check("requirementRows does not alias the manifest", (() => { ctx.requirementRows(required, [])[1].packages.apt = "x"; return required.requirements[1].packages; })(), { pacman: "pacman-contrib" });
    check("the core's config/requirements.json passes the requirements judge", ctx.requirementsError(JSON.parse(fs.readFileSync(CORE_REQUIREMENTS, "utf8"))), "");

    // configError rows: [name, config, want]. A refusal row pins the start of
    // the error text.
    const configRows = [
        ["an empty object passes", {}, ""],
        ["every key of the table, well formed, passes", { version: 1, bar: { id: "vgs.bar", layout: { left: [{ id: "a.b" }], center: [], right: [] } }, plugins: [{ id: "a.c", x: 1 }], disabledPlugins: ["a.d"], disabledTargets: ["foot"] }, ""],
        ["a key outside the table is carried", { unrelated: { any: 1 } }, ""],
        ["a list is not a config", [], "config must be an object"],
        ["null is not a config", null, "config must be an object"],
        ["version 2", { version: 2 }, "version must be 1"],
        ["plugins not a list", { plugins: {} }, "plugins must be a list"],
        ["a plugins row without an id", { plugins: [{ id: "a.b" }, { x: 1 }] }, "plugins.1 must be an object with a string id"],
        ["a plugins row that is a string", { plugins: ["a.b"] }, "plugins.0 must be an object with a string id"],
        ["disabledPlugins not a list", { disabledPlugins: "a.b" }, "disabledPlugins must be a list"],
        ["a disabledPlugins entry that is not a string", { disabledPlugins: ["a.b", 1] }, "disabledPlugins.1 must be a string"],
        ["disabledTargets not a list", { disabledTargets: "foot" }, "disabledTargets must be a list"],
        ["a disabledTargets entry that is not a string", { disabledTargets: ["foot", null] }, "disabledTargets.1 must be a string"],
        ["bar not an object", { bar: "vgs.bar" }, "bar must be an object"],
        ["bar.id not a string", { bar: { id: 1 } }, "bar.id must be a string"],
        ["bar.layout not an object", { bar: { layout: [] } }, "bar.layout must be an object"],
        ["a section not a list", { bar: { layout: { left: { id: "a.b" } } } }, "bar.layout.left must be a list"],
        ["a layout row without an id", { bar: { layout: { center: [{ format: "x" }] } } }, "bar.layout.center.0 must be an object with a string id"],
        ["a layout row with a numeric id", { bar: { layout: { right: [{ id: 3 }] } } }, "bar.layout.right.0 must be an object with a string id"],
        ["packages with each elevation command passes", { packages: { elevate: "run0" } }, ""],
        ["packages without elevate passes", { packages: {} }, ""],
        ["packages not an object", { packages: ["sudo"] }, "packages must be an object"],
        ["an elevate outside sudo, doas and run0", { packages: { elevate: "pkexec" } }, "packages.elevate must be one of sudo, doas, run0, got \"pkexec\""],
        ["an elevate that is not a string", { packages: { elevate: true } }, "packages.elevate must be one of sudo, doas, run0, got true"],
    ];
    for (const [name, config, want] of configRows) {
        const got = ctx.configError(config);
        check("configError: " + name, got.slice(0, want === "" ? got.length : want.length), want);
    }
    // The shipped file itself: Config.ready waits for a shipped file this judge
    // passes, so a refused config/shell.json leaves every screen without a bar.
    check("configError: the repository's config/shell.json passes", ctx.configError(JSON.parse(require("fs").readFileSync(path.join(__dirname, "..", "config", "shell.json"), "utf8"))), "");

    const shipped = { version: 1, bar: { id: "vgs.bar", layout: { left: [{ id: "vgs.workspaces" }], center: [{ id: "vgs.clock" }], right: [] } }, plugins: [{ id: "acme.svc", x: 1 }], disabledPlugins: [] };

    // effectiveConfig rows: [name, user, path, want]
    const mergeRows = [
        ["no user file keeps shipped", null, "bar.id", "vgs.bar"],
        ["user bar replaces whole", { bar: { id: "other.bar" } }, "bar.layout", undefined],
        ["user plugin entry wins by id", { plugins: [{ id: "acme.svc", x: 2 }] }, "plugins.0.x", 2],
        ["shipped plugin entry survives", { plugins: [{ id: "b.c" }] }, "plugins.0.id", "acme.svc"],
        ["user plugin entry appended", { plugins: [{ id: "b.c" }] }, "plugins.1.id", "b.c"],
        ["user disabled list replaces", { disabledPlugins: ["vgs.clock"] }, "disabledPlugins.0", "vgs.clock"],
    ];
    function dig(obj, p) { return p.split(".").reduce((o, k) => (o === undefined ? undefined : o[k]), obj); }
    for (const [name, user, p, want] of mergeRows) {
        check("effectiveConfig: " + name, dig(ctx.effectiveConfig(shipped, user), p), want);
    }
    check("effectiveConfig does not alias shipped", (() => { const c = ctx.effectiveConfig(shipped, null); c.bar.id = "x"; return shipped.bar.id; })(), "vgs.bar");
    check("effectiveConfig does not alias the user file", (() => { const user = { bar: { id: "u.bar" } }; const c = ctx.effectiveConfig(shipped, user); c.bar.id = "x"; return user.bar.id; })(), "u.bar");
    check("layoutEntryOf finds the first entry in section order", ctx.layoutEntryOf({ bar: { layout: { right: [{ id: "a", n: 3 }], center: [{ id: "a", n: 2 }], left: [{ id: "b" }] } } }, "a"), { id: "a", n: 2 });
    check("layoutEntryOf is null for an unplaced id", ctx.layoutEntryOf(shipped, "acme.svc"), null);
    check("activeBarId falls back on an empty id", ctx.activeBarId({ bar: { id: "" } }, "vgs.bar"), "vgs.bar");
    check("layoutIds keeps section order left, center, right", ctx.layoutIds({ bar: { layout: { right: [{ id: "r" }], center: [{ id: "c" }], left: [{ id: "l" }] } } }), ["l", "c", "r"]);

    const manifests = {};
    for (const raw of [bar, clock, svc]) manifests[raw.id] = ctx.validateManifest(raw, "/p").manifest;
    manifests["vgs.workspaces"] = ctx.validateManifest(Object.assign({}, clock, { id: "vgs.workspaces", defaultSection: "left" }), "/p").manifest;
    manifests["vgs.svc"] = ctx.validateManifest(Object.assign({}, svc, { id: "vgs.svc" }), "/p").manifest;
    manifests["acme.bar"] = ctx.validateManifest(Object.assign({}, bar, { id: "acme.bar" }), "/p").manifest;
    manifests["vgs.barpanel"] = ctx.validateManifest(Object.assign({}, bar, { id: "vgs.barpanel", kinds: ["bar", "panel"], entryPoints: { bar: "Bar.qml", panel: "P.qml" } }), "/p").manifest;
    const noSection = Object.assign({}, clock, { id: "acme.widget", settings: { size: 3, tags: ["a"] } });
    delete noSection.defaultSection;
    manifests["acme.widget"] = ctx.validateManifest(noSection, "/p").manifest;
    manifests["vgs.widgetpanel"] = ctx.validateManifest(Object.assign({}, clock, { id: "vgs.widgetpanel", kinds: ["bar-widget", "panel"], entryPoints: { "bar-widget": "W.qml", panel: "P.qml" }, defaultSection: "right" }), "/p").manifest;
    manifests["acme.both"] = ctx.validateManifest({ schemaVersion: 1, id: "acme.both", name: "B", version: "1", author: "a", description: "d", kinds: ["service", "bar-widget"], entryPoints: { service: "S.qml", "bar-widget": "W.qml" }, defaultSection: "right", settings: { label: "probe" } }, "/p").manifest;
    manifests["acme.pane"] = ctx.validateManifest({ schemaVersion: 1, id: "acme.pane", name: "Pane", version: "1", author: "a", description: "d", kinds: ["service", "bar-widget", "pane"], entryPoints: { service: "S.qml", "bar-widget": "W.qml", pane: "Pane.qml" }, defaultSection: "right", pane: { group: "System", order: 2 }, settings: { label: "probe" }, schema: { label: { type: "string", label: "Label", presets: [{ value: "probe" }], allowCustom: true } }, capabilities: ["configure"] }, "/p").manifest;
    for (const id of Object.keys(manifests)) if (manifests[id] === undefined) { throw new Error("fixture manifest refused: " + id); }

    // isEnabled rows: [name, config, id, want]
    const enabledRows = [
        ["active bar enabled", shipped, "vgs.bar", true],
        ["placed widget enabled", shipped, "vgs.clock", true],
        ["listed third-party service enabled", shipped, "acme.svc", true],
        ["unplaced widget disabled", ctx.effectiveConfig(shipped, { bar: { id: "vgs.bar", layout: { left: [], center: [], right: [] } } }), "vgs.clock", false],
        ["unlisted third-party disabled", ctx.effectiveConfig(Object.assign({}, shipped, { plugins: [] }), null), "acme.svc", false],
        ["shipped listing survives an empty user list", ctx.effectiveConfig(shipped, { plugins: [] }), "acme.svc", true],
        ["disabledPlugins wins over placement", ctx.effectiveConfig(shipped, { disabledPlugins: ["vgs.clock"] }), "vgs.clock", false],
        ["bar id absent falls to default", ctx.effectiveConfig(shipped, { bar: {} }), "vgs.bar", true],
        ["other active bar disables default bar", ctx.effectiveConfig(shipped, { bar: { id: "other.bar" } }), "vgs.bar", false],
        ["first-party service enabled unlisted", shipped, "vgs.svc", true],
        ["first-party service disabled when listed", ctx.effectiveConfig(shipped, { disabledPlugins: ["vgs.svc"] }), "vgs.svc", false],
        ["first-party widget is not enabled unplaced", shipped, "acme.widget", false],
        ["a placed widget listed in disabledPlugins is disabled", ctx.effectiveConfig(shipped, { disabledPlugins: ["vgs.workspaces"] }), "vgs.workspaces", false],
        ["an inactive bar listed for its settings is not enabled", ctx.effectiveConfig(shipped, { plugins: [{ id: "acme.bar", x: 1 }] }), "acme.bar", false],
        ["an unplaced widget listed for its settings is not enabled", ctx.effectiveConfig(shipped, { plugins: [{ id: "acme.widget", size: 1 }] }), "acme.widget", false],
        ["an inactive first-party bar with a panel kind is not enabled", ctx.effectiveConfig(shipped, { bar: { id: "acme.bar" } }), "vgs.barpanel", false],
        ["the active first-party bar with a panel kind is enabled", ctx.effectiveConfig(shipped, { bar: { id: "vgs.barpanel" } }), "vgs.barpanel", true],
        ["a first-party widget with a panel kind is enabled unplaced", shipped, "vgs.widgetpanel", true],
    ];
    for (const [name, config, id, want] of enabledRows) {
        check("isEnabled: " + name, ctx.isEnabled(config, manifests[id], "vgs.bar"), want);
    }

    check("hiddenByDisabling the active bar names its enabled widgets", ctx.hiddenByDisabling(manifests, shipped, "vgs.bar", "vgs.bar"), ["vgs.clock", "vgs.workspaces"]);
    check("hiddenByDisabling ignores disabled widgets", ctx.hiddenByDisabling(manifests, ctx.effectiveConfig(shipped, { disabledPlugins: ["vgs.clock"] }), "vgs.bar", "vgs.bar"), ["vgs.workspaces"]);
    check("hiddenByDisabling an inactive bar is empty", ctx.hiddenByDisabling(manifests, ctx.effectiveConfig(shipped, { bar: { id: "other.bar" } }), "vgs.bar", "vgs.bar"), []);
    check("hiddenByDisabling a widget is empty", ctx.hiddenByDisabling(manifests, shipped, "vgs.clock", "vgs.bar"), []);
    check("hiddenByDisabling leaves out an enabled widget the layout does not place", ctx.hiddenByDisabling(manifests, shipped, "vgs.bar", "vgs.bar").indexOf("vgs.widgetpanel"), -1);
    check("hiddenByDisabling names a placed first-party widget with a panel kind", ctx.hiddenByDisabling(manifests, ctx.effectiveConfig(shipped, { bar: { id: "vgs.bar", layout: { left: [], center: [], right: [{ id: "vgs.widgetpanel" }] } } }), "vgs.bar", "vgs.bar"), ["vgs.widgetpanel"]);
    check("hiddenByDisabling sorts ids", ctx.hiddenByDisabling(manifests, ctx.effectiveConfig(shipped, { bar: { id: "vgs.bar", layout: { left: [{ id: "vgs.workspaces" }], center: [{ id: "vgs.clock" }], right: [{ id: "acme.widget" }] } } }), "vgs.bar", "vgs.bar"), ["acme.widget", "vgs.clock", "vgs.workspaces"]);
    check("hiddenByDisabling ignores a prototype name", ctx.hiddenByDisabling(manifests, shipped, "constructor", "vgs.bar"), []);
    check("hasOwn rejects a prototype name", ctx.hasOwn(manifests, "toString"), false);

    // effectiveLayout: placement filtered by enablement, entries copied.
    const layoutRows = [
        ["shipped layout shows both widgets", shipped, { left: [{ id: "vgs.workspaces" }], center: [{ id: "vgs.clock" }], right: [] }],
        ["a disabled widget leaves its section and its entry stays in the file", ctx.effectiveConfig(shipped, { disabledPlugins: ["vgs.clock"] }), { left: [{ id: "vgs.workspaces" }], center: [], right: [] }],
        ["an unknown id is not shown", ctx.effectiveConfig(shipped, { bar: { id: "vgs.bar", layout: { left: [{ id: "nope.x" }, { id: "vgs.workspaces" }], center: [], right: [] } } }), { left: [{ id: "vgs.workspaces" }], center: [], right: [] }],
        ["a plugin without the widget kind is not shown", ctx.effectiveConfig(shipped, { bar: { id: "vgs.bar", layout: { left: [{ id: "acme.svc" }], center: [], right: [] } } }), { left: [], center: [], right: [] }],
        ["entries keep their settings keys", ctx.effectiveConfig(shipped, { bar: { id: "vgs.bar", layout: { left: [], center: [{ id: "vgs.clock", format: "HH:mm" }], right: [] } } }), { left: [], center: [{ id: "vgs.clock", format: "HH:mm" }], right: [] }],
        ["a missing section reads as empty", ctx.effectiveConfig(shipped, { bar: { id: "vgs.bar", layout: { left: [{ id: "vgs.workspaces" }] } } }), { left: [{ id: "vgs.workspaces" }], center: [], right: [] }],
    ];
    for (const [name, config, want] of layoutRows) {
        check("effectiveLayout: " + name, ctx.effectiveLayout(config, manifests, "vgs.bar"), want);
    }
    check("effectiveLayout does not alias the configuration", (() => { const c = ctx.effectiveConfig(shipped, null); ctx.effectiveLayout(c, manifests, "vgs.bar").left[0].x = 1; return c.bar.layout.left[0].x; })(), undefined);

    // settingTargetOf rows: [kind, want]. Every kind has one target.
    for (const kind of ctx.KINDS)
        check("settingTargetOf: " + kind, ctx.settingTargetOf(kind), kind === "bar-widget" ? "layout" : "plugins");

    // settingsFor: manifest defaults under the entry a setting target names.
    check("settingsFor merges the layout entry over defaults", ctx.settingsFor(shipped, manifests["acme.widget"], "layout", { id: "acme.widget", size: 9 }), { size: 9, tags: ["a"] });
    check("settingsFor drops the id key", ctx.settingsFor(shipped, manifests["acme.widget"], "layout", { id: "acme.widget" }).id, undefined);
    check("settingsFor reads the plugins entry for a non-widget", ctx.settingsFor(ctx.effectiveConfig(shipped, { plugins: [{ id: "acme.svc", x: 2 }] }), manifests["acme.svc"], "plugins", null), { x: 2 });
    check("settingsFor is empty with no entry and no defaults", ctx.settingsFor(shipped, manifests["vgs.svc"], "plugins", null), {});
    check("settingsFor gives a service the manifest defaults under its plugins row", ctx.settingsFor(ctx.effectiveConfig(shipped, { plugins: [{ id: "acme.both", label: "changed" }] }), manifests["acme.both"], "plugins", null), { label: "changed" });
    check("settingsFor gives a widget the manifest defaults with no row", ctx.settingsFor(shipped, manifests["acme.both"], "layout", { id: "acme.both" }), { label: "probe" });
    check("settingsFor ignores a layout entry for the plugins target", ctx.settingsFor(ctx.effectiveConfig(shipped, { plugins: [{ id: "acme.both", label: "row" }] }), manifests["acme.both"], "plugins", { id: "acme.both", label: "entry" }), { label: "row" });
    check("settingsFor does not alias the entry", (() => { const e = { id: "acme.widget", tags: ["z"] }; const s2 = ctx.settingsFor(shipped, manifests["acme.widget"], "layout", e); s2.tags.push("y"); return e.tags; })(), ["z"]);
    check("settingsFor refuses a kind passed where a target belongs", (() => { try { ctx.settingsFor(shipped, manifests["acme.widget"], "bar-widget", { id: "acme.widget" }); return "returned"; } catch (e) { return e.message.split(":")[0]; } })(), "settingsFor");
    check("managerSettings shows a placed widget its first layout entry", ctx.managerSettings(ctx.effectiveConfig(shipped, { bar: { id: "vgs.bar", layout: { left: [], center: [{ id: "acme.both", label: "entry" }], right: [] } }, plugins: [{ id: "acme.both", label: "row" }] }), manifests["acme.both"]), { label: "entry" });
    check("managerSettings shows an unplaced widget-plus-service its plugins row", ctx.managerSettings(ctx.effectiveConfig(shipped, { plugins: [{ id: "acme.both", label: "row" }] }), manifests["acme.both"]), { label: "row" });
    check("managerSettings shows a service its plugins row", ctx.managerSettings(ctx.effectiveConfig(shipped, { plugins: [{ id: "acme.svc", x: 2 }] }), manifests["acme.svc"]), { x: 2 });

    // withEnabled rows: [name, user, effective, id, enabled, path, want].
    // `effective` is the merged configuration the manager reads presence from.
    const placedClock = { version: 1, bar: { id: "vgs.bar", layout: { left: [{ id: "vgs.workspaces" }], center: [{ id: "vgs.clock", format: "HH:mm:ss" }], right: [] } } };
    const listedSvc = { version: 1, plugins: [{ id: "acme.svc", x: 1 }] };
    const withRows = [
        ["disable preserves inherited disabled plugins", null, Object.assign({}, shipped, { disabledPlugins: ["vgs.clock"] }), "acme.svc", false, "disabledPlugins", ["vgs.clock", "acme.svc"]],
        ["enable removes only its inherited disabled entry", null, Object.assign({}, shipped, { disabledPlugins: ["vgs.clock", "acme.svc"] }), "acme.svc", true, "disabledPlugins", ["vgs.clock"]],
        ["an explicit empty disabled list overrides shipped entries", { disabledPlugins: [] }, ctx.effectiveConfig(Object.assign({}, shipped, { disabledPlugins: ["vgs.clock"] }), { disabledPlugins: [] }), "acme.svc", false, "disabledPlugins", ["acme.svc"]],
        ["disable bar lists it", null, shipped, "vgs.bar", false, "disabledPlugins", ["vgs.bar"]],
        ["disable twice lists it once", { disabledPlugins: ["vgs.bar"] }, shipped, "vgs.bar", false, "disabledPlugins", ["vgs.bar"]],
        ["enable bar unlists it", { disabledPlugins: ["vgs.bar"] }, shipped, "vgs.bar", true, "disabledPlugins", []],
        ["disable bar leaves the bar key alone", null, shipped, "vgs.bar", false, "bar", undefined],
        ["disable widget keeps its placement and settings", placedClock, ctx.effectiveConfig(shipped, placedClock), "vgs.clock", false, "bar.layout.center", [{ id: "vgs.clock", format: "HH:mm:ss" }]],
        ["disable widget only lists it", placedClock, ctx.effectiveConfig(shipped, placedClock), "vgs.clock", false, "disabledPlugins", ["vgs.clock"]],
        ["re-enable a placed widget changes only the disabled list", Object.assign({ disabledPlugins: ["vgs.clock"] }, placedClock), ctx.effectiveConfig(shipped, Object.assign({ disabledPlugins: ["vgs.clock"] }, placedClock)), "vgs.clock", true, "bar", placedClock.bar],
        ["enable a placed widget is idempotent", placedClock, ctx.effectiveConfig(shipped, placedClock), "vgs.clock", true, "bar", placedClock.bar],
        ["enable an unplaced widget places it in its default section", null, ctx.effectiveConfig(shipped, { bar: { id: "vgs.bar", layout: { left: [], center: [], right: [] } } }), "vgs.workspaces", true, "bar.layout.left.0.id", "vgs.workspaces"],
        ["enable an unplaced widget seeds the user bar from the effective bar", null, shipped, "acme.widget", true, "bar.layout.left", [{ id: "vgs.workspaces" }]],
        ["enable an unplaced widget keeps the effective bar id", null, shipped, "acme.widget", true, "bar.id", "vgs.bar"],
        ["a user bar key is not reseeded", { bar: { layout: { left: [], center: [], right: [] } } }, ctx.effectiveConfig(shipped, { bar: { layout: { left: [], center: [], right: [] } } }), "acme.widget", true, "bar.layout.left", []],
        ["no default section places in center", null, shipped, "acme.widget", true, "bar.layout.center.1.id", "acme.widget"],
        ["a manifest default section is used", null, ctx.effectiveConfig(shipped, { bar: { id: "vgs.bar", layout: { left: [], center: [], right: [] } } }), "acme.both", true, "bar.layout.right.0.id", "acme.both"],
        ["enable third-party service lists it", null, ctx.effectiveConfig(Object.assign({}, shipped, { plugins: [] }), null), "acme.svc", true, "plugins", [{ id: "acme.svc" }]],
        ["enable a listed third-party service keeps its row", listedSvc, ctx.effectiveConfig(shipped, listedSvc), "acme.svc", true, "plugins", [{ id: "acme.svc", x: 1 }]],
        ["disable third-party service keeps its row", listedSvc, ctx.effectiveConfig(shipped, listedSvc), "acme.svc", false, "plugins", [{ id: "acme.svc", x: 1 }]],
        ["disable third-party service lists it", listedSvc, ctx.effectiveConfig(shipped, listedSvc), "acme.svc", false, "disabledPlugins", ["acme.svc"]],
        ["enable first-party service does not list it in plugins", { disabledPlugins: ["vgs.svc"] }, shipped, "vgs.svc", true, "plugins", undefined],
        ["writes version 1", null, shipped, "acme.svc", true, "version", 1],
        ["enable bar sets it active", null, shipped, "acme.bar", true, "bar.id", "acme.bar"],
        ["enable bar seeds the layout from the effective bar", null, shipped, "acme.bar", true, "bar.layout.center.0.id", "vgs.clock"],
        ["enable the active bar changes nothing but the disabled list", { disabledPlugins: ["vgs.bar"] }, shipped, "vgs.bar", true, "bar", undefined],
        ["enable bar does not list it in plugins", null, shipped, "acme.bar", true, "plugins", undefined],
        ["enable widget does not list it in plugins", null, shipped, "acme.widget", true, "plugins", undefined],
        ["enable a widget-plus-service plugin places it and does not list it", null, shipped, "acme.both", true, "plugins", undefined],
        ["enable an unplaced widget seeds its entry with its plugins row's settings", null, ctx.effectiveConfig(shipped, { plugins: [{ id: "acme.both", label: "row", keys: {} }] }), "acme.both", true, "bar.layout.right", [{ id: "acme.both", label: "row" }]],
    ];
    for (const [name, user, effective, id, enabled, p, want] of withRows) {
        check("withEnabled: " + name, dig(ctx.withEnabled(user, manifests[id], enabled, effective), p), want);
    }
    check("withEnabled does not alias the user file", (() => { const u = { bar: { layout: { left: [], center: [], right: [] } } }; ctx.withEnabled(u, manifests["acme.widget"], true, ctx.effectiveConfig(shipped, u)); return u.bar.layout.center; })(), []);

    // isPlaced rows: [name, config, id, want]. Placement reads apart from
    // enablement.
    const placedRows = [
        ["a widget in a section is placed", shipped, "vgs.clock", true],
        ["a widget in no section is unplaced", shipped, "acme.widget", false],
        ["a disabled widget's entry still reads placed", ctx.effectiveConfig(shipped, { disabledPlugins: ["vgs.clock"] }), "vgs.clock", true],
        ["an entry of a plugin without the widget kind is no placement", ctx.effectiveConfig(shipped, { bar: { id: "vgs.bar", layout: { left: [{ id: "acme.svc" }], center: [], right: [] } } }), "acme.svc", false],
    ];
    for (const [name, config, id, want] of placedRows) check("isPlaced: " + name, ctx.isPlaced(config, manifests[id]), want);

    // placedRefusal rows: [name, config, id, want].
    const placedRefusalRows = [
        ["an enabled placed widget may be unplaced", shipped, "vgs.clock", ""],
        ["an enabled unplaced widget-plus-panel may be placed", shipped, "vgs.widgetpanel", ""],
        ["a service has no widget", shipped, "acme.svc", "refused: placed=acme.svc reason=no-bar-widget"],
        ["a bar has no widget", shipped, "vgs.bar", "refused: placed=vgs.bar reason=no-bar-widget"],
        ["a disabled widget is refused", ctx.effectiveConfig(shipped, { disabledPlugins: ["vgs.clock"] }), "vgs.clock", "refused: placed=vgs.clock reason=disabled"],
        ["an unplaced widget-only plugin is disabled", shipped, "acme.widget", "refused: placed=acme.widget reason=disabled"],
    ];
    for (const [name, config, id, want] of placedRefusalRows) check("placedRefusal: " + name, ctx.placedRefusal(config, manifests[id], "vgs.bar"), want);

    // withPlaced rows: [name, user, effective, id, placed, path, want].
    const placedBoth = { version: 1, bar: { id: "vgs.bar", layout: { left: [{ id: "acme.both", label: "left" }], center: [{ id: "vgs.clock" }], right: [{ id: "acme.both", label: "right" }] } } };
    const placedPanel = { version: 1, bar: { id: "vgs.bar", layout: { left: [], center: [{ id: "vgs.clock" }], right: [{ id: "vgs.widgetpanel" }] } } };
    const inheritedDisabled = Object.assign({}, shipped, { disabledPlugins: ["vgs.workspaces"] });
    const placeRows = [
        ["place puts the widget in its default section", null, shipped, "acme.both", true, "bar.layout.right", [{ id: "acme.both" }]],
        ["place puts a widget with no default section in center", null, shipped, "acme.widget", true, "bar.layout.center", [{ id: "vgs.clock" }, { id: "acme.widget" }]],
        ["place seeds the user bar from the effective bar", null, shipped, "acme.both", true, "bar.layout.left", [{ id: "vgs.workspaces" }]],
        ["place seeds the entry with its plugins row's settings", null, ctx.effectiveConfig(shipped, { plugins: [{ id: "acme.both", label: "row", keys: {} }] }), "acme.both", true, "bar.layout.right", [{ id: "acme.both", label: "row" }]],
        ["place lists nothing in plugins", null, shipped, "acme.both", true, "plugins", undefined],
        ["place a placed widget changes nothing", placedBoth, ctx.effectiveConfig(shipped, placedBoth), "acme.both", true, "bar", placedBoth.bar],
        ["place keeps the user's disabled list", { disabledPlugins: ["vgs.svc"] }, ctx.effectiveConfig(shipped, { disabledPlugins: ["vgs.svc"] }), "acme.both", true, "disabledPlugins", ["vgs.svc"]],
        ["place writes no inherited disabled list", null, inheritedDisabled, "acme.both", true, "disabledPlugins", undefined],
        ["place writes version 1", null, shipped, "acme.both", true, "version", 1],
        ["unplace removes every entry in every section and keeps other widgets", placedBoth, ctx.effectiveConfig(shipped, placedBoth), "acme.both", false, "bar.layout", { left: [], center: [{ id: "vgs.clock" }], right: [] }],
        ["unplace keeps the bar id", placedBoth, ctx.effectiveConfig(shipped, placedBoth), "acme.both", false, "bar.id", "vgs.bar"],
        ["unplace seeds the user bar from the effective bar", null, shipped, "vgs.clock", false, "bar.layout", { left: [{ id: "vgs.workspaces" }], center: [], right: [] }],
        ["unplace a third-party widget-plus-service lists it with its first entry's settings", placedBoth, ctx.effectiveConfig(shipped, placedBoth), "acme.both", false, "plugins", [{ id: "acme.both", label: "left" }]],
        ["unplace a listed third-party widget-plus-service keeps its row", Object.assign({ plugins: [{ id: "acme.both", label: "row" }] }, placedBoth), ctx.effectiveConfig(shipped, Object.assign({ plugins: [{ id: "acme.both", label: "row" }] }, placedBoth)), "acme.both", false, "plugins", [{ id: "acme.both", label: "row" }]],
        ["unplace a first-party widget-plus-panel lists nothing", placedPanel, ctx.effectiveConfig(shipped, placedPanel), "vgs.widgetpanel", false, "plugins", undefined],
        ["unplace a widget-only plugin lists nothing", null, shipped, "vgs.clock", false, "plugins", undefined],
        ["unplace an unplaced widget changes nothing", null, shipped, "acme.both", false, "bar", undefined],
        ["unplace keeps the user's disabled list", Object.assign({ disabledPlugins: ["vgs.svc"] }, placedBoth), ctx.effectiveConfig(shipped, Object.assign({ disabledPlugins: ["vgs.svc"] }, placedBoth)), "acme.both", false, "disabledPlugins", ["vgs.svc"]],
        ["unplace writes no inherited disabled list", null, inheritedDisabled, "vgs.clock", false, "disabledPlugins", undefined],
    ];
    for (const [name, user, effective, id, placed, p, want] of placeRows) {
        check("withPlaced: " + name, dig(ctx.withPlaced(user, manifests[id], placed, effective), p), want);
    }
    // Enablement after an unplace, read from the merged result.
    const unplacedEnabled = (user, id) => ctx.isEnabled(ctx.effectiveConfig(shipped, ctx.withPlaced(user, manifests[id], false, ctx.effectiveConfig(shipped, user))), manifests[id], "vgs.bar");
    check("withPlaced: a third-party widget-plus-service stays enabled once unplaced", unplacedEnabled(placedBoth, "acme.both"), true);
    check("withPlaced: a first-party widget-plus-panel stays enabled once unplaced", unplacedEnabled(placedPanel, "vgs.widgetpanel"), true);
    check("withPlaced: a widget-only plugin reads disabled once unplaced", unplacedEnabled(null, "vgs.clock"), false);
    // Applying an edit twice gives the file applying it once gives.
    const twice = (user, id, placed) => {
        const once = ctx.withPlaced(user, manifests[id], placed, ctx.effectiveConfig(shipped, user));
        return JSON.stringify(ctx.withPlaced(once, manifests[id], placed, ctx.effectiveConfig(shipped, once))) === JSON.stringify(once);
    };
    check("withPlaced: placing twice is placing once", twice(null, "acme.both", true), true);
    check("withPlaced: unplacing twice is unplacing once", twice(placedBoth, "acme.both", false), true);
    check("withPlaced does not alias the user file on place", (() => { const u = { bar: { layout: { left: [], center: [], right: [] } } }; ctx.withPlaced(u, manifests["acme.both"], true, ctx.effectiveConfig(shipped, u)); return u.bar.layout.right; })(), []);
    check("withPlaced does not alias the effective plugins row it seeds the entry from", (() => { const e = ctx.effectiveConfig(shipped, { plugins: [{ id: "acme.both", tags: ["z"] }] }); const out = ctx.withPlaced(null, manifests["acme.both"], true, e); out.bar.layout.right[0].tags.push("y"); return ctx.pluginRow(e, "acme.both").tags; })(), ["z"]);
    // A third-party plugin whose only kind is bar-widget: unplacing lists no
    // row, so it reads disabled, and the disabled list stays the user's.
    const placedWidget = { version: 1, disabledPlugins: ["vgs.svc"], bar: { id: "vgs.bar", layout: { left: [], center: [{ id: "vgs.clock" }], right: [{ id: "acme.widget", size: 5 }] } } };
    const unplacedWidget = ctx.withPlaced(placedWidget, manifests["acme.widget"], false, ctx.effectiveConfig(shipped, placedWidget));
    check("withPlaced: unplace a third-party widget-only plugin lists nothing", unplacedWidget.plugins, undefined);
    check("withPlaced: unplace a third-party widget-only plugin keeps the user's disabled list", unplacedWidget.disabledPlugins, ["vgs.svc"]);
    check("withPlaced: a third-party widget-only plugin reads disabled once unplaced", ctx.isEnabled(ctx.effectiveConfig(shipped, unplacedWidget), manifests["acme.widget"], "vgs.bar"), false);

    // enablementRule rows: [id, want].
    for (const [id, want] of [["vgs.bar", "bar"], ["vgs.barpanel", "bar"], ["vgs.clock", "widget"], ["acme.widget", "widget"], ["vgs.svc", "first-party"], ["vgs.widgetpanel", "first-party"], ["acme.svc", "row"], ["acme.both", "row"]])
        check("enablementRule: " + id, ctx.enablementRule(manifests[id]), want);

    // A plugin with a settings schema, for the setting rows.
    const tunable = ctx.validateManifest({ schemaVersion: 1, id: "acme.tune", name: "T", version: "1", author: "a", description: "d", kinds: ["service", "bar-widget"], entryPoints: { service: "S.qml", "bar-widget": "W.qml" },
        settings: { label: "x", size: 2, on: true, mode: "a", free: 1, limit: 8 },
        schema: { label: { type: "string", label: "Label", presets: [{ value: "x" }], allowCustom: true }, size: { type: "number", label: "Size" }, on: { type: "boolean", label: "On" }, mode: { type: "enum", label: "Mode", options: ["a", "b"] }, limit: { type: "number", label: "Limit", min: 2, max: 30, step: 1, group: "Timing" } } }, "/p").manifest;
    if (tunable === undefined) throw new Error("fixture manifest refused: acme.tune");

    // settingRefusal rows: [name, key, value, want]
    // toastOptions: one row per rule. A refusal row pins the start of the error.
    const toastRows = [
        ["a title alone", { title: "Saved" }, { ok: true, value: { title: "Saved", message: "", tone: "neutral", icon: "", duration: null } }],
        ["every key", { title: "Saved", message: "to disk", tone: "success", icon: "check", duration: 0 }, { ok: true, value: { title: "Saved", message: "to disk", tone: "success", icon: "check", duration: 0 } }],
        ["not an object", "Saved", "options must be an object"],
        ["an unknown key", { title: "Saved", body: "x" }, "body unknown"],
        ["a missing title", { message: "x" }, "title must be"],
        ["a blank title", { title: " " }, "title must be"],
        ["a title past the ceiling", { title: "x".repeat(121) }, "title must be"],
        ["a message that is not a string", { title: "t", message: 4 }, "message must be"],
        ["an unknown tone", { title: "t", tone: "loud" }, "tone must be"],
        ["an icon that is not a string", { title: "t", icon: 4 }, "icon must be"],
        ["a negative duration", { title: "t", duration: -1 }, "duration must be"],
        ["a fractional duration", { title: "t", duration: 1.5 }, "duration must be"],
        ["a duration that is not a number", { title: "t", duration: "5s" }, "duration must be"]
    ];
    for (const [name, raw, want] of toastRows) {
        const got = ctx.toastOptions(raw);
        if (typeof want === "string") check("toastOptions: " + name, got.ok === false && got.error.startsWith(want), true);
        else check("toastOptions: " + name, got, want);
    }
    check("toast ceilings are whole numbers above zero", Number.isInteger(ctx.TOAST_VISIBLE_MAX) && ctx.TOAST_VISIBLE_MAX > 0 && Number.isInteger(ctx.TOAST_QUEUE_MAX) && ctx.TOAST_QUEUE_MAX >= ctx.TOAST_VISIBLE_MAX, true);
    check("toasts is a capability", ctx.CAPABILITIES.indexOf("toasts") !== -1, true);
    check("theme is a capability", ctx.CAPABILITIES.indexOf("theme") !== -1, true);
    check("layers is a capability", ctx.CAPABILITIES.indexOf("layers") !== -1, true);
    check("requirements is a capability", ctx.CAPABILITIES.indexOf("requirements") !== -1, true);
    check("session readers coexist with a lock holder", ctx.lendRefusal({ lock: "acme.locker", session: "acme.other" }, { id: "acme.reader", capabilities: ["session"] }), "");
    check("idle is a capability", ctx.CAPABILITIES.indexOf("idle") !== -1, true);
    const handler = () => {};
    const idleRows = [
        ["one second", 1, handler, ""],
        ["a day", 86400, handler, ""],
        ["zero seconds", 0, handler, "refused: idle-timeout=0 want=1..86400"],
        ["past a day", 86401, handler, "refused: idle-timeout=86401 want=1..86400"],
        ["a fraction", 1.5, handler, "refused: idle-timeout=1.5 want=1..86400"],
        ["a string", "300", handler, "refused: idle-timeout=\"300\" want=1..86400"],
        ["no handler", 300, null, "refused: idle-handler=not-a-function"]
    ];
    for (const [name, seconds, onChange, want] of idleRows) check("idleWatchRefusal: " + name, ctx.idleWatchRefusal(seconds, onChange), want);

    const refusalRows = [
        ["a string fits a string entry", "label", "y", ""],
        ["a number fits a number entry", "size", 3.5, ""],
        ["a boolean fits a boolean entry", "on", false, ""],
        ["an option fits an enum entry", "mode", "b", ""],
        ["a key outside the schema is undeclared", "free", 2, "refused: setting=free undeclared"],
        ["a prototype name is undeclared", "constructor", 1, "refused: setting=constructor undeclared"],
        ["a number is not a string", "label", 1, "refused: setting=label want=string"],
        ["a numeric string is not a number", "size", "3", "refused: setting=size want=number"],
        ["NaN is not a number", "size", NaN, "refused: setting=size want=number"],
        ["a string is not a boolean", "on", "true", "refused: setting=on want=boolean"],
        ["a value outside the options", "mode", "c", "refused: setting=mode want=one-of:a|b"],
        ["a bounded number at its min fits", "limit", 2, ""],
        ["a bounded number at its max fits", "limit", 30, ""],
        ["a bounded number off its step fits", "limit", 2.5, ""],
        ["a number under the min is refused", "limit", 1, "refused: setting=limit want=at-least:2"],
        ["a number over the max is refused", "limit", 31, "refused: setting=limit want=at-most:30"],
        ["a bounded entry still wants a number", "limit", "8", "refused: setting=limit want=number"],
    ];
    for (const [name, key, value, want] of refusalRows) {
        check("settingRefusal: " + name, ctx.settingRefusal(tunable, key, value), want);
    }
    const presetManifest = ctx.validateManifest({ schemaVersion: 1, id: "acme.presets", name: "P", version: "1", author: "a", description: "d", kinds: ["service"], entryPoints: { service: "S.qml" },
        settings: { mode: "short", delay: 60, clock: "HH:mm" },
        schema: {
            mode: { type: "string", label: "Mode", presets: [{ value: "short" }, { value: "long" }] },
            delay: { type: "number", label: "Delay", presets: [{ value: 60 }, { value: 300 }], unit: "seconds" },
            clock: { type: "string", label: "Clock", presets: [{ value: "HH:mm" }], allowCustom: true, format: "datetime" }
        } }, "/p").manifest;
    if (presetManifest === undefined) throw new Error("fixture manifest refused: acme.presets");
    const presetRefusals = [
        ["a preset string fits", "mode", "long", ""],
        ["a non-preset string is refused", "mode", "other", "refused: setting=mode want=one-of-presets"],
        ["a preset number fits", "delay", 300, ""],
        ["a non-preset number is refused", "delay", 120, "refused: setting=delay want=one-of-presets"],
        ["a custom datetime format fits", "clock", "ddd HH:mm", ""],
        ["a bad datetime format is refused", "clock", "'abc", "refused: setting=clock want=datetime-format reason=unclosed-quote"],
    ];
    for (const [name, key, value, want] of presetRefusals) {
        check("settingRefusal presets: " + name, ctx.settingRefusal(presetManifest, key, value), want);
    }

    // settingTargets rows: [name, config, manifest, want]
    const tunePlaced = ctx.effectiveConfig(shipped, { bar: { id: "vgs.bar", layout: { left: [], center: [], right: [{ id: "acme.tune" }] } } });
    const targetRows = [
        ["a placed widget writes its layout entry", shipped, manifests["vgs.clock"], ["layout"]],
        ["an unplaced widget has no entry", ctx.effectiveConfig(shipped, { bar: { id: "vgs.bar", layout: { left: [], center: [], right: [] } } }), manifests["vgs.clock"], []],
        ["a service writes its plugins row", shipped, manifests["acme.svc"], ["plugins"]],
        ["a bar writes its plugins row", shipped, manifests["vgs.bar"], ["plugins"]],
        ["a placed widget-plus-service writes both", tunePlaced, tunable, ["layout", "plugins"]],
        ["a placed pane plugin writes both", ctx.effectiveConfig(shipped, { bar: { id: "vgs.bar", layout: { left: [], center: [], right: [{ id: "acme.pane" }] } } }), manifests["acme.pane"], ["layout", "plugins"]],
    ];
    for (const [name, config, manifest, want] of targetRows) {
        check("settingTargets: " + name, ctx.settingTargets(config, manifest), want);
    }

    const configureTargetRows = [
        ["a pane writes every entry its plugin reads", ctx.effectiveConfig(shipped, { bar: { id: "vgs.bar", layout: { left: [], center: [], right: [{ id: "acme.pane" }] } } }), manifests["acme.pane"], "pane", ["layout", "plugins"]],
        ["a placed widget-plus-pane writes layout and plugins", ctx.effectiveConfig(shipped, { bar: { id: "vgs.bar", layout: { left: [], center: [], right: [{ id: "acme.pane" }] } } }), manifests["acme.pane"], "bar-widget", ["layout"]],
        ["a service writes its own plugins row", shipped, manifests["acme.svc"], "service", ["plugins"]],
        ["a window writes its own plugins row", shipped, manifests["vgs.widgetpanel"], "panel", ["plugins"]],
    ];
    for (const [name, config, manifest, kind, want] of configureTargetRows)
        check("configureTargets: " + name, ctx.configureTargets(config, manifest, kind), want);

    const paneRowsManifests = {};
    function paneManifest(id, name, group, order, extra) {
        return ctx.validateManifest(Object.assign({ schemaVersion: 1, id: id, name: name, version: "1", author: "a", description: "d", kinds: ["pane"], entryPoints: { pane: "Pane.qml" }, pane: { group: group, order: order } }, extra || {}), "/p").manifest;
    }
    paneRowsManifests["acme.beta"] = paneManifest("acme.beta", "Beta", "System", 2);
    paneRowsManifests["acme.alpha"] = paneManifest("acme.alpha", "Alpha", "System", 2);
    paneRowsManifests["acme.zed"] = paneManifest("acme.zed", "Alpha", "System", 2);
    paneRowsManifests["acme.user"] = paneManifest("acme.user", "User", "User", 1);
    paneRowsManifests["acme.widgetpane"] = paneManifest("acme.widgetpane", "Widget Pane", "System", 1, { kinds: ["bar-widget", "pane"], entryPoints: { "bar-widget": "Widget.qml", pane: "Pane.qml" }, defaultSection: "right", icon: "settings" });
    paneRowsManifests["acme.disabled"] = paneManifest("acme.disabled", "Disabled", "System", 0);
    const paneConfig = ctx.effectiveConfig(shipped, { bar: { id: "vgs.bar", layout: { left: [], center: [], right: [{ id: "acme.widgetpane" }] } }, plugins: [{ id: "acme.beta" }, { id: "acme.alpha" }, { id: "acme.zed" }, { id: "acme.user" }, { id: "acme.disabled" }], disabledPlugins: ["acme.disabled"] });
    check("paneRows: enabled panes are grouped, ordered, named and tied by id", ctx.paneRows(paneConfig, paneRowsManifests, "vgs.bar").map(r => [r.id, r.group, r.order, r.placed, r.hasWidget, r.icon]),
        [["acme.widgetpane", "System", 1, true, true, "settings"], ["acme.alpha", "System", 2, false, false, "package"], ["acme.zed", "System", 2, false, false, "package"], ["acme.beta", "System", 2, false, false, "package"], ["acme.user", "User", 1, false, false, "package"]]);
    const holderManifests = {
        "acme.host-b": ctx.validateManifest(Object.assign({}, bar, { id: "acme.host-b", kinds: ["window"], entryPoints: { window: "Window.qml" }, capabilities: ["panes"] }), "/p").manifest,
        "acme.host-a": ctx.validateManifest(Object.assign({}, bar, { id: "acme.host-a", kinds: ["window"], entryPoints: { window: "Window.qml" }, capabilities: ["panes"] }), "/p").manifest,
        "acme.disabled-host": ctx.validateManifest(Object.assign({}, bar, { id: "acme.disabled-host", kinds: ["window"], entryPoints: { window: "Window.qml" }, capabilities: ["panes"] }), "/p").manifest,
        "acme.service-holder": ctx.validateManifest(Object.assign({}, svc, { id: "acme.service-holder", capabilities: ["panes"] }), "/p").manifest,
    };
    const holderConfig = { plugins: [{ id: "acme.host-b" }, { id: "acme.host-a" }, { id: "acme.disabled-host" }, { id: "acme.service-holder" }], disabledPlugins: ["acme.disabled-host"] };
    check("panesHolderId: the enabled window holder is selected by id", ctx.panesHolderId(holderConfig, holderManifests, "vgs.bar"), "acme.host-a");
    check("panesHolderId: no enabled holder is empty", ctx.panesHolderId({ plugins: [{ id: "acme.service-holder" }] }, holderManifests, "vgs.bar"), "");

    // withSetting rows: [name, user, effective, targets, path, want]
    const shippedTune = Object.assign({}, tunePlaced, { plugins: [{ id: "acme.tune", size: 9 }] });
    const twiceTune = { bar: { id: "vgs.bar", layout: { left: [{ id: "acme.tune" }], center: [], right: [{ id: "acme.tune", label: "r" }] } } };
    const settingRows = [
        ["layout sets the key on the placed entry", null, tunePlaced, ["layout"], "bar.layout.right", [{ id: "acme.tune", label: "new" }]],
        ["layout seeds the user bar from the effective bar", null, tunePlaced, ["layout"], "bar.id", "vgs.bar"],
        ["layout sets every entry with the id", twiceTune, ctx.effectiveConfig(shipped, twiceTune), ["layout"], "bar.layout", { left: [{ id: "acme.tune", label: "new" }], center: [], right: [{ id: "acme.tune", label: "new" }] }],
        ["layout leaves plugins alone", null, tunePlaced, ["layout"], "plugins", undefined],
        ["a locator sets only its own entry", twiceTune, ctx.effectiveConfig(shipped, twiceTune), ["layout"], "bar.layout", { left: [{ id: "acme.tune" }], center: [], right: [{ id: "acme.tune", label: "new" }] }, { section: "right", nth: 0 }],
        ["a locator counts entries with the same id", { bar: { id: "vgs.bar", layout: { left: [{ id: "acme.tune" }, { id: "b.c" }, { id: "acme.tune" }], center: [], right: [] } } }, tunePlaced, ["layout"], "bar.layout.left", [{ id: "acme.tune" }, { id: "b.c" }, { id: "acme.tune", label: "new" }], { section: "left", nth: 1 }],
        ["plugins adds a row with the id", null, tunePlaced, ["plugins"], "plugins", [{ id: "acme.tune", label: "new" }]],
        ["plugins seeds the row from the effective row", null, shippedTune, ["plugins"], "plugins", [{ id: "acme.tune", size: 9, label: "new" }]],
        ["plugins updates the user row in place", { plugins: [{ id: "acme.tune", size: 4 }, { id: "b.c" }] }, shippedTune, ["plugins"], "plugins", [{ id: "acme.tune", size: 4, label: "new" }, { id: "b.c" }]],
        ["plugins leaves the bar key alone", null, tunePlaced, ["plugins"], "bar", undefined],
        ["writes version 1", null, tunePlaced, ["plugins"], "version", 1],
    ];
    for (const [name, user, effective, targets, p, want, locator] of settingRows) {
        check("withSetting: " + name, dig(ctx.withSetting(user, tunable, "label", "new", effective, targets, locator || null), p), want);
    }
    check("withSetting does not alias the user file", (() => { const u = { plugins: [{ id: "acme.tune", size: 4 }] }; ctx.withSetting(u, tunable, "label", "new", shippedTune, ["plugins"]); return u.plugins[0]; })(), { id: "acme.tune", size: 4 });

    // lendRefusal rows: [name, held, capabilities, want]
    const lendRows = [
        ["a free exclusive capability lends", {}, ["lock"], ""],
        ["an exclusive capability held by another plugin refuses", { lock: "acme.other" }, ["lock", "run"], "refused: capability=lock held-by=acme.other"],
        ["a plugin may hold what it already holds", { polkit: "acme.tune" }, ["polkit"], ""],
        ["a shared capability is never refused", { lock: "acme.other" }, ["run", "screens"], ""],
        ["the Bluetooth agent held by another plugin refuses", { bluetoothAgent: "acme.other" }, ["bluetoothAgent", "ipc"], "refused: capability=bluetoothAgent held-by=acme.other"],
        ["the monitor rules serve one plugin", { monitors: "acme.other" }, ["monitors", "ipc"], "refused: capability=monitors held-by=acme.other"],
        ["the panes holder serves one plugin", { panes: "acme.other" }, ["panes", "ipc"], "refused: capability=panes held-by=acme.other"],
    ];
    for (const [name, held, capabilities, want] of lendRows) {
        check("lendRefusal: " + name, ctx.lendRefusal(held, Object.assign({}, tunable, { capabilities: capabilities })), want);
    }

    // unknownIds rows: [name, config, want]. `manifests` knows vgs.bar,
    // vgs.clock, vgs.workspaces, vgs.svc and acme.svc.
    const unknownRows = [
        ["a configuration naming only known ids reports none", { disabledPlugins: ["vgs.clock"], plugins: [{ id: "acme.svc" }] }, []],
        ["a disabled id no plugin has is reported under disabledPlugins", { disabledPlugins: ["vgs.clock", "vgs.background"] }, [{ id: "vgs.background", key: "disabledPlugins" }]],
        ["a plugins row no plugin has is reported under plugins", { plugins: [{ id: "acme.svc" }, { id: "vgs.background", x: 1 }] }, [{ id: "vgs.background", key: "plugins" }]],
        ["an id in both keys is reported once per key, disabledPlugins first", { plugins: [{ id: "acme.gone" }], disabledPlugins: ["acme.gone"] }, [{ id: "acme.gone", key: "disabledPlugins" }, { id: "acme.gone", key: "plugins" }]],
        ["an id listed twice in one key is reported once", { disabledPlugins: ["acme.gone", "acme.gone"] }, [{ id: "acme.gone", key: "disabledPlugins" }]],
        ["ids are reported in list order", { disabledPlugins: ["b.gone", "a.gone"] }, [{ id: "b.gone", key: "disabledPlugins" }, { id: "a.gone", key: "disabledPlugins" }]],
        ["a configuration without either key reports none", {}, []],
    ];
    for (const [name, config, want] of unknownRows) {
        check("unknownIds: " + name, ctx.unknownIds(config, manifests), want);
    }

    // surfacePlacement rows: [name, kind, settings, want subset]
    const placementRows = [
        ["an overlay fills its screen on the overlay layer", "overlay", {}, { anchors: { top: true, bottom: true, left: true, right: true }, exclusion: "ignore", layer: "overlay", placement: "fill" }],
        ["no placement setting centres on the whole monitor", "panel", {}, { anchors: { top: false, bottom: false, left: false, right: false }, exclusion: "ignore", layer: "top", placement: "center" }],
        ["center ignores reserved space", "menu", { placement: "center" }, { exclusion: "ignore", placement: "center" }],
        ["top-right keeps clear of reserved space", "panel", { placement: "top-right" }, { exclusion: "normal" }],
        ["top-right keeps a gap from both edges", "panel", { placement: "top-right" }, { anchors: { top: true, bottom: false, left: false, right: true }, margins: { top: 8, bottom: 0, left: 0, right: 8 }, placement: "top-right" }],
        ["bottom anchors one edge", "menu", { placement: "bottom" }, { anchors: { top: false, bottom: true, left: false, right: false }, layer: "overlay", placement: "bottom" }],
        ["an unknown placement is reported and centres", "panel", { placement: "middle" }, { placement: "center", error: "placement=\"middle\" unknown" }],
    ];
    for (const [name, kind, settings, want] of placementRows) {
        const got = ctx.surfacePlacement(kind, settings, 8);
        const picked = {};
        for (const k of Object.keys(want)) picked[k] = got[k];
        check("surfacePlacement: " + name, picked, want);
    }

    // A plugin with two Hyprland binds, for the key rows.
    const keyed = ctx.validateManifest({ schemaVersion: 1, id: "acme.keys", name: "K", version: "1", author: "a", description: "d", kinds: ["service"], entryPoints: { service: "S.qml" }, capabilities: ["shortcut"],
        hyprland: { binds: [{ shortcut: "toggle", key: "super+m" }, { shortcut: "peek", key: "SUPER+P" }] } }, "/p").manifest;
    if (keyed === undefined) throw new Error("fixture manifest refused: acme.keys");

    // keyRefusal rows: [name, manifest, shortcut, key, want]
    const keyRefusalRows = [
        ["a declared shortcut takes a key", keyed, "toggle", "ctrl+super+k", ""],
        ["Settings accepts a keycode", keyed, "toggle", "shift+super+CODE:00108", ""],
        ["null unbinds a declared shortcut", keyed, "toggle", null, ""],
        ["undefined resets a declared shortcut", keyed, "toggle", undefined, ""],
        ["an undeclared shortcut is refused", keyed, "other", "SUPER+K", "refused: key=other undeclared"],
        ["a prototype name is undeclared", keyed, "constructor", "SUPER+K", "refused: key=constructor undeclared"],
        ["a plugin without binds declares none", manifests["acme.svc"], "toggle", "SUPER+K", "refused: key=toggle undeclared"],
        ["a key that is not a string is refused", keyed, "toggle", 5, "refused: key=toggle want=string-or-null"],
        ["a malformed key is refused with the key judge's words", keyed, "toggle", "SUPER+", "refused: key=toggle has an empty part: \"SUPER+\""],
    ];
    for (const [name, manifest, shortcut, key, want] of keyRefusalRows) {
        check("keyRefusal: " + name, ctx.keyRefusal(manifest, shortcut, key), want);
    }

    // withKey rows: [name, user, effective, shortcut, key, path, want]
    const keyRow = { version: 1, plugins: [{ id: "acme.keys", x: 1, keys: { toggle: "SUPER+K" } }] };
    const keyRows = [
        ["a key is written normalised into a new row", null, {}, "toggle", "ctrl+super+k", "plugins", [{ id: "acme.keys", keys: { toggle: "SUPER+CTRL+K" } }]],
        ["Settings writes a normalized keycode", null, {}, "toggle", "shift+super+CODE:00108", "plugins", [{ id: "acme.keys", keys: { toggle: "SUPER+SHIFT+code:108" } }]],
        ["null is written as an unbind", null, {}, "toggle", null, "plugins", [{ id: "acme.keys", keys: { toggle: null } }]],
        ["the row is seeded from the effective row", null, { plugins: [{ id: "acme.keys", x: 1 }] }, "peek", "SUPER+Q", "plugins", [{ id: "acme.keys", x: 1, keys: { peek: "SUPER+Q" } }]],
        ["the user row is updated in place", { plugins: [{ id: "b.c" }, { id: "acme.keys", keys: { peek: "SUPER+Q" } }] }, {}, "toggle", "SUPER+K", "plugins", [{ id: "b.c" }, { id: "acme.keys", keys: { peek: "SUPER+Q", toggle: "SUPER+K" } }]],
        ["a reset removes the entry alone", { plugins: [{ id: "acme.keys", keys: { toggle: "SUPER+K", peek: "SUPER+Q" } }] }, {}, "toggle", undefined, "plugins", [{ id: "acme.keys", keys: { peek: "SUPER+Q" } }]],
        ["a reset of the last entry removes keys", { plugins: [{ id: "acme.keys", keys: { toggle: "SUPER+K" } }] }, {}, "toggle", undefined, "plugins", [{ id: "acme.keys" }]],
        ["a reset no row needs writes no row", null, {}, "toggle", undefined, "plugins", undefined],
        ["a reset seeds from an effective row that holds the entry", null, keyRow, "toggle", undefined, "plugins", [{ id: "acme.keys", x: 1 }]],
        ["writes version 1", null, {}, "toggle", "SUPER+K", "version", 1],
    ];
    for (const [name, user, effective, shortcut, key, p, want] of keyRows) {
        check("withKey: " + name, dig(ctx.withKey(user, keyed, shortcut, key, effective), p), want);
    }
    check("withKey does not alias the user file", (() => { const u = { plugins: [{ id: "acme.keys", keys: { toggle: "SUPER+K" } }] }; ctx.withKey(u, keyed, "toggle", null, {}); return u.plugins[0]; })(), { id: "acme.keys", keys: { toggle: "SUPER+K" } });

    // bindRows: the key in effect, the manifest's key and the registered description.
    check("bindRows: each bind with its key in effect, its default and its description", ctx.bindRows({ plugins: [{ id: "acme.keys", keys: { toggle: null } }] }, keyed, { "acme.keys:toggle": "Open" }),
        [{ shortcut: "toggle", key: null, default: "SUPER+M", description: "Open" }, { shortcut: "peek", key: "SUPER+P", default: "SUPER+P", description: "" }]);
    check("bindRows: a rebound key is the one in effect", ctx.bindRows({ plugins: [{ id: "acme.keys", keys: { peek: "shift+super+p" } }] }, keyed, {})[1], { shortcut: "peek", key: "SUPER+SHIFT+P", default: "SUPER+P", description: "" });
    check("bindRows: a plugin without binds has none", ctx.bindRows({}, manifests["acme.svc"], {}), []);

    check("pluginIcon: a manifest's icon", ctx.pluginIcon(ctx.validateManifest(Object.assign({}, svc, { icon: "bell" }), "/p").manifest), "bell");
    check("pluginIcon: a plugin without one is listed as a package", ctx.pluginIcon(manifests["acme.svc"]), "package");

    check("SUMMONABLE_KINDS are kinds", ctx.SUMMONABLE_KINDS.every(k => ctx.KINDS.indexOf(k) !== -1), true);
    check("window is a summonable kind", ctx.SUMMONABLE_KINDS.indexOf("window"), 3);

    // summonSurface rows: [name, kind, anchored, want]. An application
    // window is a toplevel whatever the anchor; every other summonable kind
    // is a popup under its anchor and a layer surface without one.
    const surfaceRows = [
        ["a window without an anchor is a toplevel", "window", false, "window"],
        ["an anchored window is still a toplevel", "window", true, "window"],
        ["an anchored panel is a popup", "panel", true, "popup"],
        ["an unanchored panel is a layer surface", "panel", false, "layer"],
        ["an anchored menu is a popup", "menu", true, "popup"],
        ["an unanchored overlay is a layer surface", "overlay", false, "layer"],
    ];
    for (const [name, kind, anchored, want] of surfaceRows)
        check("summonSurface: " + name, ctx.summonSurface(kind, anchored), want);
    check("summonSurface refuses a kind no host summons", (() => { try { return ctx.summonSurface("background", false); } catch (e) { return e.message; } })(), "summonSurface: kind \"background\" is not summonable");

    check("capturesOverlayKeyboard: unanchored overlay captures", ctx.capturesOverlayKeyboard("overlay", false), true);
    check("capturesOverlayKeyboard: anchored overlay does not capture", ctx.capturesOverlayKeyboard("overlay", true), false);
    check("capturesOverlayKeyboard: panel does not capture", ctx.capturesOverlayKeyboard("panel", false), false);
    check("capturesOverlayKeyboard refuses a kind no host summons", (() => { try { return ctx.capturesOverlayKeyboard("background", false); } catch (e) { return e.message; } })(), "capturesOverlayKeyboard: kind \"background\" is not summonable");
    check("layerKeyboardFocus: capturing overlay is exclusive", ctx.layerKeyboardFocus("overlay", false), "exclusive");
    check("layerKeyboardFocus: non-capturing layer is on demand", ctx.layerKeyboardFocus("panel", false), "on-demand");
    check("layerCatchesOutside: a panel layer catches a press beside it", ctx.layerCatchesOutside("panel"), true);
    check("layerCatchesOutside: a menu layer catches a press beside it", ctx.layerCatchesOutside("menu"), true);
    check("layerCatchesOutside: an overlay layer catches nothing", ctx.layerCatchesOutside("overlay"), false);
    check("layerCatchesOutside refuses a kind never built as a layer", (() => { try { return ctx.layerCatchesOutside("window"); } catch (e) { return e.message; } })(), "layerCatchesOutside: kind \"window\" is never a layer summon");
}

suite(load(LOGIC), report);

// Each control removes one rule from a copy of the judge and keeps the text
// around it; the suite must fail on every copy. The copy sits at the
// judge's own place in a temporary tree, beside the icon set, the
// package-manager table and the Hyprland layer's table it imports.
const CONTROLS = [
    ["session is a known capability", '"lock", "session",', '"lock", ("session" && "planted"),'],
    ["session is not exclusive", 'var EXCLUSIVE_CAPABILITIES = ["lock", "polkit", "bluetoothAgent", "monitors", "panes"];', 'var EXCLUSIVE_CAPABILITIES = ["lock", "polkit", "bluetoothAgent", "monitors"].concat(["session"]);'],
    ["the Bluetooth agent is exclusive", 'var EXCLUSIVE_CAPABILITIES = ["lock", "polkit", "bluetoothAgent", "monitors", "panes"];', 'var EXCLUSIVE_CAPABILITIES = ["lock", "polkit", "monitors"];'],
    ["monitors is exclusive", 'var EXCLUSIVE_CAPABILITIES = ["lock", "polkit", "bluetoothAgent", "monitors", "panes"];', 'var EXCLUSIVE_CAPABILITIES = ["lock", "polkit", "bluetoothAgent", "panes"];'],
    ["panes is exclusive", 'var EXCLUSIVE_CAPABILITIES = ["lock", "polkit", "bluetoothAgent", "monitors", "panes"];', 'var EXCLUSIVE_CAPABILITIES = ["lock", "polkit", "bluetoothAgent", "monitors"];'],
    ["monitors is a capability", "\"hyprland\", \"bluetoothAgent\", \"monitors\"];", "\"hyprland\", \"bluetoothAgent\"];"],
    ["optionsFrom needs a string", "if (entry.type !== \"string\")\n                return at + \".optionsFrom needs type string\";", "if (false)\n                return at + \".optionsFrom needs type string\";"],
    ["hyprland options need the capability", "if (options !== undefined && capabilities.indexOf(\"hyprland\") === -1)\n        return \"hyprland.options needs capability hyprland\";", "if (false)\n        return \"hyprland.options needs capability hyprland\";"],
    ["hyprland option names are setting names", "if (!STATUS_KEY_PATTERN.test(name))\n            return at + \" must be a setting name\";", "if (false)\n            return at + \" must be a setting name\";"],
    ["optionsFrom names a status key", "if (typeof entry.optionsFrom !== \"string\" || !STATUS_KEY_PATTERN.test(entry.optionsFrom))", "if (false)"],
    ["optionsFrom names its own choices entry", "if (!hasOwn(status, entry.optionsFrom) || status[entry.optionsFrom].type !== \"choices\")", "if (false)"],
    ["a string entry needs presets or optionsFrom", "if (entry.type === \"string\" && entry.presets === undefined && entry.optionsFrom === undefined)", "if (false)"],
    ["presets and optionsFrom cannot coexist", "if (entry.presets !== undefined && entry.optionsFrom !== undefined)", "if (false)"],
    ["presets need a string or number", "if (entry.type !== \"string\" && entry.type !== \"number\")\n                return at + \".presets needs type string or number\";", "if (false)\n                return at + \".presets needs type string or number\";"],
    ["presets are a non-empty list", "if (!Array.isArray(entry.presets) || entry.presets.length === 0)", "if (false)"],
    ["a preset is an object", "if (!isPlainObject(preset))\n                    return presetAt + \" must be an object\";", "if (false)\n                    return presetAt + \" must be an object\";"],
    ["a preset carries known keys", "if (PRESET_KEYS.indexOf(presetKeys[pk]) === -1)", "if (false)"],
    ["a preset has a value", "if (!hasOwn(preset, \"value\"))\n                    return presetAt + \".value is required\";", "if (false)\n                    return presetAt + \".value is required\";"],
    ["a preset label is printable", "if (preset.label !== undefined && !isPrintableLine(preset.label, PRESET_LABEL_MAX))", "if (false)"],
    ["an empty preset value has a label", "if (preset.value === \"\" && preset.label === undefined)", "if (false)"],
    ["preset values are distinct", "if (seenPresets.indexOf(presetKey) !== -1)", "if (false)"],
    ["preset values fit the schema", "if (badPreset !== \"\")\n                    return presetAt + \".value does not fit its schema: \" + badPreset;", "if (false)\n                    return presetAt + \".value does not fit its schema: \" + badPreset;"],
    ["allowCustom needs presets", "if (entry.allowCustom !== undefined && entry.presets === undefined)", "if (false)"],
    ["allowCustom is boolean", "if (typeof entry.allowCustom !== \"boolean\")\n                return at + \".allowCustom must be a boolean\";", "if (false)\n                return at + \".allowCustom must be a boolean\";"],
    ["format needs type string", "if (entry.type !== \"string\")\n                return at + \".format needs type string\";", "if (false)\n                return at + \".format needs type string\";"],
    ["format needs presets", "if (entry.format !== undefined && entry.presets === undefined)", "if (false)"],
    ["format names a known format", "if (SettingValues.FORMATS.indexOf(entry.format) === -1)", "if (false)"],
    ["unit needs type number", "if (entry.type !== \"number\")\n                return at + \".unit needs type number\";", "if (false)\n                return at + \".unit needs type number\";"],
    ["unit names a known unit", "if (SettingValues.UNITS.indexOf(entry.unit) === -1)", "if (false)"],
    ["datetime settings are judged", "if (entry.format === \"datetime\") {\n            var problem = SettingValues.datetimeFormatProblem(value);", "if (false) {\n            var problem = SettingValues.datetimeFormatProblem(value);"],
    ["preset settings without custom accept only presets", "return entry.presets !== undefined && entry.allowCustom !== true && presetValues(entry).indexOf(value) === -1 ? \"want=one-of-presets\" : \"\";", "return \"\";"],
    ["packages is an object", "if (!isPlainObject(config.packages))\n            return \"packages must be an object\";", "if (false)\n            return \"packages must be an object\";"],
    ["packages.elevate is an elevation command", "config.packages.elevate !== undefined && PackageManagers.ELEVATORS.indexOf(config.packages.elevate) === -1", "false"],
    ["icon is a manifest key", "\"license\", \"icon\", \"kinds\"", "\"license\", \"kinds\""],
    ["icon names a shipped icon", "!hasOwn(Lucide.ICONS, raw.icon)", "false"],
    ["bounds need a number entry", "if (entry.type !== \"number\")\n                return at + \".\" + bound + \" needs type number\";", "if (false)\n                return at + \".\" + bound + \" needs type number\";"],
    ["bounds are finite numbers", "if (typeof entry[bound] !== \"number\" || !isFinite(entry[bound]))", "if (false)"],
    ["min below max", "!(entry.min < entry.max)", "false"],
    ["step positive", "!(entry.step > 0)", "false"],
    ["group a non-empty string", "(typeof entry.group !== \"string\" || entry.group.length === 0)", "false"],
    ["a number under min does not fit", "if (entry.min !== undefined && value < entry.min) return", "if (false) return"],
    ["a number over max does not fit", "if (entry.max !== undefined && value > entry.max) return", "if (false) return"],
    ["a key needs a declared bind", "if (!binds.some(function (bind) { return bind.shortcut === shortcut; }))", "if (false)"],
    ["a key is a string or null", "if (typeof key !== \"string\")\n        return \"refused: key=\" + shortcut + \" want=string-or-null\";", "if (false)\n        return \"refused: key=\" + shortcut + \" want=string-or-null\";"],
    ["a key string is judged", "return parsed.ok ? \"\" :", "return true ? \"\" :"],
    ["a written key is normalised", "row.keys[shortcut] = key === null ? null : hyprlandKey(key).key;", "row.keys[shortcut] = key === null ? null : key;"],
    ["null unbinds", "row.keys[shortcut] = key === null ? null : hyprlandKey(key).key;", "row.keys[shortcut] = hyprlandKey(key).key;"],
    ["a reset removes the entry", "            delete row.keys[shortcut];\n", ""],
    ["an empty keys is removed", "if (Object.keys(row.keys).length === 0) delete row.keys;", ""],
    ["a reset the row does not need changes nothing", "if (!needed)\n            return out;", "if (false)\n            return out;"],
    ["a key row is seeded from the effective row", "row = shippedRow !== undefined ? clone(shippedRow) : { id: manifest.id };\n        out.plugins = (", "row = { id: manifest.id };\n        out.plugins = ("],
    ["a bind row carries its registered description", "hasOwn(descriptions, name) ? descriptions[name] : \"\"", "\"\""],
    ["a bind row carries the manifest's key", "\"default\": defaults[i].key", "\"default\": bind.key"],
    ["a plugin without an icon is listed with the default", ": DEFAULT_ICON;", ": \"\";"],
    ["status is a manifest key", "\"requirements\", \"status\", \"tui\", \"secrets\", ", "\"requirements\", \"tui\", \"secrets\", "],
    ["secrets is a manifest key", "\"status\", \"tui\", \"secrets\", \"extras\"];", "\"status\", \"tui\", \"extras\"];"],
    ["secrets is a capability", "\"doctor\", \"secrets\", ", "\"doctor\", "],
    ["hyprland is a capability", "\"secrets\", \"hyprland\", ", "\"secrets\", "],
    ["options is a hyprland key", "\"appearance\", \"options\"];", "\"appearance\"];"],
    ["options alone declare something", " && options === undefined)", ")"],
    ["options are judged", "return hyprlandOptionsError(options, schema);", "return \"\";"],
    ["options are a non-empty object", "if (!isPlainObject(options) || Object.keys(options).length === 0)", "if (false)"],
    ["an option names a table path", "if (typeof path !== \"string\" || !hasOwn(HyprlandLayer.OPTIONS, path))", "if (typeof path !== \"string\")"],
    ["an option path once", "if (paths.indexOf(path) !== -1)", "if (false)"],
    ["an option names a schema entry", "if (!hasOwn(schema, name))", "if (false)"],
    ["a boolean option takes a boolean", "return entry.type === \"boolean\" ? \"\" : \"needs a boolean", "return true ? \"\" : \"needs a boolean"],
    ["a number option takes a number", "if (entry.type !== \"number\")\n            return \"needs a number", "if (false)\n            return \"needs a number"],
    ["a number option is bounded", "entry.min === undefined || entry.max === undefined || ", ""],
    ["a number option lies in Hyprland's range", " || entry.min < row.min || entry.max > row.max)", ")"],
    ["an int option is whole", "if (row.type === \"int\" && !(", "if (false && !("],
    ["an int option's step is whole", " && (entry.step === undefined || Number.isInteger(entry.step))))", "))"],
    ["a choice option takes an enum", "if (entry.type !== \"enum\")\n            return \"needs an enum", "if (false)\n            return \"needs an enum"],
    ["a choice option offers its choices alone", "if (row.choices.indexOf(entry.options[o]) === -1)", "if (false)"],
    ["a free string option takes a string or an enum", "return entry.type === \"string\" || entry.type === \"enum\" ? \"\" : \"needs a string", "return true ? \"\" : \"needs a string"],
    ["a manifest carries its options", "options: clone(raw.hyprland.options || {})", "options: {}"],
    ["a command needs an action", "if (entry.command !== undefined && entry.action === undefined && entry.type !== \"data\")", "if (false)"],
    ["an action is judged", "var badAction = statusActionError(entry, at + \".action\", tui, requirements, system);", "var badAction = \"\";"],
    ["an action sits on a presence or a state", "if (STATUS_ACTION_TYPES.indexOf(entry.type) === -1)\n        return at + \" needs a type", "if (false)\n        return at + \" needs a type"],
    ["an action is an object", "if (!isPlainObject(action))\n        return at + \" must be an object\";", "if (false)\n        return at + \" must be an object\";"],
    ["an action has only its keys", "if (STATUS_ACTION_KEYS.indexOf(keys[i]) === -1)", "if (false)"],
    ["an action label is a printable line", "if (!isPrintableLine(action.label, STATUS_LABEL_MAX))\n        return at + \".label", "if (false)\n        return at + \".label"],
    ["an action names exactly one route", "return action[route] !== undefined; }).length !== 1)", "return action[route] !== undefined; }).length > 1)"],
    ["an action names a route", "return action[route] !== undefined; }).length !== 1)", "return action[route] !== undefined; }).length < 0)"],
    ["an action system step is a declared one", "if (typeof action.system !== \"string\" || !Array.isArray(system) || system.indexOf(action.system) === -1)", "if (false)"],
    ["system is a capability", "\"tui\", \"system\", \"requirements\"", "\"tui\", \"requirements\""],
    ["systemSteps is a manifest key", "\"capabilities\", \"systemSteps\", \"settings\"", "\"capabilities\", \"settings\""],
    ["systemSteps is judged", "var badSteps = systemStepsError(raw.systemSteps, capabilities);", "var badSteps = \"\";"],
    ["capability system needs systemSteps", "} else if (capabilities.indexOf(\"system\") !== -1) {", "} else if (false) {"],
    ["systemSteps is a non-empty list", "if (!Array.isArray(steps) || steps.length === 0)\n        return \"systemSteps must", "if (false)\n        return \"systemSteps must"],
    ["systemSteps needs capability system", "if (capabilities.indexOf(\"system\") === -1)\n        return \"systemSteps needs", "if (false)\n        return \"systemSteps needs"],
    ["a step is one of the table", "if (typeof steps[i] !== \"string\" || SYSTEM_STEPS.indexOf(steps[i]) === -1)", "if (false)"],
    ["a step is declared once", "if (steps.indexOf(steps[i]) !== i)", "if (false)"],
    ["an absent systemSteps is normalised", "manifest.systemSteps = raw.systemSteps === undefined ? [] : raw.systemSteps.slice();", "manifest.systemSteps = raw.systemSteps;"],
    ["an action TUI is the manifest's own", "if (typeof action.tui !== \"string\" || !isPlainObject(tui) || !hasOwn(tui, action.tui))", "if (false)"],
    ["an action install is a non-empty list", "if (!Array.isArray(action.install) || action.install.length === 0)", "if (false)"],
    ["an action installs declared commands", "if (declared.indexOf(action.install[n]) === -1)", "if (false)"],
    ["an action installs each command once", "if (action.install.indexOf(action.install[n]) !== n)", "if (false)"],
    ["secrets are judged", "var badSecrets = secretsError(raw.secrets, capabilities, raw.status);", "var badSecrets = \"\";"],
    ["capability secrets needs secrets", "} else if (capabilities.indexOf(\"secrets\") !== -1) {", "} else if (false) {"],
    ["secrets is an object", "if (!isPlainObject(secrets))\n        return \"secrets must be an object\";", "if (false)\n        return \"secrets must be an object\";"],
    ["secrets has only its keys", "if (SECRETS_KEYS.indexOf(keys[i]) === -1)", "if (false)"],
    ["a secrets service matches its pattern", "if (typeof secrets.service !== \"string\" || !SECRET_SERVICE_PATTERN.test(secrets.service))", "if (false)"],
    ["a secrets label is a printable line", "if (!isPrintableLine(secrets.label, STATUS_LABEL_MAX))\n        return \"secrets.label", "if (false)\n        return \"secrets.label"],
    ["secrets need capability secrets", "if (capabilities.indexOf(\"secrets\") === -1)\n        return \"secrets needs capability secrets\";", "if (false)\n        return \"secrets needs capability secrets\";"],
    ["secrets need a presence list", "if (lists.length === 0)", "if (false)"],
    ["status needs capability status", "if (capabilities.indexOf(\"status\") === -1)\n        return \"status needs capability status\";", "if (false)\n        return \"status needs capability status\";"],
    ["capability status needs a status", "} else if (capabilities.indexOf(\"status\") !== -1) {", "} else if (false) {"],
    ["a status declaration holds an entry", "if (keys.length === 0)\n        return \"status must declare", "if (false)\n        return \"status must declare"],
    ["a status key matches its pattern", "if (!STATUS_KEY_PATTERN.test(key))\n            return \"status key \"", "if (false)\n            return \"status key \""],
    ["a status entry has only known keys", "if (STATUS_ENTRY_KEYS.indexOf(entryKeys[u]) === -1)", "if (false)"],
    ["a status entry names a known type", "if (STATUS_TYPES.indexOf(entry.type) === -1)\n            return at", "if (false)\n            return at"],
    ["a status label is a printable line", "if (!isPrintableLine(entry.label, STATUS_LABEL_MAX))", "if (false)"],
    ["a status group is a printable line", "if (entry.group !== undefined && !isPrintableLine(entry.group, STATUS_LABEL_MAX))", "if (false)"],
    ["a status hint is a printable line", "if (entry.hint !== undefined && !isPrintableLine(entry.hint, STATUS_HINT_MAX))", "if (false)"],
    ["a status command is a printable line", "if (entry.command !== undefined && !isPrintableLine(entry.command, STATUS_COMMAND_MAX))", "if (false)"],
    ["a printable line holds no control character", "!SettingValues.CONTROL_OR_SEPARATOR.test(text)", "true"],
    ["a printable line has a ceiling", "text.length <= max &&", ""],
    ["status hidden is a boolean", "if (entry.hidden !== undefined && typeof entry.hidden !== \"boolean\")", "if (false)"],
    ["a data entry is never drawn", "if (entry[drawn[d]] !== undefined)", "if (false)"],
    ["an absent status is normalised", "manifest.status = raw.status === undefined ? {} : clone(raw.status);", "manifest.status = clone(raw.status);"],
    ["window is a kind", "\"menu\", \"window\", \"pane\", \"service\"", "\"menu\", \"pane\", \"service\""],
    ["pane is a kind", "\"window\", \"pane\", \"service\"", "\"window\", \"service\""],
    ["pane is a manifest key", "\"defaultSection\", \"pane\", \"appearance\"", "\"defaultSection\", \"appearance\""],
    ["pane key is judged", "var badPane = paneError(raw.pane, raw.kinds);", "var badPane = \"\";"],
    ["kind pane needs pane key", "} else if (raw.kinds.indexOf(\"pane\") !== -1) {", "} else if (false) {"],
    ["pane configure writes every target", "return kind === \"pane\" ? settingTargets(config, manifest) : [settingTargetOf(kind)];", "return kind === \"pane\" ? [\"plugins\"] : [settingTargetOf(kind)];"],
    ["pane rows are ordered by group, order, name and id", "    }).sort(function (a, b) {\n        if (a.group !== b.group) return a.group < b.group ? -1 : 1;\n        if (a.order !== b.order) return a.order - b.order;\n        if (a.name !== b.name) return a.name < b.name ? -1 : 1;\n        return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;\n    });", "    });"],
    ["panes holder is an enabled window", "return manifest.capabilities.indexOf(\"panes\") !== -1 && manifest.kinds.indexOf(\"window\") !== -1 && isEnabled(config, manifest, defaultBarId);", "return manifest.capabilities.indexOf(\"panes\") !== -1;"],
    ["window is summonable", "\"menu\", \"window\"];", "\"menu\"];"],
    ["a window is a toplevel", "if (kind === \"window\") return \"window\";", ""],
    ["an anchored window is a toplevel", "if (kind === \"window\") return \"window\";", "if (kind === \"window\" && !anchored) return \"window\";"],
    ["an anchored summon is a popup", "return anchored ? \"popup\" : \"layer\";", "return \"layer\";"],
    ["a kind no host summons is refused a surface", "if (SUMMONABLE_KINDS.indexOf(kind) === -1)\n        throw new Error(\"summonSurface", "if (false)\n        throw new Error(\"summonSurface"],
    ["only full-screen overlays capture the keyboard", "return kind === \"overlay\" && !anchored;", "return kind === \"overlay\";"],
    ["keyboard capture refuses an unsummonable kind", "if (SUMMONABLE_KINDS.indexOf(kind) === -1)\n        throw new Error(\"capturesOverlayKeyboard", "if (false)\n        throw new Error(\"capturesOverlayKeyboard"],
    ["capturing layers take exclusive focus", "return capturesOverlayKeyboard(kind, anchored) ? \"exclusive\" : \"on-demand\";", "return \"on-demand\";"],
    ["a panel or menu layer catches a press beside it", "return !capturesOverlayKeyboard(kind, false);", "return false;"],
    ["an overlay layer catches nothing", "return !capturesOverlayKeyboard(kind, false);", "return true;"],
    ["the catcher refuses a kind never built as a layer", "if (summonSurface(kind, false) !== \"layer\")\n        throw new Error(\"layerCatchesOutside", "if (false)\n        throw new Error(\"layerCatchesOutside"],
    ["a centred surface ignores reserved space", "exclusion: placement === \"center\" ? \"ignore\" : \"normal\"", "exclusion: \"normal\""],
    ["requires is refused by name", "if (hasOwn(raw, \"requires\"))", "if (false)"],
    ["requirements is a manifest key", "\"hyprland\", \"requirements\", ", "\"hyprland\", "],
    ["requirements is a list", "if (!Array.isArray(requirements))\n        return \"requirements must be a list\";", "if (false)\n        return \"requirements must be a list\";"],
    ["a requirement is an object", "if (!isPlainObject(requirement))", "if (false)"],
    ["a requirement carries known keys", "if (REQUIREMENT_KEYS.indexOf(keys[k]) === -1)", "if (false)"],
    ["a requirement command is a bare command name", "if (!PackageManagers.validCommand(requirement.command))", "if (false)"],
    ["a requirement command is never a plugin id", "if (ID_PATTERN.test(requirement.command))", "if (false)"],
    ["a requirement command is declared once", "if (commands.indexOf(requirement.command) !== -1)", "if (false)"],
    ["requirement packages is an object", "if (!isPlainObject(requirement.packages))", "if (false)"],
    ["requirement packages name known managers", "if (PackageManagers.managerRow(managers[m]) === null)", "if (false)"],
    ["a requirement package name is judged", "if (!PackageManagers.validName(requirement.packages[managers[m]]))", "if (false)"],
    ["requirement optional is a boolean", "typeof requirement.optional !== \"boolean\"", "false"],
    ["a requirement purpose is a string", "typeof requirement.purpose !== \"string\" || ", ""],
    ["a requirement purpose is not blank", "requirement.purpose.trim().length === 0 || ", ""],
    ["a requirement purpose is at most 120 characters", "Array.from(requirement.purpose).length > REQUIREMENT_PURPOSE_MAX || ", ""],
    ["a requirement purpose holds no control character", " || CONTROL_CHARACTER.test(requirement.purpose))", ")"],
    ["an absent requirement packages is normalized", "packages: entry.packages === undefined ? {} : clone(entry.packages)", "packages: clone(entry.packages)"],
    ["an absent requirement optional is normalized", "optional: entry.optional === true", "optional: entry.optional"],
    ["a manifest carries its requirements normalized", "manifest.requirements = normalRequirements(requirements);", ""],
    ["an idle watch takes one second at least", "seconds < 1 || ", ""],
    ["an idle watch takes a day at most", " || seconds > IDLE_WATCH_MAX_SECONDS)", ")"],
    ["an idle watch takes whole seconds", "!Number.isInteger(seconds) || ", ""],
    ["an idle watch needs a handler", "if (typeof onChange !== \"function\") return \"refused: idle-handler=not-a-function\";", ""],
    ["a requirement the scan missed is reported missing", "missing.indexOf(entry.command) === -1 ? \"present\" : \"missing\"", "\"present\""],
    ["placing never writes disabledPlugins", "function withPlaced(user, manifest, placed, effective) {\n    var out = isPlainObject(user) ? clone(user) : {};", "function withPlaced(user, manifest, placed, effective) {\n    var out = isPlainObject(user) ? clone(user) : {};\n    out.disabledPlugins = Array.isArray(effective.disabledPlugins) ? effective.disabledPlugins.slice() : [];"],
    ["a widget already as asked changes nothing", "if (placed === isPlaced(effective, manifest))\n        return out;", "if (false)\n        return out;"],
    ["unplacing removes the entries", "return entry.id !== manifest.id; });", "return true; });"],
    ["unplacing lists a third-party plugin enabled by its placement", "if (enablementRule(manifest) === \"row\" && pluginRow(effective, manifest.id) === undefined) {", "if (false) {"],
    ["a third-party plugin of another kind is enabled by its row", "return manifest.id.indexOf(FIRST_PARTY_PREFIX) === 0 ? \"first-party\" : \"row\";", "return \"first-party\";"],
    ["a widget-only plugin is enabled only by its placement", "if (manifest.kinds.every(function (k) { return k === \"bar-widget\"; })) return \"widget\";", ""],
    ["a copied entry setting shares nothing with its source", "target[k] = clone(entry[k]);", "target[k] = entry[k];"],
    ["an unplaced plugin's new row carries the entry's settings", "copyEntrySettings({ id: manifest.id }, layoutEntryOf(out, manifest.id))", "{ id: manifest.id }"],
    ["a placed entry carries the plugins row's settings", "copyEntrySettings({ id: manifest.id }, pluginRow(effective, manifest.id))", "{ id: manifest.id }"],
    ["a disabled plugin's placement is refused", "if (!isEnabled(config, manifest, defaultBarId))\n        return \"refused: placed=\"", "if (false)\n        return \"refused: placed=\""],
    ["a plugin without a widget is refused placement", "if (manifest.kinds.indexOf(\"bar-widget\") === -1)\n        return \"refused: placed=\"", "if (false)\n        return \"refused: placed=\""],
    ["placement needs the widget kind", "return manifest.kinds.indexOf(\"bar-widget\") !== -1 && layoutIds(config).indexOf(manifest.id) !== -1;", "return layoutIds(config).indexOf(manifest.id) !== -1;"],
];

fs.mkdirSync(path.join(__dirname, "..", "tmp"), { recursive: true });
const temp = fs.mkdtempSync(path.join(__dirname, "..", "tmp", "plugin-logic-control-"));
try {
    fs.mkdirSync(path.join(temp, "shell", "Core"), { recursive: true });
    fs.mkdirSync(path.join(temp, "shell", "Commons"), { recursive: true });
    fs.mkdirSync(path.join(temp, "shell", "Ui", "icons"), { recursive: true });
    fs.symlinkSync(SETTING_VALUES, path.join(temp, "shell", "Commons", "SettingValues.js"));
    fs.symlinkSync(LUCIDE, path.join(temp, "shell", "Ui", "icons", "Lucide.js"));
    fs.symlinkSync(MANAGERS, path.join(temp, "shell", "Core", "PackageManagers.js"));
    fs.symlinkSync(LAYER, path.join(temp, "shell", "Core", "HyprlandLayer.js"));
    const source = fs.readFileSync(LOGIC, "utf8");
    for (const [label, needle, replacement] of CONTROLS) {
        const count = source.split(needle).length - 1;
        if (count !== 1) { report("control: " + label + ": the text to replace occurs once", count, 1); continue; }
        const mutant = path.join(temp, "shell", "Core", "PluginLogic.js");
        fs.writeFileSync(mutant, source.replace(needle, () => replacement));
        // Loaded outside the try, so a copy that does not evaluate fails the
        // suite instead of passing for a control.
        const ctx = load(mutant);
        let red = 0;
        try {
            suite(ctx, (name, got, want) => { if (JSON.stringify(got) !== JSON.stringify(want)) red += 1; });
        } catch (e) {
            red += 1;
        }
        report("control: the suite fails without the rule: " + label, red > 0, true);
    }
} finally {
    fs.rmSync(temp, { recursive: true, force: true });
}

if (failures > 0) { console.log("test-plugin-logic: " + failures + " failing"); process.exit(1); }
console.log("test-plugin-logic: ok");
