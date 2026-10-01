.pragma library

// The monitor rules: `monitors.json` judged, rendered as the Hyprland
// layer's `hl.monitor` lines, and compared with the outputs Hyprland lists.
// Pure: no QML object, no I/O, so scripts/test-monitor-logic.js runs it
// under node. MonitorState.qml reads the document and the outputs and holds
// what these answer; HyprlandLayer.qml places render's lines in the layer.
// Every Hyprland v0.56.2 fact the shapes rest on is in
// docs/architecture/runtime-hyprland-monitors.md.

var OUTPUTS_REQUEST = ["hyprctl", "-j", "monitors", "all"];

var VERSION = 1;
var DOCUMENT_KEYS = ["version", "rules"];
// A rule's keys, in the order render writes them.
var RULE_KEYS = ["output", "disabled", "mode", "position", "scale", "transform", "vrr", "mirror", "bitdepth", "cm"];
// What an enabled rule must set; a disabled rule sets nothing but its output.
var REQUIRED_KEYS = ["mode", "position", "scale"];
// The colour modes Hyprland's NCMType::fromString takes; the HDR ones need
// a 10-bit output.
var CM_TYPES = ["auto", "srgb", "dcip3", "dp3", "adobe", "wide", "edid", "hdr", "hdredid"];
var HDR_TYPES = ["hdr", "hdredid"];
var VRR_MODES = [0, 1, 2];
var BITDEPTHS = [8, 10];
// CMonitorRuleParser::parseScale refuses a scale below this.
var SCALE_MIN = 0.25;
// How far a mode size over the scale may sit from a whole number and still
// count as whole logical pixels.
var PIXEL_TOLERANCE = 0.001;
// How far two refresh rates may differ, in Hz, and still be one mode:
// `availableModes` prints two decimals and `refreshRate` five.
var REFRESH_TOLERANCE = 0.015;
// Hyprland keeps a scale as a float32, so a written scale reads back within
// a millionth of itself.
var SCALE_TOLERANCE = 0.000001;

// An output identifier the layer may put in a Lua string: printable ASCII
// with no quote, backslash or comma and no space at either end. Hyprland
// removes every comma from the description a `desc:` rule matches, so an
// identifier holding one matches no output.
var IDENTIFIER = /^[\x21\x23-\x2b\x2d-\x5b\x5d-\x7e](?:[\x20\x21\x23-\x2b\x2d-\x5b\x5d-\x7e]*[\x21\x23-\x2b\x2d-\x5b\x5d-\x7e])?$/;
var MODE = /^([1-9][0-9]{0,4})x([1-9][0-9]{0,4})@([0-9]{1,3}(?:\.[0-9]{1,3})?)$/;
var AVAILABLE_MODE = /^([0-9]+)x([0-9]+)@([0-9]+\.[0-9]+)Hz$/;

function hasOwn(object, key) {
    return Object.prototype.hasOwnProperty.call(object, key);
}

function isPlainObject(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value);
}

// Whether P is a position, `{ x, y }` whole numbers.
function isPosition(p) {
    return isPlainObject(p) && Object.keys(p).length === 2 && Number.isInteger(p.x) && Number.isInteger(p.y);
}

// VALUE as a refusal shows it: JSON, cut to 60 characters.
function shown(value) {
    var text = JSON.stringify(value);
    if (text === undefined) text = String(value);
    return text.length > 60 ? text.slice(0, 57) + "..." : text;
}

// The rule an output's settings are kept under: `desc:<make> <model>
// <serial>` when Hyprland reads a serial, else the connector name. Hyprland
// matches a `desc:` rule against the output's short description, the three
// joined by spaces, trimmed, with every comma removed
// (CMonitor::onConnect, CMonitor::matchesStaticSelector).
function identifier(output) {
    if (output.serial === "") return output.name;
    return "desc:" + (output.make + " " + output.model + " " + output.serial).trim().replace(/,/g, "");
}

// The index in OUTPUTS of the output SELECTOR names, by its identifier or
// its connector, or -1.
function resolve(outputs, selector) {
    for (var i = 0; i < outputs.length; i++)
        if (outputs[i].identifier === selector || outputs[i].name === selector) return i;
    return -1;
}

// `{ width, height, refresh }` of MODE, `WxH@R`.
function modeParts(mode) {
    var m = MODE.exec(mode);
    return { width: Number(m[1]), height: Number(m[2]), refresh: Number(m[3]) };
}

// The reply to OUTPUTS_REQUEST as the capability's `outputs`: { ok: true,
// outputs: [{ identifier, id, name, description, make, model, serial,
// width, height, refreshRate, x, y, scale, transform, vrr, disabled,
// mirrorOf, availableModes: [{ width, height, refresh }], currentFormat }] }
// in Hyprland's order, `mirrorOf` the name of the output mirrored or null,
// or { ok: false, error } with a keyed line.
function parseOutputs(text) {
    var list;
    try {
        list = JSON.parse(text);
    } catch (e) {
        return { ok: false, error: "refused: outputs=unparsed " + String(e.message || e) };
    }
    if (!Array.isArray(list)) return { ok: false, error: "refused: outputs=shape want=list" };
    var out = [];
    for (var i = 0; i < list.length; i++) {
        var m = list[i];
        var bad = function (field) { return { ok: false, error: "refused: outputs=shape output=" + i + " field=" + field }; };
        if (!isPlainObject(m)) return bad("object");
        var strings = ["name", "description", "make", "model", "serial", "mirrorOf", "currentFormat"];
        for (var s = 0; s < strings.length; s++) if (typeof m[strings[s]] !== "string") return bad(strings[s]);
        var whole = ["id", "width", "height", "x", "y", "transform"];
        for (var w = 0; w < whole.length; w++) if (!Number.isInteger(m[whole[w]])) return bad(whole[w]);
        if (typeof m.refreshRate !== "number" || !isFinite(m.refreshRate)) return bad("refreshRate");
        if (typeof m.scale !== "number" || !isFinite(m.scale)) return bad("scale");
        if (typeof m.vrr !== "boolean") return bad("vrr");
        if (typeof m.disabled !== "boolean") return bad("disabled");
        if (!Array.isArray(m.availableModes)) return bad("availableModes");
        var modes = [];
        for (var k = 0; k < m.availableModes.length; k++) {
            var parsed = typeof m.availableModes[k] === "string" ? AVAILABLE_MODE.exec(m.availableModes[k]) : null;
            if (parsed === null) return bad("availableModes");
            modes.push({ width: Number(parsed[1]), height: Number(parsed[2]), refresh: Number(parsed[3]) });
        }
        out.push({
            identifier: "", id: m.id, name: m.name, description: m.description, make: m.make, model: m.model, serial: m.serial,
            width: m.width, height: m.height, refreshRate: m.refreshRate, x: m.x, y: m.y, scale: m.scale, transform: m.transform,
            vrr: m.vrr, disabled: m.disabled, mirrorOf: m.mirrorOf, availableModes: modes, currentFormat: m.currentFormat
        });
    }
    // `mirrorOf` is the mirrored output's id, or `none`.
    for (var j = 0; j < out.length; j++) {
        out[j].identifier = identifier(out[j]);
        if (out[j].mirrorOf === "none") {
            out[j].mirrorOf = null;
            continue;
        }
        var target = out.filter(function (o) { return String(o.id) === out[j].mirrorOf; });
        if (target.length !== 1) return { ok: false, error: "refused: outputs=shape output=" + j + " mirrorOf=" + shown(out[j].mirrorOf) };
        out[j].mirrorOf = target[0].name;
    }
    return { ok: true, outputs: out };
}

// One rule at index I judged on its own fields: { ok: true, rule } with
// its keys in RULE_KEYS order and `disabled` only when true, or { ok:
// false, error }.
function judgeRule(raw, i) {
    var at = "refused: rule=" + i + " ";
    if (!isPlainObject(raw)) return { ok: false, error: at + "rule=" + shown(raw) + " want=object" };
    var keys = Object.keys(raw);
    for (var k = 0; k < keys.length; k++)
        if (RULE_KEYS.indexOf(keys[k]) === -1) return { ok: false, error: at + "key=" + shown(keys[k]) + " want=" + RULE_KEYS.join(",") };
    if (typeof raw.output !== "string" || !IDENTIFIER.test(raw.output))
        return { ok: false, error: at + "output=" + shown(raw.output) + " want=identifier" };
    var rule = { output: raw.output };
    if (hasOwn(raw, "disabled") && typeof raw.disabled !== "boolean")
        return { ok: false, error: at + "disabled=" + shown(raw.disabled) + " want=boolean" };
    if (raw.disabled === true) {
        for (var d = 0; d < keys.length; d++)
            if (keys[d] !== "output" && keys[d] !== "disabled")
                return { ok: false, error: at + keys[d] + "=" + shown(raw[keys[d]]) + " want=absent-when-disabled" };
        rule.disabled = true;
        return { ok: true, rule: rule };
    }
    for (var r = 0; r < REQUIRED_KEYS.length; r++)
        if (!hasOwn(raw, REQUIRED_KEYS[r])) return { ok: false, error: at + REQUIRED_KEYS[r] + "=missing want=" + REQUIRED_KEYS.join(",") };
    if (typeof raw.mode !== "string" || !MODE.test(raw.mode) || modeParts(raw.mode).refresh <= 0)
        return { ok: false, error: at + "mode=" + shown(raw.mode) + " want=WxH@R" };
    rule.mode = raw.mode;
    var p = raw.position;
    if (!isPosition(p)) return { ok: false, error: at + "position=" + shown(p) + " want={x,y}-whole-numbers" };
    rule.position = { x: p.x, y: p.y };
    if (typeof raw.scale !== "number" || !isFinite(raw.scale) || raw.scale < SCALE_MIN)
        return { ok: false, error: at + "scale=" + shown(raw.scale) + " want=number>=" + SCALE_MIN };
    var size = modeParts(raw.mode);
    var fractional = [size.width, size.height].some(function (side) {
        var logical = side / raw.scale;
        return Math.abs(logical - Math.round(logical)) > PIXEL_TOLERANCE;
    });
    if (fractional)
        return { ok: false, error: at + "scale=" + shown(raw.scale) + " want=whole-logical-pixels mode=" + size.width + "x" + size.height };
    rule.scale = raw.scale;
    if (hasOwn(raw, "transform")) {
        if (!Number.isInteger(raw.transform) || raw.transform < 0 || raw.transform > 7)
            return { ok: false, error: at + "transform=" + shown(raw.transform) + " want=0..7" };
        rule.transform = raw.transform;
    }
    if (hasOwn(raw, "vrr")) {
        if (VRR_MODES.indexOf(raw.vrr) === -1) return { ok: false, error: at + "vrr=" + shown(raw.vrr) + " want=" + VRR_MODES.join("|") };
        rule.vrr = raw.vrr;
    }
    if (hasOwn(raw, "mirror")) {
        if (typeof raw.mirror !== "string" || !IDENTIFIER.test(raw.mirror))
            return { ok: false, error: at + "mirror=" + shown(raw.mirror) + " want=identifier" };
        if (raw.mirror === raw.output) return { ok: false, error: at + "mirror=" + shown(raw.mirror) + " want=another-output" };
        rule.mirror = raw.mirror;
    }
    if (hasOwn(raw, "bitdepth")) {
        if (BITDEPTHS.indexOf(raw.bitdepth) === -1) return { ok: false, error: at + "bitdepth=" + shown(raw.bitdepth) + " want=" + BITDEPTHS.join("|") };
        rule.bitdepth = raw.bitdepth;
    }
    if (hasOwn(raw, "cm")) {
        if (CM_TYPES.indexOf(raw.cm) === -1) return { ok: false, error: at + "cm=" + shown(raw.cm) + " want=" + CM_TYPES.join("|") };
        if (HDR_TYPES.indexOf(raw.cm) !== -1 && raw.bitdepth !== 10) return { ok: false, error: at + "cm=" + shown(raw.cm) + " want=bitdepth-10" };
        rule.cm = raw.cm;
    }
    return { ok: true, rule: rule };
}

// The rule among RULES that Hyprland applies to OUTPUT: the last one naming
// its identifier or its connector, as CMonitorRuleManager::get searches
// from the end; null when none does.
function ruleFor(rules, output) {
    for (var i = rules.length - 1; i >= 0; i--)
        if (rules[i].output === output.identifier || rules[i].output === output.name) return rules[i];
    return null;
}

// Whether listed OUTPUT is held off by a user line after the loading
// line: Hyprland lists it disabled while SAVED, the rules the layer holds
// now, enable it. No rule the layer writes turns it on, since the later
// line wins.
function heldOff(saved, output) {
    if (!output.disabled) return false;
    var rule = ruleFor(saved, output);
    return rule !== null && rule.disabled !== true;
}

// Whether output SELECTOR shows anything once RULES apply: it is not held
// off, and its rule is enabled, or it has none and Hyprland lists it
// enabled.
function staysOn(rules, outputs, saved, selector) {
    var index = resolve(outputs, selector);
    if (index !== -1 && heldOff(saved, outputs[index])) return false;
    for (var i = rules.length - 1; i >= 0; i--)
        if (rules[i].output === selector || (index !== -1 && resolve(outputs, rules[i].output) === index)) return rules[i].disabled !== true;
    return index !== -1 && !outputs[index].disabled;
}

// DOC, monitors.json's value, judged: { ok: true, rules } or { ok: false,
// error } with a keyed line naming the first fault. OUTPUTS, parseOutputs's
// list, judges the rules against the outputs Hyprland lists: a mirror must
// name another output that stays on, a listed output's mode must be one it
// lists when it lists any, and one listed output must stay on. SAVED, the
// judged rules the layer holds now, tells an output a user line holds off
// from one the write turns on (heldOff). A rule for an output Hyprland
// does not list is kept for when it is plugged in. With OUTPUTS null, as
// for a document read from disk, the rules are judged on their own fields
// alone and SAVED is not read.
function judge(doc, outputs, saved) {
    if (!isPlainObject(doc)) return { ok: false, error: "refused: monitors=" + shown(doc) + " want=object" };
    var keys = Object.keys(doc);
    for (var k = 0; k < keys.length; k++)
        if (DOCUMENT_KEYS.indexOf(keys[k]) === -1) return { ok: false, error: "refused: monitors.key=" + shown(keys[k]) + " want=" + DOCUMENT_KEYS.join(",") };
    if (doc.version !== VERSION) return { ok: false, error: "refused: monitors.version=" + shown(doc.version) + " want=" + VERSION };
    if (!Array.isArray(doc.rules)) return { ok: false, error: "refused: monitors.rules=" + shown(doc.rules) + " want=list" };
    var rules = [];
    for (var i = 0; i < doc.rules.length; i++) {
        var judged = judgeRule(doc.rules[i], i);
        if (!judged.ok) return judged;
        for (var j = 0; j < rules.length; j++)
            if (rules[j].output === judged.rule.output)
                return { ok: false, error: "refused: rule=" + i + " output=" + shown(judged.rule.output) + " want=unique" };
        rules.push(judged.rule);
    }
    if (outputs === null) return { ok: true, rules: rules };
    if (!Array.isArray(saved)) throw new Error("MonitorLogic.judge: saved " + shown(saved) + " is no list of judged rules while the outputs are read");
    for (var r = 0; r < rules.length; r++) {
        var rule = rules[r];
        var at = "refused: rule=" + r + " ";
        if (rule.disabled === true) continue;
        var index = resolve(outputs, rule.output);
        if (rule.mirror !== undefined) {
            if (index !== -1 && resolve(outputs, rule.mirror) === index)
                return { ok: false, error: at + "mirror=" + shown(rule.mirror) + " want=another-output" };
            if (!staysOn(rules, outputs, saved, rule.mirror))
                return { ok: false, error: at + "mirror=" + shown(rule.mirror) + " want=output-on" };
        }
        if (index === -1 || outputs[index].availableModes.length === 0) continue;
        var want = modeParts(rule.mode);
        var listed = outputs[index].availableModes.some(function (mode) {
            return mode.width === want.width && mode.height === want.height && Math.abs(mode.refresh - want.refresh) <= REFRESH_TOLERANCE;
        });
        if (!listed) return { ok: false, error: at + "mode=" + shown(rule.mode) + " want=available-mode" };
    }
    var on = outputs.some(function (output) {
        if (heldOff(saved, output)) return false;
        var rule = ruleFor(rules, output);
        return rule === null ? !output.disabled : rule.disabled !== true;
    });
    if (outputs.length > 0 && !on) return { ok: false, error: "refused: rules=no-output-on want=one-output-on" };
    return { ok: true, rules: rules };
}

// monitors.json's text: judge(JSON.parse(TEXT), null), or { ok: false,
// error } for text that is no JSON.
function readDocument(text) {
    var doc;
    try {
        doc = JSON.parse(text);
    } catch (e) {
        return { ok: false, error: "refused: monitors=unparsed " + String(e.message || e) };
    }
    return judge(doc, null);
}

// The text written for judged RULES.
function documentText(rules) {
    return JSON.stringify({ version: VERSION, rules: rules }, null, 2) + "\n";
}

// One `hl.monitor` line per judged rule, in order, each field written only
// when the rule sets it. Every value is a judged literal: an identifier
// holds no quote, backslash or control character.
function render(rules) {
    return rules.map(function (rule) {
        var fields = ["output = \"" + rule.output + "\""];
        if (rule.disabled === true) return "hl.monitor({ " + fields.concat(["disabled = true"]).join(", ") + " })";
        fields.push("mode = \"" + rule.mode + "\"", "position = \"" + rule.position.x + "x" + rule.position.y + "\"", "scale = " + String(rule.scale));
        if (rule.transform !== undefined) fields.push("transform = " + rule.transform);
        if (rule.vrr !== undefined) fields.push("vrr = " + rule.vrr);
        if (rule.mirror !== undefined) fields.push("mirror = \"" + rule.mirror + "\"");
        if (rule.bitdepth !== undefined) fields.push("bitdepth = " + rule.bitdepth);
        if (rule.cm !== undefined) fields.push("cm = \"" + rule.cm + "\"");
        return "hl.monitor({ " + fields.join(", ") + " })";
    });
}

// Whether listed output OUTPUT shows otherwise than enabled rule RULE sets.
// A mirror rule is read by its mirror alone: Hyprland shows the mirrored
// output there. `vrr` is not read: `monitors -j` prints whether adaptive
// sync runs now, which a rule's 1 does not make true on an output without
// it, nor its 2 outside fullscreen.
function enabledDiffers(rule, output, outputs) {
    if (output.disabled) return true;
    if (rule.mirror !== undefined) {
        var target = resolve(outputs, rule.mirror);
        return output.mirrorOf === null || target === -1 || outputs[target].name !== output.mirrorOf;
    }
    if (output.mirrorOf !== null) return true;
    var mode = modeParts(rule.mode);
    if (mode.width !== output.width || mode.height !== output.height || Math.abs(mode.refresh - output.refreshRate) > REFRESH_TOLERANCE) return true;
    if (rule.position.x !== output.x || rule.position.y !== output.y) return true;
    if (Math.abs(rule.scale - output.scale) > SCALE_TOLERANCE * Math.max(1, rule.scale)) return true;
    return rule.transform !== undefined && rule.transform !== output.transform;
}

// The identifiers of judged RULES whose listed output Hyprland reads back
// otherwise, sorted: a user line after the layer's, or a mode the output
// fell back from. A rule for an output Hyprland does not list is never
// overridden. Null while OUTPUTS is unread.
function overridden(rules, outputs) {
    if (outputs === null) return null;
    var out = [];
    rules.forEach(function (rule) {
        var index = resolve(outputs, rule.output);
        if (index === -1) return;
        var output = outputs[index];
        var differs = rule.disabled === true ? !output.disabled : enabledDiffers(rule, output, outputs);
        if (differs) out.push(rule.output);
    });
    return out.sort();
}

// The preview: rules applied through `hyprctl eval` under a record and a
// detached guard that restores the state captured before them
// (docs/architecture/hyprland-monitors-preview.md). bin/lib/monitor-preview.js
// runs the steps; these decide each one.

var PREVIEW_VERSION = 1;
var PREVIEW_SECONDS_MIN = 2;
var PREVIEW_SECONDS_MAX = 60;
// The fields a capture cannot read back, so no restore could put them back.
var PREVIEW_UNRESTORED = ["bitdepth", "cm"];
var RECORD_KEYS = ["version", "token", "deadline", "signature", "captured"];
var CAPTURE_KEYS = ["output", "disabled", "mode", "position", "scale", "transform", "mirror", "vrr"];
var TOKEN = /^[0-9a-f]{32}$/;
// HYPRLAND_INSTANCE_SIGNATURE as Hyprland makes it: the commit, the start
// time and a random number joined by `_`. hyprctl --instance reads a value
// of digits alone as an instance index, so none is one.
var SIGNATURE = /^(?![0-9]+$)[A-Za-z0-9_]{1,128}$/;
var PREVIEW_REPLY = /^ok token=([0-9a-f]{32}) deadline=([1-9][0-9]*)$/;

// SECONDS as a preview's length, or the refusal line.
function previewSecondsError(seconds) {
    if (Number.isInteger(seconds) && seconds >= PREVIEW_SECONDS_MIN && seconds <= PREVIEW_SECONDS_MAX) return "";
    return "refused: seconds=" + shown(seconds) + " want=" + PREVIEW_SECONDS_MIN + ".." + PREVIEW_SECONDS_MAX;
}

// What LISTED, one output parseOutputs read, shows now, kept under rule
// selector OUTPUT: off, or its mode, position, scale, transform and mirror;
// `vrr` whether adaptive sync runs, read only when VRR_SET, since monitors -j
// prints no rule's setting. Null for an enabled output with no mode, which no
// rule could give back.
function captureOf(output, listed, vrrSet) {
    if (listed.disabled) return { output: output, disabled: true };
    var mode = listed.width + "x" + listed.height + "@" + listed.refreshRate.toFixed(3);
    if (!MODE.test(mode)) return null;
    return {
        output: output, disabled: false, mode: mode, position: { x: listed.x, y: listed.y }, scale: listed.scale,
        transform: listed.transform, mirror: listed.mirrorOf, vrr: vrrSet ? listed.vrr : null
    };
}

// A preview of RULES, a list a plugin hands monitors.preview, judged as
// write judges it against OUTPUTS and SAVED: { ok: true, rules, applied,
// captured } or { ok: false, error }. `rules` is every judged rule, the list
// Keep saves; `applied` the ones naming a listed output, which the preview
// applies; `captured` each listed output's state before them, one entry per
// output, under the first rule naming it. A rule for an output Hyprland does
// not list is kept and not applied. A rule that sets a field no capture
// reads back is refused.
function previewPlan(rules, outputs, saved) {
    var judged = judge({ version: VERSION, rules: rules }, outputs, saved);
    if (!judged.ok) return judged;
    var applied = [];
    var captured = [];
    var seen = [];
    for (var i = 0; i < judged.rules.length; i++) {
        var rule = judged.rules[i];
        for (var u = 0; u < PREVIEW_UNRESTORED.length; u++)
            if (hasOwn(rule, PREVIEW_UNRESTORED[u]))
                return { ok: false, error: "refused: rule=" + i + " " + PREVIEW_UNRESTORED[u] + "=" + shown(rule[PREVIEW_UNRESTORED[u]]) + " want=absent-in-preview" };
        var index = resolve(outputs, rule.output);
        if (index === -1) continue;
        applied.push(rule);
        if (seen.indexOf(index) !== -1) continue;
        seen.push(index);
        var entry = captureOf(rule.output, outputs[index], rule.vrr !== undefined);
        if (entry === null) return { ok: false, error: "refused: capture=unsized output=" + shown(rule.output) };
        captured.push(entry);
    }
    return { ok: true, rules: judged.rules, applied: applied, captured: captured };
}

// One captured entry judged: "" or the refusal's text after
// `record.captured=<i> `.
function captureError(entry) {
    if (!isPlainObject(entry)) return "entry=" + shown(entry) + " want=object";
    var keys = Object.keys(entry);
    for (var k = 0; k < keys.length; k++)
        if (CAPTURE_KEYS.indexOf(keys[k]) === -1) return "key=" + shown(keys[k]) + " want=" + CAPTURE_KEYS.join(",");
    if (typeof entry.output !== "string" || !IDENTIFIER.test(entry.output)) return "output=" + shown(entry.output) + " want=identifier";
    if (typeof entry.disabled !== "boolean") return "disabled=" + shown(entry.disabled) + " want=boolean";
    if (entry.disabled) return keys.length === 2 ? "" : "keys=" + shown(keys) + " want=output,disabled";
    if (keys.length !== CAPTURE_KEYS.length) return "keys=" + shown(keys) + " want=" + CAPTURE_KEYS.join(",");
    if (typeof entry.mode !== "string" || !MODE.test(entry.mode)) return "mode=" + shown(entry.mode) + " want=WxH@R";
    var p = entry.position;
    if (!isPosition(p)) return "position=" + shown(p) + " want={x,y}-whole-numbers";
    if (typeof entry.scale !== "number" || !isFinite(entry.scale) || entry.scale < SCALE_MIN) return "scale=" + shown(entry.scale) + " want=number>=" + SCALE_MIN;
    if (!Number.isInteger(entry.transform) || entry.transform < 0 || entry.transform > 7) return "transform=" + shown(entry.transform) + " want=0..7";
    if (entry.mirror !== null && (typeof entry.mirror !== "string" || !IDENTIFIER.test(entry.mirror))) return "mirror=" + shown(entry.mirror) + " want=identifier|null";
    if (entry.vrr !== null && typeof entry.vrr !== "boolean") return "vrr=" + shown(entry.vrr) + " want=boolean|null";
    return "";
}

// The preview record's text, judged: { ok: true, record } or { ok: false,
// error } naming the first fault.
function readRecord(text) {
    var record;
    try {
        record = JSON.parse(text);
    } catch (e) {
        return { ok: false, error: "refused: record=unparsed " + String(e.message || e) };
    }
    if (!isPlainObject(record)) return { ok: false, error: "refused: record=" + shown(record) + " want=object" };
    var keys = Object.keys(record);
    if (keys.length !== RECORD_KEYS.length || RECORD_KEYS.some(function (key) { return !hasOwn(record, key); }))
        return { ok: false, error: "refused: record.keys=" + shown(keys) + " want=" + RECORD_KEYS.join(",") };
    if (record.version !== PREVIEW_VERSION) return { ok: false, error: "refused: record.version=" + shown(record.version) + " want=" + PREVIEW_VERSION };
    if (typeof record.token !== "string" || !TOKEN.test(record.token)) return { ok: false, error: "refused: record.token=" + shown(record.token) + " want=32-hex" };
    if (!Number.isInteger(record.deadline) || record.deadline <= 0) return { ok: false, error: "refused: record.deadline=" + shown(record.deadline) + " want=epoch-seconds" };
    if (typeof record.signature !== "string" || !SIGNATURE.test(record.signature)) return { ok: false, error: "refused: record.signature=" + shown(record.signature) + " want=signature" };
    if (!Array.isArray(record.captured)) return { ok: false, error: "refused: record.captured=" + shown(record.captured) + " want=list" };
    for (var i = 0; i < record.captured.length; i++) {
        var fault = captureError(record.captured[i]);
        if (fault !== "") return { ok: false, error: "refused: record.captured=" + i + " " + fault };
    }
    return { ok: true, record: record };
}

function recordText(record) {
    return JSON.stringify(record) + "\n";
}

// The restore of CAPTURED against OUTPUTS, the outputs listed now: { lines,
// rules, skipped }. `lines` sets each listed output's captured state again,
// one `hl.monitor` per entry with every captured field written, since an
// `hl.monitor` for a name a rule holds keeps each field it leaves out:
// `disabled` either way, a mirror of `""` for none, and `vrr` only where the
// preview set it.
// `rules` are the same states as judged rules, which `overridden` reads back.
// `skipped` names each entry whose output is no longer listed.
function restorePlan(captured, outputs) {
    var out = { lines: [], rules: [], skipped: [] };
    captured.forEach(function (entry) {
        if (resolve(outputs, entry.output) === -1) {
            out.skipped.push(entry.output);
            return;
        }
        var head = "hl.monitor({ output = \"" + entry.output + "\", ";
        if (entry.disabled) {
            out.lines.push(head + "disabled = true })");
            out.rules.push({ output: entry.output, disabled: true });
            return;
        }
        var fields = ["disabled = false", "mode = \"" + entry.mode + "\"", "position = \"" + entry.position.x + "x" + entry.position.y + "\"",
                      "scale = " + String(entry.scale), "transform = " + entry.transform, "mirror = \"" + (entry.mirror === null ? "" : entry.mirror) + "\""];
        if (entry.vrr !== null) fields.push("vrr = " + (entry.vrr ? 1 : 0));
        out.lines.push(head + fields.join(", ") + " })");
        var rule = { output: entry.output, mode: entry.mode, position: entry.position, scale: entry.scale, transform: entry.transform };
        if (entry.mirror !== null) rule.mirror = entry.mirror;
        out.rules.push(rule);
    });
    return out;
}

// What the guard holding TOKEN does with RECORD, null when none, at NOW,
// epoch seconds, as the guard of Hyprland instance SIGNATURE: `gone` when
// the record is gone or another preview's, `foreign` when another
// instance's, which it leaves, `wait` before the deadline, `restore` from
// the deadline on.
function guardAction(record, token, signature, now) {
    if (record === null || record.token !== token) return "gone";
    if (record.signature !== signature) return "foreign";
    return now < record.deadline ? "wait" : "restore";
}

// What a shell start does with RECORD, null when none, as Hyprland instance
// SIGNATURE, while a guard holds the guard lock (GUARDED) or none does:
// `none`, `foreign` for another instance's record, which it leaves,
// `guarded` when a guard runs, `arm` to start one.
function adoptAction(record, signature, guarded) {
    if (record === null) return "none";
    if (record.signature !== signature) return "foreign";
    return guarded ? "guarded" : "arm";
}

// Why confirm or revert of TOKEN by Hyprland instance SIGNATURE may not act
// on RECORD, null when none: "" when it may, else the refusal line.
function tokenError(record, token, signature) {
    if (record === null) return "refused: preview=gone";
    if (record.token !== token) return "refused: token=mismatch";
    if (record.signature !== signature) return "refused: preview=foreign signature=" + record.signature;
    return "";
}

// The helper's answer to a run that exited with CODE, STDOUT and STDERR as
// the shell reads it: { ok: true, token, deadline } for a preview's `ok`
// line, { ok: true } for another verb's, else { ok: false, error } with the
// helper's refusal line, `vgsh: ` dropped, or `refused: monitor-guard=failed
// status=<code>` for a run that printed none, such as one killed. CODE is -1
// for a run that did not start.
function guardReply(code, stdout, stderr) {
    var first = stderr.split("\n")[0];
    if (code !== 0) {
        if (first.indexOf("vgsh: refused: ") === 0) return { ok: false, error: first.slice("vgsh: ".length) };
        return { ok: false, error: "refused: monitor-guard=failed status=" + code };
    }
    var line = stdout.trim();
    var m = PREVIEW_REPLY.exec(line);
    if (m !== null) return { ok: true, token: m[1], deadline: Number(m[2]) };
    if (line === "ok" || line.indexOf("ok ") === 0) return { ok: true };
    return { ok: false, error: "refused: monitor-guard=unread reply=" + shown(line) };
}
