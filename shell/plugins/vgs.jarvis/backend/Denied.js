// Filesystem metadata judge for the file, sandbox and task executors.
// No file contents, account marker or credential is opened by this module.
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const { ACCOUNT_DEPTH, accountDirectory } = require("../AccountProviders.js");

function within(file, root) {
    return file === root || file.startsWith(root === "/" ? "/" : root + "/");
}

// The names of file's components below base, or null unless strictly below.
function below(file, base) {
    if (file === base || !within(file, base)) return null;
    return file.slice(base === "/" ? 1 : base.length + 1).split("/");
}

// Collect rule-named account entries from depth to ACCOUNT_DEPTH below a
// base, reading entry names only. A link or a matched entry is never entered.
function present(directory, depth, found) {
    let entries;
    try { entries = fs.readdirSync(directory, { withFileTypes: true }); }
    catch (error) {
        if (error.code === "ENOENT") return found;
        throw error;
    }
    for (const entry of entries) {
        const file = path.join(directory, entry.name);
        if (accountDirectory(entry.name, depth) !== null) found.push(file);
        else if (depth < ACCOUNT_DEPTH && entry.isDirectory()) present(file, depth + 1, found);
    }
    return found;
}

/**
 * Resolve existing components, including links, before appending an absent
 * write suffix. Never normalize ".." before resolving a preceding link.
 * A dangling link, unreadable component or non-directory parent is a failure,
 * not absence. With follow false a final link stays the named entry itself.
 * trail lists each component's physical path before a link on it resolves.
 * The executor must rejudge immediately before its filesystem act.
 */
function resolve(file, follow = true) {
    if (typeof file !== "string" || !path.isAbsolute(file) || /[\x00-\x1f\x7f]/.test(file))
        throw new Error("jarvis: path=invalid");
    let real = "/";
    let exists = true;
    const trail = [];
    const parts = file.split("/").filter(part => part !== "" && part !== ".");
    for (let i = 0; i < parts.length; i++) {
        const part = parts[i];
        if (part === "..") {
            if (!exists) throw new Error("jarvis: path=absent-parent");
            real = path.dirname(real);
            continue;
        }
        const next = path.join(real, part);
        trail.push(next);
        if (!exists) { real = next; continue; }
        let stat;
        try {
            stat = fs.lstatSync(next);
        } catch (error) {
            if (error.code !== "ENOENT") throw error;
            exists = false;
            real = next;
            continue;
        }
        const last = i === parts.length - 1;
        real = stat.isSymbolicLink() && (follow || !last) ? fs.realpathSync.native(next) : next;
        if (!last && !fs.statSync(real).isDirectory())
            throw new Error("jarvis: path=not-directory");
    }
    return { path: real, exists, trail };
}

/**
 * Build one protected-root snapshot from trusted XDG/installation roots.
 * accountRoots holds the explicit and hand-added account roots
 * (Accounts.js::accountRoots); the account name rule protects the rest.
 * Each consumer rebuilds this snapshot immediately before it acts.
 */
function create({ home, config, data, state, runtime, install, accountRoots }) {
    if (!Array.isArray(accountRoots)) throw new Error("jarvis: paths=account-roots");
    const realHome = resolve(home);
    if (!realHome.exists || !fs.statSync(realHome.path).isDirectory()) throw new Error("jarvis: paths=home");
    // The account name rule counts depth below each physical base.
    const bases = [...new Set([realHome.path, resolve(config).path, resolve(data).path])];
    const named = file => bases.some(base => (below(file, base) || [])
        .some((name, index) => accountDirectory(name, index + 1) !== null));
    // A target this shallow can hold a rule-named entry deeper down. A base
    // itself already holds static credential roots.
    const holdsNamed = target => bases.some(base => {
        const parts = below(target, base);
        if (parts === null || parts.length >= ACCOUNT_DEPTH || !fs.lstatSync(target).isDirectory()) return false;
        return present(target, parts.length + 1, []).length > 0;
    });
    const credential = [
        [home, ".ssh"], [home, ".gnupg"], [home, ".claude"], [home, ".codex"],
        [home, ".gemini"], [home, ".copilot"], [home, ".agent-browser"],
        [home, ".mozilla"], [home, ".pki"], [home, ".netrc"], [home, ".git-credentials"],
        [config, "gh"], [config, "git/credentials"], [config, "claude"], [config, "codex"], [config, "gemini"],
        [config, "copilot"], [config, "opencode"], [data, "opencode"],
        [data, "keyrings"], [data, "kwalletd"], [config, "kwalletd"],
        [config, "chromium"], [config, "google-chrome"], [config, "BraveSoftware"],
        [config, "microsoft-edge"], [config, "vivaldi"], [config, "mozilla"]
    ].map(([base, suffix]) => {
        // Validate before path.join can turn a missing XDG root into a default.
        resolve(base);
        return path.join(base, suffix);
    }).concat(accountRoots);
    // The masks need concrete paths: the rule-named entries present now.
    const accounts = bases.flatMap(base => present(base, 1, []));
    const protectedPaths = credential.concat(accounts, [
        path.join(config, "vgs"), path.join(data, "vgs"), path.join(state, "vgs"),
        path.join(runtime, "vgs"), install
    ]);
    const execution = [
        [home, ".profile"], [home, ".bash_profile"], [home, ".bash_login"], [home, ".bashrc"],
        [home, ".zprofile"], [home, ".zshrc"], [home, ".zshenv"], [home, ".xprofile"],
        [config, "fish"], [config, "autostart"], [config, "systemd/user"],
        [data, "applications"], [config, "hypr"], [home, ".local/bin"]
    ].map(([base, suffix]) => path.join(base, suffix));
    const roots = files => files.flatMap(file => [file, resolve(file).path]);
    const protectedRoots = roots(protectedPaths);
    const executionRoots = roots(execution);
    return Object.freeze({
        // J23 consumes this snapshot for its filesystem masks. It must not
        // rebuild a second credential inventory or treat absent roots as safe.
        // Rule-named entries are those present when the snapshot was built.
        masks: Object.freeze([...new Set(protectedRoots)]),
        /**
         * Judge a typed path role. Refuse protected descendants and destructive
         * ancestors. Recursive readers must not scan across a protected root.
         * A one-level listing may list names but must judge each opened child.
         * A move source or removal is the named entry: a final link is judged
         * and answered as the link, never its target.
         */
        inspect(file, role) {
            if (!["read", "tree-read", "write", "move", "remove", "workspace"].includes(role))
                return { kind: "refuse", reason: "path-role" };
            let target;
            try { target = resolve(file, role !== "move" && role !== "remove"); }
            catch (error) { return { kind: "refuse", reason: "path-resolution", error: error.code || error.message }; }
            const changes = ["write", "move", "remove", "workspace"].includes(role);
            const ancestor = changes || role === "tree-read";
            if (target.trail.concat(target.path).some(named) || protectedRoots.some(root => within(target.path, root)
                    || (ancestor && within(root, target.path))))
                return { kind: "refuse", reason: "protected-path" };
            try {
                if (ancestor && target.exists && holdsNamed(target.path)) return { kind: "refuse", reason: "protected-path" };
            } catch (error) { return { kind: "refuse", reason: "path-resolution", error: error.code || error.message }; }
            if (!within(target.path, realHome.path)) return { kind: "refuse", reason: "outside-home" };
            const executionPath = changes && executionRoots.some(root => within(target.path, root) || within(root, target.path));
            return { kind: "path", path: target.path, exists: target.exists, execution: executionPath };
        }
    });
}

module.exports = { create };
