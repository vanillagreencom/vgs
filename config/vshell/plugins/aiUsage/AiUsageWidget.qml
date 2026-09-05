import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    // Normalize settings before using a provider as a launch tag. Unknown tags
    // would reject every payload and prevent the widget from recovering.
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
        // Persist without assigning the bound property. Each bar instance must
        // continue to receive pluginData updates.
        if (root.pluginService)
            root.pluginService.savePluginData("aiUsage", "hiddenAccounts", cur);
    }
    function setHeadlineMode(m) {
        if (root.pluginService)
            root.pluginService.savePluginData("aiUsage", "headlineMode", m);
    }

    AiUsageLogic {
        id: logic
    }

    AiUsageFormat {
        id: fmt
    }

    function shownAccounts(list) {
        return logic.shownIn(list, root.hiddenAccounts);
    }

    // The selected payload is the source for popout bindings. Clearing it
    // invalidates provider-specific display state on a switch.
    property var current: null
    // Filing sequence of current, used to reject older promotions.
    property int currentFiledAt: 0
    // Why the last fetch for the selected provider could not deliver a payload.
    // Non-empty means what `current` holds is no longer trustworthy.
    property string fetchError: ""
    property bool loading: true

    // Top-level payload fields can describe a hidden account. The view derives
    // its display state from the visible accounts.
    readonly property var view: logic.popoutView(root.current, root.hiddenAccounts, root.loading)

    readonly property bool ok: root.fetchError === "" && root.view.ok
    readonly property string errorText: root.fetchError !== "" ? root.fetchError : root.view.error
    readonly property string plan: root.view.plan
    readonly property bool pending: root.fetchError === "" && root.view.pending

    // Choose card layout from reported accounts, before filtering hidden ones.
    readonly property var accounts: (root.current && root.current.accounts) || []
    readonly property bool multiAccount: root.view.cards
    // The payload reported accounts and the user is hiding all of them: nothing
    // failed, there is simply nothing to show.
    readonly property bool allHidden: root.view.allHidden
    property string expandedAccountId: ""
    readonly property int pillFontSize: Theme.barTextSize(
        root.barThickness, root.barConfig?.fontScale, root.barConfig?.maximizeWidgetText)

    // Use the same headline calculation as the pill slots. Null means no
    // visible account and no payload-level lane supplies a usable number.
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

    // Keep raw payloads keyed by provider so headline and visibility settings
    // can update the pills between polls.
    property var providerData: ({})

    readonly property var claudeHead: logic.headOf(root.providerData.claude, root.headlineMode, root.hiddenAccounts)
    readonly property var codexHead: logic.headOf(root.providerData.codex, root.headlineMode, root.hiddenAccounts)

    // Filing sequences order payloads against fetch launches and provider switches.
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
    // The unselected provider still needs a fetch channel for its pill slot.
    readonly property string otherProvider: root.provider === "codex" ? "claude" : "codex"
    // Space retries by attempt count to allow transient failures to recover.
    readonly property int retryDelayMs: 1000
    // Cap on a failure reason before it reaches the popout and the shell log:
    // the text comes from whichever backend is installed, and a log people paste
    // into bug reports should not accumulate arbitrary backend output.
    readonly property int maxIssueChars: 200

    // Each fetch channel owns its process, collectors, and requested provider.
    component FetchChannel: QtObject {
        id: chan

        property string want: ""
        // Whether this channel supplies the selected-provider popout.
        property bool primary: false

        // Provider used to launch this fetch. Keep the tag until settlement even
        // if selection changes or the process stops before its exit arrives.
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

        // Stop work armed for the previous selection. Retain a launch tag only
        // when settleIsComing says a process still owes settlement; otherwise the
        // switch must settle work whose only remaining timer was stopped.
        function reset() {
            loaded = "";
            retries = 0;
            accepted = false;
            issue = "";
            stallTimer.stop();
            retryTimer.stop();
            flushTimer.stop();
            pending = false;
            if (!logic.settleIsComing({ inFlight: inFlight, running: proc.running,
                                        sawProcess: sawProcess, exitDone: exitDone }))
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

    // Retry budget per channel. shouldRelaunch decides whether to spend it;
    // a satisfying payload or provider switch restores it.
    readonly property int maxFetchRetries: 3

    // Clear selected-provider state on a switch. Preserve providerData because
    // its entries remain keyed by payload identity.
    function clearProviderState() {
        root.current = null;
        // Use the switch sequence as a barrier: cached data remains in the pills,
        // but only a later filing may populate the selected-provider popout.
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
        // Persist and let onProviderChanged refresh every live instance.
        // Desktop widgets can deliver pluginDataChanged after this setter returns.
        if (root.pluginService)
            root.pluginService.savePluginData("aiUsage", "provider", p);
    }

    // React to the shared setting change so every bar instance refreshes.
    onProviderChanged: {
        root.clearProviderState();
        root.refresh();
    }

    // Refresh both channels for a poll or provider switch. Retries launch only
    // their own channel and spend only its budget.
    function refresh() {
        root.launch(otherFetch);
        root.launch(usageFetch);
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

        // Report a missing requested payload or an unsuccessful fetch as unavailable.
        if (ch.loaded !== ch.want || !ch.accepted) {
            const why = ch.issue !== "" ? ch.issue : "usage unavailable";
            // A newer successful filing wins over an older failed fetch, including
            // one delivered by the other channel during a provider switch.
            const authoritative = logic.failureWins(
                root.providerData[ch.want], root.providerFiledAt[ch.want], ch.launchSeq);
            if (authoritative)
                root.storeHeadline(ch.want, { ok: false, provider: ch.want, error: why });
            if (ch.primary) {
                // Settlement ends loading even if newer data suppresses this failure text.
                root.loading = false;
                if (authoritative)
                    root.fetchError = why;
            }
        }
    }

    // File by payload identity. A result can update its pill while the channel
    // still owes a fetch for a different selected provider.
    function acceptPayload(ch, txt) {
        const got = logic.decodePayload(ch.inFlight, txt);
        ch.issue = got.issue;
        if (!got.data)
            return;
        ch.accepted = true;
        const outcome = logic.acceptOutcome(logic.payloadProvider(got.data), ch.want);
        if (outcome.file)
            root.noteHeadline(got.data);
        // Either channel can file for the selected provider during a switch.
        root.promoteSelected();
        if (!outcome.satisfies)
            return;
        ch.loaded = ch.want;
        ch.retries = 0;
    }

    // Promote the selected provider from filed data, independent of fetch channel.
    function promoteSelected() {
        const filed = root.providerData[root.provider];
        const filedAt = root.providerFiledAt[root.provider];
        // Accept provider error payloads too. Their sequence controls promotion;
        // the popout renders their error instead of waiting for a success.
        if (!logic.newerAccepted(filed, filedAt, root.currentFiledAt))
            return;
        root.current = filed;
        root.currentFiledAt = filedAt;
        root.fetchError = "";
        root.loading = false;
    }

    Timer {
        id: pollTimer
        // Polling visits accounts sequentially, so scale the minimum interval with
        // the reported account count.
        interval: Math.max(60 * Math.max(1, (root.accounts || []).length), root.refreshSeconds) * 1000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    // Keep each provider icon with its slot when another provider has no number.
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

            // Transient page state: usage is the opening page, display settings the next.
            property int page: 0
            readonly property bool onSettings: popout.page === 1

            // PluginPopout owns keyboard focus and uses this contract for Escape and
            // for resetting a pushed page when the popout closes.
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
                if (root.allHidden)
                    return logic.accountCount(root.view.totalCount) + " hidden";
                if (!root.multiAccount)
                    return root.plan || "";
                const unavailable = root.view.shownCount - root.view.liveCount;
                let suffix = unavailable > 0 ? (" · " + unavailable + " unavailable") : "";
                if (root.view.hiddenCount > 0)
                    suffix += " · " + root.view.hiddenCount + " hidden";
                const used = root.hasHeadline ? (" · " + root.headlinePct + "% used") : "";
                return logic.accountCount(root.view.liveCount) + used + suffix;
            }
            showCloseButton: true

            // The shared header slot. This surface could always refresh — the
            // popout re-reads on open — but it offered no way to ask for one.
            refreshable: !popout.onSettings
            refreshBusy: root.pending
            onRefreshRequested: root.refresh()

            // The shared header slot. It was a hand-drawn copy of this, which
            // PopoutComponent now owns for every flyout.
            configurable: true
            settingsBack: popout.onSettings
            onSettingsRequested: popout.page = popout.onSettings ? 0 : 1

            // The viewport follows the active page height so settings replace the
            // usage content instead of increasing its total height.
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

                        // Wrap the tabs to add space without changing gaps between account cards.
                        Item {
                            width: parent.width
                            height: providerRow.implicitHeight + 10

                            Row {
                                id: providerRow
                                width: parent.width
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Theme.spacingS

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
                                    // A credit pool reports an amount instead of a reset countdown.
                                    detailText: root.formatSpendExact(modelData) || root.resetLabel(modelData)
                                }
                            }
                        }

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
