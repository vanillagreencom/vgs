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
// MUST-FAIL CONTROLS the assertions below are chosen to satisfy, in the sense
// that each has been seen red: the pre-fix sources (both the
// `isFileSearching = ... && DSearchService.dsearchAvailable` form and the
// `if (!DSearchService.dsearchAvailable) return;` form), and an inverted
// ternary inside the centralized function, whose tokens are all still present.

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
    "backendCommandFor", "kindForType", "pathCompletion", "backendStateFor",
    "dispatchAllowed", "helperHasFallback"
], "DSearchService.qml");

const view = evaluateMarked(resultsSource, "EMPTY STATE DECISION", [
    "fileEmptyStateKey", "fileHintKey", "fileEmptyIcon"
], "ResultsList.qml");

// The extracted regions must be free of QML, or this harness tests something the
// shell does not run.
for (const [label, source, marker] of [
    ["DSearchService.qml", serviceSource, "SEARCH BACKEND DECISION"],
    ["ResultsList.qml", resultsSource, "EMPTY STATE DECISION"]
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

assert.equal(view.fileEmptyStateKey("checking", "", 5), "checking",
    "a pending probe says so rather than claiming search is unavailable");
assert.equal(view.fileEmptyStateKey("missing", "rg", 5), "missing-rg");
assert.equal(view.fileEmptyStateKey("missing", "fd", 5), "missing-fd");
assert.equal(view.fileEmptyStateKey("available", "", 0), "prompt");
assert.equal(view.fileEmptyStateKey("available", "", 1), "short");
assert.equal(view.fileEmptyStateKey("available", "", 2), "empty");
assert.equal(view.fileEmptyStateKey("unknown", "", 2), "empty",
    "an unanswerable probe does not rewrite the result message — the search still ran");
assert.equal(view.fileEmptyStateKey("missing", "fd", 0), "missing-fd",
    "and a missing tool is worth saying before a query is typed");

assert.equal(view.fileHintKey(true, "missing", "rg", "ready"), "install-rg");
assert.equal(view.fileHintKey(true, "missing", "fd", "ready"), "install-fd");
assert.equal(view.fileHintKey(true, "unknown", "", "failed"), "probe-failed",
    "a probe that could not run names ITSELF; blaming fd for it is the wrong cause");
assert.equal(view.fileHintKey(true, "checking", "", "pending"), "",
    "nothing is claimed while the answer is still coming");
assert.equal(view.fileHintKey(true, "available", "", "ready"), "",
    "and a working backend needs no install step");
for (const [state, missing, probe] of [["missing", "fd", "ready"], ["unknown", "", "failed"]]) {
    assert.equal(view.fileHintKey(false, state, missing, probe), "",
        "no hint where no file search would have run: 'install fd' in a mode that never searches " +
        "files promises a fix that changes nothing");
}

assert.equal(view.fileEmptyIcon("checking", "file"), "hourglass_empty");
assert.equal(view.fileEmptyIcon("missing-fd", "file"), "search_off");
assert.equal(view.fileEmptyIcon("missing-rg", "text"), "search_off");
assert.equal(view.fileEmptyIcon("empty", "file"), "insert_drive_file");
assert.equal(view.fileEmptyIcon("empty", "dir"), "folder_open");
assert.equal(view.fileEmptyIcon("empty", "text"), "article");

// --- 8. the wiring the decisions are useless without ------------------------

{
    const q = qmlSource(controllerSource, "Controller.qml");

    q.requires(q.body("performFileSearch"), "performFileSearch()", [
        ["var kind = fileSearchKind()", "the kind is decided once, by the shared accessor"],
        ["DSearchService.canDispatch(kind, fileQuery)",
            "and the gate asks about THAT kind, with the query the search will send"],
        ["_applyFileSearchResults([], effectiveType)",
            "BOTH ways a search ends with nothing clear the previous kind's hits — the gate " +
            "declining it and the search failing. Without the first, the chips leave stale " +
            "results on screen and the empty state that names the missing tool never renders", 2]
    ]);

    q.requires(q.body("performSearch"), "performSearch()", [
        ["DSearchService.canDispatch(fileSearchKind(), fileQuery)",
            "the spinner is set from the same per-kind answer, not from a single flag"]
    ]);

    q.requires(q.body("fileSearchKind"), "fileSearchKind()", [
        ["DSearchService.kindForType", "the type-to-kind mapping stays in its owner"]
    ]);

    q.requires(q.body("_retryFileSearchAfterProbe"), "_retryFileSearchAfterProbe()", [
        ["fileSearchDebounce.restart()",
            "a query typed before the probe answered is re-run when it lands"]
    ]);

    const handlers = qmlSource.flat(q.handlers("onActiveChanged").join("\n"));
    assert.ok(handlers.includes("DSearchService.ensureStatus()"),
        "opening the launcher must give a probe that gave up another chance, or one failed " +
        "probe disables search for the life of the shell");

    for (const signal of ["onStatusStateChanged", "onFdAvailableChanged", "onRipgrepAvailableChanged"]) {
        assert.ok(qmlSource.flat(stripComments(controllerSource))
            .includes(`function ${signal}() { root._retryFileSearchAfterProbe(); }`),
            `Controller must re-run the pending search on ${signal}: the answer arrives after the ` +
            "user has typed, and nothing else would run the search again");
    }
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

    q.requires(q.body("ensureStatus"), "ensureStatus()", [
        ['statusState === "failed"', "a settled answer is not re-probed on every open"],
        ["rediscover()", "and a failed one is"]
    ]);

    const code = stripComments(serviceSource);
    assert.ok(!/property\s+bool\s+dsearchAvailable/.test(code),
        "the whole-subsystem flag must stay deleted: leaving it is what the next caller adopts");
    assert.ok(/kindForType\(params\?\.type\)/.test(qmlSource.flat(code)),
        "search() must derive its kind from the shared mapping rather than a sixth copy");
}

process.stdout.write("launcher search gate: ok\n");
