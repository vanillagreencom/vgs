// Provider adapters consume lookup(reference) only at first need, in-process.
// Its Buffer must not enter a child, wire, status, file or log. J22's network
// door owns recipient checks against reference.origin. J27's accounts picker
// consumes remember(reference) for an existing Secret Service item.
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const cp = require("node:child_process");
const MAX_REFERENCES = 32; // Plugin status's presenceList ceiling.
const MAX_BYTES = 64 * 1024;
const MAX_SECRET_BYTES = 8192; // secret-tool's stdin buffer.

function fail(reason) { throw new Error("jarvis-keys: " + reason); }
function fields(value, expected) {
    if (value === null || typeof value !== "object" || Array.isArray(value)
        || Object.keys(value).sort().join(",") !== expected.slice().sort().join(","))
        fail("reference=shape");
}
function line(value, max) {
    return typeof value === "string" && value.length > 0 && value.length <= max
        && /^[\x20-\x7e]+$/.test(value);
}

// Metadata only. Existing items keep their own attributes; never a CLI token.
function reference(value) {
    fields(value, ["provider", "account", "origin", "attributes"]);
    if (!line(value.provider, 80) || !line(value.account, 80)) fail("reference=identity");
    let url;
    try { url = new URL(value.origin); } catch { fail("reference=origin"); }
    if (!["https:", "http:"].includes(url.protocol) || url.username || url.password
        || url.origin !== value.origin) fail("reference=origin");
    const attrs = value.attributes;
    if (attrs === null || typeof attrs !== "object" || Array.isArray(attrs)
        || Object.keys(attrs).length === 0 || Object.keys(attrs).length > 16)
        fail("reference=attributes");
    for (const [key, item] of Object.entries(attrs))
        if (!/^[a-zA-Z0-9_][a-zA-Z0-9_.:-]{0,79}$/.test(key) || !line(item, 256))
            fail("reference=attributes");
    return { provider: value.provider, account: value.account, origin: value.origin, attributes: { ...attrs } };
}

function ownReference(provider, account, origin) {
    return reference({ provider, account, origin,
        attributes: { service: "vgs-jarvis", provider, account, origin } });
}

// One explicit child environment, also used for the interactive store.
// Display/bus values permit a user-started Secret Service unlock, never a probe.
function childEnvironment(env) {
    const result = { LANG: "C.UTF-8" };
    for (const key of ["PATH", "HOME", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_DATA_HOME",
        "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS", "DISPLAY", "WAYLAND_DISPLAY"])
        if (typeof env[key] === "string" && env[key] !== "") result[key] = env[key];
    return result;
}

class Secrets {
    constructor(directory, env) {
        if (!path.isAbsolute(directory)) fail("references=directory");
        this.directory = directory;
        this.file = path.join(directory, "keys.json");
        this.env = childEnvironment(env);
    }

    references() {
        let bytes;
        try {
            const fd = fs.openSync(this.file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
            try {
                const stat = fs.fstatSync(fd);
                if (!stat.isFile() || stat.size > MAX_BYTES) fail("references=size");
                bytes = fs.readFileSync(fd);
            } finally { fs.closeSync(fd); }
        } catch (error) {
            if (error.code === "ENOENT") return [];
            if (error.message.startsWith("jarvis-keys:")) throw error;
            fail("references=read-failed");
        }
        let values;
        try { values = JSON.parse(bytes); } catch { fail("references=json"); }
        if (!Array.isArray(values) || values.length > MAX_REFERENCES) fail("references=limit");
        const refs = values.map(reference);
        if (new Set(refs.map(this.identity)).size !== refs.length) fail("references=duplicate");
        return refs;
    }

    identity(ref) { return JSON.stringify([ref.provider, ref.account, ref.origin]); }

    #referenceUpdate(value) {
        const ref = reference(value);
        const refs = this.references();
        const index = refs.findIndex(item => this.identity(item) === this.identity(ref));
        if (index < 0) refs.push(ref); else refs[index] = ref;
        if (refs.length > MAX_REFERENCES) fail("references=limit");
        const bytes = JSON.stringify(refs) + "\n";
        if (Buffer.byteLength(bytes) > MAX_BYTES) fail("references=size");
        return { ref, bytes };
    }

    // J27 calls this only after the user selects an item's attributes.
    // No secret-value field can be persisted by this API.
    remember(value) {
        const { ref, bytes } = this.#referenceUpdate(value);
        let temporary;
        try {
            fs.mkdirSync(this.directory, { recursive: true, mode: 0o700 });
            temporary = fs.mkdtempSync(path.join(this.directory, ".keys-"));
            const file = path.join(temporary, "refs");
            fs.writeFileSync(file, bytes, { mode: 0o600, flag: "wx" });
            fs.renameSync(file, this.file);
        } catch { fail("references=write-failed"); }
        finally {
            if (temporary) {
                try { fs.rmSync(temporary, { recursive: true }); }
                catch { fail("references=cleanup-failed"); }
            }
        }
        return ref;
    }

    attributes(ref) { return Object.entries(reference(ref).attributes).flat(); }

    // Helper output can contain a key, including on errors. Never quote it.
    run(command, args, options = {}) {
        const result = cp.spawnSync(command, args, { env: this.env, timeout: 30000,
            maxBuffer: MAX_BYTES, stdio: ["pipe", "pipe", "pipe"], ...options });
        try {
            if (result.error || result.status !== 0) {
                const cause = result.error?.code === "ENOENT" ? "missing"
                    : result.error?.code === "ETIMEDOUT" ? "timeout" : "failed";
                fail(command + "=" + cause);
            }
            return result.stdout;
        } finally {
            if (Buffer.isBuffer(result.stderr)) result.stderr.fill(0);
            if ((result.error || result.status !== 0) && Buffer.isBuffer(result.stdout)) result.stdout.fill(0);
        }
    }

    addKey(ref) {
        const own = ownReference(ref.provider, ref.account, ref.origin);
        this.#referenceUpdate(own);
        if (!process.stdin.isTTY) fail("store=terminal-required");
        // secret-tool uses getpass on the controlling terminal when stdin
        // is a TTY. Jarvis never receives the key. Keep stdout/stderr private:
        // getpass's masked prompt uses /dev/tty, not these output pipes.
        const output = this.run("secret-tool", ["store", "--label=Jarvis provider key",
            ...this.attributes(own)], { stdio: ["inherit", "pipe", "pipe"], timeout: 0 });
        output.fill(0);
        this.remember(own);
    }

    // No cache and no CLI verb for lookup: adapters get the Buffer directly.
    lookup(ref) {
        const key = this.run("secret-tool", ["lookup", ...this.attributes(ref)]);
        if (key.length === 0 || key.length > MAX_SECRET_BYTES) {
            key.fill(0);
            fail("secret-tool=empty-or-oversize");
        }
        return key;
    }

    // SearchItems exposes paths, not secrets. Both presence and the explicit
    // accounts picker use this one reply judge, without activation or unlock.
    #search(attributes) {
        const attrs = Object.entries(attributes).flat();
        let output;
        try {
            output = this.run("busctl", ["--user", "--auto-start=no",
                "--allow-interactive-authorization=no", "--timeout=5", "--json=short", "call",
                "org.freedesktop.secrets", "/org/freedesktop/secrets",
                "org.freedesktop.Secret.Service", "SearchItems", "a{ss}", String(attrs.length / 2), ...attrs]);
            let reply;
            try { reply = JSON.parse(output); } catch { fail("busctl=reply"); }
            if (reply.type !== "aoao" || !Array.isArray(reply.data) || reply.data.length !== 2
                || reply.data.some(items => !Array.isArray(items)
                    || items.some(item => typeof item !== "string" || !/^\/[a-zA-Z0-9_/]+$/.test(item))))
                fail("busctl=reply");
            return reply.data;
        } finally { if (output) output.fill(0); }
    }

    presence(ref) {
        try {
            const paths = this.#search(reference(ref).attributes);
            return { value: paths[0].length ? "present" : paths[1].length ? "locked" : "absent" };
        } catch (error) {
            return { value: "unavailable", hint: error.message.startsWith("jarvis-keys:")
                ? error.message : "jarvis-keys: busctl=reply" };
        }
    }

    // Only the user's accounts picker enumerates public item metadata.
    // Discovery of remembered references continues to use presence().
    items() {
        const groups = this.#search({});
        const paths = [...groups[0], ...groups[1]];
        if (paths.length > MAX_REFERENCES || new Set(paths).size !== paths.length) fail("items=limit-or-duplicate");
        return paths.map(item => {
            const read = (name, type) => {
                let bytes;
                try {
                    bytes = this.run("busctl", ["--user", "--auto-start=no",
                        "--allow-interactive-authorization=no", "--timeout=5", "--json=short", "get-property",
                        "org.freedesktop.secrets", item, "org.freedesktop.Secret.Item", name]);
                    let reply;
                    try { reply = JSON.parse(bytes); } catch { fail("items=reply"); }
                    if (reply.type !== type || !Array.isArray(reply.data) || reply.data.length !== 1) fail("items=reply");
                    return reply.data[0];
                } finally { if (bytes) bytes.fill(0); }
            };
            const label = read("Label", "s");
            const attributes = read("Attributes", "a{ss}");
            if (typeof label !== "string" || label.length === 0 || label.length > 80 || /[\x00-\x1f\x7f]/.test(label))
                fail("items=label");
            // Reuse the reference judge for attribute syntax, not identity.
            const checked = reference({ provider: "metadata", account: "metadata",
                origin: "https://metadata.invalid", attributes });
            return { path: item, label, attributes: checked.attributes,
                presence: groups[1].includes(item) ? "locked" : "present" };
        });
    }

    rows() {
        return this.references().map(ref => ({ label: (ref.provider + " / " + ref.account).slice(0, 60),
            ...this.presence(ref) }));
    }
}

module.exports = { Secrets, reference, ownReference, childEnvironment };
