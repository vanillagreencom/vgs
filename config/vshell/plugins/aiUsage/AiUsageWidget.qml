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

    function shownAccounts(list) {
        return logic.shownIn(list, root.hiddenAccounts);
    }
    function headlineFor(list) {
        return logic.headlineOf(list, root.headlineMode, root.hiddenAccounts);
    }

    // --- Live state ---
    //
    // ONE accepted payload, for the provider that is selected. Everything the
    // popout renders is a binding off it, so a provider switch invalidates all
    // of it by clearing this single property — there is no hand-maintained
    // mirror to forget a field in, which is how the previous provider's numbers
    // used to survive a switch (VGS-118).
    property var current: null
    // Why the last fetch for the selected provider could not deliver a payload.
    // Non-empty means what `current` holds is no longer trustworthy.
    property string fetchError: ""
    property bool loading: true

    readonly property bool ok: root.fetchError === "" && root.current !== null && root.current.ok === true
    readonly property string errorText: {
        if (root.fetchError !== "")
            return root.fetchError;
        if (root.current && root.current.ok !== true)
            return root.current.error || "usage unavailable";
        return "";
    }
    readonly property string plan: (root.current && root.current.plan) || ""

    // --- Multi-account state ---
    // People run several subscriptions side by side (one config dir per wrapper
    // script). With a single account this stays a one-entry list and every path
    // below falls back to the payload's flat lanes, so nothing changes for them.
    readonly property var accounts: (root.current && root.current.accounts) || []
    readonly property var aggregate: (root.current && root.current.aggregate) || null
    readonly property bool multiAccount: (root.accounts || []).length > 1
    property string expandedAccountId: ""
    readonly property int pillFontSize: Theme.barTextSize(
        root.barThickness, root.barConfig?.fontScale, root.barConfig?.maximizeWidgetText)

    // Consumption across the whole pool: each account contributes one 100%
    // allowance, so this is consumed/available — four accounts at 50% read as
    // 50%, not 200%. Prefers the session window like the single-account pill.
    readonly property int aggregatePct: {
        if (!root.aggregate)
            return root.primaryPct;
        // `pct` is the mean of each account's tightest window. The older
        // session/weekly means are kept for compatibility but must not be the
        // headline: averaging the 5h window alone read 8% on a pool whose
        // weeklies were at 96-100%.
        const local = root.headlineFor(root.accounts);
        if (local !== null)
            return local;
        if (root.aggregate.pct !== null && root.aggregate.pct !== undefined)
            return root.aggregate.pct;
        if (root.aggregate.weekly !== null && root.aggregate.weekly !== undefined)
            return root.aggregate.weekly;
        if (root.aggregate.session !== null && root.aggregate.session !== undefined)
            return root.aggregate.session;
        return 0;
    }
    readonly property int headlinePct: root.multiAccount ? root.aggregatePct : root.primaryPct

    // Meters for the single-account view. Prefers the accounts list so lanes the
    // flat payload can't express (a credit pool, a second model) still show up,
    // and falls back to the payload's own lanes if an older helper omits
    // accounts.
    readonly property var primaryMeters: {
        const list = root.accounts || [];
        if (list.length > 0)
            return logic.metersFor(list[0]);
        return logic.flatMeters(root.current);
    }

    function formatResetAt(epoch) {
        return logic.formatResetAt(epoch);
    }
    function formatSpend(meter) {
        return logic.formatSpend(meter);
    }
    function formatSpendExact(meter) {
        return logic.formatSpendExact(meter);
    }
    function resetLabel(meter) {
        return logic.resetLabel(meter);
    }

    function providerIcon() {
        return logic.providerIcon(root.provider);
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
        return classColor(logic.percentageClass(pct));
    }

    // Headline percentage: the tightest lane this account has. Same reasoning as
    // aggregatePct — the 5h session is usually the emptiest window and says
    // nothing about whether the weekly is about to block you.
    readonly property int primaryPct: {
        const one = root.headlineFor(root.accounts);
        if (one !== null && (root.accounts || []).length > 0)
            return one;
        const lanes = root.primaryMeters || [];
        let peak = 0;
        for (let i = 0; i < lanes.length; i++)
            peak = Math.max(peak, lanes[i].pct || 0);
        return peak;
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
    function storeHeadline(provider, data) {
        const which = logic.normalizeProvider(provider);
        if (which === "")
            return;
        // A new object, because a var property only notifies on assignment.
        const next = { claude: root.providerData.claude, codex: root.providerData.codex };
        next[which] = data;
        root.providerData = next;
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
            fetching: root.fetchingProviders
        });
    }

    // One record per fetch channel. Both channels ask the same four questions,
    // and holding them separately was how the shared failure-reason field ended
    // up reporting one provider's cause as the other's: two copies of a concept
    // stay in step only as long as somebody remembers both.
    component FetchChannel: QtObject {
        // The provider this channel's process was LAUNCHED for, empty when
        // nothing is running. A Process command is a binding on the provider,
        // but a fetch already running when the provider changes keeps its old
        // argument. The tag says which argument a running process actually got;
        // the payload's own `provider` field is what decides where its data may
        // be filed, because a tag can be reassigned while the process holding
        // it is still running.
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
        // A launch asked for while the previous process was still stopping, to
        // be applied when it actually stops.
        property bool pending: false
        // The channel whose payload the popout shows. The other one keeps only
        // its provider's headline.
        property bool primary: false

        // What a provider switch invalidates. `inFlight` is deliberately not
        // touched: a process is still running and its tag is what identifies it.
        function reset() {
            loaded = "";
            retries = 0;
            accepted = false;
            issue = "";
        }
    }

    FetchChannel {
        id: usageFetch
        primary: true
    }
    FetchChannel {
        id: otherFetch
    }

    // Immediate relaunches allowed before giving up and waiting for the poll
    // timer. Reset by any accepted payload and by a provider switch, so this
    // only ever runs out on a helper that keeps returning nothing usable.
    readonly property int maxFetchRetries: 3

    // A provider switch makes every provider-scoped answer wrong at once: the
    // payload, the failure text, and both channels' "what do we hold" state. One
    // path clears all of it, so the popout shows a loading state rather than the
    // previous provider's accounts, plan and errors. The per-provider headlines
    // (claudeData/codexData) are deliberately kept: they are keyed by provider
    // identity, so they cannot be mixed up.
    function clearProviderState() {
        root.current = null;
        root.fetchError = "";
        root.loading = true;
        root.expandedAccountId = "";
        usageFetch.reset();
        otherFetch.reset();
    }

    // `which` is "usage", "other", or empty for both. A retry relaunches only
    // the channel that asked for one: restarting both would spend one channel's
    // budget on the other's process, and every launch shells out to a provider
    // usage API once per configured bar.
    function refresh(which) {
        if (which !== "usage")
            root.launch(otherFetch, otherProc, root.otherProvider);
        if (which !== "other")
            root.launch(usageFetch, usageProc, root.provider);
    }

    // A tag is only set when a process actually starts. `running = true` on a
    // Process that has not finished stopping is a no-op, so that case parks the
    // request on the channel and onRunningChanged applies it — a tag set for a
    // launch that never happened would show a fetch that does not exist and
    // block every later refresh until the poll timer.
    function launch(ch, proc, want) {
        const decision = logic.launchDecision(ch.inFlight, proc.running);
        if (decision === "skip")
            return;
        if (decision === "pend") {
            ch.pending = true;
            return;
        }
        ch.pending = false;
        ch.inFlight = want;
        ch.accepted = false;
        ch.issue = "";
        proc.running = true;
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
        root.refresh("");
    }

    readonly property string aiUsageCommand: Paths.vshellCli

    Process {
        id: usageProc
        command: [root.aiUsageCommand, "ai-usage", root.provider]
        running: false
        stdout: StdioCollector {
            id: usageOut
            onStreamFinished: root.acceptPayload(usageFetch, root.provider, usageOut.text)
        }
        // Kept, because a helper that fails before printing anything says why
        // here and nowhere else. Without it the widget reported "parse error"
        // for a payload the helper never produced.
        stderr: StdioCollector {
            id: usageErr
        }
        // Clearing the tag belongs in the exit handler rather than in
        // onStreamFinished: the stream closes before the process is reaped (the
        // same ordering Common/settings/Processes.qml relies on), so by the time
        // it runs the accept/discard decision has already been made, and a fetch
        // that produced no output at all still releases the slot.
        onExited: (exitCode, exitStatus) => {
            root.finishFetch(usageFetch, "usage", root.provider, exitCode, usageErr.text);
        }
        // The documented Quickshell restart idiom: a launch requested while this
        // was still stopping is applied here, when it has actually stopped.
        onRunningChanged: {
            if (!running && usageFetch.pending)
                root.launch(usageFetch, usageProc, root.provider);
        }
    }

    // The provider the popout is NOT showing. Only its headline is kept, so the
    // pill can read "claude / codex" without doubling the popout's state.
    readonly property string otherProvider: root.provider === "codex" ? "claude" : "codex"

    Process {
        id: otherProc
        command: [root.aiUsageCommand, "ai-usage", root.otherProvider]
        running: false
        stdout: StdioCollector {
            id: otherOut
            onStreamFinished: root.acceptPayload(otherFetch, root.otherProvider, otherOut.text)
        }
        stderr: StdioCollector {
            id: otherErr
        }
        onExited: (exitCode, exitStatus) => {
            root.finishFetch(otherFetch, "other", root.otherProvider, exitCode, otherErr.text);
        }
        onRunningChanged: {
            if (!running && otherFetch.pending)
                root.launch(otherFetch, otherProc, root.otherProvider);
        }
    }

    // One exit path for both channels. `want` is the provider this channel is
    // supposed to be holding — the selected one for the usage channel, the other
    // one for its neighbour.
    function finishFetch(ch, which, want, exitCode, errorOut) {
        const launchedFor = ch.inFlight;
        ch.inFlight = "";
        if (launchedFor === "")
            return;

        // A non-zero exit means the helper never produced a payload, so naming
        // this "parse error" would report the wrong cause. The first stderr line
        // is what the helper writes when it knows why it failed.
        if (!ch.accepted && exitCode !== 0) {
            const lines = String(errorOut || "").split("\n").filter(l => l.trim() !== "");
            ch.issue = "helper exited " + exitCode + (lines.length > 0 ? ": " + lines[0].trim() : "");
            console.warn("aiUsage: " + launchedFor + " fetch " + ch.issue);
        }

        // Relaunch whenever this channel is not holding the provider it should
        // be — whatever the reason: the payload was discarded as misattributed,
        // it arrived after the user switched away, or it never parsed. Comparing
        // `launchedFor` to the selection instead dropped the replacement fetch on
        // a claude -> codex -> claude toggle, which is where the stale accounts
        // came from (VGS-118).
        //
        // DEFERRED, because a relaunch assigns `running = true` and that is a
        // no-op while `running` still reads true. Quickshell 0.3.0 documents
        // `running = false` as "send SIGTERM" and gives the restart idiom as
        // `onRunningChanged: if (!running) running = true` — against
        // runningChanged, not exited — and nowhere states that `running` has
        // already flipped when `exited` fires. Assuming it has would silently
        // drop the replacement fetch and leave the widget on loading = true
        // until the poll timer. Next turn, both have settled.
        if (logic.shouldRelaunch(launchedFor, ch.loaded, want, ch.retries, root.maxFetchRetries)) {
            ch.retries += 1;
            Qt.callLater(() => root.refresh(which));
            return;
        }

        // Either there is still nothing for `want`, or this fetch produced no
        // payload and what is held is now stale. Both are failures of the same
        // kind: say so rather than sitting on "loading" or on numbers no fetch
        // stands behind, and drop that provider's headline so the pill cannot
        // show a number the popout contradicts.
        if (ch.loaded !== want || !ch.accepted) {
            const why = ch.issue !== "" ? ch.issue : "usage unavailable";
            root.storeHeadline(want, { ok: false, provider: want, error: why });
            if (want === root.provider) {
                root.loading = false;
                root.fetchError = why;
            }
        }
    }

    // Both channels accept through one path: decode, record the reason on THIS
    // channel, then apply the outcome AiUsageLogic decided. Filing a payload and
    // satisfying a channel are separate answers — a result that lands after the
    // user switched still updates its own provider's pill slot, but leaves the
    // channel owing a fetch for what is selected now.
    function acceptPayload(ch, want, txt) {
        const got = logic.decodePayload(ch.inFlight, txt);
        ch.issue = got.issue;
        if (!got.data)
            return;
        ch.accepted = true;
        const outcome = logic.acceptOutcome(logic.payloadProvider(got.data), want, ch.primary);
        if (outcome.file)
            root.noteHeadline(got.data);
        if (outcome.loaded !== "")
            ch.loaded = outcome.loaded;
        if (outcome.resetRetries)
            ch.retries = 0;
        if (outcome.apply)
            root.applyPayload(got.data);
    }

    // The whole popout is a binding off `current`, so accepting a payload is one
    // assignment. Adding a lane later means adding it to the payload and to
    // AiUsageLogic.flatMeters — never to a mirror here that a switch has to
    // remember to clear.
    function applyPayload(d) {
        root.current = d;
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
        onTriggered: root.refresh("")
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
                name: root.providerIcon()
                size: root.iconSize
                color: Theme.surfaceText
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                text: root.ok ? (root.headlinePct + "%") : (root.loading ? "…" : "!")
                font.pixelSize: root.pillFontSize
                color: root.ok ? root.percentageColor(root.headlinePct)
                               : (root.loading ? Theme.surfaceVariantText : Theme.error)
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
                    return root.errorText || "Unavailable";
                if (!root.multiAccount)
                    return root.plan || "";
                // Counted over what is actually on screen — saying "5 accounts"
                // beside a number derived from four of them is just wrong.
                const shown = root.shownAccounts(root.accounts);
                const live = shown.filter(a => a.ok).length;
                const hidden = root.accounts.length - shown.length;
                const unavailable = shown.length - live;
                let suffix = unavailable > 0 ? (" · " + unavailable + " unavailable") : "";
                if (hidden > 0)
                    suffix += " · " + hidden + " hidden";
                return live + " accounts · " + root.aggregatePct + "% used" + suffix;
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
                                readonly property var meters: logic.metersFor(modelData)
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
                            text: root.errorText || "No data"
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
