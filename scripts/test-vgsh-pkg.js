#!/usr/bin/env node
// The package-manager table, shell/Core/PackageManagers.js, and its CLI,
// bin/vgsh-pkg with the `vgsh pkg` verb (D034). Every expected value below
// was written by hand from the managers' own argv, never read from the table.
//
// - The shipped table is judged: unique ids, known roles and placeholders,
//   no step names an elevation command, and no pacman-family step refreshes
//   the databases without upgrading (`-Sy` alone).
// - Detection runs over os-release texts and sets of commands on PATH.
// - Plans pin each manager's argv for install, remove and upgrade, and the
//   pickers each manager's list and preview queries; a preview word holds
//   no fzf placeholder. The elevation commands, their order and the choice
//   a run makes over them are pinned; bin/vgsh-pkg's `run` and pickers are
//   scripts/test-vgsh-pkg-run.sh's.
// - packageFor picks a requirement's package for a detected system.
// - Each update parser reads the canned outputs under scripts/fixtures/pkg/
//   and inline odd lines; each manager's update query and the meaning of
//   its exit statuses are pinned. No row touches the network.
// - The owner and installed queries pin each manager's argv and read each
//   manager's output, written from its documentation, into a name or a
//   version.
// - The CLI runs with a PATH of stub commands; `detect`, `owner` and a
//   `check` without --source read a fixture os-release bound over
//   /etc/os-release under `unshare -rm`. Without user namespaces those rows cannot run and
//   the suite exits 77.
//
// The controls at the end edit a copy of the table, bin/vgsh-pkg or
// bin/vgsh, one rule at a time, and require this suite to fail on each copy.
"use strict";
const childProcess = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { load } = require("../bin/lib/qml-library.js");

const repo = path.join(__dirname, "..");
const TABLE = path.join(repo, "shell", "Core", "PackageManagers.js");
const PKG = path.join(repo, "bin", "vgsh-pkg");
const VGSH = path.join(repo, "bin", "vgsh");
const ELEVATORS = ["sudo", "doas", "run0", "pkexec", "su"];
const PLACEHOLDERS = ["{bin}", "{names}", "{name}", "{path}"];
const EXIT_MEANINGS = ["updates", "none", "rows"];
const FIXTURES = path.join(repo, "scripts", "fixtures", "pkg");

// The table's own defects, one string each; empty for a sound table.
function tableErrors(t) {
    const errors = [];
    const ids = t.MANAGERS.map(row => row.id);
    if (t.MANAGERS.length < 9) errors.push("table: fewer than the nine managers D034 names; the loader read no table");
    if (new Set(ids).size !== ids.length) errors.push("ids: not unique");
    for (const row of t.MANAGERS) {
        const where = "manager " + row.id;
        if (!["primary", "overlay", "source"].includes(row.role)) errors.push(where + ": role " + row.role);
        if ((row.role === "primary") !== (row.family.length > 0)) errors.push(where + ": a family belongs to a primary alone");
        if (row.requires !== null && !t.MANAGERS.some(o => o.id === row.requires && o.role === "primary")) errors.push(where + ": requires names no primary");
        if (row.binaries.length === 0) errors.push(where + ": no binary");
        const pacmanFamily = row.binaries.some(b => ["pacman", "paru", "yay"].includes(b));
        const templates = [];
        for (const action of t.ACTIONS) if (row[action] !== null) for (const step of row[action]) templates.push([action, step]);
        for (const query of t.QUERIES) {
            if (row[query] === null) continue;
            templates.push([query, row[query].argv]);
            if (Object.prototype.toString.call(row[query].read) !== "[object RegExp]") errors.push(where + " " + query + ": read is no pattern");
        }
        for (const action of ["install", "remove"]) {
            const spec = row.picker[action];
            if (spec === null) continue;
            templates.push(["list", spec.list], ["preview", spec.preview]);
            // fzf substitutes every brace expression in a preview string, so
            // a preview word that is no placeholder the table fills holds none.
            for (const token of spec.preview) if (!PLACEHOLDERS.includes(token) && /[{}]/.test(token)) errors.push(where + " picker " + action + ": brace in preview word " + token);
        }
        if (row.check !== null && (!Array.isArray(row.check) || row.check.length === 0)) errors.push(where + ": check is neither null nor a list of queries");
        else if (row.check !== null) row.check.forEach((c, i) => {
            const at = where + " check " + i;
            templates.push(["check", c.argv]);
            if (c.binary !== null && !row.binaries.includes(c.binary)) errors.push(at + ": binary " + c.binary + " is not one of the row's");
            if (!Object.prototype.hasOwnProperty.call(t.PARSERS, c.parser)) errors.push(at + ": parser " + c.parser);
            if (!Number.isInteger(c.timeout) || c.timeout <= 0) errors.push(at + ": timeout " + c.timeout);
            if (typeof c.onDemand !== "boolean") errors.push(at + ": onDemand " + c.onDemand);
            if (Object.keys(c.exits).length === 0) errors.push(at + ": no exit status");
            for (const [code, meaning] of Object.entries(c.exits))
                if (!/^[0-9]+$/.test(code) || !EXIT_MEANINGS.includes(meaning)) errors.push(at + ": exit " + code + "=" + meaning);
        });
        for (const [action, step] of templates) {
            if (step.length === 0) errors.push(where + " " + action + ": empty step");
            for (const token of step) {
                if (token.startsWith("{") && !PLACEHOLDERS.includes(token)) errors.push(where + " " + action + ": placeholder " + token);
                if (ELEVATORS.includes(token)) errors.push(where + " " + action + ": elevation command " + token);
                if (pacmanFamily && /^-[A-Za-z]*S[A-Za-z]*$/.test(token) && token.includes("y") && !token.includes("u"))
                    errors.push(where + " " + action + ": partial upgrade " + token);
            }
            const names = step.filter(token => token === "{names}").length;
            if (action === "install" || action === "remove") { if (names > 1) errors.push(where + " " + action + ": {names} twice"); }
            else if (names > 0) errors.push(where + " " + action + ": {names} outside install and remove");
            if (step.includes("{path}") !== (action === "owner")) errors.push(where + " " + action + ": {path} belongs to the owner query");
            if (step.includes("{name}") !== (action === "installed" || action === "preview")) errors.push(where + " " + action + ": {name} belongs to the installed query and a picker's preview");
        }
        for (const action of ["install", "remove"])
            if (row[action] !== null && !row[action].some(step => step.includes("{names}"))) errors.push(where + " " + action + ": no step takes the names");
    }
    return errors;
}

// Detection rows: name, os-release text, the commands on PATH, the answer.
const pacman = { id: "pacman", binary: "pacman" };
const DETECT_ROWS = [
    ["Arch with paru, flatpak and mise", "NAME=\"Arch Linux\"\nID=arch\n", ["pacman", "paru", "flatpak", "mise"],
        { primary: pacman, overlays: [{ id: "aur", binary: "paru" }, { id: "flatpak", binary: "flatpak" }], sources: [{ id: "mise", binary: "mise" }] }],
    ["an Arch derivative through ID_LIKE, with yay", "ID=cachyos\nID_LIKE=arch\n", ["pacman", "yay"],
        { primary: pacman, overlays: [{ id: "aur", binary: "yay" }], sources: [] }],
    ["paru is preferred to yay", "ID=endeavouros\nID_LIKE=arch\n", ["pacman", "yay", "paru"],
        { primary: pacman, overlays: [{ id: "aur", binary: "paru" }], sources: [] }],
    ["Ubuntu through its own ID", "ID=ubuntu\nID_LIKE=debian\n", ["apt-get", "flatpak"],
        { primary: { id: "apt", binary: "apt-get" }, overlays: [{ id: "flatpak", binary: "flatpak" }], sources: [] }],
    ["an Ubuntu derivative through a quoted ID_LIKE list", "ID=linuxmint\nID_LIKE=\"ubuntu debian\"\n", ["apt-get"],
        { primary: { id: "apt", binary: "apt-get" }, overlays: [], sources: [] }],
    ["Fedora prefers dnf5; an AUR helper without pacman is no overlay", "ID=fedora\n", ["dnf5", "dnf", "paru"],
        { primary: { id: "dnf", binary: "dnf5" }, overlays: [], sources: [] }],
    ["a Fedora derivative with dnf alone", "ID=\"rocky\"\nID_LIKE=\"rhel centos fedora\"\n", ["dnf"],
        { primary: { id: "dnf", binary: "dnf" }, overlays: [], sources: [] }],
    ["Void", "ID=\"void\"\n", ["xbps-install"], { primary: { id: "xbps", binary: "xbps-install" }, overlays: [], sources: [] }],
    ["Gentoo", "ID=gentoo\n", ["emerge"], { primary: { id: "emerge", binary: "emerge" }, overlays: [], sources: [] }],
    ["NixOS", "ID=nixos\n", ["nix"], { primary: { id: "nix", binary: "nix" }, overlays: [], sources: [] }],
    ["a binary alone makes no primary", "ID=arch\n", ["apt-get"], { primary: null, overlays: [], sources: [] }],
    ["no os-release keeps overlays and sources", "", ["pacman", "paru", "flatpak", "mise"],
        { primary: null, overlays: [{ id: "flatpak", binary: "flatpak" }], sources: [{ id: "mise", binary: "mise" }] }],
    ["an unknown family has no primary", "ID=opensuse-tumbleweed\nID_LIKE=\"opensuse suse\"\n", ["zypper"], { primary: null, overlays: [], sources: [] }],
    ["a single-quoted ID", "ID='arch'\n", ["pacman"], { primary: pacman, overlays: [], sources: [] }],
    ["the last assignment wins; a comment assigns nothing", "# ID=gentoo\nID=debian\nID=arch\n", ["pacman", "apt-get"], { primary: pacman, overlays: [], sources: [] }],
    ["a CRLF file", "ID=arch\r\nNAME=x\r\n", ["pacman"], { primary: pacman, overlays: [], sources: [] }]
];

// os-release identifier rows: name, text, the identifiers in order.
const ID_ROWS = [
    ["ID then each ID_LIKE token", "ID=a\nID_LIKE=\"b  c\"\n", ["a", "b", "c"]],
    ["an escaped quote inside double quotes", "ID=\"a\\\"b\"\n", ["a\"b"]],
    ["ID_LIKE without ID", "ID_LIKE=arch\n", ["arch"]],
    ["an empty file", "", []]
];

// Plan rows: name, manager, action, names, the commands on PATH, and the
// plan's binary, elevate and steps, or the refusal's first line.
const PLAN_ROWS = [
    ["pacman install", "pacman", "install", ["gum", "fzf"], ["pacman"], { binary: "pacman", elevate: true, steps: [["pacman", "-S", "--needed", "--", "gum", "fzf"]] }],
    ["pacman remove", "pacman", "remove", ["gum"], ["pacman"], { binary: "pacman", elevate: true, steps: [["pacman", "-Rns", "--", "gum"]] }],
    ["pacman upgrade is a full -Syu", "pacman", "upgrade", [], ["pacman"], { binary: "pacman", elevate: true, steps: [["pacman", "-Syu"]] }],
    ["aur install through paru", "aur", "install", ["gum-bin"], ["paru", "yay"], { binary: "paru", elevate: false, steps: [["paru", "-S", "--needed", "--", "gum-bin"]] }],
    ["aur install through yay", "aur", "install", ["gum-bin"], ["yay"], { binary: "yay", elevate: false, steps: [["yay", "-S", "--needed", "--", "gum-bin"]] }],
    ["aur remove", "aur", "remove", ["gum-bin"], ["paru"], { binary: "paru", elevate: false, steps: [["paru", "-Rns", "--", "gum-bin"]] }],
    ["aur upgrade", "aur", "upgrade", [], ["paru"], { binary: "paru", elevate: false, steps: [["paru", "-Sua"]] }],
    ["apt install", "apt", "install", ["gum"], ["apt-get"], { binary: "apt-get", elevate: true, steps: [["apt-get", "install", "gum"]] }],
    ["apt remove", "apt", "remove", ["gum"], ["apt-get"], { binary: "apt-get", elevate: true, steps: [["apt-get", "remove", "gum"]] }],
    ["apt upgrade refreshes, then upgrades", "apt", "upgrade", [], ["apt-get"], { binary: "apt-get", elevate: true, steps: [["apt-get", "update"], ["apt-get", "full-upgrade"]] }],
    ["dnf install through dnf5", "dnf", "install", ["gum"], ["dnf5", "dnf"], { binary: "dnf5", elevate: true, steps: [["dnf5", "install", "gum"]] }],
    ["dnf remove through dnf", "dnf", "remove", ["gum"], ["dnf"], { binary: "dnf", elevate: true, steps: [["dnf", "remove", "gum"]] }],
    ["dnf upgrade", "dnf", "upgrade", [], ["dnf"], { binary: "dnf", elevate: true, steps: [["dnf", "upgrade"]] }],
    ["xbps install", "xbps", "install", ["gum"], ["xbps-install"], { binary: "xbps-install", elevate: true, steps: [["xbps-install", "-S", "gum"]] }],
    ["xbps remove", "xbps", "remove", ["gum"], ["xbps-install"], { binary: "xbps-install", elevate: true, steps: [["xbps-remove", "-R", "gum"]] }],
    ["xbps upgrade", "xbps", "upgrade", [], ["xbps-install"], { binary: "xbps-install", elevate: true, steps: [["xbps-install", "-Su"]] }],
    ["emerge install", "emerge", "install", ["app-misc/gum"], ["emerge"], { binary: "emerge", elevate: true, steps: [["emerge", "--ask", "--noreplace", "app-misc/gum"]] }],
    ["emerge remove", "emerge", "remove", ["app-misc/gum"], ["emerge"], { binary: "emerge", elevate: true, steps: [["emerge", "--ask", "--depclean", "app-misc/gum"]] }],
    ["emerge upgrade syncs, then updates the world set", "emerge", "upgrade", [], ["emerge"], { binary: "emerge", elevate: true, steps: [["emerge", "--sync"], ["emerge", "--ask", "--update", "--deep", "--newuse", "@world"]] }],
    ["flatpak install", "flatpak", "install", ["org.gnome.Loupe"], ["flatpak"], { binary: "flatpak", elevate: false, steps: [["flatpak", "install", "org.gnome.Loupe"]] }],
    ["flatpak remove", "flatpak", "remove", ["org.gnome.Loupe"], ["flatpak"], { binary: "flatpak", elevate: false, steps: [["flatpak", "uninstall", "org.gnome.Loupe"]] }],
    ["flatpak upgrade", "flatpak", "upgrade", [], ["flatpak"], { binary: "flatpak", elevate: false, steps: [["flatpak", "update"]] }],
    ["mise install", "mise", "install", ["npm:@anthropic-ai/claude-code"], ["mise"], { binary: "mise", elevate: false, steps: [["mise", "use", "--global", "npm:@anthropic-ai/claude-code"]] }],
    ["mise remove", "mise", "remove", ["node"], ["mise"], { binary: "mise", elevate: false, steps: [["mise", "unuse", "--global", "node"]] }],
    ["mise upgrade waives the release-age cooldown", "mise", "upgrade", [], ["mise"], { binary: "mise", elevate: false, steps: [["env", "MISE_MINIMUM_RELEASE_AGE=0", "mise", "upgrade"]] }],
    ["nix install is unsupported", "nix", "install", ["gum"], ["nix"], "manager=nix action=install reason=unsupported"],
    ["nix remove is unsupported", "nix", "remove", ["gum"], ["nix"], "manager=nix action=remove reason=unsupported"],
    ["nix upgrade is unsupported", "nix", "upgrade", [], ["nix"], "manager=nix action=upgrade reason=unsupported"],
    ["an unknown manager", "zypper", "install", ["gum"], ["zypper"], "manager=zypper reason=unknown"],
    ["a manager whose binary is absent", "dnf", "install", ["gum"], [], "manager=dnf reason=absent binaries=dnf5,dnf"],
    ["a name that starts with a dash", "pacman", "install", ["-Sy"], ["pacman"], "name=\"-Sy\" reason=grammar"],
    ["a name with a space", "pacman", "install", ["gum fzf"], ["pacman"], "name=\"gum fzf\" reason=grammar"],
    ["an empty name", "pacman", "install", [""], ["pacman"], "name=\"\" reason=grammar"],
    ["a name past 256 characters", "pacman", "install", ["a".repeat(257)], ["pacman"], "name=\"" + "a".repeat(257) + "\" reason=grammar"]
];

// pickerFor rows: name, manager, action, the commands on PATH, `{ list,
// preview }` or the refusal.
const PICKER_ROWS = [
    ["pacman install lists the sync databases", "pacman", "install", ["pacman"], { list: ["pacman", "-Slq"], preview: ["pacman", "-Sii", "{name}"] }],
    ["pacman remove lists the explicit packages", "pacman", "remove", ["pacman"], { list: ["pacman", "-Qqe"], preview: ["pacman", "-Qi", "{name}"] }],
    ["aur install through the helper", "aur", "install", ["yay"], { list: ["yay", "-Slqa"], preview: ["yay", "-Siia", "{name}"] }],
    ["aur remove is pacman's", "aur", "remove", ["paru"], "manager=aur picker=remove reason=unsupported"],
    ["apt install", "apt", "install", ["apt-get"], { list: ["apt-cache", "pkgnames"], preview: ["apt-cache", "show", "{name}"] }],
    ["apt remove lists the manual packages", "apt", "remove", ["apt-get"], { list: ["apt-mark", "showmanual"], preview: ["dpkg", "-s", "{name}"] }],
    ["dnf install", "dnf", "install", ["dnf5"], { list: ["dnf5", "-q", "repoquery", "--available", "--queryformat", "%{name}\\n"], preview: ["dnf5", "info", "{name}"] }],
    ["dnf remove lists the user's packages", "dnf", "remove", ["dnf"], { list: ["dnf", "-q", "repoquery", "--userinstalled", "--queryformat", "%{name}\\n"], preview: ["rpm", "-qi", "{name}"] }],
    ["flatpak offers no picker", "flatpak", "install", ["flatpak"], "manager=flatpak picker=install reason=unsupported"],
    ["an absent manager", "pacman", "install", [], "manager=pacman reason=absent binaries=pacman"]
];

// elevator rows: name, packages.elevate or undefined, the commands on PATH,
// `{ ok: true, command }` or the refusal.
const ELEVATOR_ROWS = [
    ["sudo first", undefined, ["run0", "doas", "sudo"], "sudo"],
    ["doas without sudo", undefined, ["run0", "doas"], "doas"],
    ["run0 alone", undefined, ["run0"], "run0"],
    ["none found", undefined, ["pkexec", "su"], "elevate=none candidates=sudo,doas,run0"],
    ["the configured command over sudo", "run0", ["sudo", "run0"], "run0"],
    ["a configured command that is absent", "doas", ["sudo"], "elevate=doas reason=absent source=packages.elevate"]
];

// packageFor rows: name, a requirement's packages, detect's answer, the pick.
const PACMAN = { id: "pacman", binary: "pacman" };
const PARU = { id: "aur", binary: "paru" };
const MISE = { id: "mise", binary: "mise" };
const PACKAGE_FOR_ROWS = [
    ["the primary's package wins over an overlay's", { aur: "gum-bin", pacman: "gum" }, { primary: PACMAN, overlays: [PARU], sources: [] }, { manager: "pacman", name: "gum" }],
    ["an overlay serves what the primary does not map", { aur: "vsys" }, { primary: PACMAN, overlays: [PARU], sources: [] }, { manager: "aur", name: "vsys" }],
    ["an overlay wins over a source", { mise: "node", aur: "nodejs-bin" }, { primary: PACMAN, overlays: [PARU], sources: [MISE] }, { manager: "aur", name: "nodejs-bin" }],
    ["a source serves last", { mise: "node" }, { primary: PACMAN, overlays: [], sources: [MISE] }, { manager: "mise", name: "node" }],
    ["an overlay serves a system with no primary", { flatpak: "org.gnome.Loupe" }, { primary: null, overlays: [{ id: "flatpak", binary: "flatpak" }], sources: [] }, { manager: "flatpak", name: "org.gnome.Loupe" }],
    ["no present manager is mapped", { apt: "gum", dnf: "gum" }, { primary: PACMAN, overlays: [PARU], sources: [] }, null],
    ["no package is mapped at all", {}, { primary: PACMAN, overlays: [], sources: [] }, null]
];

// Parser rows: name, parser, the text (a string, or { fixture } under
// scripts/fixtures/pkg/), and the packages as [name, old, new] or the
// parser's error. Fixture origins: checkupdates, paru and mise were captured
// from the real commands on CachyOS on 2026-09-28; the others are written
// from the format each tool's own source prints: yay print.go
// printUpdateList and text FormatAgeTag, apt apt-private private-list.cc and
// private-output.cc ListSingleVersion, dnf 4 dnf/cli/output.py fmtColumns
// and cli.py check_updates, dnf5 libdnf5-cli package_list_sections.cpp
// print_json, xbps bin/xbps-install/transaction.c show_dry_run_actions,
// emerge lib/_emerge/resolver/output.py _set_no_columns, flatpak
// app/flatpak-table-printer.c.
const fixture = name => ({ fixture: name });
const PARSE_ROWS = [
    ["checkupdates", "arrow", fixture("checkupdates.txt"), [["bpf", "7.2.7-1", "7.2.8-1"], ["coreutils", "9.11-2.1", "9.12-2.1"],
        ["python-cattrs", "26.2.0-1", "26.2.1-1"], ["python-dbus", "1.4.0-2", "1.5.0-1"], ["shellcheck", "0.11.0-140", "0.11.0-142"],
        ["sunshine", "2026.922.203725-1", "2026.928.163558-1"]]],
    ["paru's devel update", "arrow", fixture("paru.txt"), [["kendex-git", "1:r1621.bf9bed514-1", "latest-commit"]]],
    ["yay's age tags", "arrow", fixture("yay.txt"), [["yay", "12.4.2-1", "12.5.0-1"], ["go-task-bin", "3.40.0-1", "3.41.0-1"], ["zen-browser-bin", "1.7b-1", "1.8b-1"]]],
    ["arrow: no output", "arrow", "", []],
    ["arrow: an ignored package is not counted", "arrow", "linux 6.9-1 -> 6.10-1 [ignored]\nbash 5.2-1 -> 5.3-1\n", [["bash", "5.2-1", "5.3-1"]]],
    ["arrow: an unknown tag", "arrow", "bash 5.2-1 -> 5.3-1 [soon]\n", "unparseable line=1"],
    ["arrow: an error line", "arrow", "bash 5.2-1 -> 5.3-1\nerror: failed to synchronize all databases\n", "unparseable line=2"],
    ["arrow: a coloured line", "arrow", "\u001b[1mbash\u001b[0m 5.2-1 -> 5.3-1\n", "unparseable line=1"],
    ["arrow: no arrow", "arrow", "bash 5.2-1 5.3-1\n", "unparseable line=1"],
    ["apt", "apt", fixture("apt.txt"), [["bash", "5.2.21-2ubuntu4", "5.2.21-2ubuntu4.1"], ["libssl3t64", "3.0.13-0ubuntu3.4", "3.0.13-0ubuntu3.5"]]],
    ["apt: the progress line alone", "apt", "Listing... Done\n", []],
    ["apt: its CLI warning on stdout", "apt", "Listing...\nWARNING: apt does not have a stable CLI interface. Use with caution in scripts.\n", "unparseable line=2"],
    ["apt: an installed package", "apt", "Listing...\nbash/now 5.2 amd64 [installed,local]\n", "unparseable line=2"],
    ["dnf 4, a long name wrapped and the obsoletes left out", "dnf", fixture("dnf.txt"), [["bash", null, "5.2.26-3.fc40"],
        ["python3-sphinxcontrib-applehelp-doc-extra", null, "2.0.0-1.fc40"], ["dnf-plugins-core", null, "4.9.0-1.fc40"]]],
    ["dnf 4: no output", "dnf", "", []],
    ["dnf 4: the blank line alone", "dnf", "\n", []],
    ["dnf 4: the metadata notice -q removes", "dnf", "Last metadata expiration check: 0:01:02 ago on Mon 28 Sep 2026.\n\nbash.x86_64 5.2-1.fc40 updates\n", "unparseable line=1"],
    ["dnf 4: a row cut short", "dnf", "\nbash.x86_64 5.2-1.fc40\n", "unparseable line=2"],
    ["dnf5 JSON, the obsoletes left out", "dnf5", fixture("dnf5.json"), [["bash", null, "5.3.0-2.fc44"], ["dnf5", null, "5.4.6.0-1.fc44"]]],
    ["dnf5: no section", "dnf5", "{}\n", []],
    ["dnf5: text before the JSON", "dnf5", "Updating and loading repositories:\n{}\n", "unparseable json"],
    ["dnf5: an unknown section", "dnf5", "{\"upgradeable_packages\":[]}\n", "unparseable key=upgradeable_packages"],
    ["dnf5: an entry without a version", "dnf5", "{\"upgrades\":[{\"name\":\"bash\",\"arch\":\"x86_64\"}]}\n", "unparseable entry=0"],
    ["xbps, updates alone counted", "xbps", fixture("xbps.txt"), [["bash", null, "5.2.037_1"], ["xbps", null, "0.60.4_1"]]],
    ["xbps: no output", "xbps", "", []],
    ["xbps: a field missing", "xbps", "bash-5.2_1 update x86_64 https://repo 1\n", "unparseable line=1"],
    ["xbps: a pkgver without a revision", "xbps", "bash update x86_64 https://repo 1 2\n", "unparseable line=1"],
    ["emerge, updates and downgrades counted", "emerge", fixture("emerge.txt"), [["sys-apps/portage", "3.0.65", "3.0.66-r1"],
        ["app-editors/vim", "9.1.0707", "9.1.0794"], ["dev-lang/python", "3.12.5", "3.12.7"], ["sys-libs/zlib", "1.3.1-r2", "1.3.1-r1"]]],
    ["emerge: narration alone", "emerge", "Calculating dependencies  ... done!\n", []],
    ["emerge: a merge without a version", "emerge", "[ebuild     U  ] sys-apps/portage [3.0.65]\n", "unparseable line=1"],
    ["emerge: a binary whose version is one number", "emerge", "[binary     U  ] app-misc/foo-5 [4]\n", [["app-misc/foo", "4", "5"]]],
    ["flatpak", "flatpak", fixture("flatpak.txt"), [["org.gnome.Loupe", null, "stable"], ["org.gnome.Platform", null, "47"], ["org.freedesktop.Platform.GL.default", null, "24.08"]]],
    ["flatpak: no output", "flatpak", "", []],
    ["flatpak: a title row", "flatpak", "Application ID\tBranch\n", "unparseable line=1"],
    ["flatpak: a third column", "flatpak", "org.gnome.Loupe\tstable\tflathub\n", "unparseable line=1"],
    ["mise", "mise", fixture("mise.json"), [["aqua:google-antigravity/antigravity-cli", "1.2.11", "1.2.12"], ["claude", "2.1.283", "2.1.284"], ["npm:vercel", "60.1.1", "60.1.3"]]],
    ["mise: nothing outdated", "mise", "{}\n", []],
    ["mise: a tool not yet installed", "mise", "{\"node\":{\"current\":null,\"latest\":\"22.1.0\"}}\n", [["node", null, "22.1.0"]]],
    ["mise: a tool without a latest version", "mise", "{\"node\":{\"current\":\"22.0.0\"}}\n", "unparseable tool=node"],
    ["mise: an array", "mise", "[]\n", "unparseable json"]
];

// Query rows: name, manager, binary, whether it was asked for by name, and
// the query or why it is skipped.
const q = (argv, exits, parser, timeout) => ({ check: { argv, exits, parser, timeout } });
const ROWS = { "0": "rows" };
const CHECK_ROWS = [
    ["pacman runs checkupdates", "pacman", "pacman", false, q(["checkupdates"], { "0": "updates", "2": "none" }, "arrow", 120)],
    ["aur runs its helper", "aur", "yay", false, q(["yay", "-Qua"], { "0": "updates", "1": "none" }, "arrow", 120)],
    ["apt lists the upgradable packages", "apt", "apt-get", false, q(["apt", "list", "--upgradable"], ROWS, "apt", 120)],
    ["dnf5 answers in JSON", "dnf", "dnf5", false, q(["dnf5", "check-upgrade", "--json"], ROWS, "dnf5", 120)],
    ["dnf 4 answers in columns", "dnf", "dnf", false, q(["dnf", "-q", "check-update"], { "0": "none", "100": "updates" }, "dnf", 120)],
    ["xbps syncs in memory and changes nothing", "xbps", "xbps-install", false, q(["xbps-install", "-Mun"], ROWS, "xbps", 120)],
    ["emerge waits to be named", "emerge", "emerge", false, { skipped: "on-demand" }],
    ["emerge named", "emerge", "emerge", true, q(["emerge", "--pretend", "--update", "--deep", "--newuse", "--color=n", "--ask=n", "@world"], ROWS, "emerge", 900)],
    ["nix has no query", "nix", "nix", true, { skipped: "no-check" }],
    ["flatpak lists its updates", "flatpak", "flatpak", false, q(["flatpak", "remote-ls", "--updates", "--columns=application,branch"], ROWS, "flatpak", 120)],
    ["mise waives the release-age cooldown", "mise", "mise", false, q(["env", "MISE_MINIMUM_RELEASE_AGE=0", "mise", "outdated", "--json"], ROWS, "mise", 120)]
];

// Outcome rows: name, manager, binary, exit status, stdout, and the
// packages as [name, old, new] or the check's error.
const OUTCOME_ROWS = [
    ["checkupdates 2 is none", "pacman", "pacman", 2, "", []],
    ["checkupdates 1 is a failure", "pacman", "pacman", 1, "", "exit=1"],
    ["checkupdates 0 reads the rows", "pacman", "pacman", 0, "bpf 7.2.7-1 -> 7.2.8-1\n", [["bpf", "7.2.7-1", "7.2.8-1"]]],
    ["yay 1 is none", "aur", "yay", 1, "", []],
    ["dnf 100 reads the rows", "dnf", "dnf", 100, "\nbash.x86_64 5.2-1.fc40 updates\n", [["bash", null, "5.2-1.fc40"]]],
    ["dnf 0 is none", "dnf", "dnf", 0, "", []],
    ["dnf 1 is a failure", "dnf", "dnf", 1, "", "exit=1"],
    ["dnf5's JSON query never exits 100", "dnf", "dnf5", 100, "{}\n", "exit=100"],
    ["dnf5 before 5.4.0 refuses --json with 2", "dnf", "dnf5", 2, "", "exit=2"],
    ["an unreadable line fails the check", "flatpak", "flatpak", 0, "Application ID\tBranch\n", "unparseable line=1"],
    ["flatpak 1 is a failure", "flatpak", "flatpak", 1, "", "exit=1"]
];

// Query rows: name, manager, query, the value, the commands on PATH, and
// the argv, or the refusal's first line.
const QUERY_ROWS = [
    ["pacman owner", "pacman", "owner", "/usr/share/vgs/VERSION", ["pacman"], ["pacman", "-Qoq", "/usr/share/vgs/VERSION"]],
    ["pacman installed", "pacman", "installed", "vgs-git", ["pacman"], ["pacman", "-Q", "--", "vgs-git"]],
    ["apt owner through dpkg", "apt", "owner", "/usr/share/vgs/VERSION", ["apt-get"], ["dpkg", "-S", "/usr/share/vgs/VERSION"]],
    ["apt installed through dpkg-query", "apt", "installed", "vgs", ["apt-get"], ["dpkg-query", "-W", "--showformat=${Version}\n", "--", "vgs"]],
    ["dnf owner through rpm names the package alone", "dnf", "owner", "/usr/share/vgs/VERSION", ["dnf5"], ["rpm", "-qf", "--queryformat", "%{NAME}\n", "/usr/share/vgs/VERSION"]],
    ["dnf installed through rpm", "dnf", "installed", "vgs", ["dnf5"], ["rpm", "-q", "--queryformat", "%{VERSION}\n", "--", "vgs"]],
    ["xbps owner", "xbps", "owner", "/usr/share/vgs/VERSION", ["xbps-install"], ["xbps-query", "-o", "/usr/share/vgs/VERSION"]],
    ["emerge owner", "emerge", "owner", "/usr/share/vgs/VERSION", ["emerge"], ["qfile", "/usr/share/vgs/VERSION"]],
    ["xbps asks no installed query", "xbps", "installed", "vgs", ["xbps-install"], "manager=xbps query=installed reason=unsupported"],
    ["aur owns no file", "aur", "owner", "/usr/share/vgs/VERSION", ["paru"], "manager=aur query=owner reason=unsupported"],
    ["an owner path must be absolute", "pacman", "owner", "VERSION", ["pacman"], "path=\"VERSION\" reason=relative"],
    ["an installed name keeps the name grammar", "pacman", "installed", "-Qi", ["pacman"], "name=\"-Qi\" reason=grammar"],
    ["a query whose binary is absent", "pacman", "owner", "/usr/share/vgs/VERSION", [], "manager=pacman reason=absent binaries=pacman"]
];

// Answer rows: name, manager, query, what the query printed, the answer.
// The formats are packages.md § Queries' sources.
const ANSWER_ROWS = [
    ["pacman -Qoq prints the name", "pacman", "owner", "vgs-git\n", "vgs-git"],
    ["pacman -Q drops the epoch and the pkgrel", "pacman", "installed", "vgs-git 1:0.1.0.r40.gabc1234-2\n", "0.1.0.r40.gabc1234"],
    ["pacman -Q without an epoch", "pacman", "installed", "vgs 0.1.0-1\n", "0.1.0"],
    ["dpkg -S names the package before its colon", "apt", "owner", "vgs: /usr/share/vgs/VERSION\n", "vgs"],
    ["dpkg -S with an architecture qualifier", "apt", "owner", "vgs:amd64: /usr/share/vgs/VERSION\n", "vgs"],
    ["a Debian version drops the epoch and the revision", "apt", "installed", "1:0.1.0-3\n", "0.1.0"],
    ["a Debian upstream version may hold a dash", "apt", "installed", "1.2-3-1\n", "1.2-3"],
    ["a native Debian version has no revision", "apt", "installed", "0.1.0\n", "0.1.0"],
    ["rpm prints the name", "dnf", "owner", "vgs\n", "vgs"],
    ["rpm prints the version", "dnf", "installed", "0.1.0^40.gitabc1234\n", "0.1.0^40.gitabc1234"],
    ["xbps-query -o names the package before its version", "xbps", "owner", "vgs-git-0.1.0_1: /usr/share/vgs/VERSION\n", "vgs-git"],
    ["qfile names the category and package", "emerge", "owner", "gui-apps/vgs (/usr/share/vgs/VERSION)\n", "gui-apps/vgs"],
    ["a message is no answer", "pacman", "owner", "error: No package owns /x\n", null],
    ["the first line alone is read", "pacman", "installed", "\nvgs 0.1.0-1\n", null]
];

const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const triples = packages => packages.map(p => [p.name, p.old, p.new]);

function verifyTable(t) {
    const failures = tableErrors(t);
    const onPathOf = list => command => list.includes(command);
    for (const [name, text, commands, want] of DETECT_ROWS) {
        const got = t.detect(t.osReleaseIds(text), onPathOf(commands));
        if (!same(got, want)) failures.push("detect: " + name + ": got " + JSON.stringify(got));
    }
    for (const [name, text, want] of ID_ROWS) {
        const got = t.osReleaseIds(text);
        if (!same(got, want)) failures.push("os-release: " + name + ": got " + JSON.stringify(got));
    }
    const covered = new Set();
    for (const [name, manager, action, names, commands, want] of PLAN_ROWS) {
        const got = t.plan(manager, action, names, onPathOf(commands));
        const expected = typeof want === "string" ? { ok: false, error: want } : { ok: true, plan: { manager, binary: want.binary, action, elevate: want.elevate, steps: want.steps } };
        if (!same(got, expected)) failures.push("plan: " + name + ": got " + JSON.stringify(got));
        covered.add(manager + " " + action);
    }
    for (const row of t.MANAGERS) for (const action of t.ACTIONS)
        if (!covered.has(row.id + " " + action)) failures.push("plan: no row for " + row.id + " " + action);
    const queried = new Set();
    for (const [name, manager, query, value, commands, want] of QUERY_ROWS) {
        const got = t.queryArgv(manager, query, value, onPathOf(commands));
        const expected = typeof want === "string" ? { ok: false, error: want } : { ok: true, argv: want };
        if (!same(got, expected)) failures.push("query: " + name + ": got " + JSON.stringify(got));
        queried.add(manager + " " + query);
    }
    for (const row of t.MANAGERS) for (const query of t.QUERIES)
        if (row[query] !== null && !queried.has(row.id + " " + query)) failures.push("query: no row for " + row.id + " " + query);
    for (const [name, manager, query, stdout, want] of ANSWER_ROWS) {
        const got = t.queryAnswer(manager, query, stdout);
        if (got !== want) failures.push("answer: " + name + ": got " + JSON.stringify(got));
    }
    for (const [name, manager, action, commands, want] of PICKER_ROWS) {
        const got = t.pickerFor(manager, action, onPathOf(commands));
        const expected = typeof want === "string" ? { ok: false, error: want } : Object.assign({ ok: true }, want);
        if (!same(got, expected)) failures.push("picker: " + name + ": got " + JSON.stringify(got));
    }
    if (!same(t.ELEVATORS, ["sudo", "doas", "run0"])) failures.push("elevators: got " + JSON.stringify(t.ELEVATORS));
    for (const [name, configured, commands, want] of ELEVATOR_ROWS) {
        const got = t.elevator(configured, onPathOf(commands));
        const expected = want.includes("=") ? { ok: false, error: want } : { ok: true, command: want };
        if (!same(got, expected)) failures.push("elevator: " + name + ": got " + JSON.stringify(got));
    }
    for (const [name, packages, found, want] of PACKAGE_FOR_ROWS) {
        const got = t.packageFor(packages, found);
        if (!same(got, want)) failures.push("packageFor: " + name + ": got " + JSON.stringify(got));
    }

    const parsed = new Set();
    for (const [name, parser, input, want] of PARSE_ROWS) {
        const text = typeof input === "string" ? input : fs.readFileSync(path.join(FIXTURES, input.fixture), "utf8");
        const r = t.PARSERS[parser](text);
        const got = r.ok ? triples(r.packages) : r.error;
        if (!same(got, want)) failures.push("parse: " + name + ": got " + JSON.stringify(got));
        parsed.add(parser);
    }
    const parsers = Object.keys(t.PARSERS);
    if (parsers.length < 8) failures.push("parse: fewer than eight parsers; the loader read no PARSERS");
    for (const parser of parsers) if (!parsed.has(parser)) failures.push("parse: no row for parser " + parser);

    const checked = new Set();
    for (const [name, manager, binary, named, want] of CHECK_ROWS) {
        const got = t.checkFor(manager, binary, named);
        if (!same(got, want)) failures.push("check: " + name + ": got " + JSON.stringify(got));
        checked.add(manager);
    }
    for (const row of t.MANAGERS) if (!checked.has(row.id)) failures.push("check: no row for " + row.id);

    for (const [name, manager, binary, status, stdout, want] of OUTCOME_ROWS) {
        const found = t.checkFor(manager, binary, true);
        const r = found.check === undefined ? { error: "no query" } : t.checkOutcome(found.check, status, stdout);
        const got = r.error === undefined ? triples(r.packages) : r.error;
        if (!same(got, want)) failures.push("outcome: " + name + ": got " + JSON.stringify(got));
    }
    return failures;
}

// A tree at DIR holding bin/vgsh-pkg, bin/vgsh and the table as the texts
// given, and the repository's own bin/lib, which holds the loader: `{ pkg,
// vgsh }`.
function makeTree(dir, texts) {
    for (const sub of ["bin", path.join("shell", "Core")]) fs.mkdirSync(path.join(dir, sub), { recursive: true });
    fs.symlinkSync(path.join(repo, "bin", "lib"), path.join(dir, "bin", "lib"));
    fs.writeFileSync(path.join(dir, "shell", "Core", "PackageManagers.js"), texts.table);
    fs.writeFileSync(path.join(dir, "bin", "vgsh-pkg"), texts.pkg, { mode: 0o755 });
    fs.writeFileSync(path.join(dir, "bin", "vgsh"), texts.vgsh, { mode: 0o755 });
    return { pkg: path.join(dir, "bin", "vgsh-pkg"), vgsh: path.join(dir, "bin", "vgsh") };
}

// The table with the aur query's timeout cut to one second, for the row
// that proves a query is killed at its timeout without waiting two minutes.
const AUR_QUERY = "\"-Qua\"], exits: { \"0\": \"updates\", \"1\": \"none\" }, parser: \"arrow\", timeout: ";
function quickTable(text) {
    const count = text.split(AUR_QUERY + "120,").length - 1;
    if (count !== 1) throw new Error("quick table: the aur query occurs " + count + " times, not once");
    return text.replace(AUR_QUERY + "120,", () => AUR_QUERY + "1,");
}

// The CLI rows run TEXTS' bin/vgsh-pkg and bin/vgsh from trees under TMP
// with a PATH of stubs. Answers the failures and the tool a row could not
// run without, or null.
function verifyCli(texts, tmp) {
    const scripts = makeTree(path.join(tmp, "tree"), texts);
    const quick = makeTree(path.join(tmp, "quick"), Object.assign({}, texts, { table: quickTable(texts.table) }));
    const failures = [];
    const stubs = path.join(tmp, "stubs");
    const tools = path.join(tmp, "tools");
    fs.mkdirSync(stubs, { recursive: true });
    fs.mkdirSync(tools, { recursive: true });
    for (const command of ["pacman", "yay", "gum", "xbps-install"]) fs.writeFileSync(path.join(stubs, command), "#!/bin/sh\nexit 99\n", { mode: 0o755 });
    // bin/vgsh runs under bash and resolves itself with readlink and
    // dirname; node runs bin/vgsh-pkg, which takes its lock through flock
    // and runs mise's query through env; the stubs use cat and sleep. None
    // of them is a manager.
    for (const tool of ["bash", "readlink", "dirname", "flock", "env", "cat", "sleep"]) {
        const found = childProcess.spawnSync("sh", ["-c", "command -v \"$1\"", "sh", tool], { encoding: "utf8" });
        if (found.status !== 0) return { failures: [], missing: tool };
        const target = path.join(tools, tool);
        if (!fs.existsSync(target)) fs.symlinkSync(found.stdout.trim(), target);
    }
    if (!fs.existsSync(path.join(tools, "node"))) fs.symlinkSync(process.execPath, path.join(tools, "node"));
    const env = { PATH: stubs + path.delimiter + tools, LC_ALL: "C", XDG_RUNTIME_DIR: tmp, HOME: tmp };
    const run = (file, args) => childProcess.spawnSync(file, args, { encoding: "utf8", env });
    const expect = (name, r, status, stdout, stderr) => {
        if (r.status !== status || r.stdout !== stdout || (stderr !== undefined && !r.stderr.startsWith(stderr)))
            failures.push("cli: " + name + ": status=" + r.status + " stdout=" + JSON.stringify(r.stdout) + " stderr=" + JSON.stringify(r.stderr));
    };
    expect("present names the missing command and exits 1", run(scripts.pkg, ["present", "gum", "fzf"]), 1, "{\"present\":[\"gum\"],\"missing\":[\"fzf\"]}\n", "");
    expect("present exits 0 when every command is found", run(scripts.pkg, ["present", "gum", "yay"]), 0, "{\"present\":[\"gum\",\"yay\"],\"missing\":[]}\n", "");
    expect("present refuses a path", run(scripts.pkg, ["present", "/bin/sh"]), 2, "", "vgsh: refused: command=\"/bin/sh\"\n");
    expect("plan prints the aur helper's argv", run(scripts.pkg, ["plan", "install", "aur", "gum-bin"]), 0,
        "{\"manager\":\"aur\",\"binary\":\"yay\",\"action\":\"install\",\"elevate\":false,\"steps\":[[\"yay\",\"-S\",\"--needed\",\"--\",\"gum-bin\"]]}\n", "");
    expect("plan install without names is a bad invocation", run(scripts.pkg, ["plan", "install", "pacman"]), 2, "", "vgsh: refused: names=missing\n");
    expect("plan upgrade with a name is a bad invocation", run(scripts.pkg, ["plan", "upgrade", "pacman", "gum"]), 2, "", "vgsh: refused: argument=gum\n");
    expect("plan refuses an unknown action", run(scripts.pkg, ["plan", "sync", "pacman"]), 2, "", "vgsh: refused: action=sync\n");
    expect("plan refuses a manager whose binary is absent", run(scripts.pkg, ["plan", "upgrade", "apt"]), 1, "", "vgsh: refused: manager=apt reason=absent binaries=apt-get\n");
    expect("vgsh pkg reaches vgsh-pkg with its arguments", run(scripts.vgsh, ["pkg", "plan", "upgrade", "pacman"]), 0,
        "{\"manager\":\"pacman\",\"binary\":\"pacman\",\"action\":\"upgrade\",\"elevate\":true,\"steps\":[[\"pacman\",\"-Syu\"]]}\n", "");

    // detect reads /etc/os-release, so a fixture is bound over it in a
    // private mount namespace. It names Void, so a run that read the
    // machine's own file instead passes only on a Void machine.
    checkRows(scripts, quick, tools, tmp, expect, failures);

    const osRelease = (name, text) => {
        const file = path.join(tmp, name);
        fs.writeFileSync(file, text);
        return file;
    };
    const bound = (file, pathValue, args) => childProcess.spawnSync("unshare", ["-rm", "sh", "-c", "mount --bind \"$1\" /etc/os-release && shift && exec \"$@\"", "sh", file,
        "env", "PATH=" + pathValue, "LC_ALL=C", "XDG_RUNTIME_DIR=" + tmp, "HOME=" + tmp, process.execPath, scripts.pkg, ...args], { encoding: "utf8", env: { PATH: process.env.PATH, LC_ALL: "C" } });
    const probe = childProcess.spawnSync("unshare", ["-rm", "true"], { encoding: "utf8" });
    if (probe.status !== 0) return { failures, missing: "user-namespaces" };
    // Each fixture names a system the machine running the suite is unlikely
    // to be, so a run that read the machine's own file instead fails.
    const voidLinux = osRelease("os-release-void", "NAME=\"Void\"\nID=\"void\"\n");
    expect("detect --json reads os-release and PATH", bound(voidLinux, env.PATH, ["detect", "--json"]), 0, "{\"primary\":{\"id\":\"xbps\",\"binary\":\"xbps-install\"},\"overlays\":[],\"sources\":[]}\n", "");
    expect("detect prints one line per manager", bound(voidLinux, env.PATH, ["detect"]), 0, "primary=xbps binary=xbps-install\n", "");
    const gentoo = osRelease("os-release-gentoo", "NAME=Gentoo\nID=gentoo\n");
    const gentooPath = stubPath(tmp, "gentoo", { emerge: "exit 99", flatpak: "cat \"" + path.join(FIXTURES, "flatpak.txt") + "\"" }, tools);
    expectCheck(expect, "check without --source checks every detected source, emerge only on demand", bound(gentoo, gentooPath, ["check", "--json"]), [
        { source: "emerge", count: null, packages: [], checkedAt: null, error: "skipped=on-demand" },
        { source: "flatpak", count: 3, packages: [{ name: "org.gnome.Loupe", old: null, new: "stable" }, { name: "org.gnome.Platform", old: null, new: "47" },
            { name: "org.freedesktop.Platform.GL.default", old: null, new: "24.08" }], checkedAt: "<time>", error: null }]);

    // Owner stubs answer as pacman and xbps-query do for one owned file,
    // packages.md § Queries; any other call exits 99.
    const owned = "/usr/share/vgs/VERSION";
    const ownerPath = stubPath(tmp, "owner", {
        pacman: "case \"$1 $2 $3\" in\n  \"-Qoq " + owned + " \") echo vgs-git ;;\n  \"-Qoq \"*) echo \"error: No package owns $2\" >&2; exit 1 ;;\n" +
            "  \"-Q -- vgs-git\") echo \"vgs-git 0.1.0.r40.gabc1234-1\" ;;\n  *) exit 99 ;;\nesac",
        "xbps-install": "exit 99",
        "xbps-query": "[ \"$1 $2\" = \"-o " + owned + "\" ] || exit 99\necho \"vgs-0.1.0_1: " + owned + "\""
    }, tools);
    const arch = osRelease("os-release-arch", "NAME=\"Arch Linux\"\nID=arch\n");
    const suse = osRelease("os-release-suse", "ID=opensuse-tumbleweed\n");
    expect("owner names the package and its installed version", bound(arch, ownerPath, ["owner", owned]), 0,
        "{\"manager\":\"pacman\",\"package\":\"vgs-git\",\"version\":\"0.1.0.r40.gabc1234\"}\n", "");
    expect("owner reports a null version where the table asks none", bound(voidLinux, ownerPath, ["owner", owned]), 0,
        "{\"manager\":\"xbps\",\"package\":\"vgs\",\"version\":null}\n", "");
    expect("owner refuses a file no package owns, the query's words after the line", bound(arch, ownerPath, ["owner", "/opt/vgs/VERSION"]), 1, "",
        "vgsh: refused: path=/opt/vgs/VERSION reason=unowned manager=pacman exit=1\nerror: No package owns /opt/vgs/VERSION\n");
    expect("owner refuses a system no primary serves", bound(suse, ownerPath, ["owner", owned]), 1, "", "vgsh: refused: manager=none\n");
    expect("owner refuses a relative path", bound(arch, ownerPath, ["owner", "VERSION"]), 1, "", "vgsh: refused: path=\"VERSION\" reason=relative\n");
    expect("owner without a path is a bad invocation", bound(arch, ownerPath, ["owner"]), 2, "", "vgsh: refused: path=missing\n");
    return { failures, missing: null };
}

// A PATH of stub commands under TMP/stubs-NAME, each STUBS body a sh
// script, ahead of TOOLS.
function stubPath(tmp, name, stubs, tools) {
    const dir = path.join(tmp, "stubs-" + name);
    fs.mkdirSync(dir, { recursive: true });
    for (const [command, body] of Object.entries(stubs)) fs.writeFileSync(path.join(dir, command), "#!/bin/sh\n" + body + "\n", { mode: 0o755 });
    return dir + path.delimiter + tools;
}

// A check's JSON, each checkedAt that is an ISO time read as "<time>",
// against WANT, through EXPECT.
function expectCheck(expect, name, r, want) {
    let got = r.stdout;
    try {
        const rows = JSON.parse(r.stdout);
        for (const row of rows)
            if (typeof row.checkedAt === "string" && /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/.test(row.checkedAt)) row.checkedAt = "<time>";
        got = JSON.stringify(rows) + "\n";
    } catch (e) {
        if (!(e instanceof SyntaxError)) throw e;
    }
    expect(name, Object.assign({}, r, { stdout: got }), 0, JSON.stringify(want) + "\n", "");
}

// The `check` rows, through EXPECT or straight into FAILURES. Each runs
// with its own stubs and runtime directory unless it shares one on purpose.
function checkRows(scripts, quick, tools, tmp, expect, failures) {
    const fixtureOf = name => path.join(FIXTURES, name);
    const home = path.join(tmp, "home");
    fs.mkdirSync(home, { recursive: true });
    const runIn = (runtime, file, pathValue, args, extra) => childProcess.spawnSync(file, args, {
        encoding: "utf8", env: Object.assign({ PATH: pathValue, LC_ALL: "POSIX", XDG_RUNTIME_DIR: runtime, HOME: home }, extra) });
    let rows = 0;
    const fresh = () => {
        const dir = path.join(tmp, "run-" + rows++);
        fs.mkdirSync(dir, { recursive: true });
        return dir;
    };
    const bpf = { name: "bpf", old: "7.2.7-1", new: "7.2.8-1" };
    const pacmanRows = [bpf, { name: "coreutils", old: "9.11-2.1", new: "9.12-2.1" }, { name: "python-cattrs", old: "26.2.0-1", new: "26.2.1-1" },
        { name: "python-dbus", old: "1.4.0-2", new: "1.5.0-1" }, { name: "shellcheck", old: "0.11.0-140", new: "0.11.0-142" },
        { name: "sunshine", old: "2026.922.203725-1", new: "2026.928.163558-1" }];
    const checkupdates = "cat \"" + fixtureOf("checkupdates.txt") + "\"";

    expectCheck(expect, "check --source pacman reads checkupdates", runIn(fresh(), scripts.pkg, stubPath(tmp, "pacman", { pacman: "exit 99", checkupdates }, tools), ["check", "--json", "--source", "pacman"]),
        [{ source: "pacman", count: 6, packages: pacmanRows, checkedAt: "<time>", error: null }]);
    expect("check without --json prints a line per source and package", runIn(fresh(), scripts.pkg, stubPath(tmp, "flatpak-text", { flatpak: "cat \"" + fixtureOf("flatpak.txt") + "\"" }, tools), ["check", "--source", "flatpak"]), 0,
        "source=flatpak count=3\n  org.gnome.Loupe ? -> stable\n  org.gnome.Platform ? -> 47\n  org.freedesktop.Platform.GL.default ? -> 24.08\n", "");
    expectCheck(expect, "yay's exit 1 is no update", runIn(fresh(), scripts.pkg, stubPath(tmp, "yay-none", { yay: "exit 1" }, tools), ["check", "--json", "--source", "aur"]),
        [{ source: "aur", count: 0, packages: [], checkedAt: "<time>", error: null }]);
    expect("a failed query is the source's error", runIn(fresh(), scripts.pkg, stubPath(tmp, "flatpak-fails", { flatpak: "echo partial\ttrue; exit 1" }, tools), ["check", "--source", "flatpak"]), 0,
        "source=flatpak error=exit=1\n", "");
    expectCheck(expect, "an absent checkupdates is the source's error", runIn(fresh(), scripts.pkg, stubPath(tmp, "no-checkupdates", { pacman: "exit 99" }, tools), ["check", "--json", "--source", "pacman"]),
        [{ source: "pacman", count: null, packages: [], checkedAt: "<time>", error: "absent=checkupdates" }]);
    const mise = "[ \"$MISE_MINIMUM_RELEASE_AGE\" = 0 ] && [ \"$*\" = \"outdated --json\" ] && [ \"$PWD\" = \"" + home + "\" ] && [ \"$LC_ALL\" = C ] || exit 7\ncat \"" + fixtureOf("mise.json") + "\"";
    expectCheck(expect, "mise's query runs from $HOME with LC_ALL=C and the cooldown waived", runIn(fresh(), scripts.pkg, stubPath(tmp, "mise", { mise }, tools), ["check", "--json", "--source", "mise"]),
        [{ source: "mise", count: 3, packages: [{ name: "aqua:google-antigravity/antigravity-cli", old: "1.2.11", new: "1.2.12" },
            { name: "claude", old: "2.1.283", new: "2.1.284" }, { name: "npm:vercel", old: "60.1.1", new: "60.1.3" }], checkedAt: "<time>", error: null }]);

    // KILL_GRACE_MS in bin/vgsh-pkg is 5 s, the wait between a group's
    // SIGTERM and its SIGKILL. A stub below that ignores SIGTERM sleeps 15 s,
    // so a run ends near 6 s with the SIGKILL and past 15 s without it; the
    // bound between leaves room for the suite's concurrent controls.
    const SLOW_BOUND_MS = 11000;
    const pause = ms => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
    const alive = group => {
        try {
            process.kill(-group, 0);
            return true;
        } catch (e) {
            if (e.code !== "ESRCH") throw e;
            return false;
        }
    };

    // The query ignores SIGTERM and sleeps in a child that keeps stdout
    // open, so the check ends soon after its one-second timeout only if the
    // whole process group gets SIGKILL a grace later; the sleep outlasts
    // both. It runs in the background beside the stop row below, so the two
    // graces overlap, and a shell records its output and status in files.
    const slowDir = fresh();
    const slowOut = path.join(slowDir, "out");
    const slowStatus = path.join(slowDir, "status");
    const started = Date.now();
    childProcess.spawn("/bin/sh", ["-c", "\"$1\" \"$2\" check --json --source aur > \"$3\"; echo $? > \"$4\"", "sh", process.execPath, quick.pkg, slowOut, slowStatus], {
        stdio: "ignore", env: { PATH: stubPath(tmp, "yay-slow", { yay: "trap '' TERM\nsleep 15" }, tools), LC_ALL: "POSIX", XDG_RUNTIME_DIR: slowDir, HOME: home } }).unref();

    // A check stopped by SIGTERM ends every query before it exits. Two
    // sources are detected by PATH alone, as the stubs hold no primary's
    // binary: flatpak's query exits on SIGTERM, mise's ignores it. Each
    // writes its group's id, then sleeps in a child. The shell below sends
    // SIGTERM once both ids are written, finds the lock still held a second
    // later, while mise's group waits for its SIGKILL, and reports the
    // check's status. The real waits are those writes, that second, the
    // grace, and the groups' end, polled every 20 ms.
    const flatpakGroup = path.join(tmp, "stopped-flatpak");
    const miseGroup = path.join(tmp, "stopped-mise");
    const stopRuntime = fresh();
    const stopScript = "\"$1\" \"$2\" check --json & p=$!\ni=0\n" +
        "while { [ ! -s \"$3\" ] || [ ! -s \"$4\" ]; } && [ $i -lt 250 ]; do sleep 0.02; i=$((i + 1)); done\n" +
        "kill -TERM \"$p\"\nsleep 1\nflock -n -E 75 \"$5\" /bin/sh -c :\nprobe=$?\ncase $probe in 0) echo lock=free ;; 75) echo lock=held ;; *) echo lock=probe-failed-$probe ;; esac\nwait \"$p\"\necho \"status=$?\"";
    const stopStarted = Date.now();
    const stopped = childProcess.spawnSync("/bin/sh", ["-c", stopScript, "sh", process.execPath, scripts.pkg, flatpakGroup, miseGroup, path.join(stopRuntime, "vgs", "pkg-check.lock")], {
        encoding: "utf8", env: { PATH: stubPath(tmp, "stopped", { flatpak: "echo $$ > \"" + flatpakGroup + "\"\nsleep 15", mise: "trap '' TERM\necho $$ > \"" + miseGroup + "\"\nsleep 15" }, tools),
            LC_ALL: "POSIX", XDG_RUNTIME_DIR: stopRuntime, HOME: home } });
    const stopElapsed = Date.now() - stopStarted;
    expect("a stopped check holds the lock until its last query ends, then exits 143", stopped, 0, "lock=held\nstatus=143\n", "");
    if (stopped.stderr !== "") failures.push("cli: the stopped check or its lock probe wrote stderr: " + JSON.stringify(stopped.stderr));
    if (stopElapsed >= SLOW_BOUND_MS) failures.push("cli: a stopped check waited past the grace for a query ignoring SIGTERM: elapsed=" + stopElapsed + "ms");
    // The timed-out check started above; the real wait is its timeout and
    // grace, polled every 20 ms up to the sleep it must cut short.
    const slowDeadline = started + 18000;
    const slowDone = () => fs.existsSync(slowStatus) && /^\d+\n$/.test(fs.readFileSync(slowStatus, "utf8"));
    while (!slowDone() && Date.now() < slowDeadline) pause(20);
    const elapsed = Date.now() - started;
    const slow = slowDone() ? { status: Number(fs.readFileSync(slowStatus, "utf8")), stdout: fs.readFileSync(slowOut, "utf8"), stderr: "" } : { status: null, stdout: "", stderr: "" };
    expectCheck(expect, "a query past its timeout is killed", slow, [{ source: "aur", count: null, packages: [], checkedAt: "<time>", error: "timeout=1" }]);
    if (elapsed >= SLOW_BOUND_MS) failures.push("cli: the timed-out query's process group outlived its timeout and grace: elapsed=" + elapsed + "ms");

    for (const file of [flatpakGroup, miseGroup]) {
        const group = fs.existsSync(file) ? Number(fs.readFileSync(file, "utf8")) : 0;
        if (group <= 0) {
            failures.push("cli: a stopped check's query never wrote its group to " + file);
            continue;
        }
        const until = Date.now() + 2000;
        while (alive(group) && Date.now() < until) pause(20);
        if (alive(group)) {
            failures.push("cli: a check stopped by SIGTERM left its query's group " + group + " running");
            process.kill(-group, "SIGKILL");
        }
    }

    // checkupdates skips its sync only after a successful synced run and
    // while its copy of the databases holds one; the stub names the
    // argument it was given as the package.
    const stamped = stubPath(tmp, "stamp", { pacman: "exit 99", checkupdates: "echo \"run${1:-sync} 1-1 -> 2-1\"" }, tools);
    const db = path.join(tmp, "checkup-db");
    fs.mkdirSync(path.join(db, "sync"), { recursive: true });
    fs.writeFileSync(path.join(db, "sync", "core.db"), "");
    const runtime = fresh();
    const synced = name => [{ source: "pacman", count: 1, packages: [{ name, old: "1-1", new: "2-1" }], checkedAt: "<time>", error: null }];
    expectCheck(expect, "the first check syncs", runIn(runtime, scripts.pkg, stamped, ["check", "--json", "--source", "pacman"], { CHECKUPDATES_DB: db }), synced("runsync"));
    expectCheck(expect, "a check right after a synced one skips the sync", runIn(runtime, scripts.pkg, stamped, ["check", "--json", "--source", "pacman"], { CHECKUPDATES_DB: db }), synced("run-n"));
    expectCheck(expect, "a recent sync with no database copy left syncs again", runIn(runtime, scripts.pkg, stamped, ["check", "--json", "--source", "pacman"], { CHECKUPDATES_DB: path.join(tmp, "no-db") }), synced("runsync"));

    // A second check waits for the lock: a holder takes it, and the stub
    // fails unless the holder has let go before the query runs. The real
    // wait is the holder's one second.
    const locked = fresh();
    const held = path.join(locked, "held");
    const released = path.join(locked, "released");
    fs.mkdirSync(path.join(locked, "vgs"));
    const holder = childProcess.spawn("flock", [path.join(locked, "vgs", "pkg-check.lock"), "sh", "-c", "touch \"$1\"; sleep 1; touch \"$2\"", "sh", held, released], { stdio: "ignore" });
    const deadline = Date.now() + 5000;
    while (!fs.existsSync(held) && Date.now() < deadline) pause(20);
    expectCheck(expect, "a check waits for the one running", runIn(locked, scripts.pkg, stubPath(tmp, "locked", { pacman: "exit 99", checkupdates: "[ -e \"" + released + "\" ] || exit 9\n" + checkupdates }, tools), ["check", "--json", "--source", "pacman"]),
        [{ source: "pacman", count: 6, packages: pacmanRows, checkedAt: "<time>", error: null }]);
    holder.unref();

    const plain = stubPath(tmp, "plain", { pacman: "exit 99" }, tools);
    expect("check refuses an unknown manager", runIn(fresh(), scripts.pkg, plain, ["check", "--source", "zypper"]), 1, "", "vgsh: refused: manager=zypper reason=unknown\n");
    expect("check refuses a manager whose binary is absent", runIn(fresh(), scripts.pkg, plain, ["check", "--source", "apt"]), 1, "", "vgsh: refused: manager=apt reason=absent binaries=apt-get\n");
    expect("check refuses an unknown argument", runIn(fresh(), scripts.pkg, plain, ["check", "--all"]), 2, "", "vgsh: refused: argument=--all\n");
    expect("check refuses without a runtime directory", runIn("", scripts.pkg, plain, ["check", "--source", "pacman"]), 1, "", "vgsh: refused: runtime-dir=unset\n");
}

// Each control removes one rule's behaviour from a copy. A `rule:` copy
// plants a defect in the table and must meet that rule of tableErrors,
// since its plan rows would fail on any edited argv; a `table` copy is
// judged by the whole table suite; a `cli` copy runs the CLI rows from a
// tree whose other files are the repository's own. A sixth column names
// text one of the copy's failures must hold, for a control that proves one
// particular assertion can fail.
const CONTROLS = [
    ["rule:partial upgrade", "a pacman upgrade refreshes without upgrading", TABLE, "upgrade: [[\"{bin}\", \"-Syu\"]],", "upgrade: [[\"{bin}\", \"-Sy\"]],"],
    ["rule:elevation command", "a step elevates", TABLE, "[\"{bin}\", \"full-upgrade\"]", "[\"sudo\", \"{bin}\", \"full-upgrade\"]"],
    ["rule:brace", "a preview word holds an fzf placeholder", TABLE, "preview: [\"{bin}\", \"-Sii\", \"{name}\"]", "preview: [\"{bin}\", \"-Sii\", \"--x={q}\", \"{name}\"]"],
    ["rule:elevation command", "a picker's list elevates", TABLE, "list: [\"{bin}\", \"-Slq\"]", "list: [\"sudo\", \"{bin}\", \"-Slq\"]"],
    ["table", "a picker keeps the binary placeholder", TABLE, "var fill = function (token) { return token === \"{bin}\" ? found.binary : token; };", "var fill = function (token) { return token; };"],
    ["table", "the elevation order changes", TABLE, "var ELEVATORS = [\"sudo\", \"doas\", \"run0\"];", "var ELEVATORS = [\"doas\", \"sudo\", \"run0\"];"],
    ["table", "a configured elevation command is ignored", TABLE, "        if (onPath(configured)) return { ok: true, command: configured };\n", ""],
    ["table", "ID_LIKE is ignored", TABLE, "    if (like !== null) {", "    if (false) {"],
    ["table", "an overlay ignores the primary it requires", TABLE, "if (other.requires !== null && (primary === null || primary.id !== other.requires)) continue;", ""],
    ["table", "a name may start with a dash", TABLE, " && name.charAt(0) !== \"-\"", ""],
    ["table", "the first binary wins even when absent", TABLE, "if (onPath(row.binaries[i])) return row.binaries[i];", "return row.binaries[i];"],
    ["table", "a requirement's package ignores the primary's rank", TABLE, "var order = (found.primary === null ? [] : [found.primary]).concat(found.overlays, found.sources);", "var order = found.overlays.concat(found.sources, found.primary === null ? [] : [found.primary]);"],
    ["table", "a requirement's package is picked for an unmapped manager", TABLE, "if (Object.prototype.hasOwnProperty.call(packages, order[i].id))", "if (true)"],
    ["table", "a query's answer ignores its pattern", TABLE, "return m === null ? null : m[1];", "return stdout.split(\"\\n\")[0];"],
    ["cli", "owner asks no installed version", PKG, "const version = table.managerRow(id).installed === null ? null : query(", "const version = null && query("],
    ["cli", "present exits 0 with a command missing", PKG, "process.exitCode = missing.length === 0 ? 0 : 1;", "process.exitCode = 0;"],
    ["cli", "vgsh pkg drops its arguments", VGSH, "exec node \"$root/bin/vgsh-pkg\" \"$@\"", "exec node \"$root/bin/vgsh-pkg\""],
    ["table", "an unlisted exit status is read as output", TABLE, "if (meaning === undefined) return { error: \"exit=\" + status };", "if (meaning === undefined) meaning = \"rows\";"],
    ["table", "a query runs for a binary it does not name", TABLE, "if (c.binary !== null && c.binary !== binary) continue;", ""],
    ["table", "an on-demand query runs unnamed", TABLE, "if (c.onDemand && !named) return { skipped: \"on-demand\" };", ""],
    ["table", "paru's ignored package is counted", TABLE, "if (f[4] === \"[ignored]\") continue;", "if (f[4] === \"[ignored]\") { packages.push({ name: f[0], old: f[1], new: f[3] }); continue; }"],
    ["table", "apt skips a line it cannot read", TABLE, "if (m === null) return unreadable(i);\n        packages.push({ name: m[1], old: m[3], new: m[2] });", "if (m === null) continue;\n        packages.push({ name: m[1], old: m[3], new: m[2] });"],
    ["table", "dnf 4 counts the obsoleting section", TABLE, "if (rows[i] === \"Obsoleting Packages\") break;", ""],
    ["table", "dnf5 accepts an unknown section", TABLE, "if (key !== \"upgrades\" && key !== \"obsoleting_packages\") return { ok: false, error: \"unparseable key=\" + key };", ""],
    ["table", "xbps counts every transaction entry", TABLE, "if (f[1] === \"update\") packages.push", "packages.push"],
    ["table", "emerge counts every merge", TABLE, "if (m[2].indexOf(\"U\") < 0) continue;", ""],
    ["table", "flatpak reads a title row", TABLE, " || /\\s/.test(f[0] + f[1])", ""],
    ["table", "mise accepts a tool without a latest version", TABLE, "typeof t.latest !== \"string\" || ", ""],
    ["cli", "a timed-out query's process group lives on", PKG, "process.kill(-child.pid, signal);", "process.kill(child.pid, signal);"],
    ["cli", "check runs without the lock", PKG, "        holdCheckLock(dir);\n", ""],
    ["cli", "checkupdates always syncs", PKG, "if (Date.now() - fs.statSync(stamp).mtimeMs > FRESH_MS) return false;", "return false;"],
    ["cli", "checkupdates skips its sync with no database copy", PKG, "return fs.readdirSync(path.join(db, \"sync\")).some(name => name.endsWith(\".db\"));", "return true;"],
    ["cli", "a query runs from the caller's directory", PKG, "cwd: process.env.HOME || \"/\",", ""],
    ["cli", "a signalled check exits and leaves its queries running", PKG, "for (const signal of [\"SIGINT\", \"SIGTERM\", \"SIGHUP\"]) process.on(signal, () => stopQueries(signal));", ""],
    ["cli", "a timed-out query that ignores SIGTERM is never killed", PKG, "grace = setTimeout(() => signalGroup(\"SIGKILL\"), KILL_GRACE_MS);", ""],
    ["cli", "a stopped check never kills a query that ignores SIGTERM", PKG, "for (const signalGroup of liveGroups.values()) signalGroup(\"SIGKILL\");", ""],
    ["cli", "a stopped check exits when its first query ends", PKG, "if (stopStatus !== null) {\n                if (liveGroups.size === 0) process.exit(stopStatus);", "if (stopStatus !== null) {\n                process.exit(stopStatus);", "lock=free"],
    ["cli", "a query reads the caller's locale", PKG, "env: Object.assign({}, process.env, { LC_ALL: \"C\" }),", "env: process.env,"]
];

// The texts the CLI rows run: the repository's own, or CONTROLS[INDEX]'s
// copy. `{ texts }`, or `{ error }` when the control's text to replace does
// not occur exactly once.
function cliTexts(index) {
    const texts = { pkg: fs.readFileSync(PKG, "utf8"), vgsh: fs.readFileSync(VGSH, "utf8"), table: fs.readFileSync(TABLE, "utf8") };
    if (index === null) return { texts };
    const [, label, file, needle, replacement] = CONTROLS[index];
    const key = file === PKG ? "pkg" : "vgsh";
    const count = texts[key].split(needle).length - 1;
    if (count !== 1) return { error: label + ": the text to replace occurs " + count + " times, not once" };
    return { texts: Object.assign({}, texts, { [key]: texts[key].replace(needle, () => replacement) }) };
}

// The CLI rows wait on real timeouts and graces, so each CLI run is a child
// process of this suite, started together so the waits overlap:
// `--cli-run real|<control index> <dir>` prints one JSON line
// `{ failures, missing, textError }` for the run, textError null unless the
// control's text to replace does not occur exactly once.
if (process.argv[2] === "--cli-run") {
    const index = process.argv[3] === "real" ? null : Number(process.argv[3]);
    const chosen = cliTexts(index);
    const result = chosen.error !== undefined ? { failures: [], missing: null, textError: chosen.error } : Object.assign(verifyCli(chosen.texts, process.argv[4]), { textError: null });
    process.stdout.write(JSON.stringify(result) + "\n");
    process.exit(0);
}

// Run one CLI run as a child in DIR: resolves to `{ failures, missing,
// textError }`, a failure naming the child when it does not print that line.
function cliRun(which, dir) {
    return new Promise(resolve => {
        const child = childProcess.spawn(process.execPath, [__filename, "--cli-run", String(which), dir], { stdio: ["ignore", "pipe", "inherit"] });
        const chunks = [];
        child.stdout.on("data", chunk => chunks.push(chunk));
        child.on("close", (status, signal) => {
            const out = Buffer.concat(chunks).toString("utf8");
            try {
                const result = JSON.parse(out);
                if (status === 0 && Array.isArray(result.failures)) {
                    resolve(result);
                    return;
                }
            } catch (e) {
                if (!(e instanceof SyntaxError)) throw e;
            }
            resolve({ failures: ["cli run " + which + " ended status=" + status + " signal=" + signal + " stdout=" + JSON.stringify(out)], missing: null, textError: null });
        });
    });
}

// Resolve every task in TASKS, at most LIMIT at once, in order.
async function limited(tasks, limit) {
    const results = new Array(tasks.length);
    let next = 0;
    const worker = async () => {
        while (next < tasks.length) {
            const i = next++;
            results[i] = await tasks[i]();
        }
    };
    await Promise.all(Array.from({ length: Math.min(limit, tasks.length) }, worker));
    return results;
}

let failed = false;
const report = (label, failures) => {
    for (const f of failures) console.log("  FAIL  " + label + ": " + f);
    if (failures.length > 0) failed = true;
};

async function main() {
    const tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "vgsh-pkg-")));
    try {
        report("table", verifyTable(load(TABLE)));
        const cliControls = [];
        CONTROLS.forEach(([kind, label, file, needle, replacement], index) => {
            if (kind === "cli") {
                cliControls.push(index);
                return;
            }
            const source = fs.readFileSync(file, "utf8");
            const count = source.split(needle).length - 1;
            if (count !== 1) { report("control", [label + ": the text to replace occurs " + count + " times, not once"]); return; }
            const mutant = path.join(tmp, index + "-PackageManagers.js");
            fs.writeFileSync(mutant, source.replace(needle, () => replacement));
            const failures = kind === "table" ? verifyTable(load(mutant)) : tableErrors(load(mutant)).filter(f => f.includes(kind.slice("rule:".length)));
            if (failures.length === 0) report("control", [label + ": the suite passed on a copy without that rule"]);
        });
        const runs = ["real"].concat(cliControls);
        const results = await limited(runs.map(which => () => cliRun(which, path.join(tmp, "cli-" + which))), Math.max(4, os.availableParallelism()));
        report("cli", results[0].failures);
        const missing = results[0].missing;
        cliControls.forEach((index, i) => {
            const result = results[i + 1];
            const mustHold = CONTROLS[index][5];
            if (result.textError !== null) report("control", [result.textError]);
            else if (result.failures.length === 0) report("control", [CONTROLS[index][1] + ": the suite passed on a copy without that rule"]);
            else if (mustHold !== undefined && !result.failures.some(f => f.includes(mustHold))) report("control", [CONTROLS[index][1] + ": no failure on the copy holds " + JSON.stringify(mustHold)]);
        });
        if (failed) process.exitCode = 1;
        else if (missing !== null) {
            console.log("test-vgsh-pkg: status=not-measured missing=" + missing);
            process.exitCode = 77;
        } else console.log("test-vgsh-pkg: ok detect=" + DETECT_ROWS.length + " plans=" + PLAN_ROWS.length + " picks=" + PACKAGE_FOR_ROWS.length + " parses=" + PARSE_ROWS.length + " outcomes=" + OUTCOME_ROWS.length + " controls=" + CONTROLS.length);
    } finally {
        fs.rmSync(tmp, { recursive: true, force: true });
    }
}

main();
