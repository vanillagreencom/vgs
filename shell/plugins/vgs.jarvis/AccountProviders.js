// Shared by the account judge and its environment-presence reader.
// Login tokens belong to the vendor program, never to the key picker.
var PROVIDERS = [
    { id: "claude", label: "Claude Code", kind: "cli", variable: "CLAUDE_CONFIG_DIR",
        prefix: ".claude", marker: ".credentials.json", command: ["claude", "auth", "status"] },
    { id: "codex", label: "Codex", kind: "cli", variable: "CODEX_HOME",
        prefix: ".codex", marker: "auth.json", command: ["codex", "login", "status"] },
    { id: "openai", label: "OpenAI", kind: "key", variable: "OPENAI_API_KEY", origin: "https://api.openai.com" },
    { id: "anthropic", label: "Anthropic", kind: "key", variable: "ANTHROPIC_API_KEY", origin: "https://api.anthropic.com" },
    { id: "openrouter", label: "OpenRouter", kind: "key", variable: "OPENROUTER_API_KEY", origin: "https://openrouter.ai" },
    { id: "groq", label: "Groq", kind: "key", variable: "GROQ_API_KEY", origin: "https://api.groq.com" },
    { id: "cerebras", label: "Cerebras", kind: "key", variable: "CEREBRAS_API_KEY", origin: "https://api.cerebras.ai" },
    { id: "mistral", label: "Mistral", kind: "key", variable: "MISTRAL_API_KEY", origin: "https://api.mistral.ai" },
    { id: "gemini", label: "Gemini", kind: "key", variable: "GEMINI_API_KEY", origin: "https://generativelanguage.googleapis.com" },
    { id: "elevenlabs", label: "ElevenLabs", kind: "speech-key", variable: "ELEVENLABS_API_KEY", origin: "https://api.elevenlabs.io" },
    { id: "ollama", label: "Ollama", kind: "local", port: 11434, origin: "http://127.0.0.1:11434" },
    { id: "llama-server", label: "llama-server", kind: "local", port: 8080, origin: "http://127.0.0.1:8080" },
    { id: "lm-studio", label: "LM Studio", kind: "local", port: 1234, origin: "http://127.0.0.1:1234" }
];

// Only booleans cross into the helper. No key value enters its environment.
function keyPresence(read) {
    var result = {};
    for (var i = 0; i < PROVIDERS.length; i++) {
        var row = PROVIDERS[i];
        if (row.kind === "key" || row.kind === "speech-key")
            result[row.variable] = Boolean(read(row.variable));
    }
    return result;
}

if (typeof module !== "undefined") module.exports = { PROVIDERS: PROVIDERS, keyPresence: keyPresence };
