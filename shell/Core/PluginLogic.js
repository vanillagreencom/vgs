.pragma library

// Pure decisions about plugins and configuration. No QML objects, no I/O, so
// scripts/test-plugin-logic.js runs every function under node.

// The kinds the core hosts. A manifest naming any other kind is refused. A
// kind's entry point is keyed by the kind name in `entryPoints`.
var KINDS = ["bar-widget", "bar", "panel", "overlay", "menu", "service"];

// Capabilities the core can hand a plugin. A manifest naming another one is
// refused. Plugins.qml maps each name to its provider.
var CAPABILITIES = ["compositor"];

var SECTIONS = ["left", "center", "right"];

// Every key a manifest may carry. An unknown key is refused, so a misspelt
// key fails loudly instead of being carried and ignored.
var MANIFEST_KEYS = ["schemaVersion", "id", "name", "version", "author", "description", "license", "kinds", "entryPoints", "capabilities", "settings", "defaultSection"];

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

// Validate one manifest object. Returns { ok: true, manifest } with the
// normalized manifest, or { ok: false, error } naming the first defect.
// `sourceDir` is recorded on the manifest so entry points resolve later.
// A normalized manifest always carries `capabilities` (array) and
// `settings` (object), and `defaultSection` only when declared.
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
    if (raw.defaultSection !== undefined) {
        if (raw.kinds.indexOf("bar-widget") === -1)
            return { ok: false, error: "defaultSection needs kind bar-widget" };
        if (SECTIONS.indexOf(raw.defaultSection) === -1)
            return { ok: false, error: "defaultSection must be one of " + SECTIONS.join(", ") + ", got " + JSON.stringify(raw.defaultSection) };
    }
    var manifest = JSON.parse(JSON.stringify(raw));
    manifest.capabilities = capabilities.slice();
    manifest.settings = JSON.parse(JSON.stringify(settings));
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

// The settings a plugin receives: its manifest's `settings` under the entry
// the configuration holds for it. A bar widget's entry is its layout entry
// (`layoutEntry`, passed by the core when it mounts the widget); every
// other kind's entry is the `plugins[]` row with its id. Keys the entry
// sets win. The result is a fresh object with no `id` key.
function settingsFor(config, manifest, layoutEntry) {
    var out = {};
    Object.keys(manifest.settings).forEach(function (k) { out[k] = manifest.settings[k]; });
    var entry = layoutEntry;
    if (!isPlainObject(entry)) {
        entry = (Array.isArray(config.plugins) ? config.plugins : []).filter(function (e) {
            return isPlainObject(e) && e.id === manifest.id;
        })[0];
    }
    if (isPlainObject(entry))
        Object.keys(entry).forEach(function (k) { if (k !== "id") out[k] = entry[k]; });
    return JSON.parse(JSON.stringify(out));
}

// Whether a plugin is enabled under this configuration.
// - disabledPlugins[] wins over every other rule.
// - The active bar is enabled.
// - A bar widget is enabled when placed in a bar section.
// - Anything else is enabled when listed in plugins[], and a first-party
//   plugin (id under the `vgs.` prefix) declaring a kind other than bar and
//   bar-widget is enabled unlisted.
function isEnabled(config, manifest, defaultBarId) {
    var disabled = Array.isArray(config.disabledPlugins) ? config.disabledPlugins : [];
    if (disabled.indexOf(manifest.id) !== -1)
        return false;
    if (manifest.kinds.indexOf("bar") !== -1 && activeBarId(config, defaultBarId) === manifest.id)
        return true;
    if (manifest.kinds.indexOf("bar-widget") !== -1 && layoutIds(config).indexOf(manifest.id) !== -1)
        return true;
    var listed = (Array.isArray(config.plugins) ? config.plugins : []).some(function (entry) {
        return isPlainObject(entry) && entry.id === manifest.id;
    });
    if (listed)
        return true;
    var nonBarKinds = manifest.kinds.filter(function (k) { return k !== "bar" && k !== "bar-widget"; });
    return nonBarKinds.length > 0 && manifest.id.indexOf(FIRST_PARTY_PREFIX) === 0;
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
