#!/usr/bin/env node
// The provider table against its vendors' documentation, fetched 2026-09-30
// and cited in docs/architecture/jarvis-brain.md; the GPT-Live row 2026-10-01,
// cited in docs/architecture/jarvis-live.md. No request is made.
"use strict";
const { assert, path, backend, world, control } = require("./fixtures/jarvis-voice/assertions.js");
const Providers = require(path.join(backend, "Providers.js"));

// Pinned independently of the table: base URL, key need, image input and
// no-store fields per documented provider. Rows the table adds beyond these
// are not detected here; the brain suite reaches each of these rows.
const documented = {
    openai: ["https://api.openai.com/v1", "required", true, { store: false }],
    openrouter: ["https://openrouter.ai/api/v1", "required", true, { provider: { data_collection: "deny" } }],
    groq: ["https://api.groq.com/openai/v1", "required", true, null],
    cerebras: ["https://api.cerebras.ai/v1", "required", true, null],
    mistral: ["https://api.mistral.ai/v1", "required", true, null],
    gemini: ["https://generativelanguage.googleapis.com/v1beta/openai", "required", true, null],
    ollama: ["http://127.0.0.1:11434/v1", "optional", true, null],
    "llama-server": ["http://127.0.0.1:8080/v1", "optional", true, null],
    "lm-studio": ["http://127.0.0.1:1234/v1", "optional", true, null]
};
function pinned(logic) {
    for (const [id, [base, key, images, noStore]] of Object.entries(documented)) {
        const row = logic.select(id);
        assert.deepEqual([row.id, row.driver, row.base, row.key, row.images, row.noStore], [id, "openai-chat", base, key, images, noStore], id);
        assert.equal(typeof row.retention.text, "string", id);
        if (base.startsWith("https:")) assert.match(row.retention.source, /^https:\/\//, id + " cites its retention source");
        else assert.equal(row.retention.source, null, id + " is a loopback server");
        assert.ok(Object.isFrozen(row) && Object.isFrozen(row.retention), id + " is frozen");
        if (row.noStore !== null) assert.ok(Object.isFrozen(row.noStore), id + " no-store fields are frozen");
        logic.assertRow(row);
    }
    const row = logic.select("anthropic", "http://127.0.0.1:9000/v1");
    assert.deepEqual([row.id, row.driver, row.base, row.key, row.images, row.noStore],
        ["anthropic", "anthropic-messages", "https://api.anthropic.com/v1", "required", true, null]);
    assert.equal(row.retention.source, "https://privacy.claude.com/en/articles/7996866-how-long-do-you-store-my-organization-s-data");
    assert.ok(Object.isFrozen(row) && Object.isFrozen(row.retention));
    const live = logic.select("openai-live", "http://127.0.0.1:9000/v1");
    assert.deepEqual([live.id, live.driver, live.base, live.key, live.images, live.noStore],
        ["openai-live", "openai-live", "wss://api.openai.com/v1/live/sessions", "required", false, { store: false }]);
    assert.equal(live.retention.source, "https://developers.openai.com/api/docs/guides/your-data");
    assert.ok(Object.isFrozen(live) && Object.isFrozen(live.noStore));
    // The harness row: the program owns its login; base names the release recipient.
    const codex = logic.select("codex");
    assert.deepEqual([codex.id, codex.driver, codex.base, codex.key, codex.images, codex.noStore, codex.retention.source],
        ["codex", "codex-app-server", "https://chatgpt.com", "none", false, null, null]);
    const copilot = logic.select("copilot");
    assert.deepEqual([copilot.id, copilot.driver, copilot.base, copilot.key, copilot.images, copilot.noStore, copilot.retention.source],
        ["copilot", "acp", "https://api.githubcopilot.com", "none", false, null, null]);
}
pinned(Providers);

// The chained engine joins an account declaration to its brain row by id.
// Every key and local declaration has a row at the declared origin, and every
// row but custom, whose base is a setting, has a declaration.
const { PROVIDERS } = require(path.join(backend, "../AccountProviders.js"));
function joined(logic) {
    const declared = PROVIDERS.filter(row => row.kind === "key" || row.kind === "local");
    assert.ok(declared.length >= 10, "the declaration filter found the key and local rows");
    for (const row of declared) {
        let selected;
        assert.doesNotThrow(() => { selected = logic.select(row.id); }, row.id + " has a brain row");
        assert.equal(new URL(selected.base).origin, row.origin, row.id + " shares its declared origin");
    }
    for (const id of [...Object.keys(documented), "anthropic"])
        assert.ok(declared.some(row => row.id === id), id + " has an account declaration");
}
joined(Providers);

// [customBaseUrl, resolved base or keyed refusal]. Only the custom row reads it.
const custom = [
    ["http://localhost:9000/v1/", "http://127.0.0.1:9000/v1"],
    ["https://llm.example.test/api", "https://llm.example.test/api"],
    ["https://LLM.example.test:443/", "https://llm.example.test"],
    ["http://192.0.2.1:8000/v1", "http://192.0.2.1:8000/v1"],
    ["", "custom-base"],
    [undefined, "custom-base"],
    ["ws://127.0.0.1:9000/v1", "custom-base"],
    ["http://127.0.0.1:9000/v1?key=1", "custom-base"],
    ["http://127.0.0.1:9000/v1?", "custom-base"],
    ["http://user:pass@127.0.0.1:9000/v1", "custom-base"],
    ["http://127.0.0.1:9000/v1#x", "custom-base"],
    ["file:///tmp/server", "custom-base"],
    ["not a URL", "custom-base"]
];
function resolves(logic, [value, expected]) {
    if (expected.includes("/")) {
        const row = logic.select("custom", value);
        assert.deepEqual([row.base, row.key, row.images, row.noStore, row.retention.source], [expected, "optional", false, null, null], value);
    } else assert.throws(() => logic.select("custom", value), { message: "jarvis: provider=" + expected }, String(value));
}
for (const row of custom) resolves(Providers, row);
assert.equal(Providers.select("openai", "http://127.0.0.1:9000/v1").base, "https://api.openai.com/v1", "only custom reads the setting");
for (const id of ["", "OpenAI", "xai", "constructor", "__proto__", 7])
    assert.throws(() => Providers.select(id), { message: "jarvis: provider=unknown" }, String(id));
assert.throws(() => Providers.assertRow({ ...Providers.select("openai") }), { message: "jarvis: provider=row" });
assert.throws(() => Providers.select("openai").noStore.store = true, TypeError);

let controls = 0;
world("providers", root => {
    const mutants = [
        ["anthropic-driver", 'driver: "anthropic-messages"', 'driver: "openai-chat"', pinned],
        ["anthropic-base", '"https://api.anthropic.com/v1"', '"https://api.anthropic.com"', pinned],
        ["base", '"https://api.groq.com/openai/v1"', '"https://api.groq.com/v1"', pinned],
        ["no-store", "images: true,\n        noStore: { store: false }", "images: true,\n        noStore: null", pinned],
        ["live-no-store", "images: false,\n        noStore: { store: false }", "images: false,\n        noStore: null", pinned],
        ["live-base", '"wss://api.openai.com/v1/live/sessions"', '"wss://api.openai.com/v1/realtime"', pinned],
        ["codex-key", 'base: "https://chatgpt.com", key: "none"', 'base: "https://chatgpt.com", key: "optional"', pinned],
        ["copilot-base", 'base: "https://api.githubcopilot.com", key: "none"', 'base: "https://github.com", key: "none"', pinned],
        ["freeze", "Object.freeze(value);", "", logic => {
            const row = logic.select("openai");
            assert.throws(() => { row.noStore.store = true; }, TypeError);
        }],
        ["custom-query", ' || url.search !== ""', "", logic => resolves(logic, custom[7])],
        ["custom-websocket", "target.websocket || ", "", logic => resolves(logic, custom[6])],
        ["custom-bare-query", ' || url.href.endsWith("?")', "", logic => resolves(logic, custom[8])],
        ["custom-slash", '.replace(/\\/$/, "")', "", logic => resolves(logic, custom[0])],
        ["unknown", "!Object.hasOwn(ROWS, id)", "!(id in ROWS)",
            logic => assert.throws(() => logic.select("constructor"), { message: "jarvis: provider=unknown" })],
        ["account-join", '"lm-studio": { driver', '"lmstudio": { driver', joined],
        ["registered", 'if (!rows.has(value)) fail("row");', "",
            logic => assert.throws(() => logic.assertRow({ ...logic.select("openai") }), { message: "jarvis: provider=row" })]
    ];
    for (const [name, needle, replacement, check] of mutants) {
        control(root, name, "Providers.js", needle, replacement, check);
        controls++;
    }
});
console.log("test-jarvis-providers: ok rows=" + Object.keys(documented).length + " custom=" + custom.length + " controls=" + controls);
