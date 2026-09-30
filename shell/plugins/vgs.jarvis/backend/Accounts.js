"use strict";
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const cp = require("node:child_process");
const { Secrets, childEnvironment } = require("./Secrets.js");
const { PROVIDERS, keyPresence } = require("../AccountProviders.js");
const MAX_ENTRIES = 200;
const MAX_ROWS = 32; // The core's presenceList and choices ceiling.
const MAX_BYTES = 64 * 1024;

function fail(reason) { throw new Error("jarvis-accounts: " + reason); }
function printable(value, max) {
    return typeof value === "string" && value.length > 0 && value.length <= max && !/[\x00-\x1f\x7f]/.test(value);
}
function provider(id) {
    const row = PROVIDERS.find(item => item.id === id);
    if (!row) fail("provider=unknown");
    return row;
}
function identity(kind, values) {
    return kind + ":" + crypto.createHash("sha256").update(JSON.stringify(values)).digest("hex").slice(0, 32);
}

// lstat each component, including explicit and hand-added paths. An absent
// default is normal; a linked or unreadable input is not a different account.
function directory(value, hold = false) {
    if (!printable(value, 4096) || Buffer.byteLength(value) > 4096
        || !path.isAbsolute(value) || path.normalize(value) !== value)
        fail("directory=absolute-normal-path-required");
    let fd = fs.openSync("/", fs.constants.O_RDONLY | fs.constants.O_DIRECTORY);
    try {
        for (const part of value.split("/").filter(Boolean)) {
            // Linux descriptor paths anchor the parent inode. The only link
            // followed is our own /proc descriptor, never an account link.
            const child = "/proc/self/fd/" + fd + "/" + part;
            let stat;
            try { stat = fs.lstatSync(child); }
            catch (error) {
                if (error.code === "ENOENT") return { kind: "absent" };
                fail("directory=unreadable");
            }
            if (stat.isSymbolicLink()) fail("directory=link");
            if (!stat.isDirectory()) fail("directory=not-directory");
            let next;
            try { next = fs.openSync(child, fs.constants.O_RDONLY | fs.constants.O_DIRECTORY | fs.constants.O_NOFOLLOW); }
            catch { fail("directory=unreadable-or-changed"); }
            fs.closeSync(fd);
            fd = next;
        }
        const result = { kind: "directory", path: value };
        if (hold) { result.fd = fd; fd = undefined; }
        return result;
    } finally { if (fd !== undefined) fs.closeSync(fd); }
}

function added(value) {
    if (!value || typeof value !== "object" || Array.isArray(value)
        || Object.keys(value).sort().join(",") !== "directory,label,provider"
        || provider(value.provider).kind !== "cli" || !printable(value.label, 60))
        fail("added=shape");
    directory(value.directory);
    return { provider: value.provider, directory: value.directory, label: value.label };
}

// The provider CLI alone opens its own login store. These bounded replies
// are hints, not inference proof. No raw output is returned or logged.
function login(row, result) {
    if (result.error || result.signal || ![0, 1].includes(result.status))
        return { kind: "unavailable", reason: result.error?.code === "ENOENT" ? "command-missing"
            : result.error?.code === "ETIMEDOUT" ? "command-timeout" : "command-failed" };
    if (row.id === "claude") {
        let value;
        try { value = JSON.parse(result.stdout); } catch { return { kind: "unavailable", reason: "status-reply" }; }
        if (!value || typeof value !== "object" || typeof value.loggedIn !== "boolean"
            || value.loggedIn !== (result.status === 0)) return { kind: "unavailable", reason: "status-reply" };
        if (!value.loggedIn) return { kind: "found" };
        const email = value.email ?? "";
        const plan = value.subscriptionType ?? "";
        if ((email !== "" && (!printable(email, 80) || !/^[^ @]+@[^ @]+\.[^ @]+$/.test(email)))
            || !["", "pro", "max", "team", "enterprise", "free", "api"].includes(plan))
            return { kind: "unavailable", reason: "status-identity" };
        return { kind: "signed-in", email, plan };
    }
    // Codex documents its status on stderr, including a masked API key.
    // Classify the fixed prefix; never retain the key suffix.
    const text = result.stderr.toString("utf8").trim();
    if (result.status === 1 && text === "Not logged in") return { kind: "found" };
    if (result.status === 0 && /^Logged in using (ChatGPT|an API key(?: - .*)?|access token|personal access token|workload identity|Amazon Bedrock API key|Amazon Bedrock AWS access keys)$/.test(text))
        return { kind: "signed-in", email: "", plan: "" };
    return { kind: "unavailable", reason: "status-reply" };
}

/**
 * One account judge. discovery holds metadata only; Verify never runs from
 * discovery and is not persisted. A future network-door consumer supplies
 * request(account), which must return an actual inference result.
 */
class Accounts {
    constructor(stateDirectory, env, presence = keyPresence(name => env[name])) {
        directory(stateDirectory);
        this.directory = stateDirectory;
        this.file = path.join(stateDirectory, "accounts.json");
        this.env = childEnvironment(env);
        this.home = env.HOME;
        this.config = env.XDG_CONFIG_HOME || path.join(this.home, ".config");
        this.data = env.XDG_DATA_HOME || path.join(this.home, ".local/share");
        this.explicit = {};
        for (const row of PROVIDERS) if (row.kind === "cli" && env[row.variable])
            this.explicit[row.id] = env[row.variable];
        const expected = PROVIDERS.filter(row => ["key", "speech-key"].includes(row.kind)).map(row => row.variable).sort();
        if (!presence || Object.keys(presence).sort().join(",") !== expected.join(",")
            || Object.values(presence).some(value => typeof value !== "boolean")) fail("key-presence=shape");
        this.presence = { ...presence };
        this.secrets = new Secrets(stateDirectory, this.env);
        this.accounts = [];
        this.epoch = 0;
        this.operation = 0;
    }

    added() {
        let fd;
        try {
            fd = fs.openSync(this.file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
            const stat = fs.fstatSync(fd);
            if (!stat.isFile() || stat.size > MAX_BYTES) fail("added=size");
            let values;
            try { values = JSON.parse(fs.readFileSync(fd)); } catch { fail("added=json"); }
            if (!Array.isArray(values) || values.length > MAX_ROWS) fail("added=limit");
            const result = values.map(added);
            if (new Set(result.map(item => item.provider + "\0" + item.directory)).size !== result.length)
                fail("added=duplicate");
            return result;
        } catch (error) {
            if (error.code === "ENOENT") return [];
            if (error.message.startsWith("jarvis-accounts:")) throw error;
            fail("added=read-failed");
        } finally { if (fd !== undefined) fs.closeSync(fd); }
    }

    add(value) {
        const entry = added(value);
        if (directory(entry.directory).kind !== "directory") fail("added=directory-absent");
        const entries = this.added();
        const index = entries.findIndex(item => item.provider === entry.provider && item.directory === entry.directory);
        if (index < 0) entries.push(entry); else entries[index] = entry;
        if (entries.length > MAX_ROWS) fail("added=limit");
        const bytes = JSON.stringify(entries) + "\n";
        if (Buffer.byteLength(bytes) > MAX_BYTES) fail("added=size");
        let temporary;
        try {
            directory(this.directory);
            fs.mkdirSync(this.directory, { recursive: true, mode: 0o700 });
            temporary = fs.mkdtempSync(path.join(this.directory, ".accounts-"));
            const file = path.join(temporary, "metadata");
            fs.writeFileSync(file, bytes, { flag: "wx", mode: 0o600 });
            fs.renameSync(file, this.file);
        } catch { fail("added=write-failed"); }
        finally {
            if (temporary) {
                try { fs.rmSync(temporary, { recursive: true }); }
                catch { fail("added=cleanup-failed"); }
            }
        }
    }

    candidates() {
        const candidates = new Map();
        const insert = (row, dir, label) => {
            directory(dir);
            const key = row.id + "\0" + dir;
            if (!candidates.has(key)) candidates.set(key, { provider: row.id, directory: dir, label });
        };
        const cli = PROVIDERS.filter(row => row.kind === "cli");
        for (const row of cli) {
            if (this.explicit[row.id]) insert(row, this.explicit[row.id], path.basename(this.explicit[row.id]));
            insert(row, path.join(this.home, row.prefix), "default");
        }
        // Hand-added labels win over a generated label for the same path.
        for (const item of this.added()) {
            insert(provider(item.provider), item.directory, item.label);
            candidates.set(item.provider + "\0" + item.directory, item);
        }
        const visited = new Set();
        const scanned = new Map();
        const scan = (root, depth) => {
            if ((scanned.get(root) ?? Infinity) <= depth) return;
            scanned.set(root, depth);
            const opened = directory(root, true);
            if (opened.kind === "absent") return;
            let stream;
            try {
                stream = fs.opendirSync("/proc/self/fd/" + opened.fd);
                for (let entry; (entry = stream.readSync()) !== null;) {
                    visited.add(path.join(root, entry.name));
                    if (visited.size > MAX_ENTRIES) fail("discovery=entry-limit");
                    if (entry.isSymbolicLink() || !entry.isDirectory()) continue;
                    const dir = path.join(root, entry.name);
                    const row = cli.find(item => entry.name.startsWith(item.prefix));
                    if (row) insert(row, dir, entry.name.slice(row.prefix.length).replace(/^[-_.]+/, "") || "default");
                    else if (depth < 2) scan(dir, depth + 1);
                }
            } catch (error) {
                if (error.message.startsWith("jarvis-accounts:")) throw error;
                fail("discovery=directory-unreadable");
            } finally {
                if (stream) stream.closeSync();
                fs.closeSync(opened.fd);
            }
        };
        for (const root of new Set([this.home, this.config, this.data])) scan(root, 1);
        return Array.from(candidates.values());
    }

    run(command, args, extra = {}) {
        return cp.spawnSync(command, args, { env: { ...this.env, ...extra }, cwd: this.home,
            timeout: 5000, maxBuffer: MAX_BYTES, stdio: ["ignore", "pipe", "pipe"] });
    }

    cliAccount(candidate) {
        const row = provider(candidate.provider);
        const opened = directory(candidate.directory, true);
        const result = this.run(row.command[0], row.command.slice(1), { [row.variable]: candidate.directory });
        let state;
        try { state = login(row, result); }
        finally { result.stdout?.fill(0); result.stderr?.fill(0); }
        // Fallback metadata only. No marker is opened, even when mode 000.
        let marker = "absent";
        try {
            const markerPath = opened.kind === "directory" ? "/proc/self/fd/" + opened.fd + "/" + row.marker
                : path.join(candidate.directory, row.marker);
            const stat = fs.lstatSync(markerPath);
            if (stat.isSymbolicLink()) fail("marker=link");
            marker = stat.isFile() ? "present" : "absent";
        } catch (error) {
            if (error.code !== "ENOENT") {
                state = { kind: "unavailable", reason: error.message.startsWith("jarvis-accounts:") ? "marker-link" : "marker-unreadable" };
            }
        } finally { if (opened.kind === "directory") fs.closeSync(opened.fd); }
        if (state.kind === "found" && directory(candidate.directory).kind === "absent" && marker === "absent")
            return null;
        const email = state.email || "";
        const plan = state.plan || "";
        if (state.kind === "signed-in") state = { kind: "signed-in" };
        const label = candidate.label.slice(0, 60);
        return { id: identity("cli", [row.id, candidate.directory]), provider: row.id, label,
            source: { kind: "cli", directory: candidate.directory }, state, marker,
            email, plan,
            identity: { kind: email && label !== "default" && email !== label ? "mismatch" : "match" } };
    }

    // Secret Service labels/attributes only. CLI login items are not API keys.
    keyItems() {
        return this.secrets.items().filter(item => !this.vendorLogin(item));
    }

    vendorLogin(item) {
        const text = JSON.stringify([item.label, item.attributes]).toLowerCase();
        return /(claude[ -]?code|codex|copilot|oauth|refresh[ _-]?token|access[ _-]?token)/.test(text);
    }

    remember(itemPath, providerId, label) {
        const row = provider(providerId);
        if (!["key", "speech-key"].includes(row.kind)) fail("reference=provider");
        const item = this.keyItems().find(value => value.path === itemPath);
        if (!item) fail("reference=item-unavailable");
        this.secrets.remember({ provider: row.id, account: label, origin: row.origin, attributes: item.attributes });
    }

    localAccounts() {
        const result = this.run("ss", ["-H", "-ltn"]);
        try {
            if (result.error || result.status !== 0) return PROVIDERS.filter(row => row.kind === "local")
                .map(row => this.account(row, "local", { kind: "unavailable", reason: "ports-unavailable" }, { kind: "local", origin: row.origin }));
            const ports = new Set();
            for (const line of result.stdout.toString("utf8").split("\n").filter(Boolean)) {
                const fields = line.trim().split(/\s+/);
                if (fields.length < 5 || fields[0] !== "LISTEN") fail("ports=reply");
                const match = /^(127\.0\.0\.1|\[::1\]|0\.0\.0\.0|\*|\[::\]):([0-9]+)$/.exec(fields[3]);
                if (match) ports.add(Number(match[2]));
            }
            return PROVIDERS.filter(row => row.kind === "local" && ports.has(row.port))
                .map(row => this.account(row, "local", { kind: "found" }, { kind: "local", origin: row.origin }));
        } finally { result.stdout?.fill(0); result.stderr?.fill(0); }
    }

    account(row, label, state, source) {
        return { id: identity(source.kind, [row.id, source, label]), provider: row.id, label,
            source, state, identity: { kind: "match" } };
    }

    discover() {
        this.epoch++;
        this.accounts = [];
        const candidates = this.candidates();
        if (candidates.length > MAX_ROWS) fail("discovery=account-limit");
        const result = candidates.map(item => this.cliAccount(item)).filter(Boolean);
        for (const row of PROVIDERS) if (["key", "speech-key"].includes(row.kind) && this.presence[row.variable])
            result.push(this.account(row, "environment", { kind: "found" }, { kind: "variable", name: row.variable, origin: row.origin }));
        for (const ref of this.secrets.references()) {
            const row = provider(ref.provider);
            if (!["key", "speech-key"].includes(row.kind) || this.vendorLogin({ label: ref.account, attributes: ref.attributes }))
                fail("reference=vendor-login-or-provider");
            const present = this.secrets.presence(ref);
            const state = present.value === "present" ? { kind: "found" } : present.value === "locked"
                ? { kind: "locked" } : { kind: "unavailable", reason: present.value === "absent" ? "key-absent" : "keyring-unavailable" };
            result.push(this.account(row, ref.account, state, { kind: "keyring", reference: ref }));
        }
        result.push(...this.localAccounts());
        if (result.length > MAX_ROWS) fail("discovery=account-limit");
        this.accounts = result;
        return this.accounts;
    }

    /**
     * Explicit user action only. Each operation names the current discovery
     * epoch. A refresh or a replacement Verify invalidates its late result.
     * The request port is absent until the origin-bound network door lands.
     */
    async verify(id, initiation, request = null) {
        if (initiation !== "user") fail("verify=explicit-user-required");
        const account = this.accounts.find(item => item.id === id);
        if (!account) fail("verify=account-unavailable");
        if (account.state.kind === "verifying") fail("verify=busy");
        if (account.state.kind === "locked") fail("verify=keyring-locked");
        const epoch = this.epoch, operation = ++this.operation;
        account.state = { kind: "verifying", operation };
        let state;
        try {
            if (typeof request !== "function") fail("verify=request-unavailable");
            const answer = await request(structuredClone(account));
            if (!answer || answer.kind !== "inference" || typeof answer.text !== "string" || answer.text.trim() === "")
                fail("verify=no-inference");
            state = { kind: "verified" };
        } catch {
            state = { kind: "unavailable", reason: typeof request === "function" ? "verification-failed" : "verification-request-unavailable" };
        }
        if (this.epoch !== epoch || account.state.kind !== "verifying" || account.state.operation !== operation)
            return { kind: "superseded" };
        account.state = state;
        return state;
    }

    status() {
        const accounts = this.accounts.map(item => {
            const row = provider(item.provider);
            let value;
            switch (item.state.kind) {
            case "found": case "signed-in": case "verifying": case "verified": value = "present"; break;
            case "locked": value = "locked"; break;
            case "unavailable": value = "unavailable"; break;
            default: fail("state=unknown");
            }
            const facts = [item.state.kind, item.state.reason || "", item.plan || "", item.email || "",
                item.identity.kind === "mismatch" ? "Identity mismatch" : ""].filter(Boolean);
            return { label: (row.label + " / " + item.label).slice(0, 60), value, hint: facts.join("; ").slice(0, 240) };
        });
        const brains = this.accounts.filter(item => provider(item.provider).kind !== "speech-key"
            && ["found", "signed-in", "verified"].includes(item.state.kind))
            .map(item => ({ value: item.id, label: (provider(item.provider).label + " / " + item.label).slice(0, 60) }));
        return { accounts, brains };
    }
}

module.exports = { Accounts };
