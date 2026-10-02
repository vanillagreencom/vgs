// Owns a private vendor session. Model arguments pass Tools before vendor argv.
// No host HOME, vendor settings, credentials, profile or attachment is inherited.
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const cp = require("node:child_process");
const crypto = require("node:crypto");
const Tools = require("./Tools.js");
const ComputerHelp = require("./ComputerHelp.js");
const FLOOR = "0.38.1";
const OUTPUT_BYTES = 16384;
const VENDOR_BYTES = 65536;
const COMMAND_MS = 10000;
// One bounded guide persists across private sessions, keyed by the CLI version.
let guidanceCache = null;
const ACTION_POLICY = Object.freeze({ default: "deny", allow: ["navigate", "snapshot", "url", "getattribute", "click", "fill", "close"],
    deny: ["eval", "upload", "download", "state", "network"] });

/** Probe the installed CLI without opening a browser. */
function version(environment) {
    const runtime = roots(environment).runtime;
    fs.mkdirSync(runtime, { recursive: true, mode: 0o700 });
    const scratch = fs.mkdtempSync(path.join(runtime, "browser-version-"));
    const config = path.join(scratch, "config.json");
    let result;
    try {
        fs.writeFileSync(config, "{}", { mode: 0o600 });
        result = cp.spawnSync("agent-browser", ["--version"], { cwd: scratch,
            env: { PATH: environment.PATH, HOME: scratch, LANG: "C.UTF-8", AGENT_BROWSER_CONFIG: config },
            encoding: "utf8", timeout: COMMAND_MS, maxBuffer: 1024 });
    } finally { fs.rmSync(scratch, { recursive: true, force: true }); }
    if (result.error) throw new Error("jarvis: browser=version cause=" + result.error.code);
    if (result.status !== 0) throw new Error("jarvis: browser=version exit=" + result.status);
    const match = /^agent-browser (\d+)\.(\d+)\.(\d+)\s*$/.exec(result.stdout);
    if (match === null) throw new Error("jarvis: browser=version-shape");
    const found = match.slice(1).map(Number);
    const floor = FLOOR.split(".").map(Number);
    if (found[0] < floor[0] || found[0] === floor[0] && (found[1] < floor[1] || found[1] === floor[1] && found[2] < floor[2]))
        throw new Error("jarvis: browser=version-floor need=" + FLOOR);
    return found.join(".");
}

function roots(environment) {
    const home = environment.HOME;
    const data = environment.XDG_DATA_HOME || path.join(home, ".local/share");
    const runtime = environment.XDG_RUNTIME_DIR;
    if (![home, data, runtime].every(value => typeof value === "string" && path.isAbsolute(value)))
        throw new Error("jarvis: browser=directories");
    return { home: path.join(data, "vgs/jarvis/browser-home"), runtime: path.join(runtime, "vgs/jarvis"),
        marker: path.join(data, "vgs/jarvis/browser-ready.json") };
}

/** Readiness is tied to the CLI version verified by setup, never a stale pass. */
function status(environment) {
    let installed;
    try { installed = version(environment); }
    catch (error) { return { tone: "warning", text: error.message.includes("version-floor") ? "Browser driver needs an update" : "Browser driver unavailable", action: true }; }
    try {
        const bytes = fs.readFileSync(roots(environment).marker);
        if (bytes.length > 1024) throw new Error("marker-size");
        const marker = JSON.parse(bytes);
        if (marker.version !== installed) throw new Error("marker-version");
        return { tone: "ok", text: "Private browser ready", action: false };
    } catch (error) {
        return { tone: "warning", text: "Browser needs setup", action: true };
    }
}

/** The owner holds the CLI calls, settings, session, output and skill cache. */
function create({ environment, commandMs = COMMAND_MS }) {
    const installed = version(environment);
    const dirs = roots(environment);
    fs.mkdirSync(dirs.home, { recursive: true, mode: 0o700 });
    fs.mkdirSync(dirs.runtime, { recursive: true, mode: 0o700 });
    const directory = fs.mkdtempSync(path.join(dirs.runtime, "browser-"));
    const privateHome = path.join(directory, "home");
    const downloads = path.join(dirs.home, ".agent-browser/browsers");
    fs.mkdirSync(downloads, { recursive: true, mode: 0o700 });
    fs.mkdirSync(path.join(privateHome, ".agent-browser"), { recursive: true, mode: 0o700 });
    // Only the downloaded browser cache persists. All vendor session data is private.
    fs.symlinkSync(downloads, path.join(privateHome, ".agent-browser/browsers"), "dir");
    const policyFile = path.join(directory, "policy.json");
    const configFile = path.join(directory, "config.json");
    fs.writeFileSync(policyFile, JSON.stringify(ACTION_POLICY), { mode: 0o600 });
    fs.writeFileSync(configFile, JSON.stringify({ noWebmcp: true, idleTimeout: "60s" }), { mode: 0o600 });
    const session = "jarvis-" + crypto.randomUUID();
    const env = { PATH: environment.PATH, HOME: privateHome, LANG: "C.UTF-8",
        XDG_RUNTIME_DIR: directory, XDG_CONFIG_HOME: path.join(directory, "config"),
        XDG_CACHE_HOME: path.join(directory, "cache"), XDG_DATA_HOME: path.join(directory, "data"),
        AGENT_BROWSER_CONFIG: configFile, AGENT_BROWSER_NAMESPACE: session };
    const prefix = ["--session", session, "--action-policy", policyFile, "--content-boundaries", "--max-output", String(OUTPUT_BYTES), "--json"];
    let closed = false;
    let touched = false;
    let active = null;
    let observation = null;

    function options() { return { env, cwd: directory, encoding: "utf8", timeout: commandMs, maxBuffer: VENDOR_BYTES }; }
    function decode(result) {
        if (result.error) throw new Error("jarvis: browser=command cause=" + result.error.code);
        let reply;
        try { reply = JSON.parse(result.stdout); } catch { throw new Error("jarvis: browser=reply-json"); }
        if (result.status !== 0 || reply.success !== true) {
            // v0.38.1 browser launch reports this cause. No other failure installs.
            if (typeof reply.error === "string" && reply.error.startsWith("Chrome not found."))
                throw new Error("jarvis: browser=missing");
            throw new Error("jarvis: browser=command-failed");
        }
        if (!reply.data || typeof reply.data !== "object" || !reply._boundary || typeof reply._boundary.nonce !== "string")
            throw new Error("jarvis: browser=reply-shape");
        return reply;
    }
    function run(argv) {
        if (closed) throw new Error("jarvis: browser=closed");
        touched = true;
        return decode(cp.spawnSync("agent-browser", [...prefix, ...argv], options()));
    }
    function page(reply) {
        const raw = reply.data.origin ?? reply.data.url;
        const refined = Tools.refine({ id: "browser", args: { command: "open", args: { url: raw } } });
        if (refined.kind !== "call") throw new Error("jarvis: browser=page-url");
        return new URL(raw).origin;
    }
    function snapshot() {
        const reply = run(["snapshot"]);
        page(reply);
        if (typeof reply.data.snapshot !== "string" || !reply.data.refs || typeof reply.data.refs !== "object")
            throw new Error("jarvis: browser=snapshot-shape");
        return reply;
    }
    function bounded(text) {
        const bytes = Buffer.from(text);
        return bytes.length <= OUTPUT_BYTES ? text
            : new TextDecoder().decode(bytes.subarray(0, OUTPUT_BYTES - 32), { stream: true }) + "\n[result clipped]";
    }
    function content(reply) {
        // Preserve the vendor nonce and origin around untrusted page text.
        return bounded(JSON.stringify({ _boundary: reply._boundary, data: { origin: reply.data.origin,
            snapshot: reply.data.snapshot } }));
    }
    function narrow(call) {
        const refined = Tools.refine(call);
        if (refined.kind !== "call" || call.id !== "browser") throw new Error("jarvis: browser=call");
        return refined.call.args;
    }
    function inspect(call) {
        const { command, args } = narrow(call);
        if (!["click", "fill", "submit"].includes(command)) return undefined;
        const before = snapshot();
        const ref = before.data.refs[args.ref.slice(1)];
        if (!ref || typeof ref.role !== "string") throw new Error("jarvis: browser=reference");
        const attribute = run(["get", "attr", args.ref, "type"]);
        const site = page(attribute);
        if (site !== page(before) || !(attribute.data.value === null || typeof attribute.data.value === "string"))
            throw new Error("jarvis: browser=target-changed");
        const type = (attribute.data.value ?? "").toLowerCase();
        const submit = command === "submit" || command === "click" && (type === "submit" || type === "image"
            || ref.role === "button" && type !== "button");
        return { target: { kind: "site", id: site, password: type === "password", submit }, ref: args.ref, type };
    }
    function observe(call) {
        try { observation = inspect(call); return observation; }
        catch { observation = null; return undefined; }
    }
    async function execute(call) {
        const { command, args } = narrow(call);
        if (closed) throw new Error("jarvis: browser=closed");
        if (["click", "fill", "submit"].includes(command)) {
            const fresh = inspect(call);
            if (fresh.target.password) throw new Error("jarvis: browser=password");
            if (observation === null || JSON.stringify(fresh) !== JSON.stringify(observation))
                throw new Error("jarvis: browser=target-changed");
        }
        const argv = command === "open" ? ["open", args.url] : command === "read" ? null
            : command === "fill" ? ["fill", args.ref, args.text] : ["click", args.ref];
        if (argv !== null) {
            const result = await new Promise((resolve, reject) => {
                touched = true;
                const child = cp.execFile("agent-browser", [...prefix, ...argv], options(), (error, stdout, stderr) => {
                    active = null;
                    try { resolve(decode({ error: error && !Number.isInteger(error.code) ? error : null,
                        status: error ? error.code : 0, stdout, stderr })); } catch (failure) { reject(failure); }
                });
                active = child;
            });
            // Open or input can redirect to a non-web document. Refuse its content.
            if (command === "open") page(result);
        }
        return content(snapshot());
    }
    const record = { commands: ["agent-browser"], timeoutMs: commandMs * 5 + 1000, cancellable: true, observe,
        start(call, done) {
            void execute(call).then(text => done({ outcome: "completed", content: text }),
                error => done({ outcome: "failed", content: error.message }));
        },
        cancel() { close(); } };
    function close() {
        if (closed) return;
        closed = true;
        if (active !== null) active.kill("SIGKILL");
        try {
            if (touched) {
                const result = cp.spawnSync("agent-browser", [...prefix, "close"], options());
                try { decode(result); } catch { throw new Error("jarvis: browser=close-failed"); }
            }
        } finally { fs.rmSync(directory, { recursive: true, force: true }); }
    }
    function guidance() {
        if (version(environment) !== installed) throw new Error("jarvis: browser=version-changed");
        if (guidanceCache === null || guidanceCache.version !== installed) {
            const result = cp.spawnSync("agent-browser", ["skills", "get", "core"], options());
            if (result.error || result.status !== 0 || !result.stdout.trim()) throw new Error("jarvis: browser=skill");
            const stub = fs.readFileSync(path.join(__dirname, "skills/browser/SKILL.md"), "utf8");
            guidanceCache = { version: installed, text: bounded(stub + "\n\n" + result.stdout) };
        }
        return guidanceCache.text;
    }
    function verify() {
        try { fs.unlinkSync(dirs.marker); } catch (error) { if (error.code !== "ENOENT") throw error; }
        run(["open", "about:blank"]);
        const answer = run(["get", "url"]);
        if (answer.data.url !== "about:blank") throw new Error("jarvis: browser=verify-url");
        // Ready appears only after the private browser closes successfully.
        close();
        const temporary = dirs.marker + "." + crypto.randomUUID();
        fs.writeFileSync(temporary, JSON.stringify({ version: installed }) + "\n", { mode: 0o600 });
        fs.renameSync(temporary, dirs.marker);
    }
    function download() {
        const result = cp.spawnSync("agent-browser", ["install"], { ...options(), env: { ...env, HOME: dirs.home }, timeout: 120000,
            stdio: ["ignore", "inherit", "inherit"] });
        if (result.error || result.status !== 0) throw new Error("jarvis: browser=install-failed");
    }
    return Object.freeze({ record, close, guidance, verify, download });
}

/** Register only a setup-verified driver and browser. Help uses the same owner. */
function install({ router, environment }) {
    let registered = false;
    let current = null;
    let generation = null;
    let ended = false;
    let closed = false;
    function owner() {
        if (closed || ended) throw new Error("jarvis: browser=conversation-ended");
        if (current === null) {
            if (status(environment).tone !== "ok") throw new Error("jarvis: browser=unverified");
            current = create({ environment });
        }
        return current;
    }
    function clear() {
        if (current === null) return;
        const previous = current;
        current = null;
        previous.close();
    }
    const guidance = ComputerHelp.create(undefined, { timeoutMs: COMMAND_MS + 1000,
        start(call, done) {
            try { done({ outcome: "completed", content: owner().guidance() }); }
            catch (error) { done({ outcome: "failed", content: error.message }); }
        } });
    router.register("guidance", guidance);
    function prepare() {
        if (registered || closed || status(environment).tone !== "ok") return;
        router.register("browser", { commands: ["agent-browser"], timeoutMs: COMMAND_MS * 5 + 1000, cancellable: true,
            observe(call) {
                try { return owner().record.observe(call); } catch { return undefined; }
            },
            start(call, done) { owner().record.start(call, done); },
            cancel() { clear(); } });
        guidance.enableBrowser();
        registered = true;
    }
    prepare();
    return Object.freeze({
        sync(state) {
            const changed = generation !== state.gen || ended;
            if (generation !== state.gen || state.conversation.kind === "ended") clear();
            generation = state.gen;
            ended = state.conversation.kind === "ended";
            if (changed && !ended) prepare();
        },
        close() { closed = true; clear(); }
    });
}
module.exports = { create, install, status };
