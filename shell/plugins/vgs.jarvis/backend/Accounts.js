"use strict";
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const cp = require("node:child_process");
const { Secrets, childEnvironment } = require("./Secrets.js");
const { PROVIDERS, ACCOUNT_DEPTH, accountDirectory, keyPresence, keyProvider, runtimeDirectory } = require("../AccountProviders.js");
const Anchored = require("./Anchored.js");
const Net = require("./net.js");
const Policy = require("./Policy.js");
const Audit = require("./Audit.js");
const ClaudeCode = require("./ClaudeCode.js");
const Providers = require("./Providers.js");
const CodexHarness = require("./CodexHarness.js");
const MAX_ENTRIES = 200;
const MAX_ROWS = 32; // The core's presenceList and choices ceiling.
const MAX_BYTES = 64 * 1024;
const PROBE_TEXT = "Reply OK.";
// Every Verify route's bound on a stalled provider or program, not a latency budget.
const PROBE_MS = 30000;
// The harness probe's whole system prompt, so the probe stays one short turn.
const HARNESS_INSTRUCTIONS = "Answer in one word.";
// Subscriptions whose vendor program the chained engine can run as the brain.
const HARNESS_BRAINS = Object.freeze(["codex"]);

function fail(reason) { throw new Error("jarvis-accounts: " + reason); }
function printable(value, max) {
    return typeof value === "string" && value.length > 0 && value.length <= max && !/[\x00-\x1f\x7f]/.test(value);
}
function modelOf(value) {
    if (!ClaudeCode.isModel(value)) fail("verify=model-invalid");
    return value;
}
function provider(id) {
    const row = PROVIDERS.find(item => item.id === id);
    // Add key permits custom provider labels. Keep their references visible
    // but unavailable; an unknown label must never select another driver.
    return row || { id, label: id, kind: "unsupported" };
}
// A brain choice is any account but a speech-only key.
function brainRow(row) { return row.kind !== "speech-key"; }
function identity(kind, values) {
    const canonical = JSON.stringify(values, (_key, value) => value && typeof value === "object" && !Array.isArray(value)
        ? Object.fromEntries(Object.entries(value).sort(([left], [right]) => left < right ? -1 : left > right ? 1 : 0)) : value);
    return kind + ":" + crypto.createHash("sha256").update(canonical).digest("hex").slice(0, 32);
}

// The anchored walk checks each component, including explicit and hand-added
// paths. An absent default is normal; a linked or unreadable input is not a
// different account.
function directory(value, hold = false) {
    if (!printable(value, 4096) || Buffer.byteLength(value) > 4096
        || !path.isAbsolute(value) || path.normalize(value) !== value)
        fail("directory=absolute-normal-path-required");
    const opened = Anchored.directory(value);
    switch (opened.kind) {
    case "absent": return { kind: "absent" };
    case "directory":
        if (hold) return { kind: "directory", path: value, fd: opened.fd };
        fs.closeSync(opened.fd);
        return { kind: "directory", path: value };
    default: fail("directory=" + opened.kind);
    }
}

function added(value) {
    if (!value || typeof value !== "object" || Array.isArray(value)
        || Object.keys(value).sort().join(",") !== "directory,label,provider"
        || provider(value.provider).kind !== "cli" || !printable(value.label, 60))
        fail("added=shape");
    directory(value.directory);
    return { provider: value.provider, directory: value.directory, label: value.label };
}

// Hand-added rows from accounts.json. A malformed or unreadable file fails
// rather than discarding user additions; an absent file holds none.
function addedRows(file) {
    let fd;
    try {
        fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
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

// Each CLI provider's explicit root from its variable in env, by provider id.
function explicitRoots(env) {
    const result = {};
    for (const row of PROVIDERS) if (row.kind === "cli" && env[row.variable]) result[row.id] = env[row.variable];
    return result;
}

/**
 * The account roots named without the discovery scan: the explicit roots,
 * then the hand-added directories in stateDirectory's accounts.json. Denied
 * protects these beside its name rule. A malformed accounts.json or
 * hand-added directory throws its added= or directory= key.
 */
function accountRoots(stateDirectory, env) {
    return [...new Set(Object.values(explicitRoots(env))
        .concat(addedRows(path.join(stateDirectory, "accounts.json")).map(item => item.directory)))];
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
 * runtimeDirectory is the daemon's, from AccountProviders.runtimeDirectory;
 * a subscription's Verify runs its program there and refuses without one.
 */
class Accounts {
    constructor(stateDirectory, env, presence = keyPresence(name => env[name]), runtime = runtimeDirectory(env.XDG_RUNTIME_DIR)) {
        directory(stateDirectory);
        this.directory = stateDirectory;
        this.runtime = runtime;
        this.file = path.join(stateDirectory, "accounts.json");
        this.env = childEnvironment(env);
        this.home = env.HOME;
        this.config = env.XDG_CONFIG_HOME || path.join(this.home, ".config");
        this.data = env.XDG_DATA_HOME || path.join(this.home, ".local/share");
        this.explicit = explicitRoots(env);
        const expected = PROVIDERS.filter(keyProvider).map(row => row.variable).sort();
        if (!presence || Object.keys(presence).sort().join(",") !== expected.join(",")
            || Object.values(presence).some(value => typeof value !== "boolean")) fail("key-presence=shape");
        this.presence = { ...presence };
        this.secrets = new Secrets(stateDirectory, this.env);
        this.accounts = [];
        this.epoch = 0;
        this.operation = 0;
    }

    added() {
        return addedRows(this.file);
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
                    const row = accountDirectory(entry.name, depth);
                    if (row) insert(row, dir, entry.name.slice(row.prefix.length).replace(/^[-_.]+/, "") || "default");
                    else if (depth < ACCOUNT_DEPTH) scan(dir, depth + 1);
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
            if (opened.kind === "directory") {
                const markerPath = "/proc/self/fd/" + opened.fd + "/" + row.marker;
                const stat = fs.lstatSync(markerPath);
                if (stat.isSymbolicLink()) fail("marker=link");
                marker = stat.isFile() ? "present" : "absent";
            }
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
        // Add key is the producer of this service's API-key attributes.
        // A user's account alias is not a vendor credential-store label.
        if (item.attributes.service === "vgs-jarvis") return false;
        const text = JSON.stringify([item.label, item.attributes]).toLowerCase();
        return /(claude[ -]?code|codex|copilot|oauth|refresh[ _-]?token|access[ _-]?token)/.test(text);
    }

    remember(itemPath, providerId, label) {
        const row = provider(providerId);
        if (!keyProvider(row)) fail("reference=provider");
        const item = this.keyItems().find(value => value.path === itemPath);
        if (!item) fail("reference=item-unavailable");
        this.secrets.remember({ provider: row.id, account: label, origin: row.origin, attributes: item.attributes });
    }

    localAccounts() {
        const result = this.run("ss", ["-H", "-ltn"]);
        try {
            if (result.error || result.status !== 0) return this.localRows()
                .map(({ row, label, source }) => this.account(row, label, { kind: "unavailable", reason: "ports-unavailable" }, source));
            const ports = new Set();
            for (const line of result.stdout.toString("utf8").split("\n").filter(Boolean)) {
                const fields = line.trim().split(/\s+/);
                if (fields.length < 5 || fields[0] !== "LISTEN") fail("ports=reply");
                const match = /^(127\.0\.0\.1|\[::1\]|0\.0\.0\.0|\*|\[::\]):([0-9]+)$/.exec(fields[3]);
                if (match) ports.add(Number(match[2]));
            }
            return this.localRows().filter(({ row }) => ports.has(row.port))
                .map(({ row, label, source }) => this.account(row, label, { kind: "found" }, source));
        } finally { result.stdout?.fill(0); result.stderr?.fill(0); }
    }

    // The keyring and local rows discovery and resolution share. A vendor
    // login item refuses both: it is never an API key.
    keyringRows() {
        return this.secrets.references().map(reference => {
            if (this.vendorLogin({ label: reference.account, attributes: reference.attributes }))
                fail("reference=vendor-login-or-provider");
            return { row: provider(reference.provider), label: reference.account, source: { kind: "keyring", reference } };
        });
    }

    localRows() {
        return PROVIDERS.filter(row => row.kind === "local")
            .map(row => ({ row, label: "local", source: { kind: "local", origin: row.origin } }));
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
        for (const row of PROVIDERS) if (keyProvider(row) && this.presence[row.variable])
            result.push(this.account(row, "environment", { kind: "found" }, { kind: "variable", name: row.variable, origin: row.origin }));
        for (const { row, label, source } of this.keyringRows()) {
            if (!keyProvider(row)) {
                result.push(this.account(row, label, { kind: "unavailable", reason: "provider-unsupported" }, source));
                continue;
            }
            const present = this.secrets.presence(source.reference);
            const state = present.value === "present" ? { kind: "found" } : present.value === "locked"
                ? { kind: "locked" } : { kind: "unavailable", reason: present.value === "absent" ? "key-absent" : "keyring-unavailable" };
            result.push(this.account(row, label, state, source));
        }
        result.push(...this.localAccounts());
        if (result.length > MAX_ROWS) fail("discovery=account-limit");
        this.accounts = result;
        return this.accounts;
    }

    /**
     * The daemon's brain selection: a saved Brain account id among keyring
     * references, local servers and subscription directories with a harness
     * handoff, with the declaration's Verify probe model; a subscription's
     * model is "", its program's own default. It runs no vendor command and
     * reads no port, so it proves neither login nor a listening server. A
     * subscription without a handoff, a speech-only key, an unsupported label
     * or an unknown id is null.
     */
    resolve(id) {
        for (const { row, label, source } of [...this.keyringRows(), ...this.localRows()]) {
            if (this.account(row, label, { kind: "found" }, source).id !== id) continue;
            if ((source.kind === "keyring" && !keyProvider(row)) || !brainRow(row)) return null;
            return { id, provider: row.id, label, source, model: row.probe.model };
        }
        for (const candidate of this.candidates()) {
            if (identity("cli", [candidate.provider, candidate.directory]) !== id) continue;
            if (!HARNESS_BRAINS.includes(candidate.provider)) return null;
            return { id, provider: candidate.provider, label: candidate.label.slice(0, 60),
                source: { kind: "cli", directory: candidate.directory }, model: "" };
        }
        return null;
    }

    /**
     * Explicit user action only. Each operation names the current discovery
     * epoch. A refresh or a replacement Verify invalidates its late result.
     * Production uses the origin-bound door; a caller may supply a transport
     * port for an isolated state-machine consumer.
     */
    async verify(id, initiation, request = (account, selectedModel) => this.inference(account, selectedModel), model = "") {
        if (initiation !== "user") fail("verify=explicit-user-required");
        const account = this.accounts.find(item => item.id === id);
        if (!account) fail("verify=account-unavailable");
        const row = provider(account.provider);
        if (row.kind === "unsupported" || (account.source.kind === "keyring" && !keyProvider(row)))
            fail("verify=provider-unsupported");
        if (account.state.kind === "verifying") fail("verify=busy");
        if (account.state.kind === "locked") fail("verify=keyring-locked");
        const epoch = this.epoch, operation = ++this.operation;
        account.state = { kind: "verifying", operation };
        let state;
        try {
            if (typeof request !== "function") fail("verify=request-unavailable");
            const answer = await request(structuredClone(account), model);
            if (!answer || answer.kind !== "inference" || typeof answer.text !== "string" || answer.text.trim() === "")
                fail("verify=no-inference");
            state = { kind: "verified" };
        } catch (error) {
            const keyed = /^jarvis-accounts: verify=([a-z0-9-]+)$/.exec(error.message);
            const network = /^jarvis: net=([a-z0-9-]+)$/.exec(error.message);
            const secret = /^jarvis-keys: secret-tool=([a-z-]+)$/.exec(error.message);
            const harness = /^jarvis: brain=((?:harness|codex)-[a-z0-9-]+)(?: |$)/.exec(error.message);
            state = { kind: "unavailable", reason: keyed ? keyed[1] : network ? "network-" + network[1] : secret ? "key-" + secret[1]
                : harness ? harness[1] : typeof request === "function" ? "verification-failed" : "verification-request-unavailable" };
        }
        if (this.epoch !== epoch || account.state.kind !== "verifying" || account.state.operation !== operation)
            return { kind: "superseded" };
        account.state = state;
        return state;
    }

    /**
     * One minimal inference request, after the user's explicit Verify. An API
     * or local route sends one non-streaming HTTP request through the outbound
     * door. A subscription never takes that route: its vendor program owns the
     * login, so the mediated harness handoff runs it, and Claude Code and Codex each have
     * one. Every route passes the same pass the same release and pre-transfer audit record.
     */
    async inference(account, requestedModel = "") {
        const row = provider(account.provider);
        if (account.source.kind === "cli") {
            const model = modelOf(requestedModel); // Refused before any audit record.
            // Checked again, link-free, before the vendor program starts.
            if (directory(account.source.directory).kind !== "directory") fail("verify=account-directory");
            if (this.runtime === "") fail("verify=runtime-directory");
            switch (row.id) {
            case "claude":
                return this.released(account, row.id, row.origin, PROBE_TEXT, release => ClaudeCode.verify({
                    directory: account.source.directory, model, recipients: release.selected, item: release.item,
                    grants: release.grants, parent: this.runtime,
                    environment: this.env, instructions: HARNESS_INSTRUCTIONS, deadline: PROBE_MS,
                    start: events => release.start(() => events.next())
                }).then(text => text.trim() !== ""));
            case "codex":
                // The probe resolves only with the program's nonempty reply.
                return this.released(account, row.id, Providers.select(row.id).base, PROBE_TEXT, release =>
                    release.start(() => CodexHarness.probe({ directory: account.source.directory, env: this.env,
                        runtime: this.runtime, model, text: release.item.content })).then(() => true));
            default:
                fail("verify=subscription-handoff-unavailable");
            }
        }
        if (account.source.kind === "variable") fail("verify=key-reference-required");
        if (!row.probe) fail("verify=speech-inference-unavailable");
        const model = modelOf(requestedModel) || row.probe.model;
        if (row.probe.driver !== "llama" && !model) fail("verify=model-required");
        let body;
        switch (row.probe.driver) {
        case "chat":
            body = { model, messages: [{ role: "user", content: PROBE_TEXT }], stream: false,
                [row.probe.limit]: 1 };
            break;
        case "messages":
            body = { model, max_tokens: 1, messages: [{ role: "user", content: PROBE_TEXT }], stream: false };
            break;
        case "ollama":
            body = { model, prompt: PROBE_TEXT, stream: false, options: { num_predict: 1 } };
            break;
        case "llama":
            if (requestedModel !== "") fail("verify=model-unselectable");
            body = { prompt: PROBE_TEXT, n_predict: 1, stream: false };
            break;
        default: fail("verify=driver-invariant");
        }
        const ref = account.source.kind === "keyring" ? account.source.reference : null;
        const origin = ref === null ? account.source.origin : ref.origin;
        const target = Net.endpoint(origin + row.probe.path);
        return this.released(account, row.id, target.origin, JSON.stringify(body), async ({ selected, item, grants, start }) => {
            const door = Net.create(selected);
            let keyBytes, response;
            const signal = AbortSignal.timeout(PROBE_MS);
            try {
                let key;
                if (ref !== null) {
                    keyBytes = this.secrets.lookup(ref);
                    const value = keyBytes.toString("utf8").replace(/\n$/, "");
                    key = { origin: ref.origin, value, header: row.probe.header, prefix: row.probe.prefix };
                }
                const headers = { "content-type": "application/json" };
                if (row.probe.driver === "messages") headers["anthropic-version"] = "2023-06-01";
                response = await start(() => door.request(item, { url: target.url, headers, key, signal }, grants));
                if (response.kind !== "response") fail("verify=release-refused");
                if (!response.response.ok) fail("verify=http-" + response.response.status);
                const reader = response.response.body.getReader();
                const chunks = [];
                let size = 0;
                try {
                    for (;;) {
                        const part = await reader.read();
                        if (part.done) break;
                        size += part.value.byteLength;
                        if (size > MAX_BYTES) fail("verify=reply-limit");
                        chunks.push(Buffer.from(part.value));
                    }
                } finally { reader.releaseLock(); }
                let result;
                try { result = JSON.parse(Buffer.concat(chunks)); } catch { fail("verify=reply-json"); }
                let text, tokens;
                switch (row.probe.driver) {
                case "chat":
                    if (!Array.isArray(result.choices) || result.choices.length !== 1
                        || result.choices[0].message?.role !== "assistant") fail("verify=no-inference");
                    text = result.choices[0].message.content;
                    tokens = result.usage?.completion_tokens;
                    break;
                case "messages":
                    if (result.type !== "message" || result.role !== "assistant" || !Array.isArray(result.content))
                        fail("verify=no-inference");
                    if (result.content.some(part => !part || (part.type === "text" && typeof part.text !== "string")))
                        fail("verify=no-inference");
                    text = result.content.filter(part => part.type === "text").map(part => part.text).join("");
                    tokens = result.usage?.output_tokens;
                    break;
                case "ollama":
                    if (result.done !== true) fail("verify=no-inference");
                    text = result.response; tokens = result.eval_count;
                    break;
                case "llama":
                    text = result.content; tokens = result.tokens_predicted;
                    break;
                default: fail("verify=driver-invariant");
                }
                return (typeof text === "string" && text.trim() !== "") || (Number.isSafeInteger(tokens) && tokens > 0);
            } finally {
                response?.close();
                door.close();
                keyBytes?.fill(0);
            }
        });
    }

    /**
     * The one release and audit owner of a Verify probe. The fixed
     * command-labelled content passes Policy.release for the account's
     * recipient set under the user's Verify grant. transfer({selected, item,
     * grants, start}) sends it, calling start(fn) to run its first transfer
     * inside the pre-transfer audit record, and answers whether the reply
     * proved inference. Every outcome is recorded before this returns.
     */
    async released(account, providerId, origin, content, transfer) {
        const selected = Policy.recipients({ conversation: "verify:" + account.id + ":" + account.state.operation,
            profile: "standard", cloudVision: "never",
            brain: { kind: "network", provider: providerId, account: account.id, origin },
            speech: [{ kind: "local", provider: "verification-result", account: account.id }] });
        const item = Policy.item(content, ["command"]);
        // This operation exists only after the user's explicit Verify consent.
        const grants = [{ recipients: selected, labels: ["command"] }];
        const decision = Policy.release(item, selected, grants);
        const audit = Audit.create({ state: this.directory });
        const event = { kind: "release", gen: this.epoch, op: account.state.operation, tool: "release",
            args: { labels: item.labels, recipients: selected }, effect: "external",
            decision: decision.kind, confirmed: "physical", outcome: "pending" };
        try {
            if (decision.kind !== "send") {
                const saved = audit.record({ ...event, outcome: "completed" });
                if (saved.kind !== "recorded") fail("verify=audit-unavailable");
                fail("verify=release-refused");
            }
            const proven = await transfer({ selected, item, grants, start: send => {
                const started = audit.before(event, send);
                if (started.kind !== "started") fail("verify=audit-unavailable");
                return started.value;
            } });
            if (proven !== true) fail("verify=no-inference");
            const saved = audit.record({ ...event, outcome: "completed" });
            if (saved.kind !== "recorded") fail("verify=audit-unavailable");
            return { kind: "inference", text: "Inference completed" };
        } catch (error) {
            const saved = audit.record({ ...event, outcome: "failed" });
            if (saved.kind !== "recorded") fail("verify=audit-unavailable");
            throw error;
        } finally { audit.close(); }
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
        const brains = this.accounts.filter(item => brainRow(provider(item.provider))
            && ["found", "signed-in", "verified"].includes(item.state.kind))
            .map(item => ({ value: item.id, label: (provider(item.provider).label + " / " + item.label).slice(0, 60) }));
        return { accounts, brains };
    }
}

module.exports = { Accounts, accountRoots };
