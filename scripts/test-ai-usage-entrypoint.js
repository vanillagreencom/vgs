#!/usr/bin/env node

// Pins the provider stamp on the entrypoint the aiUsage widget actually runs:
// `vshell ai-usage <provider>`, which wraps whichever ai-usage backend is
// installed (VGS-118).
//
// The widget files every payload under the provider the payload itself names
// and discards anything unstamped. The wrapper's OWN error payloads carried no
// stamp, so a genuine backend failure — missing backend, non-zero exit, empty
// output — was discarded as a provider mismatch and the real cause never
// reached the user. A third-party `ai-usage` from PATH predates the field
// entirely, which is the other half of the same problem.
//
// Driven through bin/vshell with a fake backend, because that wrapper layer is
// what the widget calls; scripts/test-ai-usage-provider.js covers the QML side.

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const repoRoot = path.join(__dirname, "..");
const LOGIC = path.join(repoRoot, "config", "vshell", "plugins", "aiUsage", "AiUsageLogic.qml");

// The widget's own acceptance rules, extracted from the shipped QML, so this
// asks whether the WIDGET would accept what the entrypoint emits.
const marked = fs.readFileSync(LOGIC, "utf8")
    .match(/\/\/ BEGIN PROVIDER DECISION\n([\s\S]*?)\/\/ END PROVIDER DECISION/);
assert.ok(marked, "AiUsageLogic.qml must carry the PROVIDER DECISION markers");
const { payloadProvider, payloadIsFor } = new Function(
    `${marked[1]}\nreturn { payloadProvider, payloadIsFor };`
)();

// --- 6. the entrypoint the widget actually runs -----------------------------
//
// The widget runs `vshell ai-usage <provider>`, which wraps the backend. The
// wrapper's OWN error payloads carried no provider stamp, so with payload
// identity enforced a genuine backend failure was discarded as a mismatch and
// the real cause never reached the user. Exercised through bin/vshell, because
// that is the layer the widget calls.

const VSHELL = path.join(repoRoot, "bin", "vshell");
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "vgs-ai-usage-"));

function fakeBackend(name, body) {
    const file = path.join(tmp, name);
    fs.writeFileSync(file, `#!/bin/sh\n${body}\n`, { mode: 0o755 });
    return file;
}

function runEntrypoint(provider, backend) {
    const r = spawnSync(VSHELL, ["ai-usage", provider], {
        encoding: "utf8",
        env: Object.assign({}, process.env, { VSHELL_AI_USAGE_CMD: backend })
    });
    assert.equal(r.status, 0, `vshell ai-usage exited ${r.status}: ${r.stderr}`);
    let parsed = null;
    try {
        parsed = JSON.parse((r.stdout || "").trim());
    } catch (e) {
        assert.fail(`vshell ai-usage did not emit JSON: ${JSON.stringify(r.stdout)}`);
    }
    return parsed;
}

for (const [label, backend] of [
    ["a backend that fails", fakeBackend("fails", 'echo "boom" >&2\nexit 7')],
    ["a backend that prints nothing", fakeBackend("silent", "exit 0")],
    ["a backend that prints non-JSON", fakeBackend("garbage", "echo not-json")]
]) {
    for (const provider of ["claude", "codex"]) {
        const payload = runEntrypoint(provider, backend);
        assert.equal(payload.ok, false, `${label} reports a failure`);
        assert.equal(
            payloadProvider(payload), provider,
            `${label} must still stamp the provider, or the widget discards the real cause`
        );
        assert.ok(payloadIsFor(provider, payload), `${label} is accepted as that fetch's answer`);
    }
}

{
    // A third-party ai-usage engine from PATH predates the field entirely.
    const backend = fakeBackend("unstamped", 'echo \'{"ok":true,"plan":"Max","session":{"pct":12}}\'');
    const payload = runEntrypoint("codex", backend);
    assert.equal(payload.ok, true, "a good payload passes through");
    assert.equal(payload.plan, "Max", "the backend's own fields are untouched");
    assert.equal(payloadProvider(payload), "codex", "an unstamped backend payload is stamped by the wrapper");
}

{
    // The stamp must not overwrite what a backend already said: the backend is
    // the authority on its own identity, and a wrapper that overwrote it would
    // re-introduce attribution by argument.
    const backend = fakeBackend("stamped", 'echo \'{"ok":false,"provider":"claude","error":"nope"}\'');
    const payload = runEntrypoint("codex", backend);
    assert.equal(payloadProvider(payload), "claude", "an existing stamp is preserved, never overwritten");
    assert.ok(!payloadIsFor("codex", payload), "and the widget then rejects it, which is the point");
}

fs.rmSync(tmp, { recursive: true, force: true });

// The backend-not-found branch cannot be reached with the repo's own backend
// present, so it is pinned at the source: every payload cmd_ai_usage emits goes
// through the one stamping helper.
const helperSource = fs.readFileSync(path.join(repoRoot, "bin", "vshell-helper"), "utf8");
const cmdAiUsage = helperSource.slice(
    helperSource.indexOf("def cmd_ai_usage("),
    helperSource.indexOf("def cmd_fonts(")
);
assert.ok(cmdAiUsage.includes('payload.setdefault("provider", provider)'),
    "cmd_ai_usage must stamp the provider on the payloads it emits");
assert.equal((cmdAiUsage.match(/print\(/g) || []).length, 1,
    "cmd_ai_usage must print through the stamping helper only — a second print is an unstamped path");
assert.ok(cmdAiUsage.includes('emit({"ok": False, "error": "ai-usage backend not found"})'),
    "the backend-not-found payload is emitted through the stamping helper");

console.log("ai-usage entrypoint stamping: OK");
