.pragma library

// The package managers VGS knows, one row each, and the pure decisions made
// over them: which managers a system has and the steps an install, a removal
// or an upgrade takes. No QML objects and no I/O, so bin/vgsh-pkg runs this
// file under node through bin/lib/qml-library.js, the one source D034 names,
// and PluginLogic.js imports it to judge a manifest's `requirements` (D035).
//
// A row:
//   id        the manager's name in every VGS file and command
//   role      "primary": the distribution's own manager, at most one per
//             system; "overlay": a second package source beside it;
//             "source": a user-level tool source
//   family    the os-release ID values a primary serves, matched against ID
//             and then each ID_LIKE token
//   requires  the primary an overlay only exists beside, or null
//   binaries  the commands that run the manager, preferred first; the first
//             one on PATH is the row's binary
//   elevate   whether install, remove and upgrade need root. No step names
//             an elevation command: the shell never elevates, and a step
//             runs only in a terminal where the user answers the prompt.
//   check     the unprivileged update query: its argv, the meaning of each
//             exit status ("updates", "none", or "rows": the parser's rows
//             are the updates) and the parser's name; an unlisted status is
//             a failure. null when no read-only query exists.
//   install, remove, upgrade
//             the steps, each an argv template run in order; null when VGS
//             plans none for the manager
//   owner     the argv template naming the package that owns a file, or null
// In a template "{bin}" is the row's binary, "{names}" the package names and
// "{path}" an absolute file path. A pacman-family sync that refreshes the
// databases always upgrades too: `-Syu`, never `-Sy` alone.
var MANAGERS = [
    {
        id: "pacman", role: "primary", family: ["arch"], requires: null, binaries: ["pacman"], elevate: true,
        check: { argv: ["checkupdates"], exits: { "0": "updates", "2": "none" }, parser: "arrow" },
        install: [["{bin}", "-S", "--needed", "--", "{names}"]],
        remove: [["{bin}", "-Rns", "--", "{names}"]],
        upgrade: [["{bin}", "-Syu"]],
        owner: ["{bin}", "-Qoq", "{path}"]
    },
    {
        id: "aur", role: "overlay", family: [], requires: "pacman", binaries: ["paru", "yay"], elevate: false,
        check: { argv: ["{bin}", "-Qua"], exits: { "0": "updates", "1": "none" }, parser: "arrow" },
        install: [["{bin}", "-S", "--needed", "--", "{names}"]],
        remove: [["{bin}", "-Rns", "--", "{names}"]],
        upgrade: [["{bin}", "-Sua"]],
        owner: null
    },
    {
        id: "apt", role: "primary", family: ["debian", "ubuntu"], requires: null, binaries: ["apt-get"], elevate: true,
        check: { argv: ["apt", "list", "--upgradable"], exits: { "0": "rows" }, parser: "apt" },
        install: [["{bin}", "install", "{names}"]],
        remove: [["{bin}", "remove", "{names}"]],
        upgrade: [["{bin}", "update"], ["{bin}", "full-upgrade"]],
        owner: ["dpkg", "-S", "{path}"]
    },
    {
        id: "dnf", role: "primary", family: ["fedora"], requires: null, binaries: ["dnf5", "dnf"], elevate: true,
        check: { argv: ["{bin}", "check-update"], exits: { "0": "none", "100": "updates" }, parser: "dnf" },
        install: [["{bin}", "install", "{names}"]],
        remove: [["{bin}", "remove", "{names}"]],
        upgrade: [["{bin}", "upgrade"]],
        owner: ["rpm", "-qf", "{path}"]
    },
    {
        id: "xbps", role: "primary", family: ["void"], requires: null, binaries: ["xbps-install"], elevate: true,
        check: { argv: ["{bin}", "-Mun"], exits: { "0": "rows" }, parser: "xbps" },
        install: [["{bin}", "-S", "{names}"]],
        remove: [["xbps-remove", "-R", "{names}"]],
        upgrade: [["{bin}", "-Su"]],
        owner: ["xbps-query", "-o", "{path}"]
    },
    {
        id: "emerge", role: "primary", family: ["gentoo"], requires: null, binaries: ["emerge"], elevate: true,
        check: { argv: ["{bin}", "--pretend", "--update", "--deep", "--newuse", "@world"], exits: { "0": "rows" }, parser: "emerge" },
        install: [["{bin}", "--ask", "--noreplace", "{names}"]],
        remove: [["{bin}", "--ask", "--depclean", "{names}"]],
        upgrade: [["{bin}", "--sync"], ["{bin}", "--ask", "--update", "--deep", "--newuse", "@world"]],
        owner: ["qfile", "{path}"]
    },
    // A NixOS system changes through its own configuration, so VGS plans no
    // step and has no read-only update query for it.
    {
        id: "nix", role: "primary", family: ["nixos"], requires: null, binaries: ["nix"], elevate: false,
        check: null, install: null, remove: null, upgrade: null, owner: null
    },
    {
        id: "flatpak", role: "overlay", family: [], requires: null, binaries: ["flatpak"], elevate: false,
        check: { argv: ["{bin}", "remote-ls", "--updates", "--columns=application,branch"], exits: { "0": "rows" }, parser: "flatpak" },
        install: [["{bin}", "install", "{names}"]],
        remove: [["{bin}", "uninstall", "{names}"]],
        upgrade: [["{bin}", "update"]],
        owner: null
    },
    // An upgrade is the user asking for current versions now, so it waives
    // mise's release-age cooldown, as omarchy-update-mise does.
    {
        id: "mise", role: "source", family: [], requires: null, binaries: ["mise"], elevate: false,
        check: { argv: ["{bin}", "outdated", "--json"], exits: { "0": "rows" }, parser: "mise" },
        install: [["{bin}", "use", "--global", "{names}"]],
        remove: [["{bin}", "unuse", "--global", "{names}"]],
        upgrade: [["env", "MISE_MINIMUM_RELEASE_AGE=0", "{bin}", "upgrade"]],
        owner: null
    }
];

var ACTIONS = ["install", "remove", "upgrade"];

// A package name is printable ASCII with no space, and never starts with a
// dash, so no manager reads it as an option.
var NAME_PATTERN = /^[!-~]{1,256}$/;
// A command is a bare file name looked up on PATH, never a path.
var COMMAND_PATTERN = /^[A-Za-z0-9_+][A-Za-z0-9._+-]{0,127}$/;

function managerRow(id) {
    for (var i = 0; i < MANAGERS.length; i++)
        if (MANAGERS[i].id === id) return MANAGERS[i];
    return null;
}

function validName(name) {
    return typeof name === "string" && NAME_PATTERN.test(name) && name.charAt(0) !== "-";
}

function validCommand(command) {
    return typeof command === "string" && COMMAND_PATTERN.test(command);
}

// The value os-release(5) assigns KEY, or null. A value may be quoted with
// double or single quotes; inside double quotes a backslash escapes `\`,
// `"`, `$` and a backtick. The last assignment wins, as in a shell.
function osReleaseValue(text, key) {
    var value = null;
    var lines = text.split("\n");
    for (var i = 0; i < lines.length; i++) {
        var m = /^([A-Z][A-Z0-9_]*)=(.*)$/.exec(lines[i].trim());
        if (m === null || m[1] !== key) continue;
        var raw = m[2];
        var quote = raw.charAt(0);
        if (raw.length >= 2 && (quote === "\"" || quote === "'") && raw.charAt(raw.length - 1) === quote) {
            raw = raw.slice(1, -1);
            if (quote === "\"") raw = raw.replace(/\\([\\"$`])/g, "$1");
        }
        value = raw;
    }
    return value;
}

// The system's os-release identifiers, most specific first: ID, then each
// ID_LIKE token in order. Empty for an empty or unknown file.
function osReleaseIds(text) {
    var out = [];
    var id = osReleaseValue(text, "ID");
    if (id !== null && id !== "") out.push(id);
    var like = osReleaseValue(text, "ID_LIKE");
    if (like !== null) {
        var tokens = like.split(/\s+/);
        for (var i = 0; i < tokens.length; i++)
            if (tokens[i] !== "" && out.indexOf(tokens[i]) < 0) out.push(tokens[i]);
    }
    return out;
}

// ROW's first binary ON_PATH answers true for, or null.
function binaryOf(row, onPath) {
    for (var i = 0; i < row.binaries.length; i++)
        if (onPath(row.binaries[i])) return row.binaries[i];
    return null;
}

// The system's managers: `{ primary, overlays, sources }`, each entry
// `{ id, binary }`. The primary is the first row, taking the os-release
// identifiers OS_IDS in order, whose family holds one and whose binary is
// on PATH; null when none is. An overlay or source is present when its
// binary is, and an overlay that requires a primary only beside it.
function detect(osIds, onPath) {
    var primary = null;
    for (var i = 0; i < osIds.length && primary === null; i++) {
        for (var j = 0; j < MANAGERS.length; j++) {
            var row = MANAGERS[j];
            if (row.role !== "primary" || row.family.indexOf(osIds[i]) < 0) continue;
            var binary = binaryOf(row, onPath);
            if (binary !== null) {
                primary = { id: row.id, binary: binary };
                break;
            }
        }
    }
    var overlays = [];
    var sources = [];
    for (var k = 0; k < MANAGERS.length; k++) {
        var other = MANAGERS[k];
        if (other.role === "primary") continue;
        if (other.requires !== null && (primary === null || primary.id !== other.requires)) continue;
        var found = binaryOf(other, onPath);
        if (found === null) continue;
        (other.role === "overlay" ? overlays : sources).push({ id: other.id, binary: found });
    }
    return { primary: primary, overlays: overlays, sources: sources };
}

// The package that provides one requirement on this system, as `{ manager,
// name }`: the first manager of FOUND, detect's answer, taken primary, then
// each overlay, then each source, that PACKAGES maps to a name; null when
// it maps none of them. PACKAGES is a requirement's `packages`, manager ids
// to package names, as PluginLogic.requirementsError accepts it.
function packageFor(packages, found) {
    var order = (found.primary === null ? [] : [found.primary]).concat(found.overlays, found.sources);
    for (var i = 0; i < order.length; i++)
        if (Object.prototype.hasOwnProperty.call(packages, order[i].id))
            return { manager: order[i].id, name: packages[order[i].id] };
    return null;
}

// The steps ACTION takes for manager ID over NAMES, with the binary ON_PATH
// resolves: `{ ok: true, plan: { manager, binary, action, elevate, steps } }`
// or `{ ok: false, error }`, the error the keyed first line of a refusal.
// ACTION is one of ACTIONS and NAMES holds at least one name for install
// and remove and none for upgrade; the caller refuses any other call as a
// bad invocation.
function plan(id, action, names, onPath) {
    var row = managerRow(id);
    if (row === null) return { ok: false, error: "manager=" + id + " reason=unknown" };
    var template = row[action];
    if (template === null) return { ok: false, error: "manager=" + id + " action=" + action + " reason=unsupported" };
    for (var i = 0; i < names.length; i++)
        if (!validName(names[i])) return { ok: false, error: "name=" + JSON.stringify(names[i]) + " reason=grammar" };
    var binary = binaryOf(row, onPath);
    if (binary === null) return { ok: false, error: "manager=" + id + " reason=absent binaries=" + row.binaries.join(",") };
    var steps = template.map(function (step) {
        var argv = [];
        for (var j = 0; j < step.length; j++) {
            if (step[j] === "{bin}") argv.push(binary);
            else if (step[j] === "{names}") argv.push.apply(argv, names);
            else argv.push(step[j]);
        }
        return argv;
    });
    return { ok: true, plan: { manager: id, binary: binary, action: action, elevate: row.elevate, steps: steps } };
}
