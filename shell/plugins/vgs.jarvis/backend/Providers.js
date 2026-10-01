// The provider table: wire brain drivers and the duplex voice engine. One row
// per provider names its driver, endpoint, key need, documented retention and
// no-store request fields. Sources and fetch dates: docs/architecture/jarvis-brain.md,
// and jarvis-live.md for the voice row.
"use strict";
const Net = require("./net.js");

const LOCAL = Object.freeze({ text: "A loopback server: nothing leaves the machine.", source: null });

// key: "required" for a cloud account, "optional" where the server's operator
// may switch authentication on. noStore: request fields that keep the
// provider from storing the exchange, merged into every request body.
// images: the endpoint documents image content parts with base64 data.
const ROWS = Object.freeze({
    anthropic: { driver: "anthropic-messages", base: "https://api.anthropic.com/v1", key: "required", images: true,
        noStore: null,
        retention: { text: "API inputs and outputs are deleted within 30 days, with policy, legal, agreed-retention and covered-model exceptions. Zero data retention requires an agreement.",
            source: "https://privacy.claude.com/en/articles/7996866-how-long-do-you-store-my-organization-s-data" } },
    openai: { driver: "openai-chat", base: "https://api.openai.com/v1", key: "required", images: true,
        noStore: { store: false },
        retention: { text: "Abuse monitoring logs are kept up to 30 days; API data is not used for training unless the account opts in.",
            source: "https://developers.openai.com/api/docs/guides/your-data" } },
    // The duplex voice engine. base is its WebSocket endpoint; a key stored for
    // the openai row's origin serves it, since both handshake at that origin.
    "openai-live": { driver: "openai-live", base: "wss://api.openai.com/v1/live/sessions", key: "required", images: false,
        noStore: { store: false },
        retention: { text: "Abuse monitoring logs are kept up to 30 days; voice sessions are not used for training, and nothing is stored for forking while store is false.",
            source: "https://developers.openai.com/api/docs/guides/your-data" } },
    openrouter: { driver: "openai-chat", base: "https://openrouter.ai/api/v1", key: "required", images: true,
        noStore: { provider: { data_collection: "deny" } },
        retention: { text: "OpenRouter stores no prompts or responses unless the account opts in; it stores request metadata. Routing is limited to providers that do not collect user data.",
            source: "https://openrouter.ai/docs/guides/privacy/data-collection" } },
    groq: { driver: "openai-chat", base: "https://api.groq.com/openai/v1", key: "required", images: true,
        noStore: null,
        retention: { text: "Not retained by default; inputs and outputs may be logged up to 30 days to troubleshoot reliability or investigate abuse. Zero data retention is an account setting.",
            source: "https://console.groq.com/docs/your-data" } },
    cerebras: { driver: "openai-chat", base: "https://api.cerebras.ai/v1", key: "required", images: true,
        noStore: null,
        retention: { text: "Cerebras does not retain inputs and outputs of its inference services.",
            source: "https://www.cerebras.ai/privacy-policy" } },
    mistral: { driver: "openai-chat", base: "https://api.mistral.ai/v1", key: "required", images: true,
        noStore: null,
        retention: { text: "Input and output are kept 30 rolling days to monitor abuse unless zero data retention is activated for the account.",
            source: "https://legal.mistral.ai/terms/privacy-policy/" } },
    gemini: { driver: "openai-chat", base: "https://generativelanguage.googleapis.com/v1beta/openai", key: "required", images: true,
        noStore: null,
        retention: { text: "Paid tier: logged for a limited period to detect abuse, not used to improve products. Unpaid quota: used to improve products, and human reviewers may read it.",
            source: "https://ai.google.dev/gemini-api/terms" } },
    ollama: { driver: "openai-chat", base: "http://127.0.0.1:11434/v1", key: "optional", images: true,
        noStore: null, retention: LOCAL },
    "llama-server": { driver: "openai-chat", base: "http://127.0.0.1:8080/v1", key: "optional", images: true,
        noStore: null, retention: LOCAL },
    lmstudio: { driver: "openai-chat", base: "http://127.0.0.1:1234/v1", key: "optional", images: true,
        noStore: null, retention: LOCAL },
    // A user's own server: no documentation states its image support or
    // retention, so images go to OCR text and the operator owns retention.
    custom: { driver: "openai-chat", base: null, key: "optional", images: false,
        noStore: null, retention: { text: "Set by the server's operator.", source: null } }
});

const rows = new WeakSet();

function fail(code) { throw new Error("jarvis: provider=" + code); }

function deepFreeze(value) {
    if (value !== null && typeof value === "object") {
        for (const child of Object.values(value)) deepFreeze(child);
        Object.freeze(value);
    }
    return value;
}

/**
 * select(id, customBaseUrl) returns a frozen row with its resolved base, for
 * drivers to accept through assertRow. customBaseUrl is the brain settings'
 * customBaseUrl and is read only for the custom row: an HTTP or HTTPS URL
 * without a query, normalized by net.endpoint and stripped of a final slash.
 */
function select(id, customBaseUrl = "") {
    if (typeof id !== "string" || !Object.hasOwn(ROWS, id)) fail("unknown");
    const row = ROWS[id];
    let base = row.base;
    if (base === null) {
        let target;
        try { target = Net.endpoint(customBaseUrl); } catch { fail("custom-base"); }
        const url = new URL(target.url);
        // A bare "?" leaves search empty but still starts a query.
        if (target.websocket || url.search !== "" || url.href.endsWith("?")) fail("custom-base");
        base = url.href.replace(/\/$/, "");
    }
    const result = deepFreeze(structuredClone({ id, ...row, base }));
    rows.add(result);
    return result;
}

function assertRow(value) {
    if (!rows.has(value)) fail("row");
}

module.exports = { select, assertRow };
