#!/usr/bin/env node

// Test remote-desktop state ordering and unknown-state handling using the shipped decisions.
// Inspect service wiring without starting a host that captures the user's screen.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.join(__dirname, "..");
const WIDGET = path.join(
    repoRoot, "config", "vshell", "plugins", "remoteDesktop", "RemoteDesktopWidget.qml"
);
const SERVICE = path.join(
    repoRoot, "quickshell", "vshell", "Services", "RemoteDesktopService.qml"
);

const widgetSource = fs.readFileSync(WIDGET, "utf8");
const serviceSource = fs.readFileSync(SERVICE, "utf8");

// Blank comments while preserving offsets before source checks. Keep raw text only for
// marker extraction because the region delimiters are comments.
function stripComments(src) {
    let out = "";
    let i = 0;
    while (i < src.length) {
        const ch = src[i];
        const next = src[i + 1];

        if (ch === '"' || ch === "'" || ch === "`") {
            const quote = ch;
            out += ch;
            i += 1;
            while (i < src.length) {
                if (src[i] === "\\") {
                    out += src.slice(i, i + 2);
                    i += 2;
                    continue;
                }
                out += src[i];
                i += 1;
                if (src[i - 1] === quote)
                    break;
            }
            continue;
        }
        if (ch === "/" && next === "/") {
            while (i < src.length && src[i] !== "\n") {
                out += " ";
                i += 1;
            }
            continue;
        }
        if (ch === "/" && next === "*") {
            while (i < src.length && !(src[i] === "*" && src[i + 1] === "/")) {
                out += src[i] === "\n" ? "\n" : " ";
                i += 1;
            }
            out += "  ";
            i += 2;
            continue;
        }
        out += ch;
        i += 1;
    }
    return out;
}

test("the comment stripper blanks comments, keeps string interiors and preserves offsets", () => {
    const sample = 'a(); // function ghost() "On"\nb("// not a comment"); /* gone */ c();';
    const stripped = stripComments(sample);
    assert.ok(!stripped.includes("ghost"), "a line comment must not survive stripping");
    assert.ok(!stripped.includes('"On"'), "quoted words inside comments must not survive");
    assert.ok(!stripped.includes("gone"), "a block comment must not survive stripping");
    assert.ok(stripped.includes('"// not a comment"'), "a // inside a string literal is not a comment");
    assert.equal(stripped.length, sample.length, "stripping must preserve offsets");
    assert.equal(
        (stripped.match(/\n/g) || []).length,
        (sample.match(/\n/g) || []).length,
        "stripping must preserve line structure"
    );
});

// Read empty double-quoted literals too; skipping them shifts later quote pairing and loses values.
function quotedLiterals(text) {
    const out = [];
    for (let i = 0; i < text.length; i++) {
        if (text[i] !== '"')
            continue;
        let value = "";
        let j = i + 1;
        while (j < text.length && text[j] !== '"') {
            if (text[j] === "\\") {
                value += text[j + 1] || "";
                j += 2;
                continue;
            }
            value += text[j];
            j += 1;
        }
        out.push(value);
        i = j;
    }
    return out;
}

test("quotedLiterals keeps empty literals in pairing", () => {
    assert.deepEqual(
        quotedLiterals('f(tr("msg"), "", "category")'),
        ["msg", "", "category"],
        "an empty literal must not shift the pairing of the ones after it"
    );
});

const widgetCode = stripComments(widgetSource);
const serviceCode = stripComments(serviceSource);
test("the widget carries comments, so stripping is exercised", () => {
    assert.ok(
        widgetSource.length > widgetCode.replace(/ +$/gm, "").length,
        "the widget should carry comments; stripping is what keeps them out of these assertions"
    );
});

const marked = widgetSource.match(/\/\/ BEGIN STATE DECISION\n([\s\S]*?)\/\/ END STATE DECISION/);
assert.ok(marked, "RemoteDesktopWidget.qml must carry the STATE DECISION markers");
const {
    visualStateFor, stateColorTokenFor, pillIconUsesStateColor,
    tooltipFor, sessionDetailFrom, upSubtitleFor
} = new Function(
    `${marked[1]}\nreturn { visualStateFor, stateColorTokenFor, pillIconUsesStateColor,` +
    ` tooltipFor, sessionDetailFrom, upSubtitleFor };`
)();

const sessionMarked = serviceSource.match(/\/\/ BEGIN SESSION DECISION\n([\s\S]*?)\/\/ END SESSION DECISION/);
assert.ok(sessionMarked, "RemoteDesktopService.qml must carry the SESSION DECISION markers");
const { sessionApplyDecision } = new Function(`${sessionMarked[1]}\nreturn { sessionApplyDecision };`)();

const eventMarked = serviceSource.match(/\/\/ BEGIN EVENT DECISION\n([\s\S]*?)\/\/ END EVENT DECISION/);
assert.ok(eventMarked, "RemoteDesktopService.qml must carry the EVENT DECISION markers");
const { countInvalidatingEvent } = new Function(
    `${eventMarked[1]}\nreturn { countInvalidatingEvent };`
)();

function host(overrides) {
    return Object.assign({
        streaming: false,
        sessionKnown: true,
        statusKnown: true,
        installed: true,
        watchLive: true,
        running: false
    }, overrides || {});
}

test("visualStateFor ranks capture over uncertainty, unknown over stale, and idle over unread sessions", () => {
    for (const [facts, expected, why] of [
        [{}, "off", "installed, known, watched, not running"],
        [{ running: true }, "listening", "up with nobody connected"],
        [{ running: true, streaming: true }, "streaming", "a connected client is its own state, never folded into 'up'"],
        [{ installed: false }, "unavailable", "a known-absent Sunshine is unavailable"],
        [{ running: true, watchLive: false }, "stale", "a dead event watch means the values may be out of date"],
        [{ statusKnown: false, installed: false }, "unknown",
            "no answer yet must not render as 'not installed' — that is a default, not a fact"],
        [{ statusKnown: false, installed: true, running: true }, "unknown",
            "a failed probe must not keep rendering the previous host state as current"],
        [{ statusKnown: false, watchLive: false }, "unknown", "unknown outranks stale: there is no previous answer to call stale"],
        [{ streaming: true, statusKnown: false }, "streaming", "a possible live capture must outrank an unknown status"],
        [{ streaming: true, watchLive: false }, "streaming", "a possible live capture must outrank a dead watch"],
        [{ streaming: true, statusKnown: false, watchLive: false }, "streaming", "a possible live capture must outrank both"],
        [{ streaming: true, installed: false }, "streaming", "a possible live capture must outrank a known-absent host"],
        [{ streaming: true, sessionKnown: false, watchLive: false }, "streaming-unconfirmed",
            "a dead watch must not let a plain LIVE stand on its last message"],
        [{ streaming: true, sessionKnown: false, watchLive: false, statusKnown: false }, "streaming-unconfirmed",
            "losing the host status too does not make a possible capture idle"],
        [{ streaming: true, sessionKnown: false, watchLive: false, statusKnown: false, installed: false }, "streaming-unconfirmed",
            "an unconfirmed capture must never fall through to unknown, stale, listening, off or unavailable"],
        [{ streaming: true, sessionKnown: true, watchLive: false }, "streaming", "a session the status read still confirms stays plainly LIVE"],
        [{ running: true, sessionKnown: false }, "listening-unconfirmed",
            "a host whose sessions cannot be read must not claim nobody is watching"],
        [{ running: true, sessionKnown: true }, "listening", "a confirmed idle host still reads plainly On"],
        [{ running: false, sessionKnown: false }, "off", "a host that is down has no sessions to be unsure about"]
    ]) {
        assert.equal(visualStateFor(host(facts)), expected, `${JSON.stringify(facts)}: ${why}`);
    }
});

// An unreadable journal's default active=false cannot establish that capture stopped.
test("sessionApplyDecision lets only a literally readable journal apply its active flag", () => {
    for (const [session, expected, why] of [
        [{ readable: false, active: false, error: "No journal files were found." },
            { known: false, applyActive: false, reason: "No journal files were found." },
            "an unreadable journal leaves the session unknown, does not apply active, and passes the reason to the caller"],
        [{}, { known: false, applyActive: false, reason: "" }, "a missing session block decides nothing"],
        [null, { known: false, applyActive: false, reason: "" }, "no session block decides nothing"],
        [{ readable: "yes", active: true }, { known: false, applyActive: false, reason: "" },
            "only a literal true is readable; a truthy value is not an answer"],
        [{ readable: true, active: true, error: "" }, { known: true, applyActive: true, reason: "" },
            "a readable journal is an answer and its active is the authority that may clear LIVE"],
        [{ readable: true, active: false }, { known: true, applyActive: true, reason: "" },
            "a readable journal saying nobody is connected DOES clear it — that is the one authority"]
    ]) {
        assert.deepEqual(sessionApplyDecision(session), expected, `${JSON.stringify(session)}: ${why}`);
    }
});

// Apply the decision before writing session fields; an inconclusive path must not overwrite them.
test("_applyStatus guards the session assignment on the decision and moves an unreadable block to unknown", () => {
    const applyBody = qmlFunctionBody("_applyStatus");
    assert.ok(
        applyBody.includes("root.sessionApplyDecision(session)"),
        "_applyStatus must route the session block through the decision"
    );
    // Assert landmark presence before order because indexOf=-1 can satisfy a less-than comparison.
    const guardAt = applyBody.indexOf("if (!decision.applyActive)");
    const assignAt = applyBody.indexOf("root.streaming = session.active === true");
    assert.ok(guardAt >= 0, "_applyStatus must guard the session assignment on the decision");
    assert.ok(assignAt >= 0, "_applyStatus must still be the site that applies the session");
    assert.ok(guardAt < assignAt, "the guard must come before the assignment it guards");
    assert.ok(
        applyBody.includes("root._markSessionUnknown(decision.reason"),
        "an unreadable block moves the session to unknown, not to idle"
    );
});

// Require distinct presentation for capture and listening states.
test("stateColorTokenFor gives capture the alarm colour and idle a distinct one", () => {
    for (const [state, expected, why] of [
        ["streaming", "error", "a live capture is an alarm colour"],
        ["streaming-unconfirmed", "error",
            "an unconfirmed capture keeps the alarm colour; softening it trades a possible live capture for a tidier bar"],
        ["listening", "primary", "an idle host is not an alarm — the two states this widget exists to distinguish must not share a colour"],
        ["listening-unconfirmed", "warning", "an unread session is a warning"],
        ["unknown", "warning", "no answer is a warning"],
        ["stale", "warning", "a dead watch is a warning"],
        ["off", "surfaceVariantText", "a stopped host is muted"],
        ["unavailable", "surfaceVariantText", "an absent host is muted"]
    ]) {
        assert.equal(stateColorTokenFor(state), expected, `${state}: ${why}`);
    }
});

// Icon-only pills need a color distinction because they have no text to identify a live capture.
test("pillIconUsesStateColor colours the glyph for every alarm or uncertain state and no idle one", () => {
    for (const [state, expected, why] of [
        ["streaming", true, "the pill glyph must carry the alarm colour, or LIVE is a shape difference only"],
        ["streaming-unconfirmed", true, "an unconfirmed capture shouts too"],
        ["unknown", true, "uncertainty shows"],
        ["stale", true, "uncertainty shows"],
        ["listening-unconfirmed", true, "uncertainty shows"],
        ["listening", false, "an idle host does not shout"],
        ["off", false, "a stopped host does not shout"],
        ["unavailable", false, "an absent host does not shout"]
    ]) {
        assert.equal(pillIconUsesStateColor(state), expected, `${state}: ${why}`);
    }
});

// Require bindings to consume the decided tokens.
test("stateColor and both pill glyph colours derive from the token table", () => {
    assert.ok(
        /readonly property color stateColor: \{\s*switch \(root\.stateColorTokenFor\(root\.visualState\)\)/.test(widgetCode),
        "stateColor must be derived from the token table rather than a second switch"
    );
    assert.ok(
        widgetCode.includes("readonly property color pillIconColor: root.pillIconUsesStateColor(root.visualState) ? root.stateColor : Theme.widgetIconColor"),
        "the pill glyph colour must be derived from the token table"
    );
    assert.equal(
        (widgetCode.match(/color: root\.pillIconColor/g) || []).length,
        2,
        "both the horizontal and vertical pill glyphs must take it — a bar on the left edge is still a bar"
    );
});

function qmlFunctionBody(name) {
    return functionBodyIn(serviceSource, name, "RemoteDesktopService.qml");
}

function widgetFunctionBody(name) {
    return functionBodyIn(widgetSource, name, "RemoteDesktopWidget.qml");
}

// Read a unique function declaration and balanced body. Ambiguous names or indentation heuristics
// can select unrelated code and give source assertions false evidence.
function functionBodyIn(src, name, where) {
    // Strip comments in the shared reader so callers cannot omit that step.
    const code = stripComments(src);
    const declaration = new RegExp(`(^|[^\\w$.])function\\s+${name}\\s*\\(`, "g");
    const found = [...code.matchAll(declaration)];
    assert.equal(
        found.length, 1,
        `${where} should declare exactly one ${name}() -- ${found.length} found, and an ambiguous name means this reads whichever came first`
    );

    const start = found[0].index + found[0][1].length;
    const open = code.indexOf("{", start);
    assert.ok(open > start, `${name}() should have a body`);

    let depth = 0;
    let inString = "";
    for (let i = open; i < code.length; i++) {
        const ch = code[i];
        if (inString) {
            if (ch === "\\")
                i += 1;
            else if (ch === inString)
                inString = "";
            continue;
        }
        if (ch === '"' || ch === "'" || ch === "`") {
            inString = ch;
            continue;
        }
        if (ch === "{")
            depth += 1;
        else if (ch === "}") {
            depth -= 1;
            if (depth === 0)
                return code.slice(start, i + 1);
        }
    }
    assert.fail(`${name}() is not closed in ${where}`);
}

// Test missing, ambiguous, unclosed, and misleading source shapes before deriving state lists.

test("the function reader refuses absent, ambiguous, unclosed and comment-shadowed names and string braces", () => {
    assert.throws(
        () => widgetFunctionBody("thisFunctionDoesNotExist"),
        "the reader must fail on a name that is absent, not return an empty body"
    );

    assert.throws(
        () => functionBodyIn("function twice() { }\nfunction twice() { }", "twice", "a sample"),
        "the reader must refuse an ambiguous name rather than take whichever came first"
    );

    assert.throws(
        () => functionBodyIn("function open() {\n    return 1;", "open", "a sample"),
        "an unclosed body must fail rather than swallow the rest of the file"
    );

    assert.equal(
        functionBodyIn('function only() {\n    const s = "}";\n    return 1;\n}', "only", "a sample"),
        'function only() {\n    const s = "}";\n    return 1;\n}',
        "a brace inside a string literal must not close the body early"
    );

    assert.ok(
        functionBodyIn(
            "function targetLonger() { return 1; }\nfunction target() { return 2; }",
            "target", "a sample"
        ).includes("return 2"),
        "`target` must not resolve to `targetLonger`"
    );

    // A comment naming the function must not become its declaration landmark.
    {
        const shadowed = [
            "// call function target( from here",
            "function target() {",
            '    return "real body";',
            "}"
        ].join("\n");

        // Require the misleading fixture to fool naive first-match lookup so the control remains adversarial.
        const naive = shadowed.slice(shadowed.indexOf("function target("));
        assert.ok(
            naive.startsWith("function target( from here"),
            "the shadowing sample must fool a first-match reader, or it proves nothing about the fix"
        );

        const body = functionBodyIn(shadowed, "target", "a sample");
        assert.ok(body.includes("real body"), "the reader must locate the function, not a comment naming it");
        assert.ok(!body.includes("from here"), "and must not begin inside that comment");
    }
});

// A disconnect ends one client session. Only an authoritative count can establish that capture stopped.
test("_handleWatchToken sets streaming on connect, never clears it, and schedules the resync", () => {
    const tokenBody = qmlFunctionBody("_handleWatchToken");
    assert.ok(
        /root\.streaming = true/.test(tokenBody),
        "a connect event should set the indicator immediately"
    );
    assert.ok(
        !/root\.streaming = false/.test(tokenBody),
        "no watch event may clear `streaming`: one disconnect of several would hide a live capture"
    );
    assert.ok(
        tokenBody.includes("resyncDebounce.restart()"),
        "every event must schedule the authoritative resync that can clear it"
    );
});

test("exactly one site clears streaming: the authoritative status apply", () => {
    const clearingWriters = serviceCode
        .split("\n")
        .map((line, index) => ({ line: line.trim(), index }))
        .filter(entry => /^root\.streaming = (false|session\.active === true)/.test(entry.line));
    assert.equal(
        clearingWriters.length,
        1,
        "exactly one site may clear `streaming`, and it is the authoritative status apply"
    );
    assert.ok(
        qmlFunctionBody("_applyStatus").includes("root.streaming = session.active === true"),
        "the authoritative apply is what clears the indicator"
    );
});

test("_markSessionUnknown clears the session fields and never streaming", () => {
    // Watcher loss invalidates session detail but cannot establish streaming=false.
    const sessionUnknownBody = qmlFunctionBody("_markSessionUnknown");
    assert.ok(
        !/root\.streaming = /.test(sessionUnknownBody),
        "losing the watch must not decide the session ended; only the authoritative count may"
    );
    assert.ok(
        sessionUnknownBody.includes("root.sessionKnown = false"),
        "losing the watch makes the session unknown"
    );
    for (const field of ["sessionCount", "sessionCodec", "sessionBitrateBps", "sessionColorDepth", "sessionSince"]) {
        assert.ok(
            new RegExp(`root\\.${field} = `).test(sessionUnknownBody),
            `${field} describes a session nothing is confirming and must be cleared`
        );
    }
});

test("the watch-stop handler marks the session unknown and asks for a status read", () => {
    // Watch-stop handling must request an independent status read after invalidation.
    const watchStopSlice = serviceCode.slice(
        serviceCode.indexOf("root.watchLive = false;\n            watchStable.stop();")
    );
    assert.ok(
        watchStopSlice.slice(0, 1200).includes("root._markSessionUnknown("),
        "the watch-stop handler must mark the session unknown, not leave the cached values standing"
    );
    assert.ok(
        watchStopSlice.slice(0, 1600).includes("root.refresh();"),
        "losing the watch should immediately ask the independent status read"
    );
});

test("_applyStatus routes an unanswerable unit query to unknown before applying installed", () => {
    const applyBody = qmlFunctionBody("_applyStatus");
    // A failed unit query cannot establish that the host is uninstalled.
    assert.ok(
        /if \(status\.unitKnown === false \|\| status\.state === "unknown"\)/.test(applyBody),
        "_applyStatus must route an unanswerable unit query to unknown"
    );
    const unitGuardAt = applyBody.indexOf("status.unitKnown === false");
    const installedAt = applyBody.indexOf("root.installed = status.installed === true");
    assert.ok(unitGuardAt >= 0, "the unit-unknown guard must exist");
    assert.ok(installedAt >= 0, "_applyStatus must still be the site that applies `installed`");
    assert.ok(unitGuardAt < installedAt, "the guard must come before the assignment it guards");
});

test("a connect marks the count unknown once and sets streaming", () => {
    // A connect proves at least one viewer, not a current count. Mark the count unknown until resync.
    const connectBody = qmlFunctionBody("_handleWatchToken");
    assert.ok(
        connectBody.includes("root.sessionCountKnown = false"),
        "a connect must mark the count unknown; it proves a session, not a number"
    );
    assert.ok(
        (connectBody.match(/root\.sessionCountKnown = false/g) || []).length === 1,
        "one write, reached by every invalidating event — a per-branch copy is how the disconnect side got missed"
    );
    assert.ok(
        !/root\.sessionCount = 0/.test(connectBody),
        "a connect must never leave the count at 0 while setting `streaming`"
    );
    assert.ok(
        connectBody.includes("root.streaming = true"),
        "and it must still set the indicator optimistically — that half is deliberate"
    );
});

test("countInvalidatingEvent is true for client and lifecycle events only", () => {
    // Both connect and disconnect invalidate the prior client count.
    assert.equal(countInvalidatingEvent("connected"), true, "a client arrived: the number is stale");
    assert.equal(countInvalidatingEvent("disconnected"), true, "a client left: equally stale, and this was the gap");
    assert.equal(
        countInvalidatingEvent("lifecycle"), true,
        "the host starting or stopping ends every session it had, so a count from before it describes a host that is gone"
    );
    // Encoder and bitrate changes do not change client count without their own client events.
    assert.equal(
        countInvalidatingEvent("session"), false,
        "an encoder/bitrate change must not blank a count it did not affect"
    );
    assert.equal(countInvalidatingEvent(""), false, "an empty token decides nothing");
    assert.equal(countInvalidatingEvent("nonsense"), false, "an unknown token decides nothing");
});

test("the watch handler gates the count on the shared decision for every token", () => {
    const connectBody = qmlFunctionBody("_handleWatchToken");
    // Apply event invalidation outside the connect-only branch.
    assert.ok(
        connectBody.includes("if (root.countInvalidatingEvent(event))"),
        "the handler must gate the count on the shared decision, not on the connect branch"
    );
    assert.ok(
        connectBody.indexOf("if (root.countInvalidatingEvent(event))") > connectBody.indexOf('if (event === "connected")'),
        "and must reach it for every token, not only a connect"
    );
});

test("the count is known only from the authoritative read and rendered only then", () => {
    const sessionUnknownBody2 = qmlFunctionBody("_markSessionUnknown");
    assert.ok(
        sessionUnknownBody2.includes("root.sessionCountKnown = false"),
        "losing the session loses the count with it"
    );
    assert.ok(
        qmlFunctionBody("_applyStatus").includes("root.sessionCountKnown = true"),
        "only the authoritative read may declare the count known"
    );
    assert.ok(
        widgetSource.includes("RemoteDesktopService.sessionCountKnown ? String(RemoteDesktopService.sessionCount)"),
        "the Clients row must render the count only when it is known"
    );
});

test("captureFallback clears on unknown and is set only by an authoritative status", () => {
    // Unknown output state cannot support an asserted monitor-capture fallback warning.
    assert.ok(
        /root\.captureFallback = false/.test(qmlFunctionBody("_markStatusUnknown")),
        "an unknown status must clear captureFallback, not preserve the last answer"
    );
    assert.ok(
        qmlFunctionBody("_applyStatus").includes("root.captureFallback = status.captureFallback === true"),
        "and only an authoritative status may set it"
    );
});

test("the status grace timer is tagged per probe and stopped by the next one", () => {
    // Cancel or identify grace timers per probe so an older timer cannot expire a newer probe.
    assert.ok(
        /statusUnansweredTimer\.armedFor = root\._statusProbeGeneration/.test(serviceSource),
        "the grace timer must record which probe armed it"
    );
    assert.ok(
        /if \(armedFor !== root\._statusProbeGeneration\)/.test(serviceSource),
        "and must ignore a tick belonging to a superseded probe"
    );
    assert.ok(
        /root\._statusProbeGeneration\+\+/.test(serviceSource),
        "each probe start must take a new generation"
    );
    assert.ok(
        /root\._statusAnswered = false;\s*\n\s*root\._statusProbeGeneration\+\+;\s*\n[\s\S]{0,240}?statusUnansweredTimer\.stop\(\)/.test(serviceSource),
        "a starting probe should also stop any tick still armed for the previous one"
    );
});

test("_reportLifecycleFailure toasts once and lets an authoritative verdict replace a generic one", () => {
    const lifecycleBody = qmlFunctionBody("_reportLifecycleFailure");
    assert.ok(
        lifecycleBody.includes("ToastService.showError"),
        "lifecycle failures use the same surface as every other failure here"
    );
    assert.ok(
        lifecycleBody.includes("root._lifecycleReported = true"),
        "and are reported once"
    );
    assert.ok(
        /if \(root\._lifecycleReported && authoritative !== true\)/.test(lifecycleBody),
        "the helper's own verdict may replace a generic message that arrived first"
    );
});
// One reader for the lifecycle process and grace-timer regions, so every case judges the same text.
function lifecycleSlices() {
    const running = serviceSource.slice(serviceSource.indexOf("id: lifecycleProc"));
    const grace = serviceSource.slice(serviceSource.indexOf("id: lifecycleUnansweredTimer"));
    return {
        lifecycleRunningBody: running,
        lifecycleRunningSlice: running.slice(running.indexOf("onRunningChanged"), running.indexOf("onExited")),
        graceBody: grace.slice(0, grace.indexOf("id: settleTimer"))
    };
}

test("the lifecycle running handler defers the verdict to the grace timer", () => {
    // Process stop can precede output collection. Defer failure until grace allows a successful reply to arrive.
    const { lifecycleRunningSlice } = lifecycleSlices();
    assert.ok(
        !/_reportLifecycleFailure/.test(lifecycleRunningSlice),
        "the running=false handler must not report: it cannot yet know the command failed"
    );
    assert.ok(
        lifecycleRunningSlice.includes("lifecycleUnansweredTimer.restart()"),
        "it must hand the verdict to the grace timer instead"
    );
});

test("the grace timer takes the success path on a zero exit and reports a command that never exited", () => {
    // A recorded zero exit must take the success path when grace expires.
    const { graceBody } = lifecycleSlices();
    const zeroAt = graceBody.indexOf("root._lifecycleExitCode === 0");
    const reportAt = graceBody.indexOf("_reportLifecycleFailure");
    assert.ok(zeroAt >= 0, "the grace timer must special-case a successful exit");
    assert.ok(reportAt >= 0, "and must still be able to report a real failure");
    assert.ok(zeroAt < reportAt, "the success check must come before any report");
    assert.ok(
        /root\._lifecycleExitCode === 0\)\s*\{[\s\S]{0,900}?return;/.test(graceBody),
        "a successful command must return without reporting anything"
    );
    assert.ok(
        /root\._lifecycleExitCode < 0/.test(graceBody),
        "a command that never exited at all is the spawn failure, and must still be reported"
    );
});

test("onExited records the exit code without reporting", () => {
    const { lifecycleRunningBody } = lifecycleSlices();
    // Record exit status without preempting a more informative JSON verdict.
    const exitedSlice = lifecycleRunningBody.slice(lifecycleRunningBody.indexOf("onExited: exitCode =>"));
    const exitedBody = exitedSlice.slice(0, exitedSlice.indexOf("\n        }"));
    assert.ok(
        exitedBody.includes("root._lifecycleExitCode = exitCode"),
        "onExited must record the exit code"
    );
    assert.ok(
        !/_reportLifecycleFailure/.test(exitedBody),
        "and must not report from there, or an exit code beats the reason to the user"
    );
});

test("a failed spawn still reaches failure reporting through the grace timer", () => {
    const { lifecycleRunningSlice, graceBody } = lifecycleSlices();
    // A failed spawn may emit no exit. Running transition and grace must still reach failure reporting.
    assert.ok(
        /lifecycleUnansweredTimer\.restart\(\)/.test(lifecycleRunningSlice),
        "the running transition must arm the timer that owns the verdict"
    );
    assert.ok(
        /root\._lifecycleExitCode < 0[\s\S]{0,400}?_reportLifecycleFailure\(I18n\.tr\("`vshell remote-desktop/.test(graceBody),
        "and a command that never exited must be reported as unrunnable from there"
    );
});

test("_runLifecycle resets the exit code, takes a generation and stops the previous timer", () => {
    // Reset the recorded exit code per action so each verdict uses that action's outcome.
    const runLifecycleBody = qmlFunctionBody("_runLifecycle");
    assert.ok(
        runLifecycleBody.includes("root._lifecycleExitCode = -1"),
        "each action must start with no recorded exit code"
    );

    // Keep busy until the outcome is known and tag deferred verdicts per action.
    // UI busy gating alone cannot prevent a programmatic caller from starting another lifecycle action.
    assert.ok(
        runLifecycleBody.includes("root._lifecycleGeneration++"),
        "each action must take its own generation"
    );
    assert.ok(
        runLifecycleBody.includes("lifecycleUnansweredTimer.stop()"),
        "and must stop the previous action's timer: the tag stops misattribution, "
            + "but an armed tick nobody wants is a needless wakeup and one more ordering surprise"
    );
});
test("a superseded verdict returns without reporting or touching busy", () => {
    const { graceBody } = lifecycleSlices();
    assert.ok(
        /lifecycleUnansweredTimer\.armedFor = root\._lifecycleGeneration/.test(serviceSource),
        "the verdict timer must record which action armed it"
    );
    const supersededAt = graceBody.indexOf("armedFor !== root._lifecycleGeneration");
    assert.ok(supersededAt >= 0, "and must recognise a superseded verdict");
    assert.ok(
        supersededAt < graceBody.indexOf("root._lifecycleExitCode"),
        "the supersession check must come before anything reads the shared exit code"
    );
    assert.ok(
        /armedFor !== root\._lifecycleGeneration\)\s*\{[\s\S]{0,600}?return;/.test(graceBody),
        "a superseded verdict must return without reporting"
    );
    // A stale action must not clear newer busy state. Bound its branch by syntax,
    // not by the prohibited assignment that a mutation can move ahead of itself.
    const supersededEnd = graceBody.indexOf("return;", supersededAt);
    assert.ok(supersededEnd > supersededAt, "the superseded branch must return");
    const supersededBlock = graceBody.slice(supersededAt, supersededEnd);
    assert.ok(
        !/root\.busy/.test(supersededBlock),
        "a superseded verdict must leave `busy` to the action that now owns it"
    );
});

test("busy clears with the verdict, not with process stop", () => {
    const { lifecycleRunningSlice, graceBody } = lifecycleSlices();
    // Clear busy with the verdict, not merely process stop.
    assert.ok(
        !/root\.busy = false/.test(lifecycleRunningSlice),
        "the running=false handler must not re-enable the control before the verdict"
    );
    assert.ok(
        graceBody.includes("root.busy = false"),
        "the verdict timer is what clears busy"
    );
    assert.ok(
        graceBody.indexOf("root.busy = false") < graceBody.indexOf("root._lifecycleReported)"),
        "and it clears busy whether or not there was anything to report"
    );
});

test("ToastService exempts a changed correction from the error throttle and each action starts unreported", () => {
    const runLifecycleBody = qmlFunctionBody("_runLifecycle");
    const toastSource = fs.readFileSync(
        path.join(repoRoot, "quickshell", "vshell", "Services", "ToastService.qml"), "utf8"
    );
    assert.ok(
        /const updatesVisibleToast = /.test(toastSource),
        "ToastService must recognise an update to the toast already on screen"
    );
    assert.ok(
        /if \(level === levelError && !correctsVisibleToast\)/.test(toastSource),
        "and must exempt a correction from the error throttle"
    );
    // Only changed content is a correction exempt from throttling; repeated failures remain throttled.
    assert.ok(
        /const correctsVisibleToast = updatesVisibleToast && \(currentMessage !== message \|\| currentDetails !== \(details \|\| ""\)\)/.test(toastSource),
        "a correction must be an update whose CONTENT differs; the same message again is a repeat"
    );
    // A same-category repeat that survives throttling updates its existing toast.
    assert.ok(
        /if \(category\) \{\s*\n\s*if \(updatesVisibleToast\) \{/.test(toastSource),
        "the in-place update branch keys on the update, not on it being a correction"
    );
    const correctionAt = toastSource.indexOf("const correctsVisibleToast");
    const throttleGuardAt = toastSource.indexOf("if (level === levelError && !correctsVisibleToast)");
    assert.ok(correctionAt >= 0, "the correction flag must exist");
    assert.ok(throttleGuardAt >= 0, "the throttle must consult it");
    assert.ok(
        correctionAt < throttleGuardAt,
        "the exemption must be computed before the throttle consults it"
    );

    assert.ok(
        runLifecycleBody.includes("root._lifecycleReported = false"),
        "each action starts unreported, or the second failure in a session would be silent"
    );
});

test("a refresh during an in-flight probe is recorded and launched after it", () => {
    // Coalesce refreshes during a probe. Event debounce can expire before a slow journal read,
    // and no periodic poll recovers a dropped refresh.
    const refreshBody = qmlFunctionBody("refresh");
    assert.ok(
        refreshBody.includes("root._refreshPending = true"),
        "a refresh during an in-flight probe must be recorded, not discarded"
    );
    assert.ok(
        serviceCode.includes("if (root._refreshPending)\n                root.refresh();"),
        "the coalesced refresh must actually be launched once the probe completes"
    );
});

test("the status probe detects a start failure and marks unknown when unanswered", () => {
    // Start failure needs running-state and grace detection because it may emit no exit.
    assert.ok(
        /id: statusProc[\s\S]*?onRunningChanged/.test(serviceCode),
        "the status probe must handle onRunningChanged, or a missing binary leaves it stale forever"
    );
    assert.ok(
        serviceCode.includes("root._statusAnswered = false"),
        "the probe must arm its unanswered flag when it starts"
    );
    assert.ok(
        /id: statusUnansweredTimer[\s\S]*?_markStatusUnknown/.test(serviceCode),
        "an unanswered probe must mark the state unknown rather than keep the previous answer"
    );
});

test("_markStatusUnknown clears every knowledge axis and never streaming", () => {
    // Invalidate all related knowledge fields, including delegated session invalidation.
    const statusUnknownBody = qmlFunctionBody("_markStatusUnknown");
    const unknownBody = statusUnknownBody.includes("_markSessionUnknown(")
        ? statusUnknownBody + "\n" + qmlFunctionBody("_markSessionUnknown")
        : statusUnknownBody;
    for (const flag of ["statusKnown", "sessionKnown", "outputKnown"]) {
        assert.ok(
            unknownBody.includes(`root.${flag} = false`),
            `_markStatusUnknown must clear ${flag}: one axis left standing renders half an answer as a whole one`
        );
    }
    assert.ok(
        !/root\.streaming = false/.test(unknownBody),
        "losing the answer must not clear a possibly-live capture"
    );
});

test("the watcher backoff resets only after the stability window", () => {
    // Reset watcher backoff after sustained survival, not startup, so repeated immediate failures reach the cap.
    const watchBlock = serviceCode.slice(serviceCode.indexOf("id: watchProc"));
    const runningBranch = watchBlock.slice(0, watchBlock.indexOf("root.watchLive = false;"));
    assert.ok(
        !/backoffMs = 2000/.test(runningBranch),
        "the backoff must not reset the moment the watch starts, or 2s -> 60s is never reached"
    );
    assert.ok(
        runningBranch.includes("watchStable.restart()"),
        "entering `running` should start the stability window, not reset the backoff"
    );
    assert.ok(
        /id: watchStable[\s\S]*?onTriggered: watchRestart\.backoffMs = 2000/.test(serviceCode),
        "only the stability timer may reset the backoff"
    );
});

// Select tooltip text from the shared state decision instead of duplicating its ordering.

function tipFacts(overrides) {
    return Object.assign({
        statusKnown: true,
        sessionDetail: "",
        sessionError: "",
        statusError: "",
        unavailableReason: "",
        watchError: "",
        captureFallback: false,
        outputUnknown: false
    }, overrides || {});
}

// Derive returned states from the shipped decision so a new state enters message coverage automatically.
// Derived inside the cases that read it: at module scope a broken reader would abort the load before
// the reader's own control case could name the defect.
function derivedStates() {
    const decisionCode = stripComments(marked[1]);
    return [...new Set(
        quotedLiterals(functionBodyIn(decisionCode, "visualStateFor", "the STATE DECISION block"))
    )];
}

test("the derived state list comes from visualStateFor alone and is not vacuous", () => {
    const ALL_STATES = derivedStates();
    // Require known states and a nonempty result so a broken extractor cannot produce vacuous loops.
    assert.ok(ALL_STATES.length >= 6, `expected visualStateFor() to return at least 6 states, derived ${ALL_STATES.length}`);
    for (const anchor of ["streaming", "listening", "off"]) {
        assert.ok(
            ALL_STATES.includes(anchor),
            `the derived state list must contain ${anchor}; if it does not, the extraction is reading the wrong thing`
        );
    }
    // Exclude quoted words in comments from the derived state list.
    for (const notAState of ["On", "LIVE"]) {
        assert.ok(
            !ALL_STATES.includes(notAState),
            `${notAState} is prose from a comment, not a state -- the derivation is reading comments`
        );
    }
    // Extract visualStateFor only; neighboring tooltip and subtitle keys are not states.
    for (const notAState of ["streaming-host-uncertain", "listening-capture-fallback", "output-unmanaged"]) {
        assert.ok(
            !ALL_STATES.includes(notAState),
            `${notAState} is a message key from a sibling function -- the derivation is reading past visualStateFor()`
        );
    }
});

test("every derived state selects its own tooltip message", () => {
    const ALL_STATES = derivedStates();
    const keysSeen = new Set();
    for (const state of ALL_STATES) {
        const tip = tooltipFor(state, tipFacts());
        assert.ok(tip && typeof tip.key === "string" && tip.key.length > 0, `${state} must select a tooltip`);
        keysSeen.add(tip.key);
    }
    assert.equal(
        keysSeen.size, ALL_STATES.length,
        "each state must select a DISTINCT message; sharing one would make two states read alike — a live " +
        "capture and an idle host, a confirmed and an unconfirmed capture, 'nobody is connected' and 'we cannot say'"
    );
});

// Keep confirmed capture as the headline when host status is uncertain.
test("a confirmed capture with an unknown host stays a streaming message and carries the session detail", () => {
    const uncertain = tooltipFor("streaming", tipFacts({ statusKnown: false }));
    assert.equal(uncertain.key, "streaming-host-uncertain", "a confirmed capture with an unknown host state says both");
    assert.ok(uncertain.key.startsWith("streaming"), "and it stays a streaming message; downgrading it would hide the capture");
    assert.equal(
        tooltipFor("streaming", tipFacts({ sessionDetail: "h264 · 20000 kbps" })).detail,
        "h264 · 20000 kbps",
        "the session summary rides along with the streaming message"
    );
});

// Use the service's reason when present and a fallback only when absent.
test("tooltipFor carries the service's own reason for each uncertain state, and nothing when absent", () => {
    for (const [state, factKey] of [
        ["streaming-unconfirmed", "sessionError"],
        ["unknown", "statusError"],
        ["unavailable", "unavailableReason"],
        ["stale", "watchError"],
        ["listening-unconfirmed", "sessionError"]
    ]) {
        assert.equal(
            tooltipFor(state, tipFacts({ [factKey]: "the real reason" })).reason,
            "the real reason",
            `${state} must carry the service's own explanation, not a generic stand-in`
        );
        assert.equal(
            tooltipFor(state, tipFacts()).reason, "",
            `${state} with no reason must leave it empty for the caller to fill`
        );
    }
});

// A known invalid capture target takes precedence over an unchecked target, and those messages belong
// to listening alone.
test("tooltipFor names the listening output problems in precedence order and lends them to no other state", () => {
    for (const [facts, expected, why] of [
        [{ captureFallback: true, outputUnknown: true }, "listening-capture-fallback",
            "a confirmed fallback to a real monitor outranks an unchecked output"],
        [{ outputUnknown: true }, "listening-output-unknown", "an unchecked output is its own message, not a plain idle host"],
        [{}, "listening", "an ordinary idle host gets the plain message"]
    ]) {
        assert.equal(tooltipFor("listening", tipFacts(facts)).key, expected, why);
    }
    for (const state of ["streaming", "streaming-unconfirmed", "unknown", "unavailable", "stale", "off"]) {
        const tip = tooltipFor(state, tipFacts({ captureFallback: true, outputUnknown: true }));
        assert.ok(
            !tip.key.startsWith("listening-"),
            `${state} must not borrow a listening message just because the output looks wrong`
        );
    }
});

test("sessionDetailFrom renders the known fields in order and omits the rest", () => {
    for (const [session, expected, why] of [
        [{}, "", "nothing known is an empty summary, not a row of separators"],
        [{ codec: "h264", bitrateBps: 19999000, colorDepth: "8-bit" }, "h264 · 19999 kbps · 8-bit", "everything present renders in order"],
        [{ bitrateBps: 20000000 }, "20000 kbps", "a missing field is omitted rather than left as an empty segment"],
        [{ codec: "h264", bitrateBps: 0 }, "h264", "a zero bitrate is not a measurement, so it is omitted"],
        [{ bitrateBps: 1500 }, "2 kbps", "the bitrate is rounded, not truncated"]
    ]) {
        assert.equal(sessionDetailFrom(session), expected, why);
    }
});

// An up-host subtitle must describe non-Hyprland capture rather than return an unexplained blank.

function subtitleFacts(overrides) {
    return Object.assign({
        outputUnknown: false,
        outputPresent: false,
        outputManaged: true,
        outputName: "HEADLESS-1",
        compositor: "hyprland"
    }, overrides || {});
}

test("upSubtitleFor selects a message for every output shape, unknown first and unmanaged named", () => {
    for (const [facts, expected, why] of [
        [{ outputUnknown: true }, { key: "output-unknown", output: "HEADLESS-1" }, "an unchecked output says so"],
        [{ outputPresent: true }, { key: "output-present", output: "HEADLESS-1" }, "the ordinary case still names what is being captured"],
        [{}, { key: "output-missing", output: "HEADLESS-1" }, "Hyprland with the output gone is a real-monitor capture, not a blank subtitle"],
        [{ outputManaged: false, compositor: "niri" }, { key: "output-unmanaged", compositor: "niri" },
            "a compositor VGS cannot create an output on gets its own line, never a blank one, and names the compositor"],
        [{ outputManaged: false, compositor: "unknown" }, { key: "output-unmanaged", compositor: "unknown" }, "an unknown compositor still gets the line"],
        [{ outputManaged: false, compositor: "" }, { key: "output-unmanaged", compositor: "" }, "and so does an unnamed one"],
        [{ outputUnknown: true, outputPresent: true }, { key: "output-unknown", output: "HEADLESS-1" },
            "not knowing outranks a stale `present`, which is what the unknown flag exists to say"]
    ]) {
        assert.deepEqual(upSubtitleFor(subtitleFacts(facts)), expected, `${JSON.stringify(facts)}: ${why}`);
    }
});

// Renderers must consume descriptors so state ordering remains in the shared decision.
test("the renderers select on the descriptor key and never re-derive state", () => {
    for (const fn of ["tooltipText", "upSubtitleText"]) {
        const body = widgetFunctionBody(fn);
        assert.ok(
            /switch \(\w+\.key\)/.test(body),
            `${fn} must select on the descriptor's key`
        );
        assert.ok(
            !/RemoteDesktopService\.(statusKnown|sessionKnown|running|installed|streaming)\b/.test(body),
            `${fn} must not re-read the state it was handed a verdict for`
        );
        assert.ok(
            !/\broot\.(visualState\s*===|streaming\b|hostUp\b|statusKnown\s*[!=]==?)/.test(body.replace(/root\.tooltipFor\([^)]*/, "")),
            `${fn} must not re-derive the state; that is visualStateFor()'s job`
        );
    }
});
