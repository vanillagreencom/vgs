// Shared by the account judge and its environment-presence reader.
// Login tokens belong to the vendor program, never to the key picker.
var PROVIDERS = [
    { id: "claude", label: "Claude Code", kind: "cli", variable: "CLAUDE_CONFIG_DIR",
        prefix: ".claude", marker: ".credentials.json", command: ["claude", "auth", "status"] },
    { id: "codex", label: "Codex", kind: "cli", variable: "CODEX_HOME",
        prefix: ".codex", marker: "auth.json", command: ["codex", "login", "status"] },
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

if (typeof module !== "undefined") module.exports = { PROVIDERS: PROVIDERS, keyPresence: keyPresence, keyProvider: keyProvider };
