.pragma library
.import "../Ui/icons/Lucide.js" as Lucide
.import "PackageManagers.js" as PackageManagers
.import "HyprlandLayer.js" as HyprlandLayer

// Pure decisions about plugins and configuration. No QML objects, no I/O, so
// scripts/test-plugin-logic.js runs every function under node. The icon set
// a manifest's `icon` names is the one Icon draws from, and the manager ids
// a requirement's `packages` names are the package-manager table's (D034),
// and the size classes a `tui` entry names are the Hyprland layer's window
// table, each imported here so the shell and every offline reader judge
// against one list.

// The kinds the core hosts. A manifest naming any other kind is refused. A
// kind's entry point is keyed by the kind name in `entryPoints`.
var KINDS = ["bar-widget", "bar", "panel", "overlay", "menu", "service", "background"];

// Capabilities the core can hand a plugin. A manifest naming another one is
// refused. Capabilities.qml maps each name to its provider.
var CAPABILITIES = ["compositor", "configure", "ipc", "lock", "notifications", "polkit", "run", "screens", "shortcut", "surfaces", "builtins", "manager", "toasts", "theme", "layers", "status", "tui", "requirements"];

// The toast stack's ceilings: how many show at once and how many wait. Core
// policy; a theme sets the look and the default duration, never these.
var TOAST_VISIBLE_MAX = 3;
var TOAST_QUEUE_MAX = 20;
var TOAST_TONES = ["neutral", "accent", "success", "warning", "danger", "info"];
var TOAST_KEYS = ["title", "message", "tone", "icon", "duration"];
// A toast's title is one line and its message a few: longer text is not a
// toast.
var TOAST_TITLE_MAX = 120;
var TOAST_MESSAGE_MAX = 600;

// Capabilities whose core object serves one plugin at a time: the session
// lock and the polkit agent. A second plugin naming one is not built while
// another plugin holds it.
var EXCLUSIVE_CAPABILITIES = ["lock", "polkit"];

// The types a settings schema entry may declare, and the keys an entry may
// carry. `min`, `max` and `step` bound a number's control; `group` names the
// section heading the entry is drawn under.
var SETTING_TYPES = ["string", "number", "boolean", "enum"];
var SCHEMA_ENTRY_KEYS = ["type", "label", "description", "options", "min", "max", "step", "group"];
var NUMBER_BOUND_KEYS = ["min", "max", "step"];

// The icon a plugin without a manifest `icon` is listed with.
var DEFAULT_ICON = "package";

var SECTIONS = ["left", "center", "right"];

// Kinds a host shows on demand: `summon`, `hide` and `toggle` reach them.
// Every other kind is shown for as long as it is enabled.
var SUMMONABLE_KINDS = ["panel", "overlay", "menu"];

// Where a summoned panel or menu may sit when no anchor places it, read
// from the plugin's `placement` setting. `center` when the setting is
// absent.
var PLACEMENTS = ["top-left", "top", "top-right", "left", "center", "right", "bottom-left", "bottom", "bottom-right"];


// Every key a manifest may carry. An unknown key is refused, so a misspelt
// key fails loudly instead of being carried and ignored.
var MANIFEST_KEYS = ["schemaVersion", "id", "name", "version", "author", "description", "license", "icon", "kinds", "entryPoints", "capabilities", "settings", "schema", "defaultSection", "appearance", "hyprland", "requirements", "status", "tui"];

// What one entry of a manifest's `requirements`, and of the core's own
// config/requirements.json, may carry: an external command the plugin runs,
// the package that provides it per manager id of PackageManagers.js, whether
// the plugin works without it, and one line saying what it is for. The
// states a probed requirement is reported in.
var REQUIREMENT_KEYS = ["command", "packages", "optional", "purpose"];
var REQUIREMENT_PURPOSE_MAX = 120;
var REQUIREMENT_STATES = ["present", "missing"];
// A purpose is one printable line: no C0 or C1 control character.
var CONTROL_CHARACTER = /[\u0000-\u001f\u007f-\u009f]/;


// Plugin status: the runtime values a plugin publishes through its `status`
// capability, each declared in the manifest's `status` key with one of these
// types. `data` is structured JSON only the plugin's own instances read; the
// Settings window draws every other type unless the entry is `hidden`.
var STATUS_TYPES = ["presence", "state", "text", "count", "time", "data"];
var STATUS_ENTRY_KEYS = ["type", "label", "group", "hint", "command", "hidden"];
// A status key names a value in `shell.status.values`, so it is a plain
// identifier.
var STATUS_KEY_PATTERN = /^[a-z][A-Za-z0-9]*$/;
// Declaration text lengths, in characters: a label and a group are one short
// line, a hint a sentence, a command one shell line the page shows and never
// runs. A `text` value and a `state` value's text are one line of this length.
var STATUS_LABEL_MAX = 60;
var STATUS_HINT_MAX = 200;
var STATUS_COMMAND_MAX = 300;
var STATUS_TEXT_MAX = 200;
// The ceiling on one plugin's published values: the UTF-8 bytes of their
// JSON. A write that would pass it is refused and the values stay.
var STATUS_MAX_BYTES = 65536;
// A `presence` value, and the badge tone Settings draws it with: the thing is
// stored and readable; not stored; stored but locked, so a background probe
// cannot read it without prompting; its store cannot be asked; stored where
// another user can read it.
var STATUS_PRESENCE_TONES = { present: "success", absent: "warning", locked: "info", unavailable: "neutral", unsafe: "danger" };
// A `state` value's `tone`, and the badge tone Settings draws it with.
var STATUS_STATE_TONES = { ok: "success", info: "info", warning: "warning", danger: "danger" };
// The keys a `state` value carries.
var STATUS_STATE_KEYS = ["tone", "text"];

// A name a plugin registers a shortcut, an IPC target or a built-in widget
// under, the name a manifest's Hyprland bind gives its shortcut, and the name
// a manifest's `tui` key declares a script under.
// Capabilities.checkName refuses any other.
var NAME_PATTERN = /^[a-z0-9][a-z0-9-]*$/;

// What a manifest's `hyprland` key may hold: binds of the plugin's own
// shortcuts and blur rules for the core's layer namespaces. Data only; the
// core renders it (HyprlandLayer.js), so no plugin text reaches the
// compositor's Lua.
var HYPRLAND_KEYS = ["binds", "layerRules"];
var HYPRLAND_BIND_KEYS = ["shortcut", "key"];
var HYPRLAND_RULE_KEYS = ["namespace", "blur", "ignoreAlpha"];
// The modifiers a Hyprland key may hold, in the order a normalised key
// writes them, and the key name after them: a keysym name, which Hyprland
// looks up without regard to case.
var HYPRLAND_MODIFIERS = ["SUPER", "CTRL", "ALT", "SHIFT"];
var HYPRLAND_KEY_NAME = /^[A-Za-z0-9_]+$/;
// A layer rule matches one core host's namespace, anchored: `^vgs:<name>$`.
var HYPRLAND_NAMESPACE = /^\^vgs:[a-z][a-z0-9-]*\$$/;

function hasOwn(obj, key) {
    return obj !== null && typeof obj === "object" && Object.prototype.hasOwnProperty.call(obj, key);
}

var ID_PATTERN = /^[a-z0-9]+(\.[a-z0-9-]+)+$/;

// First-party plugins carry this prefix. They are enabled unless disabled;
// every other plugin is enabled only when the configuration names it.
var FIRST_PARTY_PREFIX = "vgs.";

function isPlainObject(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value);
}

function clone(value) {
    return value === undefined ? undefined : JSON.parse(JSON.stringify(value));
}

// The version a configuration file declares. `withEnabled` and `withSetting`
// write it into a user file that has none.
var CONFIG_VERSION = 1;

// The first defect of a configuration file (shipped or user), or "". The
// file is an object; `version`, when present, is CONFIG_VERSION; `plugins`
// is a list of objects each with a string `id`, and a row's `keys`, when
// present, passes keysError; `disabledPlugins` and
// `disabledTargets` are lists of strings; `bar` is an object whose `id` is
// a string and whose `layout` holds, per section in SECTIONS, a list of
// objects each with a string `id`; `packages` is an object whose `elevate`,
// when present, is one of PackageManagers.ELEVATORS, the command
// `vgsh pkg run` elevates through.
// A key outside that set is carried untouched. Config.qml runs this judge
// on every parsed file and reports a defect as the file's state, so no
// malformed row is dropped on the way to the screen.
function configError(config) {
    if (!isPlainObject(config))
        return "config must be an object";
    if (config.version !== undefined && config.version !== CONFIG_VERSION)
        return "version must be " + CONFIG_VERSION + ", got " + JSON.stringify(config.version);
    var rows = function (list, at) {
        if (!Array.isArray(list))
            return at + " must be a list";
        for (var i = 0; i < list.length; i++) {
            if (!isPlainObject(list[i]) || typeof list[i].id !== "string")
                return at + "." + i + " must be an object with a string id";
        }
        return "";
    };
    var bad;
    if (config.plugins !== undefined && (bad = rows(config.plugins, "plugins")) !== "")
        return bad;
    if (config.plugins !== undefined) {
        for (var p = 0; p < config.plugins.length; p++) {
            if (config.plugins[p].keys !== undefined && (bad = keysError(config.plugins[p].keys, "plugins." + p + ".keys")) !== "")
                return bad;
        }
    }
    var names = function (list, at) {
        if (!Array.isArray(list))
            return at + " must be a list";
        for (var i = 0; i < list.length; i++) {
            if (typeof list[i] !== "string")
                return at + "." + i + " must be a string";
        }
        return "";
    };
    if (config.disabledPlugins !== undefined && (bad = names(config.disabledPlugins, "disabledPlugins")) !== "")
        return bad;
    if (config.disabledTargets !== undefined && (bad = names(config.disabledTargets, "disabledTargets")) !== "")
        return bad;
    if (config.packages !== undefined) {
        if (!isPlainObject(config.packages))
            return "packages must be an object";
        if (config.packages.elevate !== undefined && PackageManagers.ELEVATORS.indexOf(config.packages.elevate) === -1)
            return "packages.elevate must be one of " + PackageManagers.ELEVATORS.join(", ") + ", got " + JSON.stringify(config.packages.elevate);
    }
    if (config.bar !== undefined) {
        if (!isPlainObject(config.bar))
            return "bar must be an object";
        if (config.bar.id !== undefined && typeof config.bar.id !== "string")
            return "bar.id must be a string";
        if (config.bar.layout !== undefined) {
            if (!isPlainObject(config.bar.layout))
                return "bar.layout must be an object";
            for (var s = 0; s < SECTIONS.length; s++) {
                var section = SECTIONS[s];
                if (config.bar.layout[section] !== undefined && (bad = rows(config.bar.layout[section], "bar.layout." + section)) !== "")
                    return bad;
            }
        }
    }
    return "";
}

// Why `value` does not fit a schema entry, or "" when it does. A number
// outside the entry's `min` or `max` does not fit; `step` refuses nothing.
function settingError(entry, value) {
    if (entry.type === "string") return typeof value === "string" ? "" : "want=string";
    if (entry.type === "number") {
        if (typeof value !== "number" || !isFinite(value)) return "want=number";
        if (entry.min !== undefined && value < entry.min) return "want=at-least:" + entry.min;
        if (entry.max !== undefined && value > entry.max) return "want=at-most:" + entry.max;
        return "";
    }
    if (entry.type === "boolean") return typeof value === "boolean" ? "" : "want=boolean";
    if (entry.type === "enum") return entry.options.indexOf(value) !== -1 ? "" : "want=one-of:" + entry.options.join("|");
    throw new Error("settingError: schema entry type " + JSON.stringify(entry.type) + " passed validation but has no rule");
}

// The first defect of a settings schema, or "". Every entry names a type
// from SETTING_TYPES and a label; an enum entry lists its options; a number
// entry may bound its control with finite `min` below finite `max` and a
// positive `step`, which no other type carries; `group`, when present, is a
// non-empty string; every entry has a default of its type, inside its
// bounds, in `settings`, so a form always has a value to show.
function schemaError(schema, settings) {
    if (!isPlainObject(schema))
        return "schema must be an object";
    if (hasOwn(schema, "id"))
        return "schema must not carry an id key";
    var keys = Object.keys(schema);
    for (var i = 0; i < keys.length; i++) {
        var key = keys[i];
        var entry = schema[key];
        var at = "schema." + key;
        if (!isPlainObject(entry))
            return at + " must be an object";
        var entryKeys = Object.keys(entry);
        for (var u = 0; u < entryKeys.length; u++) {
            if (SCHEMA_ENTRY_KEYS.indexOf(entryKeys[u]) === -1)
                return at + " has unknown key " + JSON.stringify(entryKeys[u]);
        }
        if (SETTING_TYPES.indexOf(entry.type) === -1)
            return at + ".type must be one of " + SETTING_TYPES.join(", ") + ", got " + JSON.stringify(entry.type);
        if (typeof entry.label !== "string" || entry.label.length === 0)
            return at + ".label must be a non-empty string";
        if (entry.description !== undefined && typeof entry.description !== "string")
            return at + ".description must be a string when present";
        if (entry.type === "enum") {
            if (!Array.isArray(entry.options) || entry.options.length === 0)
                return at + ".options must be a non-empty array for type enum";
            for (var o = 0; o < entry.options.length; o++) {
                if (typeof entry.options[o] !== "string" || entry.options[o].length === 0 || entry.options.indexOf(entry.options[o]) !== o)
                    return at + ".options must hold distinct non-empty strings";
            }
        } else if (entry.options !== undefined) {
            return at + ".options needs type enum";
        }
        for (var n = 0; n < NUMBER_BOUND_KEYS.length; n++) {
            var bound = NUMBER_BOUND_KEYS[n];
            if (entry[bound] === undefined)
                continue;
            if (entry.type !== "number")
                return at + "." + bound + " needs type number";
            if (typeof entry[bound] !== "number" || !isFinite(entry[bound]))
                return at + "." + bound + " must be a finite number";
        }
        if (entry.min !== undefined && entry.max !== undefined && !(entry.min < entry.max))
            return at + ".min must be less than max";
        if (entry.step !== undefined && !(entry.step > 0))
            return at + ".step must be positive";
        if (entry.group !== undefined && (typeof entry.group !== "string" || entry.group.length === 0))
            return at + ".group must be a non-empty string when present";
        if (!hasOwn(settings, key))
            return at + " has no default in settings";
        var bad = settingError(entry, settings[key]);
        if (bad !== "")
            return "settings." + key + " does not fit its schema: " + bad;
    }
    return "";
}

// Whether `text` is one printable line of 1 to `max` characters: a string
// with no control character (C0, DEL, C1) and no line or paragraph
// separator, so a page draws it on one line and a log line holds it whole.
function isPrintableLine(text, max) {
    return typeof text === "string" && text.length > 0 && text.length <= max && !/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/.test(text);
}

// The first defect of a manifest's `status` key, or "". An object keyed by
// status key (STATUS_KEY_PATTERN), each entry naming a type from
// STATUS_TYPES and a printable `label`, with an optional printable `group`
// and `hint`, an optional printable `command` the Settings page shows as
// text and never runs, and an optional boolean `hidden`. A `data` entry is
// never drawn, so it carries none of `group`, `hint`, `command` or `hidden`.
// A plugin publishes status only through its `status` capability, so the
// key needs the capability, and the capability needs at least one entry.
function statusError(status, capabilities) {
    if (!isPlainObject(status))
        return "status must be an object";
    var keys = Object.keys(status);
    if (keys.length === 0)
        return "status must declare at least one entry";
    if (capabilities.indexOf("status") === -1)
        return "status needs capability status";
    for (var i = 0; i < keys.length; i++) {
        var key = keys[i];
        var entry = status[key];
        var at = "status." + key;
        if (!STATUS_KEY_PATTERN.test(key))
            return "status key " + JSON.stringify(key) + " must match " + STATUS_KEY_PATTERN.source;
        if (!isPlainObject(entry))
            return at + " must be an object";
        var entryKeys = Object.keys(entry);
        for (var u = 0; u < entryKeys.length; u++) {
            if (STATUS_ENTRY_KEYS.indexOf(entryKeys[u]) === -1)
                return at + " has unknown key " + JSON.stringify(entryKeys[u]);
        }
        if (STATUS_TYPES.indexOf(entry.type) === -1)
            return at + ".type must be one of " + STATUS_TYPES.join(", ") + ", got " + JSON.stringify(entry.type);
        if (!isPrintableLine(entry.label, STATUS_LABEL_MAX))
            return at + ".label must be a printable line of 1 to " + STATUS_LABEL_MAX + " characters";
        if (entry.group !== undefined && !isPrintableLine(entry.group, STATUS_LABEL_MAX))
            return at + ".group must be a printable line of 1 to " + STATUS_LABEL_MAX + " characters when present";
        if (entry.hint !== undefined && !isPrintableLine(entry.hint, STATUS_HINT_MAX))
            return at + ".hint must be a printable line of 1 to " + STATUS_HINT_MAX + " characters when present";
        if (entry.command !== undefined && !isPrintableLine(entry.command, STATUS_COMMAND_MAX))
            return at + ".command must be a printable line of 1 to " + STATUS_COMMAND_MAX + " characters when present";
        if (entry.hidden !== undefined && typeof entry.hidden !== "boolean")
            return at + ".hidden must be a boolean when present";
        if (entry.type === "data") {
            var drawn = ["group", "hint", "command", "hidden"];
            for (var d = 0; d < drawn.length; d++) {
                if (entry[drawn[d]] !== undefined)
                    return at + "." + drawn[d] + " needs a type Settings draws; data is never drawn";
            }
        }
    }
    return "";
}

// Whether `value` is plain JSON: null, a boolean, a finite number, a string,
// an array of plain JSON, or an object whose prototype is Object's or none
// holding plain JSON. Anything JSON.stringify would drop, change or refuse,
// such as a function, a Date or a QML object, is not.
function isPlainJson(value) {
    if (value === null || typeof value === "boolean" || typeof value === "string")
        return true;
    if (typeof value === "number")
        return isFinite(value);
    if (Array.isArray(value)) {
        for (var i = 0; i < value.length; i++)
            if (!isPlainJson(value[i])) return false;
        return true;
    }
    if (typeof value !== "object")
        return false;
    // A plain object's prototype is Object.prototype of whichever realm made
    // it, whose own prototype is null, or it has none.
    var proto = Object.getPrototypeOf(value);
    if (Object.prototype.toString.call(value) !== "[object Object]" || (proto !== null && Object.getPrototypeOf(proto) !== null))
        return false;
    var keys = Object.keys(value);
    for (var k = 0; k < keys.length; k++)
        if (!isPlainJson(value[keys[k]])) return false;
    return true;
}

// Whether `value` fits a status entry of type `type`: `presence` a key of
// STATUS_PRESENCE_TONES; `state` { tone, text } with a tone of
// STATUS_STATE_TONES and a printable text; `text` a printable line; `count`
// a whole number from 0; `time` a whole number of milliseconds since the
// Unix epoch, from 0; `data` plain JSON.
function statusValueFits(type, value) {
    if (type === "presence") return typeof value === "string" && hasOwn(STATUS_PRESENCE_TONES, value);
    if (type === "state") {
        if (!isPlainObject(value) || !isPlainJson(value)) return false;
        var keys = Object.keys(value);
        for (var i = 0; i < keys.length; i++)
            if (STATUS_STATE_KEYS.indexOf(keys[i]) === -1) return false;
        return typeof value.tone === "string" && hasOwn(STATUS_STATE_TONES, value.tone) && isPrintableLine(value.text, STATUS_TEXT_MAX);
    }
    if (type === "text") return isPrintableLine(value, STATUS_TEXT_MAX);
    if (type === "count" || type === "time") return typeof value === "number" && isFinite(value) && value >= 0 && Math.floor(value) === value && value <= Number.MAX_SAFE_INTEGER;
    if (type === "data") return isPlainJson(value);
    throw new Error("statusValueFits: status type " + JSON.stringify(type) + " passed validation but has no rule");
}

// The number of UTF-8 bytes that encode `text`. A lone surrogate counts as
// the three bytes of its replacement character.
function utf8Bytes(text) {
    var bytes = 0;
    for (var i = 0; i < text.length; i++) {
        var code = text.charCodeAt(i);
        if (code < 0x80) bytes += 1;
        else if (code < 0x800) bytes += 2;
        else if (code >= 0xd800 && code <= 0xdbff && i + 1 < text.length && text.charCodeAt(i + 1) >= 0xdc00 && text.charCodeAt(i + 1) <= 0xdfff) {
            bytes += 4;
            i += 1;
        } else bytes += 3;
    }
    return bytes;
}

// A deep-frozen copy of plain JSON, so the writer cannot reach a published
// value. The QML engine lets a frozen array be written in place
// (docs/architecture/runtime-qml.md), so PluginStatus hands each reader a
// copy of its own.
function frozenJson(value) {
    var copy = JSON.parse(JSON.stringify(value));
    var freeze = function (node) {
        if (node === null || typeof node !== "object") return node;
        var keys = Object.keys(node);
        for (var i = 0; i < keys.length; i++) freeze(node[keys[i]]);
        return Object.freeze(node);
    };
    return freeze(copy);
}

// The one keyed line a refused status write answers:
// `refused: status=<key> reason=<reason>`, a key STATUS_KEY_PATTERN does not
// admit written as JSON so the line stays one line.
function statusRefusal(key, reason) {
    var named = typeof key === "string" && STATUS_KEY_PATTERN.test(key) ? key : JSON.stringify(String(key));
    return "refused: status=" + named + " reason=" + reason;
}

// One status write by a plugin whose validated manifest is `manifest` and
// whose published values are `values`: { ok: true, values, bytes } with
// the new deep-frozen values and their size, or { ok: false, error } with
// the one keyed line `refused: status=<key> reason=<reason>`, the reason
// `undeclared` (the manifest's `status` has no such key), `type` (the value
// does not fit the entry's type) or `size` (the values would pass
// STATUS_MAX_BYTES). A refused write leaves `values` as they were.
function statusWrite(manifest, values, key, value) {
    var refused = function (reason) { return { ok: false, error: statusRefusal(key, reason) }; };
    if (typeof key !== "string" || !hasOwn(manifest.status, key))
        return refused("undeclared");
    if (!statusValueFits(manifest.status[key].type, value))
        return refused("type");
    var next = {};
    var keys = Object.keys(values);
    for (var i = 0; i < keys.length; i++) next[keys[i]] = values[keys[i]];
    next[key] = value;
    var bytes = utf8Bytes(JSON.stringify(next));
    if (bytes > STATUS_MAX_BYTES)
        return refused("size");
    return { ok: true, values: frozenJson(next), bytes: bytes };
}

// Whether the Settings window draws status entry `entry`: every type but
// `data`, unless the entry is `hidden`.
function statusDisplayable(entry) {
    return entry.type !== "data" && entry.hidden !== true;
}

// The badge tone Settings draws a reported status value with: the
// presence's or the state's tone, "" for a type drawn as text.
function statusTone(type, value) {
    if (type === "presence") return STATUS_PRESENCE_TONES[value];
    if (type === "state") return STATUS_STATE_TONES[value.tone];
    return "";
}

// The Status rows the plugin manager shows for a plugin: one per entry
// statusDisplayable admits, in manifest key order, as { key, type, label,
// group, hint, command, report, value, tone }. `group`, `hint` and
// `command` are "" when the manifest omits them. `report` is `reported`
// with the published `value` and its `tone`, or `unreported` with `value`
// null and `tone` "" while `values` holds nothing for the key.
function statusRows(manifest, values) {
    return Object.keys(manifest.status).filter(function (key) {
        return statusDisplayable(manifest.status[key]);
    }).map(function (key) {
        var entry = manifest.status[key];
        var reported = hasOwn(values, key);
        return {
            key: key,
            type: entry.type,
            label: entry.label,
            group: entry.group === undefined ? "" : entry.group,
            hint: entry.hint === undefined ? "" : entry.hint,
            command: entry.command === undefined ? "" : entry.command,
            report: reported ? "reported" : "unreported",
            value: reported ? values[key] : null,
            tone: reported ? statusTone(entry.type, values[key]) : ""
        };
    });
}

// A Hyprland key written `MOD+MOD+KEY`, such as `SUPER+SPACE`, normalised:
// { ok: true, key } with every part upper case, the modifiers in
// HYPRLAND_MODIFIERS order, each once, and the key name last, joined by
// `+`; or { ok: false, error }. A manifest's bind and a shell.json `keys`
// entry both pass through here, so two spellings of one key compare equal.
function hyprlandKey(text) {
    if (typeof text !== "string")
        return { ok: false, error: "must be a string such as SUPER+SPACE" };
    var parts = text.split("+").map(function (part) { return part.trim().toUpperCase(); });
    if (parts.some(function (part) { return part.length === 0; }))
        return { ok: false, error: "has an empty part: " + JSON.stringify(text) };
    var name = parts[parts.length - 1];
    if (HYPRLAND_MODIFIERS.indexOf(name) !== -1)
        return { ok: false, error: "ends in the modifier " + name + " and names no key" };
    if (!HYPRLAND_KEY_NAME.test(name))
        return { ok: false, error: "names no key: " + JSON.stringify(name) };
    var mods = parts.slice(0, -1);
    for (var i = 0; i < mods.length; i++) {
        if (HYPRLAND_MODIFIERS.indexOf(mods[i]) === -1)
            return { ok: false, error: "has the unknown modifier " + JSON.stringify(mods[i]) + ", want one of " + HYPRLAND_MODIFIERS.join(", ") };
        if (mods.indexOf(mods[i]) !== i)
            return { ok: false, error: "repeats the modifier " + mods[i] };
    }
    var ordered = HYPRLAND_MODIFIERS.filter(function (mod) { return mods.indexOf(mod) !== -1; });
    return { ok: true, key: ordered.concat([name]).join("+") };
}

// The first defect of a plugins row's `keys`, or "": an object whose names
// are shortcut names and whose values are keys hyprlandKey accepts, or null
// for a shortcut the user unbinds. A name the plugin binds nothing under is
// no defect here; the Hyprland layer reports it (hyprlandSection).
function keysError(keys, at) {
    if (!isPlainObject(keys))
        return at + " must be an object";
    var names = Object.keys(keys);
    for (var i = 0; i < names.length; i++) {
        if (!NAME_PATTERN.test(names[i]))
            return at + "." + names[i] + " is not a shortcut name";
        if (keys[names[i]] === null)
            continue;
        var key = hyprlandKey(keys[names[i]]);
        if (!key.ok)
            return at + "." + names[i] + " " + key.error;
    }
    return "";
}

// The first defect of a manifest's `hyprland` key, or "". It holds `binds`,
// a list of { shortcut, key }, and `layerRules`, a list of { namespace,
// blur, ignoreAlpha }, at least one of them non-empty. A bind's shortcut is
// a name the plugin registers through its `shortcut` capability, which the
// manifest must name, so a plugin binds only its own shortcuts. A rule
// matches `^vgs:<name>$` and sets blur, ignoreAlpha from 0 to 1, or both.
// Neither a shortcut, a key nor a namespace appears twice.
function hyprlandError(hyprland, capabilities) {
    if (!isPlainObject(hyprland))
        return "hyprland must be an object";
    var keys = Object.keys(hyprland);
    for (var u = 0; u < keys.length; u++) {
        if (HYPRLAND_KEYS.indexOf(keys[u]) === -1)
            return "hyprland has unknown key " + JSON.stringify(keys[u]);
    }
    var binds = hyprland.binds === undefined ? [] : hyprland.binds;
    var rules = hyprland.layerRules === undefined ? [] : hyprland.layerRules;
    if (!Array.isArray(binds))
        return "hyprland.binds must be a list";
    if (!Array.isArray(rules))
        return "hyprland.layerRules must be a list";
    if (binds.length === 0 && rules.length === 0)
        return "hyprland declares no binds and no layer rules";
    if (binds.length > 0 && capabilities.indexOf("shortcut") === -1)
        return "hyprland.binds needs capability shortcut";
    var shortcuts = [];
    var boundKeys = [];
    for (var b = 0; b < binds.length; b++) {
        var bind = binds[b];
        var at = "hyprland.binds." + b;
        if (!isPlainObject(bind))
            return at + " must be an object";
        var bindKeys = Object.keys(bind);
        for (var k = 0; k < bindKeys.length; k++) {
            if (HYPRLAND_BIND_KEYS.indexOf(bindKeys[k]) === -1)
                return at + " has unknown key " + JSON.stringify(bindKeys[k]);
        }
        if (typeof bind.shortcut !== "string" || !NAME_PATTERN.test(bind.shortcut))
            return at + ".shortcut must be a shortcut name, got " + JSON.stringify(bind.shortcut);
        if (shortcuts.indexOf(bind.shortcut) !== -1)
            return at + ".shortcut " + bind.shortcut + " is bound twice";
        shortcuts.push(bind.shortcut);
        var key = hyprlandKey(bind.key);
        if (!key.ok)
            return at + ".key " + key.error;
        if (boundKeys.indexOf(key.key) !== -1)
            return at + ".key " + key.key + " is bound twice";
        boundKeys.push(key.key);
    }
    var namespaces = [];
    for (var r = 0; r < rules.length; r++) {
        var rule = rules[r];
        var where = "hyprland.layerRules." + r;
        if (!isPlainObject(rule))
            return where + " must be an object";
        var ruleKeys = Object.keys(rule);
        for (var q = 0; q < ruleKeys.length; q++) {
            if (HYPRLAND_RULE_KEYS.indexOf(ruleKeys[q]) === -1)
                return where + " has unknown key " + JSON.stringify(ruleKeys[q]);
        }
        if (typeof rule.namespace !== "string" || !HYPRLAND_NAMESPACE.test(rule.namespace))
            return where + ".namespace must be ^vgs:<name>$, got " + JSON.stringify(rule.namespace);
        if (namespaces.indexOf(rule.namespace) !== -1)
            return where + ".namespace " + rule.namespace + " has a rule already";
        namespaces.push(rule.namespace);
        if (rule.blur === undefined && rule.ignoreAlpha === undefined)
            return where + " sets neither blur nor ignoreAlpha";
        if (rule.blur !== undefined && typeof rule.blur !== "boolean")
            return where + ".blur must be a boolean";
        if (rule.ignoreAlpha !== undefined && (typeof rule.ignoreAlpha !== "number" || !isFinite(rule.ignoreAlpha) || rule.ignoreAlpha < 0 || rule.ignoreAlpha > 1))
            return where + ".ignoreAlpha must be a number from 0 to 1";
    }
    return "";
}

// The first defect of a `requirements` list, or "": a manifest's key and
// the core's own config/requirements.json both pass through here. Each
// entry is an object of REQUIREMENT_KEYS: `command`, a bare command name
// PackageManagers.validCommand accepts, declared once, and never a plugin
// id, since a plugin names no other plugin (D005); `packages`, when
// present, an object whose keys are manager ids of PackageManagers.MANAGERS
// and whose values are package names PackageManagers.validName accepts;
// `optional`, when present, a boolean; `purpose`, one printable line of 1
// to REQUIREMENT_PURPOSE_MAX characters. A lower-case dotted command such as
// `acme.clock` has a plugin id's spelling and is refused whichever it names.
function requirementsError(requirements) {
    if (!Array.isArray(requirements))
        return "requirements must be a list";
    var commands = [];
    for (var i = 0; i < requirements.length; i++) {
        var requirement = requirements[i];
        var at = "requirements." + i;
        if (!isPlainObject(requirement))
            return at + " must be an object";
        var keys = Object.keys(requirement);
        for (var k = 0; k < keys.length; k++) {
            if (REQUIREMENT_KEYS.indexOf(keys[k]) === -1)
                return at + " has unknown key " + JSON.stringify(keys[k]);
        }
        if (!PackageManagers.validCommand(requirement.command))
            return at + ".command must be a bare command name looked up on PATH, got " + JSON.stringify(requirement.command);
        if (ID_PATTERN.test(requirement.command))
            return at + ".command " + JSON.stringify(requirement.command) + " is spelt as a plugin id: a requirement names a command, never a plugin (D005)";
        if (commands.indexOf(requirement.command) !== -1)
            return at + ".command " + JSON.stringify(requirement.command) + " is declared twice";
        commands.push(requirement.command);
        if (requirement.packages !== undefined) {
            if (!isPlainObject(requirement.packages))
                return at + ".packages must be an object of manager ids to package names";
            var managers = Object.keys(requirement.packages);
            for (var m = 0; m < managers.length; m++) {
                if (PackageManagers.managerRow(managers[m]) === null)
                    return at + ".packages names the unknown manager " + JSON.stringify(managers[m]) + ", want one of " + PackageManagers.MANAGERS.map(function (row) { return row.id; }).join(", ");
                if (!PackageManagers.validName(requirement.packages[managers[m]]))
                    return at + ".packages." + managers[m] + " must be a package name: printable ASCII without a space, not starting with -, got " + JSON.stringify(requirement.packages[managers[m]]);
            }
        }
        if (requirement.optional !== undefined && typeof requirement.optional !== "boolean")
            return at + ".optional must be a boolean when present";
        if (typeof requirement.purpose !== "string" || requirement.purpose.trim().length === 0 || Array.from(requirement.purpose).length > REQUIREMENT_PURPOSE_MAX || CONTROL_CHARACTER.test(requirement.purpose))
            return at + ".purpose must be one printable line of 1 to " + REQUIREMENT_PURPOSE_MAX + " characters";
    }
    return "";
}

// A `requirements` list requirementsError accepted, each entry with every
// key: `packages` {} and `optional` false when absent.
function normalRequirements(requirements) {
    return requirements.map(function (entry) {
        return { command: entry.command, packages: entry.packages === undefined ? {} : clone(entry.packages), optional: entry.optional === true, purpose: entry.purpose };
    });
}

// The rows a plugin's requirements are reported as: each normalized entry
// of MANIFEST's `requirements`, in order, with `state` from
// REQUIREMENT_STATES: "missing" when MISSING, the commands the last scan
// did not find on PATH, names its command, else "present".
function requirementRows(manifest, missing) {
    return manifest.requirements.map(function (entry) {
        var row = clone(entry);
        row.state = missing.indexOf(entry.command) === -1 ? "present" : "missing";
        return row;
    });
}

// The requirement notice, shell/Core/Notices.qml
// (requirement-notice.md). At most NOTICE_QUEUE_MAX plugins hold a notice at once, the
// first shown and the rest waiting. After the user answers a plugin's
// notice Not now, the plugin's own offers are refused for
// NOTICE_OFFER_REST_MS; the install and enable triggers are the user's own
// acts, which no rest refuses. An offer names 1 to NOTICE_OFFER_MAX
// commands. Core policy, like the toast stack's ceilings.
var NOTICE_QUEUE_MAX = 8;
var NOTICE_OFFER_REST_MS = 600000;
var NOTICE_OFFER_MAX = 16;
// What raises a notice: `installed`, the pluginInstalled IPC function
// `vgsh plugin add` calls; `enabled`, setPluginEnabled turning a plugin on;
// `offered`, the plugin's own `requirements` capability.
var NOTICE_TRIGGERS = ["installed", "enabled", "offered"];

// The notice TRIGGER asks for plugin MANIFEST, whose commands MISSING the
// last scan did not find: { answer, commands, required }, `commands` the
// commands the notice lists and `required` those whose absence keeps it
// open. `answer` is "ok", "satisfied" when `required` is empty and no
// notice is due, or a refusal. The install and enable triggers list every
// missing command and require those the plugin does not mark optional, so
// a plugin missing only optional commands raises none. An offer lists and
// requires each of COMMANDS still missing, and is refused as
// `refused: requirements=malformed` for anything but a list of 1 to
// NOTICE_OFFER_MAX strings, then as `refused: requirement=<command>
// reason=undeclared` for the first command MANIFEST does not declare, so a
// plugin never raises a notice for a package it did not declare.
function noticeRequest(manifest, missing, trigger, commands) {
    var rows = requirementRows(manifest, missing);
    var listed;
    var required;
    switch (trigger) {
    case "installed":
    case "enabled":
        listed = rows.filter(function (row) { return row.state === "missing"; });
        required = listed.filter(function (row) { return !row.optional; });
        break;
    case "offered":
        if (!Array.isArray(commands) || commands.length === 0 || commands.length > NOTICE_OFFER_MAX || !commands.every(function (c) { return typeof c === "string"; }))
            return { answer: "refused: requirements=malformed", commands: [], required: [] };
        var declared = rows.map(function (row) { return row.command; });
        var undeclared = commands.filter(function (c) { return declared.indexOf(c) === -1; });
        if (undeclared.length > 0)
            return { answer: "refused: requirement=" + tuiLabel(undeclared[0]) + " reason=undeclared", commands: [], required: [] };
        listed = rows.filter(function (row) { return row.state === "missing" && commands.indexOf(row.command) !== -1; });
        required = listed;
        break;
    default:
        throw new Error("notices: trigger " + JSON.stringify(trigger) + " is not one of " + NOTICE_TRIGGERS.join(", "));
    }
    var commandOf = function (row) { return row.command; };
    return { answer: required.length === 0 ? "satisfied" : "ok", commands: listed.map(commandOf), required: required.map(commandOf) };
}

// QUEUE, the notices held, each { id, commands, required }, the first
// shown, after REQUEST, an "ok" noticeRequest for plugin ID raised by
// TRIGGER at NOW, in ms since the epoch: { answer, queue }. A plugin
// holding a notice gets REQUEST's commands merged into it, after those it
// holds, and answers "ok" whatever the trigger, since the user sees one
// notice either way. Otherwise an offer while REST, plugin id -> the end
// of its rest in ms, holds a later end for ID is refused as
// `refused: requirements=<id> reason=resting retry-ms=<ms>`; a queue
// holding NOTICE_QUEUE_MAX notices refuses as
// `refused: notices=full limit=<n>`; and any other request joins the end
// of the queue.
function noticeAdmit(queue, rest, id, request, trigger, now) {
    if (NOTICE_TRIGGERS.indexOf(trigger) === -1)
        throw new Error("notices: trigger " + JSON.stringify(trigger) + " is not one of " + NOTICE_TRIGGERS.join(", "));
    var union = function (held, added) { return held.concat(added.filter(function (c) { return held.indexOf(c) === -1; })); };
    var at = -1;
    for (var i = 0; i < queue.length; i++)
        if (queue[i].id === id) at = i;
    if (at !== -1) {
        var merged = queue.slice();
        merged[at] = { id: id, commands: union(queue[at].commands, request.commands), required: union(queue[at].required, request.required) };
        return { answer: "ok", queue: merged };
    }
    if (trigger === "offered" && hasOwn(rest, id) && rest[id] > now)
        return { answer: "refused: requirements=" + id + " reason=resting retry-ms=" + (rest[id] - now), queue: queue };
    if (queue.length >= NOTICE_QUEUE_MAX)
        return { answer: "refused: notices=full limit=" + NOTICE_QUEUE_MAX, queue: queue };
    return { answer: "ok", queue: queue.concat([{ id: id, commands: request.commands.slice(), required: request.required.slice() }]) };
}

// What NOTICE, { commands, required }, shows for plugin MANIFEST after the
// last scan, whose missing commands are MISSING, on a system whose managers
// are FOUND, detect's answer, or null when detection has no answer:
// { satisfied, rows, install, byHand }. `satisfied` holds once no command
// of `required` is missing. `rows` are the listed commands still missing,
// in declaration order, each { command, purpose, optional, package }, the
// package PackageManagers.installGroups picks, null with FOUND null or when
// no present manager maps one. `install` is the arguments after
// `vgsh pkg run install` of the first group whose manager installs, null
// when none does; one Install runs one manager's packages, and the notice
// offers the next group once a rescan finds the first installed. `byHand`
// is each group whose manager installs nothing through vgsh, nix, as
// { manager, names }.
function noticeView(manifest, missing, notice, found) {
    var rows = requirementRows(manifest, missing).filter(function (row) { return row.state === "missing" && notice.commands.indexOf(row.command) !== -1; });
    var satisfied = !notice.required.some(function (c) { return missing.indexOf(c) !== -1; });
    var plan = found === null ? { picks: rows.map(function () { return null; }), groups: [] } : PackageManagers.installGroups(rows, found);
    var installable = plan.groups.filter(function (g) { return g.installs; });
    return {
        satisfied: satisfied,
        rows: rows.map(function (row, i) { return { command: row.command, purpose: row.purpose, optional: row.optional, package: plan.picks[i] }; }),
        install: installable.length === 0 ? null : PackageManagers.installArgs(installable[0]),
        byHand: plan.groups.filter(function (g) { return !g.installs; }).map(function (g) { return { manager: g.manager, names: g.names }; })
    };
}

// QUEUE after a scan, the notices of MANIFESTS' plugins whose missing
// commands MISSING, plugin id -> commands, now holds: a notice whose plugin
// went is dropped, and so is one noticeView finds satisfied, except the
// notice of INSTALLING, the plugin id whose install runs or "". That notice
// stays until the scan after its run ended, however the run's own steps
// asked for a rescan first, so no waiting notice comes to the front while
// its terminal still holds the install's key.
function noticeSettle(queue, manifests, missing, installing) {
    return queue.filter(function (n) {
        if (!hasOwn(manifests, n.id))
            return false;
        if (n.id === installing)
            return true;
        return !noticeView(manifests[n.id], hasOwn(missing, n.id) ? missing[n.id] : [], n, null).satisfied;
    });
}

// The managers `bin/vgsh-pkg detect --json` answered the notice with, from
// its COMPLETION, { code, status } or null for a run that never started,
// its STDOUT and its STDERR: { ok: true, found }, detect's { primary,
// overlays, sources } with each entry a known manager, or { ok: false,
// line }, the log line naming why there is none.
function noticeDetected(completion, stdout, stderr) {
    if (completion === null)
        return { ok: false, line: "notices: detect=unstarted" };
    if (completion.status !== 0 || completion.code !== 0)
        return { ok: false, line: "notices: detect=failed exit=" + completion.code + " status=" + completion.status + " " + stderr.split("\n")[0] };
    var found;
    try {
        found = JSON.parse(stdout);
    } catch (e) {
        return { ok: false, line: "notices: detect=unparseable" };
    }
    var entry = function (e) { return isPlainObject(e) && typeof e.id === "string" && PackageManagers.managerRow(e.id) !== null && typeof e.binary === "string"; };
    if (!isPlainObject(found) || !(found.primary === null || entry(found.primary)) || !Array.isArray(found.overlays) || !found.overlays.every(entry) || !Array.isArray(found.sources) || !found.sources.every(entry))
        return { ok: false, line: "notices: detect=malformed" };
    return { ok: true, found: found };
}

// What one entry of a manifest's `tui` key may carry, keyed by a
// NAME_PATTERN name: the script, the window's title, its size class and
// presentation, and, when present, the row shell.tui.entries lists it with.
// `script` is a path under the plugin's `tui/` directory, the one
// bin/vgsh-tui copies out of the published snapshot and runs from; each
// segment starts with a letter, a digit or `_`, so none is `.`, `..` or
// hidden. The sizes are the size classes of HyprlandLayer.TUI_WINDOWS, the
// table the layer's window rules and the launcher's app-ids come from, and
// the presentations are bin/vgsh-tui's. A title, a label and a group are one
// printable line of at most TUI_TEXT_MAX characters.
var TUI_KEYS = ["script", "title", "size", "presentation", "entry"];
var TUI_ENTRY_KEYS = ["label", "icon", "group"];
var TUI_SIZES = Object.keys(HyprlandLayer.TUI_WINDOWS);
var TUI_PRESENTATIONS = ["full", "plain"];
var TUI_TEXT_MAX = 60;
var TUI_SCRIPT = /^tui(\/[A-Za-z0-9_][A-Za-z0-9._-]*)+$/;
// The arguments shell.tui.run hands a plugin's script: at most TUI_ARGS_MAX
// strings, each 1 to TUI_ARG_MAX characters with no control character.
var TUI_ARGS_MAX = 16;
var TUI_ARG_MAX = 256;
// The exit status bin/vgsh-tui launch and check give when xdg-terminal-exec
// is not on PATH, their `terminal=missing` refusal.
var TUI_LAUNCHER_MISSING = 69;
// What the core knows of the terminal launcher: `unknown` until a probe or a
// launch answers, `present` once one exited 0, `missing` once one exited
// TUI_LAUNCHER_MISSING. tuiLauncherAfter moves it.
var TUI_LAUNCHER_STATES = ["unknown", "present", "missing"];
// What a row of the core's own TUI table holds, and the command its argv
// starts with: a file of the core's own bin/ directory, which tuiOpen
// resolves under the directory the shell hands it, since the shell's PATH
// need not hold the core's commands.
var CORE_TUI_KEYS = ["argv", "title", "size", "presentation", "entry"];
var CORE_TUI_COMMAND = /^vgsh(-[a-z]+)*$/;
// What a refused request asks the runner to do next: nothing, one probe of
// the launcher, or focus the window of the key's live run.
var TUI_ACTIONS = ["none", "probe", "focus"];
// The states of an exit record bin/vgsh-tui writes: `running` from the
// presenter's start, `ended` once it exited or `vgsh-tui reap` found it
// gone.
var TUI_RECORD_STATES = ["running", "ended"];
// A run id the core hands bin/vgsh-tui with --run, and the key a record
// carries: `core/<name>` or `<plugin id>/<name>`.
var TUI_RUN_PATTERN = /^[a-z0-9][a-z0-9-]*$/;
// The core's own floating TUIs, by name, listed in shell.tui.entries as
// `core/<name>` and opened by that key: each { argv, title, size,
// presentation, entry }, `argv` the core command the terminal runs and the
// rest as a normalized manifest `tui` entry has them. coreTuiTable judges
// the table when this file loads. The package pickers run in the default
// size, the window Omarchy's floating terminal gives omarchy-pkg-install.
// `requirements-install` is not listed: the requirement notice opens it
// through tuiCore with the arguments PluginLogic.noticeView names.
var CORE_TUIS = coreTuiTable({
    "pkg-install": {
        argv: ["vgsh", "pkg", "install"],
        title: "Install packages",
        size: "default",
        presentation: "full",
        entry: { label: "Install packages", icon: "package-plus", group: "Packages" }
    },
    "pkg-remove": {
        argv: ["vgsh", "pkg", "remove"],
        title: "Remove packages",
        size: "default",
        presentation: "full",
        entry: { label: "Remove packages", icon: "package-minus", group: "Packages" }
    },
    "sudo-grant": {
        argv: ["vgsh", "sudo", "grant"],
        title: "Passwordless sudo",
        size: "default",
        presentation: "full",
        entry: { label: "Passwordless sudo", icon: "shield-alert", group: "System" }
    },
    "requirements-install": {
        argv: ["vgsh", "pkg", "run", "install"],
        title: "Install requirements",
        size: "default",
        presentation: "full",
        entry: null
    }
});

// One printable line of 1 to TUI_TEXT_MAX characters.
function tuiText(value) {
    return typeof value === "string" && value.trim().length > 0 && Array.from(value).length <= TUI_TEXT_MAX && !CONTROL_CHARACTER.test(value);
}

// The first defect of a manifest's `tui` key, or "": an object of at least
// one script, each named by NAME_PATTERN and holding only TUI_KEYS; `script`
// matches TUI_SCRIPT; `title` passes tuiText; `size` and `presentation`,
// when present, come from TUI_SIZES and TUI_PRESENTATIONS; `entry`, when
// present, holds a tuiText `label` and `group` and an `icon` of the shipped
// set. The plugin opens its scripts through capability `tui`, which the
// manifest must name. Whether the script is a regular executable file, and
// no link, is bin/lib/check-manifests.js's to read on disk.
function tuiError(tui, capabilities) {
    if (!isPlainObject(tui))
        return "tui must be an object of script names to scripts";
    var names = Object.keys(tui);
    if (names.length === 0)
        return "tui must declare at least one script";
    if (capabilities.indexOf("tui") === -1)
        return "tui needs capability tui";
    for (var i = 0; i < names.length; i++) {
        var name = names[i];
        var at = "tui." + name;
        if (!NAME_PATTERN.test(name))
            return "tui name " + JSON.stringify(name) + " must be lower case letters, digits and dashes";
        var row = tui[name];
        if (!isPlainObject(row))
            return at + " must be an object";
        var keys = Object.keys(row);
        for (var k = 0; k < keys.length; k++) {
            if (TUI_KEYS.indexOf(keys[k]) === -1)
                return at + " has unknown key " + JSON.stringify(keys[k]);
        }
        if (typeof row.script !== "string" || !TUI_SCRIPT.test(row.script))
            return at + ".script must be a relative path under tui/ inside the plugin, got " + JSON.stringify(row.script);
        var windowError = tuiWindowError(at, row);
        if (windowError !== "")
            return windowError;
        if (row.entry === undefined)
            continue;
        var entryError = tuiEntryError(at, row.entry);
        if (entryError !== "")
            return entryError;
    }
    return "";
}

// The first defect of the window a TUI row at AT opens, or "": `title`
// passes tuiText, and `size` and `presentation`, when present, come from
// TUI_SIZES and TUI_PRESENTATIONS.
function tuiWindowError(at, row) {
    if (!tuiText(row.title))
        return at + ".title must be one printable line of 1 to " + TUI_TEXT_MAX + " characters";
    if (row.size !== undefined && TUI_SIZES.indexOf(row.size) === -1)
        return at + ".size must be one of " + TUI_SIZES.join(", ") + ", got " + JSON.stringify(row.size);
    if (row.presentation !== undefined && TUI_PRESENTATIONS.indexOf(row.presentation) === -1)
        return at + ".presentation must be one of " + TUI_PRESENTATIONS.join(", ") + ", got " + JSON.stringify(row.presentation);
    return "";
}

// The first defect of the `entry` of a TUI row at AT, or "": an object of
// TUI_ENTRY_KEYS holding a tuiText `label` and `group` and an `icon` of the
// shipped set.
function tuiEntryError(at, entry) {
    if (!isPlainObject(entry))
        return at + ".entry must be an object";
    var entryKeys = Object.keys(entry);
    for (var e = 0; e < entryKeys.length; e++) {
        if (TUI_ENTRY_KEYS.indexOf(entryKeys[e]) === -1)
            return at + ".entry has unknown key " + JSON.stringify(entryKeys[e]);
    }
    if (!tuiText(entry.label))
        return at + ".entry.label must be one printable line of 1 to " + TUI_TEXT_MAX + " characters";
    if (typeof entry.icon !== "string" || !hasOwn(Lucide.ICONS, entry.icon))
        return at + ".entry.icon must name an icon of the shipped set, shell/Ui/icons/Lucide.js, got " + JSON.stringify(entry.icon);
    if (!tuiText(entry.group))
        return at + ".entry.group must be one printable line of 1 to " + TUI_TEXT_MAX + " characters";
    return "";
}

// The first defect of the core's own TUI NAME, ROW, or "": NAME matches
// NAME_PATTERN; ROW holds every key of CORE_TUI_KEYS and no other; `argv`
// is a CORE_TUI_COMMAND followed by arguments tuiArgsValid accepts; the
// window passes tuiWindowError with a `size` and `presentation` set; and
// `entry` is null or passes tuiEntryError.
function coreTuiError(name, row) {
    var at = "core/" + name;
    if (!NAME_PATTERN.test(name))
        return "core TUI name " + JSON.stringify(name) + " must be lower case letters, digits and dashes";
    if (!isPlainObject(row))
        return at + " must be an object";
    var keys = Object.keys(row);
    for (var k = 0; k < keys.length; k++) {
        if (CORE_TUI_KEYS.indexOf(keys[k]) === -1)
            return at + " has unknown key " + JSON.stringify(keys[k]);
    }
    for (var m = 0; m < CORE_TUI_KEYS.length; m++) {
        if (row[CORE_TUI_KEYS[m]] === undefined)
            return at + " needs key " + CORE_TUI_KEYS[m];
    }
    if (!Array.isArray(row.argv) || typeof row.argv[0] !== "string" || !CORE_TUI_COMMAND.test(row.argv[0]))
        return at + ".argv must start with a command of the core's bin/ directory, got " + JSON.stringify(row.argv);
    if (!tuiArgsValid(row.argv.slice(1)))
        return at + ".argv takes at most " + TUI_ARGS_MAX + " arguments of 1 to " + TUI_ARG_MAX + " characters with no control character";
    var windowError = tuiWindowError(at, row);
    if (windowError !== "")
        return windowError;
    return row.entry === null ? "" : tuiEntryError(at, row.entry);
}

// TABLE once every row passes coreTuiError. The table is the core's own
// code, so a defect throws when this file loads.
function coreTuiTable(table) {
    Object.keys(table).forEach(function (name) {
        var error = coreTuiError(name, table[name]);
        if (error !== "")
            throw new Error("tui: " + error);
    });
    return table;
}

// A `tui` key tuiError accepted, each entry with every key: `size`
// "default" and `presentation` "full" when absent, `entry` null.
function normalTui(tui) {
    var out = {};
    Object.keys(tui).forEach(function (name) {
        var row = tui[name];
        out[name] = {
            script: row.script,
            title: row.title,
            size: row.size === undefined ? "default" : row.size,
            presentation: row.presentation === undefined ? "full" : row.presentation,
            entry: row.entry === undefined ? null : clone(row.entry)
        };
    });
    return out;
}

// The name a TUI answer carries: the caller's text when it is one visible
// word, otherwise its JSON, so a log line never holds a raw space, newline
// or control character.
function tuiLabel(name) {
    return typeof name === "string" && /^[\x21-\x7e]+$/.test(name) ? name : JSON.stringify(name);
}

// A refusal: ANSWER's text, and ACTION, one of TUI_ACTIONS, for KEY.
function tuiRefusal(name, reason) {
    return { ok: false, answer: "refused: tui=" + tuiLabel(name) + " reason=" + reason, action: "none", key: null };
}

// The refusal of a request the judge accepted, for launch KEY, from the
// runner's state RUNNER, { launcher, busy, run }, or null to start it.
// `reason=busy` while KEY is in `busy`, the keys whose launcher is still
// waiting for its presenter or whose record says running: it asks the
// runner to focus that run's window, so a second click raises the open
// TUI instead of starting another. Then `reason=launcher-missing` while
// `launcher`, one of TUI_LAUNCHER_STATES, is `missing`: it asks for one
// probe, so a terminal installed since the last one is found by a later
// request without a restart. Any other state starts the launch: an
// `unknown` launcher that finds no terminal is logged by tuiLaunchOutcome
// and moves the state.
function tuiRunnerRefusal(runner, name, key) {
    if (TUI_LAUNCHER_STATES.indexOf(runner.launcher) === -1)
        throw new Error("tui: launcher state " + JSON.stringify(runner.launcher) + " is not one of " + TUI_LAUNCHER_STATES.join(", "));
    var refusal;
    if (runner.busy.indexOf(key) !== -1) {
        refusal = tuiRefusal(name, "busy");
        refusal.action = "focus";
    } else if (runner.launcher === "missing") {
        refusal = tuiRefusal(name, "launcher-missing");
        refusal.action = "probe";
    } else {
        return null;
    }
    refusal.key = key;
    return refusal;
}

// Whether ARGS may follow a plugin's script: absent, or a list of at most
// TUI_ARGS_MAX strings, each 1 to TUI_ARG_MAX characters with no control
// character.
function tuiArgsValid(args) {
    if (args === undefined)
        return true;
    if (!Array.isArray(args) || args.length > TUI_ARGS_MAX)
        return false;
    return args.every(function (arg) {
        return typeof arg === "string" && arg.length > 0 && Array.from(arg).length <= TUI_ARG_MAX && !CONTROL_CHARACTER.test(arg);
    });
}

// The arguments after bin/vgsh-tui that open ROW, a normalized `tui` entry
// or a CORE_TUIS row, running COMMAND as launch KEY's run RUN, so the
// presenter writes the run's exit record; PLUGIN, { id, dir }, names the
// plugin and its published snapshot, null for a core TUI.
function tuiArgv(row, plugin, key, run, command) {
    var argv = ["launch", "--title", row.title, "--size", row.size, "--presentation", row.presentation];
    if (plugin !== null)
        argv.push("--plugin", plugin.id, "--dir", plugin.dir);
    argv.push("--record", key, "--run", run);
    return argv.concat(["--"], command);
}

// Plugin MANIFEST's own TUI NAME with ARGS, from its published snapshot
// under SOURCE_DIR (D014), from the runner's state RUNNER, { launcher, busy,
// run }, `run` the id the launch gets: { ok: true, key, run, argv }, `key`
// `<id>/<name>` and `argv` what follows bin/vgsh-tui, or { ok: false,
// answer, action, key } with answer `refused: tui=<name>` and, in this
// order, `reason=undeclared` for a name the manifest does not declare,
// `reason=disabled` while the plugin is not ENABLED, `reason=args` for
// arguments tuiArgsValid refuses, then `reason=busy` or
// `reason=launcher-missing` as tuiRunnerRefusal decides; `action` is
// `none` for the first three.
function tuiRun(manifest, enabled, sourceDir, runner, name, args) {
    if (typeof name !== "string" || !hasOwn(manifest.tui, name))
        return tuiRefusal(name, "undeclared");
    if (!enabled)
        return tuiRefusal(name, "disabled");
    if (!tuiArgsValid(args))
        return tuiRefusal(name, "args");
    var key = manifest.id + "/" + name;
    var refusal = tuiRunnerRefusal(runner, name, key);
    if (refusal !== null)
        return refusal;
    var row = manifest.tui[name];
    var plugin = { id: manifest.id, dir: sourceDir + "/" + manifest.__revision };
    return { ok: true, key: key, run: runner.run, argv: tuiArgv(row, plugin, key, runner.run, [row.script].concat(args === undefined ? [] : args)) };
}

// The core's own TUI NAME of CORE, the CORE_TUIS table, listed or not,
// with ARGS after its argv, its command resolved under CORE_BIN, the core's
// bin/ directory, for RUNNER: answers as tuiRun, keyed `core/<name>`, with
// `reason=undeclared` for a name CORE lacks, `reason=args` for arguments
// tuiArgsValid refuses, then `reason=busy` or `reason=launcher-missing` as
// tuiRunnerRefusal decides. The core alone calls it; tuiOpen opens a
// listed row with no arguments through it.
function tuiCore(core, coreBin, runner, name, args) {
    var key = "core/" + name;
    if (typeof name !== "string" || !hasOwn(core, name))
        return tuiRefusal(key, "undeclared");
    if (!tuiArgsValid(args))
        return tuiRefusal(key, "args");
    var refusal = tuiRunnerRefusal(runner, key, key);
    if (refusal !== null)
        return refusal;
    var row = core[name];
    return { ok: true, key: key, run: runner.run, argv: tuiArgv(row, null, key, runner.run, [coreBin + "/" + row.argv[0]].concat(row.argv.slice(1), args === undefined ? [] : args)) };
}

// The listed TUI KEY, with no arguments: `core/<name>` of a CORE row with
// an `entry`, through tuiCore, or `<plugin id>/<name>` of a script whose
// manifest in MANIFESTS gives it an `entry`, from the plugin's snapshot
// under SOURCE_DIR. Answers as tuiRun, with `reason=undeclared` for a key
// nothing lists, `reason=disabled` for a plugin not in ENABLED_IDS, then
// `reason=busy` or `reason=launcher-missing` as tuiRunnerRefusal decides
// for RUNNER.
function tuiOpen(manifests, enabledIds, sourceDir, coreBin, runner, core, key) {
    var slash = typeof key === "string" ? key.indexOf("/") : -1;
    if (slash === -1)
        return tuiRefusal(key, "undeclared");
    var owner = key.slice(0, slash);
    var name = key.slice(slash + 1);
    if (owner === "core") {
        if (!hasOwn(core, name) || core[name].entry === null)
            return tuiRefusal(key, "undeclared");
        return tuiCore(core, coreBin, runner, name, []);
    }
    if (!hasOwn(manifests, owner) || !hasOwn(manifests[owner].tui, name) || manifests[owner].tui[name].entry === null)
        return tuiRefusal(key, "undeclared");
    if (enabledIds.indexOf(owner) === -1)
        return tuiRefusal(key, "disabled");
    var pluginRefusal = tuiRunnerRefusal(runner, key, key);
    if (pluginRefusal !== null)
        return pluginRefusal;
    var launch = tuiRun(manifests[owner], true, sourceDir, runner, name, []);
    return { ok: true, key: key, run: launch.run, argv: launch.argv };
}

// Every listed TUI, sorted by key: each CORE row with an `entry` as
// `core/<name>`, then those of the plugins in ENABLED_IDS as
// `<plugin id>/<name>`, each { key, plugin, name, title, label, icon, group }
// with `plugin` "core" for the core's own.
function tuiEntries(manifests, enabledIds, core) {
    var rows = [];
    function add(owner, name, row) {
        if (row.entry === null)
            return;
        rows.push({ key: owner + "/" + name, plugin: owner, name: name, title: row.title, label: row.entry.label, icon: row.entry.icon, group: row.entry.group });
    }
    Object.keys(core).forEach(function (name) { add("core", name, core[name]); });
    enabledIds.forEach(function (id) {
        if (!hasOwn(manifests, id))
            return;
        Object.keys(manifests[id].tui).forEach(function (name) { add(id, name, manifests[id].tui[name]); });
    });
    return rows.sort(function (a, b) { return a.key < b.key ? -1 : a.key > b.key ? 1 : 0; });
}

// The launcher state after a probe or a launch that was started while the
// state was STATE ended with COMPLETION, { code, status } or null for one
// that never started: `present` on exit 0, `missing` on
// TUI_LAUNCHER_MISSING, STATE for any other end, which says nothing about the
// terminal.
function tuiLauncherAfter(state, completion) {
    if (completion === null || completion.status !== 0)
        return state;
    if (completion.code === 0)
        return "present";
    if (completion.code === TUI_LAUNCHER_MISSING)
        return "missing";
    return state;
}

// The log line for a probe, `bin/vgsh-tui check`, that ended with
// COMPLETION and STDERR, or "" for one that answered: exit 0 or
// TUI_LAUNCHER_MISSING, which tuiLauncherAfter records. Every other end is
// `tui: probe=failed exit=<code> status=<status>` with the first stderr
// line, or `tui: probe=unstarted`.
function tuiProbeOutcome(completion, stderr) {
    if (completion === null)
        return "tui: probe=unstarted";
    if (completion.status === 0 && (completion.code === 0 || completion.code === TUI_LAUNCHER_MISSING))
        return "";
    return "tui: probe=failed exit=" + completion.code + " status=" + completion.status + " " + String(stderr).split("\n")[0];
}

// The log line for a launcher of TUI KEY that ended with COMPLETION,
// { code, status } or null for one that never started, and STDERR, or ""
// for a launch that handed the terminal its command. The request answered
// `ok` before the launcher ran, so its refusal is logged here:
// `tui: refused: tui=<key> reason=launcher-missing` for xdg-terminal-exec
// missing, `tui: launcher=unstarted tui=<key>`, and
// `tui: launcher=failed tui=<key> exit=<code> status=<status>` with the
// launcher's first stderr line for every other end.
function tuiLaunchOutcome(key, completion, stderr) {
    if (completion === null)
        return "tui: launcher=unstarted tui=" + tuiLabel(key);
    if (completion.status === 0 && completion.code === 0)
        return "";
    if (completion.status === 0 && completion.code === TUI_LAUNCHER_MISSING)
        return "tui: refused: tui=" + tuiLabel(key) + " reason=launcher-missing";
    return "tui: launcher=failed tui=" + tuiLabel(key) + " exit=" + completion.code + " status=" + completion.status + " " + String(stderr).split("\n")[0];
}

// The log lines of a `bin/vgsh-tui reap` that ended with COMPLETION, STDOUT
// and STDERR, each { level: "info" | "error", text }: one info line
// `tui: reaped=<key> run=<run>` per record it ended, an error line for any
// other line it printed, and `tui: reap=failed exit=<code> status=<status>`
// with its first stderr line, or `tui: reap=unstarted`, for a reap that did
// not exit 0.
function tuiReapOutcome(completion, stdout, stderr) {
    var lines = [];
    String(stdout).split("\n").forEach(function (line) {
        if (line === "")
            return;
        if (/^reaped=[a-z0-9.-]+\/[a-z0-9-]+ run=[a-z0-9-]+$/.test(line))
            lines.push({ level: "info", text: "tui: " + line });
        else
            lines.push({ level: "error", text: "tui: reap=unparsed line=" + JSON.stringify(line) });
    });
    if (completion === null)
        lines.push({ level: "error", text: "tui: reap=unstarted" });
    else if (completion.status !== 0 || completion.code !== 0)
        lines.push({ level: "error", text: "tui: reap=failed exit=" + completion.code + " status=" + completion.status + " " + String(stderr).split("\n")[0] });
    return lines;
}

// What a launch's `done` receives when its launcher ended with COMPLETION,
// or null for a launcher that saw the run's record: its `done` waits for
// the ended record. `{ code: null, reason: "launcher-missing" }` when no
// terminal was found, `{ code: null, reason: "launcher-failed" }` for every
// other end, the silent terminal included.
function tuiLaunchDone(completion) {
    if (completion !== null && completion.status === 0 && completion.code === 0)
        return null;
    if (completion !== null && completion.status === 0 && completion.code === TUI_LAUNCHER_MISSING)
        return { code: null, reason: "launcher-missing" };
    return { code: null, reason: "launcher-failed" };
}

// Whether KEY is a launch key: `core/<name>` or `<plugin id>/<name>`.
function tuiKeyValid(key) {
    if (typeof key !== "string")
        return false;
    var slash = key.indexOf("/");
    if (slash === -1)
        return false;
    var owner = key.slice(0, slash);
    return (owner === "core" || ID_PATTERN.test(owner)) && NAME_PATTERN.test(key.slice(slash + 1));
}

// One exit record's TEXT, as bin/vgsh-tui writes it: { ok: true, record }
// or { ok: false, error } naming the first defect. A running record has a
// null code and endedAt; an ended one an integer code, or null when
// `vgsh-tui reap` wrote it, and an endedAt.
function tuiRecord(text) {
    var value;
    try {
        value = JSON.parse(text);
    } catch (e) {
        return { ok: false, error: "record is not JSON: " + e.message };
    }
    if (!isPlainObject(value))
        return { ok: false, error: "record is not an object" };
    if (!tuiKeyValid(value.key))
        return { ok: false, error: "record key " + JSON.stringify(value.key) + " is not a launch key" };
    if (typeof value.run !== "string" || !TUI_RUN_PATTERN.test(value.run))
        return { ok: false, error: "record run " + JSON.stringify(value.run) + " is malformed" };
    if (TUI_RECORD_STATES.indexOf(value.state) === -1)
        return { ok: false, error: "record state " + JSON.stringify(value.state) + " is not one of " + TUI_RECORD_STATES.join(", ") };
    var ended = value.state === "ended";
    if (!(value.code === null || (ended && Number.isInteger(value.code))))
        return { ok: false, error: "record code " + JSON.stringify(value.code) + " does not fit state " + value.state };
    if (typeof value.startedAt !== "string" || value.startedAt.length === 0)
        return { ok: false, error: "record startedAt must be a string" };
    if (ended ? typeof value.endedAt !== "string" || value.endedAt.length === 0 : value.endedAt !== null)
        return { ok: false, error: "record endedAt " + JSON.stringify(value.endedAt) + " does not fit state " + value.state };
    if (!isPlainObject(value.window) || typeof value.window.appId !== "string" || typeof value.window.title !== "string")
        return { ok: false, error: "record window must be { appId, title }" };
    return { ok: true, record: { key: value.key, run: value.run, state: value.state, code: value.code, startedAt: value.startedAt, endedAt: value.endedAt, window: { appId: value.window.appId, title: value.window.title } } };
}

// The runs RECORDS, a list of tuiRecord records, describe: { runs, keys },
// `runs` each run's record by run id, an ended record over the running
// one of the same run, and `keys` per key { running, ended }: the running
// run with the latest startedAt, or null, and the ended run with the latest
// startedAt, or null: a record `vgsh-tui reap` wrote carries the time the
// reap found the run, which can follow a later run's end. A running record
// whose run also ended is not running.
function tuiRuns(records) {
    var runs = {};
    records.forEach(function (record) {
        if (!hasOwn(runs, record.run) || record.state === "ended")
            runs[record.run] = record;
    });
    var keys = {};
    Object.keys(runs).forEach(function (id) {
        var record = runs[id];
        if (!hasOwn(keys, record.key))
            keys[record.key] = { running: null, ended: null };
        var slot = keys[record.key];
        if (record.state === "running") {
            if (slot.running === null || record.startedAt > slot.running.startedAt)
                slot.running = record;
        } else if (slot.ended === null || record.startedAt > slot.ended.startedAt) {
            slot.ended = record;
        }
    });
    return { runs: runs, keys: keys };
}

// The keys a new run may not start under: every key in LAUNCHING, whose
// launcher still waits for its presenter, and every key of RUNS, a tuiRuns
// result, with a running run.
function tuiBusyKeys(runs, launching) {
    var busy = launching.slice();
    Object.keys(runs.keys).forEach(function (key) {
        if (runs.keys[key].running !== null && busy.indexOf(key) === -1)
            busy.push(key);
    });
    return busy.sort();
}

// shell.tui.state for the plugin ID's own TUIs NAMES, from RUNS, a tuiRuns
// result: per name { running, code, endedAt }, the last two from the key's
// latest ended run, null before any ended.
function tuiState(runs, id, names) {
    var out = {};
    names.forEach(function (name) {
        var slot = hasOwn(runs.keys, id + "/" + name) ? runs.keys[id + "/" + name] : { running: null, ended: null };
        out[name] = {
            running: slot.running !== null,
            code: slot.ended === null ? null : slot.ended.code,
            endedAt: slot.ended === null ? null : slot.ended.endedAt
        };
    });
    return out;
}

// What the `done` of RUN receives, from RUNS, a tuiRuns result: null while
// the run has no ended record, else { code, reason }, `reason` null for a
// run that ended with its code and `vanished` for one `vgsh-tui reap`
// ended, whose code is null.
function tuiRunDone(runs, run) {
    if (!hasOwn(runs.runs, run) || runs.runs[run].state !== "ended")
        return null;
    var code = runs.runs[run].code;
    return { code: code, reason: code === null ? "vanished" : null };
}

// The window of a run whose record carries WINDOW, { appId, title }, among
// WINDOWS, each { address, appId, title } as the compositor reports it:
// { state: "found", address } with a `0x` address for exactly one match,
// { state: "none" } for none, { state: "ambiguous", count } for more. The
// presenter records the app-id and the title the terminal was opened with,
// and a terminal that honours `--title` keeps it.
function tuiWindow(windows, window) {
    var matches = windows.filter(function (w) {
        return w.appId === window.appId && w.title === window.title && typeof w.address === "string" && w.address !== "";
    });
    if (matches.length === 0)
        return { state: "none" };
    if (matches.length > 1)
        return { state: "ambiguous", count: matches.length };
    var address = matches[0].address;
    return { state: "found", address: address.indexOf("0x") === 0 ? address : "0x" + address };
}

// Validate one manifest object. Returns { ok: true, manifest } with the
// normalized manifest, or { ok: false, error } naming the first defect.
// `sourceDir` is recorded on the manifest so entry points resolve later.
// A normalized manifest always carries `capabilities` and `requirements`
// (arrays, the latter's entries normalRequirements' shape), `settings`,
// `schema`, `status` and `tui` (objects, the last normalTui's shape, {}
// when undeclared), `defaultSection` only when declared, and
// `hyprland` only when declared, as { binds, layerRules } with every bind's
// key normalised by hyprlandKey.
function validateManifest(raw, sourceDir) {
    if (!isPlainObject(raw))
        return { ok: false, error: "manifest is not a JSON object" };
    if (hasOwn(raw, "requires"))
        return { ok: false, error: "requires is refused: a plugin names no other plugin (D005); declare the external commands it runs under requirements" };
    var keys = Object.keys(raw);
    for (var u = 0; u < keys.length; u++) {
        if (MANIFEST_KEYS.indexOf(keys[u]) === -1)
            return { ok: false, error: "unknown key " + JSON.stringify(keys[u]) };
    }
    if (raw.schemaVersion !== 1)
        return { ok: false, error: "schemaVersion must be 1, got " + JSON.stringify(raw.schemaVersion) };
    if (typeof raw.id !== "string" || !ID_PATTERN.test(raw.id))
        return { ok: false, error: "id must be dotted and author-namespaced, got " + JSON.stringify(raw.id) };
    var required = ["name", "version", "author", "description"];
    for (var i = 0; i < required.length; i++) {
        if (typeof raw[required[i]] !== "string" || raw[required[i]].length === 0)
            return { ok: false, error: required[i] + " must be a non-empty string" };
    }
    if (raw.license !== undefined && (typeof raw.license !== "string" || raw.license.length === 0))
        return { ok: false, error: "license must be a non-empty string when present" };
    if (raw.icon !== undefined && (typeof raw.icon !== "string" || !hasOwn(Lucide.ICONS, raw.icon)))
        return { ok: false, error: "icon must name an icon of the shipped set, shell/Ui/icons/Lucide.js, got " + JSON.stringify(raw.icon) };
    if (!Array.isArray(raw.kinds) || raw.kinds.length === 0)
        return { ok: false, error: "kinds must be a non-empty array" };
    for (var k = 0; k < raw.kinds.length; k++) {
        if (KINDS.indexOf(raw.kinds[k]) === -1)
            return { ok: false, error: "unknown kind " + JSON.stringify(raw.kinds[k]) };
        if (raw.kinds.indexOf(raw.kinds[k]) !== k)
            return { ok: false, error: "kind " + JSON.stringify(raw.kinds[k]) + " is declared twice" };
    }
    if (!isPlainObject(raw.entryPoints))
        return { ok: false, error: "entryPoints must be an object" };
    var entryKeys = Object.keys(raw.entryPoints);
    for (var x = 0; x < entryKeys.length; x++) {
        if (raw.kinds.indexOf(entryKeys[x]) === -1)
            return { ok: false, error: "entryPoints." + entryKeys[x] + " names a kind the manifest does not declare" };
    }
    for (var e = 0; e < raw.kinds.length; e++) {
        var kind = raw.kinds[e];
        var entry = raw.entryPoints[kind];
        if (typeof entry !== "string" || entry.length === 0)
            return { ok: false, error: "entryPoints." + kind + " is required for kind " + kind };
        if (entry.indexOf("..") !== -1 || entry.charAt(0) === "/")
            return { ok: false, error: "entryPoints." + kind + " must stay inside the plugin directory" };
    }
    // A plugin that owns its look names the `.pragma library` file whose
    // `TOKENS` and `LIGHT` ThemeLogic.acceptAppearance judges; the design
    // token check reads the table from it.
    if (raw.appearance !== undefined) {
        if (typeof raw.appearance !== "string" || !/\.js$/.test(raw.appearance))
            return { ok: false, error: "appearance must name a .js file, got " + JSON.stringify(raw.appearance) };
        if (raw.appearance.indexOf("..") !== -1 || raw.appearance.charAt(0) === "/")
            return { ok: false, error: "appearance must stay inside the plugin directory" };
    }
    var capabilities = raw.capabilities === undefined ? [] : raw.capabilities;
    if (!Array.isArray(capabilities))
        return { ok: false, error: "capabilities must be an array" };
    for (var c = 0; c < capabilities.length; c++) {
        if (CAPABILITIES.indexOf(capabilities[c]) === -1)
            return { ok: false, error: "unknown capability " + JSON.stringify(capabilities[c]) };
    }
    var settings = raw.settings === undefined ? {} : raw.settings;
    if (!isPlainObject(settings))
        return { ok: false, error: "settings must be an object" };
    if (hasOwn(settings, "id"))
        return { ok: false, error: "settings must not carry an id key" };
    if (hasOwn(settings, "keys"))
        return { ok: false, error: "settings must not carry a keys key: a plugins row's keys are its Hyprland keys" };
    if (hasOwn(settings, "placement") && PLACEMENTS.indexOf(settings.placement) === -1)
        return { ok: false, error: "settings.placement must be one of " + PLACEMENTS.join(", ") + ", got " + JSON.stringify(settings.placement) };
    var schema = raw.schema === undefined ? {} : raw.schema;
    var badSchema = schemaError(schema, settings);
    if (badSchema !== "")
        return { ok: false, error: badSchema };
    if (capabilities.indexOf("configure") !== -1 && Object.keys(schema).length === 0)
        return { ok: false, error: "capability configure needs a schema" };
    if (raw.defaultSection !== undefined) {
        if (raw.kinds.indexOf("bar-widget") === -1)
            return { ok: false, error: "defaultSection needs kind bar-widget" };
        if (SECTIONS.indexOf(raw.defaultSection) === -1)
            return { ok: false, error: "defaultSection must be one of " + SECTIONS.join(", ") + ", got " + JSON.stringify(raw.defaultSection) };
    }
    if (raw.hyprland !== undefined) {
        var badHyprland = hyprlandError(raw.hyprland, capabilities);
        if (badHyprland !== "")
            return { ok: false, error: badHyprland };
    }
    var requirements = raw.requirements === undefined ? [] : raw.requirements;
    var badRequirements = requirementsError(requirements);
    if (badRequirements !== "")
        return { ok: false, error: badRequirements };
    if (raw.status !== undefined) {
        var badStatus = statusError(raw.status, capabilities);
        if (badStatus !== "")
            return { ok: false, error: badStatus };
    } else if (capabilities.indexOf("status") !== -1) {
        return { ok: false, error: "capability status needs a status declaration" };
    }
    if (raw.tui !== undefined) {
        var badTui = tuiError(raw.tui, capabilities);
        if (badTui !== "")
            return { ok: false, error: badTui };
    }
    var manifest = clone(raw);
    manifest.capabilities = capabilities.slice();
    manifest.requirements = normalRequirements(requirements);
    manifest.tui = normalTui(raw.tui === undefined ? {} : raw.tui);
    manifest.settings = clone(settings);
    manifest.schema = clone(schema);
    manifest.status = raw.status === undefined ? {} : clone(raw.status);
    if (raw.hyprland !== undefined) {
        manifest.hyprland = {
            binds: (raw.hyprland.binds || []).map(function (bind) { return { shortcut: bind.shortcut, key: hyprlandKey(bind.key).key }; }),
            layerRules: clone(raw.hyprland.layerRules || [])
        };
    }
    manifest.__sourceDir = sourceDir;
    return { ok: true, manifest: manifest };
}

// Merge the shipped defaults with the user file. Every top-level key in the
// user file replaces the shipped key whole, except `plugins`, whose entries
// merge by id with the user entry winning, and `disabledPlugins`, which is
// the user list when present. A shipped plugin entry the user file does not
// name still applies, which is the point of keeping two layers.
function effectiveConfig(shipped, user) {
    var out = clone(shipped);
    if (!isPlainObject(user))
        return out;
    Object.keys(user).forEach(function (key) {
        if (key === "plugins") {
            var byId = {};
            var order = [];
            (Array.isArray(out.plugins) ? out.plugins : []).forEach(function (entry) {
                byId[entry.id] = entry;
                order.push(entry.id);
            });
            user.plugins.forEach(function (entry) {
                if (!hasOwn(byId, entry.id)) order.push(entry.id);
                byId[entry.id] = entry;
            });
            out.plugins = order.map(function (id) { return byId[id]; });
        } else {
            out[key] = clone(user[key]);
        }
    });
    return out;
}

// The layout entries of one section, in order; [] when the section or the
// layout is absent. Both files passed configError, so every entry is an
// object with a string id.
function sectionEntries(config, section) {
    var layout = config && config.bar && isPlainObject(config.bar.layout) ? config.bar.layout : {};
    return Array.isArray(layout[section]) ? layout[section] : [];
}

// Ids placed in the bar layout, in section order.
function layoutIds(config) {
    var ids = [];
    SECTIONS.forEach(function (section) {
        sectionEntries(config, section).forEach(function (entry) { ids.push(entry.id); });
    });
    return ids;
}

// The active bar id: config.bar.id, or the shipped default bar when absent.
function activeBarId(config, defaultBarId) {
    return config && config.bar && typeof config.bar.id === "string" && config.bar.id.length > 0 ? config.bar.id : defaultBarId;
}

// The first layout entry with `id`, in section order, or null.
function layoutEntryOf(config, id) {
    for (var i = 0; i < SECTIONS.length; i++) {
        var hit = sectionEntries(config, SECTIONS[i]).filter(function (entry) { return entry.id === id; })[0];
        if (hit !== undefined) return hit;
    }
    return null;
}

// The plugins[] row with `id`, or undefined.
function pluginRow(config, id) {
    return (config && Array.isArray(config.plugins) ? config.plugins : []).filter(function (entry) {
        return entry.id === id;
    })[0];
}

// The configuration entries a plugin's settings live in, in the order a
// plugin's target list reports them.
var SETTING_TARGETS = ["layout", "plugins"];

// The configuration entry an instance of `kind` reads its settings from
// and writes them to: "layout", its layout entry, for a bar widget;
// "plugins", the plugins[] row with its id, for every other kind. The one
// place this is decided; settingTargets, the configure capability and every
// core caller of settingsFor call it.
function settingTargetOf(kind) {
    return kind === "bar-widget" ? "layout" : "plugins";
}

// The settings a plugin receives from setting target `target`, one of
// SETTING_TARGETS: its manifest's `settings` under that entry. For
// "layout" the entry is `layoutEntry`, the widget's own layout entry the
// caller passes; for "plugins" it is the plugins[] row with the plugin's
// id, and `layoutEntry` is not read. A caller holding an instance's kind
// passes settingTargetOf(kind). Keys the entry sets win, but for the keys
// ENTRY_RESERVED_KEYS names, which are no setting. The result is a fresh
// object with neither.
function settingsFor(config, manifest, target, layoutEntry) {
    var out = {};
    Object.keys(manifest.settings).forEach(function (k) { out[k] = manifest.settings[k]; });
    var entry;
    if (target === "layout") entry = layoutEntry;
    else if (target === "plugins") entry = pluginRow(config, manifest.id);
    else throw new Error("settingsFor: target " + JSON.stringify(target) + " is not one of " + SETTING_TARGETS.join(", "));
    if (isPlainObject(entry))
        Object.keys(entry).forEach(function (k) { if (ENTRY_RESERVED_KEYS.indexOf(k) === -1) out[k] = entry[k]; });
    return clone(out);
}

// Keys of a configuration entry that are no setting: the plugin's `id`, and
// a plugins row's Hyprland `keys`, which only the Hyprland layer reads.
// validateManifest refuses a default setting under either name.
var ENTRY_RESERVED_KEYS = ["id", "keys"];

// What plugin MANIFEST asks of Hyprland under CONFIG: { id, version, binds,
// layerRules, unknownKeys }. `binds` follows the manifest's `hyprland.binds`
// in order, each { shortcut, key }: the key its plugins row's `keys` gives
// that shortcut, normalised, null when the row gives it null (the user
// unbinds it), else the manifest's. `unknownKeys` lists, sorted, each name
// the row's `keys` gives that no bind declares. A manifest without
// `hyprland` asks nothing: empty lists, and its row's names all unknown.
// CONFIG passed configError, so every key it gives is well formed.
function hyprlandSection(config, manifest) {
    var row = pluginRow(config, manifest.id);
    var keys = row !== undefined && isPlainObject(row.keys) ? row.keys : {};
    var declared = manifest.hyprland === undefined ? { binds: [], layerRules: [] } : manifest.hyprland;
    var binds = declared.binds.map(function (bind) {
        if (!hasOwn(keys, bind.shortcut)) return { shortcut: bind.shortcut, key: bind.key };
        if (keys[bind.shortcut] === null) return { shortcut: bind.shortcut, key: null };
        var key = hyprlandKey(keys[bind.shortcut]);
        if (!key.ok)
            throw new Error("hyprlandSection: plugins row " + manifest.id + " passed configError with keys." + bind.shortcut + " " + key.error);
        return { shortcut: bind.shortcut, key: key.key };
    });
    var names = declared.binds.map(function (bind) { return bind.shortcut; });
    return {
        id: manifest.id,
        version: manifest.version,
        binds: binds,
        layerRules: clone(declared.layerRules),
        unknownKeys: Object.keys(keys).filter(function (name) { return names.indexOf(name) === -1; }).sort()
    };
}

// The settings the plugin manager shows for a plugin: the ones its placed
// bar widget reads, from its first layout entry, or, for a plugin with no
// placed widget, the ones every other kind reads from its plugins[] row.
function managerSettings(config, manifest) {
    var entry = manifest.kinds.indexOf("bar-widget") !== -1 ? layoutEntryOf(config, manifest.id) : null;
    return entry !== null ? settingsFor(config, manifest, "layout", entry) : settingsFor(config, manifest, "plugins", null);
}

// Whether a plugin is enabled under this configuration.
// - disabledPlugins[] wins over every other rule.
// - A plugin declaring kind bar is enabled only as the active bar; every
//   other kind it declares comes and goes with its bar.
// - A bar widget is enabled when placed in a bar section.
// - A plugin declaring a kind other than bar and bar-widget is enabled when
//   listed in plugins[], and unlisted when it is first-party (id under the
//   `vgs.` prefix). A bar's settings row in plugins[] enables nothing.
function isEnabled(config, manifest, defaultBarId) {
    var disabled = Array.isArray(config.disabledPlugins) ? config.disabledPlugins : [];
    if (disabled.indexOf(manifest.id) !== -1)
        return false;
    if (manifest.kinds.indexOf("bar") !== -1)
        return activeBarId(config, defaultBarId) === manifest.id;
    if (manifest.kinds.indexOf("bar-widget") !== -1 && layoutIds(config).indexOf(manifest.id) !== -1)
        return true;
    var nonBarKinds = manifest.kinds.filter(function (k) { return k !== "bar" && k !== "bar-widget"; });
    if (nonBarKinds.length === 0)
        return false;
    return pluginRow(config, manifest.id) !== undefined || manifest.id.indexOf(FIRST_PARTY_PREFIX) === 0;
}

// The ids the configuration lists in `disabledPlugins` and `plugins` that
// no discovered plugin in `manifests` has, as { id, key } rows, `key` the
// configuration key that lists the id, in that key order and then in list
// order, each id once per key. A plugin removed or renamed leaves its id
// behind; the manager reports the row and changes nothing.
function unknownIds(config, manifests) {
    var out = [];
    function report(key, ids) {
        ids.forEach(function (id) {
            var listed = out.some(function (row) { return row.id === id && row.key === key; });
            if (!hasOwn(manifests, id) && !listed) out.push({ id: id, key: key });
        });
    }
    report("disabledPlugins", Array.isArray(config.disabledPlugins) ? config.disabledPlugins : []);
    report("plugins", (Array.isArray(config.plugins) ? config.plugins : []).map(function (entry) { return entry.id; }));
    return out;
}

// The widgets each bar section shows: the layout entries whose plugin is
// known, declares kind bar-widget and is enabled. This is the one place
// enablement meets placement; a bar receives the result and interprets
// nothing. Entries are copied, so the caller may hold them.
function effectiveLayout(config, manifests, defaultBarId) {
    var out = {};
    SECTIONS.forEach(function (section) {
        out[section] = sectionEntries(config, section).filter(function (entry) {
            var m = hasOwn(manifests, entry.id) ? manifests[entry.id] : undefined;
            return m !== undefined && m.kinds.indexOf("bar-widget") !== -1 && isEnabled(config, m, defaultBarId);
        }).map(clone);
    });
    return out;
}

// Enabled bar widgets that stop showing when `id`, the active bar, is
// disabled. They stay enabled and keep every other kind they declare; the
// manager reports them so the user knows what leaves the screen. Only a
// placed widget shows, so a plugin enabled for another kind while its
// widget is unplaced hides nothing.
function hiddenByDisabling(manifests, config, id, defaultBarId) {
    var m = hasOwn(manifests, id) ? manifests[id] : undefined;
    if (!m || m.kinds.indexOf("bar") === -1 || activeBarId(config, defaultBarId) !== id)
        return [];
    var placed = layoutIds(config);
    return Object.keys(manifests).filter(function (other) {
        var o = manifests[other];
        return other !== id && o.kinds.indexOf("bar-widget") !== -1 && placed.indexOf(other) !== -1 && isEnabled(config, o, defaultBarId);
    }).sort();
}

// The user-file change that enables or disables one plugin. Returns the new
// user object; the caller writes it.
//
// Disabling only lists the id in disabledPlugins: every placement, every
// settings row and the active bar id stay in the file, so re-enabling
// restores the screen exactly. Enabling unlists the id and, only when the
// plugin has no presence yet, gives it one: a bar becomes the active bar; a
// bar widget not placed in any section is placed in its default section
// (`center` when the manifest names none); a third-party plugin of another
// kind not listed in plugins[] is listed. Because a user `bar` key replaces
// the shipped one whole, a user file without one is seeded from the
// effective bar before its first bar edit, so the edit keeps every other
// widget in place. Enabling a plugin that already has its presence changes
// nothing but the disabled list.
function withEnabled(user, manifest, enabled, effective) {
    var out = isPlainObject(user) ? clone(user) : {};
    if (out.version === undefined) out.version = CONFIG_VERSION;
    var disabled = Array.isArray(effective.disabledPlugins) ? effective.disabledPlugins.slice() : [];
    if (!enabled) {
        if (disabled.indexOf(manifest.id) === -1) disabled.push(manifest.id);
        out.disabledPlugins = disabled;
        return out;
    }
    out.disabledPlugins = disabled.filter(function (d) { return d !== manifest.id; });
    var isBar = manifest.kinds.indexOf("bar") !== -1;
    var isWidget = manifest.kinds.indexOf("bar-widget") !== -1;
    var seedBar = function () {
        if (!isPlainObject(out.bar))
            out.bar = effective && isPlainObject(effective.bar) ? clone(effective.bar) : {};
    };
    if (isBar && activeBarId(effective, "") !== manifest.id) {
        seedBar();
        out.bar.id = manifest.id;
    }
    if (isWidget && layoutIds(effective).indexOf(manifest.id) === -1) {
        seedBar();
        if (!isPlainObject(out.bar.layout)) out.bar.layout = { left: [], center: [], right: [] };
        var section = typeof manifest.defaultSection === "string" ? manifest.defaultSection : "center";
        if (!Array.isArray(out.bar.layout[section])) out.bar.layout[section] = [];
        out.bar.layout[section].push({ id: manifest.id });
    }
    if (!isBar && !isWidget && manifest.id.indexOf(FIRST_PARTY_PREFIX) !== 0) {
        if (pluginRow(effective, manifest.id) === undefined) {
            var plugins = Array.isArray(out.plugins) ? out.plugins : [];
            plugins.push({ id: manifest.id });
            out.plugins = plugins;
        }
    }
    return out;
}

// Why `value` may not be written to setting `key` of this plugin, or "".
// Only a key the manifest's schema declares is writable, and only with a
// value of its type. The reply is one keyed line.
function settingRefusal(manifest, key, value) {
    if (!hasOwn(manifest.schema, key))
        return "refused: setting=" + key + " undeclared";
    var bad = settingError(manifest.schema[key], value);
    return bad === "" ? "" : "refused: setting=" + key + " " + bad;
}

// Why shortcut `shortcut` of this plugin may not take `key`, or "". Only a
// shortcut the manifest's `hyprland.binds` declares has a key. A key string
// hyprlandKey accepts rebinds it, null unbinds it, and undefined removes the
// plugins row's entry so the manifest's key applies. The reply is one keyed
// line.
function keyRefusal(manifest, shortcut, key) {
    var binds = manifest.hyprland === undefined ? [] : manifest.hyprland.binds;
    if (!binds.some(function (bind) { return bind.shortcut === shortcut; }))
        return "refused: key=" + shortcut + " undeclared";
    if (key === undefined || key === null)
        return "";
    if (typeof key !== "string")
        return "refused: key=" + shortcut + " want=string-or-null";
    var parsed = hyprlandKey(key);
    return parsed.ok ? "" : "refused: key=" + shortcut + " " + parsed.error;
}

// The user-file change that sets one shortcut's key in the plugin's plugins
// row `keys`: the normalised key, null to unbind, or, for undefined, no
// entry, so the manifest's key applies; a `keys` left empty is removed. The
// row is seeded from the effective one, since a user row replaces the
// shipped row whole; a reset the effective row does not need changes
// nothing. The caller checks the key with keyRefusal first.
function withKey(user, manifest, shortcut, key, effective) {
    var out = isPlainObject(user) ? clone(user) : {};
    if (out.version === undefined) out.version = CONFIG_VERSION;
    var row = pluginRow(out, manifest.id);
    if (row === undefined) {
        var shippedRow = pluginRow(effective, manifest.id);
        var needed = key !== undefined || (shippedRow !== undefined && isPlainObject(shippedRow.keys) && hasOwn(shippedRow.keys, shortcut));
        if (!needed)
            return out;
        row = shippedRow !== undefined ? clone(shippedRow) : { id: manifest.id };
        out.plugins = (Array.isArray(out.plugins) ? out.plugins : []).concat([row]);
    }
    if (key === undefined) {
        if (isPlainObject(row.keys)) {
            delete row.keys[shortcut];
            if (Object.keys(row.keys).length === 0) delete row.keys;
        }
        return out;
    }
    if (!isPlainObject(row.keys)) row.keys = {};
    row.keys[shortcut] = key === null ? null : hyprlandKey(key).key;
    return out;
}

// The Keys rows the plugin manager shows for a plugin: one per bind its
// manifest declares, in order, as { shortcut, key, default, description }:
// the key hyprlandSection puts in effect (null when unbound), the
// manifest's key, and the description the plugin registered for
// `<id>:<shortcut>` in `descriptions`, "" while none is registered.
function bindRows(config, manifest, descriptions) {
    var defaults = manifest.hyprland === undefined ? [] : manifest.hyprland.binds;
    return hyprlandSection(config, manifest).binds.map(function (bind, i) {
        var name = manifest.id + ":" + bind.shortcut;
        return { shortcut: bind.shortcut, key: bind.key, "default": defaults[i].key, description: hasOwn(descriptions, name) ? descriptions[name] : "" };
    });
}

// The icon a plugin is listed with: its manifest's, else DEFAULT_ICON.
function pluginIcon(manifest) {
    return typeof manifest.icon === "string" ? manifest.icon : DEFAULT_ICON;
}

// The configuration entries a plugin's instances read their settings from,
// one per settingTargetOf(kind) over its kinds, "layout" only while a
// widget is placed in the bar. A running instance writes only the entry it
// reads; the plugin manager writes every entry the plugin reads.
function settingTargets(config, manifest) {
    var wanted = manifest.kinds.map(settingTargetOf);
    return SETTING_TARGETS.filter(function (target) {
        if (wanted.indexOf(target) === -1) return false;
        return target !== "layout" || layoutIds(config).indexOf(manifest.id) !== -1;
    });
}

// The user-file change that sets one setting of one plugin in each of
// `targets`. "layout" sets the key on every layout entry with the plugin's
// id, or with `locator` { section, nth } on the nth such entry of that
// section alone, seeding the user `bar` key from the effective bar first;
// "plugins"
// sets it on the plugin's plugins[] row, seeding that row from the
// effective one, since a user row replaces the shipped row whole. The
// caller checks the value with settingRefusal first.
function withSetting(user, manifest, key, value, effective, targets, locator) {
    var out = isPlainObject(user) ? clone(user) : {};
    if (out.version === undefined) out.version = CONFIG_VERSION;
    if (targets.indexOf("layout") !== -1) {
        if (!isPlainObject(out.bar))
            out.bar = effective && isPlainObject(effective.bar) ? clone(effective.bar) : {};
        var layout = isPlainObject(out.bar.layout) ? out.bar.layout : {};
        SECTIONS.forEach(function (section) {
            if (isPlainObject(locator) && locator.section !== section) return;
            var seen = 0;
            (Array.isArray(layout[section]) ? layout[section] : []).forEach(function (entry) {
                if (entry.id !== manifest.id) return;
                if (!isPlainObject(locator) || seen === locator.nth) entry[key] = clone(value);
                seen += 1;
            });
        });
    }
    if (targets.indexOf("plugins") !== -1) {
        var plugins = Array.isArray(out.plugins) ? out.plugins : [];
        var row = pluginRow(out, manifest.id);
        if (row === undefined) {
            var shippedRow = pluginRow(effective, manifest.id);
            row = shippedRow !== undefined ? clone(shippedRow) : { id: manifest.id };
            plugins.push(row);
        }
        row[key] = clone(value);
        out.plugins = plugins;
    }
    return out;
}

// Why this plugin may not be built while `held` maps each exclusive
// capability to the plugin holding it, or "". A plugin may hold what it
// already holds, so its second instance builds.
function lendRefusal(held, manifest) {
    for (var i = 0; i < manifest.capabilities.length; i++) {
        var name = manifest.capabilities[i];
        if (EXCLUSIVE_CAPABILITIES.indexOf(name) === -1) continue;
        if (hasOwn(held, name) && held[name] !== manifest.id)
            return "refused: capability=" + name + " held-by=" + held[name];
    }
    return "";
}

// Judge one toast's options, the argument of shell.toasts.show: an object
// with a non-empty string `title`, an optional string `message`, `tone`
// from TOAST_TONES, an optional string `icon` and an optional `duration` in
// whole milliseconds at or above zero, zero meaning until dismissed.
// Answers { ok: true, value } with every key present, or { ok: false,
// error } with the offending key first.
function toastOptions(raw) {
    if (!isPlainObject(raw))
        return { ok: false, error: "options must be an object" };
    var keys = Object.keys(raw);
    for (var i = 0; i < keys.length; i++)
        if (TOAST_KEYS.indexOf(keys[i]) === -1)
            return { ok: false, error: keys[i] + " unknown" };
    if (typeof raw.title !== "string" || raw.title.trim() === "" || raw.title.length > TOAST_TITLE_MAX)
        return { ok: false, error: "title must be a string of 1 to " + TOAST_TITLE_MAX + " characters" };
    if (raw.message !== undefined && (typeof raw.message !== "string" || raw.message.length > TOAST_MESSAGE_MAX))
        return { ok: false, error: "message must be a string of at most " + TOAST_MESSAGE_MAX + " characters" };
    if (raw.tone !== undefined && TOAST_TONES.indexOf(raw.tone) === -1)
        return { ok: false, error: "tone must be one of " + TOAST_TONES.join(", ") };
    if (raw.icon !== undefined && typeof raw.icon !== "string")
        return { ok: false, error: "icon must be a string" };
    if (raw.duration !== undefined && !(typeof raw.duration === "number" && isFinite(raw.duration) && raw.duration >= 0 && Math.floor(raw.duration) === raw.duration))
        return { ok: false, error: "duration must be a whole number of milliseconds at or above 0" };
    return { ok: true, value: { title: raw.title, message: raw.message === undefined ? "" : raw.message, tone: raw.tone === undefined ? "neutral" : raw.tone, icon: raw.icon === undefined ? "" : raw.icon, duration: raw.duration === undefined ? null : raw.duration } };
}

// Layer placement for a summon without an item anchor. Popups delegate
// anchored placement to the compositor. Unknown user placement falls back
// to center and returns an error for the host to report. A centred panel or
// menu ignores reserved space, so it sits on the middle of the whole
// monitor; every other placement keeps clear of it.
function surfacePlacement(kind, settings, gap) {
    var zero = { top: 0, bottom: 0, left: 0, right: 0 };
    var layer = kind === "panel" ? "top" : "overlay";
    if (kind === "overlay")
        return { anchors: { top: true, bottom: true, left: true, right: true }, margins: zero, exclusion: "ignore", layer: layer, placement: "fill", error: "" };
    var asked = isPlainObject(settings) ? settings.placement : undefined;
    var known = asked === undefined || PLACEMENTS.indexOf(asked) !== -1;
    var placement = asked !== undefined && known ? asked : "center";
    var anchors = { top: false, bottom: false, left: false, right: false };
    var margins = { top: 0, bottom: 0, left: 0, right: 0 };
    var parts = placement.split("-");
    parts.forEach(function (edge) {
        if (edge === "center") return;
        anchors[edge] = true;
        margins[edge] = gap;
    });
    return { anchors: anchors, margins: margins, exclusion: placement === "center" ? "ignore" : "normal", layer: layer, placement: placement, error: known ? "" : "placement=" + JSON.stringify(asked) + " unknown" };
}
