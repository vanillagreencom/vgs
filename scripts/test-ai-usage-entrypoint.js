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

// This suite reads the payload's `provider` field directly rather than executing
// the widget's acceptance rule. It used to extract and RUN that rule from
// AiUsageLogic.qml, which meant a QML edit executed code in this process on a
// fork PR's CI run; nothing here needs it. The rule itself — that a payload is
// accepted only when its own stamp matches the fetch's provider — is proved by
// executing it in scripts/test-ai-usage-provider.js, and what this suite proves
// is the other half: that the entrypoint emits a payload carrying that stamp.

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

// try/finally, because a failing assertion throws past a trailing cleanup and
// leaves a directory of executable fake backends behind — which it did, five
// times, before this was wrapped.
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
        // A third-party ai-usage engine from PATH predates the field entirely.
        const backend = fakeBackend("unstamped", 'echo \'{"ok":true,"plan":"Max","session":{"pct":12}}\'');
        const payload = runEntrypoint("codex", backend);
        assert.equal(payload.ok, true, "a good payload passes through");
        assert.equal(payload.plan, "Max", "the backend's own fields are untouched");
        assert.equal(payload.provider, "codex", "an unstamped backend payload is stamped by the wrapper");
    }

    {
        // The stamp must not overwrite what a backend already said: the backend is
        // the authority on its own identity, and a wrapper that overwrote it would
        // re-introduce attribution by argument.
        const backend = fakeBackend("stamped", 'echo \'{"ok":false,"provider":"claude","error":"nope"}\'');
        const payload = runEntrypoint("codex", backend);
        assert.equal(payload.provider, "claude", "an existing stamp is preserved, never overwritten");
        assert.notEqual(payload.provider, "codex",
            "so the widget rejects it as another provider's payload, which is the point");
    }
} finally {
    fs.rmSync(tmp, { recursive: true, force: true });
}

// The backend-not-found branch cannot be reached with the repo's own backend
// present, so it is pinned at the source: every payload cmd_ai_usage emits goes
// through the one stamping helper.
const helperSource = fs.readFileSync(path.join(repoRoot, "bin", "vshell-helper"), "utf8");
// Comment lines blanked, same reason as everywhere else in this batch: a comment
// mentioning `print(` or the stamping call is prose, and counting it either hides
// an unstamped path or fails a harmless edit.
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

// --- the backend script's own emissions -------------------------------------
//
// The wrapper stamps what it emits and fills in a stamp the backend omitted, so
// a missing stamp in bin/vshell-ai-usage would not reach the widget — but it
// would silently make the wrapper the source of a provider identity the backend
// meant to state itself. Every payload the backend builds has to carry the key.
//
// Scanned per payload OBJECT, not per jq invocation: the main emission is ONE jq
// program holding TWO payload objects — the no-live-account failure and the
// success — so a per-invocation scan was satisfied by either sibling's key while
// the other went unstamped, and the success object is the everyday path.

const backend = fs.readFileSync(path.join(repoRoot, "bin", "vshell-ai-usage"), "utf8");

// Every brace-balanced object literal, paired with its OWN level: the text at
// this object's depth, with every nested object left out entirely. Computed
// during the walk rather than by stripping nested braces afterwards — one
// regex pass removed only the INNERMOST objects, so a key one level down
// survived into the parent's own text whenever a deeper sibling existed, and a
// nested stamp then counted as the payload's own.
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
    // The shape a single strip pass got wrong: the stamp one level down survives
    // into the parent whenever the nested object has an object of its own.
    const deeper = objectLiterals("{ok:true, a:{provider:$p, b:{x:1}}}");
    assert.ok(deeper.some(o => /ok:true/.test(o.own) && !/provider/.test(o.own)),
        "a nested stamp must not count as the payload's own even when a deeper object sits " +
        "beside it — that let the scan pass after a top-level payload LOST its stamp");
}

// The programs that BUILD payloads: `jq -n` constructs an object from nothing
// and its output is printed, while the `jq -c` calls normalise one account from
// stdin — account objects carry `ok` too and are not payloads.
//
// The program text is delimited by the single quotes the script uses throughout
// (it cannot contain a literal quote, as the script says of itself). That is a
// convention, so it is ENFORCED rather than assumed: a jq invocation whose
// program does not open with a single quote fails here. Searching forward for
// the next quote instead was fail-open — a double-quoted unstamped emission read
// the NEXT program's text and was vouched for by a stamped sibling.
function jqBuildPrograms(text) {
    const out = [];
    const at = /\bjq -n[a-z]*\b/g;
    let hit;
    while ((hit = at.exec(text)) !== null) {
        const rest = text.slice(hit.index + hit[0].length);
        // Options may precede the program, but it stays inside this one logical
        // command: only whitespace, line continuations and --arg/--argjson pairs.
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

// Comment lines are blanked first: this file documents its payload shape in a
// worked example, which is prose, not an emission.
const backendCode = backend.split("\n").map(l => (/^\s*#/.test(l) ? "" : l)).join("\n");

// A payload is what the widget parses: the object carrying `ok`. Both jq's bare
// keys and JSON's quoted ones, so a payload written any other way is covered too.
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
// One program holds two of them — the no-live-account failure and the success —
// which is exactly the pair a per-invocation scan let cover for each other.
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
