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
// WHERE THE SEAM IS, and why it moved. A first version of this suite executed
// the pure regions and pinned everything AROUND them by presence of a token; a
// mutation run killed 1 of 10 planted mutants, because a mutant that keeps the
// token and removes the behavior walks past a presence check. Two changes
// followed. The composition itself was pushed INTO the regions — which property
// lands in which slot is now executed (backendStateFrom, canDispatchFrom,
// fileSearchQueryFrom, shouldRetryAfterProbe, fileLegActive) — and what has to
// stay a QML binding is pinned by ORDER and BRANCH: the full argument list of a
// call, a statement's position relative to the `return` after it, the block a
// call sits inside. Section 4's `pathBranch < fdLookup` was the model.
//
// MUST-FAIL CONTROLS, each seen red, applied one at a time to the shipped tree.
// In-region: an inverted ternary in the command table; an inverted unknown arm
// in dispatchAllowed; a disabled "/" branch in fileSearchQueryFrom; the
// prompt/checking order put back the wrong way round. Across the seam, which is
// where the first version of this suite was blind: the fd and ripgrep slots
// swapped in backendState; canDispatch reduced to a bare equality;
// fileEmptyStateKey's leading arguments swapped; the hint fed the backend state
// where the probe state belongs; the retry predicate inverted; ensureStatus()
// moved to the launcher-CLOSED branch with the opened branch left in place; a
// `return` hoisted above the stale-result clear; the fallback conjunct dropped
// from search()'s refusal; _fileLegActive hardcoded false; the single-flight
// guard moved below the budget reset; the generation check moved below the
// in-flight reset; the retrying state never published; helperHasFallback
// restated instead of derived. Plus the pre-fix sources, both the
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
const HELPER = path.join(repoRoot, "bin", "vshell-helper");

const serviceSource = fs.readFileSync(SERVICE, "utf8");
const controllerSource = fs.readFileSync(CONTROLLER, "utf8");
const resultsSource = fs.readFileSync(RESULTS, "utf8");

// This text comes from repo files and is EXECUTED here, so it runs inside a
// child the parent kills on a wall clock — scripts/lib/qml-region.js says what
// that bounds and what it does not.
const { evaluateMarked, regionOf, guardChild } = require("./lib/qml-region.js");
const qmlSource = require("./lib/qml-source.js");
const { stripComments } = qmlSource;

// Returns only in the child; the parent exits with its status.
guardChild();

// Prove the tools before they prove anything: that a region which does not
// finish becomes a fast, named red, and that a token surviving only in a comment
// pins nothing.
require("./lib/qml-region.js").selfTest();
qmlSource.selfTest();

const backend = evaluateMarked(serviceSource, "SEARCH BACKEND DECISION", [
    "backendCommandFor", "kindForType", "pathCompletion", "queryIsDispatchable",
    "backendStateFor", "dispatchAllowed", "helperHasFallback", "serviceRefuses",
    "canDispatchFor", "probeSettled"
], "DSearchService.qml");

const view = evaluateMarked(resultsSource, "EMPTY STATE DECISION", [
    "fileEmptyStateKey", "fileHintKey", "fileEmptyIcon", "fileLegActive"
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

// Only a proven-missing tool blocks a search; unknown dispatches so the search
// itself fails with a real cause instead of being refused on nobody's answer.
assert.ok(backend.dispatchAllowed("available"));
assert.ok(backend.dispatchAllowed("unknown"), "an unanswerable probe must not block the search");
assert.ok(!backend.dispatchAllowed("missing"), "a tool proven absent does block it");
assert.ok(!backend.dispatchAllowed("checking"), "and a pending answer waits rather than guessing");

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
    const helperSource = fs.readFileSync(HELPER, "utf8");
    const nameHits = helperSource.slice(helperSource.indexOf("def _launcher_search_name_hits("));
    assert.ok(nameHits.startsWith("def _launcher_search_name_hits("), "the helper must define it");
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

const facts = extra => Object.assign({
    backendState: "available",
    missingCommand: "",
    probeState: "ready",
    queryLength: 5,
    dispatchable: true,
    declined: false,
    searchError: "",
    legActive: true
}, extra);

assert.equal(view.fileEmptyStateKey(facts({ backendState: "checking" })), "checking",
    "a pending probe says so rather than claiming search is unavailable");
assert.equal(view.fileEmptyStateKey(facts({ backendState: "missing", missingCommand: "rg" })), "missing-rg");
assert.equal(view.fileEmptyStateKey(facts({ backendState: "missing", missingCommand: "fd" })), "missing-fd");
assert.equal(view.fileEmptyStateKey(facts({ queryLength: 0, dispatchable: false })), "prompt");
assert.equal(view.fileEmptyStateKey(facts({ queryLength: 1, dispatchable: false })), "short");
assert.equal(view.fileEmptyStateKey(facts({})), "empty");
assert.equal(view.fileEmptyStateKey(facts({ backendState: "unknown" })), "empty",
    "an unanswerable probe does not rewrite the result message — the search still ran");
assert.equal(view.fileEmptyStateKey(facts({
    backendState: "missing", missingCommand: "fd", queryLength: 0, dispatchable: false
})), "missing-fd", "and a missing tool is worth saying before a query is typed");
assert.equal(view.fileEmptyStateKey(facts({ searchError: "ripgrep is required for text search" })),
    "error",
    "a search that RAN and failed shows the helper's own diagnosis rather than 'no results'");
assert.equal(view.fileEmptyStateKey(facts({ backendState: "unknown", declined: true })), "unchecked",
    "and one the gate refused says that instead");

assert.equal(view.fileHintKey(facts({ backendState: "missing", missingCommand: "rg" })), "install-rg");
assert.equal(view.fileHintKey(facts({ backendState: "missing", missingCommand: "fd" })), "install-fd");
assert.equal(view.fileHintKey(facts({ backendState: "unknown", declined: true, probeState: "failed" })),
    "probe-failed",
    "a probe that could not run names ITSELF; blaming fd for it is the wrong cause");
assert.equal(view.fileHintKey(facts({ backendState: "unknown", declined: true, probeState: "retrying" })),
    "probe-retrying",
    "a retry in progress asks the user for NOTHING — it will answer on its own, and the reopen " +
    "advice is a no-op while an episode is in flight");
assert.equal(view.fileHintKey(facts({ backendState: "unknown", probeState: "failed" })), "",
    "no probe line beside a search that actually ran, whatever the probe did");
assert.equal(view.fileHintKey(facts({ backendState: "checking", probeState: "pending" })), "",
    "nothing is claimed while the first answer is still coming");
assert.equal(view.fileHintKey(facts({})), "",
    "and a working backend needs no install step");
for (const extra of [{ backendState: "missing", missingCommand: "fd" },
    { backendState: "unknown", declined: true, probeState: "failed" }]) {
    assert.equal(view.fileHintKey(facts(Object.assign({ legActive: false }, extra))), "",
        "no hint where no file search would have run: 'install fd' in a mode that never searches " +
        "files promises a fix that changes nothing");
}

assert.equal(view.fileEmptyIcon("checking", "file"), "hourglass_empty");
assert.equal(view.fileEmptyIcon("missing-fd", "file"), "search_off");
assert.equal(view.fileEmptyIcon("missing-rg", "text"), "search_off");
assert.equal(view.fileEmptyIcon("unchecked", "file"), "search_off");
assert.equal(view.fileEmptyIcon("empty", "file"), "insert_drive_file");
assert.equal(view.fileEmptyIcon("empty", "dir"), "folder_open");
assert.equal(view.fileEmptyIcon("empty", "text"), "article");

// The prompt comes first: nothing is being checked on the user's behalf before a
// query that could dispatch.
assert.equal(view.fileEmptyStateKey(facts({
    backendState: "checking", queryLength: 0, dispatchable: false
})), "prompt", "an empty field prompts even while the probe is outstanding");
assert.equal(view.fileEmptyStateKey(facts({
    backendState: "checking", queryLength: 1, dispatchable: false
})), "short", "and a short query is short, not checking");
assert.equal(view.fileEmptyStateKey(facts({ backendState: "checking" })), "checking",
    "checking still wins for a query that would actually dispatch");

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
    "an open surface with a dispatchable query re-runs when the probe answers");
assert.ok(!files.shouldRetryAfterProbe(false, true),
    "a closed one does not — the retry must not search behind a dismissed launcher");
assert.ok(!files.shouldRetryAfterProbe(true, false), "nor one whose query would not dispatch");

assert.ok(view.fileLegActive("files", false),
    "files mode is a file surface even before a query is typed");
assert.ok(view.fileLegActive("all", true), "and so is any mode holding a dispatchable file query");
assert.ok(!view.fileLegActive("plugins", false), "plugins mode is not");
assert.ok(!view.fileLegActive("apps", false), "nor is a mode with a query too short to dispatch");

// The one owner of "long enough to search", which those two now read instead of
// carrying their own literal.
assert.ok(backend.queryIsDispatchable("ab"), "two characters dispatch");
assert.ok(backend.queryIsDispatchable("  ab  "), "after trimming");
for (const query of ["a", " a ", "", " ", undefined, null])
    assert.ok(!backend.queryIsDispatchable(query), `${JSON.stringify(query)} does not`);

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
        ["if (!DSearchService.queryIsDispatchable(fileQuery))",
            "and the length rule from the one threshold owner, not a sixth literal"],
        ["DSearchService.canDispatch(kind, fileQuery)",
            "and the gate asks about THAT kind, with the query the search will send"],
        ["_applyFileSearchResults([], effectiveType)",
            "BOTH ways a search ends with nothing clear the previous kind's hits — the gate " +
            "declining it and the search failing", 2]
    ]);

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
            "the spinner is set from the same per-kind answer, not from a single flag"]
    ]);

    q.requires(q.body("fileSearchKind"), "fileSearchKind()", [
        ["DSearchService.kindForType", "the type-to-kind mapping stays in its owner"]
    ]);

    q.requires(q.body("_retryFileSearchAfterProbe"), "_retryFileSearchAfterProbe()", [
        ["if (!shouldRetryAfterProbe(active, DSearchService.queryIsDispatchable(fileSearchQuery())))",
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
        ["readonly property bool _fileQueryDispatchable: DSearchService.queryIsDispatchable(_fileQuery)",
            "and the threshold is the service's"],
        ["readonly property string _fileBackendState: controller ? DSearchService.backendState(controller.fileSearchKind(), _fileQuery) : \"unknown\"",
            "kind BEFORE query: swapped, backendCommandFor sees a query string, every state is " +
            "permanently unknown, and no missing tool is ever named again"],
        ["readonly property string _missingBackendCommand: controller && _fileBackendState === \"missing\" ? DSearchService.backendCommandFor(controller.fileSearchKind()) : \"\"",
            "the command comes from the kind behind the missing test; hardcoded, every missing " +
            "tool becomes fd and the ripgrep hint never renders"],
        ["readonly property bool _fileSearchDeclined: !!controller && _fileQueryDispatchable && !DSearchService.canDispatch(controller.fileSearchKind(), _fileQuery)",
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
        "dispatchable: _fileQueryDispatchable", "declined: _fileSearchDeclined",
        "searchError: controller?.fileSearchError ?? \"\"", "legActive: _fileLegActive"
    ]) {
        assert.ok(code.includes(qmlSource.flat(field)),
            `the empty-state facts must carry \`${field}\`: a fact that never reaches the ` +
            "snapshot is a decision arm that can never fire");
    }

    for (const [call, why] of [
        ["fileEmptyStateKey(_emptyStateFacts)", "the message reads the whole snapshot"],
        ["root.fileHintKey(root._emptyStateFacts)", "and so does the hint"],
        ["fileLegActive(controller?.searchMode ?? \"\", _fileQueryDispatchable)",
            "and whether a file search is on screen comes from the executed rule, not a constant"]
    ]) {
        assert.ok(code.includes(qmlSource.flat(call)),
            `ResultsList must call \`${call}\` — ${why}`);
    }

    q.requires(q.body("getEmptyText"), "getEmptyText()", [
        ["case \"unchecked\":", "a refused search has its own message"],
        ["case \"checking\":", "as does a probe still running"],
        ["case \"error\":", "and a search that ran and failed shows what the helper said"]
    ]);
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
        ["statusRetryTimer.start()", "and retried"],
        ["root._statusAttempts < root._statusMaxAttempts",
            "under a bound, so it cannot spawn a process a second for the life of the shell"],
        ['root.statusState = "failed"', "before it finally gives up in a state callers can see"]
    ]);

    q.requires(q.body("_probeStatus"), "_probeStatus()", [
        ["exitCode === 124",
            "a timeout is named as one: 'the CLI never answered' is a different diagnosis from " +
            "'the CLI answered with a failure'"],
        ["root._statusProbeFailed(", "and every failure path goes through the same handler", 2],
        ['root.statusState = "ready"', "success is the ONLY thing that publishes the tool flags"]
    ]);

    // ORDER inside _statusProbeFailed: the retrying state has to be published
    // from the retry branch, before the timer is armed and before the give-up
    // assignment, or the whole retry window reads as "checking" and refuses
    // every search for the ~12s it lasts.
    {
        const failed = q.body("_statusProbeFailed");
        const retrying = failed.indexOf('root.statusState = "retrying"');
        const armed = failed.indexOf("statusRetryTimer.start()");
        const gaveUp = failed.indexOf('root.statusState = "failed"');
        assert.ok(retrying !== -1 && armed !== -1 && gaveUp !== -1,
            "the retry path must publish a retrying state, arm the timer, and keep a give-up state");
        assert.ok(retrying < armed,
            "the state has to change before the timer is armed, so a search racing the retry " +
            "already sees an unknown answer rather than a pending one");
        assert.ok(armed < gaveUp,
            "and giving up has to come after the retries, not instead of them");
    }

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
