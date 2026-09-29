.pragma library

var SECTION_NAMES = ["agents", "apps", "tools", "envs", "editors", "terminals", "databases"];
var ARCHES = ["x86_64", "aarch64"];
var INSTALLERS = ["rustup", "opam"];
var KINDS = ["cli", "gui", "tui"];
var CONTAINER_RUNTIMES = ["docker", "podman"];
var MISE_BACKENDS = ["aqua", "asdf", "cargo", "conda", "dotnet", "forgejo", "gem", "github", "gitlab", "go", "http", "npm", "packslip", "pipx", "pkgx", "s3", "spm", "ubi", "vfox"];

var COMMON_FIELDS = ["id", "name", "icon", "brand", "present", "managedBy", "packages"];
var SECTION_FIELDS = {
    agents: COMMON_FIELDS.concat(["package", "command", "bin", "exec", "launch", "arch", "channels", "buildEnv", "requires", "postInstall"]),
    apps: COMMON_FIELDS.concat(["package", "command", "bin", "exec", "launch", "kind", "arch", "channels", "buildEnv", "requires", "postInstall"]),
    tools: ["id", "name", "package", "command", "buildEnv", "requires", "present", "postInstall"],
    envs: COMMON_FIELDS.concat(["tools", "settings", "installer", "buildEnv", "requires", "postInstall"]),
    editors: COMMON_FIELDS.concat(["kind", "command", "launch", "postInstall", "requires", "arch"]),
    terminals: COMMON_FIELDS.concat(["command", "launch", "postInstall", "requires", "arch"]),
    databases: COMMON_FIELDS.concat(["container", "requires"])
};

var ID_PATTERN = /^[a-z][a-z0-9-]*$/;
var ENV_NAME_PATTERN = /^[A-Z_][A-Z0-9_]*$/;
var COMMAND_PATTERN = /^[A-Za-z0-9_+][A-Za-z0-9._+-]{0,127}$/;
var RELATIVE_PATH_PATTERN = /^[A-Za-z0-9._+/@-][A-Za-z0-9._+/@-]*(?:\/[A-Za-z0-9._+@-][A-Za-z0-9._+@-]*)*$/;
var TEXT_PATTERN = /^[^\x00-\x1f\x7f]{1,160}$/;
var OPTION_KEY_PATTERN = /^[A-Za-z_][A-Za-z0-9_.-]*$/;
var SHELL_SYNTAX = /\$\(|`|;|&&|\|\||\||>|<|[\r\n]/;
var EVAL_COMMANDS = ["eval"];
var SHELL_COMMANDS = ["sh", "bash", "zsh", "dash", "fish", "ksh"];
var EVAL_FLAGS = { python: ["-c"], python3: ["-c"], node: ["-e", "--eval"], perl: ["-e"], ruby: ["-e"] };

function hasOwn(obj, key) {
    return Object.prototype.hasOwnProperty.call(obj, key);
}

function isPlainObject(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value);
}

function listHas(list, value) {
    return list.indexOf(value) !== -1;
}

function finding(rule, path, detail) {
    return { rule: rule, path: path, detail: detail === undefined ? "" : String(detail) };
}

function printable(value) {
    return typeof value === "string" && TEXT_PATTERN.test(value) && !SHELL_SYNTAX.test(value);
}

function validPath(value) {
    return typeof value === "string" && RELATIVE_PATH_PATTERN.test(value) && value.indexOf("..") === -1 && value.charAt(0) !== "/" && value.charAt(0) !== "~";
}

function validCommand(value) {
    return typeof value === "string" && COMMAND_PATTERN.test(value);
}

function stringArray(value) {
    if (!Array.isArray(value) || value.length === 0)
        return false;
    for (var i = 0; i < value.length; i++)
        if (typeof value[i] !== "string" || value[i] === "")
            return false;
    return true;
}

function parseSpec(spec) {
    if (typeof spec !== "string" || spec === "" || /\s|[\[\]]/.test(spec.replace(/\[[^\]]*\]/g, "")))
        return { ok: false, rule: "catalog-mise-spec", detail: "invalid spec" };
    var optionsStart = spec.indexOf("[");
    var optionsEnd = spec.indexOf("]");
    var options = "";
    var base = spec;
    if (optionsStart !== -1 || optionsEnd !== -1) {
        if (optionsStart === -1 || optionsEnd === -1 || optionsEnd < optionsStart || spec.indexOf("[", optionsStart + 1) !== -1 || spec.indexOf("]", optionsEnd + 1) !== -1)
            return { ok: false, rule: "catalog-mise-spec", detail: "invalid backend options" };
        options = spec.slice(optionsStart + 1, optionsEnd);
        base = spec.slice(0, optionsStart) + spec.slice(optionsEnd + 1);
        var pairs = options.split(",");
        for (var i = 0; i < pairs.length; i++) {
            var eq = pairs[i].indexOf("=");
            if (eq <= 0 || eq === pairs[i].length - 1 || !OPTION_KEY_PATTERN.test(pairs[i].slice(0, eq)))
                return { ok: false, rule: "catalog-mise-spec", detail: "invalid option " + JSON.stringify(pairs[i]) };
            if (/[,\[\]\r\n]/.test(pairs[i].slice(eq + 1)))
                return { ok: false, rule: "catalog-mise-spec", detail: "invalid option value" };
        }
    }
    var colon = base.indexOf(":");
    var backend = colon === -1 ? "" : base.slice(0, colon);
    var nameAndVersion = colon === -1 ? base : base.slice(colon + 1);
    if (backend !== "" && !listHas(MISE_BACKENDS, backend))
        return { ok: false, rule: "catalog-mise-backend", detail: "unknown backend " + backend };
    if (nameAndVersion === "")
        return { ok: false, rule: "catalog-mise-spec", detail: "missing name" };
    var version = "";
    var at = nameAndVersion.lastIndexOf("@");
    if (at > 0) {
        version = nameAndVersion.slice(at + 1);
        nameAndVersion = nameAndVersion.slice(0, at);
        if (version === "")
            return { ok: false, rule: "catalog-mise-spec", detail: "empty version" };
        if (version === "latest")
            return { ok: false, rule: "catalog-latest", detail: "@latest is refused" };
    }
    if (/\s|[\[\]]/.test(nameAndVersion) || nameAndVersion === "")
        return { ok: false, rule: "catalog-mise-spec", detail: "invalid name" };
    return { ok: true };
}

function argvError(argv) {
    if (!stringArray(argv))
        return "argv must be a non-empty string array";
    for (var i = 0; i < argv.length; i++) {
        if (SHELL_SYNTAX.test(argv[i]))
            return "shell syntax in argv word " + JSON.stringify(argv[i]);
    }
    if (argv.length > 0 && listHas(EVAL_COMMANDS, argv[0]))
        return "interpreter evaluation form";
    if (argv.length >= 2 && listHas(SHELL_COMMANDS, argv[0]) && argv[1] === "-c")
        return "interpreter evaluation form";
    if (argv.length >= 2 && hasOwn(EVAL_FLAGS, argv[0]) && listHas(EVAL_FLAGS[argv[0]], argv[1]))
        return "interpreter evaluation form";
    if (argv[0] === "env") {
        for (var j = 1; j < argv.length; j++) {
            if (argv[j].indexOf("=") !== -1)
                continue;
            if (j + 1 < argv.length && listHas(SHELL_COMMANDS, argv[j]) && argv[j + 1] === "-c")
                return "interpreter evaluation form";
            if (j + 1 < argv.length && hasOwn(EVAL_FLAGS, argv[j]) && listHas(EVAL_FLAGS[argv[j]], argv[j + 1]))
                return "interpreter evaluation form";
            break;
        }
    }
    return "";
}

function validatePresent(value, path, out) {
    if (!isPlainObject(value)) {
        out.push(finding("catalog-present", path, "present must be an object"));
        return;
    }
    var keys = Object.keys(value);
    if (keys.length !== 1 || ["mise", "home", "command"].indexOf(keys[0]) === -1) {
        out.push(finding("catalog-present", path, "present must be one of mise, home or command"));
        return;
    }
    if (keys[0] === "command") {
        if (!validCommand(value.command)) out.push(finding("catalog-present", path + ".command", "invalid command"));
    } else if (!validPath(value[keys[0]])) {
        out.push(finding("catalog-path", path + "." + keys[0], "path must be relative and stay inside its root"));
    }
}

function validatePackages(value, path, managerIds, packageNameValid, out) {
    if (!isPlainObject(value)) {
        out.push(finding("catalog-packages", path, "packages must be an object"));
        return;
    }
    var managers = Object.keys(value);
    for (var i = 0; i < managers.length; i++) {
        var manager = managers[i];
        if (!listHas(managerIds, manager)) {
            out.push(finding("catalog-package-manager", path + "." + manager, "unknown manager"));
            continue;
        }
        if (!stringArray(value[manager])) {
            out.push(finding("catalog-packages", path + "." + manager, "package list must be non-empty strings"));
            continue;
        }
        for (var j = 0; j < value[manager].length; j++)
            if (!packageNameValid(value[manager][j]))
                out.push(finding("catalog-package-name", path + "." + manager + "[" + j + "]", "invalid package name"));
    }
}


function validateSettings(value, path, out) {
    if (!isPlainObject(value)) {
        out.push(finding("catalog-settings", path, "settings must be an object"));
        return;
    }
    var keys = Object.keys(value);
    for (var i = 0; i < keys.length; i++) {
        var key = keys[i];
        var setting = value[key];
        if (!/^[A-Za-z0-9_.-]+$/.test(key))
            out.push(finding("catalog-settings", path + "." + key, "invalid setting key"));
        if (typeof setting === "string") {
            if (setting === "" || SHELL_SYNTAX.test(setting)) out.push(finding("catalog-settings", path + "." + key, "invalid setting value"));
        } else if (typeof setting === "boolean") {
            continue;
        } else if (Array.isArray(setting)) {
            if (setting.length === 0) out.push(finding("catalog-settings", path + "." + key, "empty setting list"));
            for (var j = 0; j < setting.length; j++)
                if (typeof setting[j] !== "string" || setting[j] === "" || SHELL_SYNTAX.test(setting[j]))
                    out.push(finding("catalog-settings", path + "." + key + "[" + j + "]", "invalid setting value"));
        } else {
            out.push(finding("catalog-settings", path + "." + key, "invalid setting value"));
        }
    }
}

function validatePostInstall(value, path, ids, out) {
    var steps = Array.isArray(value) ? value : [value];
    if (steps.length === 0) {
        out.push(finding("catalog-post-install", path, "postInstall must not be empty"));
        return;
    }
    for (var i = 0; i < steps.length; i++) {
        var step = steps[i];
        var at = path + (Array.isArray(value) ? "[" + i + "]" : "");
        if (!isPlainObject(step)) {
            out.push(finding("catalog-post-install", at, "step must be an object"));
            continue;
        }
        if (hasOwn(step, "mise")) {
            var err = argvError(step.mise);
            if (err !== "") out.push(finding(err.indexOf("interpreter") === 0 ? "catalog-eval-argv" : "catalog-argv", at + ".mise", err));
            continue;
        }
        if (hasOwn(step, "exec")) {
            var e = argvError(step.exec);
            if (e !== "") out.push(finding(e.indexOf("interpreter") === 0 ? "catalog-eval-argv" : "catalog-argv", at + ".exec", e));
            if (typeof step.via !== "string" || !hasOwn(ids, step.via)) out.push(finding("catalog-via", at + ".via", "via must name an env or tool"));
            continue;
        }
        out.push(finding("catalog-post-install", at, "step must carry mise or exec"));
    }
}

function validateContainer(value, path, out) {
    if (!isPlainObject(value)) {
        out.push(finding("catalog-container", path, "container must be an object"));
        return;
    }
    var keys = Object.keys(value);
    var allowed = ["runtimes", "image", "name", "ports", "env", "volumes"];
    for (var i = 0; i < keys.length; i++)
        if (!listHas(allowed, keys[i])) out.push(finding("catalog-fields", path + "." + keys[i], "unknown container field"));
    if (!stringArray(value.runtimes)) out.push(finding("catalog-container-runtime", path + ".runtimes", "runtimes must be non-empty"));
    else for (var r = 0; r < value.runtimes.length; r++) if (!listHas(CONTAINER_RUNTIMES, value.runtimes[r])) out.push(finding("catalog-container-runtime", path + ".runtimes[" + r + "]", "unknown runtime"));
    if (!printable(value.image)) out.push(finding("catalog-container", path + ".image", "invalid image"));
    if (!validCommand(value.name)) out.push(finding("catalog-container", path + ".name", "invalid name"));
    if (!Array.isArray(value.ports) || value.ports.length === 0) out.push(finding("catalog-container-port", path + ".ports", "ports must be non-empty"));
    else for (var p = 0; p < value.ports.length; p++) {
        var port = value.ports[p];
        if (!isPlainObject(port) || port.host !== "127.0.0.1" || typeof port.hostPort !== "number" || typeof port.containerPort !== "number")
            out.push(finding("catalog-container-port", path + ".ports[" + p + "]", "ports must bind 127.0.0.1 with numeric host and container ports"));
    }
    if (value.env !== undefined) {
        if (!isPlainObject(value.env)) out.push(finding("catalog-env-name", path + ".env", "env must be an object"));
        else {
            var envKeys = Object.keys(value.env);
            for (var e = 0; e < envKeys.length; e++) {
                if (!ENV_NAME_PATTERN.test(envKeys[e])) out.push(finding("catalog-env-name", path + ".env." + envKeys[e], "invalid env name"));
                if (typeof value.env[envKeys[e]] !== "string" || SHELL_SYNTAX.test(value.env[envKeys[e]])) out.push(finding("catalog-build-env", path + ".env." + envKeys[e], "invalid env value"));
            }
        }
    }
    if (value.volumes !== undefined) {
        if (!Array.isArray(value.volumes)) out.push(finding("catalog-container", path + ".volumes", "volumes must be an array"));
        else for (var v = 0; v < value.volumes.length; v++) if (!validPath(value.volumes[v])) out.push(finding("catalog-path", path + ".volumes[" + v + "]", "invalid volume path"));
    }
}

function collectIds(catalog) {
    var ids = {};
    for (var s = 0; s < SECTION_NAMES.length; s++) {
        var section = SECTION_NAMES[s];
        var rows = catalog[section];
        if (!Array.isArray(rows)) continue;
        for (var i = 0; i < rows.length; i++)
            if (typeof rows[i].id === "string") ids[rows[i].id] = true;
    }
    return ids;
}

function validateCatalog(catalog, managerIds, lucideNames, brandKeys, packageNameValid) {
    var out = [];
    var packageValid = packageNameValid || function () { return true; };
    if (!isPlainObject(catalog))
        return { ok: false, refusals: [finding("catalog-object", "", "catalog must be an object")] };
    var keys = Object.keys(catalog);
    for (var k = 0; k < keys.length; k++)
        if (!listHas(SECTION_NAMES, keys[k])) out.push(finding("catalog-section", keys[k], "unknown section"));
    for (var required = 0; required < SECTION_NAMES.length; required++)
        if (!Array.isArray(catalog[SECTION_NAMES[required]])) out.push(finding("catalog-section-array", SECTION_NAMES[required], "section must be an array"));
    var seen = {};
    var ids = collectIds(catalog);
    for (var s = 0; s < SECTION_NAMES.length; s++) {
        var section = SECTION_NAMES[s];
        var rows = catalog[section];
        if (!Array.isArray(rows)) continue;
        for (var i = 0; i < rows.length; i++) {
            var row = rows[i];
            var path = section + "[" + i + "]";
            if (!isPlainObject(row)) { out.push(finding("catalog-entry", path, "entry must be an object")); continue; }
            var fields = Object.keys(row);
            for (var f = 0; f < fields.length; f++)
                if (!listHas(SECTION_FIELDS[section], fields[f])) out.push(finding("catalog-fields", path + "." + fields[f], "unknown field"));
            if (typeof row.id !== "string" || !ID_PATTERN.test(row.id)) out.push(finding("catalog-id", path + ".id", "id must be a slug"));
            else if (hasOwn(seen, row.id)) out.push(finding("catalog-duplicate-id", path + ".id", "already used at " + seen[row.id]));
            else seen[row.id] = path + ".id";
            if (!printable(row.name)) out.push(finding("catalog-text", path + ".name", "name must be printable text"));
            if (row.icon !== undefined && !listHas(lucideNames, row.icon)) out.push(finding("catalog-icon", path + ".icon", "unknown Lucide icon"));
            if (row.brand !== undefined && !listHas(brandKeys, row.brand)) out.push(finding("catalog-brand", path + ".brand", "unknown brand"));
            if (row.kind !== undefined && !listHas(KINDS, row.kind)) out.push(finding("catalog-kind", path + ".kind", "unknown kind"));
            if (row.command !== undefined && !validCommand(row.command)) out.push(finding("catalog-command", path + ".command", "invalid command"));
            if (row.bin !== undefined && !validPath(row.bin)) out.push(finding("catalog-path", path + ".bin", "invalid bin path"));
            if (row.exec !== undefined && !validPath(row.exec)) out.push(finding("catalog-path", path + ".exec", "invalid exec path"));
            if (row.package !== undefined) {
                var spec = parseSpec(row.package);
                if (!spec.ok) out.push(finding(spec.rule, path + ".package", spec.detail));
            }
            if (row.tools !== undefined) {
                if (!stringArray(row.tools)) out.push(finding("catalog-mise-spec", path + ".tools", "tools must be non-empty strings"));
                else for (var t = 0; t < row.tools.length; t++) {
                    var tool = parseSpec(row.tools[t]);
                    if (!tool.ok) out.push(finding(tool.rule, path + ".tools[" + t + "]", tool.detail));
                }
            }
            if (row.requires !== undefined) {
                if (!stringArray(row.requires)) out.push(finding("catalog-mise-spec", path + ".requires", "requires must be non-empty strings"));
                else for (var q = 0; q < row.requires.length; q++) {
                    var req = parseSpec(row.requires[q]);
                    if (!req.ok) out.push(finding(req.rule, path + ".requires[" + q + "]", req.detail));
                }
            }
            if (row.arch !== undefined) {
                if (!stringArray(row.arch)) out.push(finding("catalog-arch", path + ".arch", "arch must be a non-empty string array"));
                else for (var a = 0; a < row.arch.length; a++) if (!listHas(ARCHES, row.arch[a])) out.push(finding("catalog-arch", path + ".arch[" + a + "]", "unknown arch"));
            }
            if (row.launch !== undefined) {
                var launchErr = argvError(row.launch);
                if (launchErr !== "") out.push(finding(launchErr.indexOf("interpreter") === 0 ? "catalog-eval-argv" : launchErr.indexOf("shell syntax") === 0 ? "catalog-shell-syntax" : "catalog-argv", path + ".launch", launchErr));
            }
            if (row.buildEnv !== undefined) {
                if (!isPlainObject(row.buildEnv)) out.push(finding("catalog-build-env", path + ".buildEnv", "buildEnv must be an object"));
                else {
                    var buildKeys = Object.keys(row.buildEnv);
                    for (var b = 0; b < buildKeys.length; b++) {
                        if (!ENV_NAME_PATTERN.test(buildKeys[b])) out.push(finding("catalog-env-name", path + ".buildEnv." + buildKeys[b], "invalid env name"));
                        if (!printable(String(row.buildEnv[buildKeys[b]]))) out.push(finding("catalog-build-env", path + ".buildEnv." + buildKeys[b], "invalid env value"));
                    }
                }
            }
            if (row.settings !== undefined) validateSettings(row.settings, path + ".settings", out);
            if (row.channels !== undefined) {
                if (!isPlainObject(row.channels) || typeof row.channels.default !== "string" || !isPlainObject(row.channels.options) || !hasOwn(row.channels.options, row.channels.default)) out.push(finding("catalog-channels", path + ".channels", "channels must declare default and options"));
                else {
                    var channelKeys = Object.keys(row.channels.options);
                    for (var c = 0; c < channelKeys.length; c++)
                        if (!ID_PATTERN.test(channelKeys[c]) || (row.channels.options[channelKeys[c]] !== "" && !printable(row.channels.options[channelKeys[c]]))) out.push(finding("catalog-channels", path + ".channels.options." + channelKeys[c], "invalid channel option"));
                }
            }
            if (row.installer !== undefined && !listHas(INSTALLERS, row.installer)) out.push(finding("catalog-installer", path + ".installer", "unknown installer"));
            if (row.managedBy !== undefined && !validCommand(row.managedBy)) out.push(finding("catalog-command", path + ".managedBy", "invalid command"));
            if (row.present !== undefined) validatePresent(row.present, path + ".present", out);
            if (row.packages !== undefined) validatePackages(row.packages, path + ".packages", managerIds, packageValid, out);
            if (row.postInstall !== undefined) validatePostInstall(row.postInstall, path + ".postInstall", ids, out);
            if (row.container !== undefined) validateContainer(row.container, path + ".container", out);
        }
    }
    return { ok: out.length === 0, refusals: out };
}
