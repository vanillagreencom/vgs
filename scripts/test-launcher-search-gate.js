#!/usr/bin/env node

// Pins the launcher search gate: which tool each search kind needs, what the
// overview does while nobody knows, and what its empty state then says
// (VGS-114). The bug this closes was one boolean answering for two backends —
// `dsearchAvailable = fdAvailable` — so a machine with ripgrep and no fd lost
// TEXT search too, silently and with no empty state to explain it.
//
// Nothing else covers this code: `scripts/qml-smoke.sh --nested` never opens the
// overview search surface, and qmllint cannot see a gate asking about the wrong
// tool. So the decisions are extracted verbatim from the shipped QML between its
// markers and executed here, and the wiring around them is pinned as source.
//
// WHERE THE SEAM IS, and why it moved twice. A first version executed the pure
// regions and pinned everything AROUND them by presence of a token; a mutation
// run killed 1 of 10, because a mutant that keeps the token and removes the
// behavior walks past a presence check. So the composition moved INTO the
// regions — backendStateFor and canDispatchFor over one named snapshot,
// fileSearchQueryFrom, shouldRetryAfterProbe, fileLegActive, probeSettled,
// probeFailureOutcome, errorLine — leaving exactly one adapter line per
// decision, of which _probeSnapshot() is the only place a QML property becomes
// a field. A second run then killed 19 of 26: the CONSUMERS of the view's facts
// were pinned and their PRODUCERS were not, so the seam had merely moved a line
// up. Both halves are pinned now, and what has to stay a QML binding is pinned
// by ORDER and BRANCH — the full argument list of a call, a statement's
// position relative to the `return` after it, the block a call sits inside.
// Section 4's `pathBranch < fdLookup` was the model.
//
// Every assertion over the view's facts uses a combination the program can
// actually build; see the note on `facts` in section 7. A control satisfied only
// by an impossible input covers nothing, and one such control hid a dangling
// hint on the first open of every machine.
//
// MUST-FAIL CONTROLS, each seen red, applied one at a time to the shipped tree.
// In-region: an inverted ternary in the command table; an inverted unknown arm
// in dispatchAllowed; a disabled "/" branch in fileSearchQueryFrom; the
// prompt/checking and missing/error arm orders swapped. Across the seam: a
// field of _probeSnapshot() assigned from the wrong property (the original
// VGS-114 symptom, and now the only way left to express it); canDispatch
// reduced to a bare equality; the three ResultsList producer bindings mutated —
// kind and query transposed, a negation dropped, a command hardcoded; a fact
// carrying the backend state where the probe state belongs; the retry predicate
// inverted; ensureStatus() moved to the launcher-CLOSED branch with the opened
// branch left in place, and its condition narrowed back; a `return` hoisted
// above the stale-result clear; the fileSearchError capture and its reset
// deleted; the fallback conjunct dropped from search()'s refusal; _fileLegActive
// hardcoded false; the single-flight guard moved below the budget reset; the
// generation check moved below the in-flight reset and made to fall through
// instead of return; the retrying state never published; statusState declared
// "ready"; helperHasFallback restated instead of derived; the argv terminator
// and joined values reverted in either file. Plus the pre-fix sources, both the
// `isFileSearching = ... && DSearchService.dsearchAvailable` form and the
// `if (!DSearchService.dsearchAvailable) return;` form.

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.join(__dirname, "..");
const SERVICE = path.join(repoRoot, "quickshell", "vshell", "Services", "DSearchService.qml");
const OVERVIEW = path.join(repoRoot, "quickshell", "vshell", "Modules", "WorkspaceOverlays", "OverviewSearch");
const CONTROLLER = path.join(OVERVIEW, "Controller.qml");
const RESULTS = path.join(OVERVIEW, "ResultsList.qml");
const MENU = path.join(repoRoot, "config", "vshell", "plugins", "vgsMenu", "VGSMenu.qml");
const HELPER = path.join(repoRoot, "bin", "vshell-helper");

const serviceSource = fs.readFileSync(SERVICE, "utf8");
const controllerSource = fs.readFileSync(CONTROLLER, "utf8");
const resultsSource = fs.readFileSync(RESULTS, "utf8");
const menuSource = fs.readFileSync(MENU, "utf8");
const helperSource = fs.readFileSync(HELPER, "utf8");

// This text comes from repo files and is EXECUTED here, so it runs inside a
// child bounded by a wall clock — scripts/lib/qml-region.js says what
// that bounds and what it does not.
const { evaluateMarked, regionOf, guardChild } = require("./lib/qml-region.js");
const qmlSource = require("./lib/qml-source.js");
const { stripComments } = qmlSource;

// Returns only in the child; the parent exits with its status.
guardChild();

// Prove the reader before it reads anything: that a token surviving only in a
// comment pins nothing. The guard's own self-test is a separate manifest row —
// it cannot run inside a guarded suite and still report a broken guard.
qmlSource.selfTest();

const backend = evaluateMarked(serviceSource, "SEARCH BACKEND DECISION", [
    "backendCommandFor", "kindForType", "pathCompletion", "queryIsDispatchable",
    "queryIsSearchable", "backendStateFor", "dispatchAllowed", "helperHasFallback",
    "serviceRefuses", "canDispatchFor", "probeSettled", "probeFailureOutcome"
], "DSearchService.qml");

const view = evaluateMarked(resultsSource, "EMPTY STATE DECISION", [
    "fileEmptyStateKey", "fileHintKey", "fileEmptyIcon", "fileLegActive", "errorLine"
], "ResultsList.qml");

const files = evaluateMarked(controllerSource, "FILE SEARCH DECISION", [
    "fileSearchQueryFrom", "shouldRetryAfterProbe"
], "Controller.qml");

// The extracted regions must be free of QML, or this harness tests something the
// shell does not run.
for (const [label, source, marker] of [
    ["DSearchService.qml", serviceSource, "SEARCH BACKEND DECISION"],
    ["ResultsList.qml", resultsSource, "EMPTY STATE DECISION"],
    ["Controller.qml", controllerSource, "FILE SEARCH DECISION"]
]) {
    const region = regionOf(source, marker, label);
    for (const forbidden of ["root.", "Theme.", "I18n.", "Qt."]) {
        assert.ok(!region.includes(forbidden),
            `the ${marker} block in ${label} must not reference ${forbidden} — it has to stay ` +
            "plain JavaScript, or the extraction is testing a different program");
    }
}

const ready = (fd, rg) => ({ state: "ready", fd: fd, ripgrep: rg });

// One Python function's text, BOUNDED at the next top-level `def`. A slice that
// only knows where it starts runs to EOF, and an assertion looking for a token
// anywhere in it is then satisfied by an unrelated line hundreds of lines later:
// that is how `raise RuntimeError(` stayed green with the raise it names
// replaced by `pass`. Nested defs are indented, so they do not end the slice.
function pythonFunction(source, name) {
    const start = source.indexOf(`def ${name}(`);
    assert.notEqual(start, -1, `bin/vshell-helper must define ${name}()`);
    const end = source.indexOf("\ndef ", start + 1);
    return source.slice(start, end === -1 ? source.length : end);
}

// --- 1. each kind names its own tool ----------------------------------------
//
// The whole defect in one table: text follows ripgrep, name search follows fd,
// and neither may answer for the other.

assert.equal(backend.backendCommandFor("text"), "rg");
for (const kind of ["files", "folders", "all"])
    assert.equal(backend.backendCommandFor(kind), "fd", `${kind} is fd's`);

// An unlisted kind must NOT inherit fd by falling through — "zoxide" is a real
// kind this service does not probe, and a typo is not fd's either.
for (const kind of ["zoxide", "sqlite", "", undefined, null])
    assert.equal(backend.backendCommandFor(kind), "",
        `${JSON.stringify(kind)} names no probed tool, so the gate must not answer for it`);

// --- 2. every flag combination, both kinds ----------------------------------
//
// Independently, all four ways round: the inverted ternary this suite's control
// run plants keeps every token in place and only fails here.

for (const [fd, rg] of [[true, true], [true, false], [false, true], [false, false]]) {
    const probe = ready(fd, rg);
    assert.equal(backend.backendStateFor("text", "needle", probe), rg ? "available" : "missing",
        `text search follows ripgrep alone (fd=${fd}, rg=${rg})`);
    for (const kind of ["files", "folders", "all"]) {
        assert.equal(backend.backendStateFor(kind, "needle", probe), fd ? "available" : "missing",
            `${kind} follows fd alone (fd=${fd}, rg=${rg})`);
    }
}

// The regression in its exact shape: ripgrep installed, fd missing.
assert.equal(backend.backendStateFor("text", "needle", ready(false, true)), "available",
    "ripgrep-backed text search must survive a machine with no fd — this is the bug");
assert.equal(backend.backendStateFor("files", "needle", ready(false, true)), "missing",
    "while file search on the same machine is honestly reported missing");

// --- 3. unknown is never read as missing ------------------------------------

for (const probe of [{ state: "pending" }, { state: "pending", fd: true, ripgrep: true }]) {
    for (const kind of ["files", "folders", "all", "text"]) {
        assert.equal(backend.backendStateFor(kind, "needle", probe), "checking",
            "a probe that has not answered means CHECKING, not missing: telling a user to " +
            "install a tool they already have is the same dead end as saying nothing");
    }
}
for (const probe of [{ state: "failed" }, {}, null, undefined, { state: "nonsense" }]) {
    assert.equal(backend.backendStateFor("files", "needle", probe), "unknown",
        `a probe in state ${JSON.stringify(probe)} answers nothing about fd`);
}
assert.equal(backend.backendStateFor("zoxide", "needle", ready(true, true)), "unknown",
    "a kind this service never probes stays unknown even with both tools present");

// The rule at its own entry point, WITH the kind — dispatchAllowed answers
// differently per kind, so calling it with a state alone leaves `kind`
// undefined and every case falls through the no-fallback arm by accident.
//
// A proven-missing tool blocks. An unanswered probe blocks only where
// dispatching would silently buy the helper's full directory walk: ripgrep
// fails fast with a real cause, so text goes; an fd-backed name search does not,
// because taking that walk on nobody's answer is exactly what the overview
// declines.
for (const kind of ["files", "text"]) {
    assert.ok(backend.dispatchAllowed("available", kind),
        `a tool proven present dispatches (${kind})`);
    assert.ok(!backend.dispatchAllowed("missing", kind),
        `a tool proven absent does block it (${kind})`);
    assert.ok(!backend.dispatchAllowed("checking", kind),
        `and a pending answer waits rather than guessing (${kind})`);
}
assert.ok(backend.dispatchAllowed("unknown", "text"),
    "an unanswerable probe still dispatches text search: ripgrep fails fast with a real cause, " +
    "so refusing it would be a silence built on nobody's answer");
assert.ok(!backend.dispatchAllowed("unknown", "files"),
    "and does NOT dispatch an fd-backed name search: that buys the helper's full walk of every " +
    "root, which is the cost the fd gate exists to avoid and the recorded decision rejected");
assert.ok(!backend.dispatchAllowed("unknown", "folders"),
    "same for folders — a path completion reaches 'available' earlier, never this arm");

// --- 4. folder path completion is not fd's ----------------------------------
//
// bin/vshell-helper answers a folder query that starts at a path from its own
// directory walk, BEFORE fd is consulted, so gating it on fd would take away a
// capability the implementation still has.

for (const query of ["~/dev", "~", "/home/x", "  ~/dev", "/"])
    assert.ok(backend.pathCompletion("folders", query),
        `${JSON.stringify(query)} is a folder path query, answered without fd`);
for (const [kind, query] of [["folders", "dev"], ["files", "~/dev"], ["text", "~/dev"], ["folders", ""]])
    assert.ok(!backend.pathCompletion(kind, query),
        `${kind}/${JSON.stringify(query)} is an ordinary search, which does need its tool`);
assert.equal(backend.backendStateFor("folders", "~/dev", ready(false, false)), "available",
    "so folder completion stays available on a machine with neither tool");
assert.equal(backend.backendStateFor("folders", "dev", ready(false, false)), "missing",
    "while a name search for the same kind is not");

// The exemption mirrors a branch in another file, so pin that branch: if the
// helper stops answering path queries before it looks for fd, the QML above
// starts promising a capability that is gone.
{
    const nameHits = pythonFunction(helperSource, "_launcher_search_name_hits");
    const pathBranch = nameHits.indexOf('if kind == "folders" and query.strip().startswith(("~", "/")):');
    const fdLookup = nameHits.indexOf('shutil.which("fd")');
    assert.notEqual(pathBranch, -1,
        "the helper must still route a folder path query to its own walk, on the same condition " +
        "DSearchService.pathCompletion() mirrors");
    assert.notEqual(fdLookup, -1, "and must still be the place fd is looked up");
    assert.ok(pathBranch < fdLookup,
        "the path branch has to come FIRST, or the exemption is promising fd-free completion " +
        "from a code path that does need fd");
}

// --- 5. text has no fallback, name search does ------------------------------

assert.ok(!backend.helperHasFallback("text"),
    "text search shells out to ripgrep and raises without it — the service refuses it outright");
for (const kind of ["files", "folders", "all"])
    assert.ok(backend.helperHasFallback(kind),
        `${kind} falls back to the helper's own walk, which vgsMenu accepts`);

// --- 6. the chips map to kinds in one place ---------------------------------

assert.equal(backend.kindForType("dir"), "folders");
assert.equal(backend.kindForType("text"), "text");
assert.equal(backend.kindForType("zoxide"), "zoxide");
for (const type of ["file", "all", "", undefined, "nonsense"])
    assert.equal(backend.kindForType(type), "files",
        `${JSON.stringify(type)} is a name search`);

// --- 7. the empty state matrix ----------------------------------------------
//
// The decisions read NAMED FIELDS, so a fact cannot arrive in the wrong slot;
// what the view builds is pinned verbatim in section 8b.

// EVERY combination below is one the program can actually produce. That is not
// decoration: `declined` defaults false, and a missing or checking backend state
// with a searchable query ALWAYS declines — so an assertion that leaves the
// default there is satisfied by an input the shell cannot build, and stops
// covering the arm it names. Each case sets declined explicitly where the state
// implies it.
const facts = extra => Object.assign({
    backendState: "available",
    missingCommand: "",
    probeState: "ready",
    queryLength: 5,
    searchable: true,
    declined: false,
    searchError: "",
    legActive: true
}, extra);
const declinedFacts = extra => facts(Object.assign({ declined: true }, extra));

assert.equal(view.fileEmptyStateKey(declinedFacts({ backendState: "checking" })), "checking",
    "a probe still running says so rather than claiming search is unavailable — and this is the " +
    "real startup state: the first probe declines every kind, so `declined` is true here");
assert.equal(view.fileEmptyStateKey(declinedFacts({ backendState: "missing", missingCommand: "rg" })),
    "missing-rg");
assert.equal(view.fileEmptyStateKey(declinedFacts({ backendState: "missing", missingCommand: "fd" })),
    "missing-fd");
assert.equal(view.fileEmptyStateKey(facts({ queryLength: 0, searchable: false })), "prompt");
assert.equal(view.fileEmptyStateKey(facts({ queryLength: 1, searchable: false })), "short");
assert.equal(view.fileEmptyStateKey(facts({})), "empty");
assert.equal(view.fileEmptyStateKey(facts({ backendState: "unknown" })), "empty",
    "an unanswerable probe does not rewrite the result message — the search still ran");
assert.equal(view.fileEmptyStateKey(declinedFacts({
    backendState: "missing", missingCommand: "fd", queryLength: 0, searchable: false
})), "missing-fd", "and a missing tool is worth saying before a query is typed");
assert.equal(view.fileEmptyStateKey(facts({ searchError: "ripgrep is required for text search" })),
    "error",
    "a search that RAN and failed shows the helper's own diagnosis rather than 'no results'");
assert.equal(view.fileEmptyStateKey(declinedFacts({ backendState: "unknown" })), "unchecked",
    "and one the gate refused says that instead");

// ARM ORDER, with both arms true at once — one field per assertion cannot see
// a reordering, and both of these reorderings pass every assertion above.
assert.equal(view.fileEmptyStateKey(declinedFacts({
    backendState: "missing", missingCommand: "fd", searchError: "boom"
})), "missing-fd",
    "a missing tool outranks a leftover error: the tool is why the next search will fail too");
assert.equal(view.fileEmptyStateKey(declinedFacts({ backendState: "checking" })), "checking",
    "and a probe still running outranks declined — during the first probe EVERY kind is " +
    "declined, so the other order makes the startup window say the tools could not be checked " +
    "while they are being checked");

assert.equal(view.fileHintKey(declinedFacts({ backendState: "missing", missingCommand: "rg" })),
    "install-rg");
assert.equal(view.fileHintKey(declinedFacts({ backendState: "missing", missingCommand: "fd" })),
    "install-fd");
assert.equal(view.fileHintKey(declinedFacts({ backendState: "unknown", probeState: "failed" })),
    "probe-failed",
    "a probe that could not run names ITSELF; blaming fd for it is the wrong cause");
assert.equal(view.fileHintKey(declinedFacts({ backendState: "unknown", probeState: "retrying" })),
    "probe-retrying",
    "a retry in progress asks the user for NOTHING — it will answer on its own, and the reopen " +
    "advice is a no-op while an episode is in flight");
assert.equal(view.fileHintKey(facts({ backendState: "unknown", probeState: "failed" })), "",
    "no probe line beside a search that actually ran, whatever the probe did");
// THE STARTUP WINDOW, as the program produces it: first probe outstanding, two
// characters typed, so the query is searchable and therefore declined. The
// same case with declined:false is unreachable, and pinning that instead left
// this silent — the hint rendered "Still checking ...: " with a dangling colon
// and no reason, under a message already saying "Checking search tools".
assert.equal(view.fileHintKey(declinedFacts({ backendState: "checking", probeState: "pending" })), "",
    "the first probe reports NOTHING: there is no reason yet, and the message above already " +
    "says the tools are being checked");
assert.equal(view.fileHintKey(facts({})), "",
    "and a working backend needs no install step");
for (const extra of [{ backendState: "missing", missingCommand: "fd" },
    { backendState: "unknown", probeState: "failed" }]) {
    assert.equal(view.fileHintKey(facts(Object.assign({ legActive: false }, extra))), "",
        "no hint where no file search would have run: 'install fd' in a mode that never searches " +
        "files promises a fix that changes nothing");
}

assert.equal(view.fileEmptyIcon("checking", "file"), "hourglass_empty");
assert.equal(view.fileEmptyIcon("missing-fd", "file"), "search_off");
assert.equal(view.fileEmptyIcon("missing-rg", "text"), "search_off");
assert.equal(view.fileEmptyIcon("unchecked", "file"), "search_off");
assert.equal(view.fileEmptyIcon("error", "file"), "search_off");
assert.equal(view.fileEmptyIcon("empty", "file"), "insert_drive_file");
assert.equal(view.fileEmptyIcon("empty", "dir"), "folder_open");
assert.equal(view.fileEmptyIcon("empty", "text"), "article");

// The prompt comes first: nothing is being checked on the user's behalf before a
// query that could dispatch, and a query too short to dispatch is not declined.
assert.equal(view.fileEmptyStateKey(facts({
    backendState: "checking", queryLength: 0, searchable: false
})), "prompt", "an empty field prompts even while the probe is outstanding");
assert.equal(view.fileEmptyStateKey(facts({
    backendState: "checking", queryLength: 1, searchable: false
})), "short", "and a short query is short, not checking");

// The helper's text, made safe to put on screen.
assert.equal(view.errorLine("ripgrep is required for text search"),
    "ripgrep is required for text search", "an ordinary diagnosis passes through");
assert.equal(view.errorLine("usage: vshell launcher-search\n  --kind\n  --limit"),
    "usage: vshell launcher-search",
    "only the FIRST line: an argparse failure is a six-line usage block");
assert.equal(view.errorLine("no such file: we\u0007ird\u202ename"), "no such file: we ird name",
    "control and bidi characters are dropped — a filename out of the search roots ends up here");
assert.equal(view.errorLine("x".repeat(400)).length, 160,
    "and the length is bounded, so a whole argv cannot stretch the centered column");
assert.equal(view.errorLine(""), "");
assert.equal(view.errorLine(null), "");

// --- 7b. the file-search leg, and the query it would send -------------------

assert.equal(files.fileSearchQueryFrom("plugins", "/etc", "etc"), "",
    "plugins mode runs no file search: a leading / is the plugin's own text there, and a " +
    "file result appended to plugin results is the regression this exclusion exists for");
assert.equal(files.fileSearchQueryFrom("files", "notes", ""), "notes");
assert.equal(files.fileSearchQueryFrom("files", "  notes  ", ""), "notes", "trimmed");
assert.equal(files.fileSearchQueryFrom("all", "/notes", "notes"), "notes",
    "the / form drops its prefix and searches from any non-plugins mode");
assert.equal(files.fileSearchQueryFrom("files", "/d notes", "notes"), "notes",
    "including the typed-type form, whose parsed query is what arrives");

// The counter-example the docs got wrong once: the BARE "/" is consumed as the
// launcher's trigger, but "/d " consumes only itself, so an absolute path
// survives and reaches the helper's fd-free path completion.
assert.equal(files.fileSearchQueryFrom("files", "/d /home/x", "/home/x"), "/home/x",
    "the typed-type prefix passes a /-rooted query through intact");
assert.ok(backend.pathCompletion("folders", files.fileSearchQueryFrom("files", "/d /home/x", "/home/x")),
    "so absolute-path folder completion IS reachable from the overview — the manifest and the " +
    "pathCompletion comment may not narrow the claim to ~-rooted queries again");
assert.equal(backend.canDispatchFor("folders", "/home/x", { state: "ready", fd: false, ripgrep: false }),
    true, "and it dispatches with no tools at all, which is what makes it worth documenting");
assert.equal(files.fileSearchQueryFrom("all", "notes", ""), "",
    "combined mode without the prefix sends nothing — the files-in-All settings reach no " +
    "search today, which is why this must not silently look like one");
assert.equal(files.fileSearchQueryFrom("apps", "notes", ""), "");
assert.equal(files.fileSearchQueryFrom("files", "", ""), "");

assert.ok(files.shouldRetryAfterProbe(true, true),
    "an open surface with a searchable query re-runs when the probe answers");
assert.ok(!files.shouldRetryAfterProbe(false, true),
    "a closed one does not — the retry must not search behind a dismissed launcher");
assert.ok(!files.shouldRetryAfterProbe(true, false), "nor one whose query would not dispatch");

assert.ok(view.fileLegActive("files", false),
    "files mode is a file surface even before a query is typed");
assert.ok(view.fileLegActive("all", true), "and so is any mode holding a searchable file query");
assert.ok(!view.fileLegActive("plugins", false), "plugins mode is not");
assert.ok(!view.fileLegActive("apps", false), "nor is a mode with a query too short to dispatch");

// The one owner of "long enough to search", which those two now read instead of
// carrying their own literal.
assert.ok(backend.queryIsDispatchable("ab"), "two characters dispatch");
assert.ok(backend.queryIsDispatchable("  ab  "), "after trimming");
for (const query of ["a", " a ", "", " ", undefined, null])
    assert.ok(!backend.queryIsDispatchable(query), `${JSON.stringify(query)} does not`);

// And the kind-aware companion every launcher gate actually reads. "~" and "/"
// are one character AND the first keystroke of a path the helper completes
// without fd, so the length rule alone refused the capability pathCompletion
// exists to allow and the surface said "type at least two characters" for a
// query the helper answers.
for (const query of ["~", "/", "~/", "  ~  "])
    assert.ok(backend.queryIsSearchable("folders", query),
        `${JSON.stringify(query)} in folders mode is a path the helper completes, not a short query`);
assert.ok(backend.queryIsSearchable("folders", "de"), "an ordinary folder query still qualifies");
for (const [kind, query] of [["files", "~"], ["files", "/"], ["text", "~"], ["folders", "d"],
    ["folders", ""], ["folders", " "]]) {
    assert.ok(!backend.queryIsSearchable(kind, query),
        `${kind}/${JSON.stringify(query)} is genuinely too short — the exemption is folders-only, ` +
        "and only for a path");
}
assert.equal(backend.queryIsSearchable("folders", "~"), backend.pathCompletion("folders", "~"),
    "the exemption IS pathCompletion, not a second copy of it");

// --- 7c. the whole dispatch matrix, over the named snapshot -----------------
//
// One entry point per decision, each reading { state, fd, ripgrep } by name, so
// a transposed pair is not expressible at a call site — it would have to be
// written `fd: ripgrepAvailable`, which is legible in review. What the QML
// builds is pinned verbatim in section 8.

const probe = (state, fd, ripgrep) => ({ state: state, fd: fd, ripgrep: ripgrep });

assert.equal(backend.backendStateFor("text", "needle", probe("ready", false, true)), "available",
    "text follows the ripgrep field");
assert.equal(backend.backendStateFor("text", "needle", probe("ready", true, false)), "missing",
    "and NOT the fd field — reading the wrong one is the original VGS-114 symptom exactly");
assert.equal(backend.backendStateFor("files", "needle", probe("ready", true, false)), "available",
    "name search follows the fd field");
assert.equal(backend.backendStateFor("files", "needle", probe("retrying", true, true)), "unknown",
    "a retry episode answers nothing about the tools, whatever the last flags said");

// kind and query are not interchangeable either: swapped, backendCommandFor
// would see a query string, answer "" and leave every state permanently unknown.
assert.notEqual(backend.backendStateFor("folders", "~/dev", probe("ready", false, false)),
    backend.backendStateFor("~/dev", "folders", probe("ready", false, false)),
    "backendStateFor's kind and query slots must not be symmetric");

for (const [fd, rg] of [[true, true], [true, false], [false, true], [false, false]]) {
    for (const state of ["pending", "retrying", "failed", "ready"]) {
        const settled = state === "ready";
        assert.equal(backend.canDispatchFor("files", "needle", probe(state, fd, rg)), settled && fd,
            `a name search dispatches only on a positively detected fd (state=${state}, ` +
            `fd=${fd}, rg=${rg}) — dispatching it unproven buys the helper's full directory walk`);
        assert.equal(backend.canDispatchFor("text", "needle", probe(state, fd, rg)),
            settled ? rg : state !== "pending",
            `text dispatches on ripgrep when known, and on anything past the first probe when ` +
            `not (state=${state}, fd=${fd}, rg=${rg})`);
        assert.equal(backend.canDispatchFor("folders", "~/dev", probe(state, fd, rg)), true,
            "and path completion always dispatches: the helper answers it before fd is consulted");
    }
}

// A failed probe never demotes a successful one. Re-probing runs on every open
// of a machine missing a tool, so one slow re-probe replacing "ready" would
// refuse name search and blame tools that were found seconds earlier.
{
    const kept = backend.probeFailureOutcome("ready", 1, 3);
    assert.equal(kept.state, "ready",
        "a re-probe that fails leaves the previous successful answer standing");
    assert.equal(kept.publishReason, false,
        "and does not overwrite its reason with this failure's");
    assert.ok(kept.retry, "while the retry still runs in the background");
    assert.equal(backend.probeFailureOutcome("ready", 3, 3).state, "ready",
        "even once the retries are spent: the earlier answer is still the best one we have");

    assert.equal(backend.probeFailureOutcome("pending", 1, 3).state, "retrying",
        "with no earlier answer, the first failure publishes retrying");
    assert.equal(backend.probeFailureOutcome("retrying", 3, 3).state, "failed",
        "and the last one gives up");
    assert.ok(backend.probeFailureOutcome("pending", 1, 3).publishReason,
        "those two do publish the reason, since there is nothing better to show");
    assert.ok(!backend.probeFailureOutcome("retrying", 3, 3).retry, "and stop retrying");
}

// A settled answer is the only one worth leaving alone. "ready" with a tool
// missing is exactly the state the install instruction is given from, so it must
// NOT count as settled — otherwise installing fd changes nothing until restart.
assert.ok(backend.probeSettled(probe("ready", true, true)), "everything found and answered");
assert.ok(!backend.probeSettled(probe("ready", false, true)),
    "ready with fd missing is the state we tell the user to act on: re-probe it, or the product " +
    "ignores its own instruction");
assert.ok(!backend.probeSettled(probe("ready", true, false)), "same for ripgrep");
for (const state of ["pending", "retrying", "failed"])
    assert.ok(!backend.probeSettled(probe(state, true, true)),
        `${state} is not an answer at all`);
assert.ok(!backend.probeSettled(null), "and neither is nothing");

// The service's own refusal is narrower than the overview's gate, on purpose:
// vgsMenu still reaches the walk.
assert.ok(backend.serviceRefuses("text", "missing"), "text has no fallback, so the service refuses");
for (const kind of ["files", "folders", "all"])
    assert.ok(!backend.serviceRefuses(kind, "missing"),
        `${kind} still reaches the helper's walk from the service — vgsMenu depends on it`);
for (const state of ["available", "unknown", "checking"])
    assert.ok(!backend.serviceRefuses("text", state),
        `the service refuses only a PROVEN missing tool, not ${state}`);

// --- 8. the adapters: full argument lists, in order -------------------------
//
// Each of these is the ONE line between an executed decision and the properties
// feeding it, so the pin is the whole call with its arguments in their slots. A
// presence check would pass with two of them swapped, which is how the original
// bug reads at runtime.

{
    const q = qmlSource(serviceSource, "DSearchService.qml");

    q.requires(q.body("_probeSnapshot"), "_probeSnapshot()", [
        ["return { state: statusState, fd: fdAvailable, ripgrep: ripgrepAvailable };",
            "the ONE place a property becomes a field. `fd: ripgrepAvailable` here reinstates " +
            "VGS-114 exactly — ripgrep installed, text search reported missing — and unlike a " +
            "transposed positional argument it is legible on sight"]
    ]);

    q.requires(q.body("backendState"), "backendState()", [
        ["return backendStateFor(kind, query, _probeSnapshot());",
            "kind before query, and the snapshot whole"]
    ]);

    q.requires(q.body("canDispatch"), "canDispatch()", [
        ["return canDispatchFor(kind, query, _probeSnapshot());",
            "the gate is the composed rule, kind and all. Reduced to a bare equality it stops " +
            "dispatching in the unknown state, which is the fail-closed dead end this PR removes"]
    ]);

    q.requires(q.body("ensureStatus"), "ensureStatus()", [
        ["if (!probeSettled(_probeSnapshot())) rediscover();",
            "the exact condition, so it cannot be widened into a re-probe on every open nor " +
            "narrowed back to the failed-only form that ignores our own install instruction"]
    ]);

    q.requires(q.body("search"), "search()", [
        ["if (serviceRefuses(kind, backendState(kind, query)))",
            "the service's refusal is the composed one: without it a name search whose fd is " +
            "missing would be refused here too, taking the helper walk away from vgsMenu"]
    ]);

    // The declared initial value is part of the contract: started at "ready",
    // the startup window tells a machine that HAS fd to install it.
    assert.ok(qmlSource.flat(stripComments(serviceSource))
        .includes('property string statusState: "pending"'),
        "statusState must START pending — before the first probe answers, nothing is known, and " +
        "any other initial value is a claim about tools nobody has looked for yet");

    // The argv builders: user text goes behind "--" or into a joined
    // "--flag=value", never into a slot argparse can read as an option name.
    for (const [fn, why] of [
        ["search", "a query starting with '-' must search, not die in argparse"],
        ["preview", "and so must a path"]
    ]) {
        const body = q.body(fn);
        const terminator = body.lastIndexOf('args.push("--", ');
        const dispatched = body.indexOf("Proc.runCommand(");
        assert.notEqual(terminator, -1, `${fn}() must terminate its options with a bare "--" — ${why}`);
        assert.ok(terminator < dispatched,
            `${fn}() must push the terminator BEFORE it runs the command`);
        const opened = body.indexOf("const args = [");
        assert.notEqual(opened, -1, `${fn}() must build its argv in one array`);
        const literal = stripComments(body.slice(opened, body.indexOf("];", opened)));
        assert.ok(!/\b(query|path)\b/.test(literal),
            `${fn}()'s initial argv literal must not carry the user's ${fn === "search" ? "query" : "path"}: ` +
            "in the leading positional slot a dash-leading value is read as an option name");
    }
    q.requires(q.body("preview"), "preview()", [
        ['args.push("--query=" + String(query));',
            "the highlight query is joined to its flag: separated, a '-n' search hit renders " +
            "'Preview unavailable' instead of the file"]
    ]);
    q.requires(q.body("_appendListArgs"), "_appendListArgs()", [
        ['args.push(flag + "=" + value);',
            "same for configured roots and ignores, which are user-editable settings"]
    ]);
}

{
    const q = qmlSource(controllerSource, "Controller.qml");

    q.requires(q.body("fileSearchQuery"), "fileSearchQuery()", [
        ['return fileSearchQueryFrom(searchMode, searchQuery, Utils.parseFileSearchPrefix(searchQuery)?.query ?? "");',
            "the mode, the raw query and the PARSED prefix, each in its own slot, and no logic " +
            "of its own — this is the one authority every other predicate reads, and anything " +
            "decided on this side of the seam is invisible to the executed region"]
    ]);

    q.requires(q.body("performFileSearch"), "performFileSearch()", [
        ["var kind = fileSearchKind()", "the kind is decided once, by the shared accessor"],
        ["var fileQuery = fileSearchQuery()", "and the query comes from the one authority"],
        ["if (!DSearchService.queryIsSearchable(kind, fileQuery))",
            "and the searchable rule from the one owner, WITH the kind: the length rule alone " +
            "returns before canDispatch is ever consulted, so a one-character path like ~ never " +
            "reaches the fd-free completion the manifest advertises"],
        ["DSearchService.canDispatch(kind, fileQuery)",
            "and the gate asks about THAT kind, with the query the search will send"],
        ["_applyFileSearchResults([], effectiveType)",
            "BOTH ways a search ends with nothing clear the previous kind's hits — the gate " +
            "declining it and the search failing", 2],
        ["fileSearchError = response.error;",
            "the helper's diagnosis is CAPTURED. Every other pin for this feature — the executed " +
            "arm, the facts field, the case in getEmptyText — is satisfied with this one line " +
            "deleted, and then the fact is never non-empty and the whole feature is gone"],
        ['fileSearchError = "";',
            "and cleared on both paths that supersede it: the declined gate and a fresh " +
            "dispatch. Without the dispatch reset the previous failure's text sits under the " +
            "next search's empty result", 2],
        ["var generation = ++_fileSearchGeneration;",
            "a controller-side generation, because DSearchService versions per KIND: a files " +
            "answer still lands after the chip switched to text"],
        ["_supersedeFileSearch();",
            "BOTH abandon paths supersede what is in flight: the declined gate, whose answer " +
            "would otherwise land on the empty state explaining the refusal, and the " +
            "sub-threshold return, where nothing dispatches to supersede it — deleting 'docs' " +
            "back to 'd' then repaints the 'docs' hits for a query that no longer exists", 2],
        ["if (generation !== root._fileSearchGeneration) return;",
            "checked in the callback, so a stale answer neither overwrites the current kind's " +
            "results nor attributes its error to them"]
    ]);

    // BRANCH, not count: two supersedes in the declined block would satisfy the
    // occurrence count above while the sub-threshold return abandons a search
    // without superseding it — which is the defect, with the count still green.
    for (const [landmark, what, why] of [
        ["if (!DSearchService.queryIsSearchable(kind, fileQuery))", "the sub-threshold return",
            "nothing dispatches for a query this short, so nothing else supersedes the last one"],
        ["if (!DSearchService.canDispatch(kind, fileQuery))", "the declined gate",
            "its answer would otherwise land on the empty state explaining the refusal"]
    ]) {
        const branch = stripComments(q.blockFrom(q.indexOf(landmark), what));
        assert.ok(qmlSource.flat(branch).includes("_supersedeFileSearch();"),
            `${what} must supersede inside its own branch — ${why}`);
    }

    // POSITION, not presence: the guard below the error branch still reads
    // correctly and still captures a stale kind's failure into fileSearchError,
    // which is the defect the line was added for.
    {
        const body = q.body("performFileSearch");
        const dispatched = body.indexOf("DSearchService.search(");
        const guard = body.indexOf("if (generation !== root._fileSearchGeneration)", dispatched);
        const spinnerCleared = body.indexOf("isFileSearching = false;", dispatched);
        const errorBranch = body.indexOf("if (response.error)", dispatched);
        assert.ok(guard !== -1 && spinnerCleared !== -1 && errorBranch !== -1,
            "the callback must guard its generation, clear the spinner and handle an error");
        assert.ok(guard < spinnerCleared,
            "the guard comes before the spinner is cleared: a stale answer must not report that " +
            "the CURRENT search finished");
        assert.ok(guard < errorBranch,
            "and before the error branch, or a superseded kind's failure is captured into " +
            "fileSearchError and shown under the search now on screen");
    }

    // ORDER, not presence: a `return` placed above the clear leaves both tokens
    // in the function and the stale results on screen.
    {
        const gate = q.blockFrom(q.indexOf("if (!DSearchService.canDispatch(kind, fileQuery))"),
            "the not-dispatching gate");
        const cleared = gate.indexOf("_applyFileSearchResults([], effectiveType)");
        const returned = gate.indexOf("return;");
        assert.notEqual(cleared, -1, "the gate must clear the previous kind's results");
        assert.notEqual(returned, -1, "and then return");
        assert.ok(cleared < returned,
            "the clear has to PRECEDE the return, or the chips leave the previous kind's hits " +
            "on screen and the empty state naming the missing tool never renders");
    }

    q.requires(q.body("performSearch"), "performSearch()", [
        ["DSearchService.canDispatch(fileSearchKind(), fileQuery)",
            "the spinner is set from the same per-kind answer, not from a single flag"],
        ["DSearchService.queryIsSearchable(fileSearchKind(), fileQuery)",
            "and from the same owner, kind included, so the spinner agrees with the gate about " +
            "which queries search at all"]
    ]);

    // The ban is scoped to the FILES BRANCH of performSearch, not its body: the
    // same function carries the plugin-phase `searchQuery.length >= 2`, which
    // gates a different question and is deliberately left alone.
    {
        // Located on the RAW source because the landmark carries a string
        // literal, whose contents the structure view blanks; blankRanges keeps
        // offsets, so the index still means the same place to blockFrom.
        const branchAt = controllerSource.indexOf('if (searchMode === "files") {',
            controllerSource.indexOf("function performSearch("));
        const filesBranch = q.blockFrom(branchAt, "performSearch's files branch");
        assert.ok(!/length\s*[<>]=?\s*2/.test(stripComments(filesBranch)),
            "performSearch's files branch must not carry its own two-character literal — " +
            "DSearchService.queryIsDispatchable owns that rule");
        assert.ok(stripComments(filesBranch).includes("DSearchService.queryIsSearchable(fileSearchKind(), fileQuery)"),
            "and must ask the owner instead");
    }

    q.requires(q.body("fileSearchKind"), "fileSearchKind()", [
        ["DSearchService.kindForType", "the type-to-kind mapping stays in its owner"]
    ]);

    // The other three abandon paths. A response in flight outlives all of them,
    // and _applyFileSearchResults CONCATENATES outside files mode, so one that
    // outlives a mode change appends Files and Folders sections into the apps
    // list rather than replacing anything.
    q.requires(q.body("setSearchQuery"), "setSearchQuery()", [
        ["_supersedeFileSearch();",
            "a query change supersedes at the KEYSTROKE, not at the dispatch 200ms later: " +
            "performSearch has already cleared the results by then, and a response landing in " +
            "that window repaints hits for a query the user has left"]
    ]);
    q.requires(q.body("reset"), "reset()", [
        ["_supersedeFileSearch();",
            "explicitly, because a reset that leaves the mode alone fires no mode change"]
    ]);
    {
        const handler = qmlSource.flat(stripComments(q.handlers("onSearchModeChanged").join("\n")));
        assert.ok(handler.includes("_supersedeFileSearch();"),
            "a MODE change supersedes too, hooked on the change rather than on setMode: " +
            "restorePreviousMode assigns searchMode directly, so a setMode-only bump misses it");
    }

    // One owner for the bump, so every path above is the same act — and
    // abandoning means the search is no longer IN FLIGHT as well as no longer
    // current. The callback returns at the generation check before it would
    // clear the flag, and outside files mode nothing else does, so without this
    // a mode change leaves the flag set for the life of the Controller and the
    // empty state — which requires !isFileSearching — never renders again in any
    // mode: a zero-result search then paints a blank panel.
    q.requires(q.body("_supersedeFileSearch"), "_supersedeFileSearch()", [
        ["_fileSearchGeneration++;", "the generation moves"],
        ["isFileSearching = false;", "and nothing is left marked in flight"]
    ]);
    assert.equal(
        (stripComments(controllerSource).match(/_fileSearchGeneration\+\+;/g) || []).length, 1,
        "and nowhere else raises the generation by hand — a bump outside the owner is a path " +
        "that has not said what it is abandoning");

    q.requires(q.body("_retryFileSearchAfterProbe"), "_retryFileSearchAfterProbe()", [
        ["if (!shouldRetryAfterProbe(active, DSearchService.queryIsSearchable(fileSearchKind(), fileSearchQuery())))",
            "the retry predicate is the executed one, reading the live active flag, the one " +
            "query authority and the one threshold — inverted or dropped, a query typed before " +
            "the answer never re-runs"],
        ["fileSearchDebounce.restart()",
            "a query typed before the probe answered is re-run when it lands"]
    ]);

    // BRANCH, not presence: the token satisfies a presence check from either
    // arm, and in the wrong one the failed probe never gets its second chance.
    {
        const opened = q.blockFrom(q.indexOf("if (active) {"), "the launcher-opened branch");
        assert.ok(qmlSource.flat(stripComments(opened)).includes("DSearchService.ensureStatus()"),
            "ensureStatus() must sit in the branch that runs when the launcher OPENS: from the " +
            "closing branch it would re-probe a surface nobody is looking at and leave the " +
            "failed probe unrecovered");
        const closed = q.blockFrom(q.indexOf("if (!active) {"), "the launcher-closed branch");
        assert.ok(!stripComments(closed).includes("ensureStatus"),
            "and not in the closing branch");
    }

    for (const signal of ["onStatusStateChanged", "onFdAvailableChanged", "onRipgrepAvailableChanged"]) {
        assert.ok(qmlSource.flat(stripComments(controllerSource))
            .includes(`function ${signal}() { root._retryFileSearchAfterProbe(); }`),
            `Controller must re-run the pending search on ${signal}: the answer arrives after the ` +
            "user has typed, and nothing else would run the search again");
    }
}

{
    const q = qmlSource(resultsSource, "ResultsList.qml");
    const code = qmlSource.flat(stripComments(resultsSource));

    // The PRODUCERS of those facts, verbatim. Pinning only the calls left the
    // seam one line higher up: a kind/query swap or a dropped negation here
    // reaches the same user-visible symptom through the view instead of the
    // gate, with every consumer call still correct.
    for (const [binding, why] of [
        ["readonly property string _fileQuery: controller ? controller.fileSearchQuery() : \"\"",
            "the query is the controller's one authority, not a re-derivation"],
        ["readonly property bool _fileQuerySearchable: !!controller && DSearchService.queryIsSearchable(controller.fileSearchKind(), _fileQuery)",
            "and whether it searches at all is the service's answer for THIS kind — with the " +
            "kindless form, folder-path completion is reported as a too-short query"],
        ["readonly property string _fileBackendState: controller ? DSearchService.backendState(controller.fileSearchKind(), _fileQuery) : \"unknown\"",
            "kind BEFORE query: swapped, backendCommandFor sees a query string, every state is " +
            "permanently unknown, and no missing tool is ever named again"],
        ["readonly property string _missingBackendCommand: controller && _fileBackendState === \"missing\" ? DSearchService.backendCommandFor(controller.fileSearchKind()) : \"\"",
            "the command comes from the kind behind the missing test; hardcoded, every missing " +
            "tool becomes fd and the ripgrep hint never renders"],
        ["readonly property bool _fileSearchDeclined: !!controller && _fileQuerySearchable && !DSearchService.canDispatch(controller.fileSearchKind(), _fileQuery)",
            "INCLUDING the negation: dropped, every search that ran and found nothing claims the " +
            "tools could not be checked"]
    ]) {
        assert.ok(code.includes(qmlSource.flat(binding)),
            `ResultsList must compute \`${binding}\` — ${why}`);
    }

    // And the facts they are packed into, by name.
    for (const field of [
        "backendState: _fileBackendState", "missingCommand: _missingBackendCommand",
        "probeState: DSearchService.statusState", "queryLength: _fileQuery.length",
        "searchable: _fileQuerySearchable", "declined: _fileSearchDeclined",
        "searchError: controller?.fileSearchError ?? \"\"", "legActive: _fileLegActive"
    ]) {
        assert.ok(code.includes(qmlSource.flat(field)),
            `the empty-state facts must carry \`${field}\`: a fact that never reaches the ` +
            "snapshot is a decision arm that can never fire");
    }

    for (const [call, why] of [
        ["fileEmptyStateKey(_emptyStateFacts)", "the message reads the whole snapshot"],
        ["root.fileHintKey(root._emptyStateFacts)", "and so does the hint"],
        ["fileLegActive(controller?.searchMode ?? \"\", _fileQuerySearchable)",
            "and whether a file search is on screen comes from the executed rule, not a constant"]
    ]) {
        assert.ok(code.includes(qmlSource.flat(call)),
            `ResultsList must call \`${call}\` — ${why}`);
    }

    q.requires(q.body("getEmptyText"), "getEmptyText()", [
        ["case \"unchecked\":", "a refused search has its own message"],
        ["case \"checking\":", "as does a probe still running"],
        ["case \"error\":", "and a search that ran and failed shows what the helper said"],
        ["root.errorLine(root.controller?.fileSearchError)",
            "through errorLine, never raw: that text can be a whole argv or a filename out of " +
            "the search roots, carrying control and bidi characters into a launcher overlay"]
    ]);

    // The label that renders it is bounded like the hint beside it. Unbounded,
    // a long diagnosis stretches the centered column past the results panel.
    {
        const at = q.indexOf("text: getEmptyText()");
        assert.notEqual(at, -1, "ResultsList must render the empty-state message");
        const label = qmlSource.flat(stripComments(
            q.blockFrom(q.lastIndexOf("StyledText {", at), "the empty-state message label")));
        for (const [needed, why] of [
            ["width: Math.min(", "a width bound"],
            ["wrapMode: Text.WordWrap", "wrapping"],
            ["maximumLineCount:", "a line cap"],
            ["elide:", "an elide"]
        ]) {
            assert.ok(label.includes(needed),
                `the empty-state message label needs ${why} — it renders the helper's own text, ` +
                "which is not length-bounded at the source");
        }
    }
    q.requires(q.body("getDependencyHint"), "getDependencyHint()", [
        ["case \"probe-retrying\":",
            "a retry in progress gets its own line: the reopen advice is a no-op while an " +
            "episode is in flight, so telling the user to reopen would be telling them to do " +
            "nothing twice over"]
    ]);
}

// No surface may gate on a single flag again. This is the ban that catches the
// pre-fix forms being re-added beside the new gate rather than instead of it.
for (const [label, source] of [["Controller.qml", controllerSource], ["ResultsList.qml", resultsSource]]) {
    const code = stripComments(source);
    for (const banned of ["dsearchAvailable", "DSearchService.fdAvailable", "DSearchService.ripgrepAvailable"]) {
        assert.ok(!code.includes(banned),
            `${label} must not read \`${banned}\`: one flag answering for two backends is the ` +
            "defect — availability comes from DSearchService.backendState/canDispatch per kind");
    }
}

// --- 8c. the vgsMenu plugin, which this branch also changed -----------------
//
// Read here because it is in the diff: the same threshold owner, the same argv
// shape, and a plugin the suite did not open before.
{
    const q = qmlSource(menuSource, "VGSMenu.qml");
    const code = qmlSource.flat(stripComments(menuSource));

    for (const call of [
        "fileSearching = DSearchService.queryIsDispatchable(trimmed);",
        "if (!DSearchService.queryIsDispatchable(trimmed))",
        "return DSearchService.queryIsSearchable(DSearchService.kindForType(fileSearchType), trimmed) || fileSearchType === \"zoxide\";"
    ]) {
        assert.ok(code.includes(qmlSource.flat(call)),
            `VGSMenu must ask the one threshold owner: \`${call}\`. Its own literal would keep ` +
            "searching at two characters while the launcher's own rule moved");
    }

    // The dispatch predicate and the empty state must be the SAME predicate.
    // They were not: the dispatch site exempts an explicit folder path, so
    // typing "~" in folder mode runs a real search while the empty state said
    // "Type at least two characters" about it.
    q.requires(q.body("refreshFileItems"), "refreshFileItems()", [
        ["if (!fileSearchDispatches(trimmed))", "the dispatch site asks the shared predicate"]
    ]);
    assert.ok(code.includes(qmlSource.flat("!root.fileSearchDispatches(root.query.trim())")),
        "and so does the files-category empty state, or it tells the user to type more about a " +
        "search that ran and found nothing");
    for (const fn of ["refreshFileItems"]) {
        assert.ok(!/explicitFolderPath/.test(stripComments(q.body(fn))),
            `${fn} must not keep its own copy of the folder-path exemption beside the shared one`);
    }

    const openFolder = q.body("openFolder");
    const terminator = openFolder.indexOf('args.push("--", path);');
    const launched = openFolder.indexOf("Quickshell.execDetached(args)");
    assert.notEqual(terminator, -1,
        "openFolder must terminate its options before the path, exactly as search() and " +
        "preview() do — the folder-open command is user-configured");
    assert.ok(terminator < launched, "and do it before launching");
    assert.ok(qmlSource.flat(stripComments(openFolder)).includes('args.push("--command=" + SettingsData.launcherFolderOpenCommand);'),
        "and pass that configured command joined to its flag");
}

// No launcher SEARCH surface may carry its own length literal. Scoped to the
// functions that dispatch a file search: the Controller's plugin-phase and
// clipboard legs have their own thresholds for a different question and are
// deliberately untouched.
for (const [label, source, fns] of [
    ["Controller.qml", controllerSource, ["performFileSearch", "fileSearchQuery", "_retryFileSearchAfterProbe"]],
    ["VGSMenu.qml", menuSource, ["refreshAllItems", "refreshFileItems"]]
]) {
    const q = qmlSource(source, label);
    for (const fn of fns) {
        const body = stripComments(q.body(fn));
        assert.ok(!/length\s*[<>]=?\s*2/.test(body),
            `${label}::${fn} must not carry its own two-character literal — ` +
            "DSearchService.queryIsDispatchable owns that rule for every search surface");
    }
}

// --- 8d. the helper's own argv, one layer down ------------------------------
//
// The second time an option-vs-value ambiguity crossed this boundary: the QML
// joined its flags, argparse accepted the value, and fd rejected it — silently,
// because the run was not checked.
{
    const nameHits = pythonFunction(helperSource, "_launcher_search_name_hits");
    const fdCall = nameHits.indexOf("subprocess.run(command");
    assert.ok(nameHits.includes('command.append("--exclude=" + value)'),
        "the helper must pass an ignore entry joined to its flag: separated, a value starting " +
        "with '-' is an option name to fd and the whole invocation is refused");
    assert.ok(!nameHits.slice(0, fdCall).includes('"--exclude", value'),
        "and must not keep the separated form beside it");
    assert.ok(nameHits.includes("if completed.returncode != 0:"),
        "and must CHECK fd's exit: fd exits 0 for an ordinary search including permission " +
        "warnings, so non-zero means the invocation was refused, and reporting that as an empty " +
        "result set is a wrong answer wearing a successful one's clothes");
    assert.ok(nameHits.slice(0, nameHits.indexOf("if completed.returncode != 0:")).includes("stderr=subprocess.PIPE"),
        "capturing fd's stderr, so the report names the cause");
    assert.ok(nameHits.indexOf("raise RuntimeError(", fdCall) !== -1,
        "and raise rather than continue with an empty candidate list");
}

// --- 9. the view cannot call a controller function that does not exist ------
//
// Optional chaining guards a null controller, not a missing function: renaming
// one would leave the binding throwing TypeError with the empty state blank.
{
    const controllerCode = stripComments(controllerSource);
    const called = new Set();
    const call = /\bcontroller\??\.([A-Za-z_][A-Za-z0-9_]*)\s*\(/g;
    let hit;
    while ((hit = call.exec(stripComments(resultsSource))) !== null)
        called.add(hit[1]);
    assert.ok(called.has("fileSearchKind") && called.has("fileSearchQuery"),
        "ResultsList must read the kind and the effective query from the controller, so the " +
        `empty state describes the search that was actually gated; it called ${[...called].join(", ")}`);
    for (const name of called) {
        assert.ok(new RegExp(`function ${name}\\s*\\(`).test(controllerCode),
            `ResultsList calls controller.${name}(), which Controller.qml does not define`);
    }
}

// --- 10. the probe recovers ---------------------------------------------------

{
    const q = qmlSource(serviceSource, "DSearchService.qml");

    q.requires(q.body("_statusProbeFailed"), "_statusProbeFailed()", [
        ["root.log.warn(", "a failed probe is logged rather than swallowed"],
        ["probeFailureOutcome(root.statusState, root._statusAttempts, root._statusMaxAttempts)",
            "what it publishes is the executed rule's answer, current state included — that is " +
            "what stops a failed re-probe from demoting a successful one"],
        ["root.statusState = outcome.state;", "and the state it publishes is that answer"],
        ["if (outcome.publishReason) root.statusError = reason;",
            "the reason is published only where the rule says so, or a re-probe's failure " +
            "overwrites the reason belonging to an answer still on screen"],
        ["statusRetryTimer.start()", "the retry still runs whatever is published"]
    ]);

    // Restored ALONGSIDE the block above, not replaced by it. Dropping these
    // three took real coverage with them: without the first, a timeout and a
    // non-zero exit report the same text; without the second, a probe whose
    // output cannot be read reports NOTHING and leaves the state at "pending"
    // for the session, refusing every fd-backed search behind "Checking search
    // tools" — the fail-closed dead end this whole change exists to remove.
    q.requires(q.body("_probeStatus"), "_probeStatus()", [
        ["exitCode === 124",
            "a timeout is named as one: 'the CLI never answered' is a different diagnosis from " +
            "'the CLI answered with a failure'"],
        ["root._statusProbeFailed(",
            "and EVERY failure path goes through the same handler — the exit path and the " +
            "unreadable-output path alike", 2],
        ['root.statusState = "ready"',
            "success is the ONLY thing that publishes the tool flags"]
    ]);

    // ORDER inside the probe: the generation check is the FIRST thing its
    // callback does. Below the in-flight reset it would let a superseded probe
    // clear the flag; below the failure handler it would let a stale failure
    // overwrite a fresh success.
    {
        const guardCondition = "if (generation !== root._statusGeneration)";
        const probeBody = q.body("_probeStatus");
        const captured = probeBody.indexOf("const generation = ++_statusGeneration;");
        const guard = probeBody.indexOf(guardCondition);
        const inFlightCleared = probeBody.indexOf("root._statusInFlight = false;");
        const reported = probeBody.indexOf("root._statusProbeFailed(");
        assert.ok(captured !== -1 && guard !== -1 && inFlightCleared !== -1,
            "the probe must capture a generation and check it in its callback");
        assert.ok(captured < guard, "captured before the callback can read it");
        assert.ok(guard < inFlightCleared && guard < reported,
            "and checked BEFORE anything else the callback does, or a superseded probe still " +
            "reports — a late failure landing on top of a good detection is what this guards");
        assert.ok(probeBody.indexOf("_statusInFlight = true") < captured,
            "the in-flight flag is raised for the launch, not after it");

        // The guard has to RETURN. Detecting a stale generation and then
        // carrying on — logging it, say — leaves the late failure landing on the
        // fresh success exactly as before, with the position assertions green.
        const guarded = stripComments(probeBody.slice(guard + guardCondition.length));
        assert.ok(/^\s*\{?\s*return;/.test(guarded),
            "the generation guard's very next statement must be `return;`: a stale probe that " +
            "carries on after being detected is not guarded, it is announced");
    }

    // BRANCH: single-flight lives in rediscover, ahead of the budget reset, so a
    // second open during the retry window cannot restart the attempt budget.
    {
        const body = q.body("rediscover");
        const guard = body.indexOf("if (_statusInFlight || statusRetryTimer.running)");
        const reset = body.indexOf("_statusAttempts = 0;");
        assert.ok(guard !== -1, "rediscover must be single-flight");
        assert.ok(reset !== -1, "and reset the budget for a genuinely new episode");
        assert.ok(guard < reset,
            "the guard has to come FIRST — after the reset it would already have restarted the " +
            "budget it exists to protect");
    }

    const code = stripComments(serviceSource);
    assert.ok(!/property\s+bool\s+dsearchAvailable/.test(code),
        "the whole-subsystem flag must stay deleted: leaving it is what the next caller adopts");
    assert.ok(/kindForType\(params\?\.type\)/.test(qmlSource.flat(code)),
        "search() must derive its kind from the shared mapping rather than a sixth copy");
    assert.ok(/function helperHasFallback\(kind\) \{ return backendCommandFor\(kind\) === "fd"; \}/
        .test(qmlSource.flat(code)),
        "helperHasFallback must stay DERIVED from the command table; restated as its own list " +
        "of kinds it drifts, and a kind then needs a tool nobody probed");
}

process.stdout.write("launcher search gate: ok\n");
