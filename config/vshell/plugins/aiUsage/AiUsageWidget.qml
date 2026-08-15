import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    // --- Settings-backed config ---
    // Normalised, so a settings file carrying anything else degrades to the
    // default instead of leaving the widget inert: an unknown provider is
    // rejected as a launch tag, so every payload would be discarded and nothing
    // would ever relaunch, with no way back but editing settings by hand. It is
    // also what keeps the argv the helper receives a known provider.
    readonly property string provider: logic.normalizeProvider(pluginData.provider) || "claude"
    property int refreshSeconds: pluginData.refreshSeconds || 300
    // How the bar number is derived from the pool. "pool" = mean of each
    // account's tightest window, "best" = the account with the most headroom,
    // "worst" = the most exhausted account.
    property string headlineMode: pluginData.headlineMode || "pool"
    // Account ids the user has hidden. They stay out of the list AND out of the
    // headline, so the number never contradicts what is on screen.
    property var hiddenAccounts: pluginData.hiddenAccounts || []

    function isHidden(id) {
        return (root.hiddenAccounts || []).indexOf(id) !== -1;
    }
    function toggleHidden(id) {
        const cur = (root.hiddenAccounts || []).slice();
        const at = cur.indexOf(id);
        if (at === -1)
            cur.push(id);
        else
            cur.splice(at, 1);
        // Persist only. Assigning the property here would destroy its binding to
        // pluginData for this instance, and aiUsage is instantiated once per bar
        // — the other bar would keep following pluginDataChanged while this one
        // stopped, so one persisted setting would show two different states.
        if (root.pluginService)
            root.pluginService.savePluginData("aiUsage", "hiddenAccounts", cur);
    }
    function setHeadlineMode(m) {
        if (root.pluginService)
            root.pluginService.savePluginData("aiUsage", "headlineMode", m);
    }

    // Provider identity, headline arithmetic and pill composition. Extracted so
    // scripts/test-ai-usage-provider.js runs the shipped code; the wrappers
    // below just bind the widget's settings to it.
    AiUsageLogic {
        id: logic
    }

    // Meters, status classes and the date/money formatting the popout renders.
    AiUsageFormat {
        id: fmt
    }

    function shownAccounts(list) {
        return logic.shownIn(list, root.hiddenAccounts);
    }

    // --- Live state ---
    //
    // ONE accepted payload, for the provider that is selected. Everything the
    // popout renders is a binding off it, so a provider switch invalidates all
    // of it by clearing this single property — there is no hand-maintained
    // mirror to forget a field in, which is how the previous provider's numbers
    // used to survive a switch (VGS-118).
    property var current: null
    // The filing stamp of what `current` holds, so the promotion path can ask
    // the same newer-success question the failure paths ask.
    property int currentFiledAt: 0
    // Why the last fetch for the selected provider could not deliver a payload.
    // Non-empty means what `current` holds is no longer trustworthy.
    property string fetchError: ""
    property bool loading: true

    // Everything the popout shows about the payload, from one function that has
    // already taken the hidden accounts out. The payload's own top-level fields
    // describe the first LIVE account the backend found, hidden or not, so they
    // are only trustworthy for the older shape that reports no accounts at all.
    readonly property var view: logic.popoutView(root.current, root.hiddenAccounts, root.loading)

    readonly property bool ok: root.fetchError === "" && root.view.ok
    readonly property string errorText: root.fetchError !== "" ? root.fetchError : root.view.error
    readonly property string plan: root.view.plan
    // Still fetching, which the popout must not render as a failure.
    readonly property bool pending: root.fetchError === "" && root.view.pending

    // --- Multi-account state ---
    // People run several subscriptions side by side (one config dir per wrapper
    // script). One account keeps the single-account view; several render a card
    // each, carrying their own label, plan and error — which is why the card path
    // follows what the payload REPORTED, not what is left after hiding.
    readonly property var accounts: (root.current && root.current.accounts) || []
    readonly property bool multiAccount: root.view.cards
    // The payload reported accounts and the user is hiding all of them: nothing
    // failed, there is simply nothing to show.
    readonly property bool allHidden: root.view.allHidden
    property string expandedAccountId: ""
    readonly property int pillFontSize: Theme.barTextSize(
        root.barThickness, root.barConfig?.fontScale, root.barConfig?.maximizeWidgetText)

    // THE headline for what the popout is showing, from the same function the
    // pill slots use, so the bar, the vertical bar and the popout header cannot
    // disagree. Null when the payload yields no number — including the case where
    // the user has hidden every account it reported, where the old per-surface
    // arithmetic showed an error, 60% and "0 accounts · 60% used" at once.
    readonly property var currentHead: logic.headOf(root.current, root.headlineMode, root.hiddenAccounts)
    readonly property bool hasHeadline: root.currentHead !== null
    readonly property int headlinePct: root.currentHead ? root.currentHead.pct : 0

    // The SELECTED provider as one slot, the shape the horizontal pill renders,
    // so the vertical form cannot say something else about the same payload.
    readonly property var selectedSlot: logic.pillSlot(
        root.provider,
        root.provider === "codex" ? root.codexHead : root.claudeHead,
        root.providerData[root.provider],
        root.fetchingProviders,
        root.provider,
        root.hiddenAccounts)

    // The account on screen, or the payload's own lanes for the flat shape.
    readonly property var primaryMeters: {
        if (root.view.flat)
            return fmt.flatMeters(root.current);
        return root.view.account ? fmt.metersFor(root.view.account) : [];
    }

    function formatResetAt(epoch) {
        return fmt.formatResetAt(epoch);
    }
    function formatSpend(meter) {
        return fmt.formatSpend(meter);
    }
    function formatSpendExact(meter) {
        return fmt.formatSpendExact(meter);
    }
    function resetLabel(meter) {
        return fmt.resetLabel(meter);
    }

    function providerName() {
        return logic.providerName(root.provider);
    }
    function classColor(c) {
        switch (c) {
        case "critical":
            return Theme.error;
        case "high":
            return Theme.tempWarning;
        case "mid":
            return Theme.warning;
        default:
            return Theme.success;
        }
    }

    function percentageColor(pct) {
        return classColor(fmt.percentageClass(pct));
    }

    // The last payload PER PROVIDER, keyed by provider name so the pill can show
    // both without the popout having to be on that tab. Kept raw rather than
    // reduced to a number, because the headline mode and the hidden-account list
    // can change between polls and the pill has to follow them without waiting
    // for a refetch.
    //
    // A map rather than two properties, so filing is a keyed write and there is
    // no branch that could file an unidentifiable payload under a guess — the
    // guessing is what mixed the two providers up (VGS-118).
    property var providerData: ({})

    readonly property var claudeHead: logic.headOf(root.providerData.claude, root.headlineMode, root.hiddenAccounts)
    readonly property var codexHead: logic.headOf(root.providerData.codex, root.headlineMode, root.hiddenAccounts)

    // File a payload under the provider IT names, never under the provider the
    // fetch was launched for or the one currently selected.
    // A monotonic stamp per filing, and the stamp each provider's entry carries.
    // That is the only ordering evidence the failure path needs: whether the
    // payload now filed for a provider arrived after the failing fetch launched.
    property int fileSeq: 0
    property var providerFiledAt: ({})

    function storeHeadline(provider, data) {
        const which = logic.normalizeProvider(provider);
        if (which === "")
            return;
        // New objects, because a var property only notifies on assignment.
        const next = { claude: root.providerData.claude, codex: root.providerData.codex };
        const nextAt = { claude: root.providerFiledAt.claude, codex: root.providerFiledAt.codex };
        root.fileSeq += 1;
        next[which] = data;
        nextAt[which] = root.fileSeq;
        root.providerData = next;
        root.providerFiledAt = nextAt;
    }
    function noteHeadline(data) {
        root.storeHeadline(logic.payloadProvider(data), data);
    }

    // The providers with a fetch actually running, so a slot with no number yet
    // can say "waiting" rather than "nothing".
    readonly property var fetchingProviders: {
        const out = [];
        if (usageFetch.inFlight !== "")
            out.push(usageFetch.inFlight);
        if (otherFetch.inFlight !== "")
            out.push(otherFetch.inFlight);
        return out;
    }

    function pillHeads() {
        return logic.pillSlots({
            selected: root.provider,
            claudeHead: root.claudeHead,
            claudeData: root.providerData.claude,
            codexHead: root.codexHead,
            codexData: root.providerData.codex,
            fetching: root.fetchingProviders,
            hidden: root.hiddenAccounts
        });
    }

    readonly property string aiUsageCommand: Paths.vshellCli
    // The provider the popout is NOT showing. Only its headline is kept, so the
    // pill can show both without doubling the popout's state.
    readonly property string otherProvider: root.provider === "codex" ? "claude" : "codex"
    // Base spacing between retries, multiplied by the attempt number. One second
    // is long enough to be a pause rather than a burst and short enough that a
    // blip still resolves well inside a poll interval.
    readonly property int retryDelayMs: 1000
    // Cap on a failure reason before it reaches the popout and the shell log:
    // the text comes from whichever backend is installed, and a log people paste
    // into bug reports should not accumulate arbitrary backend output.
    readonly property int maxIssueChars: 200

    // One record per fetch channel — and the channel OWNS its process, its
    // collectors and the provider it wants. Threading that tuple by hand through
    // every call site is how a cross-channel mix-up gets written by accident:
    // one handler reaching for the other channel's stderr or process is a typo,
    // not a design error, and nothing structural would have caught it. Here the
    // pairing cannot be crossed, and every handler is written once.
    component FetchChannel: QtObject {
        id: chan

        // The provider this channel fetches. A binding at the instantiation
        // site, so the command follows the selection.
        property string want: ""
        // The channel whose payload the popout shows. The other one keeps only
        // its provider's headline.
        property bool primary: false

        // The provider this channel's process was LAUNCHED for, empty when
        // nothing is running. A running process keeps the argument it started
        // with, so the tag says what it actually got — while the payload's own
        // `provider` field is what decides where its data may be filed, because
        // a tag can be reassigned while the process holding it is still running.
        property string inFlight: ""
        // The provider whose payload this channel last filed. The relaunch
        // decision is "is this what is selected now?", never "did the selection
        // move?".
        property string loaded: ""
        property int retries: 0
        // Whether the launch now finishing produced a payload this channel could
        // use, and why it did not. Per channel, so one channel's failure can
        // never be shown as the other's cause.
        property bool accepted: false
        property string issue: ""
        // Captured when the stream ends rather than read at exit time, which is
        // the repo idiom (Common/settings/Processes.qml): StdioCollector only
        // fills `text` once the stream has closed, and hanging the cause off an
        // ordering assumption loses it silently when the assumption slips.
        property string errorOut: ""
        // A launch asked for while the previous process was still stopping, to
        // be applied when it actually stops.
        property bool pending: false
        // Whether THIS launch produced a process — `started` is the signal for
        // "exec succeeded", and a launch that never gets there is the only thing
        // the watchdog is for. See AiUsageLogic.watchdogArms.
        property bool sawProcess: false
        // The filing stamp this launch started at, so its failure can tell a
        // payload that predates it from one filed while it was running.
        property int launchSeq: 0
        // The two halves of a finished fetch. Nothing orders stdout closing
        // against the exit, so a fetch settles only once BOTH have landed:
        // settling on the exit alone cleared the tag acceptPayload decodes
        // against, and a VALID payload arriving second was then discarded as a
        // provider mismatch and refetched — the inverse of the rule this issue
        // exists to enforce, and a retry spent on a fetch that succeeded.
        property bool outDone: false
        property bool exitDone: false

        property Process proc: Process {
            command: [root.aiUsageCommand, "ai-usage", chan.want]
            running: false
            stdout: StdioCollector {
                id: outCollector
                onStreamFinished: {
                    chan.outDone = true;
                    root.acceptPayload(chan, outCollector.text);
                    root.completeFetch(chan);
                }
            }
            stderr: StdioCollector {
                id: errCollector
                onStreamFinished: chan.errorOut = errCollector.text
            }
            onStarted: chan.sawProcess = true
            onExited: (exitCode, exitStatus) => root.finishFetch(chan, exitCode, exitStatus)
            onRunningChanged: {
                if (running)
                    return;
                // THE INVARIANT, and why it is asked first: a stop with a tag
                // still set must leave something that will settle this channel —
                // an armed watchdog here, or the exit still coming for a process
                // that did run. Draining `pending` ahead of it could swallow the
                // arming, because launch() re-parks a request while the tag is
                // owned: nothing started, nothing armed, and this handler never
                // runs again once the process has stopped — so the channel would
                // hold its tag with no settle path at all, the pill on the
                // in-flight ellipsis and no fetch for it until a provider switch.
                //
                // Arming means the start itself failed: Qt starts a process
                // asynchronously and reports nothing when the executable cannot be
                // run. A launch that DID produce a process is not this timer's
                // business, whichever of `exited` and `runningChanged` lands
                // first. Deferred all the same, and failLaunch re-checks, because
                // `started` is not ordered against this signal either.
                if (logic.watchdogArms(chan.inFlight, chan.sawProcess)) {
                    stallTimer.restart();
                    return;
                }
                // A parked request runs only once the channel can actually take
                // it. A tag that is still set is owned until the settle path
                // clears it, and settleFetch drains `pending` when it does.
                if (chan.inFlight === "" && chan.pending)
                    root.launch(chan);
            }
        }

        // Long enough that a `started` arriving after the stop still wins, short
        // enough that a broken command is reported rather than waited out. It is
        // NOT sized against the exit: a launch that produced a process never arms
        // it, so a slow helper cannot be reported as one that never ran.
        property Timer stallTimer: Timer {
            id: stallTimer
            interval: 1000
            onTriggered: root.failLaunch(chan)
        }

        // The grace an exit gives stdout to close, and the only reason waiting for
        // both halves cannot hang: a helper can leave its stdout open in a child
        // it spawned, so the payload half may never arrive at all. Long enough
        // that an ordinary close always wins it, short enough that a fetch is not
        // left sitting on one that never comes.
        property Timer flushTimer: Timer {
            id: flushTimer
            interval: 1000
            onTriggered: root.settleFetch(chan)
        }

        // A retry waits. Deferring it to the next event-loop turn spent the whole
        // budget in consecutive turns — four calls to a provider usage API as
        // fast as the loop turns, once per configured bar — which gives a
        // transient failure no time to pass. settleFetch sets the interval from
        // the retry count, so the attempts are spaced 1s, 2s, 3s.
        property Timer retryTimer: Timer {
            id: retryTimer
            interval: root.retryDelayMs
            onTriggered: root.launch(chan)
        }

        // What a provider switch invalidates. The switch is this branch's
        // generation boundary, so nothing armed before it may act after it: both
        // timers stop here, and a request parked for the previous selection goes
        // with them, since clearProviderState refreshes anyway.
        //
        // The TAG is the deliberate part, and the question is about the LAUNCH,
        // not about the process object. A launch that produced a process has an
        // exit coming, and that exit must settle its own fetch — its payload is
        // attributed by the payload's own provider rather than by this channel's
        // rebound `want`, so nothing it does can be read as the new provider's.
        // A launch that produced none has no exit coming and its watchdog has
        // just been stopped, so leaving the tag would own the channel with
        // nothing to settle it, and every later refresh would answer "skip"
        // forever. Asking `proc.running` here instead was a bug of exactly the
        // shape this issue is about: it reads back TRUE for a start that failed
        // (measured on Quickshell 0.3.0 — a nonexistent binary reports the
        // failure only later, as runningChanged), which is the one case the
        // clear exists for. So the switch settles exactly the launches the
        // watchdog would have — one rule, asked here as its third consumer.
        //
        // Clearing it while a process is still starting is safe: launch() parks
        // a request whenever `running` is true, so no new tag can be taken while
        // that process could still deliver an exit.
        function reset() {
            loaded = "";
            retries = 0;
            accepted = false;
            issue = "";
            stallTimer.stop();
            retryTimer.stop();
            flushTimer.stop();
            pending = false;
            if (logic.watchdogArms(inFlight, sawProcess))
                inFlight = "";
        }
    }

    FetchChannel {
        id: usageFetch
        want: root.provider
        primary: true
    }
    FetchChannel {
        id: otherFetch
        want: root.otherProvider
    }

    // Immediate relaunches allowed before a channel gives up and waits for the
    // poll timer. Spent per channel; restored only by a payload that SATISFIES
    // that channel and by a provider switch. When it is spent is
    // AiUsageLogic.shouldRelaunch's to say, and only its comment says it — two
    // copies of that rule is how this one drifted.
    readonly property int maxFetchRetries: 3

    // A provider switch makes every provider-scoped answer wrong at once: the
    // payload, the failure text, and both channels' "what do we hold" state. One
    // path clears all of it, so the popout shows a loading state rather than the
    // previous provider's accounts, plan and errors. `providerData` is kept: it
    // is keyed BY provider, so neither entry can be read as the other's.
    function clearProviderState() {
        root.current = null;
        // The BARRIER, not zero: providerData survives a switch on purpose (the
        // pill keeps both slots), so comparing against 0 promoted the previous
        // session's payload for the newly selected provider — stale data on a
        // switch, which is the symptom this issue exists to fix. Holding the
        // stamp the switch happened at says "only what is filed from here on",
        // and needs no second counter: the switch IS the generation boundary.
        root.currentFiledAt = root.fileSeq;
        root.fetchError = "";
        root.loading = true;
        root.expandedAccountId = "";
        usageFetch.reset();
        otherFetch.reset();
    }

    function setProvider(p) {
        if (root.provider === p)
            return;
        // Persist only. The refresh is driven by onProviderChanged below, which
        // runs in EVERY live instance rather than only in the one whose setter
        // was clicked — and which is also correct on desktop widgets, where the
        // instance-scoped pluginService emits pluginDataChanged via
        // Qt.callLater, so root.provider has NOT moved yet when this returns.
        if (root.pluginService)
            root.pluginService.savePluginData("aiUsage", "provider", p);
    }

    // aiUsage is instantiated once per configured bar and the provider is one
    // shared setting, so the change — not the click — is what has to drive the
    // refetch. Refreshing inside setProvider left every other bar showing the
    // PREVIOUS provider's accounts and plan under the new provider's label
    // until its own poll timer fired, up to refreshSeconds later.
    onProviderChanged: {
        root.clearProviderState();
        root.refresh();
    }

    // Both channels, for the poll and for a provider switch. A retry relaunches
    // its own channel directly — restarting both would spend one channel's
    // budget on the other's process, and every launch shells out to a provider
    // usage API once per configured bar.
    function refresh() {
        root.launch(otherFetch);
        root.launch(usageFetch);
    }

    // A tag is only set when a process actually starts. `running = true` on a
    // Process that has not finished stopping is a no-op, so that case parks the
    // request on the channel and onRunningChanged applies it — a tag set for a
    // launch that never happened would show a fetch that does not exist and
    // block every later refresh until the poll timer.
    function launch(ch) {
        const decision = logic.launchDecision(ch.inFlight, ch.proc.running);
        if (decision === "skip")
            return;
        if (decision === "pend") {
            ch.pending = true;
            return;
        }
        ch.pending = false;
        ch.inFlight = ch.want;
        // Per-fetch, like the tag: the previous launch's process says nothing
        // about whether this one gets off the ground.
        ch.sawProcess = false;
        // Everything filed after this point is newer than this fetch.
        ch.launchSeq = root.fileSeq;
        ch.accepted = false;
        ch.issue = "";
        ch.errorOut = "";
        ch.outDone = false;
        ch.exitDone = false;
        ch.flushTimer.stop();
        // The previous launch's watchdog is armed in exactly the state this one
        // starts from — tag set, process not running — so leaving it running let
        // it fire against THIS fetch: "could not run" for a healthy process,
        // whose payload was then discarded as a mismatch and whose retry was
        // spent. It is per-fetch state like everything above it.
        ch.stallTimer.stop();
        // This launch supersedes any retry that was still waiting to fire.
        ch.retryTimer.stop();
        ch.proc.running = true;
    }

    // The process stopped. `exitStatus` is Qt's: non-zero means the helper did
    // not exit on its own terms (a signal, an OOM kill), which has to name
    // itself — otherwise the reason left standing is the "parse error" recorded
    // for the empty output it never wrote.
    function finishFetch(ch, exitCode, exitStatus) {
        // Symmetric with failLaunch: whichever path settles the fetch first owns
        // it. Without this an exit arriving after the watchdog already settled
        // reported a second time, and could overwrite the reason of — and settle
        // — a relaunch that was by then running.
        if (ch.inFlight === "")
            return;
        ch.exitDone = true;
        if (!ch.accepted && (exitCode !== 0 || exitStatus !== 0)) {
            const reason = logic.stderrReason(ch.errorOut, root.maxIssueChars);
            ch.issue = (exitStatus !== 0 ? "helper killed" : "helper exited " + exitCode)
                + (reason !== "" ? ": " + reason : "");
            console.warn("aiUsage: " + ch.inFlight + " fetch " + ch.issue);
        }
        root.completeFetch(ch);
    }

    // Both halves of a finished fetch, in whichever order they land. The tag has
    // to outlive the payload path, because that is what the payload is decoded
    // against; settling on the exit alone made a valid payload look like another
    // provider's. Whichever half lands last settles, and an exit that lands first
    // gives stdout a bounded grace rather than an open-ended wait.
    function completeFetch(ch) {
        if (ch.inFlight === "")
            return;
        if (!ch.outDone || !ch.exitDone) {
            if (ch.exitDone)
                ch.flushTimer.restart();
            return;
        }
        root.settleFetch(ch);
    }

    // A start that never produced a running process. Same failure path as an
    // exit, so a missing or unrunnable CLI is reported and retried exactly like
    // a helper that ran and failed, instead of leaving the widget waiting.
    function failLaunch(ch) {
        // The arming rule, asked again at the moment it would report: the fetch
        // may have settled while the timer waited, or the process may have
        // started after the stop. One function, two consumers — a second copy of
        // the condition here is how it would drift.
        if (!logic.watchdogArms(ch.inFlight, ch.sawProcess))
            return;
        ch.issue = "could not run " + root.aiUsageCommand;
        console.warn("aiUsage: " + ch.inFlight + " fetch " + ch.issue);
        root.settleFetch(ch);
    }

    // What a finished fetch means, however it finished.
    function settleFetch(ch) {
        if (ch.inFlight === "")
            return;
        ch.stallTimer.stop();
        ch.flushTimer.stop();

        // Relaunch whenever this channel is not holding the provider it should
        // be, or this fetch delivered nothing — misattributed, arrived after the
        // user switched away, never parsed, or the helper never ran. Comparing
        // the launch tag to the selection instead dropped the replacement fetch
        // on a claude -> codex -> claude toggle (VGS-118). Decided BEFORE the tag
        // is cleared, since the tag is one of the fields the decision reads. The
        // retry then WAITS: a `running = true` assigned while the process is
        // still stopping is a no-op, and beyond that a transient failure needs
        // time to pass rather than the next event-loop turn. launch() parks the
        // attempt if the process is still stopping and onRunningChanged applies
        // it then.
        const relaunch = logic.shouldRelaunch(ch, root.maxFetchRetries);
        ch.inFlight = "";
        if (relaunch) {
            ch.retries += 1;
            ch.retryTimer.interval = root.retryDelayMs * ch.retries;
            ch.retryTimer.restart();
            return;
        }
        // A request parked while this launch was unsettled runs now that the tag
        // is clear. Deferred: the process may still be stopping, in which case
        // launch() parks it again and onRunningChanged applies it.
        if (ch.pending)
            Qt.callLater(() => root.launch(ch));

        // Either there is still nothing for what this channel wants, or this
        // fetch produced no payload and what is held is now stale — the same
        // kind of failure: say so rather than sitting on "loading" or on numbers
        // no fetch stands behind.
        if (ch.loaded !== ch.want || !ch.accepted) {
            const why = ch.issue !== "" ? ch.issue : "usage unavailable";
            // ONE decision, consulted by every write below: a newer successful
            // result for a provider always wins over an older failure. The other
            // channel files by payload identity, so mid-switch it can land a good
            // payload for the provider this one is failing at. Guarding only the
            // headline write left the popout claiming an error over those
            // numbers — two guard sites is what let that drift, so there is one.
            const authoritative = logic.failureWins(
                root.providerData[ch.want], root.providerFiledAt[ch.want], ch.launchSeq);
            if (authoritative)
                root.storeHeadline(ch.want, { ok: false, provider: ch.want, error: why });
            if (ch.primary) {
                // Loading ends either way: this fetch settled and none is coming
                // before the poll, so leaving it set would keep the popout saying
                // it is checking when nothing is. Only the failure TEXT is
                // conditional — an unauthoritative failure reports nothing rather
                // than contradicting the payload that beat it.
                root.loading = false;
                if (authoritative)
                    root.fetchError = why;
            }
        }
    }

    // Both channels accept through one path: decode, record the reason on THIS
    // channel, then apply the outcome AiUsageLogic decided. Filing a payload and
    // satisfying a channel are separate answers — a result that lands after the
    // user switched still updates its own provider's pill slot, but leaves the
    // channel owing a fetch for what is selected now.
    function acceptPayload(ch, txt) {
        const got = logic.decodePayload(ch.inFlight, txt);
        ch.issue = got.issue;
        if (!got.data)
            return;
        ch.accepted = true;
        const outcome = logic.acceptOutcome(logic.payloadProvider(got.data), ch.want);
        if (outcome.file)
            root.noteHeadline(got.data);
        // The promotion path, third consumer of the newer-success rule: a good
        // payload for the SELECTED provider belongs in the popout whichever
        // channel fetched it. Gating on ch.primary left the popout empty after a
        // switch, when the other channel files for what is now selected.
        root.promoteSelected();
        if (!outcome.satisfies)
            return;
        ch.loaded = ch.want;
        ch.retries = 0;
    }

    // The popout shows whatever is filed for the selected provider, promoted here
    // rather than written by whichever channel happened to fetch it. Adding a
    // lane later means adding it to the payload and to AiUsageFormat.flatMeters —
    // never to a mirror here that a switch has to remember to clear.
    function promoteSelected() {
        const filed = root.providerData[root.provider];
        const filedAt = root.providerFiledAt[root.provider];
        // Any ACCEPTED payload, not only a successful one: an ok:false payload is
        // the provider answering — signed out, backend missing — and the popout
        // has an error path for it. Storing is an ordering question; `ok` only
        // decides what is rendered. Success-only left a signed-out provider
        // showing nothing at all, because settleFetch skips its failure branch
        // for a channel that IS accepted and loaded.
        if (!logic.newerAccepted(filed, filedAt, root.currentFiledAt))
            return;
        root.current = filed;
        root.currentFiledAt = filedAt;
        root.fetchError = "";
        root.loading = false;
    }

    Timer {
        id: pollTimer
        // Each refresh walks every account in turn, so the floor scales with how
        // many there are: one account may poll every 60s, five no faster than
        // every 300s. The configured interval still wins when it is longer.
        interval: Math.max(60 * Math.max(1, (root.accounts || []).length), root.refreshSeconds) * 1000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    // One slot per provider, each carrying its own icon. The icon is what makes
    // a slot readable on its own: with a single leading icon and a bare "x / y",
    // a provider with no number dropped its slot entirely and the other value
    // slid left, changing meaning with nothing on screen to say so.
    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            Repeater {
                model: root.pillHeads()

                Row {
                    required property var modelData
                    spacing: 2
                    anchors.verticalCenter: parent.verticalCenter

                    VgsIcon {
                        name: modelData.icon
                        size: root.iconSize
                        // The selected provider — the one the popout and the
                        // click target belong to — reads at full strength.
                        color: modelData.selected ? Theme.surfaceText : Theme.surfaceVariantText
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    StyledText {
                        text: modelData.text
                        font.pixelSize: root.pillFontSize
                        font.weight: Font.Medium
                        color: modelData.error ? Theme.error
                            : (modelData.pct === null ? Theme.surfaceVariantText
                                                    : root.percentageColor(modelData.pct))
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: 2

            VgsIcon {
                name: root.selectedSlot.icon
                size: root.iconSize
                color: Theme.surfaceText
                anchors.horizontalCenter: parent.horizontalCenter
            }

            // The same slot the horizontal pill renders for this provider, so
            // the two bar forms cannot say different things about one payload.
            StyledText {
                text: root.selectedSlot.text
                font.pixelSize: root.pillFontSize
                color: root.selectedSlot.error ? Theme.error
                    : (root.selectedSlot.pct === null ? Theme.surfaceVariantText
                                                      : root.percentageColor(root.selectedSlot.pct))
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    popoutWidth: 360
    popoutContent: Component {
        PopoutComponent {
            id: popout

            // Which page of the pager is showing: 0 usage, 1 display settings.
            // Transient view state, deliberately not persisted — reopening a
            // popout on a settings page you left open days ago is disorienting.
            property int page: 0
            readonly property bool onSettings: popout.page === 1

            // The pushed-page contract PluginPopout looks for: it owns keyboard
            // focus, so Escape can only reach a pushed page through this, and it
            // is also what resets the pager when the popout is dismissed. Two
            // members, no key handler. (VGS-88)
            readonly property bool canPopBack: popout.page > 0
            function popBack() {
                popout.page = Math.max(0, popout.page - 1);
            }

            headerText: popout.onSettings ? "Display settings" : (root.providerName() + " Usage")
            detailsText: {
                if (popout.onSettings)
                    return "How the bar number is chosen, and which accounts count.";
                if (!root.ok)
                    return root.pending ? "Checking usage…" : (root.errorText || "Unavailable");
                // Every account hidden: a number over them is the leak this closes.
                if (root.allHidden)
                    return logic.accountCount(root.view.totalCount) + " hidden";
                if (!root.multiAccount)
                    return root.plan || "";
                // Counted over what is actually on screen — saying "5 accounts"
                // beside a number derived from four of them is just wrong.
                const unavailable = root.view.shownCount - root.view.liveCount;
                let suffix = unavailable > 0 ? (" · " + unavailable + " unavailable") : "";
                if (root.view.hiddenCount > 0)
                    suffix += " · " + root.view.hiddenCount + " hidden";
                // No headline means no number: several accounts on screen and not
                // one of them ok. The pill already renders its placeholder there.
                const used = root.hasHeadline ? (" · " + root.headlinePct + "% used") : "";
                return logic.accountCount(root.view.liveCount) + used + suffix;
            }
            showCloseButton: true

            // Sits left of the close button; same 32x32 hit target so the two
            // read as a pair. It is the disclosure control and the back control
            // both — the header has no left-hand slot to put a back chevron in,
            // and adding one would mean changing PopoutComponent for every
            // plugin that uses it. Swapping the icon in place keeps the
            // affordance where the user's pointer already is.
            headerActions: Component {
                Rectangle {
                    width: 32
                    height: 32
                    radius: Theme.controlRadius
                    color: gearArea.containsMouse ? Theme.surfaceContainerHighest
                                                  : Theme.withAlpha(Theme.surfaceContainerHighest, 0)

                    VgsIcon {
                        anchors.centerIn: parent
                        name: popout.onSettings ? "arrow_back" : "tune"
                        size: Theme.iconSize - 4
                        color: popout.onSettings ? Theme.primary : Theme.surfaceText
                    }

                    MouseArea {
                        id: gearArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: popout.page = popout.onSettings ? 0 : 1
                    }
                }
            }

            // --- pager -------------------------------------------------------
            // The settings used to expand inline, pushing the account cards
            // down inside a popout that is already dense. They are a page now:
            // the two sit side by side in a clipped viewport that slides, and
            // the viewport takes the height of whichever page is showing, so
            // the popout grows TO the settings page rather than growing BY it.
            // (VGS-73)
            Item {
                id: pager

                width: parent.width
                clip: true
                height: popout.onSettings ? settingsPage.implicitHeight : usagePage.implicitHeight

                Behavior on height {
                    NumberAnimation {
                        duration: Theme.shortDuration
                        easing.type: Easing.OutCubic
                    }
                }

                Row {
                    id: pages
                    spacing: 0
                    // One viewport width per page; page 0 is the resting state.
                    x: -popout.page * pager.width

                    Behavior on x {
                        NumberAnimation {
                            duration: Theme.mediumDuration
                            easing.type: Easing.OutCubic
                        }
                    }

                    Column {
                        id: usagePage
                        width: pager.width
                        spacing: Theme.spacingM

                        // The tabs sat flush against the header and the first card.
                        // Wrapping rather than adding Column spacers keeps the gap to
                        // the neighbouring cards unchanged.
                        Item {
                            width: parent.width
                            height: providerRow.implicitHeight + 10

                            Row {
                                id: providerRow
                                width: parent.width
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Theme.spacingS

                            // Driven from the same identity source as the pill
                            // slots, so a tab's label and icon cannot disagree
                            // with the number the bar shows for that provider.
                            Repeater {
                                model: logic.providerOrder()

                                VgsButton {
                                    required property string modelData

                                    readonly property bool current: root.provider === modelData
                                    text: logic.providerName(modelData)
                                    iconName: logic.providerIcon(modelData)
                                    width: (providerRow.width - Theme.spacingS) / 2
                                    backgroundColor: current ? Theme.primary : Theme.surfaceContainerHigh
                                    textColor: current ? Theme.primaryText : Theme.surfaceText
                                    onClicked: root.setProvider(modelData)
                                }
                            }
                            }
                        }

                        // Single account: unchanged full-detail cards.
                        Repeater {
                            model: (root.ok && !root.multiAccount) ? root.primaryMeters : []

                            StyledRect {
                                width: parent.width
                                height: rowCol.implicitHeight + Theme.spacingM * 2
                                radius: Theme.cornerRadius
                                color: Theme.surfaceContainerHigh

                                MeterCard {
                                    id: rowCol
                                    anchors.fill: parent
                                    anchors.margins: Theme.spacingM
                                    spacing: Theme.spacingXS

                                    host: root
                                    meter: modelData
                                    labelWeight: Font.Medium
                                    // A credit pool reports an amount, not a countdown.
                                    detailText: root.formatSpendExact(modelData) || root.resetLabel(modelData)
                                }
                            }
                        }

                        // Several accounts: one compact row each, expanding in place to
                        // the same full-detail cards a single account gets.
                        Repeater {
                            model: root.multiAccount ? root.shownAccounts(root.accounts) : []

                            StyledRect {
                                id: accountCard

                                required property var modelData

                                readonly property bool expanded: root.expandedAccountId === modelData.id
                                readonly property var meters: fmt.metersFor(modelData)
                                width: parent.width
                                height: accountCol.implicitHeight + Theme.spacingM * 2
                                radius: Theme.cornerRadius
                                color: Theme.surfaceContainerHigh

                                Behavior on height {
                                    NumberAnimation {
                                        duration: Theme.shortDuration
                                        easing.type: Easing.OutCubic
                                    }
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.expandedAccountId = accountCard.expanded ? "" : accountCard.modelData.id
                                }

                                Column {
                                    id: accountCol
                                    anchors.fill: parent
                                    anchors.margins: Theme.spacingM
                                    spacing: Theme.spacingXS

                                    Item {
                                        width: parent.width
                                        // +5 with the text pinned to the top, so the extra
                                        // height reads as space under the account line
                                        // rather than padding on both sides of it.
                                        height: Math.max(emailText.implicitHeight, planText.implicitHeight) + 5

                                        StyledText {
                                            id: emailText
                                            anchors.left: parent.left
                                            anchors.right: planText.left
                                            anchors.rightMargin: Theme.spacingS
                                            anchors.top: parent.top
                                            text: accountCard.modelData.label || accountCard.modelData.id
                                            elide: Text.ElideMiddle
                                            font.pixelSize: Theme.fontSizeMedium
                                            font.weight: Font.Medium
                                            color: Theme.surfaceText
                                        }

                                        StyledText {
                                            id: planText
                                            anchors.right: parent.right
                                            anchors.verticalCenter: emailText.verticalCenter
                                            text: accountCard.modelData.ok ? (accountCard.modelData.plan || "") : "unavailable"
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceVariantText
                                        }
                                    }

                                    // Collapsed: slim one-line-per-window summary.
                                    Repeater {
                                        model: accountCard.expanded ? [] : accountCard.meters

                                        MeterRow {
                                            required property var modelData

                                            width: accountCol.width
                                            host: root
                                            meter: modelData
                                            ok: accountCard.modelData.ok
                                        }
                                    }

                                    // Expanded: the full card treatment, one per window.
                                    Repeater {
                                        model: accountCard.expanded ? accountCard.meters : []

                                        MeterCard {
                                            required property var modelData

                                            width: accountCol.width
                                            spacing: 2
                                            topPadding: Theme.spacingXS

                                            host: root
                                            meter: modelData
                                            ok: accountCard.modelData.ok
                                            detailText: modelData.detail ? modelData.detail : root.resetLabel(modelData)
                                        }
                                    }

                                    StyledText {
                                        visible: !accountCard.modelData.ok
                                        width: parent.width
                                        text: accountCard.modelData.error || "Usage unavailable"
                                        wrapMode: Text.WordWrap
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                    }
                                }
                            }
                        }

                        StyledText {
                            visible: !root.ok
                            width: parent.width
                            text: root.errorText || (root.pending ? "Checking usage…" : "No data")
                            wrapMode: Text.WordWrap
                            font.pixelSize: Theme.fontSizeMedium
                            color: Theme.surfaceVariantText
                        }
                    }

                    Column {
                        id: settingsPage
                        width: pager.width
                        spacing: Theme.spacingM

                        StyledRect {
                            width: parent.width
                            height: settingsCol.implicitHeight + Theme.spacingM * 2
                            radius: Theme.cornerRadius
                            color: Theme.surfaceContainerHigh

                            Column {
                                id: settingsCol
                                anchors.fill: parent
                                anchors.margins: Theme.spacingM
                                spacing: Theme.spacingS

                                StyledText {
                                    text: "Bar number"
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.Medium
                                    color: Theme.surfaceText
                                }

                                StyledText {
                                    width: parent.width
                                    text: root.headlineMode === "best"
                                        ? "The account with the most headroom left."
                                        : (root.headlineMode === "worst"
                                           ? "The most exhausted account."
                                           : "Average across accounts, each counted at its tightest limit.")
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    wrapMode: Text.WordWrap
                                }

                                Row {
                                    id: modeRow
                                    width: parent.width
                                    spacing: Theme.spacingXS

                                    Repeater {
                                        model: [
                                            { key: "pool", label: "Average" },
                                            { key: "best", label: "Most left" },
                                            { key: "worst", label: "Most used" }
                                        ]

                                        VgsButton {
                                            required property var modelData
                                            text: modelData.label
                                            width: (modeRow.width - Theme.spacingXS * 2) / 3
                                            backgroundColor: root.headlineMode === modelData.key
                                                ? Theme.primary : Theme.surfaceContainerHighest
                                            textColor: root.headlineMode === modelData.key
                                                ? Theme.primaryText : Theme.surfaceText
                                            onClicked: root.setHeadlineMode(modelData.key)
                                        }
                                    }
                                }

                                StyledText {
                                    text: "Accounts"
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.Medium
                                    color: Theme.surfaceText
                                    visible: (root.accounts || []).length > 1
                                    topPadding: Theme.spacingXS
                                }

                                Repeater {
                                    model: (root.accounts || []).length > 1
                                        ? logic.orderedAccounts(root.accounts) : []

                                    Item {
                                        required property var modelData
                                        width: settingsCol.width
                                        height: 26

                                        StyledText {
                                            anchors.left: parent.left
                                            anchors.right: eyeIcon.left
                                            anchors.rightMargin: Theme.spacingS
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: modelData.label || modelData.id
                                            elide: Text.ElideMiddle
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: root.isHidden(modelData.id) ? Theme.surfaceVariantText
                                                                               : Theme.surfaceText
                                        }

                                        VgsIcon {
                                            id: eyeIcon
                                            anchors.right: parent.right
                                            anchors.verticalCenter: parent.verticalCenter
                                            name: root.isHidden(modelData.id) ? "visibility_off" : "visibility"
                                            size: Theme.iconSizeSmall
                                            color: root.isHidden(modelData.id) ? Theme.surfaceVariantText
                                                                               : Theme.primary
                                        }

                                        MouseArea {
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.toggleHidden(modelData.id)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
