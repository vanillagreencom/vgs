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
    databases: ["id", "name", "icon", "brand", "container", "requires", "packages"]
};
var REQUIRED_FIELDS = {
    agents: ["id", "name", "icon", "brand", "package", "command", "launch"],
    apps: ["id", "name", "icon", "brand", "package", "command", "launch"],
    tools: ["id", "name", "package", "command"],
    envs: ["id", "name", "icon", "brand", "present"],
    editors: ["id", "name", "icon", "brand", "kind", "command", "launch", "present"],
    terminals: ["id", "name", "icon", "brand", "command", "launch", "present"],
    databases: ["id", "name", "icon", "brand", "container"]
};

var ID_PATTERN = /^[a-z][a-z0-9-]*$/;
var ENV_NAME_PATTERN = /^[A-Z_][A-Z0-9_]*$/;
var COMMAND_PATTERN = /^[A-Za-z0-9_+][A-Za-z0-9._+-]{0,127}$/;
var RELATIVE_PATH_PATTERN = /^[A-Za-z0-9._+/@-][A-Za-z0-9._+/@-]*(?:\/[A-Za-z0-9._+@-][A-Za-z0-9._+@-]*)*$/;
var TEXT_PATTERN = /^[^\x00-\x1f\x7f]{1,160}$/;
var OPTION_KEY_PATTERN = /^[A-Za-z_][A-Za-z0-9_.-]*$/;
var SHELL_SYNTAX = new RegExp("\\$\\(|`|;|&&|\\|\\||\\||>|<|[\\r\\n]");
var SHELL_NAMES = ["sh", "bash", "zsh", "dash", "fish", "ksh"];
var EVAL_COMMANDS = ["eval"];
var WRAPPER_COMMANDS = ["env", "mise"];

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

function result(out) {
    return { ok: out.length === 0, refusals: out };
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

function commandBase(value) {
    if (typeof value !== "string")
        return "";
    var parts = value.split("/");
    return parts[parts.length - 1];
}

function isShellCommand(value) {
    return listHas(SHELL_NAMES, commandBase(value));
}

function isEvalInterpreter(value) {
    var base = commandBase(value);
    return /^(python|python[0-9]+(?:\.[0-9]+)?|node|nodejs|perl|ruby)$/.test(base);
}

function isShellEvalFlag(flag) {
    return typeof flag === "string" && /^-[A-Za-z]*c[A-Za-z]*$/.test(flag);
}

function isInterpreterEvalFlag(flag) {
    return flag === "-c" || flag === "-e" || flag === "--eval" || flag === "--command";
}

function isStringList(value) {
    if (!Array.isArray(value) || value.length === 0)
        return false;
    for (var i = 0; i < value.length; i++)
        if (typeof value[i] !== "string" || value[i] === "")
            return false;
    return true;
}

function validateStringList(value, path, rule, out) {
    if (!isStringList(value)) {
        out.push(finding(rule, path, "must be a non-empty string array"));
        return false;
    }
    return true;
}

function validateHomeWord(value, path, out) {
    if (!isPlainObject(value) || Object.keys(value).length !== 1 || typeof value.home !== "string" || !validPath(value.home)) {
        out.push(finding("catalog-home-word", path, "home word must be a relative path below HOME"));
        return false;
    }
    return true;
}

function validateArgvWord(value, path, out) {
    if (typeof value === "string") {
        if (value === "") {
            out.push(finding("catalog-argv", path, "argv word must be non-empty"));
            return false;
        }
        if (SHELL_SYNTAX.test(value)) {
            out.push(finding("catalog-shell-syntax", path, "shell syntax in argv word"));
            return false;
        }
        return true;
    }
    return validateHomeWord(value, path, out);
}

function inspectEvaluation(words) {
    if (words.length === 0)
        return "";
    var first = words[0];
    if (listHas(EVAL_COMMANDS, commandBase(first)))
        return "interpreter evaluation form";
    if (isShellCommand(first) && words.length >= 2 && isShellEvalFlag(words[1]))
        return "interpreter evaluation form";
    if (isEvalInterpreter(first) && words.length >= 2 && isInterpreterEvalFlag(words[1]))
        return "interpreter evaluation form";
    if (commandBase(first) === "env")
        return inspectEnv(words);
    if (commandBase(first) === "mise")
        return inspectMise(words);
    return "";
}

function inspectEnv(words) {
    var i = 1;
    while (i < words.length) {
        if (words[i] === "-S" || words[i] === "--split-string")
            return "interpreter evaluation form";
        if (words[i].indexOf("=") !== -1) {
            i += 1;
            continue;
        }
        return inspectEvaluation(words.slice(i));
    }
    return "";
}

function inspectMise(words) {
    if (words.length < 2 || (words[1] !== "x" && words[1] !== "exec"))
        return "";
    var split = -1;
    for (var i = 2; i < words.length; i++) {
        if (words[i] === "--") {
            split = i;
            break;
        }
    }
    return split === -1 ? "" : inspectEvaluation(words.slice(split + 1));
}

function validateArgv(value, path, out) {
    if (!Array.isArray(value) || value.length === 0) {
        out.push(finding("catalog-argv", path, "argv must be a non-empty array"));
        return false;
    }
    var words = [];
    var ok = true;
    for (var i = 0; i < value.length; i++) {
        ok = validateArgvWord(value[i], path + "[" + i + "]", out) && ok;
        if (typeof value[i] === "string")
            words.push(value[i]);
    }
    var evalError = inspectEvaluation(words);
    if (evalError !== "") {
        out.push(finding("catalog-eval-argv", path, evalError));
        ok = false;
    }
    return ok;
}

function parseBackendOptions(options) {
    if (options === "")
        return { ok: true };
    var pairs = options.split(",");
    for (var i = 0; i < pairs.length; i++) {
        var eq = pairs[i].indexOf("=");
        if (eq <= 0 || eq === pairs[i].length - 1 || !OPTION_KEY_PATTERN.test(pairs[i].slice(0, eq)))
            return { ok: false, detail: "invalid option " + JSON.stringify(pairs[i]) };
        if (/[\[\]\r\n]/.test(pairs[i].slice(eq + 1)))
            return { ok: false, detail: "invalid option value" };
    }
    return { ok: true };
}

function parseSpec(spec) {
    if (typeof spec !== "string" || spec === "" || /\s|[\[\]]/.test(spec.replace(/\[[^\]]*\]/g, "")))
        return { ok: false, rule: "catalog-mise-spec", detail: "invalid spec" };
    var optionsStart = spec.indexOf("[");
    var optionsEnd = spec.indexOf("]");
    var base = spec;
    if (optionsStart !== -1 || optionsEnd !== -1) {
        if (optionsStart === -1 || optionsEnd === -1 || optionsEnd < optionsStart || spec.indexOf("[", optionsStart + 1) !== -1 || spec.indexOf("]", optionsEnd + 1) !== -1)
            return { ok: false, rule: "catalog-mise-spec", detail: "invalid backend options" };
        var options = parseBackendOptions(spec.slice(optionsStart + 1, optionsEnd));
        if (!options.ok)
            return { ok: false, rule: "catalog-mise-spec", detail: options.detail };
        base = spec.slice(0, optionsStart) + spec.slice(optionsEnd + 1);
    }
    var colon = base.indexOf(":");
    var backend = colon === -1 ? "" : base.slice(0, colon);
    var nameAndVersion = colon === -1 ? base : base.slice(colon + 1);
    if (backend !== "" && !listHas(MISE_BACKENDS, backend))
        return { ok: false, rule: "catalog-mise-backend", detail: "unknown backend " + backend };
    if (nameAndVersion === "")
        return { ok: false, rule: "catalog-mise-spec", detail: "missing name" };
    var at = nameAndVersion.lastIndexOf("@");
    if (at > 0) {
        var version = nameAndVersion.slice(at + 1);
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

function validateSpecField(value, path, out) {
    var parsed = parseSpec(value);
    if (!parsed.ok)
        out.push(finding(parsed.rule, path, parsed.detail));
}

function validateSpecList(value, path, out) {
    if (!validateStringList(value, path, "catalog-mise-spec", out))
        return;
    for (var i = 0; i < value.length; i++)
        validateSpecField(value[i], path + "[" + i + "]", out);
}

function validatePresent(value, path, out) {
    if (!isPlainObject(value)) {
        out.push(finding("catalog-present", path, "present must be an object"));
        return;
    }
    var keys = Object.keys(value);
    if (keys.length === 1 && keys[0] === "mise") {
        if (!validPath(value.mise))
            out.push(finding("catalog-path", path + ".mise", "path must be relative and stay inside its root"));
        return;
    }
    if (keys.length === 1 && keys[0] === "command") {
        validateCommandProbe(value.command, path + ".command", out);
        return;
    }
    if ((keys.length === 1 || keys.length === 2) && hasOwn(value, "home")) {
        if (!validPath(value.home))
            out.push(finding("catalog-path", path + ".home", "path must be relative and stay inside HOME"));
        if (hasOwn(value, "prefix") && !printable(value.prefix))
            out.push(finding("catalog-present-prefix", path + ".prefix", "prefix must be printable text"));
        return;
    }
    out.push(finding("catalog-present", path, "present must be mise, home, command or home plus prefix"));
}

function validateCommandProbe(value, path, out) {
    if (typeof value === "string") {
        if (!validCommand(value))
            out.push(finding("catalog-present", path, "invalid command"));
        return;
    }
    if (!validateStringList(value, path, "catalog-present", out))
        return;
    for (var i = 0; i < value.length; i++)
        if (!validCommand(value[i]))
            out.push(finding("catalog-present", path + "[" + i + "]", "invalid command"));
}

function validatePackages(value, path, context, out) {
    if (!isPlainObject(value)) {
        out.push(finding("catalog-packages", path, "packages must be an object"));
        return;
    }
    var managers = Object.keys(value);
    if (managers.length === 0)
        out.push(finding("catalog-packages", path, "packages must not be empty"));
    for (var i = 0; i < managers.length; i++) {
        var manager = managers[i];
        if (!listHas(context.managerIds, manager)) {
            out.push(finding("catalog-package-manager", path + "." + manager, "unknown manager"));
            continue;
        }
        if (!validateStringList(value[manager], path + "." + manager, "catalog-packages", out))
            continue;
        for (var j = 0; j < value[manager].length; j++)
            if (!context.packageNameValid(value[manager][j]))
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
            if (setting === "" || SHELL_SYNTAX.test(setting))
                out.push(finding("catalog-settings", path + "." + key, "invalid setting value"));
        } else if (typeof setting !== "boolean" && !isStringList(setting)) {
            out.push(finding("catalog-settings", path + "." + key, "invalid setting value"));
        }
    }
}

function validatePostInstall(value, path, ids, miseIds, out) {
    var steps = Array.isArray(value) ? value : [value];
    if (steps.length === 0) {
        out.push(finding("catalog-post-install", path, "postInstall must not be empty"));
        return;
    }
    for (var i = 0; i < steps.length; i++)
        validatePostInstallStep(steps[i], path + (Array.isArray(value) ? "[" + i + "]" : ""), ids, miseIds, out);
}

function validatePostInstallStep(step, path, ids, miseIds, out) {
    if (!isPlainObject(step)) {
        out.push(finding("catalog-post-install", path, "step must be an object"));
        return;
    }
    if (hasOwn(step, "mise")) {
        validateArgv(step.mise, path + ".mise", out);
        return;
    }
    if (!hasOwn(step, "exec")) {
        out.push(finding("catalog-post-install", path, "step must carry mise or exec"));
        return;
    }
    validateArgv(step.exec, path + ".exec", out);
    if (!hasOwn(step, "via"))
        return;
    if (typeof step.via !== "string" || !hasOwn(ids, step.via)) {
        out.push(finding("catalog-via", path + ".via", "via must name an existing entry"));
        return;
    }
    if (!hasOwn(miseIds, step.via))
        out.push(finding("catalog-via", path + ".via", "via must name a mise-installed entry"));
}

function validateContainer(value, path, out) {
    if (!isPlainObject(value)) {
        out.push(finding("catalog-container", path, "container must be an object"));
        return;
    }
    validateKnownFields(value, path, ["runtimes", "image", "name", "ports", "env", "volumes"], out);
    if (!validateStringList(value.runtimes, path + ".runtimes", "catalog-container-runtime", out)) {
        // keep checking the remaining fields
    } else {
        for (var r = 0; r < value.runtimes.length; r++)
            if (!listHas(CONTAINER_RUNTIMES, value.runtimes[r]))
                out.push(finding("catalog-container-runtime", path + ".runtimes[" + r + "]", "unknown runtime"));
    }
    if (!printable(value.image))
        out.push(finding("catalog-container", path + ".image", "invalid image"));
    if (!validCommand(value.name))
        out.push(finding("catalog-container", path + ".name", "invalid name"));
    validatePorts(value.ports, path + ".ports", out);
    validateContainerEnv(value.env, path + ".env", out);
    validateVolumes(value.volumes, path + ".volumes", out);
}

function validatePorts(value, path, out) {
    if (!Array.isArray(value) || value.length === 0) {
        out.push(finding("catalog-container-port", path, "ports must be non-empty"));
        return;
    }
    for (var i = 0; i < value.length; i++) {
        var port = value[i];
        if (!isPlainObject(port)) {
            out.push(finding("catalog-container-port", path + "[" + i + "]", "port must be an object"));
            continue;
        }
        if (port.host !== "127.0.0.1" || typeof port.hostPort !== "number" || typeof port.containerPort !== "number")
            out.push(finding("catalog-container-port", path + "[" + i + "]", "ports must bind 127.0.0.1 with numeric host and container ports"));
    }
}

function validateContainerEnv(value, path, out) {
    if (value === undefined)
        return;
    if (!isPlainObject(value)) {
        out.push(finding("catalog-env-name", path, "env must be an object"));
        return;
    }
    var keys = Object.keys(value);
    for (var i = 0; i < keys.length; i++) {
        if (!ENV_NAME_PATTERN.test(keys[i]))
            out.push(finding("catalog-env-name", path + "." + keys[i], "invalid env name"));
        if (typeof value[keys[i]] !== "string" || SHELL_SYNTAX.test(value[keys[i]]))
            out.push(finding("catalog-build-env", path + "." + keys[i], "invalid env value"));
    }
}

function validateVolumes(value, path, out) {
    if (value === undefined)
        return;
    if (!Array.isArray(value)) {
        out.push(finding("catalog-container", path, "volumes must be an array"));
        return;
    }
    for (var i = 0; i < value.length; i++)
        if (!validPath(value[i]))
            out.push(finding("catalog-path", path + "[" + i + "]", "invalid volume path"));
}

function validateChannels(value, path, out) {
    if (!isPlainObject(value) || typeof value.default !== "string" || !isPlainObject(value.options) || !hasOwn(value.options, value.default)) {
        out.push(finding("catalog-channels", path, "channels must declare default and options"));
        return;
    }
    var keys = Object.keys(value.options);
    for (var i = 0; i < keys.length; i++) {
        var option = value.options[keys[i]];
        if (!ID_PATTERN.test(keys[i]) || typeof option !== "string") {
            out.push(finding("catalog-channels", path + ".options." + keys[i], "invalid channel option"));
            continue;
        }
        if (option !== "") {
            var parsed = parseBackendOptions(option);
            if (!parsed.ok)
                out.push(finding("catalog-channels", path + ".options." + keys[i], parsed.detail));
        }
    }
}

function validateBuildEnv(value, path, out) {
    if (!isPlainObject(value)) {
        out.push(finding("catalog-build-env", path, "buildEnv must be an object"));
        return;
    }
    var keys = Object.keys(value);
    for (var i = 0; i < keys.length; i++) {
        if (!ENV_NAME_PATTERN.test(keys[i]))
            out.push(finding("catalog-env-name", path + "." + keys[i], "invalid env name"));
        if (!printable(String(value[keys[i]])))
            out.push(finding("catalog-build-env", path + "." + keys[i], "invalid env value"));
    }
}

function validateKnownFields(row, path, allowed, out) {
    var fields = Object.keys(row);
    for (var i = 0; i < fields.length; i++)
        if (!listHas(allowed, fields[i]))
            out.push(finding("catalog-fields", path + "." + fields[i], "unknown field"));
}

function validateRequiredFields(section, row, path, out) {
    var required = REQUIRED_FIELDS[section];
    for (var i = 0; i < required.length; i++)
        if (!hasOwn(row, required[i]))
            out.push(finding("catalog-required", path + "." + required[i], "required field missing"));
}

function validateInstallRoute(section, row, path, out) {
    var count = 0;
    if (hasOwn(row, "package"))
        count += 1;
    if (hasOwn(row, "tools"))
        count += 1;
    if (hasOwn(row, "installer"))
        count += 1;
    if (hasOwn(row, "container"))
        count += 1;
    if ((section === "editors" || section === "terminals" || section === "envs") && hasOwn(row, "packages"))
        count += 1;
    if (section === "agents" || section === "apps" || section === "tools") {
        if (!hasOwn(row, "package"))
            out.push(finding("catalog-install-route", path, "section installs through a mise package"));
        return;
    }
    if (section === "databases") {
        if (!hasOwn(row, "container"))
            out.push(finding("catalog-install-route", path, "database installs through container data"));
        return;
    }
    if (count === 0)
        out.push(finding("catalog-install-route", path, "entry has no install route"));
}

function validateContext(context, out) {
    if (!isPlainObject(context)) {
        out.push(finding("catalog-context", "<context>", "context must be an object"));
        return false;
    }
    if (!isStringList(context.managerIds))
        out.push(finding("catalog-context", "managerIds", "managerIds must be a string array"));
    if (!isStringList(context.lucideNames))
        out.push(finding("catalog-context", "lucideNames", "lucideNames must be a string array"));
    if (!isStringList(context.brandKeys))
        out.push(finding("catalog-context", "brandKeys", "brandKeys must be a string array"));
    if (typeof context.packageNameValid !== "function")
        out.push(finding("catalog-context", "packageNameValid", "packageNameValid must be a function"));
    return out.length === 0;
}

function collectIds(catalog) {
    var ids = {};
    for (var s = 0; s < SECTION_NAMES.length; s++) {
        var rows = catalog[SECTION_NAMES[s]];
        if (!Array.isArray(rows))
            continue;
        for (var i = 0; i < rows.length; i++)
            if (isPlainObject(rows[i]) && typeof rows[i].id === "string")
                ids[rows[i].id] = true;
    }
    return ids;
}

function collectMiseIds(catalog) {
    var ids = {};
    for (var s = 0; s < SECTION_NAMES.length; s++) {
        var rows = catalog[SECTION_NAMES[s]];
        if (!Array.isArray(rows))
            continue;
        for (var i = 0; i < rows.length; i++)
            if (isPlainObject(rows[i]) && typeof rows[i].id === "string" && (hasOwn(rows[i], "package") || hasOwn(rows[i], "tools")))
                ids[rows[i].id] = true;
    }
    return ids;
}

function validateField(field, value, path, row, state, out) {
    var validators = {
        id: function () {},
        name: function () {},
        icon: function () {},
        brand: function () {},
        package: function () { validateSpecField(value, path, out); },
        tools: function () { validateSpecList(value, path, out); },
        requires: function () { validateSpecList(value, path, out); },
        command: function () { if (!validCommand(value)) out.push(finding("catalog-command", path, "invalid command")); },
        managedBy: function () { if (!validCommand(value)) out.push(finding("catalog-command", path, "invalid command")); },
        bin: function () { if (!validPath(value)) out.push(finding("catalog-path", path, "invalid bin path")); },
        exec: function () { if (!validPath(value)) out.push(finding("catalog-path", path, "invalid exec path")); },
        kind: function () { if (!listHas(KINDS, value)) out.push(finding("catalog-kind", path, "unknown kind")); },
        arch: function () { validateEnumList(value, path, ARCHES, "catalog-arch", out); },
        launch: function () { validateArgv(value, path, out); },
        buildEnv: function () { validateBuildEnv(value, path, out); },
        settings: function () { validateSettings(value, path, out); },
        channels: function () { validateChannels(value, path, out); },
        installer: function () { if (!listHas(INSTALLERS, value)) out.push(finding("catalog-installer", path, "unknown installer")); },
        present: function () { validatePresent(value, path, out); },
        packages: function () { validatePackages(value, path, state.context, out); },
        postInstall: function () { validatePostInstall(value, path, state.ids, state.miseIds, out); },
        container: function () { validateContainer(value, path, out); }
    };
    validators[field]();
}

function validateEnumList(value, path, allowed, rule, out) {
    if (!validateStringList(value, path, rule, out))
        return;
    for (var i = 0; i < value.length; i++)
        if (!listHas(allowed, value[i]))
            out.push(finding(rule, path + "[" + i + "]", "unknown value"));
}

function validateRow(section, row, path, state, out) {
    if (!isPlainObject(row)) {
        out.push(finding("catalog-entry", path, "entry must be an object"));
        return;
    }
    validateKnownFields(row, path, SECTION_FIELDS[section], out);
    validateRequiredFields(section, row, path, out);
    validateInstallRoute(section, row, path, out);
    if (typeof row.id !== "string" || !ID_PATTERN.test(row.id))
        out.push(finding("catalog-id", path + ".id", "id must be a slug"));
    else if (hasOwn(state.seen, row.id))
        out.push(finding("catalog-duplicate-id", path + ".id", "already used at " + state.seen[row.id]));
    else
        state.seen[row.id] = path + ".id";
    if (!printable(row.name))
        out.push(finding("catalog-text", path + ".name", "name must be printable text"));
    if (row.icon !== undefined && !listHas(state.context.lucideNames, row.icon))
        out.push(finding("catalog-icon", path + ".icon", "unknown Lucide icon"));
    if (row.brand !== undefined && !listHas(state.context.brandKeys, row.brand))
        out.push(finding("catalog-brand", path + ".brand", "unknown brand"));

    var fields = Object.keys(row);
    for (var i = 0; i < fields.length; i++)
        if (listHas(SECTION_FIELDS[section], fields[i]))
            validateField(fields[i], row[fields[i]], path + "." + fields[i], row, state, out);
}

function validateCatalog(catalog, context) {
    var out = [];
    if (!validateContext(context, out))
        return result(out);
    if (!isPlainObject(catalog))
        return result([finding("catalog-object", "", "catalog must be an object")]);
    var keys = Object.keys(catalog);
    for (var k = 0; k < keys.length; k++)
        if (!listHas(SECTION_NAMES, keys[k]))
            out.push(finding("catalog-section", keys[k], "unknown section"));
    for (var r = 0; r < SECTION_NAMES.length; r++)
        if (!Array.isArray(catalog[SECTION_NAMES[r]]))
            out.push(finding("catalog-section-array", SECTION_NAMES[r], "section must be an array"));

    var state = { context: context, ids: collectIds(catalog), miseIds: collectMiseIds(catalog), seen: {} };
    for (var s = 0; s < SECTION_NAMES.length; s++) {
        var section = SECTION_NAMES[s];
        var rows = catalog[section];
        if (!Array.isArray(rows))
            continue;
        for (var i = 0; i < rows.length; i++)
            validateRow(section, rows[i], section + "[" + i + "]", state, out);
    }
    return result(out);
}

function validateBrandTable(catalog, brandTokens) {
    var out = [];
    var keys = [];
    if (!isPlainObject(brandTokens)) {
        out.push(finding("catalog-brand-table", "Appearance.js:TOKENS.brand", "brand must be a flat group"));
        return { ok: false, refusals: out, brandKeys: keys };
    }
    var tokenNames = Object.keys(brandTokens);
    for (var i = 0; i < tokenNames.length; i++) {
        var token = brandTokens[tokenNames[i]];
        if (!isPlainObject(token) || token.type !== "color" || !hasOwn(token, "value")) {
            out.push(finding("catalog-brand-table", "Appearance.js:TOKENS.brand." + tokenNames[i], "brand must be a flat group of colours"));
            continue;
        }
        keys.push(tokenNames[i]);
    }
    var used = usedBrands(catalog);
    for (var b = 0; b < keys.length; b++)
        if (!hasOwn(used, keys[b]))
            out.push(finding("catalog-brand-orphan", "Appearance.js:TOKENS.brand." + keys[b], "brand colour is unused"));
    return { ok: out.length === 0, refusals: out, brandKeys: keys };
}

function usedBrands(catalog) {
    var out = {};
    if (!isPlainObject(catalog))
        return out;
    for (var s = 0; s < SECTION_NAMES.length; s++) {
        var rows = catalog[SECTION_NAMES[s]];
        if (!Array.isArray(rows))
            continue;
        for (var i = 0; i < rows.length; i++)
            if (isPlainObject(rows[i]) && typeof rows[i].brand === "string")
                out[rows[i].brand] = true;
    }
    return out;
}
