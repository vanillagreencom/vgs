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
    if (!isPlainObject(p) || Object.keys(p).length !== 2 || !Number.isInteger(p.x) || !Number.isInteger(p.y))
        return { ok: false, error: at + "position=" + shown(p) + " want={x,y}-whole-numbers" };
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
