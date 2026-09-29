#!/usr/bin/env node
// Controls for scripts/check-devtools-catalog.js. The shipped catalog passes,
// then each row plants one defect in a fixture copy and asserts the stable
// rule id that must fire. Fixture directories live under repo tmp/ so the
// suite never depends on a host temporary directory.
"use strict";
const childProcess = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const repo = path.join(__dirname, "..");
const CHECK = path.join(repo, "scripts", "check-devtools-catalog.js");
const CATALOG = path.join(repo, "shell", "plugins", "vgs.devtools", "catalog.json");
const { load } = require("./qml-library.js");
const ENV = { PATH: process.env.PATH, LC_ALL: "C" };
const runRoot = path.join(repo, "tmp", "test-check-devtools-catalog-" + process.pid + "-" + Date.now());
let failures = 0;

function clone(value) {
    return JSON.parse(JSON.stringify(value));
}

function writeFixture(name, value) {
    const file = path.join(runRoot, name + ".json");
    fs.writeFileSync(file, JSON.stringify(value, null, 2) + "\n");
    return file;
}

function run(args) {
    return childProcess.spawnSync(process.execPath, [CHECK, ...args], { encoding: "utf8", env: ENV });
}

function lineHasRule(stdout, rule) {
    return stdout.split("\n").some(line => line.startsWith(rule + " "));
}

function writeAppearance(name, text) {
    const file = path.join(runRoot, name + ".js");
    fs.writeFileSync(file, text);
    return file;
}

function pass(name, args) {
    const proc = run(args);
    const ok = proc.status === 0 && proc.stdout.includes("check-devtools-catalog: ok");
    console.log((ok ? "  ok    " : "  FAIL  ") + name + (ok ? "" : "\n" + proc.stdout + proc.stderr));
    if (!ok) failures += 1;
}

function refuse(name, rule, mutate) {
    const data = clone(base);
    const fixture = writeFixture(name.replace(/[^A-Za-z0-9_-]/g, "-"), mutate(data));
    const proc = run([fixture]);
    const ok = proc.status === 1 && lineHasRule(proc.stdout, rule);
    console.log((ok ? "  ok    " : "  FAIL  ") + name + (ok ? "" : ` (want ${rule}, exit ${proc.status})\n${proc.stdout}${proc.stderr}`));
    if (!ok) failures += 1;
}

function directRefuse(name, rule, build) {
    const out = build().refusals;
    const ok = out.some(finding => finding.rule === rule);
    console.log((ok ? "  ok    " : "  FAIL  ") + name + (ok ? "" : ` (want ${rule})\n${JSON.stringify(out)}`));
    if (!ok) failures += 1;
}

fs.mkdirSync(runRoot, { recursive: true });
const base = JSON.parse(fs.readFileSync(CATALOG, "utf8"));
const Logic = load(path.join(repo, "shell", "plugins", "vgs.devtools", "CatalogLogic.js"));
const Managers = load(path.join(repo, "shell", "Core", "PackageManagers.js"));
const Lucide = load(path.join(repo, "shell", "Ui", "icons", "Lucide.js"));
const Appearance = load(path.join(repo, "shell", "plugins", "vgs.devtools", "Appearance.js"));
const brand = Logic.validateBrandTable(base, Appearance.TOKENS.brand);
const context = { managerIds: Managers.MANAGERS.map(row => row.id), lucideNames: Object.keys(Lucide.ICONS), brandKeys: brand.brandKeys, packageNameValid: Managers.validName };
try {
    pass("shipped catalog passes", []);
    if (!base.apps.some(row => String(row.package || "").includes("matching_regex=linux-x64\\.zip"))) throw new Error("regex edge case missing from catalog");
    pass("backend option regex is accepted", []);
    if (!base.apps.some(row => String(row.package || "").endsWith("@nightly"))) throw new Error("nightly edge case missing from catalog");
    pass("non-latest tag pin is accepted", []);
    for (const row of base.databases) for (const port of row.container.ports) if (port.host !== "127.0.0.1") throw new Error("database port host is not loopback");
    pass("database loopback ports are accepted", []);
    if (!base.envs.find(row => row.id === "php").postInstall[0].exec.some(word => word && word.home === ".local/bin")) throw new Error("home argv word edge case missing from catalog");
    pass("home argv words are accepted", []);
    if (base.envs.find(row => row.id === "phoenix").present.prefix !== "phx_new-") throw new Error("prefix probe edge case missing from catalog");
    pass("home prefix probes are accepted", []);

    refuse("catalog must be an object", "catalog-object", () => []);
    refuse("unknown section is refused", "catalog-section", data => { data.widgets = []; return data; });
    refuse("section must be an array", "catalog-section-array", data => { data.agents = {}; return data; });
    refuse("entry must be an object", "catalog-entry", data => { data.agents[0] = "claude"; return data; });
    refuse("unknown field is refused", "catalog-fields", data => { data.agents[0].extra = true; return data; });
    refuse("bad id is refused", "catalog-id", data => { data.agents[0].id = "Claude"; return data; });
    refuse("duplicate id is refused", "catalog-duplicate-id", data => { data.agents[1].id = data.agents[0].id; return data; });
    refuse("bad text is refused", "catalog-text", data => { data.agents[0].name = "Claude\nCode"; return data; });
    refuse("unknown icon is refused", "catalog-icon", data => { data.agents[0].icon = "no-such-icon"; return data; });
    refuse("unknown brand is refused", "catalog-brand", data => { data.agents[0].brand = "noSuchBrand"; return data; });
    refuse("unknown kind is refused", "catalog-kind", data => { data.apps[0].kind = "daemon"; return data; });
    refuse("missing required field is refused", "catalog-required", data => { delete data.agents[0].launch; return data; });
    refuse("missing install route is refused", "catalog-install-route", data => { delete data.editors[0].packages; return data; });
    refuse("bad command is refused", "catalog-command", data => { data.agents[0].command = "/bin/claude"; return data; });
    refuse("bad relative path is refused", "catalog-path", data => { data.apps[0].bin = "../herdr"; return data; });
    refuse("bad mise spec is refused", "catalog-mise-spec", data => { data.agents[0].package = "npm:"; return data; });
    refuse("unknown mise backend is refused", "catalog-mise-backend", data => { data.agents[0].package = "bogus:claude"; return data; });
    refuse("latest version pin is refused", "catalog-latest", data => { data.agents[0].package = "claude@latest"; return data; });
    refuse("bad arch is refused", "catalog-arch", data => { data.apps[0].arch = ["riscv64"]; return data; });
    refuse("bad argv is refused", "catalog-argv", data => { data.agents[0].launch = []; return data; });
    refuse("shell syntax in argv is refused", "catalog-shell-syntax", data => { data.agents[0].launch = ["claude", "a;b"]; return data; });
    refuse("interpreter evaluation argv is refused", "catalog-eval-argv", data => { data.agents[0].launch = ["sh", "-c", "true"]; return data; });
    refuse("postInstall shell syntax is refused with its own rule", "catalog-shell-syntax", data => { data.envs.find(row => row.id === "rails").postInstall[0].exec = ["gem", "install;rails"]; return data; });
    refuse("absolute home argv word is refused", "catalog-home-word", data => { data.envs.find(row => row.id === "php").postInstall[0].exec[4] = { home: "/.local/bin" }; return data; });
    refuse("escaping home argv word is refused", "catalog-home-word", data => { data.envs.find(row => row.id === "php").postInstall[0].exec[4] = { home: "../bin" }; return data; });
    refuse("versioned shell eval is refused", "catalog-eval-argv", data => { data.agents[0].launch = ["/bin/sh", "-c", "true"]; return data; });
    refuse("login shell eval is refused", "catalog-eval-argv", data => { data.agents[0].launch = ["bash", "-lc", "true"]; return data; });
    refuse("clustered shell eval is refused", "catalog-eval-argv", data => { data.agents[0].launch = ["sh", "-ec", "true"]; return data; });
    refuse("versioned python eval is refused", "catalog-eval-argv", data => { data.agents[0].launch = ["python3.12", "-c", "print(1)"]; return data; });
    refuse("env split string is refused", "catalog-eval-argv", data => { data.agents[0].launch = ["env", "-S", "sh -c true"]; return data; });
    refuse("env wrapped shell eval is refused", "catalog-eval-argv", data => { data.agents[0].launch = ["env", "VAR=1", "bash", "-c", "true"]; return data; });
    refuse("mise x wrapped node eval is refused", "catalog-eval-argv", data => { data.agents[0].launch = ["mise", "x", "node", "--", "node", "-e", "true"]; return data; });
    refuse("mise exec wrapped shell eval is refused", "catalog-eval-argv", data => { data.agents[0].launch = ["mise", "exec", "--", "sh", "-c", "true"]; return data; });
    refuse("bad buildEnv value is refused", "catalog-build-env", data => { data.agents[0].buildEnv = { UV_PYTHON: "3.13\n" }; return data; });
    refuse("bad environment name is refused", "catalog-env-name", data => { data.agents[0].buildEnv = { "UV-PYTHON": "3.13" }; return data; });
    refuse("bad settings shape is refused", "catalog-settings", data => { data.envs[0].settings = []; return data; });
    refuse("bad channels shape is refused", "catalog-channels", data => { data.apps[0].channels.default = "missing"; return data; });
    refuse("malformed channel backend option is refused", "catalog-channels", data => { data.apps[0].channels.options.preview = "bad"; return data; });
    refuse("unknown installer is refused", "catalog-installer", data => { data.envs.find(row => row.id === "rust").installer = "curl"; return data; });
    refuse("bad present probe is refused", "catalog-present", data => { data.envs[0].present = { root: "node" }; return data; });
    refuse("bad present command list is refused", "catalog-present", data => { data.editors.find(row => row.id === "helix").present.command = ["hx", "/bin/helix"]; return data; });
    refuse("bad present prefix is refused", "catalog-present-prefix", data => { data.envs.find(row => row.id === "phoenix").present.prefix = "phx\n"; return data; });
    refuse("bad package map is refused", "catalog-packages", data => { data.envs[5].packages.pacman = []; return data; });
    refuse("unknown package manager is refused", "catalog-package-manager", data => { data.envs[5].packages.zypper = ["libyaml"]; return data; });
    refuse("bad package name is refused", "catalog-package-name", data => { data.envs[5].packages.pacman = ["-Sy"]; return data; });
    refuse("flatpak package with host command launcher is refused", "catalog-flatpak-host-command", data => { data.editors.find(row => row.id === "zed").packages.flatpak = ["dev.zed.Zed"]; return data; });
    refuse("bad postInstall shape is refused", "catalog-post-install", data => { data.envs.find(row => row.id === "rails").postInstall = {}; return data; });
    refuse("unknown postInstall via is refused", "catalog-via", data => { data.envs.find(row => row.id === "rails").postInstall[0].via = "missing"; return data; });
    refuse("postInstall via cannot name a non-mise entry", "catalog-via", data => { data.envs.find(row => row.id === "rails").postInstall[0].via = "rust"; return data; });
    refuse("database present is refused", "catalog-fields", data => { data.databases[0].present = { command: "docker" }; return data; });
    refuse("bad container is refused", "catalog-container", data => { data.databases[0].container = "mysql"; return data; });
    refuse("bad container runtime is refused", "catalog-container-runtime", data => { data.databases[0].container.runtimes = ["rkt"]; return data; });
    refuse("null container port is refused without a crash", "catalog-container-port", data => { data.databases[0].container.ports[0] = null; return data; });
    refuse("non-loopback database port is refused", "catalog-container-port", data => { data.databases[0].container.ports[0].host = "0.0.0.0"; return data; });
    refuse("unused brand colour is refused", "catalog-brand-orphan", data => { for (const section of Object.keys(data)) for (const row of data[section]) if (row.brand === "xai") row.brand = "openai"; return data; });
    const nestedBrand = writeAppearance("nested-brand", '.pragma library\nfunction color(value) { return { type: "color", value: value }; }\nfunction number(value, min, max) { return { type: "number", value: value, min: min, max: max }; }\nvar TOKENS = { palette: { accent: color("#ff5a36") }, motion: { scale: number(1, 0, 4) }, brand: { nested: { claude: color("#D97757") } } };\nvar LIGHT = {};\n');
    let proc = run(["--appearance", nestedBrand]);
    let ok = proc.status === 1 && lineHasRule(proc.stdout, "catalog-brand-table");
    console.log((ok ? "  ok    " : "  FAIL  ") + "nested brand table is refused" + (ok ? "" : `\n${proc.stdout}${proc.stderr}`));
    if (!ok) failures += 1;
    const badAppearance = writeAppearance("bad-appearance", '.pragma library\nvar TOKENS = { palette: { accent: { type: "number", value: 1, min: 0, max: 1 } }, motion: { scale: { type: "number", value: 1, min: 0, max: 4 } }, brand: {} };\nvar LIGHT = {};\n');
    proc = run(["--appearance", badAppearance]);
    ok = proc.status === 1 && lineHasRule(proc.stdout, "catalog-appearance");
    console.log((ok ? "  ok    " : "  FAIL  ") + "appearance refusal is reported" + (ok ? "" : `\n${proc.stdout}${proc.stderr}`));
    if (!ok) failures += 1;
    const invalidAppearance = writeAppearance("invalid-appearance", 'var TOKENS = {};\n');
    proc = run(["--appearance", invalidAppearance]);
    ok = proc.status === 2 && proc.stdout.startsWith("check-devtools-catalog: unreadable:");
    console.log((ok ? "  ok    " : "  FAIL  ") + "appearance load failure exits 2" + (ok ? "" : `\n${proc.stdout}${proc.stderr}`));
    if (!ok) failures += 1;
    directRefuse("missing context is refused", "catalog-context", () => Logic.validateCatalog(base));
} finally {
    fs.rmSync(runRoot, { recursive: true, force: true });
}

if (failures > 0) { console.log("test-check-devtools-catalog: failed=" + failures); process.exit(1); }
console.log("test-check-devtools-catalog: ok");
