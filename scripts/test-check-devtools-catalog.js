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

fs.mkdirSync(runRoot, { recursive: true });
const base = JSON.parse(fs.readFileSync(CATALOG, "utf8"));
try {
    pass("shipped catalog passes", []);
    if (!base.apps.some(row => String(row.package || "").includes("matching_regex=linux-x64\\.zip"))) throw new Error("regex edge case missing from catalog");
    pass("backend option regex is accepted", []);
    if (!base.apps.some(row => String(row.package || "").endsWith("@nightly"))) throw new Error("nightly edge case missing from catalog");
    pass("non-latest tag pin is accepted", []);
    for (const row of base.databases) for (const port of row.container.ports) if (port.host !== "127.0.0.1") throw new Error("database port host is not loopback");
    pass("database loopback ports are accepted", []);

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
    refuse("bad command is refused", "catalog-command", data => { data.agents[0].command = "/bin/claude"; return data; });
    refuse("bad relative path is refused", "catalog-path", data => { data.apps[0].bin = "../herdr"; return data; });
    refuse("bad mise spec is refused", "catalog-mise-spec", data => { data.agents[0].package = "npm:"; return data; });
    refuse("unknown mise backend is refused", "catalog-mise-backend", data => { data.agents[0].package = "bogus:claude"; return data; });
    refuse("latest version pin is refused", "catalog-latest", data => { data.agents[0].package = "claude@latest"; return data; });
    refuse("bad arch is refused", "catalog-arch", data => { data.apps[0].arch = ["riscv64"]; return data; });
    refuse("bad argv is refused", "catalog-argv", data => { data.agents[0].launch = []; return data; });
    refuse("shell syntax in argv is refused", "catalog-shell-syntax", data => { data.agents[0].launch = ["claude", "a;b"]; return data; });
    refuse("interpreter evaluation argv is refused", "catalog-eval-argv", data => { data.agents[0].launch = ["sh", "-c", "true"]; return data; });
    refuse("bad buildEnv value is refused", "catalog-build-env", data => { data.agents[0].buildEnv = { UV_PYTHON: "3.13\n" }; return data; });
    refuse("bad environment name is refused", "catalog-env-name", data => { data.agents[0].buildEnv = { "UV-PYTHON": "3.13" }; return data; });
    refuse("bad settings shape is refused", "catalog-settings", data => { data.envs[0].settings = []; return data; });
    refuse("bad channels shape is refused", "catalog-channels", data => { data.apps[0].channels.default = "missing"; return data; });
    refuse("unknown installer is refused", "catalog-installer", data => { data.envs.find(row => row.id === "rust").installer = "curl"; return data; });
    refuse("bad present probe is refused", "catalog-present", data => { data.envs[0].present = { root: "node" }; return data; });
    refuse("bad package map is refused", "catalog-packages", data => { data.envs[5].packages.pacman = []; return data; });
    refuse("unknown package manager is refused", "catalog-package-manager", data => { data.envs[5].packages.zypper = ["libyaml"]; return data; });
    refuse("bad package name is refused", "catalog-package-name", data => { data.envs[5].packages.pacman = ["-Sy"]; return data; });
    refuse("bad postInstall shape is refused", "catalog-post-install", data => { data.envs.find(row => row.id === "rails").postInstall = {}; return data; });
    refuse("unknown postInstall via is refused", "catalog-via", data => { data.envs.find(row => row.id === "rails").postInstall[0].via = "missing"; return data; });
    refuse("bad container is refused", "catalog-container", data => { data.databases[0].container = "mysql"; return data; });
    refuse("bad container runtime is refused", "catalog-container-runtime", data => { data.databases[0].container.runtimes = ["rkt"]; return data; });
    refuse("non-loopback database port is refused", "catalog-container-port", data => { data.databases[0].container.ports[0].host = "0.0.0.0"; return data; });
    refuse("unused brand colour is refused", "catalog-brand-orphan", data => { for (const section of Object.keys(data)) for (const row of data[section]) if (row.brand === "xai") row.brand = "openai"; return data; });
} finally {
    fs.rmSync(runRoot, { recursive: true, force: true });
}

if (failures > 0) { console.log("test-check-devtools-catalog: failed=" + failures); process.exit(1); }
console.log("test-check-devtools-catalog: ok");
