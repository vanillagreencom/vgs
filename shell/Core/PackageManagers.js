.pragma library

// The package managers VGS knows, one row each, and the pure decisions made
// over them: which managers a system has, the steps an install, a removal
// or an upgrade takes, what a manager's update query printed, and the
// queries naming the package that owns a file and its installed version.
// No QML objects and no I/O, so bin/vgsh-pkg runs this file under node
// through bin/lib/qml-library.js, the one source D034 names, and
// PluginLogic.js imports it to judge a manifest's `requirements` (D035).
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
//             an elevation command: `vgsh pkg run` puts one of ELEVATORS
//             before each step, in a terminal where the user answers the
//             prompt, and the shell process never elevates.
//   check     the unprivileged update queries, the first whose binary is
//             null or the row's binary answering: its argv, the meaning of
//             each exit status ("updates" or "rows": the parser's rows are
//             the updates; "none": there are none), the parser's name in
//             PARSERS, the seconds a run may take, and whether it runs only
//             when asked for by name (onDemand). An unlisted status is a
//             failure. null when no read-only query exists.
//   install, remove, upgrade
//             the steps, each an argv template run in order; null when VGS
//             plans none for the manager
//   owner     the query naming the package that owns a file, or null:
//             { argv, read }, argv a template taking "{path}" and read the
//             pattern whose first group is the package's name in the first
//             line the query prints
//   installed the query naming a package's installed version, or null when
//             VGS asks none of the manager: { argv, read }, argv a template
//             taking "{name}" and read the pattern whose first group is the
//             upstream version, with no epoch and no packaging revision, in
//             the first line the query prints
//   picker    what `vgsh pkg install` and `remove` offer in fzf when no name
//             is given: { install, remove }, each null when VGS offers no
//             picker for the action, else { list, preview }. list prints
//             the packages, one per line, the name first; preview prints
//             one package's details and takes "{name}". Both only read.
// In a template "{bin}" is the row's binary, "{names}" the package names,
// "{name}" one package name and "{path}" an absolute file path. A
// pacman-family sync that refreshes the databases always upgrades too:
// `-Syu`, never `-Sy` alone.
var MANAGERS = [
    {
        id: "pacman", role: "primary", family: ["arch"], requires: null, binaries: ["pacman"], elevate: true,
        check: [{ binary: null, argv: ["checkupdates"], exits: { "0": "updates", "2": "none" }, parser: "arrow", timeout: 120, onDemand: false }],
        install: [["{bin}", "-S", "--needed", "--", "{names}"]],
        remove: [["{bin}", "-Rns", "--", "{names}"]],
        upgrade: [["{bin}", "-Syu"]],
        owner: { argv: ["{bin}", "-Qoq", "{path}"], read: /^(\S+)$/ },
        installed: { argv: ["{bin}", "-Q", "--", "{name}"], read: /^\S+ (?:[0-9]+:)?(\S+)-[^-\s]+$/ },
        picker: {
            install: { list: ["{bin}", "-Slq"], preview: ["{bin}", "-Sii", "{name}"] },
            remove: { list: ["{bin}", "-Qqe"], preview: ["{bin}", "-Qi", "{name}"] }
        }
    },
    {
        id: "aur", role: "overlay", family: [], requires: "pacman", binaries: ["paru", "yay"], elevate: false,
        check: [{ binary: null, argv: ["{bin}", "-Qua"], exits: { "0": "updates", "1": "none" }, parser: "arrow", timeout: 120, onDemand: false }],
        install: [["{bin}", "-S", "--needed", "--", "{names}"]],
        remove: [["{bin}", "-Rns", "--", "{names}"]],
        upgrade: [["{bin}", "-Sua"]],
        owner: null,
        installed: null,
        // pacman's remove picker lists the AUR's packages too, as
        // omarchy-pkg-remove's does.
        picker: { install: { list: ["{bin}", "-Slqa"], preview: ["{bin}", "-Siia", "{name}"] }, remove: null }
    },
    // apt lists what the package lists held at the last `apt update`, which
    // needs root, so the check never refreshes them.
    {
        id: "apt", role: "primary", family: ["debian", "ubuntu"], requires: null, binaries: ["apt-get"], elevate: true,
        check: [{ binary: null, argv: ["apt", "list", "--upgradable"], exits: { "0": "rows" }, parser: "apt", timeout: 120, onDemand: false }],
        install: [["{bin}", "install", "{names}"]],
        remove: [["{bin}", "remove", "{names}"]],
        upgrade: [["{bin}", "update"], ["{bin}", "full-upgrade"]],
        owner: { argv: ["dpkg", "-S", "{path}"], read: /^([a-z0-9][a-z0-9+.-]*)(?::[a-z0-9-]+)?: / },
        installed: { argv: ["dpkg-query", "-W", "--showformat=${Version}\n", "--", "{name}"], read: /^(?:[0-9]+:)?(\S+?)(?:-[^-\s]+)?$/ },
        picker: {
            install: { list: ["apt-cache", "pkgnames"], preview: ["apt-cache", "show", "{name}"] },
            remove: { list: ["apt-mark", "showmanual"], preview: ["dpkg", "-s", "{name}"] }
        }
    },
    {
        id: "dnf", role: "primary", family: ["fedora"], requires: null, binaries: ["dnf5", "dnf"], elevate: true,
        check: [
            { binary: "dnf5", argv: ["{bin}", "check-upgrade", "--json"], exits: { "0": "rows" }, parser: "dnf5", timeout: 120, onDemand: false },
            { binary: "dnf", argv: ["{bin}", "-q", "check-update"], exits: { "0": "none", "100": "updates" }, parser: "dnf", timeout: 120, onDemand: false }
        ],
        install: [["{bin}", "install", "{names}"]],
        remove: [["{bin}", "remove", "{names}"]],
        upgrade: [["{bin}", "upgrade"]],
        owner: { argv: ["rpm", "-qf", "--queryformat", "%{NAME}\n", "{path}"], read: /^(\S+)$/ },
        installed: { argv: ["rpm", "-q", "--queryformat", "%{VERSION}\n", "--", "{name}"], read: /^(\S+)$/ },
        // The format's `\n` is dnf's own escape: dnf5 prints only what the
        // format asks for, and dnf 4 adds a newline of its own, which leaves
        // a blank line the picker drops.
        picker: {
            install: { list: ["{bin}", "repoquery", "--available", "--queryformat", "%{name}\\n"], preview: ["{bin}", "info", "{name}"] },
            remove: { list: ["{bin}", "repoquery", "--userinstalled", "--queryformat", "%{name}\\n"], preview: ["rpm", "-qi", "{name}"] }
        }
    },
    {
        id: "xbps", role: "primary", family: ["void"], requires: null, binaries: ["xbps-install"], elevate: true,
        check: [{ binary: null, argv: ["{bin}", "-Mun"], exits: { "0": "rows" }, parser: "xbps", timeout: 120, onDemand: false }],
        install: [["{bin}", "-S", "{names}"]],
        remove: [["xbps-remove", "-R", "{names}"]],
        upgrade: [["{bin}", "-Su"]],
        owner: { argv: ["xbps-query", "-o", "{path}"], read: /^(\S+)-[^-\s]+_[0-9]+: / },
        installed: null,
        picker: { install: null, remove: null }
    },
    // emerge resolves the whole dependency graph to answer, so its check
    // runs only when asked for by name.
    {
        id: "emerge", role: "primary", family: ["gentoo"], requires: null, binaries: ["emerge"], elevate: true,
        check: [{ binary: null, argv: ["{bin}", "--pretend", "--update", "--deep", "--newuse", "--color=n", "--ask=n", "@world"], exits: { "0": "rows" }, parser: "emerge", timeout: 900, onDemand: true }],
        install: [["{bin}", "--ask", "--noreplace", "{names}"]],
        remove: [["{bin}", "--ask", "--depclean", "{names}"]],
        upgrade: [["{bin}", "--sync"], ["{bin}", "--ask", "--update", "--deep", "--newuse", "@world"]],
        owner: { argv: ["qfile", "{path}"], read: /^(\S+) \(/ },
        installed: null,
        picker: { install: null, remove: null }
    },
    // A NixOS system changes through its own configuration, so VGS plans no
    // step and has no read-only update query for it.
    {
        id: "nix", role: "primary", family: ["nixos"], requires: null, binaries: ["nix"], elevate: false,
        check: null, install: null, remove: null, upgrade: null, owner: null, installed: null,
        picker: { install: null, remove: null }
    },
    {
        id: "flatpak", role: "overlay", family: [], requires: null, binaries: ["flatpak"], elevate: false,
        check: [{ binary: null, argv: ["{bin}", "remote-ls", "--updates", "--columns=application,branch"], exits: { "0": "rows" }, parser: "flatpak", timeout: 120, onDemand: false }],
        install: [["{bin}", "install", "{names}"]],
        remove: [["{bin}", "uninstall", "{names}"]],
        upgrade: [["{bin}", "update"]],
        owner: null,
        installed: null,
        picker: { install: null, remove: null }
    },
    // An upgrade is the user asking for current versions now, so it waives
    // mise's release-age cooldown, as omarchy-update-mise does; the check
    // waives it too, so it counts what the upgrade installs.
    {
        id: "mise", role: "source", family: [], requires: null, binaries: ["mise"], elevate: false,
        check: [{ binary: null, argv: ["env", "MISE_MINIMUM_RELEASE_AGE=0", "{bin}", "outdated", "--json"], exits: { "0": "rows" }, parser: "mise", timeout: 120, onDemand: false }],
        install: [["{bin}", "use", "--global", "{names}"]],
        remove: [["{bin}", "unuse", "--global", "{names}"]],
        upgrade: [["env", "MISE_MINIMUM_RELEASE_AGE=0", "{bin}", "upgrade"]],
        owner: null,
        installed: null,
        picker: { install: null, remove: null }
    }
];

var ACTIONS = ["install", "remove", "upgrade"];

// The commands `vgsh pkg run` may put before a step of a row whose elevate
// is true, in the order it looks for them on PATH. They live outside the
// rows, so the table's steps stay free of any elevation command, and
// PluginLogic.configError judges shell.json's `packages.elevate` against
// this list.
var ELEVATORS = ["sudo", "doas", "run0"];

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

// Manager ID's row and the binary ON_PATH resolves: `{ ok: true, row,
// binary }`, or `{ ok: false, error }` for an unknown manager or one whose
// binaries are all absent.
function presentManager(id, onPath) {
    var row = managerRow(id);
    if (row === null) return { ok: false, error: "manager=" + id + " reason=unknown" };
    var binary = binaryOf(row, onPath);
    if (binary === null) return { ok: false, error: "manager=" + id + " reason=absent binaries=" + row.binaries.join(",") };
    return { ok: true, row: row, binary: binary };
}

// The steps ACTION takes for manager ID over NAMES, with the binary ON_PATH
// resolves: `{ ok: true, plan: { manager, binary, action, elevate, steps } }`
// or `{ ok: false, error }`, the error the keyed first line of a refusal.
// ACTION is one of ACTIONS and NAMES holds at least one name for install
// and remove and none for upgrade; the caller refuses any other call as a
// bad invocation.
function plan(id, action, names, onPath) {
    var found = presentManager(id, onPath);
    if (!found.ok) return found;
    var template = found.row[action];
    if (template === null) return { ok: false, error: "manager=" + id + " action=" + action + " reason=unsupported" };
    for (var i = 0; i < names.length; i++)
        if (!validName(names[i])) return { ok: false, error: "name=" + JSON.stringify(names[i]) + " reason=grammar" };
    var binary = found.binary;
    var row = found.row;
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

// The elevation command a run puts before its steps: CONFIGURED, shell.json's
// `packages.elevate` as configError accepted it, or undefined when unset.
// `{ ok: true, command }` with CONFIGURED when ON_PATH finds it, or else the
// first of ELEVATORS it finds; `{ ok: false, error }` for a configured
// command that is absent or when none is found.
function elevator(configured, onPath) {
    if (configured !== undefined) {
        if (ELEVATORS.indexOf(configured) === -1)
            throw new Error("elevator: packages.elevate " + JSON.stringify(configured) + " passed configError but is not one of " + ELEVATORS.join(", "));
        if (onPath(configured)) return { ok: true, command: configured };
        return { ok: false, error: "elevate=" + configured + " reason=absent source=packages.elevate" };
    }
    for (var i = 0; i < ELEVATORS.length; i++)
        if (onPath(ELEVATORS[i])) return { ok: true, command: ELEVATORS[i] };
    return { ok: false, error: "elevate=none candidates=" + ELEVATORS.join(",") };
}

// Manager ID's picker for ACTION, install or remove, with "{bin}" the binary
// ON_PATH resolves: `{ ok: true, list, preview }`, preview keeping "{name}"
// for the caller to fill, or `{ ok: false, error }` for an unknown or absent
// manager and `manager=<id> picker=<action> reason=unsupported` for one the
// table offers no picker for.
function pickerFor(id, action, onPath) {
    var found = presentManager(id, onPath);
    if (!found.ok) return found;
    var spec = found.row.picker[action];
    if (spec === null) return { ok: false, error: "manager=" + id + " picker=" + action + " reason=unsupported" };
    var fill = function (token) { return token === "{bin}" ? found.binary : token; };
    return { ok: true, list: spec.list.map(fill), preview: spec.preview.map(fill) };
}

// The update parsers, one per output format a check's argv prints. Each maps
// the query's stdout to `{ ok: true, packages }`, each package
// `{ name, old, new }` with old null where the format names no installed
// version, or `{ ok: false, error }` naming the first line it cannot read.
// A line a format does not define is never skipped: a changed format fails
// the check rather than miscounting it.
var ANSI_FREE = /^[^\u001b]*$/;

function lines(text) {
    var out = text.split("\n");
    if (out.length > 0 && out[out.length - 1] === "") out.pop();
    return out;
}

function unreadable(index) {
    return { ok: false, error: "unparseable line=" + (index + 1) };
}

// `name old -> new`: checkupdates, `paru -Qua` and `yay -Qua`. paru marks a
// package pacman's IgnorePkg holds with ` [ignored]`, which the upgrade
// leaves alone, so it is not counted; yay adds the release's age as
// ` [3d4h]`.
function parseArrow(text) {
    var packages = [];
    var rows = lines(text);
    for (var i = 0; i < rows.length; i++) {
        var f = rows[i].split(" ");
        if (!ANSI_FREE.test(rows[i]) || f.length < 4 || f.length > 5 || f[2] !== "->" || f[0] === "" || f[1] === "" || f[3] === "")
            return unreadable(i);
        if (f.length === 5) {
            if (f[4] === "[ignored]") continue;
            if (!/^\[(?:\d+d(?:\d+h)?|\d+h(?:\d+m)?|\d+m)\]$/.test(f[4])) return unreadable(i);
        }
        packages.push({ name: f[0], old: f[1], new: f[3] });
    }
    return { ok: true, packages: packages };
}

// `apt list --upgradable`: a `Listing...` progress line, then
// `name/suite[,suite] new arch [upgradable from: old]`.
function parseApt(text) {
    var packages = [];
    var rows = lines(text);
    for (var i = 0; i < rows.length; i++) {
        if (/^Listing\.\.\.(?: Done)?$/.test(rows[i])) continue;
        var m = /^([^\s\/]+)\/\S+ (\S+) \S+ \[upgradable from: ([^\]\s]+)\]$/.exec(rows[i]);
        if (m === null) return unreadable(i);
        packages.push({ name: m[1], old: m[3], new: m[2] });
    }
    return { ok: true, packages: packages };
}

// `dnf -q check-update` (dnf 4): a blank line, then `name.arch evr repo`,
// where a name longer than its column pushes the rest of the row onto the
// next line. An `Obsoleting Packages` section may follow; its packages are
// already among the upgrades.
function parseDnf(text) {
    var packages = [];
    var rows = lines(text);
    var tokens = [];
    var first = -1;
    for (var i = 0; i < rows.length; i++) {
        if (rows[i] === "Obsoleting Packages") break;
        if (!ANSI_FREE.test(rows[i])) return unreadable(i);
        var words = rows[i].trim().split(/\s+/);
        if (words.length === 1 && words[0] === "") continue;
        for (var w = 0; w < words.length; w++) {
            if (tokens.length === 0) first = i;
            tokens.push(words[w]);
            if (tokens.length < 3) continue;
            var na = /^(.+)\.[^.]+$/.exec(tokens[0]);
            if (na === null) return unreadable(first);
            packages.push({ name: na[1], old: null, new: tokens[1] });
            tokens = [];
        }
    }
    if (tokens.length > 0) return unreadable(first);
    return { ok: true, packages: packages };
}

// `dnf5 check-upgrade --json` (dnf5 5.4.0 and later): an object whose
// `upgrades` array holds `{ name, arch, evr, repository }`. The
// `obsoleting_packages` section repeats upgrades, and an empty section is
// left out.
function parseDnf5(text) {
    var doc;
    try {
        doc = JSON.parse(text);
    } catch (e) {
        return { ok: false, error: "unparseable json" };
    }
    if (doc === null || typeof doc !== "object" || Array.isArray(doc)) return { ok: false, error: "unparseable json" };
    for (var key in doc)
        if (key !== "upgrades" && key !== "obsoleting_packages") return { ok: false, error: "unparseable key=" + key };
    var list = doc.upgrades === undefined ? [] : doc.upgrades;
    if (!Array.isArray(list)) return { ok: false, error: "unparseable key=upgrades" };
    var packages = [];
    for (var i = 0; i < list.length; i++) {
        var p = list[i];
        if (p === null || typeof p !== "object" || typeof p.name !== "string" || p.name === "" || typeof p.evr !== "string" || p.evr === "")
            return { ok: false, error: "unparseable entry=" + i };
        packages.push({ name: p.name, old: null, new: p.evr });
    }
    return { ok: true, packages: packages };
}

// `xbps-install -Mun`: `pkgver action arch repository installed-size
// download-size` per transaction entry. Only `update` is an update; an
// install is a new dependency the update pulls in. pkgver is
// `name-version_revision`, and the installed version is not printed.
function parseXbps(text) {
    var packages = [];
    var rows = lines(text);
    for (var i = 0; i < rows.length; i++) {
        var f = rows[i].split(" ");
        if (f.length !== 6 || !/^\d+$/.test(f[4]) || !/^\d+$/.test(f[5])) return unreadable(i);
        var pv = /^(.+)-([^-]+_\d+)$/.exec(f[0]);
        if (pv === null) return unreadable(i);
        if (f[1] === "update") packages.push({ name: pv[1], old: null, new: pv[2] });
    }
    return { ok: true, packages: packages };
}

// `emerge --pretend`: each merge is `[ebuild FLAGS] cat/pkg-version` or
// `[binary FLAGS] ...`, then the replaced versions in brackets. FLAGS holds
// `U` for a new version. The slot (`:0/0`) and repository (`::gentoo`) are
// shown at --verbose and dropped here, and a binary package may carry its
// build id as a last `-N`, which no version ends with. Every other line is
// emerge's own narration and carries no package.
var GENTOO_VERSION = "\\d+(?:\\.\\d+)*[a-z]?(?:_(?:alpha|beta|pre|rc|p)\\d*)*(?:-r\\d+)?";

function gentooVersion(text) {
    return text.replace(/::.*$/, "").replace(/:[^:]*$/, "");
}

function parseEmerge(text) {
    var packages = [];
    var rows = lines(text);
    var cpv = new RegExp("^(.+?)-(" + GENTOO_VERSION + ")$");
    for (var i = 0; i < rows.length; i++) {
        if (!/^\[(?:ebuild|binary) /.test(rows[i])) continue;
        var m = /^\[(ebuild|binary) ([^\]]*)\]\s+(\S+)(?:\s+\[([^\]]+)\])?/.exec(rows[i]);
        if (m === null) return unreadable(i);
        var shown = gentooVersion(m[3]);
        var nv = m[1] === "binary" ? cpv.exec(shown.replace(/-\d+$/, "")) : null;
        if (nv === null) nv = cpv.exec(shown);
        if (nv === null) return unreadable(i);
        if (m[2].indexOf("U") < 0) continue;
        var old = m[4] === undefined ? null : gentooVersion(m[4].split(", ")[0]);
        packages.push({ name: nv[1], old: old, new: nv[2] });
    }
    return { ok: true, packages: packages };
}

// `flatpak remote-ls --updates --columns=application,branch`: `app<TAB>branch`,
// with no title row when stdout is not a terminal. flatpak prints no
// version here, so the branch stands for the new one.
function parseFlatpak(text) {
    var packages = [];
    var rows = lines(text);
    for (var i = 0; i < rows.length; i++) {
        var f = rows[i].split("\t");
        if (f.length !== 2 || f[0] === "" || f[1] === "" || /\s/.test(f[0] + f[1])) return unreadable(i);
        packages.push({ name: f[0], old: null, new: f[1] });
    }
    return { ok: true, packages: packages };
}

// `mise outdated --json`: an object keyed by tool, each
// `{ current, latest, ... }`, current null for a tool not yet installed.
function parseMise(text) {
    var doc;
    try {
        doc = JSON.parse(text);
    } catch (e) {
        return { ok: false, error: "unparseable json" };
    }
    if (doc === null || typeof doc !== "object" || Array.isArray(doc)) return { ok: false, error: "unparseable json" };
    var packages = [];
    for (var tool in doc) {
        var t = doc[tool];
        if (t === null || typeof t !== "object" || typeof t.latest !== "string" || (t.current !== null && typeof t.current !== "string"))
            return { ok: false, error: "unparseable tool=" + tool };
        packages.push({ name: tool, old: t.current, new: t.latest });
    }
    return { ok: true, packages: packages };
}

var PARSERS = {
    arrow: parseArrow, apt: parseApt, dnf: parseDnf, dnf5: parseDnf5,
    xbps: parseXbps, emerge: parseEmerge, flatpak: parseFlatpak, mise: parseMise
};

// The update query manager ID runs with BINARY, the row's binary, NAMED
// true when the caller asked for this manager by name: `{ check: { argv,
// exits, parser, timeout } }` with "{bin}" filled in, or `{ skipped }`,
// "no-check" when the row has no query for the binary and "on-demand" for
// an on-demand query nobody named.
function checkFor(id, binary, named) {
    var row = managerRow(id);
    var variants = row === null || row.check === null ? [] : row.check;
    for (var i = 0; i < variants.length; i++) {
        var c = variants[i];
        if (c.binary !== null && c.binary !== binary) continue;
        if (c.onDemand && !named) return { skipped: "on-demand" };
        var argv = c.argv.map(function (token) { return token === "{bin}" ? binary : token; });
        return { check: { argv: argv, exits: c.exits, parser: c.parser, timeout: c.timeout } };
    }
    return { skipped: "no-check" };
}

// What CHECK's run printed means: `{ packages }` or `{ error }`. STATUS is
// the exit status and STDOUT the output. A status the check does not list
// is a failure, `exit=<status>`, whatever the output holds.
function checkOutcome(check, status, stdout) {
    var meaning = check.exits[String(status)];
    if (meaning === undefined) return { error: "exit=" + status };
    if (meaning === "none") return { packages: [] };
    var parsed = PARSERS[check.parser](stdout);
    if (!parsed.ok) return { error: parsed.error };
    return { packages: parsed.packages };
}

var QUERIES = ["owner", "installed"];

// The argv of manager ID's QUERY, one of QUERIES, over VALUE: an absolute
// file path for owner, one package name for installed. `{ ok: true, argv }`
// or `{ ok: false, error }`, the error the keyed first line of a refusal.
// "{bin}" is the binary ON_PATH resolves.
function queryArgv(id, query, value, onPath) {
    var row = managerRow(id);
    if (row === null) return { ok: false, error: "manager=" + id + " reason=unknown" };
    var spec = row[query];
    if (spec === null) return { ok: false, error: "manager=" + id + " query=" + query + " reason=unsupported" };
    var placeholder = query === "owner" ? "{path}" : "{name}";
    if (query === "owner" && (typeof value !== "string" || value.charAt(0) !== "/"))
        return { ok: false, error: "path=" + JSON.stringify(value) + " reason=relative" };
    if (query === "installed" && !validName(value)) return { ok: false, error: "name=" + JSON.stringify(value) + " reason=grammar" };
    var needsBinary = spec.argv.indexOf("{bin}") >= 0;
    var binary = needsBinary ? binaryOf(row, onPath) : null;
    if (needsBinary && binary === null)
        return { ok: false, error: "manager=" + id + " reason=absent binaries=" + row.binaries.join(",") };
    var argv = spec.argv.map(function (token) {
        if (token === "{bin}") return binary;
        if (token === placeholder) return value;
        return token;
    });
    return { ok: true, argv: argv };
}

// What manager ID's QUERY printed, read: the first group of its pattern in
// the first line of STDOUT, or null when that line does not match.
function queryAnswer(id, query, stdout) {
    var m = managerRow(id)[query].read.exec(stdout.split("\n")[0]);
    return m === null ? null : m[1];
}
