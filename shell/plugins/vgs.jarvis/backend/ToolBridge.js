// One bridge owner per daemon: the private tools.sock, its session token, the
// MCP connections mcp-shim relays and the bridge's calls pending in the router.
// The router is the gate; this owner never starts an executor or judges an
// action. Contract: docs/architecture/jarvis-bridge.md.
"use strict";
const crypto = require("node:crypto");
const fs = require("node:fs");
const net = require("node:net");
const path = require("node:path");
const Mcp = require("./Mcp.js");
const Policy = require("./Policy.js");
const Private = require("./Private.js");
const Tools = require("./Tools.js");

const SHIM = path.join(__dirname, "mcp-shim");
// The plan's wire line bound. Past it the connection ends: no id is readable.
const LINE_BYTES = 256 * 1024;
// One harness connection, plus room for its restart while the old one drains.
const CONNECTIONS = 4;
// The shim writes its hello as soon as it connects; this bounds a silent peer.
const HELLO_MS = 2000;
// unix(7): sun_path holds 108 bytes, including the terminating byte.
const SOCKET_PATH_BYTES = 107;
const READY = JSON.stringify({ v: 1, type: "ready" });

function fail(code) { throw new Error("jarvis: bridge=" + code); }
function log(line) { process.stderr.write("jarvis: bridge=" + line + "\n"); }
function digest(token) { return crypto.createHash("sha256").update(token).digest(); }

/**
 * create({router, state, audit, directory, clock?}) owns the bridge for the
 * daemon's lifetime. router is the ToolRouter, state returns the runner's
 * Session state, audit is the daemon's writer, directory is hello's
 * directories.runtime. Creation touches no file; open() starts one session.
 */
function create({ router, state, audit, directory, clock = { set: setTimeout, clear: clearTimeout } }) {
    if (typeof directory !== "string" || !path.isAbsolute(directory)) fail("directory");
    const socketPath = path.join(directory, "tools.sock");
    // Router call id -> {connection, request, recipients, answered}. The one
    // judge of whether a router result belongs to the bridge.
    const pending = new Map();
    let session = null;
    let lifetime = "open";

    /** Remove a socket a killed daemon left behind; refuse anything else. */
    function removeStale() {
        let stat;
        try { stat = fs.lstatSync(socketPath); }
        catch (error) { if (error.code === "ENOENT") return; throw error; }
        if (!stat.isSocket() || stat.uid !== process.getuid()) fail("socket-type");
        fs.unlinkSync(socketPath);
    }

    /**
     * Start the one bridge session for a conversation generation and its
     * frozen recipient set. Resolves the launch contract a harness's MCP
     * configuration uses; the token appears only in its environment.
     */
    async function open({ gen, recipients }) {
        if (lifetime !== "open") fail("closed");
        if (session !== null) fail("session-open");
        if (!Number.isSafeInteger(gen) || gen < 0) fail("gen");
        Policy.assertRecipients(recipients);
        if (Buffer.byteLength(socketPath) > SOCKET_PATH_BYTES) fail("socket-path");
        Private.directory(directory);
        removeStale();
        const token = crypto.randomBytes(32).toString("hex");
        const current = { gen, recipients, digest: digest(token), connections: new Set(), server: null };
        current.server = net.createServer(socket => accept(current, socket));
        session = current;
        try {
            await new Promise((resolve, reject) => {
                current.server.once("error", reject);
                current.server.listen(socketPath, resolve);
            });
        } catch (error) {
            end(current);
            fail("listen cause=" + (error.code ?? "unknown"));
        }
        if (session !== current) fail("closed");
        current.server.on("error", error => log("server cause=" + (error.code ?? "unknown")));
        fs.chmodSync(socketPath, 0o600);
        return Object.freeze({
            command: process.execPath, args: Object.freeze([SHIM]),
            env: Object.freeze({ VGS_JARVIS_TOOLS_SOCKET: socketPath, VGS_JARVIS_TOOLS_TOKEN: token }),
            close: () => end(current)
        });
    }

    function accept(current, socket) {
        if (session !== current) { socket.destroy(); return; }
        const connection = { socket, phase: "hello", mcp: "new", tail: "", closed: false, timer: null };
        // A socket error is always followed by close, which drops the connection.
        socket.on("error", () => {});
        // A peer's end of input ends the connection; Node then ends this side.
        socket.on("end", () => drop(current, connection));
        socket.on("close", () => drop(current, connection));
        if (current.connections.size >= CONNECTIONS) { refuse(connection, "connections"); return; }
        current.connections.add(connection);
        connection.timer = clock.set(() => refuse(connection, "hello-deadline"), HELLO_MS);
        socket.setEncoding("utf8");
        socket.on("data", chunk => read(current, connection, chunk));
        socket.on("drain", () => { if (!connection.closed) socket.resume(); });
    }

    /** End a connection with one refusal line. Nothing it sent is routed. */
    function refuse(connection, reason) {
        if (connection.closed) return;
        connection.closed = true;
        if (connection.timer !== null) clock.clear(connection.timer);
        log("refused reason=" + reason);
        connection.socket.end(JSON.stringify({ v: 1, type: "refused", reason }) + "\n");
    }

    function drop(current, connection) {
        connection.closed = true;
        if (connection.timer !== null) clock.clear(connection.timer);
        current.connections.delete(connection);
    }

    function read(current, connection, chunk) {
        connection.tail += chunk;
        let end;
        while (!connection.closed && (end = connection.tail.indexOf("\n")) >= 0) {
            const line = connection.tail.slice(0, end);
            connection.tail = connection.tail.slice(end + 1);
            if (Buffer.byteLength(line) + 1 > LINE_BYTES) { refuse(connection, "line-size"); return; }
            if (connection.phase === "hello") hello(current, connection, line);
            else judge(current, connection, line);
        }
        if (!connection.closed && Buffer.byteLength(connection.tail) >= LINE_BYTES) refuse(connection, "line-size");
    }

    function hello(current, connection, line) {
        let message;
        try { message = JSON.parse(line); } catch { refuse(connection, "hello"); return; }
        if (message === null || typeof message !== "object" || Array.isArray(message)
                || Object.keys(message).sort().join(",") !== "token,type,v"
                || message.v !== 1 || message.type !== "hello" || typeof message.token !== "string") {
            refuse(connection, "hello");
            return;
        }
        // Hashing first gives timingSafeEqual equal lengths for any token.
        if (session !== current || !crypto.timingSafeEqual(digest(message.token), current.digest)) {
            refuse(connection, "token");
            return;
        }
        clock.clear(connection.timer);
        connection.timer = null;
        connection.phase = "mcp";
        connection.socket.write(READY + "\n");
    }

    function write(connection, message) {
        if (connection.closed) return;
        if (!connection.socket.write(JSON.stringify(message) + "\n")) connection.socket.pause();
    }

    function offered() {
        const offers = router.offer();
        const names = Tools.wireNames(offers.map(offer => offer.id));
        if (names === null) throw new Error("jarvis: bridge=tool-name");
        return { names, tools: [...names.keys()].map((name, index) => ({
            name, description: offers[index].description, inputSchema: offers[index].parameters })) };
    }

    function judge(current, connection, line) {
        const verdict = Mcp.accept(line, connection.mcp);
        connection.mcp = verdict.phase;
        const act = verdict.act;
        switch (act.kind) {
        case "reply": write(connection, act.message); return;
        case "none": return;
        case "list": write(connection, Mcp.result(act.id, { tools: offered().tools })); return;
        case "call": call(current, connection, act); return;
        default: throw new Error("jarvis: bridge=act");
        }
    }

    function call(current, connection, act) {
        const { names } = offered();
        if (!names.has(act.name)) { write(connection, Mcp.error(act.id, Mcp.CODES.params, "Unknown tool")); return; }
        // The session serves one conversation generation's live thinking turn.
        const s = state();
        if (s.gen !== current.gen || s.turn.kind !== "thinking") {
            write(connection, Mcp.content(act.id, JSON.stringify({ kind: "refuse", reason: "stale-turn" }), true));
            return;
        }
        const id = "bridge-" + crypto.randomUUID();
        // Registered first: the router delivers a refusal before route returns.
        pending.set(id, { connection, request: act.id, recipients: current.recipients, answered: false });
        router.route({ kind: "tool-call", id, tool: names.get(act.name), arguments: act.arguments },
            { gen: s.turn.gen, op: s.turn.op });
    }

    /**
     * The router's result port asks here first. Returns whether the value
     * answers a bridge call. A timed-out call stays pending while the router
     * still holds its action, so the actual completion is also recognised.
     */
    function deliver(value) {
        const [answer] = value.results;
        const entry = pending.get(answer.id);
        if (entry === undefined) return false;
        if (!(value.outcome === "unknown" && state().action.kind === "running")) pending.delete(answer.id);
        if (entry.answered || entry.connection.closed) return true;
        entry.answered = true;
        const released = Policy.release(answer.item, entry.recipients);
        const recipients = [entry.recipients.brain, ...entry.recipients.speech].map(recipient => recipient.provider);
        const admitted = audit.before({ kind: "release", gen: value.gen, op: value.op, tool: "release",
            args: { labels: released.labels, recipients }, effect: null, decision: released.kind,
            confirmed: "none", outcome: "pending" }, () => write(entry.connection,
            Mcp.content(entry.request, released.content.toString(), value.outcome !== "completed")));
        if (admitted.kind === "refuse")
            write(entry.connection, Mcp.content(entry.request, JSON.stringify({ kind: "refuse", reason: admitted.reason }), true));
        return true;
    }

    /** End a session: connections, socket and token. Calls in the router stay pending and are dropped. */
    function end(current) {
        if (session !== current) return;
        session = null;
        current.digest = null;
        for (const connection of current.connections) {
            connection.closed = true;
            if (connection.timer !== null) clock.clear(connection.timer);
            connection.socket.destroy();
        }
        current.connections.clear();
        // Closing the listener also unlinks tools.sock: libuv's uv__pipe_close.
        current.server.close();
    }

    return Object.freeze({
        open, deliver,
        /** Daemon teardown: end any session and refuse later opens. Idempotent. */
        close() {
            lifetime = "closed";
            if (session !== null) end(session);
        }
    });
}

module.exports = { create };
