.pragma library

// Pure decisions about plugins and configuration. No QML objects, no I/O, so
// scripts/test-plugin-logic.js runs every function under node.

// The kinds the core hosts. A manifest naming any other kind is refused. A
// kind's entry point is keyed by the kind name in `entryPoints`.
var KINDS = ["bar-widget", "bar", "panel", "overlay", "menu", "service", "background"];

// Capabilities the core can hand a plugin. A manifest naming another one is
// refused. Capabilities.qml maps each name to its provider.
var CAPABILITIES = ["compositor", "configure", "ipc", "lock", "notifications", "polkit", "run", "screens", "shortcut", "surfaces", "builtins", "manager", "toasts", "theme", "layers"];

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
// carry.
var SETTING_TYPES = ["string", "number", "boolean", "enum"];
var SCHEMA_ENTRY_KEYS = ["type", "label", "description", "options"];

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
var MANIFEST_KEYS = ["schemaVersion", "id", "name", "version", "author", "description", "license", "kinds", "entryPoints", "capabilities", "settings", "schema", "defaultSection", "appearance", "hyprland"];

// A name a plugin registers a shortcut, an IPC target or a built-in widget
// under, and the name a manifest's Hyprland bind gives its shortcut.
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
// objects each with a string `id`.
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

// Why `value` does not fit a schema entry, or "" when it does.
function settingError(entry, value) {
    if (entry.type === "string") return typeof value === "string" ? "" : "want=string";
    if (entry.type === "number") return typeof value === "number" && isFinite(value) ? "" : "want=number";
    if (entry.type === "boolean") return typeof value === "boolean" ? "" : "want=boolean";
    if (entry.type === "enum") return entry.options.indexOf(value) !== -1 ? "" : "want=one-of:" + entry.options.join("|");
    throw new Error("settingError: schema entry type " + JSON.stringify(entry.type) + " passed validation but has no rule");
}

// The first defect of a settings schema, or "". Every entry names a type
// from SETTING_TYPES and a label; an enum entry lists its options; every
// entry has a default of its type in `settings`, so a form always has a
// value to show.
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
        if (!hasOwn(settings, key))
            return at + " has no default in settings";
        var bad = settingError(entry, settings[key]);
        if (bad !== "")
            return "settings." + key + " does not fit its schema: " + bad;
    }
    return "";
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

// Validate one manifest object. Returns { ok: true, manifest } with the
// normalized manifest, or { ok: false, error } naming the first defect.
// `sourceDir` is recorded on the manifest so entry points resolve later.
// A normalized manifest always carries `capabilities` (array), `settings`
// and `schema` (objects), `defaultSection` only when declared, and
// `hyprland` only when declared, as { binds, layerRules } with every bind's
// key normalised by hyprlandKey.
function validateManifest(raw, sourceDir) {
    if (!isPlainObject(raw))
        return { ok: false, error: "manifest is not a JSON object" };
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
    var manifest = clone(raw);
    manifest.capabilities = capabilities.slice();
    manifest.settings = clone(settings);
    manifest.schema = clone(schema);
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
// to center and returns an error for the host to report.
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
    return { anchors: anchors, margins: margins, exclusion: "normal", layer: layer, placement: placement, error: known ? "" : "placement=" + JSON.stringify(asked) + " unknown" };
}
