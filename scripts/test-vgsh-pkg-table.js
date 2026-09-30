#!/usr/bin/env node
// The package-manager table, shell/Core/PackageManagers.js (D034). Every
// expected value below was written by hand from the managers' own argv,
// never read from the table.
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
// - packageFor picks a requirement's package for a detected system, and
//   installGroups groups the picks by manager with the arguments
//   `vgsh pkg run install` takes for each.
// - Each update parser reads the canned outputs under scripts/fixtures/pkg/
//   and inline odd lines; each manager's update query and the meaning of
//   its exit statuses are pinned. No row touches the network.
// - The owner and installed queries pin each manager's argv and read each
//   manager's output, written from its documentation, into a name or a
//   version.
//
// The controls at the end edit a copy of the table, one rule at a time,
// and require this suite to fail on each copy.
"use strict";
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { load } = require("../bin/lib/qml-library.js");
const { TABLE, FIXTURES } = require("./vgsh-pkg-shared.js");
const ELEVATORS = ["sudo", "doas", "run0", "pkexec", "su"];
const PLACEHOLDERS = ["{bin}", "{names}", "{name}", "{path}"];
const EXIT_MEANINGS = ["updates", "none", "rows"];

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

// installGroups rows: name, the rows' packages, detect's answer, the picks
// as manager/name or null, then each group as [manager, primary, names,
// installs, the arguments after `vgsh pkg run install` or null].
const NIX = { id: "nix", binary: "nix" };
const FLATPAK = { id: "flatpak", binary: "flatpak" };
const INSTALL_GROUP_ROWS = [
    ["one primary package", [{ pacman: "gum" }], { primary: PACMAN, overlays: [PARU], sources: [] },
        ["pacman/gum"], [["pacman", true, ["gum"], true, ["gum"]]]],
    ["an overlay's install names its manager, after the primary's", [{ aur: "vsys" }, { pacman: "gum" }], { primary: PACMAN, overlays: [PARU], sources: [] },
        ["aur/vsys", "pacman/gum"], [["pacman", true, ["gum"], true, ["gum"]], ["aur", false, ["vsys"], true, ["--manager", "aur", "vsys"]]]],
    ["a package two commands share is installed once", [{ pacman: "coreutils" }, { pacman: "coreutils" }, { pacman: "gum" }], { primary: PACMAN, overlays: [], sources: [] },
        ["pacman/coreutils", "pacman/coreutils", "pacman/gum"], [["pacman", true, ["coreutils", "gum"], true, ["coreutils", "gum"]]]],
    ["a source comes after the overlays", [{ mise: "node" }, { aur: "vsys" }], { primary: PACMAN, overlays: [PARU], sources: [MISE] },
        ["mise/node", "aur/vsys"], [["aur", false, ["vsys"], true, ["--manager", "aur", "vsys"]], ["mise", false, ["node"], true, ["--manager", "mise", "node"]]]],
    ["a row no present manager maps is picked by none", [{ apt: "gum" }, { pacman: "fzf" }], { primary: PACMAN, overlays: [], sources: [] },
        [null, "pacman/fzf"], [["pacman", true, ["fzf"], true, ["fzf"]]]],
    ["nix installs nothing through vgsh", [{ nix: "gum" }, { flatpak: "org.flat" }], { primary: NIX, overlays: [FLATPAK], sources: [] },
        ["nix/gum", "flatpak/org.flat"], [["nix", true, ["gum"], false, null], ["flatpak", false, ["org.flat"], true, ["--manager", "flatpak", "org.flat"]]]],
    ["no row", [], { primary: PACMAN, overlays: [], sources: [] }, [], []]
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
// The formats come from the sources docs/architecture/packages.md § Queries
// names.
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
    for (const [name, rows, found, picks, groups] of INSTALL_GROUP_ROWS) {
        const plan = t.installGroups(rows.map(packages => ({ packages })), found);
        const gotPicks = plan.picks.map(p => p === null ? null : p.manager + "/" + p.name);
        const gotGroups = plan.groups.map(g => [g.manager, g.primary, g.names, g.installs, g.installs ? t.installArgs(g) : null]);
        if (!same(gotPicks, picks)) failures.push("installGroups: " + name + ": picks " + JSON.stringify(gotPicks));
        if (!same(gotGroups, groups)) failures.push("installGroups: " + name + ": groups " + JSON.stringify(gotGroups));
    }
    const refusal = (() => { try { t.installArgs({ manager: "nix", primary: true, names: ["gum"], installs: false }); return "answered"; } catch (e) { return e.message; } })();
    if (refusal !== "installArgs: manager nix has no install steps") failures.push("installArgs: a manager without install steps: got " + JSON.stringify(refusal));

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
    ["table", "a requirement's package ignores the primary's rank", TABLE, "return (found.primary === null ? [] : [found.primary]).concat(found.overlays, found.sources);", "return found.overlays.concat(found.sources, found.primary === null ? [] : [found.primary]);"],
    ["table", "a requirement's package is picked for an unmapped manager", TABLE, "if (Object.prototype.hasOwnProperty.call(packages, order[i].id))", "if (true)"],
    ["table", "a package two commands share is installed twice", TABLE, " && names.indexOf(picks[j].name) === -1) names.push", ") names.push"],
    ["table", "the primary's install names its manager", TABLE, "return (group.primary ? [] : [\"--manager\", group.manager]).concat(group.names);", "return [\"--manager\", group.manager].concat(group.names);"],
    ["table", "an overlay's install omits its manager", TABLE, "return (group.primary ? [] : [\"--manager\", group.manager]).concat(group.names);", "return group.names;"],
    ["table", "nix is offered an install", TABLE, "installs: managerRow(order[i].id).install !== null", "installs: true"],
    ["table", "a query's answer ignores its pattern", TABLE, "return m === null ? null : m[1];", "return stdout.split(\"\\n\")[0];"],
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
];

let failed = false;
const report = (label, failures) => {
    for (const f of failures) console.log("  FAIL  " + label + ": " + f);
    if (failures.length > 0) failed = true;
};

function runControl(tmp, control, index) {
    const [kind, label, file, needle, replacement] = control;
    const source = fs.readFileSync(file, "utf8");
    const count = source.split(needle).length - 1;
    if (count !== 1) {
        report("control", [label + ": the text to replace occurs " + count + " times, not once"]);
        return;
    }
    const mutant = path.join(tmp, index + "-PackageManagers.js");
    fs.writeFileSync(mutant, source.replace(needle, () => replacement));
    const failures = kind === "table" ? verifyTable(load(mutant)) : tableErrors(load(mutant)).filter(f => f.includes(kind.slice("rule:".length)));
    if (failures.length === 0) report("control", [label + ": the suite passed on a copy without that rule"]);
}

function main() {
    const tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "vgsh-pkg-table-")));
    try {
        report("table", verifyTable(load(TABLE)));
        CONTROLS.forEach((control, index) => runControl(tmp, control, index));
        if (failed) process.exitCode = 1;
        else console.log("test-vgsh-pkg-table: ok detect=" + DETECT_ROWS.length + " ids=" + ID_ROWS.length + " plans=" + PLAN_ROWS.length + " queries=" + QUERY_ROWS.length + " answers=" + ANSWER_ROWS.length + " pickers=" + PICKER_ROWS.length + " elevators=" + ELEVATOR_ROWS.length + " picks=" + PACKAGE_FOR_ROWS.length + " groups=" + INSTALL_GROUP_ROWS.length + " parses=" + PARSE_ROWS.length + " checks=" + CHECK_ROWS.length + " outcomes=" + OUTCOME_ROWS.length + " controls=" + CONTROLS.length);
    } finally {
        fs.rmSync(tmp, { recursive: true, force: true });
    }
}

main();
