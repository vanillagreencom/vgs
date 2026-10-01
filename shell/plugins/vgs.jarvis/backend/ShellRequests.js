// The daemon's side of the request wire: ids, the pending bound and reply
// matching. JarvisProtocol judges every message shape; the service answers.
"use strict";

/**
 * create({Protocol, write, clock}) owns the requests awaiting a reply.
 * write(fields) sends {id, kind, args}; the daemon adds v, type, gen and
 * revision and throws the protocol judge's keyed error for a refused one.
 * send(kind, args, timeoutMs, done) answers done exactly once:
 *   {kind:"answer", answer, data}  the service's reply
 *   {kind:"busy"}                  MAX_PENDING_REQUESTS already await a reply
 *   {kind:"refused", reason}       the protocol judge refused the request
 *   {kind:"timeout"}               no reply before timeoutMs
 * A timed-out request still awaits its reply and counts toward the bound,
 * because the service has not answered it. Its late reply is dropped.
 * reply(message) throws a keyed protocol error for an id that awaits no
 * reply or a kind that is not the request's: the service answers each
 * request it received exactly once, so either is a broken peer.
 */
function create({ Protocol, write, clock }) {
    const pending = new Map();
    let last = 0;
    let closed = false;

    function send(kind, args, timeoutMs, done) {
        if (closed) throw new Error("jarvis: requests=closed");
        if (pending.size >= Protocol.MAX_PENDING_REQUESTS) {
            done({ kind: "busy" });
            return;
        }
        const fields = { id: last + 1, kind, args };
        // The writer judges the whole message before it reaches the pipe.
        // A refused argument, such as an oversized model string, fails this
        // request alone; no reply can arrive for a request never written.
        try { write(fields); }
        catch (error) {
            if (!String(error.message).startsWith("jarvis: protocol=")) throw error;
            done({ kind: "refused", reason: error.message });
            return;
        }
        last = fields.id;
        const entry = { kind, state: "waiting", done, timer: null };
        entry.timer = clock.set(() => {
            entry.timer = null;
            entry.state = "expired";
            done({ kind: "timeout" });
        }, timeoutMs);
        pending.set(fields.id, entry);
    }

    function reply(message) {
        const entry = pending.get(message.id);
        if (entry === undefined) throw new Error("jarvis: protocol=reply-unknown");
        if (entry.kind !== message.kind) throw new Error("jarvis: protocol=reply-kind");
        pending.delete(message.id);
        if (entry.state === "expired") return;
        clock.clear(entry.timer);
        entry.done({ kind: "answer", answer: message.answer, data: message.data });
    }

    // Lease loss: no reply can arrive, so no timer may keep the daemon alive.
    function close() {
        closed = true;
        for (const entry of pending.values()) if (entry.timer !== null) clock.clear(entry.timer);
        pending.clear();
    }

    return Object.freeze({ send, reply, close, get pending() { return pending.size; } });
}

module.exports = { create };
