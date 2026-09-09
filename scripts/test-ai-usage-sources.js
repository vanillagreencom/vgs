#!/usr/bin/env node

// Drive `vshell ai-usage` against an isolated HOME and a stub AI Gateway: the credential and
// config-directory store, and the provider that reads it. These cases run the real helper, so what
// they assert about is what the widget's setup page talks to.
//
// Every case builds its own HOME and tears it down, so any one of them runs alone.
//
// An API key must never reach argv, where every process on the machine can read it out of /proc,
// and must never come back out of the helper. Both are established by running it, not by reading
// its source.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const http = require("node:http");
const { spawnSync, spawn } = require("node:child_process");

const repoRoot = path.join(__dirname, "..");
const VSHELL = path.join(repoRoot, "bin", "vshell");
const LOGIC = path.join(repoRoot, "config", "vshell", "plugins", "aiUsage", "AiUsageLogic.qml");
const MODULE = path.join(repoRoot, "bin", "vshell_ai_usage.py");

const STORE = path.join(".local", "state", "vshell", "ai-usage", "sources.json");

// One temporary HOME per case. The gateway key is cleared from the environment in every run so no
// case can reach the real API, and re-supplied deliberately where a case wants one.
// Asynchronous so a case that awaits a stub gateway finishes BEFORE the home is torn down:
// returning the promise from a synchronous `finally` deleted the stored key out from under the
// child, which then found no credential and made no request at all.
async function withHome(fn) {
    const home = fs.mkdtempSync(path.join(os.tmpdir(), "vgs-ai-sources-"));
    try {
        return await fn({
            home: home,
            storePath: path.join(home, STORE),
            run(args, options) {
                const opts = options || {};
                const env = Object.assign({}, process.env, { HOME: home }, opts.env || {});
                delete env.AI_GATEWAY_API_KEY;
                delete env.VERCEL_OIDC_TOKEN;
                for (const name of Object.keys(opts.env || {}))
                    env[name] = opts.env[name];
                const r = spawnSync(VSHELL, ["ai-usage"].concat(args), {
                    encoding: "utf8", env: env, input: opts.stdin
                });
                assert.equal(r.status, 0,
                    `vshell ai-usage ${args.join(" ")} exited ${r.status}: ${r.stderr}`);
                try {
                    return JSON.parse((r.stdout || "").trim());
                } catch (e) {
                    return assert.fail(
                        `vshell ai-usage ${args.join(" ")} did not emit JSON: ${JSON.stringify(r.stdout)}`);
                }
            }
        });
    } finally {
        fs.rmSync(home, { recursive: true, force: true });
    }
}

// A stub gateway. Records what it was sent so a case can assert on the request, and answers from a
// table of routes so a case can assert on what the helper made of the reply.
//
// The helper is run through spawn(), not spawnSync(): this server answers on THIS process's event
// loop, and a synchronous spawn blocks that loop, so the request would never be served and the
// child would sit there until its own timeout.
async function withGateway(routes, fn) {
    const seen = [];
    const server = http.createServer((req, res) => {
        const url = new URL(req.url, "http://stub");
        seen.push({ path: url.pathname, query: Object.fromEntries(url.searchParams),
                    auth: req.headers.authorization || "" });
        const answer = routes[url.pathname];
        if (!answer) {
            // The documented answer for a key with no budget configured.
            res.writeHead(404, { "Content-Type": "application/json" });
            res.end(JSON.stringify({ error: "Quota not found" }));
            return;
        }
        res.writeHead(answer.status || 200, { "Content-Type": "application/json" });
        res.end(JSON.stringify(answer.body));
    });
    await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
    try {
        return await fn(`http://127.0.0.1:${server.address().port}`, seen);
    } finally {
        await new Promise(resolve => server.close(resolve));
    }
}

// The asynchronous twin of ctx.run, for the cases that need this process's loop to keep turning.
function runAsync(home, args, extraEnv) {
    const env = Object.assign({}, process.env, { HOME: home }, extraEnv || {});
    delete env.AI_GATEWAY_API_KEY;
    delete env.VERCEL_OIDC_TOKEN;
    for (const name of Object.keys(extraEnv || {}))
        env[name] = extraEnv[name];
    return new Promise((resolve, reject) => {
        const child = spawn(VSHELL, ["ai-usage"].concat(args), { env: env });
        let out = "";
        let err = "";
        child.stdout.on("data", d => { out += d; });
        child.stderr.on("data", d => { err += d; });
        child.on("error", reject);
        child.on("close", code => {
            if (code !== 0)
                return reject(new Error(`vshell ai-usage ${args.join(" ")} exited ${code}: ${err}`));
            try {
                resolve(JSON.parse(out.trim()));
            } catch (e) {
                reject(new Error(`vshell ai-usage ${args.join(" ")} did not emit JSON: ${out}`));
            }
        });
    });
}

const CREDITS = { status: 200, body: { balance: "95.50", total_used: "4.50" } };

test("the helper's provider list and the widget's catalog are the same set", () => {
    const logic = fs.readFileSync(LOGIC, "utf8");
    const order = logic.match(/function providerOrder\(\)\s*\{\s*return \[([^\]]*)\]/);
    assert.ok(order, "AiUsageLogic must declare its provider order as a literal list");
    const widget = order[1].split(",").map(s => s.trim().replace(/^"|"$/g, "")).filter(Boolean);

    const module = fs.readFileSync(MODULE, "utf8");
    const declared = module.match(/^PROVIDERS = \(([^)]*)\)/m);
    assert.ok(declared, "the helper module must declare PROVIDERS as a literal tuple");
    const backend = declared[1].split(",").map(s => s.trim().replace(/^"|"$/g, "")).filter(Boolean);

    assert.deepEqual(backend.slice().sort(), widget.slice().sort(),
        "a provider the widget lists but the helper does not know answers 'unknown provider' on " +
        "every poll, and one the helper knows but the widget does not is unreachable — the two " +
        "lists are one contract");
});

test("a key is taken from stdin, and there is no argv route to offer one instead", () => withHome(ctx => {
    const noStdin = ctx.run(["set-key", "vercel", "--label", "Empty"], { stdin: "" });
    assert.equal(noStdin.ok, false,
        "with nothing on stdin there is no key, which is what proves stdin is where it comes from");
    assert.match(noStdin.error, /stdin/, "and the reply says so");

    const viaArgv = ctx.run(["set-key", "vercel", "--key", "vck_on_argv", "--label", "Argv"],
                            { stdin: "\n" });
    assert.equal(viaArgv.ok, false,
        "there is no --key argument to pass one on: argv is readable from /proc by every process " +
        "on the machine for as long as the helper runs");
    // The REJECTION has to be of the argument itself. "no key on stdin" is the answer a helper
    // that happily accepted --key would also give when stdin was empty, so it establishes nothing.
    assert.match(viaArgv.error, /could not read the arguments/,
        "and it is refused as an unrecognised ARGUMENT, not merely left unsuccessful");
    assert.equal(fs.existsSync(ctx.storePath), false,
        "and nothing was stored from it either — a rejected argument must not be a stored key");

    const viaStdin = ctx.run(["set-key", "vercel", "--label", "Stdin"], { stdin: "vck_from_stdin\n" });
    assert.equal(viaStdin.ok, true, "while the same key on stdin is accepted");
    assert.match(fs.readFileSync(ctx.storePath, "utf8"), /vck_from_stdin/,
        "and really is what was stored, or every poll would fail with a key the user did supply");
    assert.equal(fs.readFileSync(ctx.storePath, "utf8").includes("vck_on_argv"), false,
        "with no trace of the one argv offered");
}));

test("the store is 0600 whatever the umask, and no key comes back out of the helper", () => withHome(ctx => {
    // A permissive umask is the case that matters: a file created at it is world-readable, and a
    // key is on disk from the moment it is written.
    const saved = ctx.run(["set-key", "vercel", "--label", "Test Team", "--key-id", "abc123"],
                          { stdin: "vck_secret_value\n", env: { UMASK: "" } });
    assert.equal(saved.ok, true, `saving a key must succeed: ${JSON.stringify(saved)}`);
    assert.equal(saved.id, "test-team", "whose id is derived from the label, never from the key");
    assert.equal(JSON.stringify(saved).includes("vck_secret_value"), false,
        "and the reply carries no key");

    assert.equal(fs.statSync(ctx.storePath).mode & 0o777, 0o600,
        "the store holds a secret, so it is 0600 — it is under ~/.local/state and not under " +
        "~/.config for the same reason: operators symlink that into dotfiles repositories");
    assert.equal(fs.statSync(path.dirname(ctx.storePath)).mode & 0o777, 0o700,
        "and so is the directory holding it");

    const sources = ctx.run(["sources", "vercel"]);
    assert.equal(sources.takesKey, true, "AI Gateway is configured with a key, not a login");
    assert.deepEqual(sources.accounts,
        [{ id: "test-team", label: "Test Team", source: "stored", hasKeyId: true }],
        "the setup page is told the source and the label, and nothing else about the key");
    assert.equal(JSON.stringify(sources).includes("vck_secret_value"), false,
        "a key must never come back out of the helper — the page has no use for one and no way " +
        "to hold it safely");
}));

// The window between creating the file and narrowing its mode has no observable surface: by the
// time a test could stat it, the write has finished. This is pinned in comment-stripped source for
// that reason, and the mode itself is established above by running the helper.
test("the descriptor the key is written through is narrowed before the write", () => {
    const code = fs.readFileSync(MODULE, "utf8")
        .split("\n").map(l => (/^\s*#/.test(l) ? "" : l)).join("\n");
    const narrowedAt = code.indexOf("os.fchmod(fd, 0o600)");
    // indexOf answers -1 for absent, which compares BELOW every real offset: an ordering
    // assertion alone passes when the call it orders is gone.
    assert.notEqual(narrowedAt, -1,
        "the mode is set on the descriptor the key is written through, not only on the path " +
        "afterwards: a file created at the umask is world-readable until the chmod lands");
    assert.ok(narrowedAt < code.indexOf("json.dump("), "and narrowed BEFORE the key goes through it");
});

test("two keys with the same name are two accounts", () => withHome(ctx => {
    assert.equal(ctx.run(["set-key", "vercel", "--label", "Team"], { stdin: "vck_one\n" }).id, "team");
    assert.equal(ctx.run(["set-key", "vercel", "--label", "Team"], { stdin: "vck_two\n" }).id, "team-2",
        "a reused label must not overwrite the entry that already has it: a person running two " +
        "teams names both of them after the same thing");
    assert.equal(ctx.run(["sources", "vercel"]).accounts.length, 2,
        "so both are stored, and both become account cards");
}));

test("only a key VGS stores can be removed through VGS", () => withHome(ctx => {
    ctx.run(["set-key", "vercel", "--label", "Team"], { stdin: "vck_one\n" });
    assert.equal(ctx.run(["clear-key", "vercel", "team"]).ok, true, "a stored key is removable");
    const gone = ctx.run(["clear-key", "vercel", "team"]);
    assert.equal(gone.ok, false,
        "removing it twice must not report a second removal: the page would say the key is gone " +
        "while the helper went on reading whatever else answers for it");
    assert.equal(ctx.run(["clear-key", "vercel", "env"], { env: { AI_GATEWAY_API_KEY: "vck_env" } }).ok,
        false, "and a key provisioned outside VGS is not VGS's to delete either");
    assert.equal(ctx.run(["clear-key", "claude", "anything"]).ok, false,
        "nor is a key claimed for a provider that is found by its login instead");
}));

test("an extra config directory is validated before it is stored", () => withHome(ctx => {
    assert.equal(ctx.run(["add-dir", "claude", path.join(ctx.home, "nope")]).ok, false,
        "a path that is not a directory is refused where the user can still see the field they " +
        "typed it into, rather than silently producing no account");
    assert.equal(ctx.run(["add-dir", "vercel", ctx.home]).ok, false,
        "and a provider with no config directories does not take one");

    const alt = path.join(ctx.home, ".claude-work");
    fs.mkdirSync(alt);
    assert.equal(ctx.run(["add-dir", "claude", alt]).ok, true);
    const listed = ctx.run(["sources", "claude"]).dirs.filter(d => d.managed === "extra");
    assert.deepEqual(listed.map(d => d.path), [alt],
        "and it is reported as the user's, so it can be removed");
    assert.equal(listed[0].usable, false,
        "a directory holding no login says so rather than being dropped: 'I added it and nothing " +
        "happened' is the only other thing the page could show");

    assert.equal(ctx.run(["remove-dir", "claude", alt]).ok, true);
    assert.deepEqual(ctx.run(["sources", "claude"]).dirs.filter(d => d.managed === "extra"), []);
    assert.equal(ctx.run(["remove-dir", "claude", alt]).ok, false,
        "and removing what is not there is not a removal");
}));

test("a provider with no key answers configured:false, stamped, rather than as a fault", () => withHome(ctx => {
    const payload = ctx.run(["vercel"]);
    assert.equal(payload.ok, false, "there is no usage to report");
    assert.equal(payload.configured, false,
        "but the reason is that nobody set it up, which is what keeps it off the bar instead of " +
        "showing a permanent error mark for a provider the user never asked for");
    assert.equal(payload.provider, "vercel", "and it is stamped, or the widget discards it");
    assert.deepEqual(payload.accounts, [], "with no account to render as broken");
}));

test("the gateway is called with the stored key, and its credits become one account card", () => withHome(ctx => {
    ctx.run(["set-key", "vercel", "--label", "Personal"], { stdin: "vck_live_key\n" });
    return withGateway({ "/credits": CREDITS }, async (base, seen) => {
        const payload = await runAsync(ctx.home, ["vercel"], { AI_GATEWAY_BASE: base });

        assert.deepEqual(seen.map(r => r.path), ["/credits"],
            "a key with no key ID asks only for the balance: the quotas endpoint is addressed by " +
            "an ID this one does not carry");
        assert.equal(seen[0].auth, "Bearer vck_live_key",
            "and the key reaches exactly one place — the Authorization header");

        assert.equal(payload.ok, true);
        assert.equal(payload.provider, "vercel", "stamped, or the widget discards it");
        assert.equal(payload.accounts.length, 1);
        const account = payload.accounts[0];
        assert.equal(account.label, "Personal", "labelled by what the user called the key");
        assert.equal(account.plan, "$95.50 left", "with the balance where a plan name would be");
        assert.deepEqual(account.spend,
            { label: "Credits", pct: 5, used: 4.5, limit: 100, currency: "USD",
              detail: "$95.50 left of $100.00" },
            "and the pool a prepaid balance is measured against is everything ever put in it — " +
            "spent plus left. Lifetime spend on its own has no denominator to be a percentage of");
        assert.equal(JSON.stringify(payload).includes("vck_live_key"), false,
            "and no payload carries the key");
    });
}));

test("a budget on the key becomes the tighter lane, and the pool keeps its own row", () => withHome(ctx => {
    ctx.run(["set-key", "vercel", "--label", "Team", "--key-id", "key_42"], { stdin: "vck_k\n" });
    const quota = { status: 200, body: { quotaEntityId: "api_key_id_key_42", apiKeyName: "prod",
                                         limitAmount: 10, currentSpend: 9, refreshPeriod: "monthly",
                                         active: true } };
    return withGateway({ "/credits": CREDITS, "/quotas": quota }, async (base, seen) => {
        const account = (await runAsync(ctx.home, ["vercel"], { AI_GATEWAY_BASE: base })).accounts[0];
        const quotaCall = seen.find(r => r.path === "/quotas");
        assert.ok(quotaCall, "a key with an ID has its budget looked up");
        assert.equal(quotaCall.query.quotaEntityId, "api_key_id_key_42",
            "addressed by the ID the user supplied, prefixed as the API requires");

        assert.equal(account.spend.label, "Budget (monthly)",
            "a budget is the tighter, more actionable limit, so it takes the spend lane");
        assert.equal(account.spend.pct, 90);
        assert.deepEqual(account.models.map(m => m.label), ["Credits"],
            "and the prepaid pool becomes a second row rather than vanishing");
        assert.equal(account.class, "critical",
            "with severity read from the tightest lane, or a card at 90% of budget reads as low");
    });
}));

test("a key with no budget is an absence, not a fault", () => withHome(ctx => {
    ctx.run(["set-key", "vercel", "--label", "Team", "--key-id", "key_none"], { stdin: "vck_k\n" });
    // The documented answer for a key with no budget configured is 404, which the stub gives for
    // any route it was not handed.
    return withGateway({ "/credits": CREDITS }, async (base) => {
        const account = (await runAsync(ctx.home, ["vercel"], { AI_GATEWAY_BASE: base })).accounts[0];
        assert.equal(account.ok, true, "no budget is an absence, not a fault");
        assert.equal(account.spend.label, "Credits", "so the pool stays the lane");
        assert.deepEqual(account.models, [], "and nothing invents a budget row for it");
    });
}));

// Its OWN home. These two cases shared one, and the refused-key half sat behind a `return` that
// made it unreachable — a suite that never ran the 401 path while claiming to. Made reachable, it
// failed, because a successful read caches the account (vshell_ai_usage.py:402) and the refusal
// was answered from that cache without a request being made. Sharing a home would test the cache,
// not the refusal.
test("a refused key is a fault of a configured provider", () => withHome(ctx => {
    ctx.run(["set-key", "vercel", "--label", "Team", "--key-id", "key_bad"], { stdin: "vck_k\n" });
    return withGateway({ "/credits": { status: 401, body: { error: "Authentication failed" } } },
                       async (base) => {
        const payload = await runAsync(ctx.home, ["vercel"], { AI_GATEWAY_BASE: base });
        assert.equal(payload.ok, false, "a refused key IS a fault");
        assert.equal(payload.configured, true,
            "and it is a fault of a CONFIGURED provider, which is what keeps its slot on the bar " +
            "rather than treating a bad key as an absent one");
        assert.match(payload.accounts[0].error, /Authentication failed/,
            "reported in the gateway's own words");
    });
}));

test("an unknown provider and a malformed subcommand are answered, not crashed", () => withHome(ctx => {
    const unknown = ctx.run(["sources", "gemini"]);
    assert.equal(unknown.ok, false, "an unknown provider is reported");
    assert.ok(unknown.error.includes("gemini"), "by name");
    for (const args of [["clear-key", "vercel"], ["add-dir", "claude"], ["remove-dir", "claude"]]) {
        assert.equal(ctx.run(args).ok, false,
            `${args.join(" ")} without its argument is answered, not crashed`);
    }
}));
