import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    // Which providers the bar and the popout show. An empty list means every
    // provider, so "All" and a fresh install are the same stored value and a
    // new provider needs no migration to appear.
    readonly property var providerFilter: pluginData.providerFilter || []
    property int refreshSeconds: pluginData.refreshSeconds || 300
    // How the bar number is derived from the pool. "pool" = mean of each
    // account's tightest window, "best" = the account with the most headroom,
    // "worst" = the most exhausted account.
    property string headlineMode: pluginData.headlineMode || "pool"
    // Account keys the user has hidden. They stay out of the list AND out of
    // the headline, so the number never contradicts what is on screen.
    property var hiddenAccounts: pluginData.hiddenAccounts || []
    // Bumped whenever a provider's sources change, on any surface.
    readonly property real sourcesStamp: pluginData.sourcesStamp || 0

    onSourcesStampChanged: root.refresh()

    AiUsageLogic {
        id: logic
    }

    AiUsageFormat {
        id: fmt
    }

    // Persist without assigning the bound property. Each bar instance must
    // continue to receive pluginData updates.
    function saveSetting(key, value) {
        if (root.pluginService)
            root.pluginService.savePluginData("aiUsage", key, value);
    }

    function toggleProvider(p) {
        root.saveSetting("providerFilter", logic.toggleFilter(root.providerFilter, p));
    }
    function selectAllProviders() {
        root.saveSetting("providerFilter", []);
    }
    function toggleHidden(card) {
        root.saveSetting("hiddenAccounts", logic.toggleHiddenCard(root.hiddenAccounts, card));
    }
    function isHidden(card) {
        return logic.isCardHidden(card, root.hiddenAccounts);
    }
    function setHeadlineMode(m) {
        root.saveSetting("headlineMode", m);
    }
    // A source changed on some surface. The stamp travels through the plugin
    // service, so every bar instance refetches — including the one whose popout
    // is open, and including bars on other screens that never saw the change.
    function stampSources() {
        root.saveSetting("sourcesStamp", Date.now());
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

    // One object every surface reads. The pill, the popout deck and the header
    // counts cannot disagree about which providers or accounts are in scope
    // because there is only one description of it.
    readonly property var deckState: ({
        providerData: root.providerData,
        filter: root.providerFilter,
        hidden: root.hiddenAccounts,
        mode: root.headlineMode,
        display: { value: root.barValue },
        fetching: root.fetchingProviders
    })

    readonly property var view: logic.deckView(root.deckState)
    readonly property bool ok: root.view.ok
    readonly property bool pending: root.view.pending
    readonly property bool allHidden: root.view.allHidden
    readonly property string errorText: root.view.error
    readonly property bool hasHeadline: root.view.headline !== null
    readonly property int headlinePct: root.view.headline === null ? 0 : root.view.headline

    readonly property int pillFontSize: Theme.barTextSize(
        root.barThickness, root.barConfig?.fontScale, root.barConfig?.maximizeWidgetText)

    // Whether cards open expanded. Compact shows one row per limit; expanded
    // shows each limit as its own bar with its reset countdown under it.
    readonly property bool expandByDefault: pluginData.cardDetail === "expanded"
    // Absent means on: a fresh install shows icons and colour, and only a
    // stored false turns either off.
    readonly property bool barIcons: pluginData.barIcons !== false
    readonly property bool barColor: pluginData.barColor !== false
    readonly property string barValue: pluginData.barValue === "left" ? "left" : "used"

    // The one card whose state is the opposite of the default. Storing the
    // exception rather than a set means changing the default flips every card,
    // which is what a default is for.
    property string toggledCardKey: ""

    function cardExpanded(key) {
        return root.expandByDefault !== (root.toggledCardKey === key);
    }
    function toggleCard(key) {
        root.toggledCardKey = root.toggledCardKey === key ? "" : key;
    }
    // Everything the shared display page reads and writes back by key.
    readonly property var displaySettings: ({
        headlineMode: root.headlineMode,
        barValue: root.barValue,
        barIcons: root.barIcons,
        barColor: root.barColor,
        cardDetail: pluginData.cardDetail || "compact"
    })

    function pillHeads() {
        return logic.pillSlots(root.deckState);
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
    function metersFor(card) {
        return fmt.metersFor(card);
    }

    // Provider identity for the child surfaces. They reach the catalog through
    // the host rather than holding their own reference to it, so a component
    // property can never shadow the decision module the widget is using.
    function providerOrder() {
        return logic.providerOrder();
    }
    function providerName(p) {
        return logic.providerName(p);
    }
    function providerIcon(p) {
        return logic.providerIcon(p);
    }
    function providerFullName(p) {
        return logic.providerFullName(p);
    }
    function accountFooter(card) {
        return logic.accountFooter(card);
    }
    function filterHas(p) {
        return logic.filterHas(root.providerFilter, p);
    }
    function filterIsAll() {
        return logic.filterIsAll(root.providerFilter);
    }
    function filterLabel() {
        return logic.filterLabel(root.providerFilter);
    }
    function accountCountLabel(n) {
        return logic.accountCount(n);
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

    // A slot's colour. Severity is read from CONSUMPTION whichever end the bar
    // counts from, so turning the reading to "left" does not turn a full limit
    // green. `plain` is the neutral this orientation uses when there is no
    // number, or when the user asked for one colour.
    function slotColor(slot, plain) {
        if (slot.error)
            return Theme.error;
        if (slot.pct === null || !root.barColor)
            return plain;
        return root.percentageColor(slot.pct);
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
        interval: Math.max(60 * Math.max(1, root.view.totalCount), root.refreshSeconds) * 1000
        repeat: true
        // Start once the channels exist rather than at this timer's own completion:
        // triggeredOnStart against an empty Instantiator would fetch nothing and
        // then wait out a whole refresh interval before trying again.
        running: channels.count > 0
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
                        // A setup slot keeps its icon whatever the icon setting
                        // says: it has no number, so hiding it would leave the
                        // slot empty and the way in unreachable.
                        visible: root.barIcons || modelData.setup
                        // An invitation to set a provider up is not a reading and
                        // not a fault: it takes the accent, so it does not sit on
                        // the bar looking like a number that failed to load.
                        color: modelData.setup ? Theme.primary
                            : (modelData.error ? Theme.error : Theme.surfaceVariantText)
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    StyledText {
                        text: modelData.text
                        visible: text.length > 0
                        font.pixelSize: root.pillFontSize
                        font.weight: Font.Medium
                        color: root.slotColor(modelData, Theme.surfaceVariantText)
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
            }
        }
    }

    // The same slots stacked. A vertical bar shows every selected provider too,
    // so the two orientations cannot say different things about one payload.
    verticalBarPill: Component {
        Column {
            spacing: 2

            Repeater {
                model: root.pillHeads()

                Column {
                    required property var modelData
                    spacing: 0
                    anchors.horizontalCenter: parent.horizontalCenter

                    VgsIcon {
                        name: modelData.icon
                        size: root.iconSize
                        visible: root.barIcons || modelData.setup
                        color: modelData.setup ? Theme.primary
                            : (modelData.error ? Theme.error : Theme.surfaceText)
                        anchors.horizontalCenter: parent.horizontalCenter
                    }

                    StyledText {
                        text: modelData.text
                        visible: text.length > 0
                        font.pixelSize: root.pillFontSize
                        color: root.slotColor(modelData, Theme.surfaceText)
                        anchors.horizontalCenter: parent.horizontalCenter
                    }
                }
            }
        }
    }

    popoutWidth: 380
    popoutContent: Component {
        PopoutComponent {
            id: popout

            // Transient page state: usage, then display settings, then one
            // provider's setup. Both pushed pages are entered from the usage
            // page, so a step back always lands there.
            property int page: 0
            property string setupProvider: ""
            readonly property bool onSettings: popout.page === 1
            readonly property bool onSetup: popout.page === 2

            function openSetup(provider) {
                popout.setupProvider = provider;
                popout.page = 2;
            }

            // PluginPopout owns keyboard focus and uses this contract for Escape and
            // for resetting a pushed page when the popout closes.
            readonly property bool canPopBack: popout.page > 0
            function popBack() {
                popout.page = 0;
            }

            headerText: {
                if (popout.onSetup)
                    return logic.providerFullName(popout.setupProvider) + " setup";
                if (popout.onSettings)
                    return "Display settings";
                const picked = logic.selectedProviders(root.providerFilter);
                return picked.length === 1 ? logic.providerName(picked[0]) + " Usage" : "AI Usage";
            }
            detailsText: {
                if (popout.onSetup)
                    return "Where this provider's accounts come from.";
                if (popout.onSettings)
                    return "How the bar number is chosen, and which accounts count.";
                if (root.pending)
                    return "Checking usage…";
                // A provider nobody has set up yet is not a fault to report.
                if (root.view.needsSetup)
                    return "Not set up yet";
                if (root.allHidden)
                    return logic.accountCount(root.view.totalCount) + " hidden";
                // Each failing provider still draws its own card with its own
                // cause; the header speaks only when no account answered at all.
                if (!root.ok)
                    return root.errorText || "Unavailable";
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
            refreshable: popout.page === 0
            refreshBusy: root.fetchingProviders.length > 0
            onRefreshRequested: root.refresh()

            // The shared header slot, which PopoutComponent owns for every flyout.
            configurable: true
            settingsBack: popout.page > 0
            onSettingsRequested: {
                if (popout.page > 0)
                    popout.popBack();
                else
                    popout.page = 1;
            }

            // The viewport follows the active page height so a pushed page
            // replaces the usage content instead of adding to its total height.
            Item {
                id: pager

                width: parent.width
                clip: true
                height: popout.onSetup ? setupPage.implicitHeight
                    : (popout.onSettings ? settingsPage.implicitHeight : usagePage.implicitHeight)

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

                        // The filter owns which providers are on the bar and in
                        // this list, and is the way into each provider's setup.
                        AiUsageFilterMenu {
                            width: parent.width
                            host: root
                            onProviderToggled: p => root.toggleProvider(p)
                            onAllRequested: root.selectAllProviders()
                            onSetupRequested: p => popout.openSetup(p)
                        }

                        Repeater {
                            model: root.view.sections

                            Column {
                                id: section

                                required property var modelData

                                width: parent.width
                                spacing: Theme.spacingXS

                                // Section headers are noise when one provider is
                                // on screen; the popout title already names it.
                                Item {
                                    width: parent.width
                                    height: root.view.grouped ? sectionLabel.implicitHeight + Theme.spacingXS : 0
                                    visible: root.view.grouped

                                    Row {
                                        anchors.left: parent.left
                                        anchors.bottom: parent.bottom
                                        spacing: Theme.spacingXS

                                        VgsIcon {
                                            name: section.modelData.icon
                                            size: Theme.iconSizeSmall
                                            color: Theme.surfaceVariantText
                                            anchors.verticalCenter: parent.verticalCenter
                                        }

                                        StyledText {
                                            id: sectionLabel
                                            text: section.modelData.name
                                            font.pixelSize: Theme.fontSizeSmall
                                            font.weight: Font.Medium
                                            color: Theme.surfaceVariantText
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                    }
                                }

                                Repeater {
                                    model: section.modelData.cards

                                    AiUsageAccountCard {
                                        required property var modelData

                                        width: section.width
                                        host: root
                                        account: modelData
                                        showProviderIcon: !root.view.grouped
                                        expanded: root.cardExpanded(modelData.key)
                                        onToggleExpanded: root.toggleCard(modelData.key)
                                        onHideRequested: root.toggleHidden(modelData)
                                    }
                                }

                                // A provider that answered with nothing usable
                                // says so where its cards would have been, so
                                // one failing provider cannot be mistaken for
                                // a failure of the whole widget.
                                AiUsageProviderNotice {
                                    width: section.width
                                    host: root
                                    sectionData: section.modelData
                                    onSetupRequested: popout.openSetup(section.modelData.provider)
                                }
                            }
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

                                AiUsageDisplaySettings {
                                    width: parent.width
                                    values: root.displaySettings
                                    onChanged: (key, value) => root.saveSetting(key, value)
                                }

                                StyledText {
                                    text: "Accounts"
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.Medium
                                    color: Theme.surfaceText
                                    visible: accountVisibility.count > 0
                                    topPadding: Theme.spacingXS
                                }

                                // Every account of every selected provider,
                                // hidden ones included: this is the only place
                                // a hidden account can be brought back.
                                Repeater {
                                    id: accountVisibility
                                    model: logic.allCards(root.deckState)

                                    Item {
                                        required property var modelData
                                        width: settingsCol.width
                                        height: 26

                                        VgsIcon {
                                            id: rowIcon
                                            anchors.left: parent.left
                                            anchors.verticalCenter: parent.verticalCenter
                                            name: modelData.providerIcon
                                            size: Theme.iconSizeSmall
                                            color: Theme.surfaceVariantText
                                        }

                                        StyledText {
                                            anchors.left: rowIcon.right
                                            anchors.leftMargin: Theme.spacingXS
                                            anchors.right: eyeIcon.left
                                            anchors.rightMargin: Theme.spacingS
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: modelData.label
                                            elide: Text.ElideMiddle
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: root.isHidden(modelData) ? Theme.surfaceVariantText
                                                                            : Theme.surfaceText
                                        }

                                        VgsIcon {
                                            id: eyeIcon
                                            anchors.right: parent.right
                                            anchors.verticalCenter: parent.verticalCenter
                                            name: root.isHidden(modelData) ? "visibility_off" : "visibility"
                                            size: Theme.iconSizeSmall
                                            color: root.isHidden(modelData) ? Theme.surfaceVariantText
                                                                            : Theme.primary
                                        }

                                        MouseArea {
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.toggleHidden(modelData)
                                        }
                                    }
                                }

                                StyledText {
                                    width: parent.width
                                    visible: accountVisibility.count === 0
                                    text: "No accounts reported yet."
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    wrapMode: Text.WordWrap
                                }
                            }
                        }
                    }

                    Column {
                        id: setupPage
                        width: pager.width
                        spacing: Theme.spacingM

                        AiUsageProviderSetup {
                            width: parent.width
                            provider: popout.setupProvider
                            // Only mount the processes for the provider being
                            // looked at: this page is one of three in a Row and
                            // is built whether or not it is on screen.
                            active: popout.onSetup
                            onSourcesChanged: root.stampSources()
                        }
                    }
                }
            }
        }
    }
}
