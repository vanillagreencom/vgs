.pragma library

// Pure decisions about plugins and configuration. No QML objects, no I/O, so
// scripts/test-plugin-logic.js runs every function under node.

// The kinds the core hosts. A manifest naming any other kind is refused.
var KINDS = ["bar-widget", "bar", "panel", "overlay", "menu", "service"];

// Entry-point key for each kind, as Omarchy Quattro spells them.
var ENTRY_KEYS = {
    "bar-widget": "barWidget",
    "bar": "bar",
    "panel": "panel",
    "overlay": "overlay",
    "menu": "menu",
    "service": "service"
};

// Capabilities the core can hand a plugin. A manifest naming another one is
// refused. Plugins.qml maps each name to its provider.
var CAPABILITIES = ["compositor"];

var SECTIONS = ["left", "center", "right"];

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
function validateManifest(raw, sourceDir) {
    if (!isPlainObject(raw))
        return { ok: false, error: "manifest is not a JSON object" };
    if (raw.schemaVersion !== 1)
        return { ok: false, error: "schemaVersion must be 1, got " + JSON.stringify(raw.schemaVersion) };
    if (typeof raw.id !== "string" || !ID_PATTERN.test(raw.id))
        return { ok: false, error: "id must be dotted and author-namespaced, got " + JSON.stringify(raw.id) };
    var required = ["name", "version", "author", "description"];
    for (var i = 0; i < required.length; i++) {
        if (typeof raw[required[i]] !== "string" || raw[required[i]].length === 0)
            return { ok: false, error: required[i] + " must be a non-empty string" };
    }
    if (!Array.isArray(raw.kinds) || raw.kinds.length === 0)
        return { ok: false, error: "kinds must be a non-empty array" };
    for (var k = 0; k < raw.kinds.length; k++) {
        if (KINDS.indexOf(raw.kinds[k]) === -1)
            return { ok: false, error: "unknown kind " + JSON.stringify(raw.kinds[k]) };
    }
    if (!isPlainObject(raw.entryPoints))
        return { ok: false, error: "entryPoints must be an object" };
    for (var e = 0; e < raw.kinds.length; e++) {
        var key = ENTRY_KEYS[raw.kinds[e]];
        var entry = raw.entryPoints[key];
        if (typeof entry !== "string" || entry.length === 0)
            return { ok: false, error: "entryPoints." + key + " is required for kind " + raw.kinds[e] };
        if (entry.indexOf("..") !== -1 || entry.charAt(0) === "/")
            return { ok: false, error: "entryPoints." + key + " must stay inside the plugin directory" };
    }
    var vgs = raw.vgs === undefined ? {} : raw.vgs;
    if (!isPlainObject(vgs))
        return { ok: false, error: "vgs must be an object" };
    // REVISIT(D005): a plugin dependency would be declared here, if ever.
    if (vgs.requires !== undefined)
        return { ok: false, error: "plugins declare no dependencies; a kind whose host is absent is not shown" };
    var capabilities = vgs.capabilities === undefined ? [] : vgs.capabilities;
    if (!Array.isArray(capabilities))
        return { ok: false, error: "the vgs block's capabilities must be an array" };
    if (raw.barWidget !== undefined && !isPlainObject(raw.barWidget))
        return { ok: false, error: "barWidget must be an object" };
    if (raw.barWidget && raw.barWidget.defaults !== undefined && !isPlainObject(raw.barWidget.defaults))
        return { ok: false, error: "barWidget.defaults must be an object" };
    for (var c = 0; c < capabilities.length; c++) {
        if (CAPABILITIES.indexOf(capabilities[c]) === -1)
            return { ok: false, error: "unknown capability " + JSON.stringify(capabilities[c]) };
    }
    var manifest = JSON.parse(JSON.stringify(raw));
    manifest.vgs = { capabilities: capabilities, budgets: isPlainObject(vgs.budgets) ? vgs.budgets : {} };
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

// Ids placed in the bar layout, in section order.
function layoutIds(config) {
    var ids = [];
    var layout = config && config.bar && isPlainObject(config.bar.layout) ? config.bar.layout : {};
    ["left", "center", "right"].forEach(function (section) {
        (Array.isArray(layout[section]) ? layout[section] : []).forEach(function (entry) {
            if (isPlainObject(entry) && typeof entry.id === "string") ids.push(entry.id);
        });
    });
    return ids;
}

// The active bar id: config.bar.id, or the shipped default bar when absent.
function activeBarId(config, defaultBarId) {
    return config && config.bar && typeof config.bar.id === "string" && config.bar.id.length > 0 ? config.bar.id : defaultBarId;
}

// The settings a plugin receives: its manifest's barWidget.defaults under
// the entry the configuration holds for it. A bar widget's entry is its
// layout entry (`layoutEntry`, passed by the bar); every other kind's entry
// is the `plugins[]` row with its id. Keys the entry sets win.
function settingsFor(config, manifest, layoutEntry) {
    var out = {};
    var defaults = manifest.barWidget && isPlainObject(manifest.barWidget.defaults) ? manifest.barWidget.defaults : {};
    Object.keys(defaults).forEach(function (k) { out[k] = defaults[k]; });
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

// The bar's section entry lists as a string, so a host can tell a layout
// change from a configuration write that left the layout alone.
function layoutKey(config) {
    var layout = config && config.bar && isPlainObject(config.bar.layout) ? config.bar.layout : {};
    return JSON.stringify(SECTIONS.map(function (s) { return Array.isArray(layout[s]) ? layout[s] : []; }));
}

// Whether a plugin is enabled under this configuration.
// - The active bar is enabled.
// - A bar widget is enabled when placed in a bar section.
// - Anything else is enabled when listed in plugins[], and a first-party
//   plugin (id under the `vgs.` prefix) is enabled unless listed in
//   disabledPlugins[].
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
// user object; the caller writes it. A bar widget is placed in its
// manifest's default section when enabled and removed from every section
// when disabled. Enabling a bar makes it the active bar. Because a user
// `bar` key replaces the shipped one whole, a user file without one is
// seeded from the effective bar first, so the edit keeps every other
// widget in place.
function withEnabled(user, manifest, enabled, effective) {
    var out = isPlainObject(user) ? JSON.parse(JSON.stringify(user)) : {};
    if (out.version === undefined) out.version = 1;
    var disabled = Array.isArray(out.disabledPlugins) ? out.disabledPlugins.slice() : [];
    var touchesBar = manifest.kinds.indexOf("bar-widget") !== -1 || (enabled && manifest.kinds.indexOf("bar") !== -1);
    if (touchesBar && !isPlainObject(out.bar))
        out.bar = effective && isPlainObject(effective.bar) ? JSON.parse(JSON.stringify(effective.bar)) : {};
    if (enabled && manifest.kinds.indexOf("bar") !== -1)
        out.bar.id = manifest.id;
    if (manifest.kinds.indexOf("bar-widget") !== -1) {
        if (!isPlainObject(out.bar.layout)) out.bar.layout = { left: [], center: [], right: [] };
        SECTIONS.forEach(function (section) {
            out.bar.layout[section] = (Array.isArray(out.bar.layout[section]) ? out.bar.layout[section] : []).filter(function (entry) {
                return !(isPlainObject(entry) && entry.id === manifest.id);
            });
        });
        if (enabled) {
            var section = manifest.barWidget && typeof manifest.barWidget.defaultSection === "string" ? manifest.barWidget.defaultSection : "center";
            if (SECTIONS.indexOf(section) === -1) section = "center";
            out.bar.layout[section].push({ id: manifest.id });
        }
    }
    if (enabled) {
        disabled = disabled.filter(function (d) { return d !== manifest.id; });
        if (manifest.kinds.indexOf("bar-widget") === -1 && manifest.kinds.indexOf("bar") === -1 && manifest.id.indexOf(FIRST_PARTY_PREFIX) !== 0) {
            var plugins = Array.isArray(out.plugins) ? out.plugins : [];
            if (!plugins.some(function (e) { return isPlainObject(e) && e.id === manifest.id; }))
                plugins.push({ id: manifest.id });
            out.plugins = plugins;
        }
    } else {
        if (disabled.indexOf(manifest.id) === -1) disabled.push(manifest.id);
        if (Array.isArray(out.plugins))
            out.plugins = out.plugins.filter(function (e) { return !(isPlainObject(e) && e.id === manifest.id); });
    }
    out.disabledPlugins = disabled;
    return out;
}
