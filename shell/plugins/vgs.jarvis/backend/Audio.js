// One owner for capture, paced playback, heard-prefix reports and the sidecar feed.
// Speech consumers supply PCM sinks/sources. Audio never transcribes
// or changes a default device. Session admits half-duplex only.
"use strict";
const cp = require("node:child_process");
const path = require("node:path");
const { Readable } = require("node:stream");

const PCM_RATE = 24000;
const BUFFER_BYTES = 64 * 1024;
const PLAYBACK_LEAD_MS = 60;
const NODE_LATENCY_MS = 20;
const PLAYBACK_QUEUE_BYTES = PCM_RATE * 2 * 30;
const TRANSCRIPT_BYTES = 64 * 1024;
const DISCOVERY_BYTES = 1024 * 1024;
const STREAM_PROPERTIES = JSON.stringify({ "node.dont-fallback": true, "node.dont-reconnect": true });

class Audio {
    constructor({ session, environment, clock, offers, level, fault, captureSink, playbackSource }) {
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
        this.children = new Map();
        this.state = null;
        this.lifetime = { kind: "open" };
        this.devices = { microphones: [], speakers: [] };
        this.discovery = { kind: "idle", retries: 0 };
        this.nodes = new Map();
        this.capture = null;
        this.playback = null;
        this.feed = null;
        this.playbackFeed = null;
        this.lastPlayback = null;
        this.lastLevel = -Infinity;
        this.levels = { capture: 0, playback: 0 };
        this.release = Promise.resolve();
        this.capturePort = {
            open: (e, done, failed) => this.openCapture(e, done, failed),
            close: (e, done) => this.teardown("capture-close", ["capture"]).then(done)
        };
        this.playbackPort = {
            start: (e, done, failed) => this.startPlayback(e, done, failed),
            flush: (e, done) => {
                const release = this.teardown("interrupt", ["playback"]);
                const result = this.lastPlayback;
                return release.then(() => done(result !== null && result.gen === e.gen
                    && result.op === e.target ? result : null));
            }
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
            child.stdio[4].once("error", reject);
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
        if (this.lifetime.kind === "closed") return Promise.reject(new Error("audio-start-refused"));
        const prior = this.discovery;
        switch (prior.kind) {
        case "starting":
        case "monitoring":
            return prior.ready;
        case "retiring":
            return prior.closed.then(() => this.discover());
        case "failed":
            return Promise.reject(prior.error);
        case "waiting":
            this.clock.clear(prior.timer);
            break;
        case "idle":
            break;
        default:
            throw new Error("discovery-state: " + prior.kind);
        }
        const discovery = { kind: "starting", retries: prior.retries, ready: null };
        this.discovery = discovery;
        discovery.ready = this.monitor(discovery);
        return discovery.ready;
    }

    retireDiscovery(discovery, error) {
        if (discovery.kind === "retiring" || this.discovery !== discovery || this.lifetime.kind === "closed") return;
        discovery.kind = "retiring";
        discovery.closed = this.teardown("discovery-failed", ["discovery"]).then(() => {
            if (this.lifetime.kind === "closed") return;
            // pw-dump's monitor ends when its PipeWire connection ends.
            // Bound reconnection over this Audio lifetime, including flapping.
            if (discovery.retries === 3) {
                const exhausted = new Error("discovery-recovery-exhausted: " + error.message);
                this.discovery = { kind: "failed", error: exhausted };
                this.fault(exhausted.message);
                return;
            }
            const waiting = { kind: "waiting", retries: discovery.retries + 1, timer: null };
            this.discovery = waiting;
            waiting.timer = this.clock.set(() => {
                if (this.lifetime.kind === "closed" || this.discovery !== waiting) return;
                void this.discover().catch(error => this.fault(error.message));
            }, 250 * Math.pow(2, discovery.retries));
        });
        this.devices = { microphones: [], speakers: [] };
        this.nodes.clear();
        this.offers(this.devices);
        this.failCapture("discovery-failed", error.message);
        this.fault(error.message);
    }

    async monitor(discovery) {
        let owner;
        try { owner = await this.spawn("discovery", "pw-dump", ["--monitor", "--no-colors"]); }
        catch (error) { this.retireDiscovery(discovery, error); throw error; }
        return new Promise((resolve, reject) => {
            let tail = "", size = 0, depth = 0, quoted = false, escaped = false, started = false;
            const { StringDecoder } = require("node:string_decoder");
            const decoder = new StringDecoder("utf8");
            const failed = error => {
                reject(error);
                this.retireDiscovery(discovery, error);
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
                            discovery.kind = "monitoring";
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

    snapshot(snapshot, mode = "delta") {
        if (!Array.isArray(snapshot) || snapshot.length > 4096) throw new Error("discovery-shape");
        if (mode === "full") this.nodes.clear();
        for (const node of snapshot) {
            if (!Number.isSafeInteger(node.id)) throw new Error("discovery-id");
            if (node.info === null) this.nodes.delete(node.id);
            else if (node.type === "PipeWire:Interface:Node") {
                const prior = this.nodes.get(node.id);
                const props = node.info && node.info.props;
                if (!props) continue;
                const group = props["media.class"] === undefined ? (prior && prior.group)
                    : props["media.class"] === "Audio/Source" ? "microphones"
                    : props["media.class"] === "Audio/Sink" ? "speakers" : null;
                if (!group) { this.nodes.delete(node.id); continue; }
                const value = props["node.name"] === undefined ? (prior && prior.value) : props["node.name"];
                const label = props["node.description"] || props["node.nick"] || (prior && prior.label) || value;
                if (typeof value !== "string" || !/^[^\x00-\x1f\x7f]{1,200}$/.test(value)
                        || typeof label !== "string" || !/^[^\x00-\x1f\x7f]+$/.test(label))
                    throw new Error("discovery-device");
                if (!this.nodes.has(node.id) && this.nodes.size >= 4096) throw new Error("discovery-nodes");
                // Retain only bounded offer data, never arbitrary properties
                // another client can add or remove indefinitely.
                this.nodes.set(node.id, { group, label: label.slice(0, 60), value });
            }
        }
        const devices = { microphones: [], speakers: [] };
        for (const { group, label, value } of this.nodes.values()) {
            if (devices[group].some(item => item.value === value)) throw new Error("discovery-duplicate");
            devices[group].push({ label, value });
        }
        for (const group of Object.keys(devices)) {
            devices[group].sort((a, b) => a.value < b.value ? -1 : a.value > b.value ? 1 : 0);
            devices[group] = devices[group].slice(0, 32);
        }
        this.devices = devices;
        this.offers(devices);
        if (this.capture !== null && this.capture.target !== null
                && !devices.microphones.some(item => item.value === this.capture.target))
            this.failCapture("device-lost", "");
        if (this.playback !== null && this.playback.target !== null
                && !devices.speakers.some(item => item.value === this.playback.target))
            this.failPlayback("device-lost");
    }

    selected(group, setting) {
        const offers = this.devices[group];
        const configured = this.state.settings[setting] || "";
        const value = configured === "" ? (offers[0] && offers[0].value) : configured;
        if (!offers.some(item => item.value === value)) throw new Error("device-lost");
        return value;
    }

    async openCapture(e, done, failed) {
        let capture = null;
        try {
            await this.release;
            if (!this.allowed("capture")) throw new Error("capture-refused");
            capture = { kind: "opening", owner: null, e, failed, target: null };
            this.capture = capture;
            await this.discover();
            if (!this.allowed("capture") || this.capture !== capture) return;
            const target = this.selected("microphones", "microphone");
            capture.target = target;
            if (this.captureSink === null) throw new Error("speech-unavailable");
            const feed = this.captureSink(e);
            this.feed = feed;
            if (feed === null) throw new Error("speech-unavailable");
            feed.on("error", error => {
                if (this.capture === capture) this.failCapture("provider-disconnected", error.message);
            });
            if (!this.allowed("capture") || this.capture !== capture) return;
            const owner = await this.spawn("capture", "pw-record", [
                "--raw", "--rate", String(PCM_RATE), "--channels", "1", "--format", "s16",
                "--target", target,
                "--properties", STREAM_PROPERTIES, "-"
            ]);
            if (this.capture !== capture) return;
            capture.owner = owner;
            capture.kind = "open";
            let tail = Buffer.alloc(0);
            let opened = false;
            owner.child.stdout.on("data", data => {
                if (owner.stopping || this.capture !== capture) return;
                const frame = Buffer.concat([tail, data]);
                tail = frame.subarray(frame.length - frame.length % 2);
                const pcm = frame.subarray(0, frame.length - frame.length % 2);
                if (!opened && pcm.length !== 0) {
                    opened = true;
                    if (this.allowed("capture")) done();
                }
                if (pcm.length > BUFFER_BYTES || feed.writableLength + pcm.length > BUFFER_BYTES) {
                    this.failCapture("capture-overflow", "");
                    return;
                }
                if (!feed.write(pcm)) owner.child.stdout.pause();
                this.reportLevel(e.gen, "capture", pcm);
            });
            feed.on("drain", () => { if (!owner.stopping) owner.child.stdout.resume(); });
            owner.closed.then(() => {
                if (this.capture === capture && !owner.stopping) void this.captureExited(capture, owner);
            });
            if (!this.allowed("capture")) await this.teardown("capture-refused", ["capture"]);
        } catch (error) {
            if (capture !== null && this.capture !== capture) return;
            if (capture !== null) capture.kind = "failed";
            await this.teardown("capture-failed", ["capture"]);
            failed(error.message === "device-lost" ? "device-lost" : "audio-start: " + error.message);
        }
    }

    // A stream exit and a node-removal message arrive on separate pipes.
    // Read a fresh snapshot before deciding whether the selected device was
    // lost. This one-shot read belongs to the same discovery owner.
    async captureExited(capture, owner) {
        await this.teardown("capture-failed", ["capture"]);
        if (!this.session.live(this.state, capture.e, "capture", ["opening", "open"])) return;
        try {
            await this.refreshDevices();
            if (!this.session.live(this.state, capture.e, "capture", ["opening", "open"])) return;
            capture.failed(this.devices.microphones.some(item => item.value === capture.target)
                ? "capture-exit-" + (owner.exit.signal || owner.exit.code) : "device-lost");
        } catch (error) {
            this.nodes.clear();
            this.devices = { microphones: [], speakers: [] };
            this.offers(this.devices);
            this.fault("device-probe: " + error.message);
            if (this.session.live(this.state, capture.e, "capture", ["opening", "open"]))
                capture.failed("device-probe: " + error.message);
        }
    }

    async refreshDevices() {
        const owner = await this.spawn("discovery", "pw-dump");
        const chunks = [];
        let bytes = 0, overflow = false;
        owner.child.stdout.on("data", data => {
            bytes += data.length;
            if (bytes > DISCOVERY_BYTES) {
                overflow = true;
                void this.teardown("discovery-overflow", ["discovery"]);
            } else chunks.push(data);
        });
        await owner.closed;
        if (overflow) throw new Error("discovery-overflow");
        if (owner.stopping) throw new Error("discovery-ended");
        if (owner.exit.code !== 0) throw new Error("discovery-exit: " + owner.diagnostic.trim());
        this.snapshot(JSON.parse(Buffer.concat(chunks).toString("utf8")), "full");
    }

    failCapture(reason, diagnostic) {
        const capture = this.capture;
        if (capture === null || capture.kind === "failed" || (capture.owner !== null && capture.owner.stopping)) return;
        capture.kind = "failed";
        void this.teardown(reason, ["capture"]).then(() => capture.failed(reason));
        if (diagnostic !== "") this.fault(reason + ": " + diagnostic.slice(0, 200));
    }

    reportLevel(gen, channel, pcm) {
        if (pcm.length === 0) return;
        let square = 0;
        for (let i = 0; i < pcm.length; i += 2) square += (pcm.readInt16LE(i) / 32768) ** 2;
        this.levels[channel] = Math.min(1, Math.sqrt(square / (pcm.length / 2)));
        const at = this.clock.now();
        if (at - this.lastLevel >= 1000 / 30) {
            this.lastLevel = at;
            this.level(gen, { ...this.levels });
        }
    }

    /** Return a lower bound, never received PCM or an estimate of word timing. */
    playbackResult(playback) {
        const heardFrames = Math.max(0, playback.written - Math.ceil(
            PCM_RATE * (PLAYBACK_LEAD_MS + NODE_LATENCY_MS) / 1000));
        let end = 0;
        for (const word of playback.words) {
            if (word.frame > heardFrames) break;
            end = word.end;
        }
        return Object.freeze({ gen: playback.e.gen, op: playback.e.op, source: playback.e.source,
            writtenFrames: playback.written, heardFrames, heardText: playback.text.slice(0, end).trimEnd() });
    }

    // One waiter belongs to the playback operation, whether blocked on input,
    // the clock or pw-cat. Teardown wakes it and removes every listener/timer.
    waitPlayback(playback, stream, event, ms) {
        return new Promise((resolve, reject) => {
            let timer = null;
            const finish = error => {
                if (timer !== null) this.clock.clear(timer);
                if (stream !== null) {
                    stream.removeListener(event, ready);
                    stream.removeListener("close", ready);
                    stream.removeListener("end", ready);
                    stream.removeListener("error", finish);
                }
                playback.wake = null;
                if (error) reject(error); else resolve();
            };
            const ready = () => finish();
            playback.wake = ready;
            if (stream !== null) {
                stream.once(event, ready);
                stream.once("close", ready);
                stream.once("end", ready);
                stream.once("error", finish);
            } else timer = this.clock.set(ready, ms);
        });
    }

    playbackPacket(playback, packet) {
        const pcm = Buffer.isBuffer(packet) ? packet : packet && packet.pcm;
        if (!Buffer.isBuffer(pcm) || pcm.length > BUFFER_BYTES || pcm.length % 2 !== 0)
            throw new Error("playback-frame");
        const sentence = Buffer.isBuffer(packet) ? undefined : packet && packet.sentence;
        if (sentence !== undefined) {
            if (sentence === null || typeof sentence.text !== "string" || sentence.text.trim() === ""
                    || !Number.isSafeInteger(sentence.frames) || sentence.frames < pcm.length / 2
                    || sentence.frames > PCM_RATE * 30 || playback.received < playback.sentenceEnd)
                throw new Error("playback-sentence");
            const separator = playback.text === "" ? "" : " ";
            if (Buffer.byteLength(playback.text + separator + sentence.text) > TRANSCRIPT_BYTES)
                throw new Error("playback-transcript-overflow");
            const base = playback.text.length + separator.length;
            const words = sentence.words === undefined
                ? [{ frame: sentence.frames, end: sentence.text.length }] : sentence.words;
            if (!Array.isArray(words) || words.length === 0 || playback.words.length + words.length > 4096)
                throw new Error("playback-words");
            let frame = 0, end = 0;
            for (const word of words) {
                // Providers supply actual alignment, not proportional guesses.
                // A missing alignment credits only the completed sentence.
                if (word === null || typeof word !== "object"
                        || !Number.isSafeInteger(word.frame) || word.frame <= frame || word.frame > sentence.frames
                        || !Number.isSafeInteger(word.end) || word.end <= end || word.end > sentence.text.length
                        || (word.end < sentence.text.length
                            && !/\s/u.test(sentence.text[word.end - 1]) && !/\s/u.test(sentence.text[word.end])))
                    throw new Error("playback-words");
                frame = word.frame;
                end = word.end;
                playback.words.push({ frame: playback.received + frame, end: base + end });
            }
            if (frame !== sentence.frames || end !== sentence.text.length) throw new Error("playback-words");
            playback.text += separator + sentence.text;
            playback.sentenceEnd = playback.received + sentence.frames;
        }
        playback.received += pcm.length / 2;
        return pcm;
    }

    async writePlayback(playback, owner, frame) {
        let offset = 0;
        while (offset < frame.length && this.playback === playback && !owner.stopping) {
            const now = this.clock.now();
            // Rebase after starvation or a stalled event loop. No catch-up burst.
            playback.frontier = Math.max(playback.frontier === null ? now : playback.frontier, now);
            const available = Math.floor((now + PLAYBACK_LEAD_MS - playback.frontier) * PCM_RATE / 1000);
            const needed = Math.min((frame.length - offset) / 2, PCM_RATE * NODE_LATENCY_MS / 1000);
            if (available < needed) {
                await this.waitPlayback(playback, null, null,
                    Math.max(1, Math.ceil(playback.frontier - now - PLAYBACK_LEAD_MS + needed * 1000 / PCM_RATE)));
                continue;
            }
            const bytes = needed * 2;
            const pcm = frame.subarray(offset, offset + bytes);
            if (owner.child.stdin.writableLength + bytes > BUFFER_BYTES) throw new Error("playback-overflow");
            const flowing = owner.child.stdin.write(pcm);
            playback.written += bytes / 2;
            playback.frontier += bytes * 1000 / (PCM_RATE * 2);
            offset += bytes;
            this.reportLevel(playback.e.gen, "playback", pcm);
            if (!flowing) {
                await this.waitPlayback(playback, owner.child.stdin, "drain");
                if (this.playback !== playback || owner.stopping) return;
                if (owner.exit !== null || owner.child.stdin.destroyed)
                    throw new Error("playback-pipe-closed");
            }
        }
    }

    async startPlayback(e, done, failed) {
        if (this.playback !== null) { failed("playback-busy"); return; }
        // Install the operation before the first await. An immediate flush must
        // retire startup too, even before there is a source or audio child.
        const playback = { kind: "starting", e, failed, target: null, wake: null,
            written: 0, received: 0, frontier: null, text: "", words: [], sentenceEnd: 0 };
        this.playback = playback;
        try {
            await this.release;
            if (this.playback !== playback) return;
            if (!this.allowed("playback")) throw new Error("playback-refused");
            if (this.playbackSource === null) throw new Error("playback-source-unavailable");
            const target = this.selected("speakers", "speaker");
            playback.target = target;
            const source = this.playbackSource(e.source);
            if (source === null) throw new Error("playback-source-unavailable");
            if (!(source instanceof Readable)) throw new Error("playback-source");
            this.playbackFeed = source;
            source.on("error", error => {
                if (this.playback === playback) this.failPlayback("playback-source: " + error.message);
            });
            if (this.playback !== playback) {
                await this.teardown("playback-retired", ["playback"]);
                return;
            }
            const unit = source.readableObjectMode ? BUFFER_BYTES : 1;
            const duplex = source.writableHighWaterMark !== undefined;
            const queueLimit = Math.floor((PLAYBACK_QUEUE_BYTES - (duplex ? 3 : 2) * BUFFER_BYTES)
                / unit / (duplex ? 2 : 1));
            // A compliant stream can cross its high-water mark by one chunk.
            const queueAllowance = queueLimit + BUFFER_BYTES / unit;
            if (!Number.isSafeInteger(source.readableHighWaterMark) || source.readableHighWaterMark > queueLimit
                    || (duplex && (!Number.isSafeInteger(source.writableHighWaterMark)
                        || source.writableHighWaterMark > queueLimit))
                    || source.readableEncoding !== null)
                throw new Error("playback-source-buffer");
            const owner = await this.spawn("playback", "pw-cat", [
                "--playback", "--raw", "--latency", String(NODE_LATENCY_MS) + "ms", "--rate", String(PCM_RATE),
                "--channels", "1", "--format", "s16", "--target", target,
                "--properties", STREAM_PROPERTIES, "-"
            ]);
            owner.child.stdout.resume();
            if (this.playback !== playback) return;
            if (!this.allowed("playback")) { await this.teardown("playback-refused", ["playback"]); return; }
            playback.kind = "feeding";
            owner.closed.then(() => {
                if (this.playback === playback && playback.kind === "feeding" && !owner.stopping)
                    this.failPlayback("playback-exit-" + (owner.exit.signal || owner.exit.code));
            });
            while (this.playback === playback && !owner.stopping) {
                if (source.readableLength > queueAllowance || (duplex && source.writableLength > queueAllowance))
                    throw new Error("playback-source-buffer");
                const packet = source.read(source.readableObjectMode ? undefined
                    : Math.min(BUFFER_BYTES, source.readableLength || BUFFER_BYTES));
                if (packet === null) {
                    if (source.readableEnded) break;
                    if (source.destroyed) throw new Error("playback-source-closed");
                    await this.waitPlayback(playback, source, "readable");
                    continue;
                }
                const frame = this.playbackPacket(playback, packet);
                await this.writePlayback(playback, owner, frame);
            }
            if (this.playback !== playback || owner.stopping) return;
            if (playback.received < playback.sentenceEnd) throw new Error("playback-sentence-incomplete");
            playback.kind = "draining";
            owner.child.stdin.end();
            await owner.closed;
            if (!owner.stopping) {
                if (owner.exit.code !== 0) throw new Error("playback-exit-" + (owner.exit.signal || owner.exit.code));
                await this.teardown("playback-complete", ["playback"]);
                done(this.playbackResult(playback));
            }
        } catch (error) {
            if (this.playback !== playback) return;
            await this.teardown("playback-failed", ["playback"]);
            failed(error.message);
        }
    }

    failPlayback(reason) {
        const playback = this.playback;
        if (playback === null || playback.kind === "failed") return;
        playback.kind = "failed";
        void this.teardown("playback-failed", ["playback"]).then(() => playback.failed(reason));
    }

    // The only release path. Mark owners before closing pipes so callbacks
    // cannot treat requested teardown as a device failure or reopen capture.
    teardown(reason, kinds) {
        const owners = [...this.children.values()].filter(owner => kinds.includes(owner.kind));
        const feeds = [];
        for (const owner of owners) {
            owner.stopping = true;
            owner.child.stdio[3].end();
            owner.child.stdin.destroy();
        }
        if (kinds.includes("capture")) {
            this.levels.capture = 0;
            if (this.capture !== null && this.capture.kind !== "failed") this.capture.kind = "retired";
            this.capture = null;
            if (this.feed !== null) {
                if (!this.feed.closed) feeds.push(new Promise(resolve => this.feed.once("close", resolve)));
                this.feed.destroy();
                this.feed = null;
            }
        }
        if (kinds.includes("playback")) {
            this.levels.playback = 0;
            if (this.playback !== null) {
                this.lastPlayback = this.playbackResult(this.playback);
                if (this.playback.kind !== "failed") this.playback.kind = "retired";
                if (this.playback.wake !== null) this.playback.wake();
            }
            this.playback = null;
            if (this.playbackFeed !== null) {
                if (!this.playbackFeed.closed) feeds.push(new Promise(resolve => this.playbackFeed.once("close", resolve)));
                this.playbackFeed.destroy();
                this.playbackFeed = null;
            }
        }
        const release = Promise.all(owners.map(owner => owner.closed).concat(feeds)).then(() => {});
        this.release = Promise.all([this.release, release]).then(() => {});
        return this.release;
    }

    close(reason) {
        this.lifetime = { kind: "closed" };
        if (this.discovery.kind === "waiting") this.clock.clear(this.discovery.timer);
        return this.teardown(reason, ["capture", "playback", "discovery"]);
    }
}

module.exports = { Audio };
