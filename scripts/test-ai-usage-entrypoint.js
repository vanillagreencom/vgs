#!/usr/bin/env node

// Drive the widget entrypoint through bin/vshell with a fake backend.
// Its error payloads and unstamped backend results need provider identity so failures reach the user.

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const repoRoot = path.join(__dirname, "..");

// Read provider fields directly here. test-ai-usage-provider.js exercises widget acceptance decisions.



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

// Use finally so failed assertions cannot leave executable fake backends behind.
try {
    for (const [label, backend] of [
        ["a backend that fails", fakeBackend("fails", 'echo "boom" >&2\nexit 7')],
        ["a backend that prints nothing", fakeBackend("silent", "exit 0")],
        ["a backend that prints non-JSON", fakeBackend("garbage", "echo not-json")]
    ]) {
        for (const provider of ["claude", "codex"]) {
            const payload = runEntrypoint(provider, backend);
            assert.equal(payload.ok, false, `${label} reports a failure`);
            assert.equal(
                payload.provider, provider,
                `${label} must still stamp the provider, or the widget discards the real cause — ` +
                "payloadIsFor() accepts exactly this, proved in test-ai-usage-provider.js"
            );
        }
    }

    {
        // An external backend can omit the provider field.
        const backend = fakeBackend("unstamped", 'echo \'{"ok":true,"plan":"Max","session":{"pct":12}}\'');
        const payload = runEntrypoint("codex", backend);
        assert.equal(payload.ok, true, "a good payload passes through");
        assert.equal(payload.plan, "Max", "the backend's own fields are untouched");
        assert.equal(payload.provider, "codex", "an unstamped backend payload is stamped by the wrapper");
    }

    {
        // Keep a backend-provided identity; overwriting it would conceal an attribution mismatch.
        const backend = fakeBackend("stamped", 'echo \'{"ok":false,"provider":"claude","error":"nope"}\'');
        const payload = runEntrypoint("codex", backend);
        assert.equal(payload.provider, "claude", "an existing stamp is preserved, never overwritten");
        assert.notEqual(payload.provider, "codex",
            "so the widget rejects it as another provider's payload, which is the point");
    }
} finally {
    fs.rmSync(tmp, { recursive: true, force: true });
}

// The repository backend prevents the missing-backend fixture, so inspect wrapper emissions at source.
const helperSource = fs.readFileSync(path.join(repoRoot, "bin", "vshell-helper"), "utf8");
// Blank comments before counting print and stamp calls so prose cannot satisfy emission checks.
const helperCode = helperSource.split("\n").map(l => (/^\s*#/.test(l) ? "" : l)).join("\n");
const cmdAiUsage = helperCode.slice(
    helperCode.indexOf("def cmd_ai_usage("),
    helperCode.indexOf("def cmd_fonts(")
);
assert.ok(cmdAiUsage.includes('payload.setdefault("provider", provider)'),
    "cmd_ai_usage must stamp the provider on the payloads it emits");
assert.equal((cmdAiUsage.match(/print\(/g) || []).length, 1,
    "cmd_ai_usage must print through the stamping helper only — a second print is an unstamped path");
assert.ok(cmdAiUsage.includes('emit({"ok": False, "error": "ai-usage backend not found"})'),
    "the backend-not-found payload is emitted through the stamping helper");

// Inspect each payload object. A jq program can emit both success and failure objects,
// and a stamp in one must not cover the other.

const backend = fs.readFileSync(path.join(repoRoot, "bin", "vshell-ai-usage"), "utf8");

// Read object fields at their own brace depth. A nested provider key cannot stamp its parent.
function objectLiterals(text) {
    const out = [];
    for (let i = 0; i < text.length; i++) {
        if (text[i] !== "{")
            continue;
        let depth = 0;
        let own = "";
        for (let j = i; j < text.length; j++) {
            const ch = text[j];
            if (ch === "{") {
                depth += 1;
                continue;
            }
            if (ch === "}") {
                depth -= 1;
                if (depth === 0) {
                    out.push({ body: text.slice(i + 1, j), own: own });
                    break;
                }
                continue;
            }
            if (depth === 1)
                own += ch;
        }
    }
    return out;
}

{
    const sample = objectLiterals('{ok:true, nested:{provider:$p}} {ok:false,provider:$p}');
    assert.ok(sample.some(o => /ok:true/.test(o.own) && !/provider/.test(o.own)),
        "a key inside a NESTED object must not count as its parent's");
    assert.ok(sample.some(o => /ok:false/.test(o.own) && /provider/.test(o.own)),
        "a key at the object's own level does count");
    // A nested sibling object must not expose its provider key at the parent depth.
    const deeper = objectLiterals("{ok:true, a:{provider:$p, b:{x:1}}}");
    assert.ok(deeper.some(o => /ok:true/.test(o.own) && !/provider/.test(o.own)),
        "a nested stamp must not count as the payload's own even when a deeper object sits " +
        "beside it — that let the scan pass after a top-level payload LOST its stamp");
}

// Inspect jq -n payload builders, not jq -c account normalizers.
// Require the single-quoted program convention within the same command so an unsupported
// quote shape cannot borrow a later program's stamp.
function jqBuildPrograms(text) {
    const out = [];
    const at = /\bjq -n[a-z]*\b/g;
    let hit;
    while ((hit = at.exec(text)) !== null) {
        const rest = text.slice(hit.index + hit[0].length);

        const preamble = rest.match(/^(?:\s*\\\n|\s|--arg(?:json)?\s+\w+\s+"[^"]*")*/)[0];
        const program = rest.slice(preamble.length);
        assert.equal(program[0], "'",
            "every jq payload program in bin/vshell-ai-usage must be single-quoted, or this scan " +
            "cannot tell where it ends and would borrow the next one's text:\n" +
            program.slice(0, 120));
        const close = program.indexOf("'", 1);
        assert.notEqual(close, -1, "an unterminated jq program");
        out.push(program.slice(1, close));
    }
    return out;
}

// Blank comment lines so a documented payload example cannot count as an emission.
const backendCode = backend.split("\n").map(l => (/^\s*#/.test(l) ? "" : l)).join("\n");

// Recognize payloads by their own ok field, with bare jq or quoted JSON keys.
const hasKey = (text, key) => new RegExp(`(^|[{,\\s])"?${key}"?\\s*:`).test(text);
const programs = jqBuildPrograms(backendCode);
assert.ok(programs.length >= 4,
    `expected the backend's payload-building jq programs to be found, got ${programs.length}`);
const payloads = [];
for (const program of programs) {
    for (const object of objectLiterals(program)) {
        if (hasKey(object.own, "ok"))
            payloads.push(object);
    }
}
// Require separate coverage for success and no-live-account payloads in the same program.
assert.ok(payloads.length >= 5,
    `expected every payload object the backend builds to be found, got ${payloads.length}`);
for (const payload of payloads) {
    assert.ok(hasKey(payload.own, "provider"),
        "every payload bin/vshell-ai-usage builds must name its provider at its own level:\n" +
        payload.body.slice(0, 200));
}
assert.ok(!/^\s*(printf|echo)\s+.*['"]\s*\{/m.test(backendCode),
    "a payload printed without jq would bypass the provider stamp entirely");

console.log("ai-usage entrypoint stamping: OK");
