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
    property string provider: pluginData.provider || "claude"
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
        root.hiddenAccounts = cur;
        if (root.pluginService)
            root.pluginService.savePluginData("aiUsage", "hiddenAccounts", cur);
    }
    function setHeadlineMode(m) {
        root.headlineMode = m;
        if (root.pluginService)
            root.pluginService.savePluginData("aiUsage", "headlineMode", m);
    }

    // The tightest window an account has — what actually blocks it.
    function accountPeak(a) {
        if (!a)
            return 0;
        let peak = 0;
        if (a.session && a.session.pct !== undefined) peak = Math.max(peak, a.session.pct);
        if (a.weekly && a.weekly.pct !== undefined) peak = Math.max(peak, a.weekly.pct);
        const ms = a.models || [];
        for (let i = 0; i < ms.length; i++) peak = Math.max(peak, ms[i].pct || 0);
        if (a.spend && a.spend.pct !== undefined) peak = Math.max(peak, a.spend.pct);
        return peak;
    }
    function isEnterpriseAccount(account) {
        if (!account)
            return false;
        if (account.enterprise === true)
            return true;
        // Compatibility with helper payloads from before `enterprise` was
        // explicit. Never infer account type from the email address.
        const plan = String(account.plan || "").toLowerCase();
        return plan.indexOf("enterprise") === 0 || account.spend !== null && account.spend !== undefined;
    }
    function orderedAccounts(list) {
        const ordered = (list || []).slice();
        ordered.sort((a, b) => {
            const groupA = root.isEnterpriseAccount(a) ? 1 : 0;
            const groupB = root.isEnterpriseAccount(b) ? 1 : 0;
            if (groupA !== groupB)
                return groupA - groupB;
            const labelA = String(a.label || a.id || "");
            const labelB = String(b.label || b.id || "");
            const foldedA = labelA.toLowerCase();
            const foldedB = labelB.toLowerCase();
            if (foldedA < foldedB)
                return -1;
            if (foldedA > foldedB)
                return 1;
            return labelA < labelB ? -1 : (labelA > labelB ? 1 : 0);
        });
        return ordered;
    }
    function shownAccounts(list) {
        return root.orderedAccounts(list).filter(a => a && !root.isHidden(a.id));
    }
    // Headline over whichever accounts are visible, in the chosen mode.
    function headlineFor(list) {
        const peaks = root.shownAccounts(list).filter(a => a.ok).map(root.accountPeak);
        if (peaks.length === 0)
            return null;
        if (root.headlineMode === "best")
            return Math.min.apply(null, peaks);
        if (root.headlineMode === "worst")
            return Math.max.apply(null, peaks);
        let sum = 0;
        for (let i = 0; i < peaks.length; i++) sum += peaks[i];
        return Math.round(sum / peaks.length);
    }

    // --- Live state ---
    property bool loading: true
    property bool ok: false
    property string errorText: ""
    property string plan: ""
    property int sessionPct: 0
    property string sessionReset: ""
    property double sessionResetAt: 0
    property bool hasSession: true  // absent when the provider reports no ~5h window (e.g. weekly-only Codex accounts)
    property int weeklyPct: 0
    property string weeklyReset: ""
    property double weeklyResetAt: 0
    property bool hasWeekly: true
    property string thirdLabel: ""
    property int thirdPct: 0
    property string thirdReset: ""
    property double thirdResetAt: 0
    property bool hasThird: true   // model-scoped weekly (Claude) / extra lane (Codex); hidden when the API omits it

    // --- Multi-account state ---
    // People run several subscriptions side by side (one config dir per wrapper
    // script). With a single account this stays a one-entry list and every path
    // below falls back to the flat fields above, so nothing changes for them.
    property var accounts: []
    property var aggregate: null
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

    // Meters for one account entry, in the same order the single-account view
    // uses: session, weekly, then every per-model lane the provider reported.
    function metersFor(account) {
        if (!account)
            return [];
        let out = [];
        if (account.session)
            out.push({ label: "Session (5h)", pct: account.session.pct || 0, reset: account.session.reset || "", resetAt: account.session.resetAt || 0 });
        if (account.weekly)
            out.push({ label: "Weekly (7d)", pct: account.weekly.pct || 0, reset: account.weekly.reset || "", resetAt: account.weekly.resetAt || 0 });
        const models = account.models || [];
        for (let i = 0; i < models.length; i++)
            out.push({ label: models[i].label || "Model", pct: models[i].pct || 0, reset: models[i].reset || "", resetAt: models[i].resetAt || 0 });
        // Credit-billed seats have no rate-limit windows at all — their monthly
        // spend pool is the only usage there is, so it stands in for them.
        if (account.spend)
            out.push({ label: "Credits", pct: account.spend.pct || 0, reset: "", resetAt: 0,
                       detail: account.spend.detail || "",
                       used: account.spend.used, limit: account.spend.limit, currency: account.spend.currency || "USD" });
        return out;
    }

    // Meters for the single-account view. Prefers the accounts list so lanes the
    // flat fields can't express (a credit pool, a second model) still show up,
    // and falls back to the flat fields if an older helper omits accounts.
    readonly property var primaryMeters: {
        const list = root.accounts || [];
        if (list.length > 0)
            return root.metersFor(list[0]);
        let out = [];
        if (root.hasSession)
            out.push({ label: "Session (5h)", pct: root.sessionPct, reset: root.sessionReset, resetAt: root.sessionResetAt, detail: "" });
        if (root.hasWeekly)
            out.push({ label: "Weekly (7d)", pct: root.weeklyPct, reset: root.weeklyReset, resetAt: root.weeklyResetAt, detail: "" });
        if (root.hasThird)
            out.push({ label: root.thirdLabel, pct: root.thirdPct, reset: root.thirdReset, resetAt: root.thirdResetAt, detail: "" });
        return out;
    }

    // Absolute reset instant as wall-clock text. A countdown alone ("4d 17h")
    // makes you do the arithmetic; the clock time is what you actually plan
    // around. Same day -> just the time, otherwise the weekday, and the date
    // once it is far enough out that the weekday is ambiguous. Kept short and
    // lowercase ("tom 02:59", "thu 04:00") — these sit in a narrow column
    // beside the bar, so every character costs bar width.
    function formatResetAt(epoch) {
        if (!epoch || epoch <= 0)
            return "";
        const when = new Date(epoch * 1000);
        if (isNaN(when.getTime()))
            return "";
        const now = new Date();
        // Past instants are stale data (a window that already rolled over);
        // showing them would be worse than showing nothing.
        if (when.getTime() <= now.getTime())
            return "";
        // 24h, explicitly — the locale short format drags in AM/PM, which is
        // three more characters in a column that is already fighting the bar.
        const time = when.toLocaleTimeString(Qt.locale(), "HH:mm");
        const startOfDay = d => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
        const days = Math.round((startOfDay(when) - startOfDay(now)) / 86400000);
        if (days === 0)
            return time;
        if (days === 1)
            return "tom " + time;
        if (days < 7)
            return when.toLocaleDateString(Qt.locale(), "ddd").toLowerCase() + " " + time;
        return when.toLocaleDateString(Qt.locale(), "d MMM").toLowerCase() + " " + time;
    }

    // Money for the compact row: no cents, thousands separated. At credit-pool
    // scale the cents are noise, and this column is only as wide as the bar can
    // spare. The expanded card keeps the engine's exact string.
    function formatSpend(meter) {
        if (!meter || meter.used === undefined || meter.limit === undefined)
            return "";
        const sym = meter.currency === "USD" ? "$" : "";
        const round = n => Math.round(n).toLocaleString(Qt.locale(), "f", 0);
        return sym + round(meter.used) + " / " + sym + round(meter.limit);
    }

    // The card has room for the cents. Falls back to the engine's own string
    // if an older helper sent only that.
    function formatSpendExact(meter) {
        if (!meter)
            return "";
        if (meter.used === undefined || meter.limit === undefined)
            return meter.detail || "";
        const sym = meter.currency === "USD" ? "$" : "";
        const money = n => sym + n.toLocaleString(Qt.locale(), "f", 2);
        return money(meter.used) + " of " + money(meter.limit);
    }

    // "Resets in 4d 17h · thu 04:00", degrading to whichever half we have.
    function resetLabel(meter) {
        if (!meter)
            return "";
        const at = root.formatResetAt(meter.resetAt || 0);
        const inn = meter.reset && meter.reset !== "\u2014" ? meter.reset : "";
        if (inn && at)
            return "Resets in " + inn + " \u00b7 " + at;
        if (at)
            return "Resets " + at;
        if (inn)
            return "Resets in " + inn;
        return "";
    }

    function providerIcon() {
        return root.provider === "codex" ? "terminal" : "smart_toy";
    }
    function providerName() {
        return root.provider === "codex" ? "Codex" : "Claude";
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

    // One percentage has one status colour everywhere it appears. Provider and
    // account classes describe their worst lane, so using them for every meter
    // made a healthy 0% lane red whenever a different lane was exhausted.
    function percentageClass(pct) {
        const value = Math.max(0, Math.min(Number(pct) || 0, 100));
        if (value >= 90)
            return "critical";
        if (value >= 75)
            return "high";
        if (value >= 50)
            return "mid";
        return "low";
    }
    function percentageColor(pct) {
        return classColor(percentageClass(pct));
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
        if (lanes.length > 0)
            return peak;
        return root.hasSession ? root.sessionPct : root.weeklyPct;
    }

    // Headline for each provider, kept side by side so the pill can show both
    // without the popout having to be on that tab. {pct} or null when the
    // provider has no signed-in accounts.
    // The last payload per provider. Kept raw rather than reduced to a number,
    // because the headline mode and the hidden-account list can change between
    // polls and the pill has to follow them without waiting for a refetch.
    property var claudeData: null
    property var codexData: null

    function computeHead(data) {
        if (!data || data.ok !== true)
            return null;
        const agg = data.aggregate;
        const local = root.headlineFor(data.accounts);
        const pct = local !== null ? local
            : (agg && agg.pct !== undefined && agg.pct !== null ? agg.pct
            : (data.session ? data.session.pct : (data.weekly ? data.weekly.pct : 0)));
        return { pct: pct };
    }

    readonly property var claudeHead: root.computeHead(root.claudeData)
    readonly property var codexHead: root.computeHead(root.codexData)

    function noteHeadline(provider, data) {
        if (provider === "codex")
            root.codexData = data;
        else
            root.claudeData = data;
    }

    function pillHeads() {
        const heads = [];
        if (root.claudeHead)
            heads.push({ pct: root.claudeHead.pct });
        if (root.codexHead)
            heads.push({ pct: root.codexHead.pct });
        if (heads.length > 0)
            return heads;
        if (root.loading && !root.ok && root.errorText === "")
            return [{ text: "…", pct: null, error: false }];
        if (!root.ok)
            return [{ text: "!", pct: null, error: true }];
        return [{ pct: root.headlinePct }];
    }

    function refresh() {
        if (!otherProc.running)
            otherProc.running = true;
        if (usageProc.running)
            return;
        usageProc.running = true;
    }

    function setProvider(p) {
        if (root.provider === p)
            return;
        root.provider = p;
        if (root.pluginService)
            root.pluginService.savePluginData("aiUsage", "provider", p);
        root.loading = true;
        root.refresh();
    }

    readonly property string aiUsageCommand: Paths.vshellCli

    Process {
        id: usageProc
        command: [root.aiUsageCommand, "ai-usage", root.provider]
        running: false
        stdout: StdioCollector {
            id: usageOut
            onStreamFinished: root.parseOutput(usageOut.text)
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
            onStreamFinished: {
                try {
                    root.noteHeadline(root.otherProvider, JSON.parse((otherOut.text || "").trim()));
                } catch (e) {
                    root.noteHeadline(root.otherProvider, null);
                }
            }
        }
    }

    function parseOutput(txt) {
        root.loading = false;
        try {
            const d = JSON.parse((txt || "").trim());
            root.ok = d.ok === true;
            root.noteHeadline(root.provider, d);
            root.accounts = d.accounts || [];
            root.aggregate = d.aggregate || null;
            if (!root.ok) {
                root.errorText = d.error || "usage unavailable";
                return;
            }
            root.errorText = "";
            root.plan = d.plan || "";
            root.hasSession = !!d.session;
            root.sessionPct = (d.session && d.session.pct) || 0;
            root.sessionReset = (d.session && d.session.reset) || "";
            root.sessionResetAt = (d.session && d.session.resetAt) || 0;
            root.hasWeekly = !!d.weekly;
            root.weeklyPct = (d.weekly && d.weekly.pct) || 0;
            root.weeklyReset = (d.weekly && d.weekly.reset) || "";
            root.weeklyResetAt = (d.weekly && d.weekly.resetAt) || 0;
            root.hasThird = !!d.third;
            root.thirdLabel = (d.third && d.third.label) || "";
            root.thirdPct = (d.third && d.third.pct) || 0;
            root.thirdReset = (d.third && d.third.reset) || "";
            root.thirdResetAt = (d.third && d.third.resetAt) || 0;
        } catch (e) {
            root.ok = false;
            root.errorText = "parse error";
        }
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

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            VgsIcon {
                name: root.providerIcon()
                size: root.iconSize
                color: Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter
            }

            Row {
                spacing: 0
                anchors.verticalCenter: parent.verticalCenter

                Repeater {
                    model: root.pillHeads()

                    Row {
                        required property var modelData
                        required property int index
                        spacing: 0

                        StyledText {
                            visible: index > 0
                            text: " / "
                            font.pixelSize: root.pillFontSize
                            font.weight: Font.Medium
                            color: Theme.surfaceVariantText
                        }

                        StyledText {
                            text: modelData.text !== undefined ? modelData.text : (modelData.pct + "%")
                            font.pixelSize: root.pillFontSize
                            font.weight: Font.Medium
                            color: modelData.error ? Theme.error
                                : (modelData.pct === null ? Theme.surfaceVariantText
                                                        : root.percentageColor(modelData.pct))
                        }
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

            headerText: root.providerName() + " Usage"
            detailsText: {
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

            property bool settingsOpen: false

            // Sits left of the close button; same 32x32 hit target so the two
            // read as a pair.
            headerActions: Component {
                Rectangle {
                    width: 32
                    height: 32
                    radius: Theme.controlRadius
                    color: gearArea.containsMouse ? Theme.surfaceContainerHighest
                                                  : Theme.withAlpha(Theme.surfaceContainerHighest, 0)

                    VgsIcon {
                        anchors.centerIn: parent
                        name: "tune"
                        size: Theme.iconSize - 4
                        color: popout.settingsOpen ? Theme.primary : Theme.surfaceText
                    }

                    MouseArea {
                        id: gearArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: popout.settingsOpen = !popout.settingsOpen
                    }
                }
            }

            Column {
                width: parent.width
                spacing: Theme.spacingM

                // --- display settings, folded away by default ---------------
                StyledRect {
                    width: parent.width
                    height: settingsCol.implicitHeight + Theme.spacingM * 2
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainerHigh
                    visible: popout.settingsOpen

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
                                ? root.orderedAccounts(root.accounts) : []

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

                    VgsButton {
                        text: "Claude"
                        iconName: "smart_toy"
                        width: (providerRow.width - Theme.spacingS) / 2
                        backgroundColor: root.provider === "claude" ? Theme.primary : Theme.surfaceContainerHigh
                        textColor: root.provider === "claude" ? Theme.primaryText : Theme.surfaceText
                        onClicked: root.setProvider("claude")
                    }

                    VgsButton {
                        text: "Codex"
                        iconName: "terminal"
                        width: (providerRow.width - Theme.spacingS) / 2
                        backgroundColor: root.provider === "codex" ? Theme.primary : Theme.surfaceContainerHigh
                        textColor: root.provider === "codex" ? Theme.primaryText : Theme.surfaceText
                        onClicked: root.setProvider("codex")
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

                        Column {
                            id: rowCol
                            anchors.fill: parent
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingXS

                            Item {
                                width: parent.width
                                height: Math.max(labelText.implicitHeight, pctText.implicitHeight)

                                StyledText {
                                    id: labelText
                                    text: modelData.label
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Medium
                                    color: Theme.surfaceText
                                    anchors.left: parent.left
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                StyledText {
                                    id: pctText
                                    text: modelData.pct + "%"
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Bold
                                    color: root.percentageColor(modelData.pct)
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            Rectangle {
                                width: parent.width
                                height: 6
                                radius: 3
                                color: Theme.surfaceContainerHighest

                                Rectangle {
                                    width: parent.width * Math.max(0, Math.min(modelData.pct, 100)) / 100
                                    height: parent.height
                                    radius: 3
                                    color: root.percentageColor(modelData.pct)
                                }
                            }

                            StyledText {
                                // A credit pool reports an amount, not a countdown.
                                text: root.formatSpendExact(modelData) || root.resetLabel(modelData)
                                visible: text.length > 0
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                            }
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
                        readonly property var meters: root.metersFor(modelData)
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

                                Item {
                                    required property var modelData

                                    width: accountCol.width
                                    height: compactLabel.implicitHeight + 5

                                    StyledText {
                                        id: compactLabel
                                        anchors.left: parent.left
                                        anchors.top: parent.top
                                        width: 74
                                        text: modelData.label
                                        elide: Text.ElideRight
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                    }

                                    Rectangle {
                                        anchors.left: compactLabel.right
                                        anchors.leftMargin: Theme.spacingXS
                                        anchors.right: compactReset.left
                                        anchors.rightMargin: Theme.spacingXS
                                        anchors.verticalCenter: compactLabel.verticalCenter
                                        height: 4
                                        radius: 2
                                        color: Theme.surfaceContainerHighest

                                        Rectangle {
                                            width: parent.width * Math.max(0, Math.min(modelData.pct, 100)) / 100
                                            height: parent.height
                                            radius: 2
                                            color: accountCard.modelData.ok
                                                ? root.percentageColor(modelData.pct) : Theme.error
                                        }
                                    }

                                    StyledText {
                                        id: compactPct
                                        anchors.right: parent.right
                                        anchors.top: parent.top
                                        width: 32
                                        horizontalAlignment: Text.AlignRight
                                        text: modelData.pct + "%"
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.weight: Font.Medium
                                        color: accountCard.modelData.ok
                                            ? root.percentageColor(modelData.pct) : Theme.error
                                    }

                                    // The reset clock time belongs on the collapsed row too —
                                    // otherwise it is only readable one account at a time, and
                                    // comparing windows across accounts is the point of this view.
                                    StyledText {
                                        id: compactReset
                                        anchors.right: compactPct.left
                                        anchors.rightMargin: Theme.spacingS
                                        anchors.top: parent.top
                                        text: root.formatSpend(modelData) || root.formatResetAt(modelData.resetAt || 0)
                                        visible: text.length > 0
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                    }
                                }
                            }

                            // Expanded: the full card treatment, one per window.
                            Repeater {
                                model: accountCard.expanded ? accountCard.meters : []

                                Column {
                                    required property var modelData

                                    width: accountCol.width
                                    spacing: 2
                                    topPadding: Theme.spacingXS

                                    Item {
                                        width: parent.width
                                        height: Math.max(fullLabel.implicitHeight, fullPct.implicitHeight)

                                        StyledText {
                                            id: fullLabel
                                            anchors.left: parent.left
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: modelData.label
                                            font.pixelSize: Theme.fontSizeMedium
                                            color: Theme.surfaceText
                                        }

                                        StyledText {
                                            id: fullPct
                                            anchors.right: parent.right
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: modelData.pct + "%"
                                            font.pixelSize: Theme.fontSizeMedium
                                            font.weight: Font.Bold
                                            color: accountCard.modelData.ok
                                                ? root.percentageColor(modelData.pct) : Theme.error
                                        }
                                    }

                                    Rectangle {
                                        width: parent.width
                                        height: 6
                                        radius: 3
                                        color: Theme.surfaceContainerHighest

                                        Rectangle {
                                            width: parent.width * Math.max(0, Math.min(modelData.pct, 100)) / 100
                                            height: parent.height
                                            radius: 3
                                            color: accountCard.modelData.ok
                                                ? root.percentageColor(modelData.pct) : Theme.error
                                        }
                                    }

                                    StyledText {
                                        text: modelData.detail ? modelData.detail : root.resetLabel(modelData)
                                        visible: text.length > 0
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                    }
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
        }
    }
}
