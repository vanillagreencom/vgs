#!/usr/bin/env node

// Inspect how AiUsageWidget applies its shared decisions. These checks parse source
// and do not execute its fetch paths. Whitespace normalization permits line wrapping.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.join(__dirname, "..");
const PLUGIN = path.join(repoRoot, "config", "vshell", "plugins", "aiUsage");
const WIDGET = path.join(PLUGIN, "AiUsageWidget.qml");
const source = fs.readFileSync(WIDGET, "utf8");

const { blockFrom, body, handlers, requires, indexOf, lastIndexOf, stripComments } =
    require("./lib/qml-source.js")(source, "AiUsageWidget.qml");

// Use comment-blanked text for bans and code structure for landmarks.
// Required tokens must agree in both views at the same offset.
const code = stripComments(source);

// Run helper self-tests before using the helpers against widget source.
require("./lib/qml-source.js").selfTest();

test("the shared source reader walks whole blocks and strips comments from the widget source", () => {
    const walked = body("storeHeadline");
    assert.ok(walked.startsWith("{") && walked.endsWith("}"), "the walk returns a whole block");
    assert.ok(walked.includes("root.providerFiledAt = nextAt"), "the walk reaches the end of the block");
    assert.ok(!walked.includes("function noteHeadline"), "the walk stops at the block it was asked for");
    const stripped = stripComments('a(); // "Claude" lives here\nb("kept"); /* gone */ c();');
    assert.ok(!stripped.includes("Claude"), "a line comment must not survive stripping");
    assert.ok(!stripped.includes("gone"), "a block comment must not survive stripping");
    assert.ok(stripped.includes('b("kept")'), "code must survive stripping");
});

test("storeHeadline files by key with a stamp and noteHeadline files under the payload's own provider", () => {
    const store = body("storeHeadline");
    requires(store, "storeHeadline()", [
        ["next[which] = data", "a headline is filed by key, never by branch"],
        ['if (which === "")', "an unidentifiable provider files nothing"],
        ["root.fileSeq += 1", "every filing takes the next stamp"],
        ["nextAt[which] = root.fileSeq", "and records it — the ordering evidence failures read"],
        ["const order = logic.providerOrder()",
            "and the copy it files into is built from the catalog, so a provider added there " +
            "keeps its filed payload instead of being dropped by a hand-written field list"]]);
    assert.ok(!/(claudeData|codexData|vercelData)\s*=/.test(store),
        "a per-provider branch is what let an unknown provider land under Claude");
    assert.ok(body("noteHeadline").includes("logic.payloadProvider(data)"),
        "the provider filed under is the payload's own, not the fetch's tag");
});

test("acceptPayload decodes against its own channel's tag and files by the payload's provider", () => {
    const accept = body("acceptPayload");
    requires(accept, "acceptPayload()", [
        ["logic.decodePayload(ch.inFlight, txt)", "validated against ITS OWN channel's tag"],
        ["ch.issue = got.issue", "the reason is recorded on the channel that fetched it"],
        ["ch.accepted = true", "acceptance is what tells the exit path a payload arrived"],
        // Match the complete call; separate operands can also appear in unrelated statements.
        ["logic.acceptOutcome(logic.payloadProvider(got.data), ch.want)",
            "the outcome is decided from the payload's OWN provider and what this channel wants"],
        ["outcome.file", "a payload that names a provider updates that provider's slot"],
        ["root.noteHeadline(got.data)", "which is what files it"],
        ["outcome.satisfies", "a payload that does not satisfy this channel goes no further"],
        ["ch.loaded = ch.want", "the channel records what it holds, or relaunch answers true"],
        ["ch.retries = 0", "a satisfying payload restores the retry budget"]
    ]);
});

const channel = blockFrom(indexOf("component FetchChannel:"), "FetchChannel");
test("FetchChannel owns its process, collectors and timers and settles on both halves", () => {
    requires(channel, "FetchChannel", [
        ["property Process proc: Process {", "the channel owns its process"],
        ["stdout: StdioCollector {", "and its stdout collector"],
        ["stderr: StdioCollector {", "and its stderr collector"],
        ["property Timer stallTimer: Timer {", "the watchdog that reports a start that never ran"],
        ["property Timer retryTimer: Timer {", "and the timer its retries wait on"],
        ["onTriggered: root.launch(chan)", "which relaunches THIS channel when the wait is over"],
        ['property string want: ""', "and the provider it fetches"],
        ["chan.outDone = true; root.acceptPayload(chan, outCollector.text);",
            "stdout marks its half done and goes to this channel's accept path, IN THAT ORDER"],
        ["root.completeFetch(chan)",
            "and then asks whether the fetch is finished — settling on the exit alone cleared the " +
            "tag the payload is decoded against, discarding a valid payload as a mismatch"],
        ["property Timer flushTimer: Timer {",
            "and an exit that lands first waits on a BOUNDED grace, so a stream that never closes " +
            "still settles"],
        ["onStreamFinished: chan.errorOut = errCollector.text",
            "stderr is captured when the stream ends, not read at exit time: StdioCollector fills " +
            "text only once the stream closes, which is the repo idiom"],
        ["onExited: (exitCode, exitStatus) => root.finishFetch(chan, exitCode, exitStatus)",
            "the exit carries both the code and the status of THIS channel's process"],
        ["onTriggered: root.settleFetch(chan)", "and the grace timer settles this channel's fetch"],
        ["onStarted: chan.sawProcess = true",
            "and a launch that produced a process records it, which is what tells a slow exit " +
            "from a start that never ran"],
        ['command: [root.aiUsageCommand, "ai-usage", chan.want]',
            "the process fetches the provider its own channel wants"]
    ]);
});

// Inspect everything outside the extracted channel block, using its opening-brace offset.
// A component-keyword offset would remove the wrong span and leave part of the block behind.
test("no per-channel process or collector is nameable outside the channel", () => {
    const componentAt = indexOf("{", indexOf("component FetchChannel:"));
    assert.equal(source.slice(componentAt, componentAt + channel.length), channel,
        "the removed span is exactly the component block, starting at its own open brace");
    const outside = source.slice(0, componentAt) + source.slice(componentAt + channel.length);
    assert.ok(!/\b(usageProc|otherProc|usageOut|otherOut|usageErr|otherErr)\b/.test(stripComments(outside)),
        "per-channel processes and collectors are not nameable from outside the channel");
});

test("one channel per provider is built from the catalog, and none is named by hand", () => {
    const instantiator = blockFrom(indexOf("Instantiator {"), "the channel Instantiator");
    requires(instantiator, "the channel Instantiator", [
        ["model: logic.providerOrder()",
            "channels come from the same catalog the slots and the filter come from, so a provider " +
            "cannot be listed on the bar with nothing able to fetch it"],
        ["delegate: FetchChannel {", "each entry gets its own channel"],
        ["want: modelData", "fetching the provider it was built for"]
    ]);
    assert.ok(!/\bid:\s*(usageFetch|otherFetch|claudeFetch|codexFetch|vercelFetch)\b/.test(code),
        "no channel is named for one provider by hand: that is how a provider gets added to the " +
        "catalog and silently never fetched");
    assert.ok(!/\botherProvider\b/.test(code),
        "and there is no 'the other provider' any more — every selected provider is fetched");
    const refresh = body("refresh");
    requires(refresh, "refresh()", [
        ["for (let i = 0; i < channels.count; i++)", "a refresh visits every channel there is"],
        ["root.launch(ch)", "launching each through the shared decision"]
    ]);
});

test("completeFetch and finishFetch settle once, on both halves, with a bounded flush wait", () => {
    // Either failure path can settle first; settlement must be idempotent.
    assert.ok(body("finishFetch").includes('if (ch.inFlight === "")'),
        "an exit arriving after the watchdog settled must not report twice, nor settle a relaunch");

    requires(body("completeFetch"), "completeFetch()", [
        ['if (ch.inFlight === "")', "a settled fetch is not completed twice"],
        ["if (!ch.outDone || !ch.exitDone)", "BOTH halves must have landed, in either order — the " +
            "tag has to outlive the payload path, which is what the payload is decoded against"],
        ["if (ch.exitDone) ch.flushTimer.restart()", "and only an exit that landed first waits, " +
            "on a bound, so a stream that never closes cannot hang the fetch"],
        ["root.settleFetch(ch)", "and the last half in settles"]]);
    requires(body("finishFetch"), "the exit half of finishFetch()", [
        ["ch.exitDone = true", "the exit records its half rather than settling on its own"]]);
});

test("failLaunch re-asks the arming rule, names the command and settles", () => {
    requires(body("failLaunch"), "failLaunch()", [
        ["if (!logic.watchdogArms(ch.inFlight, ch.sawProcess))",
            "the arming rule is asked again at the moment of reporting — one function, so a fetch " +
            "that settled or a process that started while the timer waited is never a failed start"],
        ['ch.issue = "could not run " + root.aiUsageCommand', "a failed start names the command"],
        ["console.warn", "and says so in the log"],
        ["root.settleFetch(ch)", "then settles like a failed exit — retried, then reported"]]);
});

test("finishFetch names a signal death apart from a failure, captures stderr's last line and caps it", () => {
    const finish = body("finishFetch");
    requires(finish, "finishFetch()", [
        ["exitCode !== 0 || exitStatus !== 0",
            "a helper killed by a signal did not fail on its own terms; branching on the exit code " +
            "alone left the empty output's 'parse error' as the cause"],
        ['exitStatus !== 0 ? "helper killed"', "and says which of the two happened"],
        ["logic.stderrReason(ch.errorOut, root.maxIssueChars)",
            "the reason is the captured stderr's last line, truncated"],
        ["console.warn", "the failure has to reach vshell logs, or the cause exists nowhere"],
        ["root.completeFetch(ch)", "and then asks whether BOTH halves have landed, rather than " +
            "settling on the exit alone"]]);
    // The provider tests enforce the supplied stderr limit. This assertion fixes the limit supplied by the widget.
    const capMatch = code.match(/property int maxIssueChars: (\d+)/);
    assert.ok(capMatch, "the reason's cap must be a named property, not a literal at the call site");
    const cap = Number(capMatch[1]);
    assert.ok(cap > 0 && cap <= 500,
        `maxIssueChars is ${cap}: that caps nothing — the line comes from whichever backend is ` +
        "installed and lands in the popout and in logs people paste into bug reports");
});

test("settleFetch relaunches through the shared predicate before clearing the tag and files through the ordering rule", () => {
    const settle = body("settleFetch");
    requires(settle, "settleFetch()", [
        // Use channel fields to avoid exchanging same-typed provider arguments.
        ["logic.shouldRelaunch(ch, root.maxFetchRetries)", "relaunch is the shared predicate's"],
        ['if (ch.inFlight === "")', "a fetch already settled is settled once"],
        ["ch.retries += 1", "a relaunch spends a retry, or the budget bounds nothing"],
        // Retries need a delay; consecutive event-loop turns can exhaust the budget in a burst of API calls.
        ["ch.retryTimer.interval = root.retryDelayMs * ch.retries",
            "the wait grows with the attempt number rather than being one fixed tick"],
        ["ch.retryTimer.restart()", "and the retry runs off that timer, not the event loop"],
        ["ch.stallTimer.stop()", "a settled fetch stops its own watchdog"],
        // A parked request can run immediately after the old process settles. Require exact occurrence counts
        // so a delayed retry cannot acquire an extra immediate path.
        ["if (ch.pending)", "a parked request is drained when the channel settles", 1],
        ["Qt.callLater(() => root.launch(ch))",
            "by launching it promptly — and this is the ONLY immediate deferral left in settleFetch", 1],
        ["ch.loaded !== ch.want || !ch.accepted",
            "a poll that delivered nothing for this channel's provider is a failure"],
        ['ch.issue !== "" ? ch.issue : "usage unavailable"', "the recorded reason, else the generic"],
        ["logic.failureWins(root.providerData[ch.want], root.providerFiledAt[ch.want], ch.launchSeq)",
            "and it is filed only if no newer answer for that provider has landed since this launch", 1],
        ["root.storeHeadline(ch.want, { ok: false, provider: ch.want", "filed for its own provider"]]);
    assert.ok(settle.indexOf("logic.shouldRelaunch") < settle.indexOf('ch.inFlight = ""'),
        "the decision reads the tag, so it is taken BEFORE the tag is cleared");
    assert.ok(!/root\.(fetchError|loading)\b/.test(stripComments(settle)),
        "a failure reaches the popout as the FILED payload for its provider and nowhere else — a " +
        "second widget-level error string is what let one provider's failure caption a popout " +
        "showing another provider's accounts");
});

test("the one exit handler lives on the channel's own process", () => {
    const exits = handlers("onExited");
    assert.equal(exits.length, 1, "the one exit handler lives on the channel's own process");
});

test("every surface reads one description of what is in scope", () => {
    requires(source, "AiUsageWidget.qml", [
        ["readonly property var deckState:",
            "the pill, the deck and the header counts read ONE object, so they cannot disagree " +
            "about which providers or accounts are in scope"],
        ["providerData: root.providerData", "which carries every filed payload"],
        ["filter: root.providerFilter", "the providers the user is looking at"],
        ["hidden: root.hiddenAccounts", "the accounts they are not"],
        ["mode: root.headlineMode", "how several accounts combine into one number"],
        ["fetching: root.fetchingProviders", "and which providers are mid-fetch"],
        ["readonly property var view: logic.deckView(root.deckState)",
            "the popout is that state's deck"],
        ["return logic.pillSlots(root.deckState)", "and the bar is that same state's slots"]
    ]);
    assert.ok(!/aggregatePct|primaryPct/.test(code), "a second owner is a second answer");
    assert.ok(!/root\.current\b/.test(code),
        "there is no single 'current provider' payload any more: every selected provider is on " +
        "screen at once, and one of them being selected is what made looking at Codex move the " +
        "bar off Claude");
});

test("both pill orientations render the same slots, and neither invents a number", () => {
    for (const which of ["horizontalBarPill", "verticalBarPill"]) {
        const pill = blockFrom(indexOf(which + ":"), which);
        assert.ok(pill.includes("model: root.pillHeads()"),
            `${which} renders the shared slots, so the two orientations cannot say different ` +
            "things about one payload");
        assert.ok(pill.includes("text: modelData.text"),
            `${which} shows what the slot says, not its own reading of the payload`);
        assert.ok(pill.includes("provider: modelData.provider"),
            `${which} draws each slot's provider mark from the slot itself`);
        // A setup slot has no number: it keeps the key glyph and the accent, so it reads as an
        // invitation rather than as a reading that failed to load, and the icon setting cannot
        // hide it — an empty slot leaves the way in unreachable.
        assert.ok(pill.includes("visible: modelData.setup") && pill.includes("color: Theme.primary"),
            `${which} draws a setup slot as an invitation, unconditionally`);
        assert.ok(pill.includes("visible: root.barSlotIcons && !modelData.setup"),
            `${which} hides only a provider MARK when the icon mode is not the per-slot one`);
        // The single-icon mode is the widget's own mark, drawn once ahead of the numbers.
        // It is a sibling of the Repeater, not inside it, or a bar with three slots would
        // draw the same widget icon three times.
        assert.ok(pill.includes("visible: root.barWidgetIcon") && pill.includes("name: root.widgetIcon()"),
            `${which} draws the widget's own mark once for the whole widget in the "one" mode`);
        assert.ok(pill.indexOf("visible: root.barWidgetIcon") < pill.indexOf("Repeater {"),
            `${which} draws that mark ahead of the slots rather than once per slot`);
        assert.ok(!/"smart_toy"|"data_usage"/.test(pill),
            `${which} takes the widget's glyph from the catalog rather than spelling it out`);
        assert.ok(!/headlinePct/.test(stripComments(pill)),
            `a raw percentage in ${which} is how it came to show 60% beside an error glyph`);
    }
});

test("the popout's account-scoped state comes from the view, not the payloads' top-level fields", () => {
    requires(source, "AiUsageWidget.qml", [
        ["readonly property bool ok: root.view.ok",
            "whether anything usable is on screen is that view's answer, not a payload's own field"],
        ["readonly property bool pending: root.view.pending",
            "and whether it is merely still fetching comes from there too"],
        ["readonly property bool allHidden: root.view.allHidden", "and the all-hidden case"],
        ["readonly property string errorText: root.view.error", "and the cause"],
        ["readonly property var view: logic.deckView(root.deckState)", "from one function"]
    ]);
    assert.ok(!/root\.providerData\.(claude|codex|vercel)\b/.test(code),
        "no surface reaches past the view into one named provider's payload");
});

test("detailsText answers pending, setup and all-hidden before any percentage, and counts through accountCount", () => {
    const details = blockFrom(indexOf("detailsText:"), "detailsText");
    assert.ok(details.includes("root.pending ?") || details.includes("if (root.pending)"),
        "a popout with nothing yet must say it is fetching, not that usage is Unavailable — a " +
        "fault invented on every first load");
    assert.ok(details.includes("root.view.needsSetup"),
        "a provider nobody has configured is not a failure to report either");
    assert.ok(details.includes("if (root.allHidden)"),
        "the header must answer the all-hidden case before it prints any percentage");
    assert.ok(details.indexOf("root.allHidden") < details.indexOf("% used"),
        "and answer it BEFORE the percentage, not after");
    assert.ok(details.indexOf("root.view.needsSetup") < details.indexOf("root.errorText"),
        "and offer setup before it reports a fault");

    const detailsCode = stripComments(details);
    assert.ok(!/\+\s*" accounts?\b/.test(detailsCode),
        "both header lines count accounts through logic.accountCount(), so neither can lose its " +
        "singular: hiding a three-account payload down to one visible read '1 accounts'");
    assert.equal((details.match(/logic\.accountCount\(/g) || []).length, 2,
        "which is once per counted line — the card line and the all-hidden line");
    assert.ok(details.includes("root.hasHeadline ?"),
        "and print no percentage when there is no headline — several accounts on screen, none ok, " +
        "where the pill already shows its placeholder");
});

test("every account renders through the one card, and nothing hand-draws a second layout", () => {
    const cards = blockFrom(indexOf("AiUsageAccountCard {"), "the account card delegate");
    requires(cards, "the account card delegate", [
        ["host: root", "reaching the formatting helpers through the host"]
    ]);
    // The card sits inside a slot Item that holds the gap above it, so the delegate's model
    // object is reached through that slot's id. What matters is that the binding is the deck's
    // own card object and that expansion is keyed by `.key`, not which id carries it here.
    assert.ok(/account: (cardSlot\.)?modelData\b/.test(cards),
        "a card renders the card the deck built");
    assert.ok(/expanded: root\.cardExpanded\((cardSlot\.)?modelData\.key\)/.test(cards),
        "and expansion is keyed by the provider-qualified key, so two providers' accounts " +
        "sharing an id cannot expand each other");
    assert.equal((code.match(/AiUsageAccountCard \{/g) || []).length, 1,
        "one card component, used once: a single-account layout beside a multi-account one is " +
        "what made an account change shape when a sibling appeared");
    assert.ok(!/MeterRow \{|MeterCard \{/.test(code),
        "and the meters live inside that card rather than being drawn again by the widget");
});

test("provider identity is the logic's, and no surface spells a provider out", () => {
    assert.ok(code.includes("model: logic.providerOrder()"),
        "the channels are generated from the same order the slots and the filter use");
    for (const literal of ['"Claude"', '"Codex"', '"Vercel"', '"Vercel AI Gateway"', '"smart_toy"',
                           '"terminal"', '"change_history"'])
        assert.ok(!code.includes(literal),
            `${literal} must live only in AiUsageLogic — a second copy in CODE is where a rename drifts`);

    // A child never takes the decision module through a property: `logic: logic` resolves the
    // right-hand side against the object being declared, so the property being assigned shadows
    // the id and the child silently binds to itself. It reaches the catalog through the host, or
    // it constructs one.
    for (const file of ["AiUsageFilterMenu.qml", "AiUsageFilterRow.qml", "AiUsageAccountCard.qml",
                        "AiUsageProviderNotice.qml", "AiUsageProviderSetup.qml",
                        "AiUsageDisplaySettings.qml"]) {
        const child = stripComments(fs.readFileSync(path.join(PLUGIN, file), "utf8"));
        assert.ok(!/property\s+var\s+logic\b/.test(child),
            `${file} must not take the decision module through a property`);
        for (const literal of ['"Claude"', '"Codex"', '"Vercel"', '"smart_toy"', '"terminal"']) {
            assert.ok(!child.includes(literal),
                `${file} spells out ${literal}: provider identity has exactly one owner`);
        }
    }
    assert.ok(!/property\s+var\s+logic\b/.test(code),
        "and the widget names its own instance rather than exposing it for a child to bind to");
});

test("both settings surfaces embed the same setup component", () => {
    const settings = stripComments(fs.readFileSync(path.join(PLUGIN, "AiUsageSettings.qml"), "utf8"));
    assert.ok(/AiUsageProviderSetup\s*\{/.test(settings),
        "the settings application shows the same sources page the popout does, or a key can only " +
        "be added from a bar flyout and the two surfaces drift into offering different sources");
    assert.ok(settings.includes("model: catalog.providerOrder()"),
        "with one section per provider, from the catalog rather than a list written out here");
    assert.ok(/AiUsageDisplaySettings\s*\{/.test(settings) && /AiUsageDisplaySettings\s*\{/.test(code),
        "and BOTH surfaces carry the display page: bar number, what the slots read, the icons, " +
        "the colour and the card default are one set of choices, or the two pages drift");
    assert.ok(/AiUsageProviderSetup\s*\{/.test(code), "and the popout embeds it too");

    const setup = stripComments(fs.readFileSync(path.join(PLUGIN, "AiUsageProviderSetup.qml"), "utf8"));
    assert.ok(!/\broot\.host\b/.test(setup),
        "which it can only do because the page depends on no widget: the settings application is " +
        "not one and has no catalog to lend it");
    assert.ok(setup.includes("signal sourcesChanged"),
        "a source change is announced rather than acted on, because what to do about it differs " +
        "between a widget that can refetch and a settings page that cannot");
    for (const surface of [code, settings]) {
        assert.ok(/onSourcesChanged:\s*(root\.stampSources\(\)|root\.saveValue\("sourcesStamp")/.test(surface),
            "and each surface stamps it, so a key added on either one reaches every bar instance " +
            "instead of waiting out a poll interval");
    }
    assert.ok(body("stampSources").includes('root.saveSetting("sourcesStamp", Date.now())'),
        "the stamp travels through the plugin service, which is what reaches bars on other screens");
    assert.ok(code.includes("onSourcesStampChanged: root.refresh()"),
        "and every widget instance refetches when it changes");
});

test("every provider mark ships beside the plugin and is colorisable", () => {
    const logicSource = fs.readFileSync(path.join(PLUGIN, "AiUsageLogic.qml"), "utf8");
    const assets = Array.from(logicSource.matchAll(/return "([a-z0-9-]+\.svg)";/g), m => m[1]);
    assert.ok(assets.length > 0, "the catalog must name the marks it ships, or this checks nothing");
    for (const asset of assets) {
        const file = path.join(PLUGIN, asset);
        assert.ok(fs.existsSync(file),
            `${asset} is named by the catalog but not shipped beside the plugin: the icon falls ` +
            "back to its Material symbol, which is the fallback working, not the mark loading");
        const svg = fs.readFileSync(file, "utf8");
        assert.ok(!/currentColor/.test(svg),
            `${asset} fills with currentColor: Qt's SVG renderer has no CSS context for it and ` +
            "paints BLACK, and colorising black does nothing — MultiEffect's colorisation keeps " +
            "luminance. That is a black glyph on a dark bar");
        assert.match(svg, /fill="#(FFFFFF|ffffff)"/,
            `${asset} must fill white, which is the source a colorisation turns into the asked-for ` +
            "colour — the convention the shell's own matrix-logo-white.svg follows");
    }
});

test("the filter is persisted through the shared toggle, and clearing it means all", () => {
    requires(body("toggleProvider"), "toggleProvider()", [
        ['root.saveSetting("providerFilter", logic.toggleFilter(root.providerFilter, p))',
            "a filter change is the shared decision's result, persisted — computing the next " +
            "filter at the call site is where 'unchecking the last provider' loses its way back"]]);
    requires(body("selectAllProviders"), "selectAllProviders()", [
        ['root.saveSetting("providerFilter", [])',
            "and 'all' is stored as nothing, so a provider added later is included without a migration"]]);
    requires(body("toggleHidden"), "toggleHidden()", [
        ["logic.toggleHiddenCard(root.hiddenAccounts, card)",
            "hiding an account writes the provider-qualified key through the shared rule, which is " +
            "also what drops a legacy bare id for the same account"]]);
    assert.ok(body("saveSetting").includes('root.pluginService.savePluginData("aiUsage"'),
        "every setting is persisted through the plugin service rather than by assigning the bound " +
        "property, so each bar instance keeps receiving pluginData updates");
    assert.ok(!/pluginData\.provider\b/.test(code),
        "the single-selected-provider setting is gone; a filter of providers replaced it");
});

test("the setup page is mounted only while it is on screen", () => {
    const setup = blockFrom(indexOf("AiUsageProviderSetup {"), "the setup page");
    requires(setup, "the setup page", [
        ["provider: popout.setupProvider", "it shows the provider the user asked about"],
        ["active: popout.onSetup",
            "and reads the helper only while it is on screen: this page is one of three in a Row " +
            "and is built whether or not anyone opened it"]
    ]);
});

test("the poll interval scales with the accounts actually being visited", () => {
    const timer = blockFrom(lastIndexOf("Timer {", indexOf("onTriggered: root.refresh()")), "pollTimer");
    assert.ok(timer.includes("root.view.totalCount"),
        "polling visits accounts sequentially across every provider, so the floor has to count " +
        "all of them — counting one provider's set left three providers' accounts sharing one " +
        "provider's interval");
    assert.ok(timer.includes("root.refreshSeconds"), "and the user's interval is still the floor");
});

test("the display page's unpadded switch rows carry no row-wide hover wash", () => {
    const display = stripComments(fs.readFileSync(path.join(PLUGIN, "AiUsageDisplaySettings.qml"), "utf8"));
    const unpadded = (display.match(/horizontalPadding:\s*0\b/g) || []).length;
    const unwashed = (display.match(/rowHoverHighlight:\s*false\b/g) || []).length;
    assert.ok(unpadded > 0, "the switch rows still set their own inset to nothing");
    assert.equal(unwashed, unpadded,
        "and every row that drops that inset drops the row-wide hover wash with it: a full-bleed " +
        "rectangle behind a label with no padding reads as a box drawn around the text. The " +
        "switch's own press feedback and the row's click are unaffected");
});

test("every value the shared display page reads is supplied by BOTH surfaces", () => {
    const display = stripComments(fs.readFileSync(path.join(PLUGIN, "AiUsageDisplaySettings.qml"), "utf8"));
    const settings = stripComments(fs.readFileSync(path.join(PLUGIN, "AiUsageSettings.qml"), "utf8"));
    const read = new Set(Array.from(display.matchAll(/root\.values\.([A-Za-z]+)/g), m => m[1]));
    assert.ok(read.size >= 5,
        `the reader extractor found ${read.size} value(s) — read that as the EXTRACTOR being ` +
        "broken, not the page being empty");

    const block = (text, label, re) => {
        const m = text.match(re);
        assert.ok(m, `${label} has no values object for this row to check`);
        return m[1];
    };
    const fromWidget = block(stripComments(source), "AiUsageWidget.qml",
        /displaySettings:\s*\(\{([\s\S]*?)\}\)/);
    const fromSettings = block(settings, "AiUsageSettings.qml", /values:\s*\(\{([\s\S]*?)\}\)/);
    for (const key of read) {
        // A key one surface omits is not an error the page can see: `values.x` is
        // simply undefined and the page silently falls back to its default, so the
        // same switch reads one way in the popout and another in the settings app.
        assert.ok(new RegExp("\\b" + key + ":").test(fromWidget),
            `the widget does not send ${key}, which the display page reads: the popout's copy of ` +
            "that control would show its default however the setting is actually stored");
        assert.ok(new RegExp("\\b" + key + ":").test(fromSettings),
            `the settings application does not send ${key}, which the display page reads`);
    }
    assert.ok(read.has("providerFilter") && read.has("barIconMode") && read.has("hideUnusedLanes"),
        "and the page is the one that reads them, so neither surface has a control the other lacks");
});

test("the display page offers the icon modes the catalog defines, and names none of them itself", () => {
    const display = stripComments(fs.readFileSync(path.join(PLUGIN, "AiUsageDisplaySettings.qml"), "utf8"));
    assert.ok(display.includes("keys: catalog.iconModes()"),
        "the modes come from the catalog, so a mode added there reaches both settings surfaces " +
        "without either one carrying a list of its own");
    assert.ok(!/"none"|"one"|"provider"/.test(display),
        "and the page never spells a mode out: the labels are positional against those keys, so " +
        "a mode added to the catalog shows up here rather than silently shifting the labels");
    assert.ok(display.includes('root.changed("barIconMode", key)'),
        "picking a mode writes the mode key, not a boolean the bar would have to guess at");
});

test("the display page's slot list orders through the catalog and writes one setting", () => {
    const display = stripComments(fs.readFileSync(path.join(PLUGIN, "AiUsageDisplaySettings.qml"), "utf8"));
    assert.ok(display.includes("model: catalog.filterOrder(root.providerFilter)"),
        "the rows are listed in the order the bar uses, so an arrow moves a row to where its " +
        "slot will actually be");
    for (const [call, why] of [
        ["catalog.toggleFilter(root.providerFilter, modelData)",
            "checking a provider goes through the shared rule, which is also what collapses a " +
            "full selection back to the value 'all' is stored as"],
        ["catalog.moveProvider(root.providerFilter, modelData, -1)", "and so does moving one up"],
        ["catalog.moveProvider(root.providerFilter, modelData, 1)", "and down"],
        ["canMoveUp: catalog.canMoveProvider(root.providerFilter, modelData, -1)",
            "an arrow that would do nothing says so before it is used"],
        ["canMoveDown: catalog.canMoveProvider(root.providerFilter, modelData, 1)", "at both ends"]
    ])
        assert.ok(display.includes(call), why);
    assert.ok(!/changed\("providerOrder"|changed\("barProviders"/.test(display),
        "selection and order are ONE stored list: a second one would let the bar and the popout " +
        "disagree about which providers exist");
});

test("the filter menu lists providers in the bar's order and can rearrange it", () => {
    const menu = stripComments(fs.readFileSync(path.join(PLUGIN, "AiUsageFilterMenu.qml"), "utf8"));
    assert.ok(menu.includes("root.host.filterOrder()"),
        "the popout's filter lists the same arrangement the display page does, or the two would " +
        "show one provider in two places");
    assert.ok(!/providerOrder\(\)/.test(menu),
        "and never the catalog's raw order, which would put the arrows beside the wrong rows");
    assert.ok(menu.includes("signal moveRequested(string provider, int delta)"),
        "the row asks its host to move a provider rather than writing the setting itself: the " +
        "menu has no save path and the popout and the settings app reach one differently");
    assert.ok(code.includes("onMoveRequested: (p, delta) => root.moveProvider(p, delta)"),
        "and the widget answers it through the same persisted setting");
});

test("a card asks for the lanes its own state should draw", () => {
    const card = stripComments(fs.readFileSync(path.join(PLUGIN, "AiUsageAccountCard.qml"), "utf8"));
    assert.ok(card.includes("metersFor(accountCard.account, accountCard.expanded)"),
        "an expanded card lists every limit and a compact one may drop the untouched ones, so " +
        "the card's own state has to reach the decision that filters them");
    assert.ok(!/hideUnusedLanes/.test(card),
        "but WHICH lanes to drop is not the card's to decide: it would then differ between the " +
        "popout's cards and any other surface that renders one");
    assert.ok(code.includes("fmt.shownMeters(fmt.metersFor(card), expanded, root.hideUnusedLanes)"),
        "the widget filters the shared list once, through the shared rule");
});

test("the plugin declares the same glyph the bar draws for the whole widget", () => {
    const manifest = JSON.parse(fs.readFileSync(path.join(PLUGIN, "plugin.json"), "utf8"));
    const logic = stripComments(fs.readFileSync(path.join(PLUGIN, "AiUsageLogic.qml"), "utf8"));
    const declared = logic.match(/function widgetIcon\(\)\s*\{\s*return "([a-z_]+)";/);
    assert.ok(declared, "the catalog names the widget's own glyph in one place");
    assert.equal(manifest.icon, declared[1],
        "the icon the bar draws in the single-icon mode is the icon the settings list and the " +
        "widget picker show for this plugin: two glyphs for one widget is two widgets to a user");
});

test("every provider mark fills its own box, so no provider's slot looks smaller than the rest", () => {
    // Vendor artwork arrives boxed to the vendor's own margins. Codex's mark sat in 65% of a
    // 24x24 box where Claude's filled 95% of a 248x248 one, so on a bar drawn at one icon size
    // it rendered two thirds the size of its neighbours and, being a thin-stroke glyph with a
    // third less ink, read as dimmer as well. The fix is the box, not a per-provider scale
    // factor: a number tuned to one drawing is wrong the moment the drawing is replaced.
    //
    // Extents come from the coordinate pairs in each path, so a curve is measured by its control
    // points and this reads slightly WIDE, never narrow. The threshold has room for that.
    const catalog = stripComments(fs.readFileSync(path.join(PLUGIN, "AiUsageLogic.qml"), "utf8"));
    const marks = Array.from(catalog.matchAll(/return "([a-z0-9-]+\.svg)";/g), m => m[1]);
    assert.ok(marks.length > 0,
        "the mark extractor found none — read that as the EXTRACTOR being broken, not the " +
        "catalog shipping no artwork");
    for (const mark of marks) {
        const svg = fs.readFileSync(path.join(PLUGIN, mark), "utf8");
        const box = svg.match(/viewBox="([-\d.\s]+)"/);
        assert.ok(box, `${mark} has no viewBox, so it has no defined size to be drawn at`);
        const [, , boxW, boxH] = box[1].trim().split(/\s+/).map(Number);
        const xs = [], ys = [];
        for (const d of svg.matchAll(/\sd="([^"]+)"/g)) {
            const n = (d[1].match(/-?\d*\.?\d+(?:e-?\d+)?/gi) || []).map(Number);
            for (let i = 0; i + 1 < n.length; i += 2) { xs.push(n[i]); ys.push(n[i + 1]); }
        }
        assert.ok(xs.length > 1, `${mark}: no path coordinates to measure`);
        const fill = Math.max((Math.max(...xs) - Math.min(...xs)) / boxW,
                              (Math.max(...ys) - Math.min(...ys)) / boxH);
        assert.ok(fill >= 0.85,
            `${mark} draws across only ${(fill * 100).toFixed(0)}% of its own box, so beside a ` +
            "mark that fills its own it renders visibly smaller and, spreading the same ink over " +
            "fewer pixels, dimmer. Tighten the viewBox to the artwork rather than scaling the " +
            "icon at one call site");
    }
});

test("the bar draws in the shell's own widget colours, not this plugin's idea of them", () => {
    for (const which of ["horizontalBarPill", "verticalBarPill"]) {
        const pill = blockFrom(indexOf(which + ":"), which);
        assert.ok(pill.includes("Theme.widgetIconColor"),
            `${which} takes the icon colour every other bar widget takes, or this widget's marks ` +
            "sit on the bar at a different brightness from its neighbours'");
        assert.ok(pill.includes("Theme.widgetTextColor"),
            `${which} takes the same token for a number carrying no severity colour`);
        // The two orientations were on different tokens, which is how the horizontal one came
        // to render dimmer than the vertical one for the same payload.
        assert.ok(!/Theme\.surfaceVariantText|Theme\.surfaceText/.test(pill),
            `${which} reaches past the widget tokens to a surface one: those do not follow the ` +
            "bar's own colour mode, and the two orientations then disagree about one payload");
    }
});

test("a mark is drawn at a Material glyph's optical size, and its fallback at the plain one", () => {
    const icon = stripComments(fs.readFileSync(path.join(PLUGIN, "AiUsageProviderIcon.qml"), "utf8"));
    // Filling the box is right for artwork and wrong for a bar: a Material Symbol reserves
    // roughly a quarter of the size it is asked for as padding, so a mark drawn at the same
    // number renders visibly larger than the glyph beside it. Measured on the bar, the marks
    // came out 26-28px tall against 22px for the Material glyphs before this ratio.
    assert.ok(/materialGlyphFill/.test(icon) && /markArtworkFill/.test(icon),
        "the adjustment is the ratio of two named fills, not a tuned constant: a bare 0.79 says " +
        "nothing about which of the two numbers behind it moved when the artwork is replaced");
    assert.ok(/markSize:.*root\.size \* \(materialGlyphFill \/ markArtworkFill\)/.test(icon),
        "and the size is derived from both of them");

    const at = icon.indexOf("VgsSVGIcon {");
    const fallbackAt = icon.indexOf("VgsIcon {");
    assert.ok(at !== -1 && fallbackAt > at, "the mark is drawn before its Material fallback");
    assert.ok(icon.slice(at, fallbackAt).includes("size: root.markSize"),
        "the shipped mark takes the adjusted size");
    assert.ok(icon.slice(fallbackAt).includes("size: root.size"),
        "and the Material fallback takes the plain one: it IS a Material glyph, so adjusting it " +
        "toward one would shrink it below every other glyph on the bar");
});

test("the gap above an account card sits outside the card's own rectangle", () => {
    const slot = blockFrom(lastIndexOf("Item {", indexOf("id: cardSlot")), "the account card's slot");
    const offset = slot.match(/y:\s*(\d+)/);
    const reserved = slot.match(/height:\s*card\.height \+ (\d+)/);
    assert.ok(offset && reserved, "the slot offsets the card and reserves room for that offset");
    assert.equal(offset[1], reserved[1],
        "the gap is entirely ABOVE the card: reserving more than the offset leaves the remainder " +
        "below it, which doubles the gap everywhere two cards meet");

    const card = stripComments(fs.readFileSync(path.join(PLUGIN, "AiUsageAccountCard.qml"), "utf8"));
    assert.ok(/height:\s*cardColumn\.implicitHeight/.test(card),
        "and the card's own height stays its content's. A card that padded itself would put the " +
        "gap inside the rectangle that IS its hover wash and its click target, so the row would " +
        "light up and respond 5px above where the card is drawn");
});

test("no control on the display page carries explanatory prose", () => {
    const display = stripComments(fs.readFileSync(path.join(PLUGIN, "AiUsageDisplaySettings.qml"), "utf8"));
    assert.ok(!/\bdescription:/.test(display),
        "a switch here is named by what it does, and a caption under it repeated its own label " +
        "back at the cost of doubling the page's height");
    assert.ok(!/\bcaption:/.test(display),
        "and a segmented choice is read from its segment labels, not from a line of prose that " +
        "follows the selection");
    // The switch rows are the ones that would regrow a description first, since VgsToggle takes
    // one; the choices have no such property left to set.
    const rows = (display.match(/VgsToggle \{/g) || []).length;
    assert.ok(rows >= 3, `the row extractor found ${rows} switch(es) — read that as the EXTRACTOR ` +
        "being broken, not the page being empty");
    assert.ok(code.includes('if (popout.onSettings)\n                    return "";'),
        "and the page's own header says nothing under its title either — but it still ANSWERS, " +
        "or the settings page falls through and wears the usage page's details line");
});
