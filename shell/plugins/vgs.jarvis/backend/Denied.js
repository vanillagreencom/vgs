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
// A judgment must see every name, so a folder it cannot list throws; the
// mask inventory skips one, since the name rule still judges each path.
function present(directory, depth, found, skipUnlisted = false) {
    let entries;
    try { entries = fs.readdirSync(directory, { withFileTypes: true }); }
    catch (error) {
        if (error.code === "ENOENT" || skipUnlisted) return found;
        throw error;
    }
    for (const entry of entries) {
        const file = path.join(directory, entry.name);
        if (accountDirectory(entry.name, depth) !== null) found.push(file);
        else if (depth < ACCOUNT_DEPTH && entry.isDirectory()) present(file, depth + 1, found, skipUnlisted);
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
    // A folder moved to fewer than ACCOUNT_DEPTH levels below a base carries
    // its entries up: one that lands within the rule's depth is rule-named.
    const landsNamed = (source, destination) => fs.lstatSync(source).isDirectory() && bases.some(base => {
        const parts = below(destination, base);
        return parts !== null && parts.length < ACCOUNT_DEPTH && present(source, parts.length + 1, []).length > 0;
    });
    const credential = [
        [home, ".ssh"], [home, ".gnupg"], [home, ".claude"], [home, ".codex"],
        [home, ".gemini"], [home, ".copilot"], [home, ".agent-browser"],
        [home, ".mozilla"], [home, ".pki"], [home, ".netrc"], [home, ".git-credentials"],
        [home, ".aws"], [home, ".azure"], [home, ".kube"], [home, ".docker/config.json"],
        [home, ".npmrc"], [home, ".pypirc"], [home, ".cargo/credentials.toml"], [home, ".cargo/credentials"],
        [config, "gcloud"], [config, "rclone"],
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
    const protectedPaths = credential.concat([
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
    let masks = null;
    // The resolved targets of rule-named links directly in each base, read
    // once per snapshot on its first judgment: a dotfile manager's
    // ~/.claude-work link must protect the folder it points to. Only the
    // bases' own entries are read; a link two levels down is in masks only.
    // A dangling or looping link is protected by its own path, by name.
    let linkTargets = null;
    function accountLinkTargets() {
        if (linkTargets === null) {
            linkTargets = bases.flatMap(base => {
                let entries;
                try { entries = fs.readdirSync(base, { withFileTypes: true }); }
                catch (error) {
                    if (error.code === "ENOENT") return [];
                    throw error;
                }
                return entries.filter(entry => entry.isSymbolicLink() && accountDirectory(entry.name, 1) !== null)
                    .flatMap(entry => {
                        try { return [resolve(path.join(base, entry.name)).path]; } catch { return []; }
                    });
            });
        }
        return linkTargets;
    }
    /**
     * Judge a typed path role. Refuse protected descendants and destructive
     * ancestors. Recursive readers must not scan across a protected root.
     * A one-level listing may list names but must judge each opened child.
     * A move source or removal is the named entry: a final link is judged
     * and answered as the link, never its target. A rule-named account entry
     * is judged by its name alone, so one made after this snapshot counts.
     */
    function inspect(file, role) {
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
            if (accountLinkTargets().some(link => within(target.path, link) || (ancestor && within(link, target.path))))
                return { kind: "refuse", reason: "protected-path" };
        } catch (error) { return { kind: "refuse", reason: "path-resolution", error: error.code || error.message }; }
        try {
            if (ancestor && target.exists && holdsNamed(target.path)) return { kind: "refuse", reason: "protected-path" };
        } catch (error) { return { kind: "refuse", reason: "path-resolution", error: error.code || error.message }; }
        if (!within(target.path, realHome.path)) return { kind: "refuse", reason: "outside-home" };
        const executionPath = changes && executionRoots.some(root => within(target.path, root) || within(root, target.path));
        return { kind: "path", path: target.path, exists: target.exists, execution: executionPath };
    }
    return Object.freeze({
        /**
         * J23 consumes this list for its filesystem masks. It must not
         * rebuild a second credential inventory or treat absent roots as
         * safe. The masks need concrete paths, so the first read adds the
         * rule-named entries present then, found by names alone. A dangling
         * or looping one is masked by its own path. Judgments never read it.
         */
        get masks() {
            if (masks === null) {
                const accounts = bases.flatMap(base => present(base, 1, [], true)).flatMap(file => {
                    try { return [file, resolve(file).path]; } catch { return [file]; }
                });
                masks = Object.freeze([...new Set(protectedRoots.concat(accounts))]);
            }
            return masks;
        },
        /**
         * Judge a typed path role. Refuse protected descendants and destructive
         * ancestors. Recursive readers must not scan across a protected root.
         * A one-level listing may list names but must judge each opened child.
         * A move source or removal is the named entry: a final link is judged
         * and answered as the link, never its target.
         */
        inspect,
        /**
         * Judge every [path, role] of one call: the one entry Policy and an
         * executor's rejudge use. Answers {kind: "paths", paths} in order, or
         * the first refusal with the refused input as file. A move source is
         * also judged where it lands, against each write destination of the
         * same call.
         */
        inspectPaths(pairs) {
            const paths = [];
            for (const [file, role] of pairs) {
                const verdict = inspect(file, role);
                if (verdict.kind === "refuse") return { ...verdict, file };
                paths.push(verdict);
            }
            const roles = pairs.map(([, role]) => role);
            for (const [index, source] of paths.entries()) {
                if (roles[index] !== "move" || !source.exists) continue;
                for (const [other, destination] of paths.entries()) {
                    if (roles[other] !== "write") continue;
                    const file = pairs[index][0];
                    try {
                        if (landsNamed(source.path, destination.path)) return { kind: "refuse", reason: "protected-path", file };
                    } catch (error) { return { kind: "refuse", reason: "path-resolution", error: error.code || error.message, file }; }
                }
            }
            return { kind: "paths", paths };
        }
    });
}

module.exports = { create };
