// Filesystem metadata judge for the planned file, sandbox and task executors.
// No file contents, account marker or credential is opened by this module.
"use strict";
const fs = require("node:fs");
const path = require("node:path");

function within(file, root) {
    return file === root || file.startsWith(root === "/" ? "/" : root + "/");
}

/**
 * Resolve existing components, including links, before appending an absent
 * write suffix. Never normalize ".." before resolving a preceding link.
 * A dangling link, unreadable component or non-directory parent is a failure,
 * not absence. The executor must rejudge immediately before its filesystem act.
 */
function resolve(file) {
    if (typeof file !== "string" || !path.isAbsolute(file) || /[\x00-\x1f\x7f]/.test(file))
        throw new Error("jarvis: path=invalid");
    let real = "/";
    let exists = true;
    const parts = file.split("/").filter(part => part !== "" && part !== ".");
    for (let i = 0; i < parts.length; i++) {
        const part = parts[i];
        if (part === "..") {
            if (!exists) throw new Error("jarvis: path=absent-parent");
            real = path.dirname(real);
            continue;
        }
        const next = path.join(real, part);
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
        real = stat.isSymbolicLink() ? fs.realpathSync.native(next) : next;
        if (i < parts.length - 1 && !fs.statSync(real).isDirectory())
            throw new Error("jarvis: path=not-directory");
    }
    return { path: real, exists };
}

/**
 * Build one protected-root snapshot from trusted XDG/installation roots.
 * J27 supplies every discovered or hand-added account root in accountRoots.
 * An executor rebuilds this snapshot after roots or filesystem links change.
 */
function create({ home, config, data, state, runtime, install, accountRoots }) {
    if (!Array.isArray(accountRoots)) throw new Error("jarvis: paths=account-roots");
    const realHome = resolve(home);
    if (!realHome.exists || !fs.statSync(realHome.path).isDirectory()) throw new Error("jarvis: paths=home");
    const credential = [
        [home, ".ssh"], [home, ".gnupg"], [home, ".claude"], [home, ".codex"],
        [home, ".gemini"], [home, ".copilot"], [home, ".agent-browser"],
        [home, ".mozilla"], [home, ".pki"], [home, ".netrc"], [home, ".git-credentials"],
        [config, "gh"], [config, "claude"], [config, "codex"], [config, "gemini"],
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
    return Object.freeze({
        // J23 consumes this snapshot for its filesystem masks. It must not
        // rebuild a second credential inventory or treat absent roots as safe.
        masks: Object.freeze([...new Set(protectedRoots)]),
        /**
         * Judge a typed path role. Refuse protected descendants and destructive
         * ancestors. Recursive readers must not scan across a protected root.
         * A one-level listing may list names but must judge each opened child.
         */
        inspect(file, role) {
            if (!["read", "tree-read", "write", "move", "remove", "workspace"].includes(role))
                return { kind: "refuse", reason: "path-role" };
            let target;
            try { target = resolve(file); }
            catch (error) { return { kind: "refuse", reason: "path-resolution", error: error.code || error.message }; }
            const changes = ["write", "move", "remove", "workspace"].includes(role);
            if (protectedRoots.some(root => within(target.path, root)
                    || ((changes || role === "tree-read") && within(root, target.path))))
                return { kind: "refuse", reason: "protected-path" };
            if (!within(target.path, realHome.path)) return { kind: "refuse", reason: "outside-home" };
            const executionPath = changes && executionRoots.some(root => within(target.path, root) || within(root, target.path));
            return { kind: "path", path: target.path, exists: target.exists, execution: executionPath };
        }
    });
}

module.exports = { create };
