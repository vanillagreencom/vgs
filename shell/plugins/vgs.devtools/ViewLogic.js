.pragma library

// The Dev Tools plugin's decisions, pure: the commands the service runs and
// when, how it reads each answer, the status values it publishes from them,
// and the sections and rows the panel draws from the published `catalog`.
// Service.qml and Panel.qml hold no rule of their own; each asks here.
// scripts/test-devtools-view.js pins every rule with a control.

// The catalog's sections in the order the panel draws them, after the VGS
// section, each with the title the panel heads it with. `other` is the
// engine's list of global mise tools no row declares. The keys are
// CatalogLogic.SECTION_NAMES plus `other`; the test holds them equal.
// `icon` is the Lucide icon of a row that names none, on a neutral tile:
// the catalog gives the CLI tools and the other mise tools no icon.
var TOOL_SECTIONS = [
    { key: "agents", title: "Agents", description: "Coding agents on the command line", icon: "bot" },
    { key: "apps", title: "Apps", description: "Developer applications", icon: "app-window" },
    { key: "tools", title: "CLI tools", description: "Command-line developer tools", icon: "terminal" },
    { key: "envs", title: "Languages", description: "Language and framework environments", icon: "code" },
    { key: "editors", title: "Editors", description: "Code editors", icon: "file-code" },
    { key: "databases", title: "Databases", description: "Database containers bound to 127.0.0.1", icon: "database" },
    { key: "terminals", title: "Terminals", description: "Terminal emulators", icon: "square-terminal" },
    { key: "other", title: "Other mise tools", description: "Tools your global mise config holds that no row declares", icon: "package" }
];

var VGS_SECTION = { key: "vgs", title: "VGS", description: "How VGS is installed, and every command VGS or an enabled plugin needs that is missing" };

// The commands the service runs, each read-only: `catalog` the engine's
// list, `requirements` the core's doctor report, `vgs` the core's
// self-status, `updates` the mise updates the core's package layer counts,
// and `launchers` the engine's launcher verb the writeLaunchers setting
// picks. `network` marks a command that asks a remote: the release API or
// the upstream checkout for `vgs`, the tool registries for `updates`.
var QUERIES = {
    launchers: { network: false },
    catalog: { network: false },
    requirements: { network: false },
    vgs: { network: true },
    updates: { network: true }
};

// What each trigger runs. `catalog` always follows `launchers` (next), since
// a launcher verb changes what the list reports. `start` is the service's
// first shell, `refresh` the IPC call, `open` the IPC call that summons the
// panel, `tui` the end of a run of one of the plugin's own TUIs and
// `setting` a change of writeLaunchers.
var TRIGGERS = {
    start: ["launchers", "requirements", "vgs", "updates"],
    refresh: ["launchers", "requirements", "vgs", "updates"],
    open: ["launchers", "requirements", "vgs", "updates"],
    tui: ["launchers", "requirements", "updates"],
    setting: ["launchers"]
};

// An `open` asks a remote again only when that query's last answer is
// older than this: a user who opens the panel twice in a minute does not
// query the release API and every tool registry twice. A run of the
// plugin's own TUI and an explicit `refresh` always ask.
var NETWORK_FRESH_MS = 10 * 60 * 1000;

// The plugin's TUI names, as the manifest's `tui` key declares them: one
// per engine verb, and `requirement` for a missing requirement's package.
var VERBS = ["install", "update", "remove"];
var REQUIREMENT_TUI = "requirement";

// The group whose first listed TUI entry updates VGS: the launcher's Update
// row reads the same group (docs/architecture/tui-capability.md).
var UPDATE_GROUP = "Update";

// A status `text` and `state` text are at most this long
// (docs/architecture/status.md).
var STATUS_TEXT_MAX = 200;

var METHOD_LABELS = { checkout: "Git checkout", package: "Package", curl: "Install script", nix: "Nix" };
var ORIGIN_CHIPS = { mise: "mise", installer: "Installer", foreign: "Foreign" };

function hasOwn(object, key) { return Object.prototype.hasOwnProperty.call(object, key); }
function isObject(value) { return value !== null && typeof value === "object" && !Array.isArray(value); }

function sectionOf(key) {
    for (var i = 0; i < TOOL_SECTIONS.length; i++)
        if (TOOL_SECTIONS[i].key === key) return TOOL_SECTIONS[i];
    throw new Error("devtools: section " + JSON.stringify(key) + " is not one of " + TOOL_SECTIONS.map(function (s) { return s.key; }).join(", "));
}

function clip(text) {
    var chars = Array.from(String(text));
    return chars.length <= STATUS_TEXT_MAX ? chars.join("") : chars.slice(0, STATUS_TEXT_MAX - 1).join("") + "…";
}

// The queries TRIGGER runs now: every query the trigger names, less, for
// `open`, a network query whose last answer ended under NETWORK_FRESH_MS
// before NOW. ENDED maps a query name to the time its last answer ended.
function queriesFor(trigger, ended, now) {
    if (!hasOwn(TRIGGERS, trigger)) throw new Error("devtools: trigger " + JSON.stringify(trigger) + " is not one of " + Object.keys(TRIGGERS).join(", "));
    return TRIGGERS[trigger].filter(function (name) {
        if (trigger !== "open" || !QUERIES[name].network) return true;
        return !hasOwn(ended, name) || now - ended[name] >= NETWORK_FRESH_MS;
    });
}

// The query that runs once NAME's answer arrived, or "".
function next(name) {
    return name === "launchers" ? "catalog" : "";
}

// The argv of query NAME: TREE is the VGS tree the shell runs from, PLUGIN
// the plugin's own directory, WRITE the writeLaunchers setting.
function queryArgv(name, tree, plugin, write) {
    var engine = [plugin + "/bin/devtools", "--tree", tree];
    var vgsh = tree + "/bin/vgsh";
    switch (name) {
    case "launchers": return engine.concat(["launchers", write ? "refresh" : "remove"]);
    case "catalog": return engine.concat(["list", "--json"]);
    case "requirements": return [vgsh, "doctor", "--json"];
    case "vgs": return [vgsh, "self", "status", "--json"];
    case "updates": return [vgsh, "pkg", "check", "--json", "--source", "mise"];
    }
    throw new Error("devtools: query " + JSON.stringify(name) + " is not one of " + Object.keys(QUERIES).join(", "));
}

// Why a command failed, from its exit CODE (null when it did not start)
// and its stderr: the value of its first `refused:` line, else its first
// line, else the code.
function failure(code, stderr) {
    if (code === null) return "start=failed";
    var lines = String(stderr).split("\n").filter(function (line) { return line.trim() !== ""; });
    for (var i = 0; i < lines.length; i++) {
        var at = lines[i].indexOf("refused: ");
        if (at !== -1) return clip(lines[i].slice(at + "refused: ".length));
    }
    return lines.length > 0 ? clip(lines[0]) : "exit=" + code;
}

// Whether VALUE has the shape query NAME prints on success.
function shaped(name, value) {
    switch (name) {
    case "catalog":
        return isObject(value) && isObject(value.mise) && typeof value.mise.present === "boolean" && isObject(value.sections)
            && Array.isArray(value.other) && TOOL_SECTIONS.every(function (s) { return s.key === "other" || Array.isArray(value.sections[s.key]); });
    case "requirements":
        return isObject(value) && Array.isArray(value.core) && isObject(value.plugins)
            && Object.keys(value.plugins).every(function (id) { return Array.isArray(value.plugins[id]); });
    case "vgs":
        return isObject(value) && hasOwn(value, "version") && hasOwn(value, "method") && hasOwn(value, "behind") && hasOwn(value, "error");
    case "updates":
        return Array.isArray(value) && value.length === 1 && isObject(value[0]) && value[0].source === "mise";
    }
    throw new Error("devtools: query " + JSON.stringify(name) + " has no shape");
}

// Query NAME's answer from its exit CODE, stdout and stderr: { value,
// error }, `value` null beside an `error`. `launchers` prints lines, not
// JSON; its value is those lines. An `updates` answer whose mise source
// could not be read is that source's error.
function readAnswer(name, code, stdout, stderr) {
    if (code !== 0) return { value: null, error: failure(code, stderr) };
    if (name === "launchers")
        return { value: String(stdout).split("\n").filter(function (line) { return line !== ""; }), error: null };
    var value;
    try {
        value = JSON.parse(stdout);
    } catch (e) {
        return { value: null, error: "unparseable" };
    }
    if (!shaped(name, value)) return { value: null, error: "unparseable" };
    if (name === "updates") {
        var source = value[0];
        if (source.error !== null) return { value: null, error: clip(source.error) };
        return { value: { count: source.count, packages: source.packages }, error: null };
    }
    return { value: value, error: null };
}

// The missing requirements of a doctor report, the core's first and then
// each plugin's in id order: { owner, command, purpose, optional, package },
// `owner` "core" or the plugin id, `package` { manager, name } or null.
function missingRequirements(report) {
    var out = [];
    function add(owner, rows) {
        rows.forEach(function (row) {
            if (row.state !== "missing") return;
            out.push({ owner: owner, command: row.command, purpose: row.purpose, optional: row.optional === true, package: row.package === undefined ? null : row.package });
        });
    }
    add("core", report.core);
    Object.keys(report.plugins).sort().forEach(function (id) { add(id, report.plugins[id]); });
    return out;
}

// Every row the list holds, the sections' then the other tools'.
function listedRows(report) {
    var rows = [];
    TOOL_SECTIONS.forEach(function (section) {
        rows = rows.concat(section.key === "other" ? report.other : report.sections[section.key]);
    });
    return rows;
}

// The `catalog` status value, everything the panel draws: each query's
// answer as { value, error }, null before its first answer. The
// requirements are reduced to the missing ones.
function catalogValue(answers) {
    function pick(name, reduce) {
        if (!hasOwn(answers, name)) return null;
        var a = answers[name];
        return { value: a.value === null ? null : reduce(a.value), error: a.error };
    }
    function same(v) { return v; }
    return {
        tools: pick("catalog", same),
        requirements: pick("requirements", missingRequirements),
        vgs: pick("vgs", same),
        updates: pick("updates", same)
    };
}

// The status values ANSWERS support now, by key, for Service.qml to
// publish: `catalog` always; `mise`, `installed` and `outdated` from the
// list and the mise updates; `missingRequirements` from the doctor report.
// A value no answer supports yet is left out, so Settings reads it as not
// reported rather than as a guess.
function statusValues(answers) {
    var out = { catalog: catalogValue(answers) };
    var tools = answers.catalog;
    if (tools !== undefined) {
        if (tools.value === null) {
            out.mise = { tone: "danger", text: clip("Unknown: the tool list failed: " + tools.error) };
        } else {
            out.mise = tools.value.mise.present ? { tone: "ok", text: clip(tools.value.mise.version) } : { tone: "warning", text: "Not installed" };
            out.installed = listedRows(tools.value).filter(function (row) { return row.installed === true; }).length;
        }
    }
    var updates = answers.updates;
    if (updates !== undefined && updates.value !== null && typeof updates.value.count === "number") out.outdated = updates.value.count;
    var requirements = answers.requirements;
    if (requirements !== undefined && requirements.value !== null) out.missingRequirements = missingRequirements(requirements.value).length;
    return out;
}

// The TUI runs of the plugin's own scripts that ended since SEEN, as names:
// STATE is `shell.tui.state`, SEEN a map of name to the `endedAt` last
// seen. The first reading, SEEN null, reports none: a run that ended
// before the service started is already in the list the service starts
// with.
function endedSince(seen, state) {
    if (seen === null) return [];
    return Object.keys(state).filter(function (name) {
        var at = state[name].endedAt;
        return at !== null && (!hasOwn(seen, name) || seen[name] !== at);
    });
}

// The `endedAt` of each of the plugin's TUIs in STATE, by name.
function endings(state) {
    var out = {};
    Object.keys(state).forEach(function (name) { out[name] = state[name].endedAt; });
    return out;
}

// The arguments shell.tui.run hands verb VERB's script for ROW: a catalog
// row by id, with --channel CHANNEL for an install on a channel other than
// its default, or an other mise tool by --mise and its key.
function verbArgs(verb, row, channel) {
    if (VERBS.indexOf(verb) === -1) throw new Error("devtools: verb " + JSON.stringify(verb) + " is not one of " + VERBS.join(", "));
    if (row.section === "other") return ["--mise", row.id];
    var args = [row.id];
    if (verb === "install" && channel !== "" && Array.isArray(row.channels) && channel !== row.channels[0]) args.push("--channel", channel);
    return args;
}

// The arguments the requirement script hands `vgsh pkg run install` for a
// missing requirement's package.
function requirementArgs(requirement) {
    return ["--manager", requirement.package.manager, requirement.package.name];
}

// The key of the first listed TUI entry of UPDATE_GROUP, or "".
function updateEntry(entries) {
    for (var i = 0; i < entries.length; i++)
        if (entries[i].group === UPDATE_GROUP) return entries[i].key;
    return "";
}

var ACTION_LABELS = { install: "Install", update: "Update", remove: "Remove" };
var ACTION_VARIANTS = { install: "primary", update: "secondary", remove: "danger" };

// One catalog or other-tool ROW as the panel draws it: { key, name, icon,
// brand, tile, secondary, chips, channels, actions, lines }. `tile` is
// "brand", "neutral" or "accent"; `chips` { text, tone }; `actions`
// { kind, verb, label, variant }; `channels` the choices a Select offers,
// empty for none. WRITE is the writeLaunchers setting: a foreign launcher
// is named only while VGS would write one.
function toolRow(section, row, write) {
    var branded = section !== "other" && row.icon !== null && row.brand !== null;
    var out = {
        key: section + "/" + row.id,
        section: section,
        id: row.id,
        name: section === "other" ? row.id : row.name,
        icon: branded ? row.icon : sectionOf(section).icon,
        brand: branded ? row.brand : "",
        tile: branded ? "brand" : "neutral",
        secondary: "",
        chips: [],
        channels: [],
        actions: [],
        lines: []
    };
    if (row.installed === null) {
        out.secondary = "State unknown";
        out.chips.push({ text: "Unknown", tone: "danger" });
        out.lines.push(clip(row.error));
    } else if (row.installed) {
        out.secondary = row.version === null ? "Installed" : row.version;
        if (row.origin === "foreign") out.secondary += " · Managed outside VGS";
        if (row.origin === "managedBy") out.secondary += " · Managed by the " + row.package + " package";
        var chip = hasOwn(ORIGIN_CHIPS, row.origin) ? ORIGIN_CHIPS[row.origin] : row.origin === "container" ? row.runtime : row.manager;
        if (chip !== null && chip !== undefined) out.chips.push({ text: chip, tone: row.origin === "foreign" ? "warning" : "neutral" });
    } else {
        out.secondary = row.actions.length === 0 ? "Not installed · Not offered on this system" : "Not installed";
    }
    if (write && row.launcher === "foreign") out.lines.push("Its launcher in ~/.local/bin is managed outside VGS");
    if (section !== "other" && Array.isArray(row.channels) && row.channels.length > 1 && row.actions.indexOf("install") !== -1) out.channels = row.channels;
    VERBS.forEach(function (verb) {
        if (row.actions.indexOf(verb) !== -1) out.actions.push({ kind: "verb", verb: verb, label: ACTION_LABELS[verb], variant: ACTION_VARIANTS[verb] });
    });
    return out;
}

// The VGS row: the install method and version from the self-status ANSWER,
// with an Update action while it is behind and ENTRY, the Update group's
// first TUI key, is listed.
function vgsRow(answer, entry) {
    var out = { key: "vgs/self", section: "vgs", id: "self", name: "VGS", icon: "layers", brand: "", tile: "accent", secondary: "", chips: [], channels: [], actions: [], lines: [] };
    if (answer === null) {
        out.secondary = "Checking";
        return out;
    }
    if (answer.value === null) {
        out.secondary = "State unknown";
        out.chips.push({ text: "Unknown", tone: "danger" });
        out.lines.push("vgsh self status failed: " + answer.error);
        return out;
    }
    var s = answer.value;
    var method = s.method === null ? "Unknown install" : hasOwn(METHOD_LABELS, s.method) ? METHOD_LABELS[s.method] : s.method;
    if (s.method === "package" && s.package !== null) method += " " + s.package;
    out.secondary = (s.current !== null ? s.current : s.version) + " · " + method;
    if (s.behind === true) {
        out.chips.push({ text: s.latest === null ? "Update available" : "Update to " + s.latest, tone: "warning" });
        if (entry !== "") out.actions.push({ kind: "entry", verb: entry, label: "Update", variant: "primary" });
        else out.lines.push("Enable a plugin with an Update entry, such as Updates, to update VGS from here");
    } else if (s.behind === false) {
        out.chips.push({ text: "Up to date", tone: "success" });
    } else {
        out.chips.push({ text: "Unknown", tone: "neutral" });
    }
    if (s.error !== null) out.lines.push(clip(s.error));
    return out;
}

// One missing requirement as a row, with Install when this system has a
// package for it.
function requirementRow(requirement, index) {
    var out = {
        key: "vgs/requirement/" + index + "/" + requirement.owner + "/" + requirement.command,
        section: "vgs",
        id: requirement.command,
        name: requirement.command,
        icon: "package",
        brand: "",
        tile: "neutral",
        secondary: (requirement.owner === "core" ? "VGS" : requirement.owner) + " · " + requirement.purpose,
        chips: [{ text: "Missing", tone: requirement.optional ? "neutral" : "warning" }],
        channels: [],
        actions: [],
        lines: [],
        requirement: requirement
    };
    if (requirement.optional) out.chips.push({ text: "Optional", tone: "neutral" });
    if (requirement.package === null) out.lines.push("No package on this system provides it; install " + requirement.command + " by hand");
    else out.actions.push({ kind: "requirement", verb: REQUIREMENT_TUI, label: "Install", variant: "primary" });
    return out;
}

// Every section the panel draws from CATALOG, the published `catalog`
// value, or [] before the service published one: { key, title,
// description, rows, lines }. ENTRY is the Update group's first TUI key, ""
// for none; WRITE the writeLaunchers setting. A query that failed puts its
// error under the section it feeds.
function sections(catalog, entry, write) {
    if (catalog === null || catalog === undefined) return [];
    var vgs = { key: VGS_SECTION.key, title: VGS_SECTION.title, description: VGS_SECTION.description, rows: [vgsRow(catalog.vgs, entry)], lines: [] };
    var req = catalog.requirements;
    if (req !== null && req.value === null) vgs.lines.push("vgsh doctor failed: " + req.error);
    else if (req !== null && req.value.length === 0) vgs.lines.push("Every requirement is met");
    else if (req !== null) vgs.rows = vgs.rows.concat(req.value.map(requirementRow));
    var out = [vgs];
    var tools = catalog.tools;
    TOOL_SECTIONS.forEach(function (section) {
        var drawn = { key: section.key, title: section.title, description: section.description, rows: [], lines: [] };
        if (tools === null) drawn.lines.push("Listing");
        else if (tools.value === null) drawn.lines.push("The tool list failed: " + tools.error);
        else drawn.rows = (section.key === "other" ? tools.value.other : tools.value.sections[section.key]).map(function (row) { return toolRow(section.key, row, write); });
        if (drawn.rows.length > 0 || drawn.lines.length > 0) out.push(drawn);
    });
    return out;
}

// The panel's summary line from CATALOG: what mise reports, how many tools
// are installed and how many mise can update.
function summary(catalog) {
    if (catalog === null || catalog === undefined || catalog.tools === null) return "Listing tools";
    var parts = [];
    var tools = catalog.tools.value;
    if (tools === null) return "The tool list failed";
    parts.push(tools.mise.present ? "mise " + tools.mise.version : "mise is not installed");
    parts.push(listedRows(tools).filter(function (row) { return row.installed === true; }).length + " installed");
    var updates = catalog.updates;
    if (updates !== null && updates.value !== null) parts.push(updates.value.count + (updates.value.count === 1 ? " update" : " updates"));
    return parts.join(" · ");
}

var RUN_LABELS = { install: "An install", update: "An update", remove: "A removal", requirement: "A requirement install" };

// One line per TUI of the plugin whose run is live in STATE,
// `shell.tui.state`, in RUN_LABELS order.
function runningLines(state) {
    return Object.keys(RUN_LABELS).filter(function (name) {
        return hasOwn(state, name) && state[name].running === true;
    }).map(function (name) {
        return RUN_LABELS[name] + " runs in its window; the list refreshes when it ends";
    });
}

// The line the panel shows for the REPLY a TUI request answered: none for
// `ok`, and none for `busy`, whose answer is the live run's window raised.
function replyLine(reply) {
    if (reply === "ok" || /^refused: tui=\S+ reason=busy$/.test(reply)) return "";
    return clip(reply);
}
