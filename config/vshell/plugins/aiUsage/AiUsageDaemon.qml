import QtQuick
import Quickshell.Io
import qs.Common
import qs.Modules.Plugins

// The one aiUsage fetcher in the shell. Each bar's AiUsageWidget is a view of
// this instance, so a poll asks each provider once however many screens show
// the widget, and every screen renders the same filed payloads.
PluginDaemonComponent {
    id: root

    property int refreshSeconds: pluginData.refreshSeconds || 300
    // Bumped whenever a provider's sources change, on any surface.
    readonly property real sourcesStamp: pluginData.sourcesStamp || 0

    // With no bar showing the widget there is nothing to refresh: the poll
    // fetches at once when a view appears.
    onSourcesStampChanged: {
        if (root.watched)
            root.refresh();
    }

    AiUsageLogic {
        id: logic
    }

    // Keep raw payloads keyed by provider so filter, headline and visibility
    // settings can update every surface between polls.
    property var providerData: ({})
    // Filing sequences order payloads against fetch launches.
    property int fileSeq: 0
    property var providerFiledAt: ({})

    function storeHeadline(provider, data) {
        const which = logic.normalizeProvider(provider);
        if (which === "")
            return;
        // New objects, because a var property only notifies on assignment.
        const next = {};
        const nextAt = {};
        const order = logic.providerOrder();
        for (let i = 0; i < order.length; i++) {
            next[order[i]] = root.providerData[order[i]];
            nextAt[order[i]] = root.providerFiledAt[order[i]];
        }
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
        for (let i = 0; i < channels.count; i++) {
            const ch = channels.objectAt(i);
            if (ch && ch.inFlight !== "")
                out.push(ch.inFlight);
        }
        return out;
    }

    readonly property string aiUsageCommand: Paths.vshellCli
    // Space retries by attempt count to allow transient failures to recover.
    readonly property int retryDelayMs: 1000
    // Cap on a failure reason before it reaches the popout and the shell log:
    // the text comes from whichever backend is installed, and a log people paste
    // into bug reports should not accumulate arbitrary backend output.
    readonly property int maxIssueChars: 200
    // Retry budget per channel. shouldRelaunch decides whether to spend it;
    // a satisfying payload restores it.
    readonly property int maxFetchRetries: 3

    // Each fetch channel owns its process, collectors, and one provider. A
    // channel's provider never changes, so a payload can only ever be filed
    // under the identity it names.
    component FetchChannel: QtObject {
        id: chan

        property string want: ""

        // Provider used to launch this fetch. Keep the tag until settlement even
        // if the process stops before its exit arrives.
        property string inFlight: ""
        // Provider last filed by this channel, used to decide whether it owes a fetch.
        property string loaded: ""
        property int retries: 0
        // Keep acceptance and failure reason with the channel that produced them.
        property bool accepted: false
        property string issue: ""
        // StdioCollector text becomes complete only when the stream closes;
        // exit and stream-close signals need not arrive in the same order.
        property string errorOut: ""
        // A deferred launch waits for the preceding process to finish stopping.
        property bool pending: false
        // Only a launch without a started signal belongs to the failed-start watchdog.
        property bool sawProcess: false
        // Launch sequence distinguishes older data from payloads filed during this fetch.
        property int launchSeq: 0
        // Keep the tag until both stdout and exit arrive. Clearing it at exit
        // would reject a valid payload whose stream closes later.
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
                // A stopped tagged launch needs a settlement path before pending work can
                // run. Failed starts use the watchdog; processes that ran owe an exit.
                // Defer the watchdog and re-check because started can arrive after stop.
                if (logic.watchdogArms(chan.inFlight, chan.sawProcess)) {
                    stallTimer.restart();
                    return;
                }
                // Drain parked work only after settlement releases the launch tag.
                if (chan.inFlight === "" && chan.pending)
                    root.launch(chan);
            }
        }

        // Allow a delayed started signal before reporting a failed launch.
        // A process that ran does not arm this timer.
        property Timer stallTimer: Timer {
            id: stallTimer
            interval: 1000
            onTriggered: root.failLaunch(chan)
        }

        // A child can inherit stdout and keep it open after the helper exits.
        // Bound the stream-close wait so that fetch still settles.
        property Timer flushTimer: Timer {
            id: flushTimer
            interval: 1000
            onTriggered: root.settleFetch(chan)
        }

        // Delay retries by attempt count so a transient failure has time to clear.
        property Timer retryTimer: Timer {
            id: retryTimer
            interval: root.retryDelayMs
            onTriggered: root.launch(chan)
        }
    }

    // One channel per provider, built from the catalog itself, so adding a
    // provider cannot leave it without a way to be fetched.
    Instantiator {
        id: channels
        model: logic.providerOrder()

        delegate: FetchChannel {
            want: modelData
        }
    }

    // Refresh every provider. Retries launch only their own channel and spend
    // only its budget.
    function refresh() {
        for (let i = 0; i < channels.count; i++) {
            const ch = channels.objectAt(i);
            if (ch)
                root.launch(ch);
        }
    }

    // Set the tag only when starting. A process still stopping can ignore
    // running = true, so park its request until settlement.
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
        ch.sawProcess = false;
        ch.launchSeq = root.fileSeq;
        ch.accepted = false;
        ch.issue = "";
        ch.errorOut = "";
        ch.outDone = false;
        ch.exitDone = false;
        ch.flushTimer.stop();
        // A watchdog belongs to its launch. Stop it before another fetch reuses the channel.
        ch.stallTimer.stop();
        ch.retryTimer.stop();
        ch.proc.running = true;
    }

    // Record abnormal process termination as the cause, ahead of an empty-output
    // parse error from a helper killed before it could reply.
    function finishFetch(ch, exitCode, exitStatus) {
        // Ignore an exit after this fetch has already settled.
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

    // Settle after both exit and stdout. The tag must survive payload decoding;
    // an exit arriving first starts a bounded stream-close wait.
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

    // Report and retry a launch that never produced a running process.
    function failLaunch(ch) {
        // Re-check at timer delivery: the fetch may have settled or started.
        if (!logic.watchdogArms(ch.inFlight, ch.sawProcess))
            return;
        ch.issue = "could not run " + root.aiUsageCommand;
        console.warn("aiUsage: " + ch.inFlight + " fetch " + ch.issue);
        root.settleFetch(ch);
    }

    // Settle the channel and schedule any remaining retry or parked request.
    function settleFetch(ch) {
        if (ch.inFlight === "")
            return;
        ch.stallTimer.stop();
        ch.flushTimer.stop();

        // Decide retry eligibility before clearing the tag it reads. Delay retry
        // until the process can start and the transient failure has had time to clear.
        const relaunch = logic.shouldRelaunch(ch, root.maxFetchRetries);
        ch.inFlight = "";
        if (relaunch) {
            ch.retries += 1;
            ch.retryTimer.interval = root.retryDelayMs * ch.retries;
            ch.retryTimer.restart();
            return;
        }
        // A parked request may still find a stopping process; launch will park it again.
        if (ch.pending)
            Qt.callLater(() => root.launch(ch));

        // Report a missing payload or an unsuccessful fetch as unavailable.
        if (ch.loaded !== ch.want || !ch.accepted) {
            const why = ch.issue !== "" ? ch.issue : "usage unavailable";
            // A newer successful filing wins over an older failed fetch.
            if (logic.failureWins(root.providerData[ch.want], root.providerFiledAt[ch.want], ch.launchSeq))
                root.storeHeadline(ch.want, { ok: false, provider: ch.want, error: why });
        }
    }

    // File by payload identity. A channel only ever fetches one provider, so a
    // payload naming another one is someone else's answer and is dropped.
    function acceptPayload(ch, txt) {
        const got = logic.decodePayload(ch.inFlight, txt);
        ch.issue = got.issue;
        if (!got.data)
            return;
        ch.accepted = true;
        const outcome = logic.acceptOutcome(logic.payloadProvider(got.data), ch.want);
        if (outcome.file)
            root.noteHeadline(got.data);
        if (!outcome.satisfies)
            return;
        ch.loaded = ch.want;
        ch.retries = 0;
    }

    Timer {
        id: pollTimer
        // Polling visits accounts sequentially, so scale the minimum interval with
        // the reported account count across every provider.
        interval: Math.max(60 * Math.max(1, logic.polledAccountCount(root.providerData)),
                           root.refreshSeconds) * 1000
        repeat: true
        // Poll only while a bar shows the widget, so the first view fetches at
        // once. Start once the channels exist rather than at this timer's own
        // completion: triggeredOnStart against an empty Instantiator would fetch
        // nothing and then wait out a whole refresh interval before trying again.
        running: channels.count > 0 && root.watched
        triggeredOnStart: true
        onTriggered: root.refresh()
    }
}
