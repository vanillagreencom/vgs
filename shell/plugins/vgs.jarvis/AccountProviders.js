// Shared by the account judge and its environment-presence reader.
// Login tokens belong to the vendor program, never to the key picker.
var PROVIDERS = [
    { id: "claude", label: "Claude Code", kind: "cli", variable: "CLAUDE_CONFIG_DIR", origin: "https://api.anthropic.com",
        prefix: ".claude", marker: ".credentials.json", command: ["claude", "auth", "status"] },
    { id: "codex", label: "Codex", kind: "cli", variable: "CODEX_HOME",
        prefix: ".codex", marker: "auth.json", command: ["codex", "login", "status"] },
    // Copilot documents no login status command; its config.json exists signed in or not.
    { id: "copilot", label: "GitHub Copilot", kind: "cli", variable: "COPILOT_HOME",
        prefix: ".copilot", marker: "config.json", command: null },
    { id: "openai", label: "OpenAI", kind: "key", variable: "OPENAI_API_KEY", origin: "https://api.openai.com",
        probe: { driver: "chat", path: "/v1/chat/completions", model: "gpt-4.1-nano", limit: "max_completion_tokens", header: "authorization", prefix: "Bearer " } },
    { id: "anthropic", label: "Anthropic", kind: "key", variable: "ANTHROPIC_API_KEY", origin: "https://api.anthropic.com",
        probe: { driver: "messages", path: "/v1/messages", model: "claude-haiku-4-5", header: "x-api-key", prefix: "" } },
    { id: "openrouter", label: "OpenRouter", kind: "key", variable: "OPENROUTER_API_KEY", origin: "https://openrouter.ai",
        probe: { driver: "chat", path: "/api/v1/chat/completions", model: "openai/gpt-4.1-nano", limit: "max_tokens", header: "authorization", prefix: "Bearer " } },
    { id: "groq", label: "Groq", kind: "key", variable: "GROQ_API_KEY", origin: "https://api.groq.com",
        probe: { driver: "chat", path: "/openai/v1/chat/completions", model: "llama-3.1-8b-instant", limit: "max_tokens", header: "authorization", prefix: "Bearer " } },
    { id: "cerebras", label: "Cerebras", kind: "key", variable: "CEREBRAS_API_KEY", origin: "https://api.cerebras.ai",
        probe: { driver: "chat", path: "/v1/chat/completions", model: "", limit: "max_completion_tokens", header: "authorization", prefix: "Bearer " } },
    { id: "mistral", label: "Mistral", kind: "key", variable: "MISTRAL_API_KEY", origin: "https://api.mistral.ai",
        probe: { driver: "chat", path: "/v1/chat/completions", model: "mistral-small-latest", limit: "max_tokens", header: "authorization", prefix: "Bearer " } },
    { id: "gemini", label: "Gemini", kind: "key", variable: "GEMINI_API_KEY", origin: "https://generativelanguage.googleapis.com",
        probe: { driver: "chat", path: "/v1beta/openai/chat/completions", model: "gemini-2.5-flash-lite", limit: "max_tokens", header: "authorization", prefix: "Bearer " } },
    { id: "elevenlabs", label: "ElevenLabs", kind: "speech-key", variable: "ELEVENLABS_API_KEY", origin: "https://api.elevenlabs.io" },
    { id: "ollama", label: "Ollama", kind: "local", port: 11434, origin: "http://127.0.0.1:11434",
        probe: { driver: "ollama", path: "/api/generate", model: "" } },
    { id: "llama-server", label: "llama-server", kind: "local", port: 8080, origin: "http://127.0.0.1:8080",
        probe: { driver: "llama", path: "/completion", model: "" } },
    { id: "lm-studio", label: "LM Studio", kind: "local", port: 1234, origin: "http://127.0.0.1:1234",
        probe: { driver: "chat", path: "/v1/chat/completions", model: "", limit: "max_tokens" } }
];

// The daemon's runtime directory under the session's XDG_RUNTIME_DIR, empty
// without one. The service hands it to the daemon in hello and the account
// helper to Verify's harness handoff, so both place Codex in one directory.
function runtimeDirectory(base) {
    return base ? base + "/vgs/jarvis" : "";
}

/**
 * The account directory name rule, shared by discovery and the protected
 * path judge. An entry `depth` levels below HOME, the XDG config home or the
 * XDG data home is an account directory when its name starts with a CLI
 * provider's prefix and depth is 1 to ACCOUNT_DEPTH. Returns that provider's
 * row, else null. The caller supplies the three bases and the depth.
 */
var ACCOUNT_DEPTH = 2;
function accountDirectory(name, depth) {
    if (depth < 1 || depth > ACCOUNT_DEPTH) return null;
    for (var i = 0; i < PROVIDERS.length; i++) {
        var row = PROVIDERS[i];
        if (row.kind === "cli" && name.indexOf(row.prefix) === 0) return row;
    }
    return null;
}

// The CLI providers' explicit root variables, read through read(name), so
// a child sees the same explicit account roots discovery does.
function accountVariables(read) {
    var result = {};
    for (var i = 0; i < PROVIDERS.length; i++)
        if (PROVIDERS[i].kind === "cli") result[PROVIDERS[i].variable] = read(PROVIDERS[i].variable);
    return result;
}

// Only booleans cross into the helper. No key value enters its environment.
function keyProvider(row) {
    return row.kind === "key" || row.kind === "speech-key";
}

function keyPresence(read) {
    var result = {};
    for (var i = 0; i < PROVIDERS.length; i++) {
        var row = PROVIDERS[i];
        if (keyProvider(row))
            result[row.variable] = Boolean(read(row.variable));
    }
    return result;
}

// The account CLI and its QML reader share this exact safe error protocol.
// Only producer-owned keys can leave stderr; values and native errors cannot.
var FAILURE_KEYS = {
    "jarvis-accounts": {
        directory: ["absolute-normal-path-required", "unreadable", "link", "not-directory", "unreadable-or-changed"],
        added: ["shape", "size", "json", "limit", "duplicate", "read-failed", "directory-absent", "write-failed", "cleanup-failed"],
        discovery: ["entry-limit", "directory-unreadable", "account-limit"],
        "key-presence": ["shape"],
        ports: ["reply"],
        reference: ["provider", "item-unavailable", "vendor-login-or-provider"],
        arguments: ["presence", "list", "providers", "items", "add", "remember", "verb"],
        verify: ["explicit-user-required", "account-unavailable", "provider-unsupported", "busy", "keyring-locked"],
        state: ["unknown"],
        operation: ["failed"]
    },
    "jarvis-keys": {
        reference: ["shape", "identity", "origin", "attributes"],
        references: ["directory", "size", "read-failed", "json", "limit", "duplicate", "write-failed", "cleanup-failed"],
        busctl: ["missing", "timeout", "failed", "reply"],
        "secret-tool": ["missing", "timeout", "failed", "empty-or-oversize"],
        items: ["limit-or-duplicate", "reply", "label"],
        store: ["terminal-required"]
    }
};
var MAX_DIAGNOSTIC_CHARS = 256;

function feedDiagnostic(state, chunk) {
    if (state.kind === "oversize") return state;
    var text = state.text + chunk;
    if (text.length > MAX_DIAGNOSTIC_CHARS) return { kind: "oversize" };
    return { kind: "collected", text: text };
}

function helperFailure(text) {
    if (typeof text !== "string" || text.length > MAX_DIAGNOSTIC_CHARS) return "";
    var match = /^([a-z-]+): ([a-z-]+)=([a-z0-9-]+)\n?$/.exec(text);
    if (match === null) return "";
    var fields = FAILURE_KEYS[match[1]];
    var codes = fields === undefined ? undefined : fields[match[2]];
    if (!Array.isArray(codes) || codes.indexOf(match[3]) === -1) return "";
    return match[1] + ": " + match[2] + "=" + match[3];
}

function probeFailure(completion, diagnostic) {
    switch (completion.kind) {
    case "starting": return "jarvis-accounts: process=start-failed";
    case "crashed": return "jarvis-accounts: process=crashed";
    case "exited":
        if (completion.code === 0) return "jarvis-accounts: output=invalid";
        if (diagnostic.kind === "oversize") return "jarvis-accounts: diagnostic=oversize";
        return helperFailure(diagnostic.text) || "jarvis-accounts: process=failed";
    default: throw new Error("jarvis-accounts: process=invalid-outcome");
    }
}

if (typeof module !== "undefined") module.exports = { PROVIDERS: PROVIDERS, runtimeDirectory: runtimeDirectory,
    ACCOUNT_DEPTH: ACCOUNT_DEPTH, accountDirectory: accountDirectory, accountVariables: accountVariables,
    keyPresence: keyPresence, keyProvider: keyProvider, feedDiagnostic: feedDiagnostic, helperFailure: helperFailure, probeFailure: probeFailure };
