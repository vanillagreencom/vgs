#!/usr/bin/env node

// Test per-kind launcher search tools, unknown probe state, and empty-state messages.
// Execute marked decisions and inspect their adapters, producers, branches, and statement order.
// Use reachable input combinations so impossible fixture states cannot satisfy the intended case.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.join(__dirname, "..");
const APP_SEARCH = path.join(repoRoot, "quickshell", "vshell", "Services", "AppSearchService.qml");
const SERVICE = path.join(repoRoot, "quickshell", "vshell", "Services", "DSearchService.qml");
const OVERVIEW = path.join(repoRoot, "quickshell", "vshell", "Modules", "WorkspaceOverlays", "OverviewSearch");
const CONTROLLER = path.join(OVERVIEW, "Controller.qml");
const RESULTS = path.join(OVERVIEW, "ResultsList.qml");
const MENU = path.join(repoRoot, "config", "vshell", "plugins", "vgsMenu", "VGSMenu.qml");
const HELPER = path.join(repoRoot, "bin", "vshell-helper");

const appSearchSource = fs.readFileSync(APP_SEARCH, "utf8");
const serviceSource = fs.readFileSync(SERVICE, "utf8");
const controllerSource = fs.readFileSync(CONTROLLER, "utf8");
const resultsSource = fs.readFileSync(RESULTS, "utf8");
const menuSource = fs.readFileSync(MENU, "utf8");
const helperSource = fs.readFileSync(HELPER, "utf8");

// Extracted code runs under qml-region process deadlines.
const { evaluateMarked, regionOf, guardChild } = require("./lib/qml-region.js");
const qmlSource = require("./lib/qml-source.js");
const { stripComments } = qmlSource;


guardChild();

// Run source-reader self-tests first. Guard self-tests run separately so a broken guard cannot hide them.
qmlSource.selfTest();

const backend = evaluateMarked(serviceSource, "SEARCH BACKEND DECISION", [
    "backendCommandFor", "kindForType", "pathCompletion", "queryIsDispatchable",
    "queryIsSearchable", "backendStateFor", "dispatchAllowed", "helperHasFallback",
    "serviceRefuses", "canDispatchFor", "probeSettled", "probeFailureOutcome"
], "DSearchService.qml");

const appSearch = evaluateMarked(appSearchSource, "APPLICATION SEARCH RELEVANCE DECISION", [
    "normalizeSearchText", "tokenizeNormalizedSearchText", "tokenize", "searchQueryContext",
    "ensureSearchQueryContext", "fieldScorePenalty", "usageScoreCap", "actionScoreGap",
    "searchFieldValues", "normalizedSearchField", "normalizedSearchFields",
    "normalizedFieldSet", "wordBoundaryMatchFromWords", "levenshteinDistance",
    "fuzzyMatchScoreForField", "fieldMatchScore", "bestFieldScore",
    "bestAllowedWordScore", "allQueryWordsScore", "fuzzyFallbackScore",
    "secondaryFieldBonus", "textRelevance", "applicationAliasFields", "firstExecToken",
    "executableBasename", "applicationIdentifierFields", "applicationSearchFields",
    "boundedUsageScore", "applicationFinalScore", "appFromSearchItem",
    "appUsageFromSearchItem", "searchAppActions", "applicationSearchResultsFor"
], "AppSearchService.qml");

const view = evaluateMarked(resultsSource, "EMPTY STATE DECISION", [
    "fileEmptyStateKey", "fileHintKey", "fileEmptyIcon", "fileLegActive", "errorLine"
], "ResultsList.qml");

const files = evaluateMarked(controllerSource, "FILE SEARCH DECISION", [
    "fileSearchQueryFrom", "shouldRetryAfterProbe"
], "Controller.qml");
const menuSort = evaluateMarked(menuSource, "LAUNCHER MENU SORT DECISION", [
    "sortRanked"
], "VGSMenu.qml");

const probe = (state, fd, ripgrep) => ({ state: state, fd: fd, ripgrep: ripgrep });
const ready = (fd, rg) => probe("ready", fd, rg);
const TOOL_FLAGS = [[true, true], [true, false], [false, true], [false, false]];

function textRelevanceResult(args) {
    return appSearch.textRelevance({
        primary: args.primary || [],
        aliases: args.aliases || [],
        keywords: args.keywords || [],
        identifiers: args.identifiers || [],
        secondary: args.secondary || []
    }, args.query || "");
}

function textScore(args) {
    return textRelevanceResult(args).score;
}

function assertRejected(args, message) {
    const result = textRelevanceResult(args);
    assert.equal(result.admitted, false, `${message}: result must not be admitted`);
    assert.equal(result.score, 0, `${message}: score must stay zero`);
    assert.equal(result.textScore, 0, `${message}: text score must stay zero`);
}

function qmlSequence(values) {
    const sequence = { length: values.length };
    for (let i = 0; i < values.length; i++)
        sequence[i] = values[i];
    return sequence;
}

function appSearchRows(apps, query, includeActions = false, limit = 10, usageForApp = null) {
    return appSearch.applicationSearchResultsFor(apps.map(app => ({
        app: app,
        fields: appSearch.applicationSearchFields(app),
        usage: app.usage
    })), query, includeActions, limit, usageForApp);
}

function actionRowNames(rows) {
    return rows.filter(row => row.app.isAction).map(row => row.app.name);
}

function searchRowSummaries(rows) {
    return rows.map(row => ({
        name: row.app.name,
        isAction: !!row.app.isAction,
        score: row.score
    }));
}

function expectedActionScore(tier) {
    if (tier === "exact")
        return 90000 - appSearch.actionScoreGap();
    if (tier === "prefix")
        return 80000 - appSearch.fieldScorePenalty() - appSearch.actionScoreGap();
    return 60000 - appSearch.fieldScorePenalty() - appSearch.actionScoreGap();
}

// Bound a Python function at the next top-level def. Unbounded slices can borrow
// an unrelated later statement to satisfy a missing failure branch.
function pythonFunction(source, name) {
    const start = source.indexOf(`def ${name}(`);
    assert.notEqual(start, -1, `bin/vshell-helper must define ${name}()`);
    const end = source.indexOf("\ndef ", start + 1);
    return source.slice(start, end === -1 ? source.length : end);
}

function replaceOnce(source, before, after, label) {
    const count = source.split(before).length - 1;
    assert.equal(count, 1, `${label} control needs one insertion point, found ${count}`);
    return source.replace(before, after);
}

function assertAllSearchRouteAvoidsFileProvider(source, label) {
    const q = qmlSource(source, label);
    const route = `${q.body("buildImmediateAllItems")}\n${q.body("refreshAllItems")}`;
    const routeCode = stripComments(route);
    for (const [pattern, reason] of [
        [/\bDSearchService\s*\.\s*search\s*\(/,
            "calling DSearchService.search starts the shared file and folder provider"],
        [/\bPaths\s*\.\s*vshellCli\b|["']launcher-search["']/,
            "starting vshell launcher-search search bypasses DSearchService"],
        [/\bfileItem\s*\(/, "building fileItem rows brings files back into All results"],
        [/\blauncherMenuUsageHistory\b/, "reading file history brings previous files back into All results"]
    ]) {
        assert.ok(!pattern.test(routeCode),
            `VGSMenu All search must not ${reason}; keep files in the Files category and prefixes`);
    }
}

test("application relevance admits strong fields and rejects secondary-only matches", () => {
    const exact = textScore({ primary: ["OpenCode"], query: "opencode" });
    const prefix = textScore({ primary: ["OpenCode editor"], query: "opencode" });
    const wordPrefix = textScore({ primary: ["Run OpenCode"], query: "opencode" });
    const substring = textScore({ primary: ["XOpenCode"], query: "opencode" });
    const aliasExact = textScore({ aliases: ["OpenCode"], query: "opencode" });
    const keywordExact = textScore({ keywords: ["opencode"], query: "opencode" });
    const identifierExact = textScore({ identifiers: ["opencode.desktop"], query: "opencode.desktop" });

    assert.ok(exact > prefix, "an exact title or app name outranks a prefix");
    assert.ok(prefix > wordPrefix, "a title or app-name prefix outranks a word prefix");
    assert.ok(wordPrefix > substring, "a word prefix outranks a title or app-name substring");
    assert.ok(substring > aliasExact,
        "aliases, identifiers and keywords remain below title or app-name substring matches");
    assert.ok(aliasExact > keywordExact, "an alias match outranks a keyword match");
    assert.ok(keywordExact > identifierExact, "a keyword match outranks an identifier match");

    assertRejected({
        primary: ["Terminal"], secondary: ["OpenCode coding agent"], query: "opencode"
    }, "subtitle and category text cannot admit a result by themselves");

    assert.ok(textScore({
        primary: ["OpenCode"], secondary: ["OpenCode coding agent"], query: "opencode"
    }) > exact, "subtitle and category text can improve a result already admitted by title");

    assert.ok(textScore({
        primary: ["OpenCode"], keywords: ["agent"], query: "opencode agent"
    }) > 0, "a multi-word query may match across allowed fields");
    assertRejected({
        primary: ["OpenCode"], secondary: ["agent"], query: "opencode agent"
    }, "every query word must match an allowed field, not only subtitle or category text");

    assert.equal(textScore({
        keywords: qmlSequence(["alpha", "opencode"]), query: "opencode"
    }), keywordExact, "a QML keyword sequence is scored one keyword at a time");
    assert.ok(textScore({
        keywords: qmlSequence(["alpha", "opencode tools"]), query: "opencode"
    }) > 0, "a QML keyword sequence also preserves prefix keyword matches");

    assertRejected({
        identifiers: appSearch.applicationIdentifierFields({
            id: "other.desktop",
            execString: "/usr/bin/other --flag"
        }),
        query: "usr"
    }, "path-only Exec words cannot admit an unrelated application");
    assert.ok(textScore({
        identifiers: appSearch.applicationIdentifierFields({
            id: "other.desktop",
            execString: "/usr/bin/opencode --flag"
        }),
        query: "opencode"
    }) > 0, "the executable basename remains an identifier");

    const desktopIdApps = [
        { name: "OpenCode", id: "org.example.OpenCode.desktop" },
        { name: "Terminal", id: "org.example.Terminal.desktop" }
    ];
    for (const query of ["desktop", ".desktop"]) {
        assert.deepEqual(appSearchRows(desktopIdApps, query), [],
            `${query} must not admit applications through the desktop-entry suffix`);
    }
    assert.deepEqual(appSearchRows(desktopIdApps, "org.example.OpenCode.desktop").map(row => row.app.name),
        ["OpenCode"], "an exact full desktop-entry identifier remains searchable");

    assert.ok(appSearch.textRelevance(appSearch.applicationSearchFields({ name: "OpenCode" }), "opencdoe").score > 0,
        "typo fallback admits a bounded title or app-name match");
    assert.ok(appSearch.textRelevance(appSearch.applicationSearchFields({ name: "Editor", aliases: ["OpenCode"] }),
        "opencdoe").score > 0, "typo fallback also covers declared aliases");
    assert.ok(appSearch.textRelevance(appSearch.applicationSearchFields({ name: "Editor", startupClass: "OpenCode" }),
        "opencode").score > 0, "startupClass is a real desktop-entry alias source");
    assert.equal(appSearch.textRelevance(appSearch.applicationSearchFields({ name: "Editor", id: "opencode.desktop" }),
        "opencdoe").score, 0, "typo fallback does not run against identifiers");

    assert.ok(appSearch.applicationFinalScore(substring, 0, 999999)
        > appSearch.applicationFinalScore(keywordExact, 999999, 0),
        "the usage cap cannot move a keyword match above a title or app-name substring");
    assert.equal(appSearch.boundedUsageScore(999999, 0), appSearch.usageScoreCap(),
        "the usage cap is the shared boundary for app and menu score boosts");

    const exactActionApp = {
        name: "Terminal",
        id: "terminal.desktop",
        icon: "terminal",
        categories: ["System"],
        actions: [{ name: "OpenCode", icon: "run" }]
    };
    const exactAction = appSearch.searchAppActions("opencode", [exactActionApp]);
    assert.deepEqual(searchRowSummaries(exactAction), [{
        name: "OpenCode",
        isAction: true,
        score: expectedActionScore("exact")
    }], "action search executes the exact action tier");
    assert.deepEqual({
        icon: exactAction[0].app.icon,
        comment: exactAction[0].app.comment,
        categories: exactAction[0].app.categories,
        parentName: exactAction[0].app.parentApp.name,
        actionName: exactAction[0].app.actionData.name
    }, {
        icon: "run",
        comment: "Terminal",
        categories: ["System"],
        parentName: "Terminal",
        actionName: "OpenCode"
    }, "action search keeps the returned action row payload");
    assert.ok(exact > exactAction[0].score, "an exact application stays above an exact action");

    const prefixAction = appSearch.searchAppActions("opencode", [{
        name: "Terminal",
        id: "terminal.desktop",
        actions: [{ name: "OpenCode workspace", icon: "run" }]
    }]);
    assert.deepEqual(searchRowSummaries(prefixAction), [{
        name: "OpenCode workspace",
        isAction: true,
        score: expectedActionScore("prefix")
    }], "action search executes the prefix action tier");
    assert.ok(textScore({ primary: ["OpenCode workspace"], query: "opencode" }) > prefixAction[0].score,
        "a prefix application stays above a prefix action");

    const substringAction = appSearch.searchAppActions("opencode", [{
        name: "Terminal",
        id: "terminal.desktop",
        actions: [{ name: "XOpenCode", icon: "run" }]
    }]);
    assert.deepEqual(searchRowSummaries(substringAction), [{
        name: "XOpenCode",
        isAction: true,
        score: expectedActionScore("substring")
    }], "action search executes the substring action tier");
    assert.ok(textScore({ primary: ["XOpenCode"], query: "opencode" }) > substringAction[0].score,
        "a substring application stays above a substring action");

    assert.deepEqual(appSearch.searchAppActions("p", [{
        name: "Terminal",
        id: "terminal.desktop",
        actions: [{ name: "OpenCode", icon: "run" }]
    }]), [], "one-character queries do not admit substring-only action matches");

    assert.deepEqual(appSearchRows([
        {
            name: "Terminal",
            comment: "OpenCode coding agent",
            id: "terminal.desktop",
            usage: { frecency: 999999, daysSinceUsed: 0 }
        },
        {
            name: "OpenCode",
            id: "opencode.desktop",
            usage: { frecency: 0, daysSinceUsed: 999999 }
        }
    ], "opencode").map(row => row.app.name), ["OpenCode"],
        "the application result builder drops secondary-only rows before ranking");

    const usageLookups = [];
    assert.deepEqual(appSearchRows([
        {
            name: "Terminal",
            comment: "OpenCode coding agent",
            id: "terminal.desktop"
        },
        {
            name: "OpenCode",
            id: "opencode.desktop"
        }
    ], "opencode", false, 10, app => {
        usageLookups.push(app.name);
        return {
            frecency: app.name === "OpenCode" ? 25 : 999999,
            daysSinceUsed: app.name === "OpenCode" ? 2 : 0
        };
    }).map(row => row.app.name), ["OpenCode"],
        "usage is looked up through the result builder only for admitted applications");
    assert.deepEqual(usageLookups, ["OpenCode"],
        "a rejected application does not pay a usage lookup");

    for (const [label, usage, expectedFrecency, expectedDaysSinceUsed] of [
        ["present zero values", { frecency: 0, daysSinceUsed: 0 }, 0, 0],
        ["null usage values", { frecency: null, daysSinceUsed: null }, 0, 999999],
        ["missing usage values", {}, 0, 999999]
    ]) {
        const rows = appSearchRows([{
            name: "OpenCode",
            id: "opencode.desktop",
            usage: usage
        }], "opencode");
        assert.equal(rows[0].score, appSearch.applicationFinalScore(exact, expectedFrecency, expectedDaysSinceUsed),
            `${label} must use only nullish defaults in the application result builder`);
    }

    const actionRows = appSearchRows([
        {
            name: "Terminal",
            id: "terminal.desktop",
            actions: [
                { name: "OpenCode workspace", icon: "run" },
                { name: "", icon: "blank" }
            ]
        }
    ], "opencode", true);
    assert.deepEqual(actionRowNames(appSearchRows([{
        name: "Terminal",
        id: "terminal.desktop",
        actions: [{ name: "OpenCode workspace", icon: "run" }]
    }], "opencode", false)), [], "disabled action search returns no action rows");
    assert.deepEqual(actionRows.map(row => ({
        name: row.app.name,
        isAction: !!row.app.isAction
    })), [{ name: "OpenCode workspace", isAction: true }],
        "action search returns the matching action row and rejects the empty-name action");
    assert.deepEqual(searchRowSummaries(appSearchRows([
        { name: "OpenCode", id: "opencode.desktop" },
        { name: "OpenCode workspace", id: "opencode-workspace.desktop" },
        {
            name: "Terminal",
            id: "terminal.desktop",
            actions: [{ name: "OpenCode", icon: "run" }]
        }
    ], "opencode", true, 2)), [
        { name: "OpenCode", isAction: false, score: exact },
        { name: "OpenCode", isAction: true, score: expectedActionScore("exact") }
    ], "the result cap keeps a high-ranked matching action above lower-ranked applications");
});

test("searchApplicationResults stays a thin adapter to the executable result builder", () => {
    const q = qmlSource(appSearchSource, "AppSearchService.qml");
    assert.equal(qmlSource.flat(stripComments(q.body("searchApplicationResults"))),
        qmlSource.flat(`{
        return applicationSearchResultsFor(getVisibleSearchItems(), searchQueryContext(query), SessionData.searchAppActions, maxResults, calculateFrecency);
    }`), "searchApplicationResults stays a thin adapter to the executable result builder");
});

// Set declined where the program derives it. A searchable query with a missing or checking
// backend cannot produce declined:false, so that fixture would cover an unreachable state.
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

// Keep extracted decisions independent of QML state so fixture inputs fully determine their behavior.
test("marked decision regions stay plain JavaScript", () => {
    for (const [label, source, marker, extraForbidden] of [
        ["AppSearchService.qml", appSearchSource, "APPLICATION SEARCH RELEVANCE DECISION", ["AppUsageHistoryData."]],
        ["DSearchService.qml", serviceSource, "SEARCH BACKEND DECISION", []],
        ["ResultsList.qml", resultsSource, "EMPTY STATE DECISION", []],
        ["Controller.qml", controllerSource, "FILE SEARCH DECISION", []]
    ]) {
        const region = regionOf(source, marker, label);
        for (const forbidden of ["root.", "Theme.", "I18n.", "Qt.", ...extraForbidden]) {
            assert.ok(!region.includes(forbidden),
                `the ${marker} block in ${label} must not reference ${forbidden} — it has to stay ` +
                "plain JavaScript, or the extraction is testing a different program");
        }
    }
});

// Text search depends on ripgrep; name search depends on fd. An unrecognized kind must not fall
// through to the fd decision.
test("backendCommandFor names the tool per kind and nothing for a foreign kind", () => {
    for (const [kind, expected] of [
        ["text", "rg"], ["files", "fd"], ["folders", "fd"], ["all", "fd"],
        ["zoxide", ""], ["sqlite", ""], ["", ""], [undefined, ""], [null, ""]
    ]) {
        assert.equal(backend.backendCommandFor(kind), expected,
            `${JSON.stringify(kind)} → ${JSON.stringify(expected)}: a kind naming no probed tool ` +
            "gets no answer from the gate");
    }
});

test("backendStateFor follows one tool flag per kind on a ready probe", () => {
    for (const [fd, rg] of TOOL_FLAGS) {
        assert.equal(backend.backendStateFor("text", "needle", ready(fd, rg)), rg ? "available" : "missing",
            `text search follows ripgrep alone (fd=${fd}, rg=${rg}) — reading the fd field is the ` +
            "original VGS-114 symptom: ripgrep installed, text search reported missing");
        for (const kind of ["files", "folders", "all"]) {
            assert.equal(backend.backendStateFor(kind, "needle", ready(fd, rg)), fd ? "available" : "missing",
                `${kind} follows fd alone (fd=${fd}, rg=${rg})`);
        }
    }
});

test("backendStateFor reports checking, unknown or nothing for unsettled and foreign probes", () => {
    for (const [kind, snapshot, expected, why] of [
        ["files", { state: "pending" }, "checking", "a probe that has not answered means CHECKING, not missing"],
        ["folders", { state: "pending" }, "checking", "for every fd-backed kind"],
        ["all", { state: "pending" }, "checking", "for every fd-backed kind"],
        ["text", { state: "pending" }, "checking", "and for text"],
        ["files", { state: "pending", fd: true, ripgrep: true }, "checking",
            "even with stale flags attached: telling a user to install a tool they already have " +
            "is the same dead end as saying nothing"],
        ["folders", { state: "pending", fd: true, ripgrep: true }, "checking", "stale flags, fd-backed kind"],
        ["all", { state: "pending", fd: true, ripgrep: true }, "checking", "stale flags, fd-backed kind"],
        ["text", { state: "pending", fd: true, ripgrep: true }, "checking", "stale flags, text"],
        ["files", { state: "retrying", fd: true, ripgrep: true }, "unknown",
            "a retry episode answers nothing about the tools, whatever the last flags said"],
        ["files", { state: "failed" }, "unknown", "a failed probe answers nothing about fd"],
        ["files", {}, "unknown", "an empty snapshot answers nothing"],
        ["files", null, "unknown", "and neither does no snapshot"],
        ["files", undefined, "unknown", "or an undefined one"],
        ["files", { state: "nonsense" }, "unknown", "or a state this service never publishes"],
        ["zoxide", ready(true, true), "unknown",
            "a kind this service never probes stays unknown even with both tools present"]
    ]) {
        assert.equal(backend.backendStateFor(kind, "needle", snapshot), expected,
            `${kind} with ${JSON.stringify(snapshot)}: ${why}`);
    }
});

// Kind and query order matters; swapping them can leave every backend lookup unknown.
test("backendStateFor's kind and query slots are not symmetric", () => {
    assert.notEqual(backend.backendStateFor("folders", "~/dev", ready(false, false)),
        backend.backendStateFor("~/dev", "folders", ready(false, false)),
        "backendStateFor's kind and query slots must not be symmetric");
});

// Pass the kind as well as probe state. Unknown name-search availability must not authorize
// a fallback directory walk; text search has no such walk and can report its tool failure directly.
test("dispatchAllowed answers per state and kind", () => {
    for (const [state, kind, expected, why] of [
        ["available", "files", true, "a tool proven present dispatches"],
        ["available", "text", true, "a tool proven present dispatches"],
        ["missing", "files", false, "a tool proven absent does block it"],
        ["missing", "text", false, "a tool proven absent does block it"],
        ["checking", "files", false, "a pending answer waits rather than guessing"],
        ["checking", "text", false, "a pending answer waits rather than guessing"],
        ["unknown", "text", true,
            "an unanswerable probe still dispatches text search: ripgrep fails fast with a real " +
            "cause, so refusing it would be a silence built on nobody's answer"],
        ["unknown", "files", false,
            "and does NOT dispatch an fd-backed name search: that buys the helper's full walk of " +
            "every root, which is the cost the fd gate exists to avoid and the recorded decision rejected"],
        ["unknown", "folders", false,
            "same for folders — a path completion reaches 'available' earlier, never this arm"]
    ]) {
        assert.equal(backend.dispatchAllowed(state, kind), expected, `${state}/${kind}: ${why}`);
    }
});

// Explicit folder paths use the helper's directory walk before fd lookup.
test("pathCompletion answers folder path queries without fd", () => {
    for (const [kind, query, expected] of [
        ["folders", "~/dev", true], ["folders", "~", true], ["folders", "/home/x", true],
        ["folders", "  ~/dev", true], ["folders", "/", true],
        ["folders", "dev", false], ["files", "~/dev", false], ["text", "~/dev", false], ["folders", "", false]
    ]) {
        assert.equal(backend.pathCompletion(kind, query), expected,
            `${kind}/${JSON.stringify(query)}: ${expected ? "a folder path query, answered without fd" :
                "an ordinary search, which does need its tool"}`);
    }
    assert.equal(backend.backendStateFor("folders", "~/dev", ready(false, false)), "available",
        "so folder completion stays available on a machine with neither tool");
    assert.equal(backend.backendStateFor("folders", "dev", ready(false, false)), "missing",
        "while a name search for the same kind is not");
});

// Check the helper branch that makes the QML path-completion exemption valid.
test("the helper routes a folder path query to its own walk before it looks up fd", () => {
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
});

test("helperHasFallback is true only for the fd-backed kinds", () => {
    for (const [kind, expected] of [["text", false], ["files", true], ["folders", true], ["all", true]]) {
        assert.equal(backend.helperHasFallback(kind), expected, expected ?
            `${kind} falls back to the helper's own walk, which vgsMenu accepts` :
            `${kind} shells out to ripgrep and raises without it — the service refuses it outright`);
    }
});

test("kindForType maps result types to search kinds, name search by default", () => {
    for (const [type, expected] of [
        ["dir", "folders"], ["text", "text"], ["zoxide", "zoxide"],
        ["file", "files"], ["all", "files"], ["", "files"], [undefined, "files"], ["nonsense", "files"]
    ]) {
        assert.equal(backend.kindForType(type), expected, `${JSON.stringify(type)} → ${expected}`);
    }
});

test("queryIsDispatchable needs two characters after trimming", () => {
    for (const [query, expected] of [
        ["ab", true], ["  ab  ", true],
        ["a", false], [" a ", false], ["", false], [" ", false], [undefined, false], [null, false]
    ]) {
        assert.equal(backend.queryIsDispatchable(query), expected, `${JSON.stringify(query)}`);
    }
});

// Single-character path starts can use folder completion without fd; length alone cannot reject them.
test("queryIsSearchable exempts folder paths from the length rule and nothing else", () => {
    for (const [kind, query, expected] of [
        ["folders", "~", true], ["folders", "/", true], ["folders", "~/", true], ["folders", "  ~  ", true],
        ["folders", "de", true],
        ["files", "~", false], ["files", "/", false], ["text", "~", false],
        ["folders", "d", false], ["folders", "", false], ["folders", " ", false]
    ]) {
        assert.equal(backend.queryIsSearchable(kind, query), expected,
            `${kind}/${JSON.stringify(query)}: the exemption is folders-only, and only for a path`);
    }
    assert.equal(backend.queryIsSearchable("folders", "~"), backend.pathCompletion("folders", "~"),
        "the exemption IS pathCompletion, not a second copy of it");
});

test("canDispatchFor composes the probe state with the per-kind rule", () => {
    for (const [fd, rg] of TOOL_FLAGS) {
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
});

// A failed reprobe must not replace an already successful tool discovery.
test("probeFailureOutcome keeps a ready answer and publishes retrying or failed otherwise", () => {
    for (const [state, attempt, max, expected, why] of [
        ["ready", 1, 3, { state: "ready", retry: true, publishReason: false },
            "a re-probe that fails leaves the previous successful answer standing, does not " +
            "overwrite its reason with this failure's, and still retries in the background"],
        ["ready", 3, 3, { state: "ready", retry: false, publishReason: false },
            "even once the retries are spent: the earlier answer is still the best one we have"],
        ["pending", 1, 3, { state: "retrying", retry: true, publishReason: true },
            "with no earlier answer, the first failure publishes retrying and its reason"],
        ["retrying", 2, 3, { state: "retrying", retry: true, publishReason: true },
            "a middle failure keeps retrying"],
        ["retrying", 3, 3, { state: "failed", retry: false, publishReason: true },
            "and the last one gives up, publishing the reason since there is nothing better to show"]
    ]) {
        assert.deepEqual(backend.probeFailureOutcome(state, attempt, max), expected,
            `${state} attempt ${attempt}/${max}: ${why}`);
    }
});

// A ready probe with missing tools still needs reprobe so installation can take effect without restart.
test("probeSettled is true only for a ready probe that found both tools", () => {
    for (const [snapshot, expected, why] of [
        [probe("ready", true, true), true, "everything found and answered"],
        [probe("ready", false, true), false,
            "ready with fd missing is the state we tell the user to act on: re-probe it, or the " +
            "product ignores its own instruction"],
        [probe("ready", true, false), false, "same for ripgrep"],
        [probe("pending", true, true), false, "pending is not an answer at all"],
        [probe("retrying", true, true), false, "retrying is not an answer at all"],
        [probe("failed", true, true), false, "failed is not an answer at all"],
        [null, false, "and neither is nothing"]
    ]) {
        assert.equal(backend.probeSettled(snapshot), expected, `${JSON.stringify(snapshot)}: ${why}`);
    }
});

// The service permits fallback directory walks that the overview gate declines.
test("serviceRefuses only a proven-missing tool with no fallback", () => {
    for (const [kind, state, expected, why] of [
        ["text", "missing", true, "text has no fallback, so the service refuses"],
        ["files", "missing", false, "files still reaches the helper's walk from the service — vgsMenu depends on it"],
        ["folders", "missing", false, "folders still reaches the helper's walk"],
        ["all", "missing", false, "all still reaches the helper's walk"],
        ["text", "available", false, "the service refuses only a PROVEN missing tool"],
        ["text", "unknown", false, "not an unknown one"],
        ["text", "checking", false, "nor one still being checked"]
    ]) {
        assert.equal(backend.serviceRefuses(kind, state), expected, `${kind}/${state}: ${why}`);
    }
});

// Use named empty-state fields and verify their producers at the QML adapter. Competing arms are
// made true together so swapped precedence becomes observable.
test("fileEmptyStateKey ranks the empty-state facts", () => {
    for (const [input, expected, why] of [
        [declinedFacts({ backendState: "checking" }), "checking",
            "a probe still running says so rather than claiming search is unavailable — and this " +
            "is the real startup state: the first probe declines every kind, so declined is true " +
            "here, and checking outranks declined or the startup window says the tools could not " +
            "be checked while they are being checked"],
        [declinedFacts({ backendState: "missing", missingCommand: "rg" }), "missing-rg", "a missing tool is named"],
        [declinedFacts({ backendState: "missing", missingCommand: "fd" }), "missing-fd", "a missing tool is named"],
        [facts({ queryLength: 0, searchable: false }), "prompt", "an empty field prompts"],
        [facts({ queryLength: 1, searchable: false }), "short", "a short query is short"],
        [facts({}), "empty", "a search that ran and found nothing"],
        [facts({ backendState: "unknown" }), "empty",
            "an unanswerable probe does not rewrite the result message — the search still ran"],
        [declinedFacts({ backendState: "missing", missingCommand: "fd", queryLength: 0, searchable: false }), "missing-fd",
            "a missing tool is worth saying before a query is typed"],
        [facts({ searchError: "ripgrep is required for text search" }), "error",
            "a search that RAN and failed shows the helper's own diagnosis rather than 'no results'"],
        [declinedFacts({ backendState: "unknown" }), "unchecked", "and one the gate refused says that instead"],
        [declinedFacts({ backendState: "missing", missingCommand: "fd", searchError: "boom" }), "missing-fd",
            "a missing tool outranks a leftover error: the tool is why the next search will fail too"],
        [facts({ backendState: "checking", queryLength: 0, searchable: false }), "prompt",
            "an empty field prompts even while the probe is outstanding"],
        [facts({ backendState: "checking", queryLength: 1, searchable: false }), "short",
            "and a short query is short, not checking"]
    ]) {
        assert.equal(view.fileEmptyStateKey(input), expected, `${JSON.stringify(input)}: ${why}`);
    }
});

test("fileHintKey names an install step or the probe's own state, and nothing beside a search that ran", () => {
    for (const [input, expected, why] of [
        [declinedFacts({ backendState: "missing", missingCommand: "rg" }), "install-rg", "a missing tool gets its install line"],
        [declinedFacts({ backendState: "missing", missingCommand: "fd" }), "install-fd", "a missing tool gets its install line"],
        [declinedFacts({ backendState: "unknown", probeState: "failed" }), "probe-failed",
            "a probe that could not run names ITSELF; blaming fd for it is the wrong cause"],
        [declinedFacts({ backendState: "unknown", probeState: "retrying" }), "probe-retrying",
            "a retry in progress asks the user for NOTHING — it will answer on its own, and the " +
            "reopen advice is a no-op while an episode is in flight"],
        [facts({ backendState: "unknown", probeState: "failed" }), "",
            "no probe line beside a search that actually ran, whatever the probe did"],
        [declinedFacts({ backendState: "checking", probeState: "pending" }), "",
            "the first probe reports NOTHING: there is no reason yet, and the message above " +
            "already says the tools are being checked"],
        [facts({}), "", "a working backend needs no install step"],
        [facts({ legActive: false, backendState: "missing", missingCommand: "fd" }), "",
            "no hint where no file search would have run: 'install fd' in a mode that never " +
            "searches files promises a fix that changes nothing"],
        [facts({ legActive: false, backendState: "unknown", probeState: "failed" }), "",
            "no probe line where no file search would have run"]
    ]) {
        assert.equal(view.fileHintKey(input), expected, `${JSON.stringify(input)}: ${why}`);
    }
});

test("fileEmptyIcon follows the state key, then the result type", () => {
    for (const [key, type, expected] of [
        ["checking", "file", "hourglass_empty"], ["missing-fd", "file", "search_off"],
        ["missing-rg", "text", "search_off"], ["unchecked", "file", "search_off"],
        ["error", "file", "search_off"], ["empty", "file", "insert_drive_file"],
        ["empty", "dir", "folder_open"], ["empty", "text", "article"]
    ]) {
        assert.equal(view.fileEmptyIcon(key, type), expected, `${key}/${type}`);
    }
});

test("errorLine keeps one bounded, printable line of the helper's diagnosis", () => {
    for (const [input, expected, why] of [
        ["ripgrep is required for text search", "ripgrep is required for text search", "an ordinary diagnosis passes through"],
        ["usage: vshell launcher-search\n  --kind\n  --limit", "usage: vshell launcher-search",
            "only the FIRST line: an argparse failure is a six-line usage block"],
        ["no such file: we\u0007ird\u202ename", "no such file: we ird name",
            "control and bidi characters are dropped — a filename out of the search roots ends up here"],
        ["", "", "nothing stays nothing"],
        [null, "", "and so does no diagnosis"]
    ]) {
        assert.equal(view.errorLine(input), expected, why);
    }
    assert.equal(view.errorLine("x".repeat(400)).length, 160,
        "and the length is bounded, so a whole argv cannot stretch the centered column");
});

test("fileSearchQueryFrom sends a file query only from a mode and form that search files", () => {
    for (const [mode, raw, parsed, expected, why] of [
        ["plugins", "/etc", "etc", "",
            "plugins mode runs no file search: a leading / is the plugin's own text there, and a " +
            "file result appended to plugin results is the regression this exclusion exists for"],
        ["files", "notes", "", "notes", "files mode searches the raw query"],
        ["files", "  notes  ", "", "notes", "trimmed"],
        ["all", "/notes", "notes", "notes", "the / form drops its prefix and searches from any non-plugins mode"],
        ["files", "/d notes", "notes", "notes", "including the typed-type form, whose parsed query is what arrives"],
        ["files", "/d /home/x", "/home/x", "/home/x", "the typed-type prefix passes a /-rooted query through intact"],
        ["all", "notes", "", "",
            "combined mode without the prefix sends nothing — the files-in-All settings reach no " +
            "search today, which is why this must not silently look like one"],
        ["apps", "notes", "", "", "apps mode searches no files"],
        ["files", "", "", "", "an empty query sends nothing"]
    ]) {
        assert.equal(files.fileSearchQueryFrom(mode, raw, parsed), expected,
            `${mode}/${JSON.stringify(raw)}/${JSON.stringify(parsed)}: ${why}`);
    }
});

// A bare slash is a launcher trigger; /d consumes its own prefix and preserves an absolute path query.
test("absolute-path folder completion is reachable from the overview with no tools at all", () => {
    const query = files.fileSearchQueryFrom("files", "/d /home/x", "/home/x");
    assert.ok(backend.pathCompletion("folders", query),
        "the manifest and the pathCompletion comment may not narrow the claim to ~-rooted queries again");
    assert.equal(backend.canDispatchFor("folders", query, ready(false, false)), true,
        "and it dispatches with no tools at all, which is what makes it worth documenting");
});

test("shouldRetryAfterProbe re-runs only an open surface with a searchable query", () => {
    for (const [active, searchable, expected, why] of [
        [true, true, true, "an open surface with a searchable query re-runs when the probe answers"],
        [false, true, false, "a closed one does not — the retry must not search behind a dismissed launcher"],
        [true, false, false, "nor one whose query would not dispatch"]
    ]) {
        assert.equal(files.shouldRetryAfterProbe(active, searchable), expected, why);
    }
});

test("fileLegActive is true for files mode and for any mode holding a searchable file query", () => {
    for (const [mode, searchable, expected, why] of [
        ["files", false, true, "files mode is a file surface even before a query is typed"],
        ["all", true, true, "and so is any mode holding a searchable file query"],
        ["plugins", false, false, "plugins mode is not"],
        ["apps", false, false, "nor is a mode with a query too short to dispatch"]
    ]) {
        assert.equal(view.fileLegActive(mode, searchable), expected, why);
    }
});

test("sortRanked preserves ranked sorting and grouped browsing", () => {
    const sortRegion = qmlSource.flat(stripComments(regionOf(menuSource,
        "LAUNCHER MENU SORT DECISION", "VGSMenu.qml")));

    assert.deepEqual(menuSort.sortRanked([
        { id: "low", kind: "command", title: "Low", rank: 120 },
        { id: "high", kind: "app", title: "High", rank: 9000 },
        { id: "mid", kind: "command", title: "Mid", rank: 4500 }
    ], false, false).map(item => item.id), ["high", "mid", "low"],
        "ranked sorting follows the one relevance score");

    assert.deepEqual(menuSort.sortRanked([
        { id: "group-b", kind: "command", title: "B command", rank: 10, group: 2 },
        { id: "group-a", kind: "command", title: "A command", rank: 5, group: 1 },
        { id: "group-z", kind: "command", title: "Z command", rank: 1, group: 1 }
    ], true, true).map(item => item.id), ["group-a", "group-z", "group-b"],
        "alphabetical grouped sorting still keeps a category's own entries above generated ones");

    for (const removed of ["filesLast", "allResultGroup"]) {
        assert.ok(!sortRegion.includes(removed),
            `VGSMenu sort logic must not keep the VGS-270 file-last rule: ${removed}`);
    }
});

// Require complete adapter calls so swapped arguments cannot satisfy independent token checks.

test("DSearchService adapters call the executed rules whole", () => {
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
});

test("statusState starts pending", () => {
    // An initially ready state would label installed tools missing before the probe answers.
    assert.ok(qmlSource.flat(stripComments(serviceSource))
        .includes('property string statusState: "pending"'),
        "statusState must START pending — before the first probe answers, nothing is known, and " +
        "any other initial value is a claim about tools nobody has looked for yet");
});

test("user text stays behind -- or joined to its flag in search, preview and list args", () => {
    const q = qmlSource(serviceSource, "DSearchService.qml");
    // Keep user text behind -- or in joined --flag=value arguments so it cannot become an option.
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
});


test("Controller's file search reads one authority and captures, clears and supersedes on every path", () => {
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
});

test("both abandonment branches supersede inside their own branch", () => {
    const q = qmlSource(controllerSource, "Controller.qml");
    // Check each abandonment branch separately; duplicate supersedes in one branch cannot cover another.
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
});

test("the search callback checks its generation before the spinner and the error", () => {
    const q = qmlSource(controllerSource, "Controller.qml");
    // Reject stale-kind responses before copying their error into the active view.
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
});

test("the declined gate clears stale results before it returns", () => {
    const q = qmlSource(controllerSource, "Controller.qml");
    // The stale-result clear must run before its return, not merely appear in the same function.
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
});

test("performSearch asks the owner about dispatch and carries no length literal", () => {
    const q = qmlSource(controllerSource, "Controller.qml");
    q.requires(q.body("performSearch"), "performSearch()", [
        ["DSearchService.canDispatch(fileSearchKind(), fileQuery)",
            "the spinner is set from the same per-kind answer, not from a single flag"],
        ["DSearchService.queryIsSearchable(fileSearchKind(), fileQuery)",
            "and from the same owner, kind included, so the spinner agrees with the gate about " +
            "which queries search at all"]
    ]);

    // Scope this ban to file search; plugin search uses a separate length rule.
    {
        // This literal-bearing landmark uses raw text. Preserved offsets map it to the structural brace walk.
        const branchAt = controllerSource.indexOf('if (searchMode === "files") {',
            controllerSource.indexOf("function performSearch("));
        const filesBranch = q.blockFrom(branchAt, "performSearch's files branch");
        assert.ok(!/length\s*[<>]=?\s*2/.test(stripComments(filesBranch)),
            "performSearch's files branch must not carry its own two-character literal — " +
            "DSearchService.queryIsDispatchable owns that rule");
        assert.ok(stripComments(filesBranch).includes("DSearchService.queryIsSearchable(fileSearchKind(), fileQuery)"),
            "and must ask the owner instead");
    }
});

test("every query, mode or reset change supersedes the in-flight search", () => {
    const q = qmlSource(controllerSource, "Controller.qml");
    q.requires(q.body("fileSearchKind"), "fileSearchKind()", [
        ["DSearchService.kindForType", "the type-to-kind mapping stays in its owner"]
    ]);

    // A response can outlive a mode change. It must not append file sections to another result mode.
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
});

test("_supersedeFileSearch alone moves the generation and clears in-flight state", () => {
    const q = qmlSource(controllerSource, "Controller.qml");
    // Abandonment must clear in-flight state as well as advance generation. A stale callback returns
    // before clearing the flag, so leaving it set can suppress empty states indefinitely.
    q.requires(q.body("_supersedeFileSearch"), "_supersedeFileSearch()", [
        ["_fileSearchGeneration++;", "the generation moves"],
        ["isFileSearching = false;", "and nothing is left marked in flight"]
    ]);
    assert.equal(
        (stripComments(controllerSource).match(/_fileSearchGeneration\+\+;/g) || []).length, 1,
        "and nowhere else raises the generation by hand — a bump outside the owner is a path " +
        "that has not said what it is abandoning");
});

test("a query typed before the probe answered re-runs when it lands", () => {
    const q = qmlSource(controllerSource, "Controller.qml");
    q.requires(q.body("_retryFileSearchAfterProbe"), "_retryFileSearchAfterProbe()", [
        ["if (!shouldRetryAfterProbe(active, DSearchService.queryIsSearchable(fileSearchKind(), fileSearchQuery())))",
            "the retry predicate is the executed one, reading the live active flag, the one " +
            "query authority and the one threshold — inverted or dropped, a query typed before " +
            "the answer never re-runs"],
        ["fileSearchDebounce.restart()",
            "a query typed before the probe answered is re-run when it lands"]
    ]);
});

test("ensureStatus runs from the launcher-opened branch only", () => {
    const q = qmlSource(controllerSource, "Controller.qml");
    // Require retry in the opened branch; the same token in the closed branch cannot provide recovery.
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
});

test("Controller re-runs the pending search on every probe signal", () => {
    for (const signal of ["onStatusStateChanged", "onFdAvailableChanged", "onRipgrepAvailableChanged"]) {
        assert.ok(qmlSource.flat(stripComments(controllerSource))
            .includes(`function ${signal}() { root._retryFileSearchAfterProbe(); }`),
            `Controller must re-run the pending search on ${signal}: the answer arrives after the ` +
            "user has typed, and nothing else would run the search again");
    }
});


    // Verify fact producers as well as consumers. A swapped kind/query or negation at the producer
    // can produce incorrect view state with every consumer call unchanged.
test("ResultsList computes its facts from the controller and the service per kind", () => {
    const code = qmlSource.flat(stripComments(resultsSource));
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
});


test("every fact reaches the empty-state snapshot", () => {
    const code = qmlSource.flat(stripComments(resultsSource));
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
});

test("ResultsList calls the executed rules with the whole snapshot", () => {
    const code = qmlSource.flat(stripComments(resultsSource));
    for (const [call, why] of [
        ["fileEmptyStateKey(_emptyStateFacts)", "the message reads the whole snapshot"],
        ["root.fileHintKey(root._emptyStateFacts)", "and so does the hint"],
        ["fileLegActive(controller?.searchMode ?? \"\", _fileQuerySearchable)",
            "and whether a file search is on screen comes from the executed rule, not a constant"]
    ]) {
        assert.ok(code.includes(qmlSource.flat(call)),
            `ResultsList must call \`${call}\` — ${why}`);
    }
});

test("getEmptyText has an arm per state key and renders errors through errorLine", () => {
    const q = qmlSource(resultsSource, "ResultsList.qml");
    q.requires(q.body("getEmptyText"), "getEmptyText()", [
        ["case \"unchecked\":", "a refused search has its own message"],
        ["case \"checking\":", "as does a probe still running"],
        ["case \"error\":", "and a search that ran and failed shows what the helper said"],
        ["root.errorLine(root.controller?.fileSearchError)",
            "through errorLine, never raw: that text can be a whole argv or a filename out of " +
            "the search roots, carrying control and bidi characters into a launcher overlay"]
    ]);
});

test("the empty-state message label is bounded", () => {
    const q = qmlSource(resultsSource, "ResultsList.qml");
    // Bound the diagnosis label so long messages cannot stretch the centered results column.
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
});
test("getDependencyHint has a retrying arm", () => {
    const q = qmlSource(resultsSource, "ResultsList.qml");
    q.requires(q.body("getDependencyHint"), "getDependencyHint()", [
        ["case \"probe-retrying\":",
            "a retry in progress gets its own line: the reopen advice is a no-op while an " +
            "episode is in flight, so telling the user to reopen would be telling them to do " +
            "nothing twice over"]
    ]);
});

// Reject single-tool flags alongside the shared gate so another path cannot bypass per-kind decisions.
test("no launcher surface reads a single-tool flag", () => {
    for (const [label, source] of [["Controller.qml", controllerSource], ["ResultsList.qml", resultsSource]]) {
        const code = stripComments(source);
        for (const banned of ["dsearchAvailable", "DSearchService.fdAvailable", "DSearchService.ripgrepAvailable"]) {
            assert.ok(!code.includes(banned),
                `${label} must not read \`${banned}\`: one flag answering for two backends is the ` +
                "defect — availability comes from DSearchService.backendState/canDispatch per kind");
        }
    }
});

// Verify vgsMenu uses the shared relevance, explicit file-routing and argv construction rules.

test("VGSMenu keeps All search local and uses shared relevance", () => {
    const q = qmlSource(menuSource, "VGSMenu.qml");
    const code = qmlSource.flat(stripComments(menuSource));

    q.requires(q.body("buildImmediateAllItems"), "buildImmediateAllItems()", [
        ["const q = AppSearchService.normalizeSearchText(trimmed);",
            "the menu uses the shared normalizer before command relevance"],
        ["const apps = AppSearchService.searchApplicationResults(trimmed);",
            "applications arrive with the canonical relevance score, not a second menu score"],
        ["next.push(appItem(apps[i]));",
            "that scored result is what builds the app row"],
        ["const textScore = commandTextRelevance(item, q);",
            "commands are scored once while the menu decides admission"],
        ["next.push(commandItem(item, textScore));",
            "the admitted command row reuses the score already computed"]
    ]);
    assert.ok(!code.includes("itemMatches("),
        "VGSMenu must not keep a second command relevance wrapper around commandItem");
    assert.ok(!stripComments(q.body("buildImmediateAllItems")).includes("fileItem("),
        "All builds no file or folder rows, including remembered file history");
    assert.ok(!stripComments(q.body("buildImmediateAllItems")).includes("launcherMenuUsageHistory"),
        "All does not read file history as a substitute file provider");

    q.requires(q.body("refreshAllItems"), "refreshAllItems()", [
        ["++fileSearchGeneration;", "existing file replies are invalidated when All takes over"],
        ["fileSearching = false;", "All has no file-provider request to wait for"]
    ]);
    assert.ok(!stripComments(q.body("refreshAllItems")).includes("DSearchService."),
        "unprefixed All does not call the file-search service");
    q.requires(q.body("refreshItems"), "refreshItems()", [
        ["if (item.category !== \"apps\")",
            "the Apps branch only admits built-in app-category commands"],
        ["nextApps.push(commandItem(item, 0));",
            "empty Apps browsing still includes built-in app-category commands"],
        ["nextApps.push(commandItem(item, textScore));",
            "typed Apps search reuses the command score already computed"]
    ]);

    q.requires(q.body("appItem"), "appItem()", [
        ["item.rank = (searchResult?.score || 0) + usageBonus(item);",
            "the row keeps AppSearchService's text score and adds only bounded launcher usage"]
    ]);
    q.requires(q.body("commandTextRelevance"), "commandTextRelevance()", [
        ["return AppSearchService.textRelevance(",
            "commands use the same field-aware relevance function as applications"],
        ["[item.title || \"\"]", "the title is the primary admission field"],
        ["[item.subtitle || \"\", category?.label || \"\", category?.description || \"\"]",
            "subtitle and category text are secondary fields only"]
    ]);
    assert.ok(code.includes(qmlSource.flat("function commandItem(item, textScore)")),
        "commandItem must take the already computed text score");
    q.requires(q.body("commandItem"), "commandItem()", [
        ["result.rank = (textScore || 0) + usageBonus(result);",
            "launcher usage is bounded and applied after text relevance"]
    ]);

    assert.ok(!code.includes("AppSearchService.searchApplications("),
        "VGSMenu must not select applications with searchApplications() and rank them again");
});

test("VGSMenu All search avoids the file provider", () => {
    assertAllSearchRouteAvoidsFileProvider(menuSource, "VGSMenu.qml");
    assert.throws(() => assertAllSearchRouteAvoidsFileProvider(replaceOnce(menuSource,
        "    function refreshAllItems() {\n        folderCompletion = \"\";",
        "    function refreshAllItems() {\n        DSearchService.search(trimmed, { kind: \"all\", limit: 80 }, () => {});\n        folderCompletion = \"\";",
        "All search provider"), "mutated VGSMenu.qml"),
        /calling DSearchService\.search/,
        "the All-search provider guard must fail when refreshAllItems starts DSearchService.search");

});

test("VGSMenu asks the explicit file threshold owner", () => {
    const code = qmlSource.flat(stripComments(menuSource));
    assert.ok(code.includes(qmlSource.flat(
        "return DSearchService.queryIsSearchable(DSearchService.kindForType(fileSearchType), trimmed) || fileSearchType === \"zoxide\";")),
        "VGSMenu keeps the shared threshold owner for explicit file searches");
});

test("VGSMenu's dispatch site and files empty state agree through the shared predicate", () => {
    const q = qmlSource(menuSource, "VGSMenu.qml");
    const code = qmlSource.flat(stripComments(menuSource));
    // Dispatch and empty state must agree on explicit path exemptions.
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
});

test("openFolder terminates its options before the path and joins the configured command to its flag", () => {
    const q = qmlSource(menuSource, "VGSMenu.qml");
    const openFolder = q.body("openFolder");
    const terminator = openFolder.indexOf('args.push("--", path);');
    const launched = openFolder.indexOf("Quickshell.execDetached(args)");
    assert.notEqual(terminator, -1,
        "openFolder must terminate its options before the path, exactly as search() and " +
        "preview() do — the folder-open command is user-configured");
    assert.ok(terminator < launched, "and do it before launching");
    assert.ok(qmlSource.flat(stripComments(openFolder)).includes('args.push("--command=" + SettingsData.launcherFolderOpenCommand);'),
        "and pass that configured command joined to its flag");
});

// Scope shared-length checks to file dispatch functions; other search kinds have distinct thresholds.
test("no file dispatch function carries its own two-character literal", () => {
    for (const [label, source, fns] of [
        ["Controller.qml", controllerSource, ["performFileSearch", "fileSearchQuery", "_retryFileSearchAfterProbe"]],
        ["VGSMenu.qml", menuSource, ["refreshFileItems"]]
    ]) {
        const q = qmlSource(source, label);
        for (const fn of fns) {
            const body = stripComments(q.body(fn));
            assert.ok(!/length\s*[<>]=?\s*2/.test(body),
                `${label}::${fn} must not carry its own two-character literal — ` +
                "DSearchService.queryIsDispatchable owns that rule for every search surface");
        }
    }
});

// The helper must also preserve option/value separation when constructing fd arguments.
test("the helper joins fd's exclude values to the flag and checks fd's exit", () => {
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
});

// Optional chaining on the controller does not protect a renamed or absent method.
test("every controller method ResultsList calls exists in Controller.qml", () => {
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
});




test("_statusProbeFailed publishes the executed rule's answer and keeps retrying", () => {
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
});

test("_probeStatus names a timeout, routes every failure through one handler and publishes flags only on success", () => {
    const q = qmlSource(serviceSource, "DSearchService.qml");
    // Distinguish timeout from nonzero exit and ensure unreadable probe output leaves pending state
    // with a reported failure instead of permanently blocking name search.
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
});

test("_probeStatus checks its generation first and returns on a stale one", () => {
    const q = qmlSource(serviceSource, "DSearchService.qml");
    // Check generation before clearing in-flight state or publishing failure.
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

        // The stale-generation guard must return; a condition that only logs still applies the stale result.
        const guarded = stripComments(probeBody.slice(guard + guardCondition.length));
        assert.ok(/^\s*\{?\s*return;/.test(guarded),
            "the generation guard's very next statement must be `return;`: a stale probe that " +
            "carries on after being detected is not guarded, it is announced");
    }
});

test("rediscover is single-flight before it resets the retry budget", () => {
    const q = qmlSource(serviceSource, "DSearchService.qml");
    // Check single-flight state before resetting retry budgets so repeated opens cannot restart the allowance.
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
});

test("the whole-subsystem flag stays deleted and helperHasFallback stays derived", () => {
    const code = stripComments(serviceSource);
    assert.ok(!/property\s+bool\s+dsearchAvailable/.test(code),
        "the whole-subsystem flag must stay deleted: leaving it is what the next caller adopts");
    assert.ok(/kindForType\(params\?\.type\)/.test(qmlSource.flat(code)),
        "search() must derive its kind from the shared mapping rather than a sixth copy");
    assert.ok(/function helperHasFallback\(kind\) \{ return backendCommandFor\(kind\) === "fd"; \}/
        .test(qmlSource.flat(code)),
        "helperHasFallback must stay DERIVED from the command table; restated as its own list " +
        "of kinds it drifts, and a kind then needs a tool nobody probed");
});
