// The outbound door for daemon adapters. No adapter gets the raw WebSocket.
// Session owns create/close. Approval and the pre-transfer audit stay with their
// owners; this installed interface is not connected to the skeleton daemon.
"use strict";
const { isIP } = require("node:net");

/** Parse a transport URL once. WS credentials use the HTTP handshake's origin. */
function endpoint(value) {
    if (typeof value !== "string") throw new Error("jarvis: net=url");
    let url;
    try { url = new URL(value); } catch { throw new Error("jarvis: net=url"); }
    if (!["http:", "https:", "ws:", "wss:"].includes(url.protocol)
            || url.username !== "" || url.password !== "" || url.hash !== "" || url.href.endsWith("#"))
        throw new Error("jarvis: net=url");
    const loopback = url.hostname === "localhost" || url.hostname === "[::1]"
        || (isIP(url.hostname) === 4 && /^127\./.test(url.hostname)) || /^\[::ffff:7f[0-9a-f]{2}:[0-9a-f]{1,4}\]$/.test(url.hostname);
    // Local server defaults use localhost. Pin it without consulting DNS or
    // the user's hosts file. Selection and key storage use this numeric origin.
    if (url.hostname === "localhost") url.hostname = "127.0.0.1";
    const handshake = new URL(url);
    if (handshake.protocol === "ws:") handshake.protocol = "http:";
    if (handshake.protocol === "wss:") handshake.protocol = "https:";
    return Object.freeze({ url: url.href, origin: handshake.origin, loopback,
        websocket: ["ws:", "wss:"].includes(url.protocol) });
}

// These are adapter metadata, not a route for an unbound credential. All
// credential headers enter through the origin-bound key record below.
const METADATA = new Set(["accept", "content-type", "anthropic-version", "anthropic-beta", "openai-beta"]);

function headers(target, values, key) {
    const result = new Headers();
    if (values !== undefined) {
        for (const [name, value] of new Headers(values)) {
            if (!METADATA.has(name)) throw new Error("jarvis: net=header");
            result.set(name, value);
        }
    }
    if (key !== undefined) {
        if (!key || typeof key.origin !== "string" || key.origin !== target.origin)
            throw new Error("jarvis: net=key-origin");
        if (!target.loopback && !target.origin.startsWith("https:")) throw new Error("jarvis: net=key-plaintext");
        if (!["authorization", "x-api-key", "xi-api-key"].includes(key.header)
                || typeof key.value !== "string" || key.value === "" || /[\r\n]/.test(key.value)
                || typeof key.prefix !== "string" || /[\r\n]/.test(key.prefix))
            throw new Error("jarvis: net=key-shape");
        result.set(key.header, key.prefix + key.value);
    }
    return result;
}

/**
 * One transport lifetime per immutable recipient set. request takes
 * (item, {url, method?, headers?, key?, signal?}, grants?). websocket takes the
 * same arguments (without method/signal); its item gates connection metadata,
 * not a frame. Its returned channel sends each labelled frame through release.
 * Ask/withhold opens no connection and writes no frame. Native failures carry
 * no URL, headers or key. HTTP streams stay native Responses for SSE adapters.
 */
function create(selected) {
    const Policy = require("./Policy.js");
    Policy.assertRecipients(selected);
    const active = new Set();
    let closed = false;

    function targetFor(value, websocket) {
        if (closed) throw new Error("jarvis: net=closed");
        const target = endpoint(value);
        const all = [selected.brain, ...selected.speech];
        if (!all.some(recipient => recipient.kind === "network" && recipient.origin === target.origin))
            throw new Error(selected.offline ? "jarvis: net=offline-recipient" : "jarvis: net=recipient");
        if (target.websocket !== websocket) throw new Error("jarvis: net=transport");
        return target;
    }

    async function request(value, options, grants = []) {
        const target = targetFor(options.url, false);
        const metadata = headers(target, options.headers, options.key);
        const decision = Policy.release(value, selected, grants);
        if (decision.kind !== "send") return decision;
        const method = options.method === undefined ? "POST" : options.method;
        const bodyless = method === "GET" || method === "HEAD";
        if (bodyless && decision.content !== "") throw new Error("jarvis: net=body-method");
        const controller = new AbortController();
        const abort = () => controller.abort();
        if (options.signal) {
            if (options.signal.aborted) abort();
            else options.signal.addEventListener("abort", abort, { once: true });
        }
        active.add(abort);
        try {
            const response = await fetch(target.url, { method,
                headers: metadata, body: bodyless ? undefined : decision.content, redirect: "manual", signal: controller.signal });
            if (response.status >= 300 && response.status < 400) {
                await response.body?.cancel();
                throw new Error("jarvis: net=redirect");
            }
            // The session keeps cancellation through stream consumption. Calling
            // close aborts a Response even after request has returned its headers.
            return { kind: "response", response, close: () => {
                abort();
                active.delete(abort);
                options.signal?.removeEventListener("abort", abort);
            } };
        } catch (error) {
            active.delete(abort);
            options.signal?.removeEventListener("abort", abort);
            if (error.message === "jarvis: net=redirect") throw error;
            throw new Error(controller.signal.aborted ? "jarvis: net=aborted" : "jarvis: net=request");
        }
    }

    function websocket(value, options, grants = []) {
        const target = targetFor(options.url, true);
        const metadata = headers(target, options.headers, options.key);
        const decision = Policy.release(value, selected, grants);
        if (decision.kind !== "send") return decision;
        // Node 22's bundled WebSocketInit supports headers. Its handshake uses
        // redirect:error. See docs/architecture/jarvis-release.md § Node contract.
        const socket = new WebSocket(target.url, { headers: metadata });
        const events = new EventTarget();
        const stop = () => socket.close();
        active.add(stop);
        socket.addEventListener("open", () => events.dispatchEvent(new Event("open")));
        socket.addEventListener("message", event => events.dispatchEvent(new MessageEvent("message", { data: event.data })));
        socket.addEventListener("error", () => events.dispatchEvent(new Event("error")));
        socket.addEventListener("close", () => {
            active.delete(stop);
            events.dispatchEvent(new Event("close"));
        });
        return Object.freeze({ kind: "channel", events,
            get readyState() { return socket.readyState; },
            send(frame, frameGrants = []) {
                if (closed) throw new Error("jarvis: net=closed");
                if (socket.readyState !== WebSocket.OPEN) throw new Error("jarvis: net=socket-not-open");
                const released = Policy.release(frame, selected, frameGrants);
                if (released.kind === "send") socket.send(typeof released.content === "string"
                    ? released.content : Buffer.from(released.content));
                return released;
            },
            close: stop });
    }

    return Object.freeze({ request, websocket, close() {
        closed = true;
        for (const stop of active) stop();
        active.clear();
    } });
}

module.exports = { endpoint, create };
