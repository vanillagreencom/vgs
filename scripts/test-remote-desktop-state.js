#!/usr/bin/env node

// Pins the remoteDesktop widget's state ordering and the service's
// unknown-state handling.
//
// Bundled plugins get no runtime coverage from `qml-smoke.sh --nested` — the
// sandbox loads them but never places one in a bar, so no binding here is ever
// evaluated (same reason scripts/test-sudo-toggle-confirm.js exists, VGS-19).
// Every finding this file closes was either an ORDERING bug or a dropped event,
// neither of which qmllint can see, and starting the real Sunshine host to
// observe them means capturing somebody's screen.
//
// The decision function is extracted verbatim from the shipped QML between its
// BEGIN/END STATE DECISION markers, so this tests the real source rather than a
// re-implementation. The service's structural invariants are asserted against
// its own source, because the bug shape there is a MISSING line.

"use strict";

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

// --- read the CODE, never the commentary ------------------------------------
//
// Every assertion below asks whether some text is present. Read against the raw
// file a COMMENT answers that just as well as the code does, and both files are
// heavily commented precisely because the orderings they encode are subtle. Two
// concrete hazards here: `visualStateFor`'s own comments contain quoted words
// ("On", "LIVE"), which would land in the derived state list; and a comment
// naming a function would satisfy the body extractor.
//
// Comments are blanked once, up front, with characters replaced by spaces so
// offsets and line structure survive. The BEGIN/END markers are themselves
// comments, so marker extraction deliberately keeps using the raw text.
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

// Prove the stripper before a single assertion leans on it.
{
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
}

// Every double-quoted literal in `text`, scanned rather than regex-matched.
// The obvious /"([^"]+)"/g cannot match an empty literal, so one `""` shifts
// every pair after it and swallows the values between them -- an under-count,
// which is the quietest way for a check to stop checking.
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

assert.deepEqual(
    quotedLiterals('f(tr("msg"), "", "category")'),
    ["msg", "", "category"],
    "an empty literal must not shift the pairing of the ones after it"
);

const widgetCode = stripComments(widgetSource);
const serviceCode = stripComments(serviceSource);
assert.ok(
    widgetSource.length > widgetCode.replace(/ +$/gm, "").length,
    "the widget should carry comments; stripping is what keeps them out of these assertions"
);

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

// --- the ordinary states ----------------------------------------------------

assert.equal(visualStateFor(host({})), "off", "installed, known, watched, not running");
assert.equal(visualStateFor(host({ running: true })), "listening", "up with nobody connected");
assert.equal(
    visualStateFor(host({ running: true, streaming: true })),
    "streaming",
    "a connected client is its own state, never folded into 'up'"
);
assert.equal(
    visualStateFor(host({ installed: false })),
    "unavailable",
    "a known-absent Sunshine is unavailable"
);
assert.equal(
    visualStateFor(host({ running: true, watchLive: false })),
    "stale",
    "a dead event watch means the values may be out of date"
);

// --- unknown is checked BEFORE installed ------------------------------------
//
// `installed` defaults to false, so testing it first rendered "Sunshine is not
// installed" for every instant before the first reply, and again after any
// failed probe. A default is not an answer.

assert.equal(
    visualStateFor(host({ statusKnown: false, installed: false })),
    "unknown",
    "no answer yet must not render as 'not installed' — that is a default, not a fact"
);
assert.equal(
    visualStateFor(host({ statusKnown: false, installed: true, running: true })),
    "unknown",
    "a failed probe must not keep rendering the previous host state as current"
);
assert.equal(
    visualStateFor(host({ statusKnown: false, watchLive: false })),
    "unknown",
    "unknown outranks stale: there is no previous answer to call stale"
);

// --- streaming is checked before EVERY uncertainty state --------------------
//
// A capture that may still be live has to fail loud. Downgrading it to a
// question mark because a probe failed would hide the one thing this widget
// exists to show.

for (const uncertain of [
    { statusKnown: false },
    { watchLive: false },
    { statusKnown: false, watchLive: false },
    { installed: false }
]) {
    assert.equal(
        visualStateFor(host(Object.assign({ streaming: true }, uncertain))),
        "streaming",
        `a possible live capture must outrank uncertainty ${JSON.stringify(uncertain)}`
    );
}

// --- a live capture is never rendered on a dead watcher's last message ------
//
// Losing the watch makes the session UNKNOWN, not idle. "Confirmed live" and
// "last we heard, live" are different claims, so they get different states —
// but neither of them is idle, and neither hides the capture.

assert.equal(
    visualStateFor(host({ streaming: true, sessionKnown: false, watchLive: false })),
    "streaming-unconfirmed",
    "a dead watch must not let a plain LIVE stand on its last message"
);
assert.equal(
    visualStateFor(host({ streaming: true, sessionKnown: false, watchLive: false, statusKnown: false })),
    "streaming-unconfirmed",
    "losing the host status too does not make a possible capture idle"
);
assert.equal(
    visualStateFor(host({ streaming: true, sessionKnown: true, watchLive: false })),
    "streaming",
    "a session the status read still confirms stays plainly LIVE"
);
for (const state of ["unknown", "stale", "listening", "off", "unavailable"]) {
    assert.notEqual(
        visualStateFor(host({ streaming: true, sessionKnown: false, watchLive: false, statusKnown: false, installed: false })),
        state,
        `an unconfirmed capture must never fall through to ${state}`
    );
}

// --- an unreadable journal is not "nobody is watching" ----------------------
//
// The helper reports `readable: false` with `active` left at its default
// false. Taking that default at face value cleared a live capture on the
// strength of a failed read — the same defect as the dead-watcher case, moved
// to the assignment site.

const unreadable = sessionApplyDecision({ readable: false, active: false, error: "No journal files were found." });
assert.equal(unreadable.known, false, "an unreadable journal leaves the session unknown");
assert.equal(
    unreadable.applyActive, false,
    "`active` must not be applied from a block that says it could not be read"
);
assert.equal(unreadable.reason, "No journal files were found.", "the reason survives to the caller");

assert.equal(sessionApplyDecision({}).applyActive, false, "a missing session block decides nothing");
assert.equal(sessionApplyDecision(null).applyActive, false, "no session block decides nothing");
assert.equal(
    sessionApplyDecision({ readable: "yes", active: true }).applyActive,
    false,
    "only a literal true is readable; a truthy value is not an answer"
);

const readable = sessionApplyDecision({ readable: true, active: true, error: "" });
assert.equal(readable.known, true, "a readable journal is an answer");
assert.equal(readable.applyActive, true, "and its `active` is the authority that may clear LIVE");
assert.equal(
    sessionApplyDecision({ readable: true, active: false }).applyActive,
    true,
    "a readable journal saying nobody is connected DOES clear it — that is the one authority"
);

// _applyStatus must route through the decision, and must not assign the
// session fields on the path that decided nothing.
const applyBody = qmlFunctionBody("_applyStatus");
assert.ok(
    applyBody.includes("root.sessionApplyDecision(session)"),
    "_applyStatus must route the session block through the decision"
);
// The guard's PRESENCE is asserted before its position. `indexOf` returns -1
// for an absent needle, and -1 is trivially less than any real index, so an
// ordering assertion alone passes vacuously once the guard is deleted — which
// is precisely the mutation it exists to catch.
const guardAt = applyBody.indexOf("if (!decision.applyActive)");
const assignAt = applyBody.indexOf("root.streaming = session.active === true");
assert.ok(guardAt >= 0, "_applyStatus must guard the session assignment on the decision");
assert.ok(assignAt >= 0, "_applyStatus must still be the site that applies the session");
assert.ok(guardAt < assignAt, "the guard must come before the assignment it guards");
assert.ok(
    applyBody.includes("root._markSessionUnknown(decision.reason"),
    "an unreadable block moves the session to unknown, not to idle"
);

// And "up, but we cannot say whether anyone is connected" must not render as a
// plain On, which claims nobody is — the reassuring direction is the worse one
// to get wrong.
assert.equal(
    visualStateFor(host({ running: true, sessionKnown: false })),
    "listening-unconfirmed",
    "a host whose sessions cannot be read must not claim nobody is watching"
);
assert.equal(
    visualStateFor(host({ running: true, sessionKnown: true })),
    "listening",
    "a confirmed idle host still reads plainly On"
);
assert.equal(
    visualStateFor(host({ running: false, sessionKnown: false })),
    "off",
    "a host that is down has no sessions to be unsure about"
);

// --- streaming must not LOOK like listening ---------------------------------
//
// The state split is only worth having if it reaches the pixels. The colour
// tokens are returned as names precisely so this can be asserted without a
// Theme instance.

assert.equal(stateColorTokenFor("streaming"), "error", "a live capture is an alarm colour");
assert.equal(
    stateColorTokenFor("streaming-unconfirmed"), "error",
    "an unconfirmed capture keeps the alarm colour; softening it trades a possible live capture for a tidier bar"
);
assert.equal(stateColorTokenFor("listening"), "primary");
assert.equal(stateColorTokenFor("listening-unconfirmed"), "warning");
assert.equal(stateColorTokenFor("unknown"), "warning");
assert.equal(stateColorTokenFor("stale"), "warning");
assert.equal(stateColorTokenFor("off"), "surfaceVariantText");
assert.equal(stateColorTokenFor("unavailable"), "surfaceVariantText");

assert.notEqual(
    stateColorTokenFor("streaming"), stateColorTokenFor("listening"),
    "the two states this widget exists to distinguish must not share a colour"
);

// The BAR PILL glyph, not just the popout. In `icon` pill mode there is no
// text at all, so before this the only difference between "someone is watching
// my screen" and "idle" was `cast_connected` vs `cast` — a glyph shape, at bar
// size, in the same colour.
assert.equal(
    pillIconUsesStateColor("streaming"), true,
    "the pill glyph must carry the alarm colour, or LIVE is a shape difference only"
);
assert.equal(pillIconUsesStateColor("streaming-unconfirmed"), true);
assert.equal(pillIconUsesStateColor("unknown"), true);
assert.equal(pillIconUsesStateColor("stale"), true);
assert.equal(pillIconUsesStateColor("listening-unconfirmed"), true);
// Bars keep one icon colour by convention, and for the states where nothing is
// wrong that convention is right.
assert.equal(pillIconUsesStateColor("listening"), false, "an idle host does not shout");
assert.equal(pillIconUsesStateColor("off"), false);
assert.equal(pillIconUsesStateColor("unavailable"), false);

// The bindings have to actually consume the tokens; a table nothing reads is
// not a fix.
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

// --- the decision function can fail ----------------------------------------
//
// Everything above passes; that proves nothing about the harness. Confirm the
// assertions are capable of failing on the shape they are written to reject.
assert.throws(
    () => assert.equal(visualStateFor(host({ statusKnown: false, installed: false })), "unavailable"),
    "the ordering assertions must be capable of failing"
);

// --- service invariants -----------------------------------------------------

function qmlFunctionBody(name) {
    return functionBodyIn(serviceCode, name, "RemoteDesktopService.qml");
}

function widgetFunctionBody(name) {
    return functionBodyIn(widgetCode, name, "RemoteDesktopWidget.qml");
}

// A QML function body, located by a UNIQUE declaration and closed by matching
// braces.
//
// The previous form took the first `function <name>(` in the raw file and ran
// to the first line matching "\n    }". Three ways that measured the wrong
// thing while still passing: a comment mentioning the name matched (comments are
// now stripped); a second, similarly-named function silently repointed it; and
// the closing heuristic depended on the indentation the body happens to sit at,
// so it stopped early on anything nested differently. Same class as the
// first-match `showInfo` lookup on PR #82.
function functionBodyIn(code, name, where) {
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

// --- prove the reader, on sources it must reject or handle exactly ----------
//
// ALL_STATES is derived through this reader, so a reader that quietly located
// the wrong span would produce a wrong state list and every loop over it would
// assert about the wrong thing while reporting success. Its self-test therefore
// has to be capable of failing.
//
// What stood here was `!functionBodyIn(...).includes("ghost")`. "ghost" was in
// neither the sample nor any output the reader could produce, so that assertion
// could not fail for any implementation -- it read like a check and measured
// nothing. Each case below is paired with the reason it can fail.

// Absent: no declaration at all.
assert.throws(
    () => widgetFunctionBody("thisFunctionDoesNotExist"),
    "the reader must fail on a name that is absent, not return an empty body"
);

// Ambiguous: two declarations, so "the first one" is a guess.
assert.throws(
    () => functionBodyIn("function twice() { }\nfunction twice() { }", "twice", "a sample"),
    "the reader must refuse an ambiguous name rather than take whichever came first"
);

// Unclosed: running to the end of the file is not an answer.
assert.throws(
    () => functionBodyIn("function open() {\n    return 1;", "open", "a sample"),
    "an unclosed body must fail rather than swallow the rest of the file"
);

// A brace inside a string literal must not close the body early.
assert.equal(
    functionBodyIn('function only() {\n    const s = "}";\n    return 1;\n}', "only", "a sample"),
    'function only() {\n    const s = "}";\n    return 1;\n}',
    "a brace inside a string literal must not close the body early"
);

// A shorter name must not match a longer one that starts with it.
assert.ok(
    functionBodyIn(
        "function targetLonger() { return 1; }\nfunction target() { return 2; }",
        "target", "a sample"
    ).includes("return 2"),
    "`target` must not resolve to `targetLonger`"
);

// THE CENTRAL CLAIM: a comment naming the function must not be located instead
// of the function. This is what the raw-source reader got wrong, and it was the
// one behaviour with no assertion behind it.
{
    const shadowed = [
        "// call function target( from here",
        "function target() {",
        '    return "real body";',
        "}"
    ].join("\n");

    // The fixture must actually be adversarial, or the assertion below passes
    // for the wrong reason. A naive first-match reader has to be fooled by it.
    const naive = shadowed.slice(shadowed.indexOf("function target("));
    assert.ok(
        naive.startsWith("function target( from here"),
        "the shadowing sample must fool a first-match reader, or it proves nothing about the fix"
    );

    const body = functionBodyIn(stripComments(shadowed), "target", "a sample");
    assert.ok(body.includes("real body"), "the reader must locate the function, not a comment naming it");
    assert.ok(!body.includes("from here"), "and must not begin inside that comment");
}

// A single disconnect must never clear the indicator. With more than one client
// connected it ends ONE session, not the capture, so only the authoritative
// session count may turn LIVE off.
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

// _applyStatus is the ONLY writer that turns streaming off.
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

// Losing the watch clears the session DETAIL, because those values were only
// current while something was refreshing them — but never `streaming`, which
// would be claiming idle on a dead watcher's say-so.
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

// The watch-stop path has to actually call it, and then ask the status read —
// which is a separate process and does not depend on the watch.
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

// A status reply that says the unit query failed must not be applied as
// "not installed" — the same defect as reading an unreadable journal as idle.
assert.ok(
    /if \(status\.unitKnown === false \|\| status\.state === "unknown"\)/.test(applyBody),
    "_applyStatus must route an unanswerable unit query to unknown"
);
const unitGuardAt = applyBody.indexOf("status.unitKnown === false");
const installedAt = applyBody.indexOf("root.installed = status.installed === true");
assert.ok(unitGuardAt >= 0, "the unit-unknown guard must exist");
assert.ok(installedAt >= 0, "_applyStatus must still be the site that applies `installed`");
assert.ok(unitGuardAt < installedAt, "the guard must come before the assignment it guards");

// A refresh arriving during a probe is coalesced, never dropped: the journal
// read can take seconds while the event debounce is 400ms, and there is no
// polling fallback to recover a lost event.
const refreshBody = qmlFunctionBody("refresh");
assert.ok(
    refreshBody.includes("root._refreshPending = true"),
    "a refresh during an in-flight probe must be recorded, not discarded"
);
assert.ok(
    serviceCode.includes("if (root._refreshPending)\n                root.refresh();"),
    "the coalesced refresh must actually be launched once the probe completes"
);

// A command that fails to start emits no `exited` at all, so the probe has to
// be keyed on `running` plus an unanswered grace period.
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

// Every knowledge axis drops together — a half answer must not render whole.
// The session half may be reached by delegation to _markSessionUnknown (the
// watch-loss path needs it on its own), so the effective body is what matters;
// asserting only the literal body would go red on a refactor that still clears
// everything, and — worse — could go green if the delegate stopped clearing.
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

// The backoff is earned by surviving, not by starting. Resetting on `running`
// makes the cap unreachable for a watcher that fails immediately.
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

// --- the tooltip selects on the decided state, and never re-derives it ------
//
// tooltipText() used to walk the same ordering a second time: streaming, then
// statusKnown, then installed, then stale. Two copies of one table, free to
// drift, in a widget whose every reported defect has been an ordering bug. The
// ordering now has one owner and the message is chosen from its verdict, so the
// table below is what pins that every state still says something, and says the
// right thing.

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

// EVERY state the decision function can return must get a message. A state
// added to visualStateFor() without one would silently fall to the default and
// tell the user the host is off.
//
// DERIVED, not transcribed. A hand-maintained list is the same defect this
// block exists to prevent, one level up: add a state, forget the list, and the
// new state goes untested while the suite still reports success. The block
// itself is extracted verbatim from the shipped QML, so the states it can
// return are read out of it the same way.
const decisionCode = stripComments(marked[1]);
const ALL_STATES = [...new Set(
    quotedLiterals(functionBodyIn(decisionCode, "visualStateFor", "the STATE DECISION block"))
)];

// Anchors, so a broken extraction cannot make every loop below vacuous. An
// empty or truncated list would otherwise pass everything by iterating nothing.
assert.ok(ALL_STATES.length >= 6, `expected visualStateFor() to return at least 6 states, derived ${ALL_STATES.length}`);
for (const anchor of ["streaming", "listening", "off"]) {
    assert.ok(
        ALL_STATES.includes(anchor),
        `the derived state list must contain ${anchor}; if it does not, the extraction is reading the wrong thing`
    );
}
// The comments inside visualStateFor() quote words like "On" and "LIVE". If
// those reached the list the loops below would assert about text that is not a
// state at all, so the stripping above is load-bearing here specifically.
for (const notAState of ["On", "LIVE"]) {
    assert.ok(
        !ALL_STATES.includes(notAState),
        `${notAState} is prose from a comment, not a state -- the derivation is reading comments`
    );
}
// And it must be scoped to visualStateFor(), not to the whole marked block.
// These are tooltip and subtitle KEYS from the sibling functions: they are
// string literals in the same block, so a reader that took the block instead of
// the one function would sweep them in and the completeness loop would then
// demand tooltips for things that are not states.
for (const notAState of ["streaming-host-uncertain", "listening-capture-fallback", "output-unmanaged"]) {
    assert.ok(
        !ALL_STATES.includes(notAState),
        `${notAState} is a message key from a sibling function -- the derivation is reading past visualStateFor()`
    );
}

const keysSeen = new Set();
for (const state of ALL_STATES) {
    const tip = tooltipFor(state, tipFacts());
    assert.ok(tip && typeof tip.key === "string" && tip.key.length > 0, `${state} must select a tooltip`);
    keysSeen.add(tip.key);
}
assert.equal(
    keysSeen.size, ALL_STATES.length,
    "each state must select a DISTINCT message; sharing one would make two states read alike"
);

// The states this widget exists to distinguish must not share a tooltip either
// -- the colour split above is worthless if the words collapse.
assert.notEqual(
    tooltipFor("streaming", tipFacts()).key,
    tooltipFor("listening", tipFacts()).key,
    "a live capture and an idle host must not read alike"
);
assert.notEqual(
    tooltipFor("streaming", tipFacts()).key,
    tooltipFor("streaming-unconfirmed", tipFacts()).key,
    "a confirmed capture and an unconfirmed one are different claims"
);
assert.notEqual(
    tooltipFor("listening", tipFacts()).key,
    tooltipFor("listening-unconfirmed", tipFacts()).key,
    "'nobody is connected' and 'we cannot say' must not read alike"
);

// An uncertain host axis is reported BESIDE a confirmed capture, not instead
// of it: the capture is still the headline.
assert.equal(
    tooltipFor("streaming", tipFacts({ statusKnown: false })).key,
    "streaming-host-uncertain",
    "a confirmed capture with an unknown host state says both"
);
assert.ok(
    tooltipFor("streaming", tipFacts({ statusKnown: false })).key.startsWith("streaming"),
    "and it stays a streaming message; downgrading it would hide the capture"
);
assert.equal(
    tooltipFor("streaming", tipFacts({ sessionDetail: "h264 · 20000 kbps" })).detail,
    "h264 · 20000 kbps",
    "the session summary rides along with the streaming message"
);

// The service's own reason reaches the message; the caller supplies a fallback
// only when there is none, so a real explanation is never replaced by a
// generic one.
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

// A known-bad capture target outranks an unchecked one: one is a fact, the
// other is not knowing, and the fact is the worse news.
assert.equal(
    tooltipFor("listening", tipFacts({ captureFallback: true, outputUnknown: true })).key,
    "listening-capture-fallback",
    "a confirmed fallback to a real monitor outranks an unchecked output"
);
assert.equal(
    tooltipFor("listening", tipFacts({ outputUnknown: true })).key,
    "listening-output-unknown",
    "an unchecked output is its own message, not a plain idle host"
);
assert.equal(
    tooltipFor("listening", tipFacts()).key, "listening",
    "an ordinary idle host gets the plain message"
);

// The capture-fallback and unchecked-output messages belong to the LISTENING
// state only. Reaching them from a streaming state would bury the capture.
for (const state of ["streaming", "streaming-unconfirmed", "unknown", "unavailable", "stale", "off"]) {
    const tip = tooltipFor(state, tipFacts({ captureFallback: true, outputUnknown: true }));
    assert.ok(
        !tip.key.startsWith("listening-"),
        `${state} must not borrow a listening message just because the output looks wrong`
    );
}

// --- the session summary --------------------------------------------------

assert.equal(sessionDetailFrom({}), "", "nothing known is an empty summary, not a row of separators");
assert.equal(
    sessionDetailFrom({ codec: "h264", bitrateBps: 19999000, colorDepth: "8-bit" }),
    "h264 · 19999 kbps · 8-bit",
    "everything present renders in order"
);
assert.equal(
    sessionDetailFrom({ bitrateBps: 20000000 }), "20000 kbps",
    "a missing field is omitted rather than left as an empty segment"
);
assert.equal(
    sessionDetailFrom({ codec: "h264", bitrateBps: 0 }), "h264",
    "a zero bitrate is not a measurement, so it is omitted"
);
assert.equal(
    sessionDetailFrom({ bitrateBps: 1500 }), "2 kbps",
    "the bitrate is rounded, not truncated"
);

// --- the up-host subtitle always says something ----------------------------
//
// The non-Hyprland branch used to fall through to "". A blank line where every
// neighbouring state has one reads as a rendering fault, and it is exactly the
// case where the user most needs telling that a REAL monitor is being captured.

function subtitleFacts(overrides) {
    return Object.assign({
        outputUnknown: false,
        outputPresent: false,
        outputManaged: true,
        outputName: "HEADLESS-1",
        compositor: "hyprland"
    }, overrides || {});
}

for (const facts of [
    subtitleFacts({ outputUnknown: true }),
    subtitleFacts({ outputPresent: true }),
    subtitleFacts({}),
    subtitleFacts({ outputManaged: false, compositor: "niri" }),
    subtitleFacts({ outputManaged: false, compositor: "unknown" }),
    subtitleFacts({ outputManaged: false, compositor: "" })
]) {
    const sub = upSubtitleFor(facts);
    assert.ok(
        sub && typeof sub.key === "string" && sub.key.length > 0,
        `every up-host subtitle must select a message: ${JSON.stringify(facts)}`
    );
}

assert.equal(
    upSubtitleFor(subtitleFacts({ outputManaged: false, compositor: "niri" })).key,
    "output-unmanaged",
    "a compositor VGS cannot create an output on gets its own line, never a blank one"
);
assert.equal(
    upSubtitleFor(subtitleFacts({ outputManaged: false, compositor: "niri" })).compositor,
    "niri",
    "and it can name the compositor when one is known"
);
assert.equal(
    upSubtitleFor(subtitleFacts({})).key,
    "output-missing",
    "Hyprland with the output gone is a real-monitor capture, not a blank subtitle"
);
assert.equal(
    upSubtitleFor(subtitleFacts({ outputPresent: true })).key, "output-present",
    "the ordinary case still names what is being captured"
);
assert.equal(
    upSubtitleFor(subtitleFacts({ outputUnknown: true, outputPresent: true })).key,
    "output-unknown",
    "not knowing outranks a stale `present`, which is what the unknown flag exists to say"
);

// --- both renderers select on the descriptor, and decide nothing themselves -
//
// The point of the split is that the ordering has ONE owner. A renderer that
// re-tested the service's state would put a second copy back.
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

console.log("Remote desktop state checks passed.");
