// One owner for capture, playback, the local echo loader and the sidecar feed.
// Speech consumers supply PCM sinks/sources. Audio never transcribes, counts
// heard frames, selects echo parameters or changes a default device.
"use strict";
const cp = require("node:child_process");
const path = require("node:path");
const { once } = require("node:events");

const PCM_RATE = 24000;
const BUFFER_BYTES = 64 * 1024;
const DISCOVERY_BYTES = 1024 * 1024;

class Audio {
    constructor({ session, environment, clock, offers, level, fault, captureSink, playbackSource, echo }) {
        this.session = session;
        this.environment = {};
        for (const key of ["PATH", "HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME",
            "XDG_RUNTIME_DIR", "PIPEWIRE_RUNTIME_DIR", "PIPEWIRE_REMOTE", "LANG", "LC_ALL"])
            if (environment[key] !== undefined) this.environment[key] = environment[key];
        this.clock = clock;
        this.offers = offers;
        this.level = level;
        this.fault = fault;
        this.captureSink = captureSink;
        this.playbackSource = playbackSource;
        this.echo = echo;
        this.children = new Map();
        this.state = null;
        this.lifetime = { kind: "open" };
        this.devices = { microphones: [], speakers: [] };
        this.discovery = null;
        this.nodes = new Map();
        this.capture = null;
        this.feed = null;
        this.playbackFeed = null;
        this.lastLevel = -Infinity;
        this.release = Promise.resolve();
        this.capturePort = {
            open: (e, done, failed) => this.openCapture(e, done, failed),
            close: (e, done) => this.teardown("capture-close").then(done)
        };
        this.playbackPort = {
            start: (e, done, failed) => this.startPlayback(e, done, failed),
            flush: (e, done) => this.teardown("interrupt").then(done)
        };
    }

    observe(state) { this.state = state; }

    allowed(kind) {
        const s = this.state;
        return this.lifetime.kind === "open" && s !== null
            && (kind === "playback" ? this.session.canPlayback(s) : this.session.canCapture(s));
    }

    async spawn(kind, command, args = []) {
        if (this.lifetime.kind === "closed" || (kind !== "discovery"
                && !this.allowed(kind === "playback" ? "playback" : "capture")))
            throw new Error("audio-start-refused");
        const child = cp.spawn("setpriv", ["--pdeathsig", "KILL", "--", "python3", "-I",
            path.join(__dirname, "audio-child.py"), "outer", String(process.pid), command, ...args], {
            env: this.environment, stdio: ["pipe", "pipe", "pipe", "pipe", "pipe"]
        });
        const owner = { child, kind, stopping: false, diagnostic: "", exit: null };
        this.children.set(child, owner);
        child.stdin.on("error", error => {
            if (!owner.stopping && error.code !== "EPIPE") this.fault("audio-write-" + error.code);
        });
        child.stdio[3].on("error", error => {
            if (!owner.stopping && error.code !== "EPIPE") this.fault("audio-lease-" + error.code);
        });
        child.stderr.on("data", data => {
            owner.diagnostic = (owner.diagnostic + data.toString("utf8")).slice(-4096);
        });
        // close includes pipe closure, not just the direct child's exit.
        const closed = new Promise(resolve => {
            child.once("error", error => { owner.diagnostic = "spawn-" + error.code; });
            child.once("close", (code, signal) => {
                owner.exit = { code, signal };
                this.children.delete(child);
                resolve();
            });
        });
        owner.closed = closed;
        child.stdio[3].write("S");
        const ready = new Promise((resolve, reject) => {
            child.stdio[4].once("data", data => data.equals(Buffer.from("R"))
                ? resolve() : reject(new Error("audio-readiness")));
            closed.then(() => reject(new Error("audio-child: " + owner.diagnostic.trim())));
        });
        try { await ready; }
        catch (error) { await this.teardown("start-failed", [kind]); throw error; }
        if (owner.stopping || this.lifetime.kind === "closed") throw new Error("audio-ended");
        return owner;
    }

    // Read-only node discovery. node.name is the stable target accepted by
    // pw-cat; the transient object id is never saved as a setting.
    discover() {
        if (this.discovery !== null) return this.discovery;
        this.discovery = this.monitor();
        return this.discovery;
    }

    async monitor() {
        const owner = await this.spawn("discovery", "pw-dump", ["--monitor", "--no-colors"]);
        return new Promise((resolve, reject) => {
            let tail = "", size = 0, depth = 0, quoted = false, escaped = false, started = false;
            const { StringDecoder } = require("node:string_decoder");
            const decoder = new StringDecoder("utf8");
            const failed = error => {
                reject(error);
                this.offers({ microphones: [], speakers: [] });
                this.devices = { microphones: [], speakers: [] };
                this.failCapture("discovery-failed", error.message);
                this.fault(error.message);
                void this.teardown("discovery-failed", ["discovery"]);
            };
            owner.child.stdout.on("data", data => {
                if (owner.stopping) return;
                try {
                    for (const char of decoder.write(data)) {
                        if (!started && /\s/.test(char)) continue;
                        if (!started && char !== "[") throw new Error("discovery-framing");
                        started = true;
                        tail += char;
                        size += Buffer.byteLength(char);
                        if (size > DISCOVERY_BYTES) throw new Error("discovery-overflow");
                        if (quoted) {
                            if (escaped) escaped = false;
                            else if (char === "\\") escaped = true;
                            else if (char === '"') quoted = false;
                        } else if (char === '"') quoted = true;
                        else if (char === "[" || char === "{") depth++;
                        else if (char === "]" || char === "}") depth--;
                        if (depth === 0 && !quoted) {
                            this.snapshot(JSON.parse(tail));
                            tail = "";
                            size = 0;
                            started = false;
                            resolve();
                        }
                    }
                } catch (error) { failed(error); }
            });
            owner.closed.then(() => {
                if (owner.stopping) reject(new Error("discovery-ended"));
                else failed(new Error("discovery-exit: " + owner.diagnostic.trim()));
            });
        });
    }

    snapshot(snapshot) {
        if (!Array.isArray(snapshot) || snapshot.length > 4096) throw new Error("discovery-shape");
        for (const node of snapshot) {
            if (!Number.isSafeInteger(node.id)) throw new Error("discovery-id");
            if (node.info === null) this.nodes.delete(node.id);
            else if (node.type === "PipeWire:Interface:Node") {
                const prior = this.nodes.get(node.id);
                const props = node.info && node.info.props;
                if (props) this.nodes.set(node.id, { ...(prior || {}), ...props });
            }
        }
        if (this.nodes.size > 4096) throw new Error("discovery-nodes");
        const devices = { microphones: [], speakers: [] };
        for (const p of this.nodes.values()) {
            const group = p["media.class"] === "Audio/Source" ? "microphones"
                : p["media.class"] === "Audio/Sink" ? "speakers" : null;
            if (group === null) continue;
            const value = p["node.name"];
            const label = p["node.description"] || p["node.nick"] || value;
            if (typeof value !== "string" || !/^[^\x00-\x1f\x7f]{1,200}$/.test(value)
                    || typeof label !== "string" || !/^[^\x00-\x1f\x7f]+$/.test(label))
                throw new Error("discovery-device");
            if (devices[group].some(item => item.value === value)) throw new Error("discovery-duplicate");
            devices[group].push({ label: label.slice(0, 60), value });
        }
        for (const group of Object.keys(devices)) {
            devices[group].sort((a, b) => a.value < b.value ? -1 : a.value > b.value ? 1 : 0);
            devices[group] = devices[group].slice(0, 32);
        }
        this.devices = devices;
        this.offers(devices);
        if (this.capture !== null && !devices.microphones.some(item => item.value === this.capture.target))
            this.failCapture("device-lost", "");
    }

    selected(group, setting) {
        const offers = this.devices[group];
        const configured = this.state.settings[setting] || "";
        const value = configured === "" ? (offers[0] && offers[0].value) : configured;
        if (!offers.some(item => item.value === value)) throw new Error("device-lost");
        return value;
    }

    async openCapture(e, done, failed) {
        try {
            await this.release;
            if (!this.allowed("capture")) throw new Error("capture-refused");
            await this.discover();
            if (!this.allowed("capture")) return;
            const target = this.selected("microphones", "microphone");
            if (this.captureSink === null) throw new Error("speech-unavailable");
            this.feed = this.captureSink(e);
            if (this.feed === null) throw new Error("speech-unavailable");
            this.feed.on("error", error => this.failCapture("provider-disconnected", error.message));
            if (this.state.duplex.kind === "echo") {
                if (this.echo === null) throw new Error("echo-unavailable");
                const loader = await this.spawn("echo", "pw-cli");
                loader.child.stdout.resume();
                loader.child.stdin.write("load-module libpipewire-module-echo-cancel " + this.echo.arguments + "\n");
                loader.closed.then(() => {
                    if (!loader.stopping) this.failCapture("echo-exit", loader.diagnostic);
                });
            }
            if (!this.allowed("capture")) { await this.teardown("capture-refused"); return; }
            const owner = await this.spawn("capture", "pw-record", [
                "--raw", "--rate", String(PCM_RATE), "--channels", "1", "--format", "s16",
                "--target", this.state.duplex.kind === "echo" ? this.echo.target : target, "-"
            ]);
            this.capture = { owner, e, failed, target };
            let tail = Buffer.alloc(0);
            let opened = false;
            owner.child.stdout.on("data", data => {
                if (owner.stopping) return;
                const frame = Buffer.concat([tail, data]);
                tail = frame.subarray(frame.length - frame.length % 2);
                const pcm = frame.subarray(0, frame.length - frame.length % 2);
                if (!opened && pcm.length !== 0) {
                    opened = true;
                    if (this.allowed("capture")) done();
                }
                if (pcm.length > BUFFER_BYTES || this.feed.writableLength + pcm.length > BUFFER_BYTES) {
                    this.failCapture("capture-overflow", "");
                    return;
                }
                if (!this.feed.write(pcm)) owner.child.stdout.pause();
                const at = this.clock.now();
                if (at - this.lastLevel >= 1000 / 30) {
                    let square = 0;
                    for (let i = 0; i < pcm.length; i += 2) square += (pcm.readInt16LE(i) / 32768) ** 2;
                    this.lastLevel = at;
                    this.level(e.gen, pcm.length === 0 ? 0 : Math.min(1, Math.sqrt(square / (pcm.length / 2))));
                }
            });
            this.feed.on("drain", () => { if (!owner.stopping) owner.child.stdout.resume(); });
            owner.closed.then(() => {
                if (!owner.stopping) this.failCapture("capture-exit-" + owner.exit.code, owner.diagnostic);
            });
            if (!this.allowed("capture")) await this.teardown("capture-refused");
        } catch (error) {
            await this.teardown("capture-failed");
            failed(error.message === "device-lost" ? "device-lost" : "audio-start: " + error.message);
        }
    }

    failCapture(reason, diagnostic) {
        const capture = this.capture;
        if (capture === null || capture.owner.stopping) return;
        void this.teardown(reason).then(() => capture.failed(reason));
        if (diagnostic !== "") this.fault(reason + ": " + diagnostic.slice(0, 200));
    }

    async startPlayback(e, done, failed) {
        try {
            await this.release;
            if (!this.allowed("playback")) throw new Error("playback-refused");
            if (this.playbackSource === null) throw new Error("playback-source-unavailable");
            const source = this.playbackSource(e.source);
            this.playbackFeed = source;
            const owner = await this.spawn("playback", "pw-cat", [
                "--playback", "--raw", "--latency", "20ms", "--rate", String(PCM_RATE),
                "--channels", "1", "--format", "s16", "--target", this.selected("speakers", "speaker"), "-"
            ]);
            owner.child.stdout.resume();
            if (!this.allowed("playback")) { await this.teardown("playback-refused"); return; }
            for await (const frame of source) {
                if (owner.stopping) return;
                if (!Buffer.isBuffer(frame) || frame.length > BUFFER_BYTES || frame.length % 2 !== 0)
                    throw new Error("playback-frame");
                if (owner.child.stdin.writableLength + frame.length > BUFFER_BYTES)
                    throw new Error("playback-overflow");
                if (!owner.child.stdin.write(frame)) {
                    await Promise.race([once(owner.child.stdin, "drain"), owner.closed]);
                    if (owner.stopping) return;
                }
            }
            owner.child.stdin.end();
            await owner.closed;
            if (!owner.stopping) {
                if (owner.exit.code !== 0) throw new Error("playback-exit");
                await this.teardown("playback-complete", ["playback"]);
                done();
            }
        } catch (error) {
            await this.teardown("playback-failed");
            failed(error.message);
        }
    }

    // The only release path. Mark owners before closing pipes so callbacks
    // cannot treat requested teardown as a device failure or reopen capture.
    teardown(reason, kinds = reason === "capture-close" || reason === "capture-failed"
            || reason === "device-lost" || reason === "provider-disconnected"
        ? ["capture", "echo"] : ["capture", "echo", "playback"]) {
        const owners = [...this.children.values()].filter(owner => kinds.includes(owner.kind));
        const feeds = [];
        for (const owner of owners) {
            owner.stopping = true;
            owner.child.stdio[3].end();
            owner.child.stdin.destroy();
        }
        if (kinds.includes("capture")) {
            this.capture = null;
            if (this.feed !== null) {
                if (!this.feed.closed) feeds.push(new Promise(resolve => this.feed.once("close", resolve)));
                this.feed.destroy();
                this.feed = null;
            }
        }
        if (kinds.includes("playback") && this.playbackFeed) {
            if (!this.playbackFeed.closed) feeds.push(new Promise(resolve => this.playbackFeed.once("close", resolve)));
            this.playbackFeed.destroy();
            this.playbackFeed = null;
        }
        const release = Promise.all(owners.map(owner => owner.closed).concat(feeds)).then(() => {});
        this.release = Promise.all([this.release, release]).then(() => {});
        return this.release;
    }

    close(reason) {
        this.lifetime = { kind: "closed" };
        return this.teardown(reason, ["capture", "echo", "playback", "discovery"]);
    }
}

module.exports = { Audio };
