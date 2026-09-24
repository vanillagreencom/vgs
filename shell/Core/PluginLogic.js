.pragma library

// Pure decisions about plugins and configuration. No QML objects, no I/O, so
// scripts/test-plugin-logic.js runs every function under node.

// The kinds the core hosts. A manifest naming any other kind is refused. A
// kind's entry point is keyed by the kind name in `entryPoints`.
var KINDS = ["bar-widget", "bar", "panel", "overlay", "menu", "service", "background"];

// Capabilities the core can hand a plugin. A manifest naming another one is
// refused. Capabilities.qml maps each name to its provider.
var CAPABILITIES = ["compositor", "configure", "ipc", "lock", "notifications", "polkit", "run", "screens", "shortcut", "surfaces", "builtins", "manager"];

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
var MANIFEST_KEYS = ["schemaVersion", "id", "name", "version", "author", "description", "license", "kinds", "entryPoints", "capabilities", "settings", "schema", "defaultSection"];

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

// Validate one manifest object. Returns { ok: true, manifest } with the
// normalized manifest, or { ok: false, error } naming the first defect.
// `sourceDir` is recorded on the manifest so entry points resolve later.
// A normalized manifest always carries `capabilities` (array), `settings`
// and `schema` (objects), and `defaultSection` only when declared.
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
    var manifest = JSON.parse(JSON.stringify(raw));
    manifest.capabilities = capabilities.slice();
    manifest.settings = JSON.parse(JSON.stringify(settings));
    manifest.schema = JSON.parse(JSON.stringify(schema));
    manifest.__sourceDir = sourceDir;
    return { ok: true, manifest: manifest };
}

// Merge the shipped defaults with the user file. Every top-level key in the
// user file replaces the shipped key whole, except `plugins`, whose entries
// merge by id with the user entry winning, and `disabledPlugins`, which is
// the user list when present. A shipped plugin entry the user file does not
// name still applies, which is the point of keeping two layers.
function effectiveConfig(shipped, user) {
    var out = JSON.parse(JSON.stringify(shipped));
    if (!isPlainObject(user))
        return out;
    Object.keys(user).forEach(function (key) {
        if (key === "plugins") {
            var byId = {};
            var order = [];
            (Array.isArray(out.plugins) ? out.plugins : []).forEach(function (entry) {
                if (isPlainObject(entry) && typeof entry.id === "string") { byId[entry.id] = entry; order.push(entry.id); }
            });
            (Array.isArray(user.plugins) ? user.plugins : []).forEach(function (entry) {
                if (!isPlainObject(entry) || typeof entry.id !== "string") return;
                if (!(entry.id in byId)) order.push(entry.id);
                byId[entry.id] = entry;
            });
            out.plugins = order.map(function (id) { return byId[id]; });
        } else {
            out[key] = JSON.parse(JSON.stringify(user[key]));
        }
    });
    return out;
}

// The raw layout entries of one section: objects with a string id, in order.
function sectionEntries(config, section) {
    var layout = config && config.bar && isPlainObject(config.bar.layout) ? config.bar.layout : {};
    return (Array.isArray(layout[section]) ? layout[section] : []).filter(function (entry) {
        return isPlainObject(entry) && typeof entry.id === "string";
    });
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
        return isPlainObject(entry) && entry.id === id;
    })[0];
}

// The settings a plugin receives: its manifest's `settings` under the entry
// the configuration holds for it. A bar widget's entry is its layout entry
// (`layoutEntry`, passed by the core when it mounts the widget); every
// other kind's entry is the `plugins[]` row with its id. Keys the entry
// sets win. The result is a fresh object with no `id` key.
function settingsFor(config, manifest, layoutEntry) {
    var out = {};
    Object.keys(manifest.settings).forEach(function (k) { out[k] = manifest.settings[k]; });
    var entry = isPlainObject(layoutEntry) ? layoutEntry : pluginRow(config, manifest.id);
    if (isPlainObject(entry))
        Object.keys(entry).forEach(function (k) { if (k !== "id") out[k] = entry[k]; });
    return JSON.parse(JSON.stringify(out));
}

// Whether a plugin is enabled under this configuration.
// - disabledPlugins[] wins over every other rule.
// - The active bar is enabled.
// - A bar widget is enabled when placed in a bar section.
// - A plugin declaring a kind other than bar and bar-widget is enabled when
//   listed in plugins[], and unlisted when it is first-party (id under the
//   `vgs.` prefix). A bar's settings row in plugins[] enables nothing.
function isEnabled(config, manifest, defaultBarId) {
    var disabled = Array.isArray(config.disabledPlugins) ? config.disabledPlugins : [];
    if (disabled.indexOf(manifest.id) !== -1)
        return false;
    if (manifest.kinds.indexOf("bar") !== -1 && activeBarId(config, defaultBarId) === manifest.id)
        return true;
    if (manifest.kinds.indexOf("bar-widget") !== -1 && layoutIds(config).indexOf(manifest.id) !== -1)
        return true;
    var nonBarKinds = manifest.kinds.filter(function (k) { return k !== "bar" && k !== "bar-widget"; });
    if (nonBarKinds.length === 0)
        return false;
    return pluginRow(config, manifest.id) !== undefined || manifest.id.indexOf(FIRST_PARTY_PREFIX) === 0;
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
        }).map(function (entry) { return JSON.parse(JSON.stringify(entry)); });
    });
    return out;
}

// Enabled bar widgets that stop showing when `id`, the active bar, is
// disabled. They stay enabled and keep every other kind they declare; the
// manager reports them so the user knows what leaves the screen.
function hiddenByDisabling(manifests, config, id, defaultBarId) {
    var m = hasOwn(manifests, id) ? manifests[id] : undefined;
    if (!m || m.kinds.indexOf("bar") === -1 || activeBarId(config, defaultBarId) !== id)
        return [];
    return Object.keys(manifests).filter(function (other) {
        var o = manifests[other];
        return other !== id && o.kinds.indexOf("bar-widget") !== -1 && isEnabled(config, o, defaultBarId);
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
    var out = isPlainObject(user) ? JSON.parse(JSON.stringify(user)) : {};
    if (out.version === undefined) out.version = 1;
    var disabled = Array.isArray(out.disabledPlugins) ? out.disabledPlugins.slice() : [];
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
            out.bar = effective && isPlainObject(effective.bar) ? JSON.parse(JSON.stringify(effective.bar)) : {};
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
        var listed = (Array.isArray(effective.plugins) ? effective.plugins : []).some(function (e) { return isPlainObject(e) && e.id === manifest.id; });
        if (!listed) {
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

// The configuration entries a plugin's instances read their settings from:
// "layout" when it is a bar widget placed in the bar, "plugins" when it
// declares any other kind. A running instance writes only the entry it
// reads; the plugin manager writes every entry the plugin reads.
function settingTargets(config, manifest) {
    var out = [];
    if (manifest.kinds.indexOf("bar-widget") !== -1 && layoutIds(config).indexOf(manifest.id) !== -1)
        out.push("layout");
    if (manifest.kinds.some(function (k) { return k !== "bar-widget"; }))
        out.push("plugins");
    return out;
}

// The user-file change that sets one setting of one plugin in each of
// `targets`. "layout" sets the key on every layout entry with the plugin's
// id, seeding the user `bar` key from the effective bar first; "plugins"
// sets it on the plugin's plugins[] row, seeding that row from the
// effective one, since a user row replaces the shipped row whole. The
// caller checks the value with settingRefusal first.
function withSetting(user, manifest, key, value, effective, targets) {
    var out = isPlainObject(user) ? clone(user) : {};
    if (out.version === undefined) out.version = 1;
    if (targets.indexOf("layout") !== -1) {
        if (!isPlainObject(out.bar))
            out.bar = effective && isPlainObject(effective.bar) ? clone(effective.bar) : {};
        var layout = isPlainObject(out.bar.layout) ? out.bar.layout : {};
        SECTIONS.forEach(function (section) {
            (Array.isArray(layout[section]) ? layout[section] : []).forEach(function (entry) {
                if (isPlainObject(entry) && entry.id === manifest.id) entry[key] = clone(value);
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

// The layer-shell geometry of one summoned surface.
//
// `kind` is the summoned kind; `settings` the plugin's settings; `anchor`
// null or { x, y, width, height }, the rectangle of the item it was
// summoned from, relative to the screen; `size` { width, height } of the
// surface; `screen` { width, height }; `gap` the distance kept from an edge
// or an anchor.
//
// Returns { anchors: { top, bottom, left, right }, margins: { top, bottom,
// left, right }, exclusion: "normal" | "ignore", placement, error }. An overlay
// fills its screen. An anchored surface sits under its anchor, centred on
// it and clamped to the screen, or above it when there is no room below,
// positioned from the screen's top-left corner so the bar's reserved space
// does not move it. An unanchored surface takes its `placement` setting and
// keeps clear of reserved space. An unknown placement centres the surface
// and names the setting in `error`, which is "" otherwise.
function surfacePlacement(kind, settings, anchor, size, screen, gap) {
    var zero = { top: 0, bottom: 0, left: 0, right: 0 };
    if (kind === "overlay")
        return { anchors: { top: true, bottom: true, left: true, right: true }, margins: zero, exclusion: "ignore", placement: "fill", error: "" };
    if (isPlainObject(anchor)) {
        var left = Math.round(anchor.x + anchor.width / 2 - size.width / 2);
        left = Math.max(0, Math.min(left, screen.width - size.width));
        var below = anchor.y + anchor.height + gap;
        var top = below + size.height <= screen.height ? below : Math.max(0, anchor.y - gap - size.height);
        return { anchors: { top: true, bottom: false, left: true, right: false }, margins: { top: top, bottom: 0, left: left, right: 0 }, exclusion: "ignore", placement: "anchor", error: "" };
    }
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
    return { anchors: anchors, margins: margins, exclusion: "normal", placement: placement, error: known ? "" : "placement=" + JSON.stringify(asked) + " unknown" };
}
