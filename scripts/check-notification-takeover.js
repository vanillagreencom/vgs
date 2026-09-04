#!/usr/bin/env node

"use strict";

// VGS-64: the first-run notification takeover, pinned against its own source.
//
// This is the one subsystem in the shell that changes the user's system without
// being asked: it masks and stops whichever daemon holds
// org.freedesktop.Notifications. Every finding on it so far has been an
// ORDERING mistake rather than a logic error -- acting before a durable fact was
// established, or announcing an outcome the evidence did not support:
//
//   J1  acted on a settings.json that had not parsed
//   P1  acted on a one-shot whose write was never confirmed
//   P5  announced success over a takeover whose undo record was never saved
//
// qmllint cannot see any of that, the nested smoke never reaches the branch (a
// sandbox bus has no foreign daemon to take the name from), and exercising it
// for real means masking a live notification daemon. So the invariants are
// pinned here, against NotificationService.qml's own text. A missing line is the
// bug in every case, which is exactly what source-pinning catches.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.resolve(__dirname, "..");
const servicePath = path.join(repoRoot, "quickshell/vshell/Services/NotificationService.qml");
const rawSource = fs.readFileSync(servicePath, "utf8");

// --- read the CODE, never the commentary --------------------------------
//
// Every assertion below asks whether a name or a statement is present. Read
// against the raw file, a comment satisfies that question just as well as the
// code does -- and this file is heavily commented, precisely because the
// orderings it pins are subtle. The announcement guard was the live example:
// both flag names appear in the comment explaining the guard, so deleting the
// executable condition left the assertion passing.
//
// Comments are therefore blanked out first, everywhere, rather than worked
// around at each site. Characters are replaced with spaces instead of being
// deleted so offsets and line structure survive, which is what lets
// functionBody() keep matching on "\n    }".
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

// The file must actually BE commented for the above to be load-bearing; if the
// comments were ever stripped from the source itself, this check would quietly
// become equivalent to reading it raw.
assert.ok(
    rawSource.length > source.replace(/ +$/gm, "").length,
    "NotificationService.qml should carry comments; stripping is what keeps them out of these assertions"
);

// A QML function body, from its `function name(` to the closing brace at the
// singleton's own indentation. Same reader as scripts/test-toast-actions.js.
function functionBody(name) {
    const start = source.indexOf(`function ${name}(`);
    assert.ok(start >= 0, `NotificationService.qml should define ${name}()`);
    const end = source.indexOf("\n    }", start);
    assert.ok(end > start, `${name}() should be a closed function body`);
    return source.slice(start, end);
}

// Prove the reader can fail before anything it returns is used as evidence.
assert.throws(
    () => functionBody("thisFunctionDoesNotExist"),
    "functionBody() must fail on a name that is absent, or every assertion below is vacuous"
);

// --- P1: nothing is masked until the one-shot is confirmed on disk ----------
//
// SettingsData.set() updates the property and asks FileView to save; it does not
// confirm the save landed. On an unwritable settings.json the shell would read
// the one-shot as spent while the next process reads it unspent, and the
// "one-shot" would mask and stop the user's daemon on every start. The takeover
// therefore waits for a SEPARATE process to read the flag back
// (`status --json`'s vgsFirstRunTakeoverDone -> serverPersistedOneShotDone).

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
// Split at the write, because every gate's value is in which side of it they
// sit on. Asserting only that a name appears somewhere in the body passed with
// either of the two _isReadOnly checks deleted -- the same defect this file
// exists to catch, one level up.
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

// The confirmation cannot wait forever: an unspawnable probe produces no next
// answer, and an unbounded pending state is a takeover that never resolves.
assert.ok(
    /_firstRunSpendDeadline/.test(maybeTakeOver) && /_firstRunSpendDeadline/.test(resolveSpend),
    "the spend confirmation must be bounded by a deadline it both sets and checks"
);

// ...and that deadline needs a driver that does not depend on re-entry. A
// Process that fails to start emits no `exited` and produces no output (see
// quickshell/vshell/AGENTS.md), so nothing calls
// _applyServerOwnership(), nothing reaches _resolveFirstRunSpend(), and a
// deadline only checked on re-entry is never checked at all.
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

// One owner for clearing the confirmation, so no path can drop the flag and
// leave the timer armed, or stop the timer and leave the flag set.
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

// --- P5: ownership reaching "vgs" is not evidence the takeover succeeded -----
//
// The helper masks and stops the foreign daemon FIRST and writes the undo record
// LAST, so a record that cannot be saved leaves the daemon masked, the bus name
// won, and nothing to reverse it with. Reading only the ownership status would
// announce success over precisely that state.

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

// The success announcement must require the takeover's own verdict.
// The condition of the `if` that governs `index`, read as a balanced
// parenthesis so it is the executable test and nothing else. Searching the
// whole prefix for a name was the weaker form: it could not tell a condition
// from any earlier mention of the same identifier.
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

// Prove it reads the condition rather than its surroundings.
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

// --- the unreversible state is never described as reversible ----------------
//
// `restore` reads the undo record. With no record it reports "nothing to do" and
// exits 0, so running it and trusting the exit code would log a successful
// reversal while the user's daemon is still masked and stopped.
const reverse = functionBody("_reverseFirstRunTakeover");
const spawnIndex = reverse.indexOf("restoreProcess.running = true");
assert.ok(spawnIndex > 0, "_reverseFirstRunTakeover() should start the restore helper");
assert.ok(
    reverse.slice(0, spawnIndex).includes("_takeoverRecordLost"),
    "a takeover whose undo record was lost must be reported before the restore is spawned, not after it reports success over nothing"
);

// --- every unattended change has a bounded wait ------------------------------
//
// Each of these waits for something that may never arrive -- a helper that never
// exits, a probe that cannot be spawned, a write that never lands. An unbounded
// one is a state the user cannot get out of.
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

// --- every sticky message has an owner that clears it -----------------------
//
// Sticky was the right call for messages the user must not miss, but a sticky
// message about a TRANSIENT state needs something that takes it down when the
// state changes -- otherwise a retry that succeeds leaves "the takeover failed"
// on screen indefinitely, saying the opposite of what is true.
//
// Asserted as a rule over every sticky category this service raises, rather
// than for the two that prompted it, because the next one added would have the
// same hole and nothing would notice.

// Every double-quoted literal in `text`, scanned rather than matched.
//
// The obvious /"([^"]+)"/g is wrong here and fails SILENTLY: `+` cannot match
// the empty `command` argument these calls pass (`"", "category"`), so that
// quote goes unpaired, every later pair shifts by one, and the category is
// swallowed into a "literal" that spans the code between two real strings. The
// first version of this rule inspected one category instead of three and still
// reported success -- an under-count, which is the quietest way for a check to
// stop checking.
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

// Prove the scanner on the shapes that broke the regex.
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

// Categories this service RAISES, read from the show calls themselves so a
// category mentioned only in a dismissal is not mistaken for one that is shown.
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

// The two specific transitions that prompted the rule, pinned on the functions
// that own them so a dismissal moving somewhere useless still fails.
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
