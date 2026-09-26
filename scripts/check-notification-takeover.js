#!/usr/bin/env node

"use strict";

// Source checks cover notification takeover ordering without masking a live daemon.
// The nested smoke bus has no foreign notification owner, so it does not reach this branch.
// These assertions inspect source text; they do not establish all runtime orderings.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.resolve(__dirname, "..");
const servicePath = path.join(repoRoot, "quickshell/vshell/Services/NotificationService.qml");
const rawSource = fs.readFileSync(servicePath, "utf8");

// Blank comments without shifting offsets or line structure.
// Otherwise a comment can satisfy a source assertion after the executable guard is deleted.
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


{
    const sample = 'a(); // takeOverNotificationServer(true)\nb("// not a comment"); /* gone */ c();';
    const stripped = stripComments(sample);
    assert.ok(!stripped.includes("takeOverNotificationServer"), "a line comment must not survive stripping");
    assert.ok(!stripped.includes("gone"), "a block comment must not survive stripping");
    assert.ok(stripped.includes('"// not a comment"'), "a // inside a string literal is not a comment");
    assert.ok(stripped.includes("a();") && stripped.includes("c();"), "code either side of a comment must survive");
    assert.equal(stripped.length, sample.length, "stripping must preserve offsets, or every slice below shifts");
    assert.equal(
        (stripped.match(/\n/g) || []).length,
        (sample.match(/\n/g) || []).length,
        "stripping must preserve line structure, or functionBody() stops matching"
    );
}

const source = stripComments(rawSource);

// This fixture requires comments in the inspected source to exercise comment stripping.
assert.ok(
    rawSource.length > source.replace(/ +$/gm, "").length,
    "NotificationService.qml should carry comments; stripping is what keeps them out of these assertions"
);

// Read a QML function through its closing brace at singleton indentation.
function functionBody(name) {
    const start = source.indexOf(`function ${name}(`);
    assert.ok(start >= 0, `NotificationService.qml should define ${name}()`);
    const end = source.indexOf("\n    }", start);
    assert.ok(end > start, `${name}() should be a closed function body`);
    return source.slice(start, end);
}


assert.throws(
    () => functionBody("thisFunctionDoesNotExist"),
    "functionBody() must fail on a name that is absent, or every assertion below is vacuous"
);

// SettingsData.set() requests a save but does not confirm persistence.
// A separate process must read back the one-shot before takeover can mask another daemon.

const automaticTakeoverCalls = source.match(/takeOverNotificationServer\(true\)/g) || [];
assert.equal(
    automaticTakeoverCalls.length,
    1,
    "the automatic takeover must have exactly one call site, or a second one can skip the confirmation"
);

const resolveSpend = functionBody("_resolveFirstRunSpend");
assert.ok(
    resolveSpend.includes("takeOverNotificationServer(true)"),
    "the automatic takeover must be fired from _resolveFirstRunSpend(), the confirmation step"
);
assert.ok(
    resolveSpend.includes("serverPersistedOneShotDone"),
    "_resolveFirstRunSpend() must consult the on-disk one-shot; without it the confirmation is decorative"
);

const maybeTakeOver = functionBody("_maybeTakeOverOnFirstRun");
assert.ok(
    !maybeTakeOver.includes("takeOverNotificationServer("),
    "_maybeTakeOverOnFirstRun() must not take over directly -- it writes the one-shot, and the write is what has to be confirmed first"
);
// Split at the write so a gate after the mutation cannot satisfy a precondition check.
const spendIndex = maybeTakeOver.indexOf('SettingsData.set("notificationFirstRunTakeoverDone", true)');
assert.ok(spendIndex > 0, "_maybeTakeOverOnFirstRun() should write the one-shot");
const beforeSpend = maybeTakeOver.slice(0, spendIndex);
const afterSpend = maybeTakeOver.slice(spendIndex);

assert.ok(
    beforeSpend.includes("_hasLoaded") && beforeSpend.includes("_parseError"),
    "J1: a config that did not load is indistinguishable from a fresh install, so both gates must precede the write"
);
assert.ok(
    beforeSpend.includes("_isReadOnly"),
    "a settings store already known unwritable must be refused BEFORE the one-shot is written"
);
assert.ok(
    afterSpend.includes("_isReadOnly"),
    "a save that failed synchronously must be caught right after the write, not assumed away"
);
assert.ok(
    maybeTakeOver.includes("_firstRunSpendPending"),
    "_maybeTakeOverOnFirstRun() must hand off to the confirmation step rather than proceeding"
);

// A probe that cannot start must not leave confirmation pending without a deadline.
assert.ok(
    /_firstRunSpendDeadline/.test(maybeTakeOver) && /_firstRunSpendDeadline/.test(resolveSpend),
    "the spend confirmation must be bounded by a deadline it both sets and checks"
);

// A failed Process start can emit no exited event. The deadline needs an independent timer.
assert.ok(
    source.includes("id: firstRunSpendTimer"),
    "the spend confirmation must have its own timer; a deadline checked only on re-entry never fires when nothing re-enters"
);
assert.ok(
    maybeTakeOver.includes("firstRunSpendTimer.restart()"),
    "the spend timer must be armed where the pending state is set, or the two can disagree"
);

const spendTimerStart = source.indexOf("id: firstRunSpendTimer");
const spendTimerBody = source.slice(spendTimerStart, source.indexOf("\n    }", spendTimerStart));
assert.ok(
    spendTimerBody.includes("_firstRunSpendPending = false"),
    "the spend timer must resolve the pending state rather than only logging"
);
assert.ok(
    !spendTimerBody.includes("takeOverNotificationServer"),
    "the spend timer must fail CLOSED: an unconfirmed spend is a reason not to take over, never a reason to proceed"
);

// Clearing the pending state and stopping its timer must share an owner.
const endSpend = functionBody("_endFirstRunSpend");
assert.ok(
    endSpend.includes("_firstRunSpendPending = false") && endSpend.includes("firstRunSpendTimer.stop()"),
    "_endFirstRunSpend() must clear both halves of the confirmation state"
);
assert.equal(
    (resolveSpend.match(/_firstRunSpendPending\s*=/g) || []).length,
    0,
    "_resolveFirstRunSpend() must clear the confirmation through _endFirstRunSpend(), not by hand"
);

// Winning the bus name does not prove the helper saved an undo record.
// The success notice must also use the takeover result.

assert.ok(
    /stdout:\s*StdioCollector\s*\{[^}]*_applyTakeoverResult\(text\)/.test(
        source.slice(source.indexOf("id: takeoverProcess"))
    ),
    "the takeover reply must go through _applyTakeoverResult(), not straight to _applyServerOwnership()"
);

const takeoverResult = functionBody("_applyTakeoverResult");
assert.ok(
    /result\.ok\s*===\s*true/.test(takeoverResult),
    "_applyTakeoverResult() must check the helper's ok field; the bus name moving is a different claim"
);
assert.ok(
    /result\.restore\s*&&\s*result\.restore\.available/.test(takeoverResult),
    "_applyTakeoverResult() must read restore.available, which is how a lost undo record is told from any other failure"
);
assert.ok(
    takeoverResult.includes("_reportTakeoverFailure("),
    "a takeover that did not fully succeed must be reported, not left in the log"
);

// Read the balanced condition of the last preceding if statement.
// An identifier elsewhere in the prefix is not evidence that the condition checks it.
function governingCondition(body, index, what) {
    const ifIndex = body.lastIndexOf("if (", index);
    assert.ok(ifIndex >= 0, `${what} should be governed by an if statement`);
    const open = body.indexOf("(", ifIndex);
    let depth = 0;
    for (let i = open; i < body.length; i++) {
        if (body[i] === "(")
            depth += 1;
        else if (body[i] === ")") {
            depth -= 1;
            if (depth === 0)
                return body.slice(open + 1, i);
        }
    }
    assert.fail(`unbalanced condition governing ${what}`);
}


{
    const sample = 'if (alpha && beta) {\n    raise("thing");\n}';
    const condition = governingCondition(sample, sample.indexOf('"thing"'), "the sample");
    assert.equal(condition, "alpha && beta", "governingCondition() must return exactly the test");
}

const applyOwnership = functionBody("_applyServerOwnership");
const announceIndex = applyOwnership.indexOf('"notification-server-takeover"');
assert.ok(announceIndex > 0, "_applyServerOwnership() should raise the first-run announcement");
const announceCondition = governingCondition(applyOwnership, announceIndex, "the first-run announcement");
for (const flag of ["_takeoverReportedOk", "_takeoverRecordLost"]) {
    assert.ok(
        announceCondition.includes(flag),
        `the success announcement must be gated on ${flag} in the condition itself; ownership alone would announce success over a takeover that failed`
    );
}

// Restore can exit successfully without an undo record. That cannot prove a masked daemon was restored.
const reverse = functionBody("_reverseFirstRunTakeover");
const spawnIndex = reverse.indexOf("restoreProcess.running = true");
assert.ok(spawnIndex > 0, "_reverseFirstRunTakeover() should start the restore helper");
assert.ok(
    reverse.slice(0, spawnIndex).includes("_takeoverRecordLost"),
    "a takeover whose undo record was lost must be reported before the restore is spawned, not after it reports success over nothing"
);

// Helpers and probes can fail to answer. These waits need independent deadlines.
for (const [deadline, timer] of [
    ["_firstRunTakeoverDeadline", "firstRunTakeoverTimer"],
    ["_reverseAfterProbeDeadline", "reverseDeadlineTimer"]
]) {
    assert.ok(
        source.includes(`id: ${timer}`),
        `${timer} must exist to bound ${deadline}`
    );
    assert.ok(
        source.includes(`root.${deadline} = Date.now() +`),
        `${deadline} must be set from the wall clock, so a re-armed timer cannot extend it indefinitely`
    );
}

// A notice about a transient failure must clear when a retry succeeds.
// Derive raised categories from show calls so added categories enter the check.

// Read double-quoted literals, including empty strings and escapes.
// Skipping empty strings shifts quote pairing and can hide a category.
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
    quotedLiterals('f(tr("msg"), "", "category", x)'),
    ["msg", "", "category"],
    "an empty literal must not shift the pairing of the ones after it"
);
assert.deepEqual(
    quotedLiterals('a("say \\"hi\\" now", "next")'),
    ['say "hi" now', "next"],
    "an escaped quote must not end the literal"
);

const toastSource = stripComments(
    fs.readFileSync(path.join(repoRoot, "quickshell/vshell/Services/ToastService.qml"), "utf8")
);
const stickyMatch = toastSource.match(/readonly property var stickyCategories:\s*\[([^\]]*)\]/);
assert.ok(stickyMatch, "ToastService.qml should declare stickyCategories");
const stickyCategories = quotedLiterals(stickyMatch[1]).filter(value => value.length > 0);
assert.ok(stickyCategories.length > 0, "stickyCategories should not be empty");

// Derive categories from show calls; dismissal-only references are not raised categories.
const raised = new Set();
{
    const re = /ToastService\.show(?:Info|Warning|Error)\(/g;
    let match;
    while ((match = re.exec(source)) !== null) {
        const open = match.index + match[0].length - 1;
        let depth = 0;
        let end = -1;
        for (let i = open; i < source.length; i++) {
            if (source[i] === "(")
                depth += 1;
            else if (source[i] === ")") {
                depth -= 1;
                if (depth === 0) {
                    end = i;
                    break;
                }
            }
        }
        assert.ok(end > open, "unbalanced ToastService.show* call");
        for (const literal of quotedLiterals(source.slice(open, end)))
            raised.add(literal);
    }
}
assert.ok(raised.size > 0, "NotificationService.qml should raise at least one toast");

const stickyRaised = stickyCategories.filter(category => raised.has(category));
assert.ok(
    stickyRaised.length > 0,
    "this service should raise at least one sticky category, or the rule below checks nothing"
);
for (const category of stickyRaised) {
    assert.ok(
        source.includes(`dismissCategory("${category}")`),
        `${category} is sticky and raised here, so something must dismiss it when the state it describes ends -- otherwise it sits on screen contradicting reality`
    );
}

// Require dismissals in the functions that own the successful transitions.
assert.ok(
    functionBody("_applyTakeoverResult").includes('dismissCategory("notification-server-takeover-failed")'),
    "a takeover that reports ok must clear an earlier failure notice"
);
assert.ok(
    functionBody("_reportTakeoverFailure").includes('dismissCategory("notification-server-takeover")'),
    "a takeover failure must clear an earlier success announcement -- the mirror of the same bug"
);
assert.ok(
    functionBody("_applyRestoreResult").includes('dismissCategory("notification-server-restore")'),
    "a restore that succeeds must clear an earlier restore failure notice"
);

console.log(`notification takeover checks passed (${automaticTakeoverCalls.length} automatic takeover call site, ${stickyRaised.length} sticky categories with owners).`);
